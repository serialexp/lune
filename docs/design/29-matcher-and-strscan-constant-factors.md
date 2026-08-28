# 29 — matcher & string→number constant factors (Pall-core parity)

Status: **DRAFT — codex-reviewed (ledger at bottom, all findings folded in);
pending Bart's grammar decision (§B2).**
Owner: Bart
Last updated: 2026-08-28

Prerequisite reading: doc 28 §11 (why the op-core arc could not close the string
gap), `~/Projects/LuaJIT/src/lib_string.c:152-512` (the matcher),
`~/Projects/LuaJIT/src/lj_char.c` (the ctype table),
`~/Projects/LuaJIT/src/lj_strscan.c` (string→number). This arc is **core-only**:
no recorder, IR, or nativegen changes. Doc 30 (pattern/tonumber recording) sits
on top of these cores and is a separate arc.

## Why this exists

Bart's question — "how are we at 3× LuaJIT with an anticipated 10% win left?" —
decomposed into three buckets (perf profiles, 2026-08-28, ReleaseFast,
`--jit-native`):

| bench | tier-0 dispatch | matcher | other |
|---|---:|---:|---|
| str_find_match 32.4 ms (2.4× LJ) | ~25% | ~40% | tonumber ~13%, wrapper ~11% |
| str_gmatch 61.2 ms (2.4×) | ~30% | ~29% | gmatchAuxCore self 24% |
| str_gsub 60.5 ms (1.37×) | **~5%** | **~53%** | map lookup 13%, gsubCore 17% |
| str_format 103.7 ms (3.6×) | ~9% | — | decimal ~40%, memcpy 17% |

LuaJIT does NOT trace pattern calls either (`recff_string_find` NYIs on any
pattern, `lj_ffrecord.c:997`) — both engines run these loops interpreted. Its
edge is (a) a cheaper interpreter (doc 30's business) and (b) **leaner C
cores**: our matcher runs ~2× its per-byte cost at identical algorithmic
structure, and our `tonumber` string path is generic `std.fmt` machinery vs his
hand-written `lj_strscan.c`. This doc closes (b). Z-6: every pattern user and
every string→number coercion wins; the benches are just the instruments.

`src/stdlib/pattern.zig` is already a faithful structural port of Pall's
matcher (the `goto init` tail-loop is `continue`, `classEnd` is threaded,
`maxExpand` is two-phase, the anchor is hoisted). The 2× is pure per-item
constant factor, in four named places (§A). Nothing structural moves.

## Part A — the matcher

### A1. Table-driven `matchClass` (the `lj_char_bits` design)

Today (`pattern.zig:82-98`): per class test = `std.ascii.toLower(cl)` + a
10-way switch + a range-compare `isX()` + `isUpper(cl)` negate. Called per
subject byte in every class quantifier loop (`%d+`, `%w+`, `[%a%d]`…).

Replace with Pall's two-table design (`lib_string.c:210-228`, `lj_char.c:24`):

- `char_bits: [256]u8` — comptime-built, bits `CNTRL|SPACE|PUNCT|DIGIT|XDIGIT|
  UPPER|LOWER` (+1 spare). Composites: ALPHA=UPPER|LOWER, ALNUM=ALPHA|DIGIT,
  GRAPH=ALNUM|PUNCT. **Built by evaluating the CURRENT `matchClass` predicates
  at comptime**, not transcribed from LuaJIT — the table is definitionally
  equal to today's semantics (bytes ≥ 0x80 get 0: lune classes are ASCII-only
  by the S-D rule, unlike LuaJIT's IDENT bit).
- `class_map: [32]u8` — maps `cl & 0x1f` → bit mask for the 10 class letters.
- `matchClass(c, cl)`: `if ((cl & 0xc0) == 0x40)` (ASCII letter either case) →
  `t = class_map[cl & 0x1f]`; if `t != 0` → `res = char_bits[c] & t != 0`,
  return `if (cl & 0x20 != 0) res else !res` (lowercase = positive class).
  Else / `t == 0` → literal `cl == c`. One load + two masks, no branch on the
  class letter. lune has no `%z` (dropped per 5.4) — `'z'` maps to 0 → literal,
  same as today.

**Pin** (review M4): the full cross-product — every `c: 0..255` × every
`cl: 0..255` (`matchClass` accepts any `u8`, not just the 20 class letters),
new table vs an **independent reference copy of the old predicates** kept in
the test (not the generator's input — a table checked against its own source
is tautological). Explicitly pinned bytes: `%s` on VT/FF (Zig
`std.ascii.whitespace` includes 0x0B/0x0C — `ascii.zig:151`), `%c` on DEL
(0x7F), high bytes ≥ 0x80 carrying no bits.

### A2. `singleMatch` literal fast path

Today the literal arm calls `litEq` → slice construction + `std.mem.eql` even
for a **1-byte ASCII literal** (the overwhelming case — 6.0% of str_find_match
is `mem.eql`). LuaJIT's is `uchar(*p) == c` (`lib_string.c:260`).

Fix: in the `else` arm, `if (ep - p == 1) return c == self.pat[p];` — a
multibyte literal item (grouped by `classEnd`, always `ep - p > 1`) keeps the
`litEq` slice compare. Semantics identical by construction.

### A3. ASCII width fast paths

- `seqLen` (`pattern.zig:169-173`): prepend `if (b < 0x80) return 1;` before
  `utf8ByteSequenceLength` — kills the per-char switch for ASCII subjects.
- `matchWidth` (`pattern.zig:208-213`): the literal arm's width is `ep - p`
  when the item is a valid sequence (byte-equality of valid UTF-8 proves
  equal encoded width) — no re-decode. **Review M3 carve-out**: a malformed
  1-byte pattern item with a high lead byte (`ep - p == 1 and pat[p] >= 0x80`
  — `classEnd`'s degraded-tail case, `pattern.zig:123`) must keep `seqLen(s)`
  so the defensive boundary-alignment contract (`pattern.zig:609`'s lone-
  `\xC3` test) is preserved: today that item byte-matches a lead byte and
  advances by the *subject's* code-point width. ASCII literals (`< 0x80`)
  have `ep - p == 1 == seqLen` — no carve-out needed. `.` keeps `seqLen`.
  Requires threading `ep` (all call sites already have it).

### A4. Specialized counting loops (`maxExpand`, the hot one)

Today `maxExpand`'s counting loop re-dispatches `singleMatch`'s 4-way switch
AND `matchWidth`'s switch per subject position. LuaJIT's source calls
`singlematch` (with its item-kind switch, `lib_string.c:253`) per iteration
too (`lib_string.c:286-289`) and relies on the C compiler to inline and
specialize it (review m3); the Zig `countRun` makes that specialization
explicit at source level rather than hoping for it.

Fix: hoist the item-kind switch out of the loop — a `countRun(s, p, ep)` that
switches ONCE on `pat[p]`:

- `.` → **O(1)**: every code point matches, return `src.len` (the S-B
  invariant — subjects at the matcher boundary are valid UTF-8 — makes
  `src.len` a code-point boundary; identical to today's loop outcome).
- `%X` where `class_map` yields a nonzero mask → `while (cur < len and
  src[cur] < 0x80 and <table test>) cur += 1;` — class items match exactly
  one ASCII byte (the load-bearing `< 0x80` guard), so width is constant 1.
  **Review M2**: a `%X` whose map entry is 0 is an *escaped literal* item
  (`%z+`, `%%+`, `%q*` — `matchClass`'s fallthrough, `pattern.zig:95`) and
  must take a repeated-equality loop against `pat[p + 1]`, not "never
  matches".
- `[set]` → same 1-byte loop over `matchBracket`.
- literal → `while (startsWith(src[cur..], item)) cur += item.len;` — with
  the M3 malformed-item carve-out from A3 applied to the stride.

The backtracking phase (`while (i>=0) match(...)`) is untouched. `minExpand`
keeps its shape (advance-by-one; it benefits from A1–A3 already).

**Pin**: the existing pattern test suite (quantifiers, S-D multibyte matrix)
covers the main arms; directed tests additionally cover (review m2): `%z+`,
`%%+`, `%q+` (escaped-literal quantified), complement classes at a multibyte
boundary, the malformed-multibyte-pattern parity leg, and `countRun` == the
old loop on a mixed ASCII/multibyte subject for each item kind.

### A5. (Optional, measured separately) first-item skip-scan in the outer loop

`findCore`/`matchCore`/`gsubCore`/`gmatchAuxCore` retry `match` at every
subject offset. When a failed offset must fail at the first item, a skip-scan
(literal first byte → `indexOfScalar`; class → `char_bits` loop) advances to
the next candidate offset before paying `reset` + `match` + dispatch. The
eligibility predicate is **positive** (review m1), not "no `*`/`-`/`?`": the
first pattern item must be a *consuming* literal, real character class, or
bracket set, whose quantifier is absent or `+` — everything else (`(`/`()`
captures, `%f`, `%b`, `%1`-`%9` back-refs, terminal `$`, empty patterns,
zero-width-capable quantifiers) keeps the plain loop. Candidate scanning
steps by code point (S-D) exactly as the plain loop does. This is beyond-Pall
(PUC-Lua and LuaJIT both lack it) but general: every unanchored pattern scan
over non-matching prefixes wins (gsub's `%w+` over spaces; gmatch's `[^,]+`
over dense tokens is neutral). Directed tests: empty pattern, `()a`,
`%f[%a]a`, `$`, `(ab)%1`, `a+`, multibyte first literal. Landed LAST and
A/B'd alone; dropped if it doesn't pay or the predicate grows warts.

### A-semantics

Zero language-visible change. All existing matcher tests + the S-D matrix +
hashgate 84/84 pin it; A1's exhaustive parity test pins the table.

## Part B — string→number (`arith.toNumber`'s string path)

### B1. Current state

`arith.zig:282-309`: trim ASCII whitespace → `std.fmt.parseInt(i64, t, 0)` →
else `std.fmt.parseFloat(f64, t)` → else nil. Explicit-base form:
`std.fmt.parseInt(i64, t, base)`. ONE core, shared by the `tonumber` native
and the recorder's konst fold — that property is preserved.

Cost: `parseInt` base-0 is generic comptime machinery — per char: underscore
filtering, `charToDigit`, checked mul/add — plus a failed full parse before
`parseFloat` even starts on float inputs. ~13% of str_find_match
(`bToNumber` 7.1% + `parseIntWithSign`/`parseInt` ~4% + overhead).

### B2. The grammar decision (Bart) — std.fmt is not Lua

What the current path ACCEPTS, verified against the pinned toolchain
(`fmt.zig:306-316` doc + tests, `fmt/parse_float/parse.zig:143` underscores):

| input | lune today | Lua 5.4 | LuaJIT |
|---|---|---|---|
| `"1_000"` | 1000 | nil | nil |
| `"0o17"` | 15 | nil | nil |
| `"0b101"` | 5 | nil | nil |
| `"inf"` / `"nan"` | inf / nan | nil | inf / nan |
| `"0x10"` | 16 | 16 | 16 |
| `"0x1p4"` | 16.0 | 16.0 | 16.0 |
| `"0xffffffffffffffff"` | 1.8446744073709552e19 (float) | -1 (wraps mod 2⁶⁴) | 1.8446744073709552e19 (double) |
| `" 3.5 "` | 3.5 | 3.5 | 3.5 |

The `_`/`0o`/`0b` rows are std.fmt artifacts, not decisions anyone made.
Options:

- **(a) Freeze today's grammar** — the new scanner replicates std.fmt's
  acceptance set exactly. No semantic change; carries the accidental grammar
  forward deliberately.
- **(b) Lua 5.4 grammar** — decimal/hex ints (hex wraps mod 2⁶⁴), decimal/hex
  floats, sign, whitespace; drops `_`, `0o`, `0b`, `inf`, `nan`.
- **(c) LuaJIT grammar** — (b) plus `inf`/`nan` (and LuaJIT's `0b`), hex
  overflow → double instead of wrap.

The parser's literal grammar (`parser.zig:677-730`, same std.fmt calls) is a
**separate language-design surface and out of scope** — noted in TODO.md;
whatever is chosen here does not silently change source-literal syntax.

### B3. The implementation (shaped by review Blocker #1)

Today's operation is not "a grammar, then a conversion" — it is an **ordered,
type-sensitive pipeline** (trim exactly `" \t\n\r"` → try `parseInt(i64,t,0)`
→ only on *any* integer error try `parseFloat` → preserve the int/float tag).
Reproducing that routing exactly from a fresh grammar is a minefield (codex
enumerated the families: `"1e5"`/`"1.0"` must stay floats; 21-digit
`"00…001"` is int 1, so digit-count cutoffs mis-route; parseInt and
parseFloat have *different* underscore grammars — `fmt.zig:439` vs
`parse_float/parse.zig:278` — so underscore acceptance can depend on which
lane a value overflows into; `"infinity"` is accepted case-insensitively,
`parse_float/parse.zig:249`; `"-0"` is int 0 but `"-0.0"` is float −0.0; the
trim set is four bytes, NOT `std.ascii.isWhitespace`, which adds VT/FF).

So the design under each grammar option:

- **Grammar (a) — freeze today**: NO full scanner. A **fast path that claims
  only the unambiguous shape** and falls through to the existing untouched
  std.fmt pipeline for everything else: optional `" \t\n\r"` trim, optional
  single sign, 1+ pure ASCII digits (no `_`, no prefix, no `.`/`e`), value
  accumulated in u64 with the sign-asymmetric i64 range check → `Value.int`.
  Anything else — including >19-digit runs (leading zeros!), any non-digit —
  takes today's `parseInt`/`parseFloat` calls verbatim. Routing and tags are
  preserved **by construction** (the fast path claims exactly a subset of
  strings where `parseInt` succeeds with the same value); the bench case and
  the overwhelming majority of real `tonumber(string)` calls (plain decimal
  ints) get the ~10× cheaper path. ~40 lines.
- **Grammar (b)/(c) — Lua 5.4 / LuaJIT**: the acceptance set changes anyway,
  so a full single-pass scanner owns the grammar: strscan's prescan-and-
  accumulate shape, int/hex/float classification, with the float *conversion*
  still delegated to `std.fmt.parseFloat` on the validated slice (values
  bit-identical to a correctly-rounded converter; a full `strscan_dec` port
  is available as a later std.fmt-independence step, not this arc). The
  chosen grammar's behavior matrix (every B2 row + codex's edge families) is
  pinned by tests, and tag routing is defined BY the grammar (integral
  decimal → int; any `.`/exponent/hex-float → float; hex per the B2 overflow
  cell), not by error-fallback.

Either way the **explicit-base form** gets a trivial hand loop only under
(b)/(c); under (a) it keeps `parseInt(i64, t, base)` untouched (its cost is
not on any profile).

### B4. Determinism

Unchanged by construction: `arith.toNumber` remains the ONE core (tier-0
native + recorder konst fold + doc 30's future `str2num` op all call it); it
stays a pure function of its byte input; all 8 modes share it. A B2 grammar
change is a language-level semantic change applied uniformly — hashgate
re-verifies 84/84 (no bench exercises the changed rows).

## Tests

- A1 exhaustive `matchClass` parity (256×20 + literals) + comptime assert.
- A4 `countRun` vs old-loop equivalence per item kind, ASCII + multibyte.
- Full existing pattern/S-D/string suites (unchanged expectations).
- B: behavior matrix pinning every row of the B2 table for the chosen option,
  plus codex's edge families (review m2): >19 decimal digits **with leading
  zeros** (int 1, not float); >16 hex nibbles with leading zeros; `"1e0"` vs
  `"1"` (float vs int tag); `"-0"` (int 0) vs `"-0.0"`/`"-0e0"` (float −0.0);
  `"infinity"` mixed-case; VT/FF around a number (rejected — trim is exactly
  4 bytes); consecutive/internal underscores incl. spellings whose acceptance
  differs between the two std.fmt lanes; uppercase `0X`/`0B`/`0O` prefixes;
  i64 max/min boundaries; `""`, `"-"`, `" 42 "`, `"0x"` bare, embedded NUL,
  `"1e999"` → inf-per-today; equivalent explicit-base cases. Differential
  fuzz current-vs-new comparing **nil/int/float tag AND float bits**, not
  acceptance alone (all-accept + all-reject + boundary corpora). The existing
  `bToNumber` tests (`basic.zig:337-344`) are far too shallow to carry this —
  the matrix above becomes the suite.
- Bench gates: `just test` both legs, hashgate 84/84, `just bench` 28/28
  cross=ok, whole-board A/B vs a `just shadow` baseline (nm-verified),
  instruction-count A/B on the four string benches + scalar (no regression
  outside noise elsewhere).

## Expected outcome (honest predictions, measured against the 2026-08-28 board)

- str_gsub 60.5 → **~45-50 ms** (matcher is 53% of it; target ≤1.2× LJ's 44.1
  comes into view).
- str_find_match 32.4 → **~26-28 ms** (matcher 40% halved + tonumber 13%
  mostly removed).
- str_gmatch 61.2 → **~52-55 ms** (matcher 29% halved).
- str_manip / str_format: neutral (no pattern calls / decimal-bound).
- The remaining gap on find_match/gmatch is tier-0 dispatch — doc 30's arc.

## Landed results (2026-08-28, A1–A4 + B(a); A5 deferred)

Board `bench/results/20260828-212112-aeedf4c.tsv` vs the pre-arc board, plus
an instruction-count A/B against a `just shadow` aeedf4c baseline
(nm-verified: baseline has no `countRun`/`fastDecInt` symbols), jit mode,
`perf stat -e instructions -r 3`:

| bench          | wall (jit)      | ×LJ           | instructions |
|----------------|-----------------|---------------|--------------|
| str_find_match | 32.4 → 29.8 ms  | 2.4× → 2.2×   | **−12.2%**   |
| str_gsub       | 60.5 → 53.3 ms  | 1.37× → **1.2×** | **−16.9%** |
| str_gmatch     | 61.2 → 58.0 ms  | 2.3× (flat)   | **−7.6%**    |
| str_format     | 101.8 ms (flat) | 3.6×          | −0.00%       |
| scalar         | flat            | 0.9×          | +0.00%       |

Full 28-row board: cross=ok everywhere, no regressions (nsieve 1.1×,
sieve_int 1.1×). **str_gsub is at the ≤1.2× campaign target.**

Honest deltas vs the predictions above: gsub landed −11% wall (predicted
−20-25%) — the matcher share shrank but map-lookup/interning remain; still
reached target. gmatch only −4% wall (predicted −10-15%): its `[^,]+` bracket
class still linear-scans `matchBracket` per byte inside `countRun` (the
bitset-precompute non-goal), and its dominant cost is tier-0 dispatch —
doc 30's lever. find_match −8% wall, in range. Format/scalar exactly flat as
predicted, confirming zero collateral cost.

A5 (first-item skip-scan) not landed — deferred until after doc 30, where
its benefit can be measured against the recorded-callout world it would
actually live in.

## Non-goals

- Recorder/IR/native work (doc 30).
- `matchBracket` bitset precompute (LuaJIT doesn't either; short sets dominate;
  revisit only with a profile showing bracket-scan heat).
- Parser literal grammar (separate surface, TODO.md).
- `string.format`/decimal renderer (own arc, doc 28 §7).
- NUL-sentinel string representation (LuaJIT's matcher trick; lune keeps
  explicit bounds — the A-series removes the cost where it was measurable).
- A full `strscan_dec` port (std.fmt float-conversion independence): only if
  a profile ever shows float-parse heat; grammar (b)/(c)'s scanner is built
  so the converter is swappable.

## Codex review ledger (2026-08-28)

Blockers: **#1** B option (a) "bit-identical by construction" was too strong —
today's behavior is an *ordered, type-sensitive* pipeline (int lane, then
float lane, tag preserved), and a fresh grammar cannot safely reproduce its
routing (leading-zero digit counts, divergent underscore grammars between the
two std.fmt lanes, `"infinity"`, `-0` tags, the exact 4-byte trim set vs
`isWhitespace`'s VT/FF) → B3 rewritten: under grammar (a) the fast path
claims only the unambiguous plain-decimal-int shape and everything else falls
through to the existing pipeline verbatim; a full scanner exists only under a
deliberate grammar change (b)/(c). Majors: **#2** `countRun`'s `%X` arm must
fall back to escaped-literal equality when the class map yields 0 (`%z+`,
`%%+`, `%q*`) → folded into A4. **#3** A3/A4's literal width `ep - p` broke
the malformed-pattern defensive contract (`pattern.zig:609` lone-`\xC3`
boundary alignment) → carve-out: `ep - p == 1 and pat[p] >= 0x80` keeps
`seqLen(s)`. **#4** parity domain underspecified → full 256×256 cross-product
against an independent reference predicate. Minors: **m1** A5 predicate
stated positively (consuming literal/class/set, quantifier absent or `+`).
**m2** directed-test additions folded into A4/A5/Tests. **m3** LuaJIT
counting-loop characterization corrected (source calls `singlematch` per
iteration; the compiler specializes — `countRun` makes it explicit).
