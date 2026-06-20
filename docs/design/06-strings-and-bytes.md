# lune — Strings & Bytes (Unicode-native text)

Status: design — not started (this doc is the shape; no code yet)
Owner: Bart
Last updated: 2026-06-19

A language designed in 2026 does not get to say "a string is an array of bytes."
That was the right call for Lua in 1993 and it is the wrong default now: outside
the US and western Europe a string that cannot represent every Unicode code point
is not usable. So lune makes the split that Python 3, Swift, and Rust all made
and that Lua (and Go's "unvalidated UTF-8 bytes") did not:

- **A `string` is a sequence of Unicode scalar values (code points).** It is text.
- **An array of bytes is an array of bytes** — an ordinary lune array of small
  integers. That is the binary type.
- The boundary between them is **explicit and fallible** (`encode` / `decode`),
  because converting bytes → text is the one operation that can fail.

This is a deliberate divergence from Lua (consistent with "Lua-shaped, not
Lua-compatible", `00-architecture.md`) and it reaches into the lexer, the string
library, the pattern engine, and one new recorded effect. It does **not** reach
into string interning, equality, hashing, table keys, or the keyframe wire —
those stay byte-keyed and unchanged, which is what keeps determinism cheap.

## Implementation status

### Done

- [x] **S-A — the bytes world + conversion boundary** (additive, no
      string-semantics change). `string.encode`/`s:encode()` → byte array (a
      table with integer keys `1..n`, each `0..255`); `string.decode(bytes)` →
      string | catchable error (validates UTF-8). Bytes are plain integer arrays;
      no new type. `encode` is a `string` module field so `s:encode()` resolves
      through the string metatable; `decode` is a free function (byte arrays have
      no metatable). Pure — no effect, a trace barrier like every native;
      determinism-invisible. ASCII is the identity on both directions. Lives in
      `src/stdlib/string.zig` (`sEncode`/`sDecode`); unit tests there + 8-mode
      `expectProgram` parity in `interp.zig`. CSV rows `string.encode`/
      `string.decode` → implemented. **Strings are still byte-indexed at this
      point** — S-A only *adds* the conversion; code-point semantics arrive in S-B.

### Outstanding
- [x] **S-B — strings become code-point-native** (the breaking core).
      `#s`/`len`/`sub`/`reverse`/`string.char`/`string.codepoint`/`s:codes()`
      index by code point; cached `cp_len` on the heap string (computed in
      `String.create`, recomputed on restore — no schema bump); the valid-UTF-8
      invariant enforced at the construction boundary (`decodeString` +
      `utf8ValidateSlice`); `\u{…}` lexer escape; `\xNN`/`\ddd` source escapes are
      ASCII-only (a byte ≥ 0x80 is a compile error pointing at `\u{…}` or a byte
      array). `string.byte` removed; `utf8.*` dissolves into the string type. The
      char-index `sub` vs still-byte-index pattern functions (`find`/`match`/…)
      gap is the explicit intermediate state, closed in S-D. (Patterns and case
      mapping stay byte/ASCII-level until S-C/S-D.)
- [x] **S-C — case mapping + pinned Unicode version** (determinism gate).
      *Landed.* `upper`/`lower` are Unicode-aware via the vendored, versioned
      **simple (1:1)** case table (`src/gen/unicode_case.zig`, generated from
      `vendor/ucd/16.0.0/UnicodeData.txt` fields 12/13 by `tools/gen_unicode_case.py`);
      ASCII is the branch-free fast path. The active version (**16.0.0**) is
      recorded once per session as the `unicode_version` effect — packed
      `major<<16|minor<<8|patch`, pinned at the first case op, re-asserted on
      replay (a mismatch is fatal/uncatchable, `Error.UnicodeVersionMismatch`).
      The pin is derived, not stored: a snapshot resume re-scans the consumed
      effect-log prefix rather than carrying a keyframe field, so only
      `effect_format_version` bumped (3→4). Simple mapping is count-preserving:
      `ß`/`ﬀ` are unchanged (no length-changing or locale tailoring).
- [x] **S-D — patterns on code points** *(landed)*. The matcher steps the subject
      by code point — `.` matches one whole code point, a literal multibyte char is
      one item, and quantifiers/anchors/captures advance by code-point width — while
      `find`/`match`/`gmatch`/`gsub` accept and return 1-based **character** indices
      (so `find` composes with code-point-indexed `sub`; position captures `()` are
      character indices). `%a %l %u %d …` classes and bracket sets stay **ASCII**:
      a class never matches a non-ASCII byte (a load-bearing guard — without it a
      UTF-8 lead/continuation byte would wrongly satisfy the *complement* classes
      `%A`/`%D`/`[^…]`). **Caveat:** multibyte characters inside bracket sets
      (`[é]`, `[é-ñ]`) and multibyte `%b` delimiters stay byte/ASCII-level (won't
      match a whole code point). The matcher is a pure, allocation-free function of
      its byte inputs — no host effect, no new recorded input — so 8-mode
      determinism is inherited. Unicode property classes (`\p{L}`) deferred.
- [ ] **S-E — the `u8` array lane** (perf follow-up, JIT gate). One more rung on
      the monotonic lane lattice so byte arrays pack at one byte/slot;
      zero-extending native load/store in `nativegen.zig`.

## Why this exists

`02-determinism.md` makes byte-identical replay the architecture. `string.zig`
makes strings interned-by-bytes. Those two facts pull in opposite directions the
moment "string" means "text": if text operations (length, slicing, case) depend
on a *byte* view, then every non-ASCII program is subtly wrong, and if they
depend on a Unicode table, that table is a new determinism input. This doc
resolves the tension: strings present a **code-point** view over an
**internally-UTF-8** byte buffer, so identity/hashing/keys stay byte-keyed
(determinism untouched), while the one genuinely version-dependent operation
(case mapping) is handled the way lune already handles every nondeterministic
input — by **recording it** (here, the Unicode version) at the session boundary.

## Goals

- A `string` can represent every Unicode scalar value; `#s` counts characters,
  not bytes; `s:sub(i, j)` slices by character.
- Binary data has a first-class home (`bytes` = integer arrays) with no second
  string type and no new heap-object kind for the semantics (the `u8` lane is a
  perf detail, not a type).
- The text↔binary boundary is explicit and the failure case (invalid UTF-8) is a
  caught error, never silent corruption.
- Zero change to string interning, `==`, hashing, table-key behaviour, or the
  snapshot/keyframe wire format.
- Determinism preserved across Unicode-table churn: old replays reproduce
  byte-identically because they replay under their **recorded** Unicode version.

## Non-goals

- **Grapheme clusters.** A "character" is a Unicode **scalar value** (code point),
  like Python 3 `str`, Rust `char`, Go runes — *not* a UAX #29 extended grapheme
  cluster like Swift's `Character`. Grapheme segmentation needs a big, fast-
  churning versioned table and stateful O(n) iteration; it is over the deep end
  for our default. (A `graphemes()` library could come later, opt-in.)
- **Normalization** (NFC/NFD) as an implicit operation. `==` is byte equality on
  the UTF-8 form; `"é"` (U+00E9) and `"e" .. "\u{301}"` are **not** equal. A
  `normalize()` function may come later; it is never implicit.
- **Unicode identifiers** in source. Identifiers stay ASCII; only string literals
  and comments are full Unicode.
- **Locale.** Case mapping is full-Unicode default case mapping, not locale-
  tailored (no Turkish dotless-ı special case). Locale-dependent behaviour breaks
  reproducibility and is out of scope (cf. `os.setlocale` excluded).
- **Backwards compatibility** with the current byte-string library (Rule #8).
  This is a breaking rewrite of the string surface.

## The model

### `string` — a sequence of code points, UTF-8 inside

A `string` is logically a sequence of Unicode scalar values. Physically it is the
**same inline UTF-8 byte buffer we have today** (`src/string.zig`), with one
added invariant — **the bytes are always valid UTF-8** — and one added cached
field (below). Code points are version-independent (U+00DF is ß in every Unicode
version); only *operations* (case, classes) are version-dependent, and those are
handled in S-C.

Why UTF-8 internally and not UTF-32:

- Interning, hashing, table keys, and the keyframe wire already key on the byte
  buffer. UTF-8-inside means **none of that changes** — the bytes are still
  there, we just promise they are valid.
- The I/O boundary is bytes. UTF-8-inside makes `encode` a near-`memcpy`.
- The cost — character indexing is O(n), not O(1) — is acceptable: the common
  hot operation is *length* (made O(1) by caching) and *whole-string* ops
  (concat, compare, hash — all byte-level and unchanged). `sub`/`reverse`/random
  index are O(n) walks, which is correct and fine; a per-string code-point index
  is a possible later optimization, not needed now.

**Invariant enforcement is at the construction boundary, not on read.** The only
ways to make a string are: (1) a source literal (validated once by the lexer,
including `\u{…}` escapes); (2) concatenation of two valid strings (valid UTF-8 +
valid UTF-8 = valid UTF-8, no re-check); (3) number/bool coercion in `..`/
`tostring` (ASCII, trivially valid); (4) `string.char(cp…)` from code points
(each validated in range, then encoded); (5) `string.decode(bytes)` (the one
*fallible* constructor — validates, errors on malformed UTF-8); (6) **host inputs**
— `getenv`/`argv`/`file_read` content and the `arg[]` table — which can supply
arbitrary bytes and are therefore *also fallible*: the host-input boundary
validates and raises a catchable error on malformed UTF-8 (`Vm.validateHostText`),
exactly like `decode`. Because strings are immutable and interned, validation
happens exactly once per distinct content.

For the **recorded** host inputs (`getenv`/`argv`/`file_read` are nondeterministic
effects), validation runs *after* the effect is logged, on the recorded result —
so `record` (fresh intern) and `replay` (re-intern from the log) validate the
identical bytes and raise identically. The effect log stores the raw bytes; the
raise is reproduced from them, never smuggled around the log. `internValue` itself
stays unchecked: every *internal* caller (concat, coercion, error messages, the
replay re-intern, keyframe restore) is valid by construction, so the host boundary
is the only place that validates.

### Cached code-point length (the spare-bits payoff)

Since `#s` now means "number of code points", computing it by scanning UTF-8 on
every `#` would make a constant-time operation O(n). Strings are immutable and
interned, so we compute the code-point count **once at construction** and cache
it on the heap object. Today's `String` is:

```
extern struct { header: GcHeader, hash: u64, len: usize /* bytes */, <inline bytes> }
```

Add a code-point count alongside `len` (byte length stays — it is needed for the
inline allocation and for `encode`). `#s` and `string.len(s)` return the cached
count; O(1). (`len` as a `usize` has enormous spare range on 64-bit; the count
can share that budget or be its own field — an implementation detail for S-B, not
a wire-format change since the keyframe stores `(byte-len, bytes)` and the count
is recomputed/cached on load.)

### Why two types — the U+0080 collision, not "Unicode handling"

It is tempting to collapse strings and byte arrays into a single integer-array
type and *derive* the text/binary distinction from the values — "all elements
small ⇒ it's a byte array; bigger ⇒ apply UTF-8." That works for ASCII and breaks
at exactly U+0080, for a reason no rule on the values can fix:

- The string `"é"` is the **code point** `{0xE9}` (= `{233}`) — one element.
- The raw byte `0xE9` from a file read is **also** `{233}` — same array.
- But `"é"` as **UTF-8 bytes** is `{0xC3, 0xA9}` (= `{195, 169}`) — *two* elements.

So `{233}` is simultaneously a legal "the character é" and a legal "the raw byte
0xE9," and those are **not** the same text. You cannot tell which is meant from
the integers — both interpretations are valid, and the collision lives at 128,
*inside* `u8`, where everything still "fits." The **type** (not the values) has to
carry "these ints are code points" vs "these ints are raw bytes." That ambiguity
is irreducible; one type with a value-derived rule cannot express it.

There is a second, Unicode-independent reason: **mutability + interning.** A byte
array is *mutable* — you build it up from a file read, a `pack`, a socket. A
string is *immutable and interned* — which is precisely what lets it be a table
key, compare by content with `==`, and collapse to a cheap pointer-guard in the
JIT. You cannot intern a mutable buffer (its content changes out from under the
hash). So even in an all-ASCII world, "buffer being assembled" and "frozen
interned text" want to be different types.

Hence two types — but, crucially, **the wall is invisible for ASCII** (next).

### The ASCII identity (≤ U+007F): conversion is free

For pure-ASCII content (every code point `< 0x80`), the code-point sequence, the
UTF-8 bytes, and the raw byte array are **bit-identical**. `"Hi"` and `{72, 105}`
are the same two bytes. So at and below 127 the boundary is the **identity
function**, and lune makes that literal:

- `string.decode(bytes)` on all-ASCII input is a **no-op that cannot fail** —
  it just reinterprets the same bytes as text.
- `s:encode()` of an all-ASCII string is a **no-op memcpy** — the UTF-8 bytes
  *are* the byte array.

So the 90% of programs that are ASCII-only pay **zero ceremony**: a byte array and
a string are freely interchangeable, and `decode` only does work — and only *can*
fail — once a byte `≥ 0x80` appears. The U+0080 collision above is exactly the
point where the no-op stops being a no-op: a Latin-1 code point (one `u8`) and its
UTF-8 encoding (two bytes) diverge, so from there the conversion is real and the
fallible `decode` earns its keep.

This is also why strings stay **UTF-8-internal** rather than stored as code-point
arrays: UTF-8-inside is what simultaneously makes an ASCII string byte-identical
to its byte array, makes `encode` a no-op, and leaves interning / hashing /
table-keys / the keyframe wire **unchanged**. Code-point-array storage would
re-encode UTF-8 on every print/file-write and change the snapshot wire, all to buy
O(1) random indexing we've already deferred as rare (`#` is O(1) via the cached
count regardless).

### `bytes` — just an integer array

There is **no new `bytes` type.** An array of bytes is an ordinary lune array
whose elements are integers `0..255`. This is exactly Bart's framing: stick a
value `≤ 255` in an array and you have a uint8 array; stick a negative in and it
widens to a signed lane — "one more blob on the monotonic size increase thing."

- `#bytes` is the array length (= byte count) — array semantics, already correct.
- Indexing, slicing, concat of byte arrays are array/table operations.
- `string.pack`/`unpack`, file reads, sockets produce/consume byte arrays.
- `tostring(bytes)` prints as a table (it *is* a table); to view it as text,
  `string.decode` it. Explicit, by design — no accidental "bytes look like text."

The existing lane lattice is `value · boolean · i8 · i16 · i32 · i64 · f64`
(`src/array.zig`). A byte (`0..255`) lands on **i16** today (it overflows signed
`i8`'s 127 ceiling). That already works — the bytes world needs **no lattice
change to be correct**. S-E adds a `u8` rung purely so byte arrays pack at one
byte/slot instead of two; see below.

### The boundary: `encode` / `decode`

The only named operations the split genuinely requires — everything else falls
out of "strings are code points, bytes are arrays":

| Operation | Signature | Fails? |
|---|---|---|
| `s:encode()` / `string.encode(s)` | string → byte array (its UTF-8 bytes) | never |
| `string.decode(bytes)` | byte array → string | **yes** — error on invalid UTF-8 |

`encode` is total (a valid string always has valid UTF-8 bytes). `decode` is the
fallible direction and the *only* place malformed UTF-8 is handled — it raises a
catchable error (so `pcall(string.decode, junk)` is the "try to interpret these
bytes as text" idiom). `s:encode()` works because strings already carry the
string metatable (M3); `string.decode` is a free function because byte arrays are
plain tables with no metatable.

Both are **no-ops on ASCII** (≤ U+007F): `encode` is a memcpy of bytes that are
already the UTF-8 form, and `decode` of all-ASCII input cannot fail (the bytes
*are* valid UTF-8). Work — and `decode`'s failure mode — appear only once a byte
`≥ 0x80` is involved, i.e. exactly at the U+0080 collision point above.

## How `utf8` dissolves

Bart's original question — *"why is `utf8` even a library? it should be the
default"* — is answered by the model itself: once strings are code-point-native,
most of Lua's `utf8` library has nothing left to do.

| Lua `utf8.*` | lune equivalent |
|---|---|
| `utf8.len(s)` | `#s` (cached, O(1)) |
| `utf8.codes(s)` | `s:codes()` — iterator of `(index, code-point)` |
| `utf8.codepoint(s, i [, j])` | `s:codepoint(i [, j])` / indexing |
| `utf8.char(cp…)` | `string.char(cp…)` — now builds from **code points** |
| `utf8.offset(s, n)` | *gone* — there is no byte/char-index gap to bridge |
| `utf8.charpattern` | *gone* — `.` already matches one code point (S-D) |

So lune ships **no `utf8` module**. What used to be that library is now either
core string behaviour (`#`, `sub`, `char`, `codepoint`, `codes`) or evaporated
(`offset`, `charpattern`). The inventory CSV's `utf8` rows move from
`not-started` to a disposition reflecting "absorbed into `string`/excluded as
redundant" in the S-B change (Rule Z-5, same change).

### `string.char` / `string.byte` shift meaning

- `string.char(cp…)` builds a string from **code points** (`0 .. 0x10FFFF`,
  surrogates `0xD800..0xDFFF` rejected), encoding each to UTF-8. (Was: from byte
  values.)
- The old byte-returning `string.byte` role moves to the bytes world: take
  `s:encode()` and index the resulting array. A `string.codepoint(s, i)` covers
  the "scalar value at character position i" need directly.

## Case mapping & the pinned Unicode version (determinism)

`upper`/`lower` are the only in-scope operations whose result depends on a Unicode
table (patterns keep ASCII classes in S-D; no graphemes; no normalization). The
table churns between Unicode versions, which would otherwise make `upper("ﬀ")`
non-reproducible across a toolchain bump — unacceptable for replay-forever.

The version does **not** live in the string. Per-string tagging would force
interning/`==`/hashing to learn to ignore the tag and would need a "which version
wins" rule on every `..` — complexity smeared across the hottest, most
identity-sensitive type. Instead the version lives where lune already puts
nondeterministic inputs: **the recorded session.**

- lune's determinism is session-scoped: a snapshot + effect log reproduces one
  run, and inputs (clock, RNG seed) are recorded and re-fed on replay
  (`02-determinism.md`).
- A Unicode version is exactly that shape. Record **one active version per
  session** as an effect (`unicode_version`, in the effect-log header next to the
  seed). New runs use the newest compiled-in table; a replay re-pins whatever it
  recorded. **Churn the tables freely — every old replay still reproduces
  byte-identically**, with zero per-string cost and interning/`==`/hashing
  untouched. Only one table is *live* per run (the `switch` still grows one arm
  per vendored version, so we bump rarely — see Open questions).
- Practical reassurance: Unicode case mapping is **stability-policy-protected and
  append-mostly** — assigned characters essentially never change their mapping;
  new versions add mappings for newly-assigned code points. So divergence
  requires case-mapping a character that was *unassigned* in the old table and
  *gained* a mapping in the new one. Session-versioning covers even that; in
  practice most version bumps can be skipped.
- ASCII (`< U+0080`) gets a branch-free fast path; the vendored table is consulted
  only above U+007F. Default case mapping only (no locale tailoring).

## Pattern matching (S-D) — landed

The engine (`src/stdlib/pattern.zig`) is now code-point-oriented:

- `.`, literal characters, captures, anchors, and quantifiers (`* + - ?`) step by
  **code point** (one UTF-8 sequence at a time), so `.` matches one character and
  `s:gsub(".", …)` walks characters. The subject is always valid UTF-8 (S-B
  invariant), so each advance lands on a code-point boundary and reaches `src.len`
  exactly — every `$`/end check stays valid. Greedy backtracking (`maxExpand`)
  steps back one code point at a time via a backward continuation-byte scan
  (`cur -= 1; while (src[cur] & 0xC0) == 0x80) cur -= 1`), so the matcher stays
  **allocation-free** (no scratch buffer, no allocator on `MatchState`).
- The class shorthands `%a %l %u %d %s %w %p %c %x` (and bracket sets) stay
  **ASCII**. The `singleMatch` caller guards every class/bracket test with
  `src[s] < 0x80` — **load-bearing, not an optimization**: without it a UTF-8
  lead/continuation byte (≥0x80) would wrongly satisfy a *complement* class
  (`%A`/`%D`/`%S`, `[^…]`, all `!isX(byte)` tests). Unicode property classes
  (`\p{L}`-style) are a deferred follow-up — they would add their own versioned
  property tables and a second determinism surface; out of scope until there's
  demand.
- **Boundary (character indices).** `find`/`match`/`gmatch`/`gsub` accept and
  return 1-based **character** indices at the `src/stdlib/string.zig` seam: `init`
  is a character index (`charByteOffset`), `find`'s start/end are character indices
  (`cpCount`), and position captures `()` are character indices. Captures stay
  **byte offsets** inside the engine and convert only at the seam. ASCII is
  numerically identical, so existing ASCII tests/benches are untouched.
- **Caveat (out of scope, documented).** Multibyte characters inside bracket sets
  (`[é]`, `[é-ñ]`) and multibyte `%b` delimiters stay byte/ASCII-level — they
  won't match a whole code point. `%b` and back-references are correct on
  boundary-aligned spans (byte-equal == code-point-equal there). The `%f` frontier
  is the one path that feeds a subject byte to an ASCII set *without* the
  `< 0x80` guard — deliberately: it is **zero-width** (consumes nothing, so it
  cannot split a code point) and is a byte-for-byte port of Lua 5.4's frontier. A
  multibyte character is not an ASCII letter, so every one of its bytes reads as
  `%A`/`%D`/… — the frontier therefore fires entering a multibyte char from an
  ASCII letter, consistent with the ASCII-class rule (pinned by test).
- Byte-exact matching, when wanted, is available by matching over a byte array
  view (`s:encode()`); the string-level engine is text-level.

This bounds the new Unicode determinism surface to **exactly one table** (case
mapping) for the whole effort — the matcher itself adds no recorded input.

## Lexer & source (S-B)

- Source files are UTF-8; the lexer validates string-literal byte runs and
  rejects malformed UTF-8 at compile time (a located diagnostic, not a runtime
  trap).
- `\u{XXXX}` escape encodes a code point into the string's UTF-8 (range-checked;
  surrogates rejected).
- `\xNN` / `\ddd` escapes in a string literal are legal **only for ASCII**
  (`≤ 0x7F`), where they merely spell an ASCII character; a value `≥ 0x80` is a
  **compile error** pointing at `\u{…}` (a code point) or an integer-array literal
  (a raw byte). A lone `\xFF` is not valid UTF-8 and therefore not a valid string,
  so it is rejected in text — raw bytes are written as integer arrays (see the
  bytes section). A string literal is *always* valid UTF-8 by construction.
- Identifiers stay ASCII (non-goal above).

## Determinism summary

What changes, and why each is safe:

- **String identity / `==` / hashing / table keys** — unchanged. All key on the
  UTF-8 byte buffer, which still exists and is still the thing interned/hashed.
- **Keyframe / snapshot wire** — unchanged. Strings serialize as `(byte-len,
  bytes)`; the valid-UTF-8 invariant is a property, not a stored flag; the cached
  code-point count is recomputed on load. Byte arrays serialize via the existing
  array/lane format.
- **New recorded effect: `unicode_version`** — one per session, in the effect-log
  header beside the RNG seed; re-pinned on replay. This is the entire new
  determinism input.
- **The JIT** — untouched by S-A..S-D (string ops are natives → trace barriers,
  as today). S-E (the `u8` lane) touches `nativegen.zig` load/store (zero-extend
  vs i8 sign-extend) and gets the standard review gate.

## Work sequence (landable chunks)

Each lands green behind `just test` with 8-mode `expectProgram` parity (Rule
Z-3), CSV/TODO in lockstep (Rule Z-5), and the determinism-adjacent chunks
(S-C, S-E) get the Codex + Antigravity review gate before landing.

1. **S-A — bytes world + boundary** *(additive, low risk, no review gate).*
   `string.encode`/`s:encode()`, `string.decode`. Strings still byte-indexed at
   this point; this only *adds* the byte/text conversion. Tests: round-trip
   `s == string.decode(s:encode())`; `decode` of malformed bytes is a catchable
   error; `encode` of a multi-byte string yields the right integer array.

2. **S-B — code-point-native strings** *(the breaking core).* Cached code-point
   count + O(1) `#`/`len`; `sub`/`reverse`/iteration/`string.char`/
   `string.codepoint`/`s:codes()` on code points; valid-UTF-8 invariant at
   construction; `\u{…}` escape; `\xNN`/`\ddd` → byte arrays; **delete the planned
   `utf8` module** and fold the CSV rows. Rewrite the byte-assuming string tests.
   Tests: `#"héllo" == 5`; `("héllo"):sub(2,2) == "é"`; reverse preserves
   characters; surrogate/over-range `string.char` errors; literal validation.

3. **S-C — case mapping + pinned Unicode** *(determinism gate).* Vendored
   versioned case table + ASCII fast path; `upper`/`lower` Unicode-aware; record
   `unicode_version` as a session effect; replay re-pins it. Tests: ASCII path
   unchanged; a non-ASCII case map is byte-identical across record/replay and all
   8 modes; the recorded version round-trips.

4. **S-D — patterns on code points** *(no new table — classes stay ASCII).*
   `pattern.zig` steps by UTF-8 sequence; `.`/captures/quantifiers are
   code-point; ASCII classes retained. Tests: `("héllo"):gsub(".", "x") ==
   "xxxxx"`; capture spans land on character boundaries; byte-level matching via
   `encode` still possible.

5. **S-E — the `u8` lane** *(perf follow-up, JIT review gate).* Add `u8` to the
   lattice (sibling of `i8`; widens to `{i16, i32, i64, value}`); `intLaneFor`/
   `laneForValue`/`canWidenTo`/presence/`isInt` arms; zero-extending native
   load/store in `nativegen.zig`; `encode`/`decode`/`pack` target `u8`. Tests:
   a byte array commits to `u8`; a `256` widens it to `i16`; a `-1` to `i8`/`i16`;
   8-mode determinism on a byte-array workload; native store/load round-trips.

`load`/`dofile`/`loadfile` is **independent** of this arc and can land before,
during, or after it (it touches the compiler-entry surface, not strings).

## Open questions

- ~~**Byte-string literal syntax.**~~ **Resolved (derive it):** no new
  byte-string literal. A string literal is always text (valid UTF-8); raw bytes
  are written as an ordinary **integer-array literal** (`{0x89, 0x50, …}`) or
  obtained via `s:encode()` — the array literal *is* the byte literal. `\xNN` /
  `\ddd` inside a string literal are legal only for ASCII (`≤ 0x7F`), where they
  just spell an ASCII character; a value `≥ 0x80` in `\x`/`\ddd` is a **compile
  error** that points you at `\u{…}` (for a code point) or an integer array (for a
  raw byte). This keeps "derive it" — the values/representation carry byte-ness,
  no bespoke syntax — while respecting the U+0080 type distinction.
- **`u8` lane and the `int_of_float`/store lowering.** `u8` needs zero-extension
  on load where `i8..i64` sign-extend; confirm the `nativegen.zig` store path's
  presence-bit + width-truncate shape composes with an unsigned lane without a
  new op (S-E).
- **How often to vendor a new Unicode version.** Each adds a `switch` arm and a
  table blob. Given case-mapping stability, the answer is "rarely, and only when a
  newly-assigned character's case mapping is actually wanted." Pick an initial
  pinned version (e.g. the latest at S-C time) and document the bump policy.
- ~~**`string.format` precision unit.**~~ **Resolved:** `%.3s` precision counts
  **code points** (not bytes). `%c` ("emit the character with this code") emits a
  **one-code-point string** — i.e. `string.char` of a single argument. Settle in
  S-B.
- **A per-string code-point index** for O(1) random `sub`/index. Deferred; `#` is
  O(1) via the cached count and that covers the common case. Revisit only if
  profiles show O(n) `sub` hurting.

## References

- `00-architecture.md` — Lua-shaped-not-compatible; value representation; typed
  unboxed containers.
- `02-determinism.md` — session-scoped replay; recorded inputs (clock, seed); the
  home for `unicode_version`.
- `03-gc-memory.md` — string interning & inline allocation; byte-array ownership.
- `04-snapshot-replay-schema.md` — keyframe wire (strings as `(len, bytes)`;
  array lanes).
- `05-native-codegen.md` — the lane lattice & Phase B array load/store (the `u8`
  rung in S-E).
- `src/string.zig`, `src/array.zig`, `src/stdlib/pattern.zig`, `src/lexer.zig`.
- Unicode stability policies (case mapping stability) — rationale for cheap
  version pinning.
