# CURRENT TASK — doc 14 grid flattening (re-planned: gate behind fused ops)

(NB: `CURRENT_TASK.md` holds a *different* agent's uncommitted sqrt-JIT notes —
left untouched. This file tracks the grid-flattening arc only.)

Phase 3 (row forwarding) landed: commit `ba031d5`. Then, building 4+5, a
soundness counterexample (in-place row swap) forced an architecture decision.

## Decisions (Bart, 2026-06-26)
- **Inflation rule:** STRICT homogeneous numeric (every row a heap table, dense
  numeric array, no hash/metatable; all cells unify to one fixed-width lane;
  jagged allowed = bounding box). Implemented in `Heap.inflateToGrid`.
- **Escape/identity:** **GATE GRIDS BEHIND FUSED INDEXING.** Don't produce a
  runtime grid until the compiler emits fused `get_index2`/`set_index2` for
  chained `a[i][j]`. A bare `get_index`/`set_index` on a grid deflates (escape).
  So a `row_view` Value is never materialised at runtime → the swap/identity
  hazard cannot arise. (Doc 14 §Escape detection has the full rationale + the
  swap counterexample.)

## The swap counterexample (why we gated)
`local tmp=a[i]; a[i]=a[j]; a[j]=tmp` — `tmp` is a bare row_view parked in a
register; `a[i]=a[j]` deflates the grid and reassigns slot i; resolving the stale
`tmp` through the parent slot reads the reassigned value. Both copy-out-on-escape
and persistent-alias fail this. Gating (no bare row_view ever) avoids it.

## Built so far (uncommitted, green)
- `src/array.zig`: `intLaneForRange` made `pub` (grid unifies cell lane over it).
- `src/gc.zig`: `Heap.inflateToGrid(parent) bool` (strict scan + build grid +
  swap, OOM/precondition ⇒ false) and `Heap.deflateGrid(parent) !void` (rebuild
  heap row Tables, swap back). 3 unit tests (round-trip, all-float, blockers).
- Phase 3's `Unimplemented` stubs in `interp.zig` (outer grid store, inner
  overflow) still stand — fine, no runtime grid exists yet.

## New build order (uncommitted until the arc is safe+complete; keep `just test` green)
1. [x] **Phase 4a — fused opcodes as a NESTED-TABLE optimisation (no grids).**
   DONE (green, committed). `get_index2`/`set_index2` in bytecode; compiler
   fuses chained `a[i][j]` / `a[i][j]=v`; interp handlers do the two-step access
   via indexGet/indexSet. 3 expectProgram tests (chained get/set, inner
   __index/__newindex dispatch, eval order). Recorder aborts on them until P8.
2. [x] **Phase 4b — inflation in the fused store path.** DONE (green). `fusedStore`
   inflates a homogeneous-numeric nested `a` on the first `a[i][j]=v`; cells then
   hit the grid directly. **Reshape-on-overflow** (Bart): column past `stride` →
   `gridGrowStride` (geometric); int past the cell lane → `gridWidenElem`. Only a
   type change deflates. `Table.no_grid` hysteresis bounds the scan + stops thrash.
3. [x] **Phase 4c — bare access deflates.** DONE (green). Bare `indexGet`/`indexSet`
   on a grid deflates first; Phase 3 `Unimplemented` stubs replaced. stdlib
   `tableArg` (table/base/basic/string) + `iterableArg` deflate on entry, so
   `table.*`, `raw*`, `setmetatable`, `next`/`pairs`/`ipairs` see real rows.
4. [x] **Phase 5 — `expectProgram` sweep (10 modes + GC stress).** DONE (green). 8
   grid e2e tests: fill/read+compute, stride-grow, lane-widen, type-change deflate,
   row escape+mutate+ipairs+`a[1]==a[1]`, `table.insert`, **in-place row swap**,
   `table.sort` by key. Plus 2 gate + 1 inflation/reshape direct unit tests.
5. [x] **Phase 6 — GC under stress with grids live.** DONE — the Phase 5 e2e tests
   run with `gc_stress=true` (collect at every safepoint) while grids inflate/
   deflate mid-program; green ⇒ no wrong-collect, no row-table leak on deflate.
6. [ ] **Phase 7 — determinism + keyframe** (deflate/skip grids at capture).
7. [ ] **Phase 8 — recorder fast path** (the perf win; grids currently abort
   recording on `get_index2`/`set_index2` ⇒ correct but tier-0).
8. [x] Doc 14 updated (4b/4c/5/6 → Done, status header). No inventory change (no
   stdlib function added/renamed). Next: commit the arc.

## Notes
- Under the gate, Phase 1 `row_view` Value + Phase 3 `rowViewGet/Set/Len` become
  dormant at runtime (kept green; fused ops compute cell addresses directly).
- inflate/deflate are `gc.Heap` methods (need the heap to alloc/free row Tables).
- GC already grid-safe: grid cells are narrow leaves → `blacken` skips them.
- Collection only fires at the dispatch-loop safepoint (`Vm.collect`), never
  inside `newTable`/`link` → inflate/deflate are GC-atomic (verified gc.zig:26).
