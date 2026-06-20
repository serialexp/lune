# CURRENT TASK — S-D (pattern matching on code points + character indices, doc 06)

## Status: implemented + tested, GATE GREEN, Codex+Antigravity review DONE. Awaiting Bart's review before commit (Rule #15 — do NOT commit until approved).

## Review (Codex + Antigravity)
Both passed the consuming paths, the backward-boundary backtracking, `classEnd`
totality, and every seam char-index conversion as correct. One split verdict:
Codex flagged the `%f` frontier (the one path feeding a subject byte to an ASCII
set *without* the `< 0x80` guard); Antigravity argued it is correct. **Resolution:
not a bug** — `%f` is zero-width (consumes nothing → cannot split a code point) and
is a byte-for-byte port of Lua 5.4's frontier; a multibyte char reads as non-ASCII
on every byte, so the frontier behavior is self-consistent with the documented
"classes stay ASCII" rule. Made the decision **explicit**: added the
`S-D: %f frontier classifies a multibyte char by its (non-ASCII) bytes` unit test
and a doc-06 caveat note. Gate still green.

(S-A + S-B + the host-input UTF-8 boundary landed as c8fb684; S-C — Unicode case
mapping + pinned `unicode_version` — committed as 433e334.)

## What S-D does

The pattern engine and the `find`/`match`/`gmatch`/`gsub` boundary become
code-point-native, closing the last char-vs-byte gap in the string surface (doc 06
§51-52, §66).

**Part 1 — engine steps the subject by code point (`src/stdlib/pattern.zig`).**
- `seqLen(s)` (new, `pub`): UTF-8 width of the code point at byte `s`, clamped to
  `src.len`. Every subject-advance uses it, never `+1`.
- `singleMatch(s, p, ep)` takes a byte **offset** (not a pre-read byte). Arms: `.`
  → any one code point; `%`-class → `src[s] < 0x80 and matchClass`; `[` → `src[s]
  < 0x80 and matchBracket`; literal → `litEq`. **The `src[s] < 0x80` guard is
  load-bearing** — without it a high byte satisfies the complement classes
  (`%A`/`%D`/`[^…]`).
- `litEq`/`matchWidth` (new): byte-equal literal compare (== code-point compare on
  canonical UTF-8); width is `seqLen` for `.`/literal, `1` for class/bracket.
- `classEnd` groups a multibyte literal into ONE item (so `é*` binds the whole
  char), clamped + `catch 1` to stay total on a truncated pattern tail.
- `maxExpand` (greedy) backtracks **one code point at a time** via a backward
  continuation-byte scan (`cur -= 1; while (src[cur] & 0xC0)==0x80`), so
  `MatchState` stays **allocation-free** (no scratch buffer). `minExpand`/`match`
  advance by `matchWidth`; `firstMatch` test helper by `seqLen`.
- Unchanged (confirmed correct): `matchClass`, `matchBracket`, `matchBalance`
  (`%b`, ASCII delims), `matchCapture` (back-ref), `%f` frontier, capture helpers,
  `Capture` (stays byte offsets).

**Part 2 — character indices at the seam (`src/stdlib/string.zig`).**
- `resolveInit(init_raw, s)` now treats `init` as a 1-based **character** index →
  byte offset (`posRelat` on `cpCount`, then `charByteOffset`).
- `byteToChar(s, off)` (new): byte offset on a boundary → 1-based char index.
- `findCore` returns char start = `byteToChar(s, sp)`, end = `cpCount(s[0..e])`
  (both plain and pattern branches); outer scan `sp += seqLen`.
- `captureValue` position captures (`cap_position`) → `byteToChar(src, cap.init)`.
- `matchCore` outer scan `sp += seqLen`.
- `gmatchAuxCore` scan advances by `@max(seqLen, 1)`; empty-match bump steps a
  whole code point (`@max(…,1)` guarantees end-of-string termination).
- `gsubCore` empty-match / non-match advance copies the **whole code point**
  (`appendSlice(s[src..src+seqLen])`) so it never splices a partial sequence.
  Captures stay byte offsets inside the engine; convert only at the seam.

## Out of scope (documented, doc-consistent)
- Multibyte chars inside bracket sets (`[é]`, `[é-ñ]`) and multibyte `%b`
  delimiters stay byte/ASCII-level. Unicode property classes (`\p{L}`),
  normalization, graphemes — deferred.

## Tests
- `src/stdlib/pattern.zig` — 7 multibyte unit tests added in Part 1 (`.` over one
  code point, `(.)` capture width, greedy/lazy over mixed ASCII+multibyte, literal
  multibyte under a quantifier, ASCII classes stop at a high byte, anchors/`%b`/
  back-ref with multibyte, truncated-tail totality).
- `src/stdlib/string.zig` — `S-D: …CHARACTER indices (multibyte)`: find char
  positions, find+sub compose, `(.)`/`()` char-indexed captures, init as char
  index, gmatch char-aligned, `gsub(".", "x")` over "héllo" → "xxxxx".
- `src/interp.zig` — `S-D: pattern matching over multibyte text is byte-identical
  across all modes` (8-mode `expectProgram`; pattern ops are trace barriers, so
  parity is inherited).

## Bench
`just bench --filter str`: all str benches `cross: ok` (lune 8-mode consistency
intact); pattern benches (find_match 36ms, gmatch 64ms, gsub 67ms) unregressed.
`str_manip` shows `luajit=ERR` — **pre-existing S-B divergence** (the bench uses
`string.codepoint`, lune's rename of `byte`, which LuaJIT lacks), unrelated to S-D.

## Docs (lockstep, Rule Z-5)
doc-06 S-D `[x]` (landed note + bracket/`%b` ASCII caveat) + "Pattern matching
(S-D) — landed" section; CSV find/match/gmatch/gsub rows note character indices;
TODO S-D-LANDED block + "Next in the arc" → S-E.

## Gate
`just test` = 0.

## Next
Codex + Antigravity review (esp. the ASCII-class guard, the backward-boundary
backtracking scan, and the boundary char-index conversion), address findings, then
Bart's review and commit approval (conventional-commits, trailer
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`). Then S-E
(`u8` array lane).
