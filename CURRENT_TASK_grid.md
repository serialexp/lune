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
- Output byte-identical across mahina tier-0, `--jit-native`, and LuaJIT (checksum
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

## Phase 8 — CONCRETE IR DESIGN (decided 2026-06-27; int lanes, 2-level)

After reading all four tiers, the encoding is fixed. The hard constraint:
`IrInstr` carries only `.a`/`.b`/`.aux` (16 B), but a grid cell needs (table, row,
col) = 3 refs. Resolved with a **2-op address chain** so nothing grows past two
operands and `tropt.zig` needs only `kindOf` additions (the proven
liveness/LICM/compaction switches dispatch on `kindOf` and already handle the
`.aref`/`.aload`/`.astore`/`.guard` kinds generically):

- `garow` — `.a=table, .b=row, .aux=grid_elem_ord` → pairs (table,row); tier-1b
  materialises `row0 = row-1`. **kind `.aref`.**
- `gcell` — `.a=garow, .b=col, .aux=grid_elem_ord` → the full cell token; tier-1b
  materialises `flat = row0*stride + (col-1)` (walks `gcell.a→garow.a` for the
  table, loads `stride` live). **kind `.aref`.**
- `gload` — `.a=gcell, .aux=grid_elem_ord, .ty=obs` → tier-1a `array.gridGet(row-1,
  col-1)`; tier-1b `data + flat*width` load. **kind `.aload`.**
- `gstore` — `.a=gcell, .b=value, .aux=grid_elem_ord` → tier-1a `array.gridSet`;
  tier-1b store + presence `bts`. **kind `.astore`.**
- `guard_grid` — `.a=table, .aux=grid_elem_ord` → `lane==.grid && grid_elem==aux`.
  The **deflation + elem-widen** guard (a deflate flips lane; `gridWidenElem`
  changes grid_elem). **kind `.guard`.**
- `guard_stride` — `.a=table, .aux=stride` → `stride==aux`. Pins stride so the
  flat math is valid and a `gridGrowStride` (which **reallocates** data/present)
  side-exits before any hoisted pointer goes stale. **kind `.guard`.**
- `guard_gcol` — `.a=gcell` → `1 <= col <= stride` (reads `col` from `gcell.b`,
  table via `gcell.a→garow.a`). The column-dimension bound. **kind `.guard`.**
- `guard_gpresent` — `.a=gcell` → cell present (`!gridGet(...).isNil()` / `bt`).
  **kind `.guard`.** (Can't reuse `guard_present`: its tier-1a body calls the
  scalar `tbl.getInt`, which asserts `lane != .grid`.)

**Reused unchanged:** `guard_bounds` on `garow` gives the **row** bound (its
tier-1a body checks `1<=index<=len`, and a grid's `len==rows`); `guard_fits` on
the store value (checks the value fits `grid_elem`). Why dedicated `gload`/`gstore`/
`guard_gpresent` instead of reusing `aload`/`astore`/`guard_present`: those three
re-derive through the **scalar** `tbl.getInt(idx)` / `setInLane(idx,v)` API, which
asserts `lane != .grid` — the gate's whole point. So the grid needs its own
cell-addressed load/store/present that call `array.gridGet/gridSet` (tier-1a) and
flat addressing (tier-1b).

Recorded sequence for a read `A[i][j]` (`get_index2 dst=a tab=b row=c col=aux`):
```
rtab = refOf(tab); guard_grid(rtab, ge); guard_stride(rtab, stride)
ri = refOf(row); guardInt(ri);  rj = refOf(col); guardInt(rj)
garow = aref-chain(rtab, ri, ge); guard_bounds(garow)      // row in [1,rows]
gcell = gcell(garow, rj, ge); guard_gcol(gcell)            // col in [1,stride]
guard_gpresent(gcell)
gload(gcell, ge) → setReg(dst)
```
Store `C[i][j]=v` mirrors it with `guard_fits(rval, ge)` + `gstore` (and the same
C1 deopt-replay rule as `astore`: abort if a prior grid/array load exists, or sink
— Phase 8a keeps it simple and **aborts** the store-after-load case, like the
single-store original; matmul's hot trace is the inner k-loop which only *reads*
A and B, so this costs nothing). Record only when the observed container is
already a grid with an **int** `grid_elem`; a would-grow (`col>stride`) or
would-widen (`!fits`) store **aborts** (tier-0 reshapes; the guards then side-exit
on later iterations). f64 grid_elem → abort (int lanes first).

**Soundness of the guard set:** `guard_grid` catches deflate + elem-widen;
`guard_stride` catches stride-grow (the realloc); `guard_bounds(garow)` + `guard_gcol`
together prove `flat ∈ [0,rows*stride)` AND the right cell (per-dimension, not just
`flat<cells` which would alias across rows); `guard_gpresent` catches holes;
`guard_fits` catches lane-widen on stores. Any miss → side-exit to tier-0.

**Staging (each independently `just test`-green):**
- **Stage A — record + tier-1a oracle only; native BAILS.** Add the 8 ops
  (enum/kindOf/guardKeyAux/guardConstPasses), tier-1a exec, recorder cases,
  `assertWellFormed`, traceser ordinal test. `proveKinds` returns `false` on any
  grid op → grid traces run on the tier-1a oracle. Since the oracle is ~tier-0
  speed, the yield gate may retire them — net ≈ tier-0, no regression, but the
  record/oracle path is exercised across 8/10 modes for correctness.
- **Stage B — native lowering (the win).** `proveKinds`/`lower`/`isTransient`/
  `operandReads`/home-reservation for the 8 ops: `garow`→`row-1`, `gcell`→
  `row0*stride+(col-1)` (imul + load stride), `gload`/`gstore` flat addressing at
  `grid_elem` width + presence `bt`/`bts`. Re-bench `grid_matmul` vs baseline
  (t0=304ms, jit=318ms, lj=7.5ms).

## Notes
- Under the gate, Phase 1 `row_view` Value + Phase 3 `rowViewGet/Set/Len` become
  dormant at runtime (kept green; fused ops compute cell addresses directly).
- inflate/deflate are `gc.Heap` methods (need the heap to alloc/free row Tables).
- GC already grid-safe: grid cells are narrow leaves → `blacken` skips them.
- Collection only fires at the dispatch-loop safepoint (`Vm.collect`), never
  inside `newTable`/`link` → inflate/deflate are GC-atomic (verified gc.zig:26).

## Stage A — LANDED (2026-06-27, `just test` green)

The 8 ops + recorder + tier-1a oracle are in and committed:
- `src/trace.zig`: 8 `IrOp`s appended after `sar` (ordinals 48–55);
  `assertWellFormed`; `recGridGet`/`recGridSet` (emit the address chain +
  guards; abort on non-grid / f64 grid / grow / widen / hole; Stage-A C1 = abort
  store after any heap load); `traceHasHeapLoad` now pools `gload`.
- `src/tropt.zig`: `kindOf` (garow/gcell→aref, gload→aload, gstore→astore, 4
  guards→guard); `guardKeyAux` includes `guard_grid`(elem)/`guard_stride`(stride).
- `src/irinterp.zig`: tier-1a exec for all 8 via `array.gridGet`/`gridSet` +
  chain-walk guards (byte-identical to tier-0).
- `src/troptdiag.zig`: dead-carry use-counting switches extended.
- `src/traceser.zig`: ordinal test → 56 ops. `viz/src/enums.ts`: ordinals 48–55.
- `nativegen.zig`: UNCHANGED — `proveKinds`'s `else => return false` already bails
  on the grid ops, so grid traces run on the tier-1a oracle (`--dump-native`:
  "unsupported — runs on the tier-1a interpreter").

Verified: `grid_matmul` records 4 traces (the recorded IR shows the exact
load/store chains), `--dump-aborts` shows NO `get_index2`/`set_index2` aborts
(only the bare scalar init loop's `set_index`/`for_prep`), and output is
byte-identical across tier-0 / `--trace` / `--trace-no-opt` /
`--trace-record-only` / `--jit-native`.

## Stage B — LANDED (2026-06-27, `just test` green)
`nativegen` now lowers all 8 grid ops to native x64. Model (Bart's pick,
"Reuse .aref + fold stride const"):
- **Kinds (`proveKinds` Pass B):** `garow`/`gcell` → `.aref` (the existing
  addressing-token kind, so they compose with `guard_bounds`/home-reservation and
  can't be flushed); `gload` → `.int`; `gstore`/`guard_gcol`/`guard_gpresent` →
  `.none`; `guard_grid`/`guard_stride` → `.none` (prologue-only). New `gcol_ok[]`
  array mirrors `bounds_ok[]`: a memory op requires `bounds_ok[garow]` (row, set at
  `gcell`) **and** `gcol_ok[gcell]` (column). Pass A marks `guard_grid` as a table
  guard (→ slot becomes `.ptr`). Int lanes only (`laneKind==.int`); f64/bool bail.
- **Slot pinning (`analyze`):** a `.ptr` slot with a `garow` on it gets
  `s.lane=GRID_LANE`, `s.grid_elem`, `s.grid_stride` from its `guard_grid`/
  `guard_stride`; bails if it also carries a scalar lane (a table is grid XOR
  array). Home-reservation walks the **two-hop** `gcell→garow→table` chain for the
  data/present bases (`gload`→data, `gstore`→data+present, `guard_gpresent`→
  present); `guard_bounds(garow)`→len rides the existing one-hop arm.
- **Codegen (`lower`):** `garow`→`row-1` (like aref idx0); `gcell`→`movabs
  rcx,stride; imul rax,rcx; add col; dec` (stride folded as imm32 from
  `s.grid_stride`); `gload`→SIB `[data+flat*w]` sign/zero-extend; `gstore`→
  width-truncating store + `bts [present],flat`; `guard_gcol`→`[1,stride]` range
  bracket; `guard_gpresent`→`bt [present],flat`. `guard_grid`/`guard_stride` are
  prologue checks (`lane==.grid ∧ grid_elem ∧ stride`), no body code.
- **Recorder tweak:** `guard_gcol` now carries the column ref in `.b` (was `.a`
  only) so native liveness keeps it for the range-compare — touched
  `assertWellFormed`, `operandReads`, `troptdiag`, `viz/enums.ts`.
- **Result:** `grid_matmul` **jit 318 ms → 36.2 ms** (8.8×; lj gap 39× → 4.5×),
  byte-identical across all 8 modes + LuaJIT, serialisation round-trip intact,
  `--dump-native` now compiles the two hot grid traces (init loops still tier-0).
  Two of four traces compile (#2 hot k-loop, #3 C-store loop); #0/#1 are the bare
  scalar init loops (array growth → no trace), unchanged.
- **Doc 14** status → complete (Phase 8 Stage B bullet → Done). No stdlib
  inventory change.

## Stage C — LANDED (2026-06-27, `just test` green)
f64 grid cells now lower to native, reusing the scalar-array f64 (XMM) machinery:
- **Recorder (`trace.zig`):** `recGridGet`/`recGridSet` drop the `grid_elem.isInt()`
  abort → now `isInt() or .f64`. The f64 `gstore` value must be a float
  (`laneFits(.f64, v) == v.isFloat()`); an int-into-f64 store still aborts to tier-0
  (sound). `gload.ty` is `obsTypeOf(loaded)` = `.float` for an f64 cell.
- **`nativegen.proveKinds`:** `guard_grid`/`garow`/`gcell` accept `laneKind == .float`
  (was int-only); `gload` takes `kinds[i] = lk` (f64 → `.float`, an XMM home);
  `gstore` switches on the lane — int requires a fits_ok int value, f64 requires a
  proven `.float` (full-width `movsd`, no fits_ok, mirroring the f64 `astore`).
- **`nativegen.lower`:** `gload` f64 → `lea rax,[data+flat*8]; movsd xmm,[rax]`;
  `gstore` f64 → stage value in XMM_SCRATCH0, `lea`, `movsd [rax],xmm`, then the
  lane-agnostic presence `bts`. Slot pinning / home-reservation / `isTransient` /
  `operandReads` were already lane-agnostic — no change. The prologue grid_elem/stride
  checks already use the recorded ordinal, so f64 works unchanged.
- **tier-1a (`irinterp.zig`):** already executed f64 grids via the lane-agnostic
  `gridGet`/`gridSet` + `laneFits`; only stale "int grid" comments updated.
- **Result (`bench/grid_matmul_f64.lua`, new):** **jit 338 ms → 40 ms** (8.4×; LuaJIT
  gap 42× → 5.0×), `cross=ok` + `luajit=ok` (byte-identical across all 8 modes + LJ).
  `--dump-native`: hot k-loop is two `movsd` cell loads + `mulsd`/`addsd` in XMM
  behind the folded-stride `imul` + `bt` presence checks; C-store trace `movsd`s the
  cell + `bts`. Init loops stay tier-0 (array growth → no trace), as before.

Future cut (not this phase): store-after-load sinking for grids (Stage A/B/C all
abort the RMW-after-load case — matmul's hot trace is read-only so it costs nothing);
bool grid cells (no grid ever forms with a bool element lane today).
