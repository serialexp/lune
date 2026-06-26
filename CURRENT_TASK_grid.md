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
2. [ ] **Phase 4b — inflation in the fused store path.** `set_index2` on a
   homogeneous-numeric nested `a` calls `inflateToGrid`; fused ops then hit grid
   cells directly. Don't-retry flag for hysteresis.
3. [ ] **Phase 4c — bare access deflates.** Bare `get_index`/`set_index` on a
   grid calls `deflateGrid` then proceeds nested. Replace the Phase 3
   `Unimplemented` stubs with deflation. Now grids are produced AND safe.
4. [ ] **Phase 5 — `expectProgram` sweep (8 modes + GC stress).** matrix
   fill/read, jagged, **row swap/sort**, `a[i]==a[i]`, row escapes (function arg
   / table store) deflate, `#a[i]`, `pairs`/`ipairs`.
5. [ ] **Phase 6 — GC under stress with grids live** (largely already satisfied).
6. [ ] **Phase 7 — determinism + keyframe** (deflate/skip grids at capture).
7. [ ] **Phase 8 — recorder fast path** (the perf win).
8. [ ] Doc 14 → Done as phases land; inventory if needed. Commit the arc.

## Notes
- Under the gate, Phase 1 `row_view` Value + Phase 3 `rowViewGet/Set/Len` become
  dormant at runtime (kept green; fused ops compute cell addresses directly).
- inflate/deflate are `gc.Heap` methods (need the heap to alloc/free row Tables).
- GC already grid-safe: grid cells are narrow leaves → `blacken` skips them.
- Collection only fires at the dispatch-loop safepoint (`Vm.collect`), never
  inside `newTable`/`link` → inflate/deflate are GC-atomic (verified gc.zig:26).
