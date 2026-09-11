# Per-chain array lane binding — Design

Status: complete — landed with adversarial admission tests, gates and board (task #29)
Owner: Claude (campaign loop), codex review thread 01a09008-f492-7bb1-b679-7d7f9b06c6f6
Last updated: 2026-09-11

## Implementation status

### Done

- [x] **Replace the trace-global `trace_lane` cell with per-root `RootBind` + per-chain aux equality in `proveKinds`.** `guard_lane` binds a root's scalar lane; `guard_grid` + `guard_stride` jointly bind a grid shape (conflicting re-guards and scalar/grid cross-use fail closed); `aref` requires its root's dominating `guard_lane` (it may never establish the binding itself); `garow` requires BOTH grid guards; every memory op (`aload`/`astore`/`astore_append`/`gcell`/`gload`/`gstore`) requires direct aux equality with its own address op. `laneConsistent` deleted from `nativegen_layout.zig` with its unused imports.
- [x] **`fits_mask` lane bitset replaces the lane-blind `fits_ok` bool.** A `guard_fits` proof covers exactly its own lane's bit; each int-lane store requires its own lane's bit (or `konstFitsLane`). Prevents an i64 proof covering an i8 store once lanes mix, and admits one value stored at two widths under two proofs.
- [x] **Duplicate `slot_load` rejection.** Allocation keeps ONE `SlotInfo` (one prologue check) per VM slot; two refs with independent root bindings could disagree while only one is runtime-verified. The recorder dedups real inputs, so a dup is malformed by construction.
- [x] **Tests.** Mixed-lane roots (u8 index array into f64 array) admit + native/tier-1a parity across full/bounds-exit/mid-run entries; refusals for aload-vs-aref mismatch, aref-vs-guard_lane mismatch, missing guard_lane, conflicting guard_lane, duplicate slot_load, wrong-width guard_fits (+ exact-width acceptance); grid variants — scalar↔grid cross-use both directions, conflicting guard_grid elem, garow without guard_grid / without guard_stride / elem mismatch, gcell/gload aux mismatches. Gates: unit, wasm, hashgate 84×2, full board.

### Outstanding

_(nothing — the sparse residual is the nest-coverage arc, docs 22/44, not this doc)_

## Why this exists

`proveKinds` enforced ONE packed array lane per TRACE (a single `trace_lane`
cell every lane-bearing op had to match). Any loop touching two element widths
— sparse's `sum + vx[col[i]] * val[i]` (u8/int index array + f64 data arrays),
LU's int pivot array + f64 rows — was refused native admission wholesale and
ran tier-1a, which the dispatch gate then rightly starved back to tier-0:
scimark-sparse sat at 0.0% native residency with **83.3% of its iterations as
"tier-0 fallback despite a committed trace"** (15M iters, 79% of run cycles).

The restriction never carried any runtime weight: codegen already lowers
per-op (`nativegen_emit.zig` picks widths from each op's `aux`) and the
prologue emits one lane check per `guard_lane` op, each naming its own root.
The real invariant is per-root/per-chain — each access must use the width that
ITS OWN root's structural guard verified — which is exactly what the new
binding proves. Two different roots aliasing one runtime array stay safe: the
array has one live lane, so one of the two runtime lane checks fails at entry.

## Results

- Long-body mixed-lane loop (isolated repro): tier-0 0.27s → native 0.03s (~9×).
- scimark-lu 182.4 → 142.7ms (−22%, residency 40.6% → 56.8%).
- scimark-sparse fallback population 83.3% → 25.0% of iterations, residency
  0% → 53.3%, wall 586 → 573ms only — each sparse row has ~5 elements, so
  ~3 iterations/native-entry cannot amortize the entry seam (replayLedger
  ~380 cyc/walk × 3.0M walks). The remaining sparse lever is tracing the
  OUTER row loop across the inner `for_prep` (nyi_opcode abort today) — the
  Pall-shape nest coverage arc (docs 22/44), deliberately out of scope here
  (codex: "this arc should narrowly repair native admission").
- euler14-bit 64.0 → 59.1, spectral-norm 34.9 → 32.1; no board regressions
  beyond run noise.

## References

- `src/nativegen_prove.zig` — all admission rules (task #29 comments).
- `src/nativegen_arrayread_test.zig` — the adversarial admission suite.
- Doc 14 (grids), doc 32 (value lane), doc 31 (dispatch gate / fallback
  forensics), docs 22/44 (the follow-up nest-coverage domain).
