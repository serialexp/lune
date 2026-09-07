//! Trace IR — the shared, leaf representation of a recorded trace.
//!
//! Carved out of `trace.zig` (the file-split pass): the SSA instruction set
//! (`IrOp`/`IrInstr`), its guard-PC accessors, the loop-carried `SlotStore`,
//! the instruction disassembler, and the `withPhis` test helper. This is the
//! surface every IR consumer shares (`nativegen.zig`, `irinterp.zig`,
//! `tropt.zig`, `troptdiag.zig`, `traceser.zig`, and the nativegen tests).
//!
//! LEAF MODULE: must not import `trace.zig` (or anything that cycles back to
//! it) so the IR definition stays dependency-free. `trace.zig` re-exports
//! every name here, so external importers keep spelling `trace.IrOp` etc.

const std = @import("std");
const io = @import("io.zig");
const function = @import("function.zig");

/// An SSA value reference: an index into a trace's `instrs` array. Every IR
/// instruction defines exactly one value, named by its position.
pub const Ref = u16;

/// Index into the (future) per-guard snapshot table. Still a RESERVED
/// placeholder (checked 2026-09: no producer writes a non-default value and no
/// consumer reads it) — kept deliberately so per-guard snapshot deopt can land
/// as a body to fill in, not a trace-schema change. Serialized as-is by
/// traceser. See docs/design/01-trace-lifecycle.md.
pub const SnapIdx = u32;

/// The type the recorder *observed* for a value, and therefore the type a guard
/// pins / the result type the recorder inferred. Drives guard insertion now and
/// type-narrowing in the Phase 6 optimizer.
pub const ObsType = enum(u8) { unknown, int, float, boolean, nil, heap };

/// Trace IR opcode. Mirrors the arithmetic/compare subset of the tier-0 ISA
/// (`bytecode.OpCode`) plus the constructs unique to a linear trace: value
/// *inputs* (`slot_load`/`konst`), *guards* (the runtime checks that keep the
/// straight-line trace valid), and the `loop` back-edge marker.
pub const IrOp = enum(u8) {
    // ---- inputs ----
    /// `aux` = tier-0 register read at trace entry (a loop-variant input).
    slot_load,
    /// `aux` = index into the trace's `consts` pool.
    konst,

    // ---- arithmetic / bitwise (R = a op b) ----
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,
    band,
    bor,
    bxor,
    shl,
    shr,

    // ---- unary (R = op a) ----
    neg,
    not,
    bnot,

    // ---- comparisons (R = a cmp b → boolean). gt/ge normalise to lt/le with
    //      swapped operands, exactly as tier-0 does. ----
    eq,
    ne,
    lt,
    le,

    // ---- guards (check `a`; on failure the future executor side-exits to
    //      tier-0 via the snapshot). ----
    guard_int,
    guard_float,
    guard_number,
    guard_true,
    guard_false,

    // ---- lane-aware packed-array access (Phase B) ----
    //
    // These reach a table's dense array part (`array.zig`) directly, at its
    // current lane. The 3-input store (table, index, value) won't fit a 16-byte
    // `IrInstr`, so `aref` *pairs* the (table, index) addressing into one node and
    // `aload`/`astore` reference it plus at most one more operand. `aux` on every
    // op below is the `array.Lane` ordinal the access was recorded against.
    //
    /// `a`=table value ref, `b`=index ref → element address descriptor. Carries no
    /// usable `Value` (its operands are what `aload`/`astore` read); native kind
    /// is a raw pointer (`Kind.ptr`).
    aref,
    /// `a`=`aref` ref → decode the packed slot to a `Value` (int/boolean per lane).
    aload,
    /// `a`=`aref` ref, `b`=value ref → encode `b` into the packed slot (the FIRST
    /// mid-iteration heap mutation; see `02-determinism.md`). Effectful: never DCE'd
    /// and a CSE/alias barrier for later `aload`s. The recorder only emits it when
    /// the store is in-lane + in-bounds and its value does NOT depend on any prior
    /// `aload` (C1 deopt-replay idempotence), so re-running the iteration on a
    /// side-exit reproduces the same heap.
    astore,

    // ---- array-access guards (check via the referenced node; side-exit on miss) ----
    /// `a`=table value ref → the value is a heap table **with no metatable**.
    /// Recording aborts on a metatable-bearing table (`AbortReason.has_metatable`),
    /// so every trace assumes raw array access; the no-metatable half of this guard
    /// catches a `setmetatable` that lands between trace entries (chunk 2a) and
    /// side-exits to tier-0, which does full `__index`/`__newindex` dispatch.
    guard_table,
    /// `a`=table value ref, `aux`=lane → the table's array lane equals `aux`
    /// (bails if a monotonic widen moved it past the recorded lane).
    guard_lane,
    /// `a`=`aref` ref → the index is in the array part: `(index-1) <u len`.
    guard_bounds,
    /// `a`=`aref` ref → the slot is present (narrow-lane presence bit set); a hole
    /// would read as `nil`, which the native int/boolean path can't represent.
    guard_present,
    /// `a`=value ref, `aux`=lane → the int value fits the narrow int lane's signed
    /// range (i8/i16/i32). Emitted before an int-lane `astore` so that a value
    /// which would force a tier-0 lane WIDEN (an alloc+relayout native can't do
    /// mid-run) side-exits to tier-1a instead of being silently truncated. The
    /// bool lane and the i64 lane need no such guard — every value fits.
    guard_fits,

    // ---- close ----
    /// Loop back-edge: the end of the straight-line trace. Carries no operands;
    /// the loop-carried register writes are the slot-bound `phi` nodes (each
    /// `phi` with `aux >= 0` flushes its update to that register at the back-edge).
    loop,

    // ---- loop-carried value (Phase E) ----
    /// A first-class loop-carried value (a φ at the loop header). `b` = the value
    /// carried to the next iteration (the *update*; the body def — what an
    /// `exit_store.ref` used to name), `aux` = the tier-0 register `slot` this φ
    /// flushes to at commit/deopt (a *slot-bound* φ, `aux >= 0`), or **-1** for an
    /// *internal* φ that backs no register (strength-reduction's running
    /// accumulator). `ty` = carried scalar type.
    ///
    /// The *init* (the value on loop entry) differs by kind: a **slot-bound** φ's
    /// init is implicit — it is `regs[aux]`, read fresh each entry exactly as the
    /// matching `slot_load` does — so `a` is unused (kept 0). An **internal** φ has
    /// no register, so its init is an explicit ref: `a` = the preheader value
    /// (Phase E1's hoisted region), seeded once on the first iteration.
    ///
    /// A φ whose value is read in the body is *carried* (gets a home + the back-edge
    /// shuffle); a slot-bound φ never read is *write-only* (just flushed). `b` is the
    /// one operand allowed to reference a *later* node (the back-edge), exactly as
    /// `exit_store.ref` always could — well-formedness validates `b < last`, not
    /// `b < i`. Replaces the implicit `slot_load`+`exit_store` carry (a slot-bound φ
    /// + its `slot_load` is what an `exit_store`/`slot_load` pair was). Appended at
    /// the enum's end so `loop`'s ordinal stays stable for the wire format.
    phi,

    // ---- loop region boundary (Phase E1: LICM) ----
    /// Marks the end of the **preheader** region. Every instruction *before* this
    /// marker runs exactly **once** (on loop entry); every instruction *after* it
    /// (up to and including `loop`) runs **every iteration**. Carries no operands
    /// and produces no value — a pure structural boundary, the run-once analogue of
    /// the terminal `loop` marker. Synthesized only by the LICM pass (`tropt.zig`):
    /// a freshly-recorded trace has none, so its absence is the common case and the
    /// executor's `body_start == 0` fast path is byte-identical to pre-E1 behaviour.
    ///
    /// Linear SSA already guarantees a preheader instruction (index < marker) can
    /// only reference earlier instructions (all in the preheader) — the hoisted
    /// region is self-contained by construction. A `phi` never sits in the
    /// preheader (loop-carried values run every iteration); `assertWellFormed`
    /// enforces both that and the at-most-one-marker rule. Appended last so every
    /// prior ordinal (incl. `loop`/`phi`) stays stable for the wire format.
    preheader,

    // ---- float→int loop-limit specialization (numeric-for) ----
    /// `a` = a float value ref → its **exact integer value** (`ty == .int`), OR a
    /// side-exit if the float is not an integer representable in `[-2^63, 2^63)`
    /// (`value.floatAsExactInt` returns null). Both a value producer AND a guard.
    ///
    /// Emitted by `recForLoop` when a numeric-`for` has an int index+step but a
    /// **float** limit whose observed value is an exact integer: tier-0 compares the
    /// int index against the float limit EXACTLY (`compareIntFloat`), and for an
    /// integral limit `L` in range `idx <= L ⟺ idx <= (i64)L`, so converting the
    /// loop-invariant limit to an int once makes the body compare int-vs-int — which
    /// the native backend can lower (a mixed int/float compare bails). If a later
    /// entry's limit is non-integral the op side-exits at the loop header (completed
    /// unchanged) and tier-0 runs the loop with the exact mixed compare. `aux` carries
    /// the recording PC for exit-PC chaining, like the other side-exiting guards.
    /// Appended last so every prior op's wire ordinal stays stable.
    int_of_float,

    // ---- array-growth (append) store path (capacity-bounded grow) -------------
    /// `a` = `aref` ref → the append precondition guard, the grow analogue of
    /// `guard_bounds`. Side-exits to tier-0 unless ALL hold for the `aref`'s table
    /// at runtime: (1) the hash part is empty (so `Table.set`'s `migrateFromHash`
    /// would be a no-op — native/oracle skip it), (2) `idx == len+1` (the key is the
    /// exact append successor — the store lands at `data[len]`), and (3) `len < cap`
    /// (room to grow *without* a realloc). On a side-exit tier-0 runs the iteration:
    /// it `append`s — doubling `cap` via `ensureCapacity` when (3) fails, or absorbing
    /// a hash successor when (1) fails — then the loop re-enters. Because the realloc
    /// only ever happens on this side-exit (never on-trace), `len`/`cap`/`data` stay
    /// byte-identical across tier-0 / tier-1a / native (the B5 invariant, extended to
    /// growth: the array is never reallocated *on-trace*). Marks the `aref`
    /// bounds-checked (the store at `data[len]` is in-cap), like `guard_bounds`.
    /// Appended last so every prior op's wire ordinal stays stable.
    guard_append,
    /// `a` = `aref` ref, `b` = value ref → append the value as the new key `len+1`,
    /// writing `data[len]` in the lane encoding and bumping `len` by one. The grow
    /// analogue of `astore`: the FIRST mid-iteration *length-changing* heap mutation.
    /// Behind a dominating `guard_append` (room + shape + empty hash proven) and a
    /// `guard_fits` (value in-lane), so it neither reallocs, widens, nor migrates —
    /// `irinterp` lowers it to `ArrayPart.appendInCap`. Effectful (never DCE'd, an
    /// alias/CSE barrier, and — unlike `astore` — it *writes* `len`, so `guard_append`
    /// can never be hoisted above it). Produces no value. Boolean lane only in Phase A.
    /// Appended last so every prior op's wire ordinal stays stable.
    astore_append,

    // ---- cross-frame call identity guard (cross-frame tracing) ----------------
    /// `a` = SSA ref of the callee value at the inlined `.call` slot; `aux` =
    /// the recorded `Proto.id` (`@bitCast(u32↔i32)`, a stable id, NEVER a raw
    /// pointer — replay restores a closure with the same id but a new address,
    /// doc 02). Side-exits to tier-0 unless the runtime value is a heap Lua
    /// closure whose `proto.id == aux`. Fails **closed**: a non-closure, a
    /// native function, or a different proto all deopt, and tier-0 re-runs the
    /// iteration from the loop header — re-executing the real `.call`, which
    /// reconstructs the callee frame for free (the replay-from-header model, so
    /// no multi-frame snapshot is needed). Proto-id identity is sound only while
    /// in-callee upvalue access still aborts recording (two closures over one
    /// proto are trace-identical when no upvalue is read); when upvalue inlining
    /// lands this must tighten to the closure's `GcHeader.id`. Produces no value
    /// (`ty == .none`); never DCE'd (it is a `.guard` in `tropt.kindOf`).
    /// Appended last so every prior op's wire ordinal stays stable.
    guard_func,

    // ---- hash-part (string-keyed) field access (doc 11) -----------------------
    //
    // The mirror of `aref`/`aload`/`astore` for a table's HASH part, reached by a
    // *constant* key (an `obj.field` access — the compiler lowers `.field` to a
    // `load_const <name>` + `get_index`, so the key ref is always a `konst`). The
    // value cell for a constant key is loop-invariant (stable across iterations
    // unless the map rehashes), so — like the array base pointer and the
    // `.ptr`/`.func` snapshots — it hoists to the native prologue (H1). A computed
    // string key (`t[expr]`) records as a non-`konst` ref and aborts (v1 scope).
    //
    /// `a` = table value ref, `b` = the key `konst` ref (an interned string) →
    /// the hash value-cell address descriptor. The hash analogue of `aref`:
    /// carries no usable `Value` (its operands are what `hload`/`hstore` read);
    /// native kind is a raw pointer (`Kind.href`, the re-resolved `getPtr` cell).
    /// Classified `.aref` in `tropt.kindOf` (same (a=table, b=key) operand shape).
    href,
    /// `a` = `href` ref → load the full tagged `Value` from the cell. The hash
    /// analogue of `aload`: the oracle returns `Table.get(key)`; native loads the
    /// cell's tag+payload (a following consumer guard — `guard_int`/`guard_number`,
    /// exactly as for a `slot_load` — narrows it, and native declines a
    /// heap-valued field). Classified `.aload`.
    hload,
    /// `a` = `href` ref, `b` = value ref → store the value into the cell in place
    /// (`hash.getPtr(key).?.* = v`). The hash analogue of `astore`: present-key
    /// overwrite only (the recorder rejects an absent key — an insert could grow /
    /// rehash and dangle every hoisted cell — and a `nil` value, a delete). Follows
    /// the same C1 store-sink discipline as `astore` (deferred below every guard
    /// when it follows a load). Effectful; never DCE'd. Classified `.astore`.
    hstore,
    /// `a` = `href` ref → the hash-part structural-stability guard. Side-exits to
    /// tier-0 unless, for the `href`'s table: the recorded key is still **present**
    /// AND the hash part is structurally unchanged since the cell was resolved
    /// (`hash.size == aux`, the recorded population — native additionally pins the
    /// `metadata` pointer to catch a same-size realloc). Pinning `size` catches
    /// insert/delete/grow; pinning `metadata` (H1) catches realloc-grow — together
    /// they prove the hoisted cell pointer (re-resolved per entry, NEVER a
    /// serialized pointer) is still valid. `aux` = recorded `hash.count()` (a small
    /// count, not a PC — so NOT in `guardExitPc`, like `guard_lane`/`guard_fits`).
    /// The no-metatable / is-table half is owned by the `guard_table` emitted on
    /// the raw table ref just before `href`. Produces no value; never DCE'd
    /// (a `.guard`). Classified `.guard`.
    guard_hash,

    // ---- pure-builtin inlining (doc 12) ---------------------------------------
    //
    // A `recCall` to a native flagged `RecordedBuiltin` (e.g. `math.sqrt`) is inlined
    // as a dedicated leaf producer instead of aborting `.host_barrier`. The trace
    // bakes in "callee is this builtin"; `guard_builtin` re-proves that identity, and
    // the producer (`fsqrt`) computes the result directly from its float operand.
    //
    /// `a` = the callee value ref (a once-seeded loop-invariant upvalue/global),
    /// `aux` = `@intFromEnum(RecordedBuiltin)`. Side-exits to tier-0 unless the runtime
    /// callee is still a `.native` carrying exactly this `pure` tag — so a reassigned
    /// `sqrt` upvalue deopts on the same iteration in both the oracle and native.
    /// The callee is a once-seeded synthetic input, so the value is loop-invariant
    /// and the guard is a candidate for LICM (like `guard_func`); the current pass
    /// does NOT hoist guards (re-checking an invariant value each iteration is cheap
    /// — see `tropt`'s LICM note), so today it re-checks per iteration. Produces no
    /// value; never DCE'd. Classified `.guard`.
    guard_builtin,
    /// `a` = the float argument ref → the pure-builtin result. v1 is `sqrt` only:
    /// the oracle computes `Value.float(@sqrt(arg))` and native lowers to a single
    /// `sqrtsd` (both IEEE correctly-rounded, bit-identical under the default MXCSR).
    /// A leaf unary producer: it cannot itself side-exit — its operand's preceding
    /// `guard_float` pins the arg type. `ty` is always `.float`. Classified `.unary`
    /// (NOT a constant-folder input — see doc 12 / `tropt`).
    fsqrt,

    // ---- arithmetic right shift (`~>>`, mahina syntax extension) ----------------
    /// `a` = value ref, `b` = count ref → arithmetic (sign-extending) right shift,
    /// the `~>>` operator. The bitwise-group analogue of `shr`/`shl`: both operands
    /// guarded `.int` upstream, 64-bit width like the rest of mahina's integer
    /// bitwise set, oracle is `arith.sar`. Classified `.binary` (a pure two-int
    /// producer). Appended last so every prior op's wire ordinal stays stable
    /// (the traceser ordinal-pinning convention — NEW ops go at the enum end).
    sar,

    // ---- flattened-grid cell access (doc 14, Phase 8) -------------------------
    //
    // The mirror of `aref`/`aload`/`astore` for a table whose array part is a
    // **flattened grid** (`lane == .grid`): a contiguous row-major buffer of
    // `cap*stride` cells at the fixed-width `grid_elem` lane (i8/u8/i16/i32/i64;
    // f64 deferred), with a per-cell presence bitmap. Reached ONLY by a fused
    // `get_index2`/`set_index2` (`a[i][j]`) — the gate (doc 14 §Escape) keeps a
    // grid from ever materialising a bare `row_view`, so these are the only grid
    // accessors and the scalar `aref`/`aload`/`astore` (which go through the
    // grid-hostile `tbl.getInt`/`setInLane`) never touch one.
    //
    // A cell needs (table, row, col) = three refs, which won't fit one 16-byte
    // `IrInstr`, so the address is a **two-op chain**: `garow` pairs (table,row)
    // and `gcell` pairs (garow,col). `aux` on every op below is the `grid_elem`
    // `array.Lane` ordinal (a real fixed-width lane, so `nativegen.laneKind`/
    // `intLaneWidth` classify it exactly like a scalar int lane).
    //
    /// `a`=table value ref, `b`=row index ref → grid row descriptor; carries no
    /// usable `Value` (its operands are what `gcell` reads). Tier-1b materialises
    /// `row0 = row-1`. The grid analogue of `aref`; classified `.aref` in
    /// `tropt.kindOf` (same (a,b) operand shape). Bounds-checked by a `guard_bounds`
    /// (a grid's `len == rows`, so the existing `1<=index<=len` body is the row
    /// bound). Appended last so every prior op's wire ordinal stays stable.
    garow,
    /// `a`=`garow` ref, `b`=column index ref → the full grid cell descriptor.
    /// Tier-1b materialises the flat row-major index `flat = row0*stride + (col-1)`
    /// (the table is reached through `garow.a`, `stride` loaded live). Carries no
    /// usable `Value`. Classified `.aref`. Appended last.
    gcell,
    /// `a`=`gcell` ref → decode the addressed grid cell to a `Value`. Tier-1a runs
    /// the exact tier-0 reader `array.gridGet(row-1, col-1)` (byte-identical);
    /// tier-1b loads `data + flat*width` at the `grid_elem` width. `aux`=grid_elem,
    /// `ty`=observed scalar type. The grid analogue of `aload`; classified `.aload`.
    /// Appended last.
    gload,
    /// `a`=`gcell` ref, `b`=value ref → encode `b` into the addressed grid cell.
    /// Tier-1a runs `array.gridSet(row-1, col-1, v)`; tier-1b stores at the lane
    /// width and sets the presence bit. Behind a dominating `guard_fits` (value in
    /// `grid_elem`) and the cell's row/col bound guards. The recorder emits it only
    /// for an in-grid, in-bounds, in-lane store (a grow/widen aborts to tier-0), so
    /// it never reshapes/reallocs. Effectful (never DCE'd, an alias/CSE barrier).
    /// The grid analogue of `astore`; classified `.astore`. Appended last.
    gstore,
    /// `a`=table value ref, `aux`=grid_elem ordinal → the table's array part is
    /// still a grid at the recorded element lane (`lane == .grid && grid_elem ==
    /// aux`). The grid's deflation + element-widen guard: a bare access deflates the
    /// grid (lane flips off `.grid`) and `gridWidenElem` changes `grid_elem`; either
    /// side-exits to tier-0. Produces no value; never DCE'd. Classified `.guard`.
    /// `aux` is the recorded lane (semantic identity, like `guard_lane`). Appended last.
    guard_grid,
    /// `a`=table value ref, `aux`=recorded stride → the grid's column count is
    /// unchanged (`stride == aux`). Pins stride so `gcell`'s `row0*stride` math
    /// stays valid AND a `gridGrowStride` (which **reallocates** `data`/`present`)
    /// side-exits before any hoisted base pointer dangles. Produces no value; never
    /// DCE'd. Classified `.guard`; `aux` (the stride) is semantic identity. The
    /// recorder aborts if the live stride exceeds `i32` (absurd for a real grid).
    /// Appended last.
    guard_stride,
    /// `a`=`gcell` ref → the column index is in the grid's column extent
    /// (`1 <= col <= stride`). The column-dimension analogue of `guard_bounds`
    /// (which, on the `garow`, covers the row dimension). Reads `col` from `gcell.b`
    /// and the table through `gcell.a`→`garow.a`. Together with the row bound this
    /// proves the flat index lands in the correct cell (not merely `< cells`, which
    /// would alias across rows). Produces no value; never DCE'd. Classified `.guard`.
    /// Appended last.
    guard_gcol,
    /// `a`=`gcell` ref → the addressed grid cell is present (a hole reads as `nil`,
    /// which the narrow int path can't represent). The grid analogue of
    /// `guard_present` — but distinct because `guard_present`'s tier-1a body calls
    /// the scalar `tbl.getInt`, which asserts `lane != .grid`. Tier-1a checks
    /// `!array.gridGet(row-1,col-1).isNil()`; tier-1b `bt`s the presence bitmap at
    /// the flat index. Produces no value; never DCE'd. Classified `.guard`. Appended last.
    guard_gpresent,
    // ---- nested-loop trace linking (doc 15, Phase 2) --------------------------
    /// Terminal **link** to an inner root trace — the mahina analogue of LuaJIT's
    /// `LJ_TRLINK_ROOT`. Emitted *instead of* `.loop` to close a *continuation*
    /// trace (one anchored at a non-header exit pc, recording the outer body) when,
    /// going forward, it re-reaches an inner numeric-`for`'s `for_prep` whose loop
    /// header **already has a root trace**. The recorder records `for_prep`'s
    /// entry state (`R[a] = init`, `R[a+3] = init`) as the final hand-off snapshot,
    /// then this terminator hands control to the inner root anchored at `aux` (a
    /// bytecode pc in the *same* proto — replay-safe, never a pointer). Carries no
    /// operand refs (`a`/`b` unused). Structurally a terminal exactly like `.loop`:
    /// exactly one, last in the trace, with the φ block immediately preceding it as
    /// the register hand-off snapshot.
    ///
    /// Phase 3 tier-1a flushes the snapshot and follows the link through
    /// `driveChain`; Phase 4 lowers it to a native-to-native chain. Appended last
    /// so every prior op's wire ordinal stays stable.
    link,

    // ---- builtin recording breadth (doc 23, arc A) ----------------------------
    /// `a`=table value ref → the table's `#t` border via the exact fast case
    /// (doc 23 D3): produces `max(asize − 1, 0)` (`.int`), side-exiting unless
    /// *hash.count == 0 ∧ the array lane keeps a presence bitmap ∧ (asize ≤ 1 ∨
    /// present(asize−1))* — under exactly those premises `Table.length()` returns
    /// `asize − 1` with no trim/hash search (key 0 never participates, doc 18),
    /// so the fast case is exact, not approximate. A **guarded producer** like
    /// `int_of_float`: it stamps its exit PC in `aux` (see `emit`) and appears in
    /// `guardExitPc`/`isSideExitGuardOp`. The general border search (trailing
    /// holes, hash borders, grids, in-band `.value`/`.boolean` lanes) stays
    /// tier-0 behind the side-exit. Alias discipline is `aload`-like — never
    /// CSE'd/hoisted across stores. Pending SUNK stores are fine to record past
    /// (doc 24 D7): sunk stores are in-bounds-only (`asize` invariant), presence
    /// only goes false→true, and `alen` side-exits with the stores un-executed —
    /// so a pre-flush read either matches the post-flush border or exits cleanly.
    /// Appended last (wire ordinal 57).
    alen,
    /// `a`=float operand ref → `sin(a)` (`.float`). A leaf pure producer like
    /// `fsqrt` — hoistable iff invariant, CSE'd, DCE'd if dead, deliberately
    /// NEVER constant-folded (no compile-time transcendental: fold-vs-runtime
    /// last-ulp divergence is exactly what the shared kernel exists to kill).
    /// All tiers evaluate it through the ONE `fmath.sinRuntime` body — tier-1a
    /// calls it, native calls out to the same pointer (doc 23 D4) — so the op
    /// is bit-identical everywhere by construction. Wire ordinal 58.
    fsin,
    /// `a`=float operand ref → `cos(a)` (`.float`). Exactly `fsin`'s contract
    /// with `fmath.cosRuntime`. Wire ordinal 59.
    fcos,

    // ---- deterministic on-trace allocation (doc 24, arc B) --------------------
    //
    // The first ops that ALLOCATE on trace: interned-string producers. Allocation
    // events are effects on the serialized id stream (`next_obj_id` is a
    // byte-compared keyframe field), so `.alloc`-kind ops are never DCE'd, never
    // hoisted, and never reordered across each other or across `guard_gc` — see
    // doc 24 D2/D4 and `tropt.kindOf`. Every allocating body is protected by ONE
    // `guard_gc` entry guard emitted before its first `.alloc` op.
    //
    /// `a`=proven-int operand ref → the interned decimal rendering of the int
    /// (`ty = .heap`, an interned `String`). All tiers run the ONE
    /// `stralloc.tostrIntRuntime` body (`io.writeValue` render + `Heap.intern`)
    /// — the exact pair tier-0's `bToString` composes — so the result is
    /// byte-identical everywhere by construction. `__tostring` is statically
    /// impossible (non-heap values carry no metatable). Fallible: on OOM the
    /// helper performed NO `Heap.link` (intern is transactional), the trace
    /// side-exits at the header, and tier-0's replay re-raises the same OOM at
    /// the same logical point (doc 24 D5). Wire ordinal 60.
    tostr_int,
    /// `a`=proven-float operand ref → the interned rendering of the float.
    /// Exactly `tostr_int`'s contract over `Value.float`. Wire ordinal 61.
    tostr_num,
    /// `a`=proven-string ref → `#s` (`.int`): the string's cached `cp_len`
    /// (code points, NOT bytes — the `#s` semantic, distinct from `rawlen`).
    /// A pure leaf producer (allocates nothing): CSE/DCE fine, deliberately
    /// never constant-folded (its operand is never a konst in an honest trace —
    /// the recorder folds `#` of a konst string directly). Wire ordinal 62.
    slen,
    /// `a`=value ref → the value is a heap string. Pins an *observed* string
    /// operand (a loaded slot) where the producer doesn't already prove it
    /// (`tostr_*`/future snew-class results are proven by construction and skip
    /// this). Produces no value; never DCE'd. Classified `.guard`; carries no
    /// `aux` (NOT exit-PC-chaining — like `guard_table`). Wire ordinal 63.
    guard_string,
    /// The doc 24 D3 allocation-budget entry guard; `aux` = the trace's static
    /// allocation bound `A` (each `.alloc` op performs at most one `Heap.link` —
    /// the D5 audit rule). Passes ⇔ `!gc_stress ∧ object_count + A < next_gc`
    /// (saturating): passing makes a mid-burst collection arithmetically
    /// impossible in every mode, so loop-header re-entry deopt stays sound and
    /// the tier-0 id stream is reproduced exactly (D2). Failing exits at the
    /// coherent loop header with ZERO allocations performed this iteration.
    /// Emitted ONCE per allocating body, before its first `.alloc` op; `aux` is
    /// stamped by `commit()`. Deliberately NOT in `guardExitPc` /
    /// `isSideExitGuardOp` (`aux` is a bound, not a PC): every exit-PC-keyed
    /// consumer — side-trace hotguard counting, exit chaining, Option-A
    /// headroom — therefore ignores it, which is exactly the doc 24 D3 chaining
    /// discipline (a side trace anchored at a budget failure would just be the
    /// same loop again). Produces no value; never DCE'd/deduped/hoisted.
    /// Wire ordinal 64.
    guard_gc,
    /// The snew class (doc 24 D4, c3): allocating string TRANSFORMS. Each is a
    /// callout to the ONE heap-only core in `stdlib/string.zig`
    /// (`subCore`/`reverseCore`/`char1Core`/`rep2Core`) that tier-0's natives
    /// wrap — bytes, interned object, and allocation count are tier-identical
    /// by construction. All are `.alloc` roots (never DCE'd/hoisted/reordered)
    /// and — unlike `tostr_*` — NEVER CSE'd (codex #8: they allocate host
    /// scratch before interning; eliding a repeat would remove a fallible
    /// operation tier-0 performs). On OOM no `Heap.link` happened (scratch
    /// fails first; intern is transactional): side-exit, tier-0 replays.
    ///
    /// `ssub`: `string.sub(s, i, j)` — `a` = proven-string ref, `b` = start
    /// (proven-int) ref, and **`aux` = the end (proven-int) ref** — the third
    /// operand rides `aux` as a Ref (codex #4: `IrInstr` has no third operand
    /// field; `assertWellFormed` pins it). A 2-arg `sub` records `aux` as a
    /// konst −1 (the tier-0 default). Clamping semantics — never errors.
    /// `ty = .heap`. Wire ordinal 65.
    ssub,
    /// `srev`: `string.reverse(s)` — `a` = proven-string ref, `ty = .heap`.
    /// Wire ordinal 66.
    srev,
    /// `schar1`: 1-argument `string.char(c)` — `a` = proven-int ref,
    /// `ty = .heap`. The variadic shape stays a recording abort (no operand
    /// vector encoding). An out-of-range `c` (tier-0 would raise) side-exits
    /// with no allocation; tier-0's replay raises the located error.
    /// Wire ordinal 67.
    schar1,
    /// `srep2`: 2-argument `string.rep(s, n)` — `a` = proven-string ref,
    /// `b` = proven-int count ref, `ty = .heap`. The separator shape aborts
    /// (pinned arity, codex #4). `n <= 0` interns the empty string; a
    /// pathological `n` OOMs in scratch (before any link) and side-exits.
    /// Wire ordinal 68.
    srep2,
    /// `supper`: `string.upper(s)` (doc 26) — `a` = proven-string ref,
    /// `ty = .heap`. Snew class: full Unicode simple case mapping through the
    /// ONE shared `caseCore`, heap-only on trace (the Unicode-version pin is a
    /// committed-trace invariant, doc 26 D1 — a trace containing this op sets
    /// `Trace.requires_unicode_pin`). Scratch OOM → null → side-exit before
    /// any link. Wire ordinal 69.
    supper,
    /// `slower`: `string.lower(s)`, ditto `supper`. Wire ordinal 70.
    slower,
    /// `scp`: single-result `string.codepoint(s, i, j)` (doc 26 D3) —
    /// `a` = proven-string ref, `b` = start ref, `aux` = end ref (the ssub
    /// three-operand encoding; **`aux` is an operand ref, NEVER a PC** — this
    /// op must stay out of `guardExitPc`-class accessors), `ty = .int`. PURE
    /// and non-allocating (kind `.pure3`): full `posRelat` wrap + clamp via
    /// the shared `codepointCore`; an empty range side-exits (tier-0 replays
    /// to nil). Wire ordinal 71.
    scp,

    // ---- doc 30: pattern-engine + string→number callouts ----
    //
    // The match ops write the per-VM `Heap.match_scratch`; the projection ops
    // read it. Every failure crosses the shim ABI as a negative status
    // (`stdlib/string.zig` `MatchStatus`, doc 30 M03) and side-exits as an
    // ORDINARY unchainable header-replay exit — none of these ops join
    // `guardExitPc`/`isSideExitGuardOp` (their `aux` is an operand or an
    // immediate, NEVER a PC — doc 30 M02, pinned by the accessor tests).

    /// `sfindp`: plain-substring `string.find` (the no-specials bypass) —
    /// `a` = proven-string subject, `b` = init ref, `aux` = pattern ref (the
    /// scp/ssub ternary encoding). `ty = .int`: the matched 1-based char
    /// index (>= 1); negative → side-exit. The END index is recorder
    /// arithmetic (`start + cpLen(pat) − 1`, konst-folded), not a result.
    /// PURE (`.pure3`), heap-free, no scratch. Wire ordinal 72.
    sfindp,
    /// `smatch`: pattern locate + scratch fill (find/match flavor) —
    /// `a` = proven-string subject, `b` = init ref, `aux` = pattern ref.
    /// `ty = .int`: the status channel (0 = matched, projections may read
    /// scratch; negative → side-exit). Side-effecting producer
    /// (`.scratch3`): never DCE'd/CSE'd/hoisted/folded/reordered — the
    /// scratch write is the projections' data source. Wire ordinal 73.
    smatch,
    /// `sgmatch` (doc 30 §6): ONE composite gmatch-iterator step —
    /// `a` = state-table ref, `b` unused, `aux` = **konst-pool id of the
    /// record-time pattern** (an IMMEDIATE, never walked as a ref —
    /// `.scratch1k`). The shim verifies the pattern identity and the B03
    /// slot-3 layout, then locates from the stored pos READ-ONLY (the pos
    /// advance is `sgm_setpos`) and fills scratch incl. `slot_next_pos`.
    /// `ty = .int` status. Wire ordinal 74.
    sgmatch,
    /// `scap_int`: non-allocating scratch projection — `a` = the match op's
    /// ref (data dependence), `b` = SLOT IMMEDIATE (never remapped).
    /// `ty = .int`. Native lowering is a direct load from a baked absolute
    /// scratch address; no call, no exit path; requires the heap context
    /// (doc 30 M05). Kind `.proj`: DCE'd when unused, never CSE'd/hoisted.
    /// Wire ordinal 75.
    scap_int,
    /// `scap_str`: allocating scratch projection — `a` = match ref, `b` =
    /// slot immediate, `ty = .heap`: interns the span (≤1 link; null=OOM →
    /// side-exit, the snew protocol). Kind `.alloc_proj` (round-2 M02): an
    /// alloc ROOT (a dead one is still executed — the id stream is the
    /// observable, doc 24:140) with `.proj` operand shape. Emitted for
    /// EVERY string capture tier-0 materializes, in capture order,
    /// regardless of the caller's result window (doc 30 B02).
    /// Wire ordinal 76.
    scap_str,
    /// `str2num_i`: `tonumber(string)`, int direction — `a` = proven-string
    /// ref, `ty = .int`. The shim returns `{status, value}` (rax:rdx); a
    /// status ≠ int (nil or float) side-exits (kind honesty). Unary pure
    /// producer: DCE admitted (removing a dead parse removes only its
    /// kind-honesty exit — sound), CSE/LICM excluded fail-closed.
    /// Wire ordinal 77.
    str2num_i,
    /// `str2num_f`: ditto, float direction. `ty = .float`. Wire ordinal 78.
    str2num_f,
    /// `sgm_setpos` (doc 30 §6): the gmatch cursor commit — `a` = state ref,
    /// `b` = new-pos ref. A DEFERRED STORE on the docs-07/08 sinking
    /// discipline: sunk below every guard of the iteration, just before
    /// `.loop`, so any exit replays tier-0 against the UN-advanced pos and
    /// reproduces the same token (round-2 B01). Writes the int payload into
    /// the B03-verified `.value`-lane array cell; the shim re-verifies and a
    /// layout change side-exits (defensive; unreachable under the recorder's
    /// pins). Never DCE'd, never reordered. Wire ordinal 79.
    sgm_setpos,
    /// `guard_sid` (doc 30 §2a): the interned-identity pin for an OBSERVED
    /// (non-konst) find/match pattern — `a` = string ref (a dominating
    /// string proof is required — `guard_string` or a proven producer),
    /// `aux` = **konst-pool id** of the expected string (never a raw
    /// pointer; the native emitter resolves the konst to its address at
    /// compile time). Equal bytes ⇔ same object within a heap, so identity
    /// is a pointer compare. `aux` IS semantic identity → joins
    /// `guardKeyAux` (round-2 M01). NOT in `guardExitPc` /
    /// `isSideExitGuardOp` (aux is a konst id, not a PC). Wire ordinal 80.
    guard_sid,

    // -- rounding builtins (float→int); extends doc 23's recorded-builtin set.

    /// `math.floor(x)`: `@floor` + convert to `i64`. Operand: a proven
    /// numeric ref (float or int — an int operand is promoted to float).
    /// Result type: `.int`. Side-exits on out-of-range / NaN / inf (tier-0
    /// replays and raises TypeError). Wire ordinal 81.
    ffloor,
    /// `math.ceil(x)`: `@ceil` + convert to `i64`. Same contract as `ffloor`.
    /// Wire ordinal 82.
    fceil,

    // ---- closed-cell upvalue access (doc 43 P5) -------------------------------
    //
    // The mirror of `href`/`hload`/`hstore` for a CLOSED upvalue cell's owned
    // `Value` slot. The entry seeder resolves `&cell.loc.closed` (a `*Value`,
    // never serialized) into the synthetic slab slot `uref.aux`, after proving
    // the cell CLOSED and every access path of the alias class agreeing on one
    // cell (`InputSeed.kind == .upvalue_cell`); a failed resolution DECLINES the
    // whole entry to tier-0 (`.next_candidate`) — there are no operands to
    // re-derive the cell from, so no tier-1a downgrade exists (unlike
    // `hash_cell`). A closed cell can never re-open and the GC is non-moving,
    // so the pointer is stable for the episode with NO per-iteration
    // structural guard (the `guard_hash` analogue is unnecessary).
    //
    /// `aux` = the synthetic slab slot holding the seeded `*Value` cell pointer
    /// (tagged `.int` so a GC scan of the dead scratch never mistakes it for a
    /// header). One `uref` per alias class — the recorder keys classes on the
    /// OBSERVED `*Upvalue` at record time. Carries no usable guest `Value`
    /// (tier-1a logs nil, like `href` — a raw pointer must never enter the exec
    /// log). Classified `.aref` (memory token, canonical-to-self); native kind
    /// is the seeded cell pointer (`Kind.href`). Wire ordinal 83.
    uref,
    /// `a` = `uref` ref → load the cell's tagged `Value`, fused tag exit per the
    /// recorded `ty` (int/float/bool — v1 routes only scalar-observed reads
    /// through cells). The `hload` twin: tier-1a tag-checks before logging;
    /// native `cmp byte [cell], TAG_*` + payload load. Classified `.aload`
    /// (never folded/CSE'd across the store class). Wire ordinal 84.
    uload,
    /// `a` = `uref` ref, `b` = value ref → overwrite the closed cell's `Value`
    /// in place (tag + payload). SCALAR values only in v1 (int/float/bool —
    /// recorder-enforced), which sidesteps the native write-barrier ABI (the
    /// barrier is only meaningful for heap values; today it is a no-op
    /// everywhere). Follows the C1 store-sink discipline of `hstore` (deferred
    /// below every guard when the trace has a prior heap load). Effectful;
    /// never DCE'd. Classified `.astore`. Wire ordinal 85.
    ustore,

    // ---- one-shot trace terminator (doc 44 P0) --------------------------------

    /// Terminator of a HEAD-anchored (function-entry) trace — the one-shot
    /// shape: the trace covers the body up to (never including) a depth-0
    /// `ret` or a depth-0 direct self-`call`, then hands back to tier-0,
    /// which resumes AT that instruction and executes it exactly once.
    /// `a` = `TerminalKind` ordinal (`trace_code.TerminalKind`:
    /// return_interp / self_call_interp); `aux` = the real resume bytecode
    /// pc. No operands; like `.loop`/`.link` it must be the last
    /// instruction, and only kind-`.head` traces may carry it
    /// (`assertWellFormed`). A SUCCESSFUL terminal exit is NOT a side
    /// exit: it publishes end-of-trace state (sunk stores flushed exactly
    /// once — the terminator never ran in-trace, so C1 idempotence holds)
    /// and bypasses guard-hotness/side-trace/chaining accounting entirely
    /// (doc 44 D5). Guard FAILURES in a head trace deopt to the
    /// function-entry snapshot at pc 0, never to the terminal. Wire
    /// ordinal 86.
    terminal,
};

/// Doc 44: what a `.terminal` hands back to tier-0 (rides `terminal.a`).
/// The `_interp` suffix is deliberate — P0's staged model has tier-0 execute
/// the terminating instruction; Phase 4's native frame push will add
/// native-resuming kinds alongside, not replace these.
pub const TerminalKind = enum(u16) {
    /// The trace ends at a depth-0 `ret`: tier-0 resumes at the ret pc
    /// (terminal.aux) and performs the actual return.
    return_interp = 0,
    /// The trace ends at a depth-0 direct self-`call` (the up-recursion
    /// analogue, staged): tier-0 performs the call; the callee's patched
    /// head re-enters the trace.
    self_call_interp = 1,
};

/// Sentinel `phi.aux` for an *internal* φ (strength-reduction accumulator) that
/// flushes to no tier-0 register. A slot-bound φ stores its register index (≥ 0).
pub const PHI_INTERNAL: i32 = -1;

/// One IR instruction. `a`/`b` are operand `Ref`s (or unused); `aux` carries a
/// slot index (`slot_load`) or const-pool index (`konst`); `ty` is the inferred
/// result / guarded type; `snap` is the deopt-snapshot index for guards.
pub const IrInstr = struct {
    op: IrOp,
    a: Ref = 0,
    b: Ref = 0,
    aux: i32 = 0,
    ty: ObsType = .unknown,
    snap: SnapIdx = 0,
};

/// The **post-increment resume/exit PC** recorded in a guard's `aux`, or null if
/// this op doesn't carry one. ONLY the SIX ops
/// `guard_int/float/number/true/false` + `int_of_float` stamp their recording PC
/// into `aux` (see `emit`); the array guards (`guard_lane`, `guard_fits`) reuse
/// `aux` for lane ordinals, and the rest leave it zero — so reading `aux` as a PC
/// there is a category error that can mis-key a guard-failure counter or, worse,
/// chain to an unrelated trace. Exit-PC chaining (`driveChain`) and guard-failure
/// counting MUST resolve the exit PC through this accessor — never read `.aux`
/// directly. This is the *resume/exit* PC (the fall-through / continuation
/// target), NOT the source-opcode index — for the latter use `guardSourcePc`.
/// Returns the PC for the six PC-carrying guards (which may legitimately be 0);
/// callers treat 0 as "no usable PC" since no loop-body guard sits at PC 0.
pub fn guardExitPc(ins: IrInstr) ?u32 {
    return switch (ins.op) {
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float, .alen => @intCast(ins.aux),
        else => null,
    };
}

/// Every IR op whose runtime failure side-exits the trace — i.e. an exit that a
/// SIDE TRACE could absorb by recording the alternate shape. This is the Option-A
/// discriminator (see `accountLegacyThrash`): zero progress through one of these
/// is side-trace evidence, not thrash.
pub fn isSideExitGuardOp(op: IrOp) bool {
    return switch (op) {
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float, .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits, .guard_append, .guard_func, .guard_hash, .guard_builtin, .guard_grid, .guard_stride, .guard_gcol, .guard_gpresent, .alen => true,
        else => false,
    };
}

/// Whether a trace actually entered its body or refused in its hoisted native
/// prologue. `exit_instr` is overloaded and cannot identify a refusal.
pub const ChargeKind = enum { entered, entry_refusal };

/// The **source-opcode PC** (guest bytecode index) that OWNS a guard — the single
/// canonical definition of "which bytecode op does this guard belong to", i.e. the
/// `source_pc` a future `GuardProvenance` tag keys on (doc 17, H-1b). Distinct in
/// *meaning* from `guardExitPc` (the post-increment resume/exit PC): every guard is
/// recorded with `aux = source_pc + 1` because the tier-0 fetch advances the PC by
/// exactly one fixed-width `Instr` before the recording mirror runs and jumps are
/// applied only *after* recording (`interp.zig` `step`), so the source opcode is the
/// slot immediately before the exit PC. Returns null exactly when `guardExitPc`
/// does (non-PC-carrying op, or the 0 sentinel). Callers that previously derived the
/// source opcode as `code[guardExitPc(g).? - 1]` MUST route through this accessor so
/// the "+1" fetch convention has one owner, not eight open-coded copies.
pub fn guardSourcePc(ins: IrInstr) ?u32 {
    const exit_pc = guardExitPc(ins) orelse return null;
    return if (exit_pc == 0) null else exit_pc - 1;
}

/// A loop-carried writeback: at the back-edge, tier-0 register `slot` holds the
/// value produced by IR `ref`. The set of these is the trace's exit snapshot —
/// what a future executor copies back into the register file each iteration.
pub const SlotStore = struct { slot: u16, ref: Ref };

/// Write one IR instruction in a fixed columnar form (no trailing newline).
pub fn writeIrInstr(w: *io.Writer, ins: IrInstr) io.Writer.Error!void {
    try w.print("{s:<13}", .{@tagName(ins.op)});
    switch (ins.op) {
        .slot_load => try w.print("r{d}", .{ins.aux}),
        .konst => try w.print("k{d}", .{ins.aux}),
        .neg,
        .not,
        .bnot,
        .guard_int,
        .guard_float,
        .guard_number,
        .guard_true,
        .guard_false,
        .aload,
        .guard_table,
        .guard_lane,
        .guard_bounds,
        .guard_present,
        .guard_fits,
        .int_of_float,
        .guard_func,
        .fsqrt,
        .alen,
        .fsin,
        .fcos,
        .ffloor,
        .fceil,
        .tostr_int,
        .tostr_num,
        .slen,
        .guard_string,
        .srev,
        .schar1,
        .supper,
        .slower,
        => try w.print("%{d}", .{ins.a}),
        // guard_gc's aux is the allocation bound, not an operand.
        .guard_gc => try w.print("A={d}", .{ins.aux}),
        // ssub's third operand rides aux as a ref (codex #4); scp shares the
        // encoding (doc 26 D3), as do doc 30's sfindp/smatch.
        .ssub, .scp, .sfindp, .smatch => try w.print("%{d}  %{d}  %{d}", .{ ins.a, ins.b, ins.aux }),
        // Doc 30: sgmatch reads the state `%a` and pins the pattern konst id.
        .sgmatch => try w.print("%{d}  pat=k{d}", .{ ins.a, ins.aux }),
        // Projections: match ref + slot immediate.
        .scap_int, .scap_str => try w.print("%{d}  [{d}]", .{ ins.a, ins.b }),
        .str2num_i, .str2num_f => try w.print("%{d}", .{ins.a}),
        .sgm_setpos => try w.print("%{d}  pos=%{d}", .{ ins.a, ins.b }),
        // Closed-cell upvalue access (doc 43 P5): uref renders its seed slot,
        // uload its cell token, ustore cell + value.
        .uref => try w.print("r{d}", .{ins.aux}),
        .uload => try w.print("%{d}", .{ins.a}),
        .ustore => try w.print("%{d}  %{d}", .{ ins.a, ins.b }),
        // guard_sid: operand + the expected string's konst id.
        .guard_sid => try w.print("%{d}  sid=k{d}", .{ ins.a, ins.aux }),
        // `guard_builtin` reads the callee `%a` and tags the builtin in `aux`.
        .guard_builtin => try w.print("%{d}  [{s}]", .{ ins.a, @tagName(@as(function.RecordedBuiltin, @enumFromInt(ins.aux))) }),
        .loop, .preheader => {},
        // `.link` (doc 15): terminal hand-off; `aux` is the inner root's anchor pc.
        .link => try w.print("-> {d}", .{ins.aux}),
        // `.terminal` (doc 44): one-shot close; kind tag + resume pc.
        .terminal => try w.print("{s} @ {d}", .{ @tagName(@as(TerminalKind, @enumFromInt(ins.a))), ins.aux }),
        // φ: a slot-bound φ prints `update=%b → r{slot}` (init is implicit
        // `regs[slot]`); an internal φ prints `init=%a update=%b → internal`.
        // Doc 39: a peeled trace's slot-bound φ may carry `a` = the slot's
        // internal (steady-state) φ ref; print it as `steady=%a` so peel
        // associations are visible in dumps.
        .phi => {
            if (ins.aux == PHI_INTERNAL) {
                try w.print("init=%{d} update=%{d} -> internal", .{ ins.a, ins.b });
            } else if (ins.a != 0) {
                try w.print("update=%{d} -> r{d} steady=%{d}", .{ ins.b, ins.aux, ins.a });
            } else {
                try w.print("update=%{d} -> r{d}", .{ ins.b, ins.aux });
            }
        },
        else => try w.print("%{d}  %{d}", .{ ins.a, ins.b }),
    }
}

/// Test helper: splice slot-bound `phi` nodes for a `carry` spec (tier-0 register
/// `slot` ← body update `ref`) into a `body` that ends in `.loop`, placing them
/// just before the terminator. This mirrors exactly what `commit()` builds, so
/// hand-built test traces (in `nativegen`/`irinterp`/`interp`) can keep expressing
/// loop carry as a `SlotStore` list. Body refs are *stable* — only `loop` shifts
/// down by `carry.len`, and nothing references `loop` by index, so every operand
/// ref in `body` stays valid.
///
/// `body` / `carry` are `*const [N]…` (pointers to fixed-size arrays): the array
/// *lengths* are comptime (so the return type is a sized array) while the element
/// *values* may be runtime — tropt's tests build instrs with a runtime `op`.
pub fn withPhis(
    body: anytype,
    carry: anytype,
) [
    @typeInfo(@typeInfo(@TypeOf(body)).pointer.child).array.len +
        @typeInfo(@typeInfo(@TypeOf(carry)).pointer.child).array.len
]IrInstr {
    const nbody = @typeInfo(@typeInfo(@TypeOf(body)).pointer.child).array.len;
    const ncarry = @typeInfo(@typeInfo(@TypeOf(carry)).pointer.child).array.len;
    const last = nbody - 1;
    std.debug.assert(body[last].op == .loop);
    var out: [nbody + ncarry]IrInstr = undefined;
    for (0..last) |i| out[i] = body[i];
    for (carry, 0..) |st, j| {
        // Slot-bound φ: implicit init (`regs[slot]`, so `a` = 0), update `b`.
        out[last + j] = .{ .op = .phi, .a = 0, .b = st.ref, .aux = @intCast(st.slot), .ty = body[st.ref].ty };
    }
    out[last + ncarry] = .{ .op = .loop };
    return out;
}
