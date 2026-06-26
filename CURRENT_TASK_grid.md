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
6. [x] **Phase 7 — determinism + keyframe.** DONE (green). Grid is never on the
   wire: `keyframeser.encodeSnapshot` calls `Heap.deflateAllGrids` up front;
   `.row_view => unreachable` stays (gate guarantees no bare view escapes).
   **Cross-resume byte-identity** solved with **deterministic reserved-space row
   ids** (Bart's call): `deflateAllGrids` enumerates grids in canonical
   (parent-id-sorted) order, stamps each rebuilt row from `gc.reserved_grid_id_base`
   via `linkRestored` (pure fn of logical state, never bumps the counter); restore
   skips reserved ids when rebuilding `next_obj_id`. Proven by a grid program in the
   f2c resume corpus (byte-identical final snapshot through a live-grid mid-cut) +
   a 3-case single-VM round-trip test; all run across 10 modes incl. gc_stress.
7. [ ] **Phase 8 — recorder fast path** (the perf win; grids currently abort
   recording on `get_index2`/`set_index2` ⇒ correct but tier-0). NOT STARTED —
   scope below. **Profile FIRST (CLAUDE.md): need a grid-forming benchmark.**
8. [x] Doc 14 updated (4b/4c/5/6/7 → Done, status header → "Phases 0–7"). No
   inventory change (no stdlib function added/renamed). Phase 7 committed `9b39918`.

## Phase 8 scope (recorder fast path) — STEP 0 DONE (baseline), codegen next

Bart's calls (2026-06-26): **microbench + baseline first**, **int lanes first**.

**Step 0 — DONE.** Authored `bench/grid_matmul.lua` (int N×N dense matmul; three
matrices that inflate to grids and are read/written via fused `get_index2`/
`set_index2`). Verified:
- Grids genuinely form: a temp probe in `inflateToGrid` showed exactly 3 inflations
  (A, B, C), confirming the fused-store inflation path fires.
- `--dump-aborts` confirms the hot loops abort on `get_index2`/`set_index2`
  (`nyi_opcode`) — the exact opcodes Phase 8 must record.
- Output byte-identical across lune tier-0, `--jit-native`, and LuaJIT (checksum
  19602000000 at N=200).
- **Baseline (`just bench --filter grid_matmul`, N=200, ReleaseFast, 5 reps):**
  `t0 = 304 ms`, `jit = 318 ms`, `luajit = 7.5 ms` → **~41× slower than LuaJIT,
  and the JIT currently gives NO benefit** (4% *slower* than tier-0: pure
  recording overhead with the access aborting). This is the number Phase 8 moves.

**Background (rejected real benches):** array3d uses a *manual* flat `image[pos]`
1-D array (no nested `a[i][j]`); nbody uses hash-field structs (`b.x`). Genuine
nested-numeric `a[i][j]` appears only in scimark (LU `a[jp][j]`, float — would
bail on the f64 cell lane) and LuaJIT meteor. A focused int microbench is the
clean yardstick; revisit scimark once the f64 grid lane lands in a later phase.

**Codegen surface (multi-tier — this is the big one):**
- `src/trace.zig` recorder: add `.get_index2`/`.set_index2` cases (today → `else
  => abort(.nyi_opcode)`). Mirror `recArrayGet`/`recArraySet` (lines 1840/1903)
  but emit grid-relative addressing: `guard_grid(tab)` + bounds guards on i and j
  + an `aref`-analogue computing `base + (i*stride + j)` at the `grid_elem` lane +
  `aload`/`astore`. Side-exit to tier-0 when the grid has deflated.
- New IR ops (`src/trace.zig` `IrOp`): `guard_grid` (lane==.grid + grid_elem
  matches recorded), a grid `aref` variant (carries stride; 2-D index), reusing
  `aload`/`astore` at `grid_elem`. Decide: reuse `aref` with an `aux`-encoded
  grid flag, or a distinct `garef`.
- `src/tropt.zig` `kindOf`: classify the new ops.
- `src/irinterp.zig` (tier-1a): execute the grid ops via `array.gridGet/gridSet`.
- `src/nativegen.zig` (tier-1b): lower grid `aref` to `base + (i*stride+j)*width`
  address arith + lane-width load/store + presence `bt`/`bts`. `ArrayPart.Layout`
  already freezes the field offsets (lane/grid_elem/len/cap/data/present/stride/
  row_len) for exactly this.
- Guard-invalidation: a grid that *widens* `grid_elem` or *grows* `stride` mid-
  trace must invalidate like `guard_lane`'s widen check (trace.zig:1029). The
  `guard_grid` must pin both `grid_elem` AND `stride` (a stride grow re-lays the
  flat buffer, so a recorded `i*stride+j` would be wrong) → side-exit on either.

**Open design choices for Bart (Rule #17 — options, not a pick):**
- (1) f64 grids in the recorder now, or int-lanes-first (f64 needs XMM load/store
  the array path doesn't yet emit — `recArraySet` already defers `.f64`).
- (2) Single fused level (`a[i][j]`) first, or full n-level (`a[i][j][k]`) — the
  bytecode only fuses 2-level today (`get_index2`), so 2-level is the natural cut.
- (3) Whether to author a dedicated grid matmul microbench vs. driving scimark.

## Notes
- Under the gate, Phase 1 `row_view` Value + Phase 3 `rowViewGet/Set/Len` become
  dormant at runtime (kept green; fused ops compute cell addresses directly).
- inflate/deflate are `gc.Heap` methods (need the heap to alloc/free row Tables).
- GC already grid-safe: grid cells are narrow leaves → `blacken` skips them.
- Collection only fires at the dispatch-loop safepoint (`Vm.collect`), never
  inside `newTable`/`link` → inflate/deflate are GC-atomic (verified gc.zig:26).
