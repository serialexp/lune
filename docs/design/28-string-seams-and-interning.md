# 28 — String seams & interning: general string-op speed

Status: reviewed (codex gpt-5.6-sol: approve-with-must-fixes — all folded in
below and marked **[MF]**)
Arc: Bart 2026-08-28 — "Lets do the strings first. Everyone will run into
those at some point."

## 1. Problem: the profile, across every string bench

`perf record` on the four string benches (ReleaseFast, `--trace --jit-native`,
board args), symbols rolled up by cause:

| cost, % of run            | str_manip | str_find_match | str_gmatch | str_format |
|---------------------------|-----------|----------------|------------|------------|
| codepoint↔byte seam scans | ~27 (subCore 17.4 self + caseCore decode share + decodeAt 3.2 + reverseCore share) | ~10 (cpCount/byteToChar inlined into matchCore 16.9/findCore 8.4 self) | small (byte-offset state) | small (%Ns widths) |
| interning tax (wyhash + probe memcmp + intern) | ~17 (wyhash 11.3 + intern 5.6) | ~9 (captureValue skid + mem.eql 4.8) | ~18 (captureValue skid inside gmatchAuxCore 23 self + intern 2.1) | ~7 (intern 4.5 + wyhash 2.4) |
| memcpy (scratch + intern copy) | 13.4 | — | — | 10.6 |
| pattern engine proper (`MatchState.match`/`singleMatch`/`matchClass`) | — | ~27 | ~30 | — |
| tier-0 dispatch (`Vm.exec`, `lenValue`) | 19.1 | 31.3 | 30.3 | 14.9 |
| decimal exact renderer (`toDigits`/`exactDigits`/`fixed`) | — | — | — | ~45 |

(The `captureValue` "skid" rows: `perf annotate` shows 51% of matchCore's and
69% of gmatchAuxCore's self time on the instruction *after* `callq
captureValue` — return-skid attribution of the per-capture `internValue`
work, i.e. interning tax, not scan work.)

Two general costs dominate everything that isn't the pattern engine, the
decimal renderer, or tier-0 dispatch:

**(a) Seam scans that re-derive what the String already caches.** mahina
strings are code-point-native (S-B): `#s`, `sub`, `codepoint`, `find`
indices are all character-based. The seams between character positions and
byte offsets (`cpCount`, `charByteOffset`, `byteToChar`, `resolveInit`,
`decodeAt`) are O(n) decode scans — run per *call*, on every `string.sub`,
every `find`/`match` (`resolveInit` does `cpCount(s)` per call; a match hit
does `cpCount(s[0..e])`), every `codepoint`. Yet every `*String` already
caches `cp_len`, and — for valid UTF-8 (§2) — `cp_len == len` ⟺ the string
is pure ASCII ⟺ **every one of those conversions is the identity**. The
cores throw this away because `strArg` degrades to `[]const u8` at the
wrapper boundary.

**(b) The interning tax.** Every produced string — a `sub` slice, a case
map, a capture, a token, a `format` result — pays `Wyhash.hash(0, bytes)`
over the *full* content plus a chain probe (`mem.eql` on hit). Steady-state
loops produce the same strings forever, so this is pure per-op overhead on
the hit path. LuaJIT pays the same *structure* but its default hash
(`lj_str.c hash_sparse`) is **O(1)**: four sampled unaligned u32 reads
(first 4 bytes, last 4, midpoint, quarter-point) mixed with `len`, with an
opt-in linear `hash_dense` only when a chain turns pathological
(LUAJIT_SECURITY_STRHASH). mahina's is O(len) always.

Not this arc (each its own frontier, recorded in §7): the pattern engine
internals (already a faithful byte-based lj port), the exact decimal
renderer (str_format's ~45%), tier-0 dispatch fraction (JIT-coverage arcs),
rep3 recording.

## 2. Design principle: consult the String, not the bytes (Z-7)

The structural error is that the cores take `[]const u8` and re-derive
character structure per call. The fix is to **thread the `*const String`
through the seams** so cached facts flow to every consumer, and specialize
on the free predicate

```zig
inline fn isAscii(s: *const String) bool { return s.cp_len == s.len; }
```

**[MF, REVISED during c1 — the review's fix was itself wrong.]** The
review correctly observed that `cp_len == len` proves ASCII only for valid
UTF-8 (`countCodepoints` counts non-continuation bytes, so all-`0xFF`
counterfeits it), and proposed enforcing valid UTF-8 as a construction
invariant (restore validation + constructor assert). **Implementing that
enforcement failed the effect suite and exposed the real architecture**:
mahina's *validate-after-log* seams (`performEffect`, `obtainFileRead`)
deliberately intern raw non-UTF-8 host bytes BEFORE validating — the
invalid string is parked in the effect log so a recorded bad `getenv`/
`argv`/`loadfile` replays byte-identically, and it legitimately flows
through `effectser` (inline bytes, re-interned on replay) and keyframes
(the log's parked results are live objects). Program-VISIBLE strings are
valid UTF-8 (S-B — the seams raise before the value escapes, catchably),
but String *objects* are not, by design, and no constructor assert or
restore rejection can stand.

**Landed design instead: an exact `str_ascii` bit** in `GcFlags` (a spare
flag bit — the header doc explicitly refuses per-string bloat), computed
in the same construction-time scan as `cp_len` (`b >= 0x80` ⇒ false).
`String.isAscii()` is then a proof for ANY bytes — valid, invalid,
program-visible or log-parked — with zero storage growth and no
whole-system reasoning. Not serialized; restore recomputes through
`create`. Non-ASCII (and non-UTF-8) strings take exactly the current code
paths; outputs are byte-identical in every case (pure recomputation
refactor — invisible to determinism, effects, traces, replay).

## 3. L1 — seam helpers specialize on ASCII

New shapes, all in `stdlib/string.zig`:

```zig
/// 1-based char → 0-based byte. ASCII: identity (ci-1, clamped).
fn charByteOffsetS(s: *const String, ci: usize) usize {
    if (isAscii(s)) return @min(ci -| 1, s.len);
    return charByteOffset(s.bytes(), ci);
}
// Edge agreement with the byte helper (verified in review): ci ∈ {0,1} → 0;
// ci == cp_len+1 → len; beyond → len; empty string → 0.

/// 0-based byte boundary → 1-based char. ASCII: off + 1.
fn byteToCharS(s: *const String, off: usize) usize {
    std.debug.assert(off <= s.len); // [MF] slice precondition stays explicit
    if (isAscii(s)) return off + 1;
    return cpCount(s.bytes()[0..off]) + 1;
}

/// cpCount of a prefix. ASCII: the byte length.
fn cpCountPrefixS(s: *const String, end: usize) usize {
    std.debug.assert(end <= s.len); // [MF]
    if (isAscii(s)) return end;
    return cpCount(s.bytes()[0..end]);
}

/// [MF] Byte end of "at most `count` characters" — count-clamped BEFORE any
/// arithmetic, so a huge parsed %.Ns precision cannot overflow `count + 1`.
fn charPrefixEndS(s: *const String, count: usize) usize {
    const n = @min(count, s.cp_len);
    if (isAscii(s)) return n;
    return charByteOffset(s.bytes(), n + 1);
}
```

Consumers converted to take `*const String` (wrappers switch from `strArg`
to `strObjArg`; the JIT shims in `stralloc.zig` already hold the `*String`
and currently degrade via `.bytes()` — they pass the object instead).
**[MF] Subject strings become objects; pattern strings stay `[]const u8`;
`pattern.MatchState` stays byte-based.**

* `subCore` — both `charByteOffset` scans collapse; an ASCII `sub` becomes
  slice-and-intern. (17.4% self in str_manip is this scan.)
* `codepointCore` / `sCodepointN` / `codesAuxCore` — direct byte read for
  ASCII (`decodeAt` skipped; the byte IS the code point). `codesAuxCore`
  already threads its ordinal (no seam scan today) — object recovery is
  for the direct read only.
* `resolveInit` — `cpCount(s)` → `cp_len`; offset conversion identity for
  ASCII. **[MF] Applies to `find`/`match` only** — `gmatch` threads a byte
  position through its state table and `gsub` starts at byte 0; neither
  has an init seam. (`gsub` benefits via position captures and known-count
  interning only.)
* `findCore`/`matchCore` result seam — `byteToChar`/`cpCount(s[0..e])` per
  hit become O(1)/identity for ASCII.
* **[MF]** `gmatchAuxCore` recovers the subject **object** from `state[1]`
  (it holds the string `Value` already — take `String.fromHeader` instead
  of only `interp.strBytes`) and threads it to `writeCaptures` →
  `captureValue` (position captures use `byteToCharS`). Same threading for
  the three `addRepl*` functions under `gsubCore`.
* **[MF]** `sFormat` `%Ns`/`%Nc`: rather than guessing "the emitted
  slice's ASCII-ness", `emitString` takes a **known character count** from
  the caller: a string argument passes `min(precision, s.cp_len)` /
  `s.cp_len` (via `charPrefixEndS` for the precision cut); `%c` passes 1;
  numeric/nil/boolean coercions are ASCII by construction → `body.len`.
  This deletes `emitString`'s `cpCount` scan for non-ASCII arguments too.
  **[MF]** The width/precision digit accumulators get checked arithmetic
  with a defined rejection (bad-argument) instead of overflow.

The `[]const u8` helper forms stay for pattern internals and scratch
slices — and as the **reference implementations** the tests compare the
fast paths against (§8).

## 4. L2 — caseCore/reverseCore block paths

`caseCore` today: per-byte loop with `try buf.append` per byte (ArrayList
bounds-check + grow check per byte), Unicode `decodeAt` + table map above
0x7F. New shape:

* **ASCII input** (`isAscii(s)`): `try buf.resize(s.len)` once, then a
  plain `for` byte map (`std.ascii.toUpper`/`toLower`) — no decode, no
  per-byte capacity checks; LLVM autovectorizes. Result `cp_len == s.len`
  by construction (L4 hook).
* **General path: unchanged.** **[MF]** The reviewed draft's
  `ensureTotalCapacity` + `appendAssumeCapacity` mix is unsound (a
  multibyte re-encode can grow past the reservation and a fallible append
  can leave capacity exactly consumed, invalidating a later assumed
  append). The profile justifies optimizing the whole-ASCII branch; the
  Unicode branch keeps its fallible appends.

The unicode-version pin (`mapCaseUnicode` → `noteUnicodeVersion`) runs
**before the core for ASCII inputs too** — the pin is a session effect and
skipping it on the fast path would fork replay behaviour. **[MF]**

`reverseCore`: ASCII input → reverse bytes into the pre-sized buffer (no
per-char `utf8ByteSequenceLength`). General path unchanged. (Takes
`*const String` now; the shim passes the object.)

## 5. L3 — intern hash policy (SEPARATE DECISION, Bart's call)

The O(len) wyhash on every intern is the largest single component of the
interning tax. The LuaJIT-shaped alternative: `hash_sparse`-style O(1)
hash — mix `len` with four sampled u32 loads (first 4, last 4, midpoint,
quarter-point; small-len degenerate variant below 4 bytes), fixed
little-endian loads (`std.mem.readInt`) so the value is
architecture-independent. **[MF]**

**[MF] Determinism analysis, corrected by review + source check:**
`String.hash` does **not** feed table-key hashing — `table.ValueContext`
hashes heap keys by stable `GcHeader.id` (value.zig:228, table.zig:589),
and observable iteration order is imposed by `key_order.keyLessThan`'s
canonical sort in both `pairs`/`next` and the keyframe serializer,
erasing probe order entirely (doc 02 §"Table iteration order"). So a hash
change affects **nothing observable**: no `pairs` order change, no
snapshot change, no bench-ref regeneration. `String.hash`'s only consumer
is the intern table itself; the hash is recomputed on restore (not
serialized). The stale "Cached for fast table-key hashing" comment on
`String.hash` (string.zig:23) gets corrected as part of any L3 landing.

**[MF] Collision hardening ships in the same change, not later.** Sparse
sampling admits engineered collisions (strings agreeing on the sampled
words); the LuaJIT answer — a deterministic chain-length threshold that
re-hashes the offending chain with the dense (linear) hash — comes along,
with a fixed seed (replay-safe: pure function of bytes) and transactional
rechaining (allocation failure leaves the table valid).

Payoff estimate: str_manip −11% (wyhash share); every string-producing
program proportionally; the tax drops most where strings are longest.

This document does NOT assume L3; L1/L2/L4 land regardless. L3 is a
standalone yes/no with this section as the decision text.

## 6. L4 — intern with a known cp_len

`Heap.intern` recounts code points on every miss (`createWithHash` →
`countCodepoints`). Producers that know the answer pass it. **[MF] One
centralized path** so the doc-24 D5 transactional shape can't fork:

```zig
// AS LANDED (c3a) — the review-era signature was `known_cp: ?usize` alone,
// which predates §2's exact `str_ascii` bit: a count cannot produce the bit,
// so the channel carries BOTH facts, each independently optional (a producer
// that knows only one still skips that half of the fused scan).
pub const String.Known = struct { cp_len: ?usize = null, ascii: ?bool = null };
fn internImpl(self: *Heap, content: []const u8, known: String.Known) !*String
// intern()       -> internImpl(content, .{})
// internKnown()  -> internImpl(content, known)   (doc draft name: internKnownCp)
```

Miss sequence unchanged and single: hash+lookup → allocate unlinked (with
the known facts) → ensure table capacity → insert → the ONE `Heap.link`.
**[MF] The safety-build assert (each known fact vs `countCodepoints(content)`)
runs on the HIT path too** — a wrong count must not hide behind existing
bytes.

Ascii-bit provenance at the §6 sites: a slice of an ASCII string, a
repetition, and a permutation all *preserve* the source's bit; a general
(non-ASCII-source) substring or a case-mapped result does NOT (Unicode
simple case mapping can cross the ASCII boundary, e.g. U+212A KELVIN SIGN
→ `k`), so those sites pass `ascii = null` and the scan derives it.

**[MF] Known sites are broader than ASCII** (the review's correction —
these hold for ALL valid inputs, not just ASCII):

* `subCore`: `j - i + 1` (character count of the slice, by definition).
* `caseCore`: `s.cp_len` (simple 1:1 mapping is count-preserving — already
  documented on the core).
* `reverseCore`: `s.cp_len` (permutation).
* `rep2Core`: `s.cp_len * n` with checked multiplication (overflow →
  fall back to `null`/recount, never a wrapped count).
* `char1Core`: 1.

## 7. Non-goals (recorded so they aren't re-derived)

* **Pattern engine internals** — faithful port of LuaJIT's byte-based
  matcher; its 27–30% share is parity-adjacent (those benches sit at
  2.3–2.7×).
* **`decimal.toDigits`** — ~45% of str_format; the exact-precision
  renderer is its own arc (digit-pair emission, pow10 LUTs).
* **tier-0 dispatch / `lenValue` share** — JIT-coverage arcs own this
  (pattern calls don't record yet; `#s` in an untraced loop pays dispatch,
  not string work).
* **rep3 recording** (`recBSRep2` is 2-arg) — separate recorder arc.
* **Capture/token result caching** — rejected on Z-6 grounds (shapes to a
  bench's repetition profile, not to the language).
* **D5 scope note [MF]:** the "≤1 `Heap.link` per core" audit rule governs
  the JIT-callout cores (`subCore`, `caseCore`, `reverseCore`, `rep2Core`,
  `char1Core`, `codepointCore`); `findCore`/`matchCore`/`gsubCore` are
  tier-0-only natives that legitimately intern several captures — the rule
  does not apply to them and this doc must not be read as extending it.

## 8. Tests

The arc's risk is a *fork* between the ASCII fast path and the general
path. Pins:

1. **Reference-comparison harness [MF]:** the byte-slice helpers
   (`charByteOffset`, `cpCount`, `byteToChar`) remain as the reference;
   tests drive the `*String` fast forms against them across exhaustive
   ASCII boundary vectors (empty; len 1; ci = 0, 1, cp_len, cp_len+1,
   beyond; negative and clamped op indices). The "non-ASCII twin" oracle
   from the draft is dropped — appending a suffix changes `cp_len` and
   breaks end-relative cases.
2. **Boundary vectors through every touched op** (`sub`, `reverse`,
   `upper`, `lower`, `codepoint`, `codes`, `find`, `match`, `gmatch`,
   `gsub`, `format %Ns/%Nc`): pure ASCII / multibyte at start-middle-end /
   empty, with negative + clamped indices; empty-match-at-end; position
   captures at byte offset `len`. **[MF]**
3. **Hostile format args [MF]:** huge `%N`/`%.N` width/precision values —
   defined rejection, no overflow trap in any build mode.
4. **Exact-bit soundness [MF, revised]:** non-UTF-8 bytes yield
   `isAscii() == false` even when they counterfeit `cp_len == len`
   (all-`0xFF` vector); genuinely-ASCII and multibyte strings get the
   right bit; a restored string recomputes it.
5. **`internImpl` contract [MF]:** wrong `known_cp` traps in safe builds on
   both hit and miss; link-count audit (miss links once, hit links zero)
   stays green.
6. **Full battery:** `zig build test`, hashgate 84/84 (byte-identical
   outputs are the whole claim), board cross=ok 28/28, plus the 8-mode
   matrix and a keyframe save/restore leg per landing step. **[MF]**

## 9. Landing plan (review-reordered)

1. **c1** — §2 exact `str_ascii` bit + L1 helpers + non-pattern consumers
   (`subCore`, `codepointCore`, `codes*`, case/reverse signature change
   only) + wrappers/shims atomically.
2. **c2** — pattern seams: `resolveInit` (find/match), result-index
   conversion, `gmatchAuxCore` object recovery, `captureValue`/`addRepl*`
   threading, `sFormat` known-count `emitString` + checked width/precision.
3. **c3a** — `internImpl`/`internKnownCp` infrastructure + contract tests.
4. **c3b** — L2 ASCII block paths + the §6 known-count call sites.
5. Gates + board at each step; doc updated with measured results.
6. **L3** presented to Bart separately (§5 is the decision text).

## 10. Predictions (to be checked against, not tuned toward)

* str_manip: seam scans ~27% + case-append discipline → jit ~23.9 ms →
  **~16–18 ms** (5.0× → ~3.4–3.8×).
* str_find_match: ~10% seam share → **~32–33 ms** (2.7× → ~2.4×).
* str_gmatch: small L1 effect (byte-offset state already); real movement
  needs L3/tier-0 coverage — expect **≤5%**.
* str_format: modest (L1 width seams + L4 crumbs); the decimal arc owns
  the rest.
* Non-string rows: strictly unchanged (interning call sites keep
  behaviour; nothing else is shared).

## 11. Measured results

c1–c3b landed; full board 20260828-191940 vs pre-arc baseline
20260828-171400 (quiet machine, ReleaseFast, reps=5).

| bench          | jit before | jit after | Δ      | ratio      | vs prediction |
|----------------|-----------:|----------:|-------:|------------|---------------|
| str_manip      | 23.9 ms    | 18.8 ms   | −21%   | 5.0× → 4.0× | just above the 16–18 band — the band assumed L3 crumbs too |
| str_find_match | 35.9 ms    | 32.4 ms   | −9.7%  | 2.7× → 2.4× | **landed** (32–33) |
| str_gsub       | 63.8 ms    | 60.5 ms   | −5.3%  | 1.4×       | unpredicted bonus (position captures + known-fact sites) |
| str_gmatch     | 61.4 ms    | 61.2 ms   | −0.4%  | 2.4×       | landed (≤5%: per-capture interning dominates — L3/dispatch territory) |
| str_format     | 99.2 ms    | ~104 ms   | **+4%**| 3.4× → 3.6× | see below |
| non-string rows| —          | —         | ±noise | —          | landed (28/28 cross=ok, no mover >±5% jit) |

**The str_format +4% was A/B'd and bisected, not shrugged off** (shadow
builds per slice, `perf stat -r 5` instruction counts): baseline 2211M
insns → c1 2244M → c2 2254M → c3a 2263M → c3b 2316M. Two components:

1. **Principled (~1%, c1):** the fused construction scan (+1 cmp/branch
   per byte on every intern miss) — the price of the exact `str_ascii`
   bit, paid by every unique string built. It buys str_manip's −21% and
   the seam O(1)s everywhere.
2. **Codegen churn (~3%, spread, biggest at c3b):** the c3b slice touches
   only cores this bench never calls (`sub`/`rep`/`reverse`/`case`), yet
   attribution swung in untouched functions (`exactDigits` +4pp,
   `execImpl` −6.6pp, memcpy↔memmove ICF renaming in `perf diff`) —
   LLVM inline/layout luck in the decimal+sFormat hot cluster. Forcing
   `internImpl` inline was tried and did NOT recover it (reverted).
   Chasing per-bench inline boundaries is exactly what Z-6 forbids; the
   decimal renderer arc (§7) rewrites this hot cluster anyway and owns
   str_format's real gap (~45% of its profile).

L3 (sparse intern hash, §5) remains a separate decision for Bart — it is
the biggest single remaining lever on every string-producing bench
(wyhash is 11.3% of str_manip; LuaJIT's `hash_sparse` is 4 sampled u32
loads, O(1) in the length).
