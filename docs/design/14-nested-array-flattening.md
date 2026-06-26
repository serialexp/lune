# Nested Numeric Array Flattening — Design

Status: partial — **building D.** Phases 0–3 landed on `master` (decision gate;
`RowView` fat value; grid representation in `ArrayPart`; row forwarding through
the interpreter). Architecture pivoted post-review to **transient fat-value rows
with copy-out on escape** — then pivoted *again* (2026-06-26, Bart) to **gate
grids behind fused indexing**: see §Escape detection — the gate decision below.
The `inflateToGrid`/`deflateGrid` primitives landed (uncommitted) on `gc.Heap`.
Determinism/replay is the one principled gate and is satisfiable (see
§Determinism gate). Build size is explicitly *not* a blocker (see §Decision).
**Re-ordered phasing:** fused multi-level indexing (was Phase 8) now precedes
live grids — grids are never enabled until tier-0 only touches them through a
fused op, so no bare `row_view` ever escapes to a register. Next: fused
`get_index2`/`set_index2` opcodes (compiler + interp), then inflation wired into
the fused store path, then the recorder fast path.
Owner: Bart
Last updated: 2026-06-26

## Implementation status

Tracking the gap between this design and what's on `master`. Tick items as they
land; move whole sections to Done once everything inside is checked.

### Done

- [x] **Phase 0 — Decision gate.** Doc landed; Codex + Antigravity feasibility
  sign-off obtained. **Decided: BUILD D**, on the **transient fat-value**
  architecture (§Decision), not the heap-`RowView` first cut. Both reviewers
  sized it at 2–6 months and recommended the `.table` lane first — but that
  sizing prices *human* lifetime, the input that made Pall's cdata line rational;
  under AI-assisted coding a failed attempt costs token budget, not months, so
  build-size is not a gate. The only principled blockers are **unsoundness**
  (reviewers agreed it's soundable) and **determinism/replay** (satisfiable —
  §Determinism gate). The reviews surfaced the GC-pinning / identity-cache
  failure modes; the fat-value fix came straight out of them.
- [x] **Phase 1 — `RowView` fat value + structural identity.** `row_view`
  `Value` tag (parent `*GcHeader` in low 48 bits + 16-bit row in high 16);
  `eql`/identity by `(parent.id, row)`; `typeName` → "table"; truthy. Threaded
  through every exhaustive `Tag` switch (serializers, JIT encoders, renderer);
  `gc.markValue` marks the parent so a register-live row handle survives a
  collection (landed early — the GC arm belongs with the value). Wire ordinal
  appended at 5; pinned-contract test + `viz/src/enums.ts` mirror in lockstep.
  Four unit tests. Commit `c55d109`. (Grids not yet enabled, so no `row_view` is
  produced at runtime — this is the value-level surface only.)
- [x] **Phase 2 — Grid representation in the array part.** Chose **2a**: a
  `.grid` meta-lane on `ArrayPart` (Bart's call — nothing external depends on the
  `Layout` "contract," so touching it costs nothing). `data` is a flat row-major
  `[cap*stride]` buffer at a `grid_elem` sub-lane (`i8`/`u8`/`i16`/`i32`/`i64`/
  `f64`), `present` a per-cell bitmap, `row_len[r]` the per-row high-water length.
  `grid_elem` rides in `lane`'s offset-2 padding so `len`/`cap`/`data`/`present`
  stay byte-identical (nativegen untouched); `stride`/`row_len` appended after
  `present`. Self-contained `initGrid`/`gridGet`/`gridSet`/`gridRowLen` with a
  cell codec that mirrors the scalar one byte-for-byte; scalar paths assert
  `lane != .grid`. Six unit tests (round-trip, scalar-identical decode, jagged
  `row_len`, u8 packing, empty grid, OOM-safety). No interp wiring yet — Phase 3.
- [x] **Phase 3 — Row forwarding.** Outer `t[i]` on a grid table mints a
  transient `row_view` (`Table.getInt` grid arm, `@constCast` parent handle);
  both index fast paths in `interp.zig` skip grids so the handle is minted via
  `indexGet`. Inner `row[j]` get/set forward into the flat cells
  (`Table.rowViewGet`/`rowViewSet`); a non-int key, past-stride index, or
  lane-missing value returns `false` ⇒ deflation (Phase 5, surfaced as
  `Unimplemented` for now), as does any *outer* grid store. `#row` →
  `gridRowLen`, `#t` → row count; `next`/`pairs`/`ipairs` traverse a row as a
  length-`#row` array (`iterableArg` accepts a `row_view`; `rowViewNextStep`).
  `tostring(row)` already renders table-like (Phase 1 `io.writeValue` arm).
  Dormant until Phase 4 produces a grid at runtime — exercised by hand-built grid
  tables: 3 `table.zig` + 1 `interp.zig` + 1 `base.zig` unit tests. **Deferred to
  Phase 5** (with `Unimplemented` stubs in `indexSet`): outer row (re)assignment /
  append, and inner stores that overflow the grid.
- [x] **Phase 4a — Fused multi-level index opcodes (the gate).** New
  `get_index2`/`set_index2` bytecode (`bytecode.zig`); the compiler emits them
  for a chained `a[i][j]` / `a[i][j]=v` (the `.index`-of-`.index` arms of
  `compileExprTo` and `compileStore`), falling back to the two-op form otherwise.
  Interp handlers do the two-step access via `indexGet`/`indexSet`, so metatable
  dispatch on either level and the RHS-first evaluation order are byte-identical
  to the unfused form. Landed as a *pure optimisation on ordinary nested tables*
  — no grids yet — green on its own (3 `expectProgram` tests: chained get/set,
  inner `__index`/`__newindex` dispatch, eval order). The recorder aborts on the
  new opcodes (`.nyi_opcode`) until Phase 8. This is the vehicle that, once grids
  exist, never materialises a bare `row_view` into a register — closing the
  swap/identity hole (§Escape detection).

### Outstanding

The escape-detection re-plan (§Escape detection) **re-orders** these. The
`inflateToGrid`/`deflateGrid` primitives are built; the work now is the fused
indexing that lets grids be enabled safely.

- [ ] **Phase 4b — Inflation wired into the fused store path.** `a[i][j]=v` on a
  homogeneous-numeric nested `a` calls `Heap.inflateToGrid` (built); the fused
  ops then read/write grid cells directly. Hysteresis: a don't-retry flag so a
  non-qualifying or recently-deflated parent is scanned at most once.
- [ ] **Phase 4c — Bare access ⇒ deflate (escape).** A bare `get_index`/
  `set_index` (single level) on a grid table is conservatively an escape: it
  calls `Heap.deflateGrid` (built) and proceeds on the now-nested table. So a
  `row_view` value is *never produced at runtime* — only the fused path touches a
  grid, and it never leaks a view. Inner-overflow / outer-reassignment stores
  (the Phase 3 `Unimplemented` stubs) likewise deflate.
- [ ] **Phase 5 — `expectProgram` correctness sweep.** All 8 modes + GC stress on
  the canonical workloads: `a[i][j]` matrix fill/read, jagged rows, **in-place
  row swap / sort** (the pattern that motivated the gate — it deflates on the
  bare `tmp=a[i]` and stays correct), `a[i]==a[i]`, row passed to a function /
  stored in a table (deflates), `#a[i]`, `pairs`/`ipairs`.
- [ ] **Phase 6 — GC integration.** `blacken` over a grid skips the (non-heap)
  leaves; the grid buffer is owned by the parent. Already largely satisfied
  (`isLeaf` skips a grid array; no `row_view` heap objects exist) — verify under
  GC stress with grids live.
- [ ] **Phase 7 — Determinism + keyframe.** Prove the grid is in-memory only
  (never serialised), identity is `parent.id`-based (address-independent), all 8
  modes + keyframe restore observe identical logical values, and grids are
  deflated (or skipped) at keyframe capture. See §Determinism gate.
- [ ] **Phase 8 — Trace recorder support.** Record `get_index2`/`set_index2` as
  grid-relative address arithmetic (`base + (i*stride+j)`) behind `guard_grid` +
  bounds + not-deflated guards, side-exiting to tier-0 when a row has deflated.
  This is where the locality win is cashed.

## Why this exists

Today an array whose elements are themselves arrays/tables — nbody's
`bodies[i]`, array3d's `a[i][j][k]` — lands in the catch-all `.value` lane
(`ArrayPart.optimalLane`, array.zig:366: any heap element ⇒ `.value`). The trace
recorder aborts `get_index`/`set_index` on a `.value` lane (`recArrayGet`,
trace.zig:1857, `.nyi_opcode`), so these workloads run ~entirely on the tier-0
interpreter and never tier up. `--dump-aborts` localised both benchmarks'
single biggest gap to exactly this one opcode/lane combination.

There are two ways to close it:

- **The `.table` lane (option A, see doc 13's discussion / the cheaper path):**
  add a homogeneous-heap lane so `a[i]` records as a guarded table-typed load
  and `a[i][j]` chains as nested pointer-chasing packed loads. Unblocks *trace
  coverage* with no new semantics, but the rows stay scattered on the heap — no
  cache locality, N dependent loads per access.

- **Grid flattening (option D, this doc):** lay the nested numeric arrays out as
  one contiguous strided buffer in the parent table, so `a[i][j][k]` is
  `base + (i*d2+j)*d3 + k` — one multiply-add, one load, cache-friendly. This is
  the global structural win for every workload that touches a numeric matrix,
  but it collides with Lua's reference semantics for `a[i]` (rows are tables
  with identity and aliasing) and so needs an inflation/deflation lattice plus
  row-view objects to stay correct.

This doc is the contract for **option D**.

## The core tension (read this before the mechanism)

Scalar lane narrowing (i8/i16/.../f64) is sound and lives purely in the storage
layer for one reason: **its elements are value types with no identity.** `a[i]`
on an int lane returns a *copy* of an int; nothing can alias it or ask "is this
the same int," so the storage layer can swap representations invisibly.

Rows are tables: **reference types with identity and aliasing.** Lua lets the
program observe a row as a first-class handle, and the flat representation must
keep every one of these correct:

1. `local r = a[1]; r[4] = 99` — `r` aliases row 1; the write must hit the grid.
2. `a[1] == a[1]` — must return the same object both times (identity).
3. `a[1] = otherTable` — reassigns the whole row to an unrelated table.
4. `a[1]` may be stored elsewhere, passed to a function, survive across GC.
5. Rows may be jagged or grow past the stride.

Flattening is therefore only legal for rows that **do not escape** as live
handles, and the representation must **deflate** any row that does. Inflation is
the i8→value analogue (a store migrates the representation up); deflation is the
new inverse the scalar lattice never needed (scalars never escape, so they never
deflate). Jaggedness/sparsity is *not* a correctness barrier — a grid sized to
the bounding box wastes memory on short rows but stays correct; the bet (Bart's)
is that `a[i][j]` workloads are overwhelmingly rectangular-ish and numeric.

## Domain model

### `RowView` (Phase 1)

```
RowView = extern struct {
    header: GcHeader,      // ObjectType.row_view
    parent: *Table,        // the grid-bearing table
    row: u32,              // 0-based row index into the grid
    _pad: ...,
}
```

- `get_index`/`set_index` on a `RowView` forward into
  `parent.grid[row*stride + (k-1)]` at the grid's element lane.
- Identity: the parent caches the materialised `RowView` per row (a sparse
  `row → *RowView` map, populated lazily on first escape) so a second `a[i]`
  returns the same pointer and `a[i] == a[i]` holds.
- A `RowView` keeps its `parent` alive (GC edge) and pins the grid row.

### Grid array-part (Phase 2)

**Decided: 2a, and landed** (see Implementation status). The two encodings that
were on the table:

- **(2a) New `.grid` lane** on the existing `ArrayPart`: `data` reinterpreted as
  a flat `[rows*stride]` buffer at a sub-element lane (`grid_elem: Lane`), plus a
  per-row `len`/presence vector and a `stride`. Keeps everything in one struct;
  costs `ArrayPart` two new fields (layout churn the JIT's `Layout` contract
  catches at compile time).
- **(2b) Separate `GridPart`** pointed to from the parent when nested. Keeps
  `ArrayPart` untouched (no JIT `Layout` disturbance) at the cost of a second
  representation the table must branch on.

Either way the parent's *outer* `get(i)` returns "the i-th row" — which is a
`RowView` (materialised/cached) when read as a value, but the **fused** index
path (Phase 7 + the tier-0 fast path) reads `grid[i*stride + j]` directly
without ever materialising the row.

## Mechanism

### Inflation — when a plain table becomes a grid (Phase 4)

Trigger lives where `setInPlace`'s widen already lives. On `a[i][j] = v`:
- `a` is a table, `a[i]` is (or is about to be) a table, `v` is a narrow scalar.
- If `a`'s elements are all such rows (homogeneous, numeric leaves), migrate `a`
  into a grid with `stride = max observed row length` (grows by reshape, like
  array growth today). The existing nested row tables are copied into the grid
  and freed; any that already escaped (have outstanding refs) block inflation
  for that row — it stays nested.

This is deliberately the same shape as `widenFor` (array.zig): a store that
doesn't fit the current representation migrates it to a more capable one.

### Deflation — the inverse the scalar lattice never needed (Phase 5)

A row deflates back to a real `Table` when it can no longer be a grid row:
- **Escape:** the program takes a live handle to `a[i]` (see Open questions for
  how tier-0 detects this). Deflation here means: stop, materialise a `RowView`
  (cheap — no copy, it's a view) OR copy the row out to a real table. The
  `RowView` route is preferred (keeps the grid intact); copy-out is the fallback
  when a `RowView`'s invariants can't hold (e.g. the row then grows).
- **Reassignment:** `a[i] = x` overwrites slot i with a real ref; the old grid
  row is orphaned (kept alive only if a `RowView` still references it).
- **Row growth past stride / non-numeric leaf store:** reshape the grid (grow
  stride) or deflate that row to nested.

Invariant: **at every deflation boundary, readers see byte-identical logical
values** before and after. This is the determinism contract (doc 02) and the
correctness contract simultaneously.

### Trace recorder (Phase 7) — where the win is cashed

A fused multi-level index records `a[i][j][k]` as:
`guard_grid(a)` + bounds guards on i/j/k + one `aref` computing
`base + (i*stride_i + j)*stride_j + k` + one `aload` at the grid element lane.
A side-exit fires if any row on the path has deflated (the `guard_grid` /
per-row-present check fails), dropping to tier-0 which holds the always-correct
nested/deflated representation. This is structurally identical to today's
`guard_lane` + `aref` + `aload`, just with multi-dimensional address arithmetic
and a grid-validity guard instead of a single-lane guard.

## Non-goals (v1)

- **Explicit `typed_array` n-d (`object.zig` TypedArray).** That's the FFI-cdata
  analogue with no per-row table identity — a *separate*, simpler target. This
  doc is specifically about making *plain Lua nested tables* flatten implicitly.
  If review concludes implicit flattening is too costly, n-d `typed_array` is
  the documented fallback for the cache win.
- **Non-numeric grids.** A grid of strings/tables stays nested (`.table` lane or
  `.value`). Grids are for narrow scalar leaves only.
- **Auto-flattening arrays whose rows demonstrably escape.** Those stay nested;
  the optimisation is best-effort, never mandatory for correctness.

## Phasing

Phases 1–6 make the representation correct under tier-0 alone (no trace) — the
gate is that all 8 modes + keyframe replay stay byte-identical with grids
enabled, with deflation exercised. Phase 7 adds the trace fast path that turns
correctness into the actual speedup. The build stays green at every phase
(Rule Z-3); each representational invariant gets its shape pinned with tests
(inflation round-trip, deflation-on-escape identity, `a[i]==a[i]`,
alias-through-`RowView`, jagged bounding box, GC of escaped-orphan rows).

## Escape detection — the gate decision (2026-06-26, Bart)

**Resolved: option (a) — gate grids behind fused indexing.** A bare `get_index`
is conservatively an escape (it deflates the grid); the compiler emits a fused
`get_index2`/`set_index2` for chained `a[i][j]` that reads/writes the grid cell
directly and never produces a `row_view` `Value`. So at runtime a `row_view` is
never materialised into a register at all, and the grid is only ever touched
through the fused path.

**Why the alternatives were rejected — the in-place row swap.** During Phase 4+5
implementation a decisive counterexample surfaced that breaks **both** the
"copy-out on escape" architecture (Decision section below) *and* a
"persistent-`row_view`-alias" variant:

```lua
local tmp = a[i]   -- transient row_view(a, i-1); grid intact; NOT a heap store
a[i] = a[j]        -- outer store on a grid ⇒ DEFLATE a; slot i is then reassigned
a[j] = tmp         -- tmp must still denote the ORIGINAL a[i]
```

`tmp` is a bare `row_view` parked in a register across the deflation. Any scheme
that resolves a stale `row_view` *through the parent's array slot* reads the
**reassigned** value, not tmp's original row — and copy-out-on-escape can't save
it either, because tmp's copy-out happens only at line 3, after the grid is gone
and slot `i` already overwritten (this is the same hazard the review flagged as
"orphaned-row-on-reassignment," lines below). The only fully sound slot-free fix
is a per-grid `row → *Table` deflation map frozen at deflation time — extra
permanent state on every deflated `Table`. Rather than pay that, **gate**: never
let a bare `row_view` exist at runtime, so the parked-stale-view case cannot
arise. The `row_view` `Value` (Phase 1) and the `rowViewGet`/`Set`/`Len`
forwarding (Phase 3) become dormant at runtime under this gate — kept (green,
harmless), but the fused opcodes compute cell addresses directly without minting
a view.

This re-orders the phasing: fused indexing (was Phase 8) is now the prerequisite
(Phase 4a) for enabling live grids.

## Open questions for review
- [x] **2a (`.grid` lane) vs 2b (separate `GridPart`)** — ~~layout churn vs a
  second representation to branch on.~~ **Decided 2a** (Bart): the `Layout`
  "frozen contract" is purely our own compile-time-checked invariant — nothing
  external consumes it — so disturbing it costs nothing, and one struct beats two
  representations to branch on. Landed in Phase 2; `grid_elem` slotted into
  existing padding kept even the nativegen-addressed offsets byte-identical.
- [ ] **Is the win worth the deflation machinery vs option A?** A unblocks the
  same benchmarks' *coverage* for a fraction of the work but leaves rows
  scattered. D adds locality globally but is a large, semantically delicate
  build. This is the decision Phase 0 must settle.
- [ ] **GC cost of the per-row `RowView` cache** and orphaned-but-referenced
  rows — does this reintroduce per-element heap objects in the escape-heavy
  case, eroding the win exactly where the representation is most stressed?

## Feasibility review outcome (2026-06-26)

Two independent external reviews (Codex high-reasoning, Antigravity) reached the
**same conclusion**: build the `.table` lane first; grid flattening is sound but
a long, semantically delicate project, not a quick win. Verbatim sizings — Codex:
`.table` lane "1–3 week project," grid flattening "2–6 months to make solid";
Antigravity: `.table` lane "2-week build," grid flattening "6-month tar pit."

Both flagged failure modes I under-weighted, recorded here so they're not
rediscovered the hard way:

- **GC space-leak via parent pinning (the sharpest new objection).** A `RowView`
  must read from the parent's contiguous buffer, so a single escaped row pins the
  *entire* grid. `local r = a[1]` on a 1000×1000 f64 grid, then drop `a` → the
  whole 8 MB buffer is uncollectable while `r` lives. Avoiding it needs copy-out
  of the row on parent death (hard to coordinate with our GC) or accepting the
  leak. Scalar lanes never had this because scalars don't escape.
- **Identity-cache strong/weak dilemma.** Strong per-row `RowView` cache →
  unbounded bloat (every touched row pinned for the parent's life). Weak cache →
  requires weak-pointer marking in the GC, new bookkeeping + sweep cost.
- **Orphaned-row-on-reassignment.** `local r=a[1]; a[1]=other` means `r` must keep
  denoting the *old* row contents — deflation must copy the slice out to a fresh
  table and rewrite `r`'s identity target, not just deflate the parent.
- **Observability surface (Codex's list).** `rawequal`, row-as-hash-key, weak
  tables, `next`/`pairs` over a row, `#row`, `setmetatable(row,…)`, `rawget`/
  `rawset`, coroutine-suspended row refs, debug APIs — each must either implement
  full row-table semantics on `RowView` or force a stable, identity-preserving
  deflation. "A grid row has a stable table identity that may be virtual
  internally, and every table-observing op must honour it" — that's implementing
  virtual tables with lazy materialisation, far past storage widening.
- **Deflation cascades / perf cliff.** A trace compiled for the flat layout that
  hits a deflation in a loop enters continuous alloc/dealloc — invisible and
  worse than never flattening. This is *why* LuaJIT keeps flat n-d in FFI cdata:
  cdata bypasses per-row identity, metatables, weak refs, hash-key use. Plain
  tables are "too observable." We would be crossing a line Pall drew deliberately;
  the hidden cost is exactly semantic transparency.

**Better escape-detection option than the doc's (a)/(b)** — both reviewers,
converging:
- Codex: keep "borrowed/pinned" **purely inside the trace IR**, never a
  VM-visible state. Once a row becomes a runtime `Value` it is a real identity
  object; tier-0 always returns a stable cached `RowView`. Fused opcodes are a
  *perf* fast path, not the correctness foundation.
- Antigravity (Option C): represent `RowView` as a **transient 16-byte fat
  `Value`** (tag + parent ptr + row index) — no heap allocation; `rawequal` =
  compare parent+row. The catch: every opcode that stores a `Value` into a heap
  object must eagerly inflate/deflate the transient into a concrete table on the
  way in. Trades heap churn for a check on every heap-store opcode.

The reviewers' net recommendation was "`.table` lane first, defer D." That
recommendation rests on the 2–6-month sizing, which is a *human-time* cost — see
§Decision for why that input no longer dominates. Their **technical** findings
(the failure modes above) stand and are what the revised architecture below is
built to neutralise.

## Decision (post-review): build D, on a revised architecture

**Why build-size is not the deciding factor.** The "tar pit" verdict prices six
months of an engineer's irreplaceable time against an uncertain payoff — exactly
the calculus that made Pall confine flat n-d to FFI cdata. That input is now
~zero: a failed attempt costs token budget and recoverable effort, not months of
a life. So the decision reduces to the project's two real gates — is it sound
(yes), and does it preserve determinism/replay (yes, below). Build size is not a
gate. (This reverses the "do A first" lean recorded above; the original
heap-`RowView`-with-cache domain model in §Domain model is kept as the rejected
alternative.)

**The architecture pivot that dissolves the worst objections.** The reviews'
sharpest failure modes — GC parent-pinning (one escaped row pins the whole grid),
the identity-cache strong/weak dilemma, and per-element heap churn in loops — are
all artefacts of representing a row as a *heap* `RowView` that points into the
grid and must be cached for identity. Drop that. Instead (Antigravity's Option C
+ Codex's "borrowed stays internal," converging):

- **Rows are transient fat values, not heap objects.** `a[i]` on a grid returns a
  16-byte `RowView` *value* — `{ tag: row_view, parent: *Table, row: u32 }` —
  packed into the existing `Value` payload. No heap allocation, so a hot
  `a[i][j]` loop allocates nothing.
- **Identity is structural.** `a[i] == a[i]` and `rawequal(a[i], a[i])` compare
  `(parent, row)`. No identity cache exists, so there is no strong/weak dilemma —
  and, decisively, no dependence on GC timing (the determinism point below).
- **Escape ⇒ copy-out, not pin.** The instant a `RowView` value would be stored
  into a heap object (any heap-store opcode: `set_index`, `set_global`, upvalue
  close, table-constructor), that opcode **inflates it to a real concrete
  `Table`** — copying the row's slice out of the grid. An escaped row is then a
  normal table that does not reference the grid, so it cannot pin it. The grid
  only ever holds rows that never escaped. Antigravity's own 8 MB-pinning killer
  is thereby designed out, not mitigated.
- **The cost moves to the heap-store opcodes.** Every opcode that writes a
  `Value` into a heap slot gains a check "is this a transient `RowView`? then
  inflate first." Bounded, on the store path (not the read path), and to be
  measured against non-grid workloads for regression.

This replaces the `RowView`/identity-cache bullets in §Domain model and the
(a)/(b) escape-detection options in §Open questions; both are kept above as the
rejected first cut.

## Determinism gate (the one principled blocker — and why it clears)

Per `00-architecture.md`, the only legitimate reason a representation trick is
off-limits is that it breaks byte-identical 8-mode equivalence or keyframe
replay. Grid flattening clears this:

- **The grid is never serialised.** Like `lane`, it is an in-memory
  optimisation; keyframes persist *logical* values (`array.get(i)` round-trips on
  any representation), so a restore that lands on a different grid/nested state is
  still observably identical.
- **Identity is address-independent.** `RowView` equality is `(parent.id, row)`,
  not a heap address — same discipline as `key_order` and the `ValueContext` hash
  (which key off `asHeap().id`, never the pointer). So `a[i]==a[i]` and
  row-as-hash-key are reproducible across modes.
- **Inflation/deflation are pure functions of the operation stream.** Inflation
  fires on a deterministic store shape; deflation fires on a deterministic op
  (escape via a heap store, `setmetatable`, row growth past stride). Neither is
  driven by the collector or by a clock.
- **The single forbidden mechanism: GC-timing-driven deflation.** A weak identity
  cache would make `a[i]==a[i]` depend on whether a `RowView` was collected —
  non-deterministic. The fat-value model has no cache, so this hazard does not
  exist by construction. (This is *why* the structural-identity choice is load-
  bearing, not just convenient.)

Determinism therefore constrains *how* (no weak cache, structural identity,
op-driven transitions), never *whether* — exactly the asterisk the architecture
doc reserves.

## References

- `src/array.zig` — `ArrayPart`, `Lane`, `optimalLane`, `widenFor`, `setInPlace`,
  the `Layout` JIT contract.
- `src/table.zig` — `Table`, `array`/`hash` split, `getInt`.
- `src/interp.zig:1893` — the `get_index`/`set_index` tier-0 fast paths.
- `src/trace.zig:1840` — `recArrayGet`/`recArraySet` (the `.value` abort to lift).
- `src/gc.zig:243` — `blacken`; `isLeaf` (array.zig:197) drives array marking.
- `src/object.zig` — `TypedArray` (the explicit n-d fallback, a non-goal here).
- `docs/design/02-determinism.md`, `03-gc-memory.md` — the contracts grids must
  not break.
