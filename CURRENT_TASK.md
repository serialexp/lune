# CURRENT TASK — S-E (the `u8` array lane, design doc 06 final chunk)

## Status: implemented + tested, GATE GREEN, bench clean. Awaiting Codex+Antigravity review, then Bart's review before commit (Rule #15 — do NOT commit until approved).

This is the LAST chunk of design doc 06 (Unicode-native strings). S-A..S-D already
landed (S-D as ad5392a). S-E is a pure storage/perf optimization — no new language
surface.

## What S-E does

Byte arrays (integers in `[0,255]`) now pack at **1 byte/slot** instead of `i16`'s
two (a byte ≥ 128 overflows signed `i8`'s 127 ceiling, so today they land on i16).
A `u8` rung is added to the monotonic lane lattice.

**Part 1 — lattice (`src/array.zig`).**
- `Lane` gains a `u8` variant **appended at the end** (ordinal 7) so existing
  ordinals stay put (trace IR embeds the lane ordinal in `guard_lane.aux`). Lattice
  order is explicit in `canWidenTo`, independent of ordinal.
- `u8` is a **sibling** of `i8`, not below it. New `intLaneForRange(lo,hi)` returns
  `.u8` when `[lo,hi] ⊆ [0,255]`, else `intLaneFor` (signed). `laneForValue` and
  `optimalLane`'s all-int arm route through it.
- `widenFor`'s `.u8` arm widens to the smallest *signed* lane covering the
  **combined** range `[min(0,v), max(255,v)]` — always `≥ i16`, never `i8`, never
  back to `u8`, so existing high bytes re-encode exactly.
- `canWidenTo(.u8,·) = {i16,i32,i64,value}`; nothing widens *to* `u8`.
- `decode` zero-extends (`Value.int(@as(i64, byte))`); `encode` `@intCast`s;
  `laneFits` checks `[0,255]`; `dataBytes`→`cap`; `usesPresenceBitmap`/`isInt`
  include `u8`.

**Part 2 — native codegen (`src/nativegen.zig`; `src/x64.zig` unchanged).**
- `U8_LANE` const; `laneKind(U8_LANE)→.int`; `intLaneWidth(U8_LANE)→1`.
- `aload` `u8` branch: zero-extend via `loadRegMemSib(.rax, …, 1, false, 0)`
  (`movzx`, no `sub`) — the only divergence from the signed lanes' `movsx`. Uses the
  **existing** encoder, no new x64 op.
- `guard_fits` `u8` branch: range-check `[0,255]` derived from the *lane* (not the
  width — width-1 is now ambiguous with `i8`).
- Store path (`astore`/`astore_append`: width-truncate + presence `bts`) is
  signedness-agnostic → unchanged.

**Part 3 — recorder (`src/trace.zig`).** No code change: the append + in-bounds
`astore` gates key on `lane == .boolean or lane.isInt()` / `array.fits(v)`, both of
which now include `u8` automatically.

## Determinism
Lanes are internal and **never serialised** (the keyframe wire stores logical
Values). The native zero-extend `aload` matches tier-0 `decode` byte-for-byte. So
8-mode parity is inherited. Touches `nativegen.zig` → review gate applies.

## Tests
- `src/array.zig` — 3 new u8 tests (byte array commits u8 + 1 B/slot + zero-extend
  decode; `256` widens to i16; `-1` widens to i16). Existing lane tests updated:
  small non-negative int arrays now commit `u8` (was `i8`) — `{1,2,3}`, `@mod(i,100)`
  dense run, etc.; the `canWidenTo` lattice test gains a `u8` row; the i8-specific
  guard_fits nativegen test now fills with a **negative** to stay on i8.
- `src/nativegen.zig` — 3 new u8 tests (zero-extend read scan proving `movzx` not
  `movsx`; in-range `t[k]=C` write; `guard_fits` side-exit at 256 and −1).
- `src/interp.zig` — 2 new 8-mode `expectProgram` tests (byte-array workload;
  `u8→i16` mid-run widen); the widen-eviction native test updated to track the `u8`
  trace eviction (crossover now at i=256, not 128).

## Bench
`just bench`: every `cross: ok` (8-mode consistency intact); no regression on the
int/bool array benches (repack, sieve_int, tbl_ops, scalar, pi_leibniz). `str_manip
ok/ERR` is the **pre-existing** S-B LuaJIT divergence (uses `string.codepoint`),
unrelated to S-E.

## Docs (lockstep, Rule Z-5)
doc-06 S-E checklist `[x]` (landed note) + the `u8`/store-lowering open question
**resolved** (zero-extend via existing `movzx`, no new op) + the JIT determinism
summary updated; TODO `S-E LANDED` block + header `S-A..S-E ALL LANDED`. CSV
unchanged — S-E adds/renames no stdlib function (the lane is internal storage, not a
user-facing semantic; the byte array is unchanged to the program).

## Gate
`just test` = 0, `just check-version` = 0.

## Next
Codex + Antigravity review (esp. `widenFor`'s combined-range superset correctness +
`canWidenTo`, and the native zero-extend `aload` + `[0,255]` `guard_fits`), address
findings, then Bart's review and commit approval (conventional-commits, trailer
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`). This
completes design doc 06.
