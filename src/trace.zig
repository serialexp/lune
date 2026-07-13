//! Trace recorder + trace IR — the heart of the JIT (Phase 5).
//!
//! A tracing JIT works by watching tier-0 execute, noticing when a loop runs
//! *hot*, and **recording** one iteration of that loop into a linear,
//! single-assignment IR specialised to the types it actually observed. Later
//! tiers (Phase 6: IR-interpreter; Phase 8: native codegen) *execute* that IR;
//! this module only **records** it. Recording is deliberately *transparent* —
//! tier-0 still performs every operation, so a program's observable behaviour is
//! identical whether the recorder is on or off. That invariant is the recorder's
//! decisive correctness test (`interp.zig`, the `expectProgram` matrix).
//!
//! Two pieces live here:
//!   * the **trace IR** — `IrOp`/`IrInstr`/`Trace`, plus a disassembler. This is
//!     the cache-sensitive representation the architecture reserves for the JIT
//!     (docs/design/00-architecture.md §Value representation), kept separate from
//!     the tier-0 bytecode (`bytecode.zig`).
//!   * the **recorder** — `TraceState` (hotness counters, the trace cache, and
//!     the in-progress `Recorder`) and its state machine (`onBackEdge`).
//!
//! Policy is set by docs/design/01-trace-lifecycle.md. Phase 5a (this increment)
//! lands hotness detection, recording with type guards, and the abort policy;
//! executing traces, deopt/side-exit restore, blacklist backoff, side traces, and
//! cache invalidation are later phases (named there, not built here).

const std = @import("std");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");

// ---------------------------------------------------------------------------
// Trace IR
// ---------------------------------------------------------------------------

/// An SSA value reference: an index into a trace's `instrs` array. Every IR
/// instruction defines exactly one value, named by its position.
pub const Ref = u16;

/// Index into the (future) per-guard snapshot table. A placeholder in Phase 5a —
/// the field exists from day one so the deopt machinery (Phase 6) is a body to
/// fill in, not a schema change. See docs/design/01-trace-lifecycle.md.
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
    // A `recCall` to a native flagged `PureBuiltin` (e.g. `math.sqrt`) is inlined
    // as a dedicated leaf producer instead of aborting `.host_barrier`. The trace
    // bakes in "callee is this builtin"; `guard_pure` re-proves that identity, and
    // the producer (`fsqrt`) computes the result directly from its float operand.
    //
    /// `a` = the callee value ref (a once-seeded loop-invariant upvalue/global),
    /// `aux` = `@intFromEnum(PureBuiltin)`. Side-exits to tier-0 unless the runtime
    /// callee is still a `.native` carrying exactly this `pure` tag — so a reassigned
    /// `sqrt` upvalue deopts on the same iteration in both the oracle and native.
    /// The callee is a once-seeded synthetic input, so the value is loop-invariant
    /// and the guard is a candidate for LICM (like `guard_func`); the current pass
    /// does NOT hoist guards (re-checking an invariant value each iteration is cheap
    /// — see `tropt`'s LICM note), so today it re-checks per iteration. Produces no
    /// value; never DCE'd. Classified `.guard`.
    guard_pure,
    /// `a` = the float argument ref → the pure-builtin result. v1 is `sqrt` only:
    /// the oracle computes `Value.float(@sqrt(arg))` and native lowers to a single
    /// `sqrtsd` (both IEEE correctly-rounded, bit-identical under the default MXCSR).
    /// A leaf unary producer: it cannot itself side-exit — its operand's preceding
    /// `guard_float` pins the arg type. `ty` is always `.float`. Classified `.unary`
    /// (NOT a constant-folder input — see doc 12 / `tropt`).
    fsqrt,

    // ---- arithmetic right shift (`~>>`, lune syntax extension) ----------------
    /// `a` = value ref, `b` = count ref → arithmetic (sign-extending) right shift,
    /// the `~>>` operator. The bitwise-group analogue of `shr`/`shl`: both operands
    /// guarded `.int` upstream, 64-bit width like the rest of lune's integer
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
    /// Terminal **link** to an inner root trace — the lune analogue of LuaJIT's
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

/// The bytecode PC recorded in a guard's `aux`, or null if this op doesn't carry
/// one. ONLY `guard_int/float/number/true/false` stamp their recording PC into
/// `aux` (see `emit`); the array guards (`guard_lane`, `guard_fits`) reuse `aux`
/// for lane ordinals, and the rest leave it zero — so reading `aux` as a PC there
/// is a category error that can mis-key a guard-failure counter or, worse, chain
/// to an unrelated trace. Exit-PC chaining (`driveChain`) and guard-failure
/// counting MUST resolve the exit PC through this accessor — never read `.aux`
/// directly. Returns the PC for the five PC-carrying guards (which may legitimately
/// be 0); callers treat 0 as "no usable PC" since no loop-body guard sits at PC 0.
pub fn guardExitPc(ins: IrInstr) ?u32 {
    return switch (ins.op) {
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float => @intCast(ins.aux),
        else => null,
    };
}

/// Whether IR instruction `idx` of `t` is a numeric-for loop-done guard: a
/// `guard_true` whose deopt PC lands immediately after a `for_loop` bytecode op.
/// Mirrors nativegen's `isNumericForLoopDoneGuard`, kept here so the arming side can
/// enforce the P-C option (b) invariant (2.3c-0a) without reaching into codegen.
/// Returns before touching `t.anchor` when `idx` is out of range, so it is safe on
/// synthetic traces with an undefined anchor and empty `instrs`.
pub fn isLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    if (idx >= t.instrs.len) return false;
    const g = t.instrs[idx];
    if (g.op != .guard_true) return false;
    const exit_pc = guardExitPc(g) orelse return false;
    if (exit_pc == 0 or exit_pc > t.anchor.proto.code.len) return false;
    return t.anchor.proto.code[exit_pc - 1].op == .for_loop;
}

/// Caller-declared intent for `armNativeLink`, enforcing the P-C option (b) invariant
/// (doc 17, 2.3c-0a): a numeric-for loop-done guard's `slot[ei]` is EXCLUSIVELY its
/// linked-materialized exit. So only a `.loop_done_linked` arm may target a loop-done
/// guard slot, and conversely `.link_terminal` / `.ordinary_guard` arms must never
/// land on one (a loop-done ordinary deopt reaches `shared_exit` through the memory-
/// staged `NativeResult.exit_target`, never through `slot[ei]`).
pub const ArmKind = enum {
    /// `.link`-terminal handoff (2.3b-1). The terminal is a `.link` op, never a guard.
    link_terminal,
    /// Ordinary source-branch guard slot (2.3c-1). Must not be a loop-done guard.
    ordinary_guard,
    /// The loop-done linked-materialized exit (2.3c-2). Must be a loop-done guard.
    loop_done_linked,
};

/// A loop-carried writeback: at the back-edge, tier-0 register `slot` holds the
/// value produced by IR `ref`. The set of these is the trace's exit snapshot —
/// what a future executor copies back into the register file each iteration.
pub const SlotStore = struct { slot: u16, ref: Ref };

/// Result of an exit-PC chain attempt. Ordinary same-loop side traces resume at
/// the caller's current loop header (`resume_pc == null`). Nested-loop link
/// chains consume a post-inner-loop continuation and therefore resume tier-0 at
/// that continuation anchor when the bounded chain yields back.
pub const ChainResult = struct {
    completed: usize,
    resume_pc: ?u32 = null,
};

/// The execution tier a chain drive uses for the candidate traces it enters.
/// Chosen at each dispatcher call site (comptime), NOT per-candidate:
///   * `.ir`          — run candidates on the tier-1a IR interpreter. Used by the
///                      ordinary zero-exit chain and the tier-1a loop-done chain.
///   * `.native_only` — run candidates as native compiled code; a candidate with
///                      no native compilation ends the drive (never silently
///                      tier-1a). Used by the native loop-done chain.
/// See `docs/design/16-coherent-state-chaining.md`.
pub const ChainTier = enum { ir, native_only };

/// How the *failed* trace left the register file when it side-exited — this fixes
/// where tier-0 must resume if the drive yields, and whether a loop-done commit is
/// still owed before a continuation can run. (Design doc 16, "exit kinds".)
///   * `.ordinary_header`       — an ordinary guard exit; `regs` are coherent at
///                                `failed.anchor.pc` and nothing is owed.
///   * `.ir_numeric_for_done`   — a tier-1a numeric-`for` loop-done exit; the final
///                                iteration's sunk stores + φ hand-off are still in
///                                the carried executor scratch (`[]Value`) and must
///                                be flushed via `flushNumericForLoopDone` before a
///                                continuation runs.
///   * `.native_numeric_for_done` — a native numeric-`for` loop-done exit; the root
///                                was entered with `runLinkedLoopDone`, so the final
///                                iteration is already materialized — no flush owed.
pub const ExitMaterialization = union(enum) {
    ordinary_header,
    ir_numeric_for_done: []Value,
    native_numeric_for_done,
};

/// Identifies a trace anchor: a loop header at byte-`pc` within a `Proto`. Loop
/// headers are the only root-trace anchors in Phase 5a (hot side exits seed side
/// traces later).
///
/// The `proto` pointer is *borrowed*, not owned: a cached `Trace` keeps it live
/// only by assumption. In the VM that holds — a hot proto is reachable from a
/// live closure for as long as code can branch to its loop, so it outlives any
/// trace anchored in it. Tests that free the compiled chunk must therefore do so
/// *after* inspecting the cache (see `interp.zig`'s `runForTrace`). When cache
/// invalidation lands (a later phase) this is where proto liveness gets pinned
/// down properly.
pub const AnchorKey = struct { proto: *const Proto, pc: u32 };

/// Per-anchor cooldown record for the gate (`TraceState.gate`). An anchor that
/// thrashed (low-yield penalty maxed) or could not be traced (abort / commit
/// failure) is held off until its back-edge counter reaches `retry_at`. On the
/// retry it is given one more chance; a re-failure calls `gateAnchor` again,
/// which doubles `window` (capped at `config.backoff_max`) and bumps `strikes`.
/// At `config.max_strikes` the anchor is abandoned permanently. The schedule is
/// counted in the deterministic global back-edge `tick` (which advances on *every*
/// back-edge, including ones the hot-count pre-filter skips), so the cooldown keeps
/// elapsing while a gated anchor is being cheaply skipped, and is reproducible.
pub const Gate = struct {
    /// Global `tick` value at/after which the anchor becomes eligible again.
    retry_at: u64,
    /// Length of the *next* cooldown window (back-edges); doubles per escalation.
    window: u32,
    /// How many times this anchor has been gated; `>= max_strikes` ⇒ permanent.
    strikes: u32,
};

/// Identifies a guard-failure site: the trace anchor and the bytecode PC of the
/// failing guard instruction (stored in the guard's `aux` field by the per-guard
/// PC recording, step 2).  Used to count how often a specific guard fails, so
/// side-trace recording (step 4) can be triggered at the right threshold.
pub const GuardKey = struct { anchor: AnchorKey, exit_pc: u32 };

/// The kind of type a trace's entry guard enforces on a register.
pub const EntryGuardType = enum(u8) {
    int,
    float,
    number, // accepts both int and float (guard_number)
    table,
};

/// A register and the type it must have for this trace to be entered.
/// Pairs are computed from the trace's IR at commit time and stored as a
/// runtime-only fingerprint — not serialized.
pub const EntryGuard = struct { slot: u16, ty: EntryGuardType };

/// Where a synthetic trace input is resolved from at entry (cross-frame tracing,
/// cluster sub-lever 1). A callee reached through an UPVALUE or GLOBAL is a
/// loop-invariant register value the executor cannot read (it has no `*Vm`, no
/// closure). The recorder snapshots it into a dead slab slot *above* the anchor
/// frame window and reads it as an ordinary `slot_load`; the dispatch loop seeds
/// the slot once per entry (`upvalGet`/`globals.get`) before running the trace.
/// `hash_cell` (doc 11, H1): the loop-invariant **value-cell pointer** of a
/// constant-key field access (`obj.field`). Unlike `upvalue`/`global` it seeds no
/// `slot_load` — the existing `href` op consumes it (via `href.aux == slot`) — and
/// it writes a raw `@intFromPtr(cell)` into the slab payload for the **native** path
/// only; the tier-1a oracle ignores the slot and re-derives the cell from `href`'s
/// `(table,key)` operands each iteration (so H0's IR and exec-log behaviour are
/// frozen). Re-resolved every entry via `Table.fieldPtr`, so — like every seed — no
/// pointer is ever serialized.
pub const InputKind = enum(u8) { upvalue, global, hash_cell };

/// One synthetic entry input the dispatch loop resolves and writes into the slab
/// before trace entry. For `upvalue`/`global`: `source` is the upvalue index
/// (`closure.upvalues[source]`) or the global key's constant-pool index
/// (`proto.constants[source]`); `slot` is the synthetic frame-relative slab slot
/// (== the seeding `slot_load`'s `aux`), always `>= anchor_num_registers`. For
/// `hash_cell` (H1): `source` is the **key**'s constant-pool index, `table_reg` is
/// the anchor slot holding the table value, and `expected_count` is the recorded
/// `hash.count()` (the `guard_hash` aux) the seed re-checks for native eligibility.
/// Runtime-only — not serialized (precedent: `entry_guards`).
pub const InputSeed = struct {
    kind: InputKind,
    source: u32,
    slot: u16,
    /// `hash_cell` only: anchor slot the table value lives in at entry.
    table_reg: u16 = 0,
    /// `hash_cell` only: recorded `hash.count()` — the entry must match it (the
    /// native analogue of the oracle's per-iteration `guard_hash` count check), else
    /// the entry declines native and runs tier-1a (which side-exits at `guard_hash`).
    expected_count: u32 = 0,
};

/// A completed, cached trace: the recorded IR plus the entry/exit snapshots that
/// connect it back to tier-0 register slots. Immutable once committed (Phase 5a
/// never invalidates a cached trace — see the lifecycle doc).
pub const Trace = struct {
    /// Stable, monotonically-assigned identity (P-B, doc 17). Unlike the cache
    /// index (`traceIndex`, which `swapRemove` shuffles), this is assigned once at
    /// finalize from `TraceState.next_trace_id` and NEVER reused — so it can be
    /// baked into native exit code as `final_trace_id` and resolved back via
    /// `traceById` even after unrelated traces retire. Default 0 for hand-built test
    /// traces that never go through finalize (they don't chain, so id collisions are
    /// harmless — the dispatcher's id path only runs for real recorded traces).
    id: u32 = 0,
    anchor: AnchorKey,
    /// The straight-line IR, terminated by a `loop` instruction.
    instrs: []IrInstr,
    /// Constants referenced by `konst` instructions (may include heap values, so
    /// the collector roots these — see `Vm.collect`).
    consts: []Value,
    /// Tier-0 registers read as inputs, in `slot_load` order (the entry snapshot).
    entry_slots: []u16,
    /// Synthetic entry inputs (cross-frame tracing cluster sub-lever 1): each
    /// loop-invariant upvalue/global callee the dispatch loop must resolve and seed
    /// into a dead slab slot above the anchor window before entry. Empty for the
    /// common case (no upvalue/global-reached callee). Runtime-only — not
    /// serialized; freed in `destroy`.
    inputs: []InputSeed = &.{},
    /// Entry type guards extracted from the IR at commit time: for each register
    /// this trace guards on entry, the type it must have.  Used by
    /// `matchesFingerprint` to skip non-matching traces without a trial entry.
    /// Runtime-only — not serialized.
    entry_guards: []EntryGuard,
    /// Tier-1b native-codegen cache (Phase 8): lazily compiled machine code for
    /// this trace, or a terminal `unsupported` verdict. `unattempted` until the
    /// first native dispatch (`TraceState.nativeFor`). Runtime-only — not part of
    /// the serialized trace; the page is freed in `destroy`.
    native: nativegen.NativeState = .unattempted,
    /// Runtime counter: how many times this trace has committed a useful
    /// number of iterations (>= `min_useful`).  Used by `findTrace` to
    /// return the most-successful trace first — a stable frequency-based
    /// priority that does not thrash on alternating types.
    hit_count: u64 = 0,

    /// Free a heap-allocated trace and its arrays.
    pub fn destroy(self: *Trace, gpa: std.mem.Allocator) void {
        self.native.deinit();
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        gpa.destroy(self);
    }

    /// Check whether the current register types match this trace's entry
    /// type guards (the fingerprint).  Returns true if all guarded slots
    /// have the expected type, or if the trace has no entry guards at all
    /// (hand-built test traces, traces without type guards).
    pub fn matchesFingerprint(self: *const Trace, regs: RegWindow) bool {
        for (self.entry_guards) |g| {
            const v = regs.get(g.slot);
            switch (g.ty) {
                .int => if (!v.isInt()) return false,
                .float => if (!v.isFloat()) return false,
                .number => if (!v.isNumber()) return false,
                .table => if (!v.isHeap() or v.heapType() != .table) return false,
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Recorder + trace state
// ---------------------------------------------------------------------------

/// Why a recording was abandoned. Aborting discards the partial trace and leaves
/// tier-0 entirely untouched; the anchor may be retried later (penalty/blacklist
/// backoff is a later increment — see the lifecycle doc). `recordInstr` and the
/// state machine fill these in (Increment B).
pub const AbortReason = enum {
    /// An opcode the recorder does not yet model (tables, globals, concat, …).
    nyi_opcode,
    /// A `call`/`ret`/`halt` — cross-frame tracing is deferred.
    cross_frame,
    /// A host (`native`) call — always a trace barrier (`02-determinism.md`).
    host_barrier,
    /// The trace exceeded `maxrecord` instructions.
    too_long,
    /// An operand had a type the recorder cannot guard/model here.
    bad_type,
    /// An indexed/appended table carries a metatable, so the access may dispatch
    /// a `__index`/`__newindex` metamethod (chunk 2a). Recording aborts: the
    /// metamethod call would be a trace barrier anyway, and a present-slot raw
    /// read/store could silently skip a metamethod on a *later* iteration if the
    /// table's shape changes. Conservative and exact — these tables run tier-0,
    /// which does full metamethod dispatch. Lifting this needs a
    /// `guard_no_metatable` IR op (deferred perf follow-up).
    has_metatable,
    /// Allocation failed while building the trace.
    alloc,
    /// Cross-frame inlining exceeded `max_inline_depth`, or would overflow the
    /// recorder's grown `reg_map` window. Abort rather than panic on an OOB slab
    /// read; tier-0 owns the loop. (Deep/unbounded recursion is Phase 3.)
    too_deep,
};

/// One aggregated abort, accumulated in `TraceState.abort_log` when
/// `config.record_aborts`. Rows are deduped by `(anchor.pc, reason, op)` so a
/// loop that aborts a million times collapses to a single row with a `count` —
/// the diagnostic-friendly shape ("this loop dies on `new_table`, `nyi_opcode`,
/// after 6 IR instrs, N times"). Purely informational; nothing in the tiering
/// path reads it. The `proto` pointer is borrowed (valid while the chunk is
/// alive, which it is when `--dump-aborts` prints, exactly like `--dump-traces`).
pub const AbortRecord = struct {
    /// Loop-header anchor the recording was attempting.
    proto: *const Proto,
    anchor_pc: u32,
    /// Bytecode PC of the instruction that triggered the abort (`rec.cur_pc`).
    abort_pc: u32,
    /// The tier-0 opcode being recorded when the abort fired (`rec.cur_op`).
    op: OpCode,
    /// Why the recording was abandoned.
    reason: AbortReason,
    /// How many IR instructions the partial trace had reached before aborting —
    /// "how far it got" (0 = died on the very first recorded instruction).
    ir_len: u32,
    /// How many times this exact `(anchor, reason, op)` abort recurred.
    count: u64 = 1,
};

/// Tunables for the recorder. Defaults track LuaJIT's where sensible; all are
/// overridable (tests use tiny thresholds, the CLI flips `enabled`).
pub const TraceConfig = struct {
    /// Master switch. Off by default: with this false the VM behaves exactly as
    /// it did before Phase 5 (no counting, no recording, no trace execution). The
    /// CLI `--trace` / `--dump-traces` flags and tests flip it on.
    enabled: bool = false,
    /// Whether cached traces are *executed* by the tier-1a IR-interpreter
    /// (`irinterp.zig`). On by default once `enabled`; tests set it false to get
    /// Phase-5a behaviour (record only, tier-0 executes everything) and isolate
    /// recorder bugs from executor bugs.
    execute: bool = true,
    /// Whether the trace optimizer (`tropt.zig`) rewrites a trace at commit time
    /// (constant folding, CSE, dead-code elimination). On by default; independent
    /// of `execute` (an unexecuted trace can still be optimized for inspection).
    /// Tests set it false to compare optimized vs raw IR and prove transparency.
    optimize: bool = true,
    /// Back-edge count at which a loop header becomes a trace anchor.
    hotloop: u32 = 56,
    /// Maximum IR instructions in one trace before aborting (`too_long`).
    maxrecord: u32 = 2000,
    /// A trace entry that commits at least this many iterations is "doing real
    /// work" and clears the anchor's re-entry penalty. Loops shorter than this per
    /// entry are exactly where a tracing JIT wins nothing, so retiring them to
    /// tier-0 (below) costs ~nothing.
    min_useful: u32 = 8,
    /// Minimum remaining numeric-`for` trip count for a trace *entry* to be worth
    /// it. At a `for_loop` back-edge whose computed remaining iteration count is
    /// below this, the dispatch loop declines to enter the trace and lets tier-0
    /// run the short loop. This keeps a loop that is profitable for some strides
    /// (the inner nsieve loop runs `m/i` times — huge for small `i`) but trivial
    /// for others (1–7 times for large `i`) from gating its shared anchor on the
    /// trivial runs: declining entry means no `onSideExit` penalty, so the
    /// profitable long runs stay traced. Only applies to `for_loop` (a clean,
    /// computable trip count); while/repeat loops are entered as before. Set to 0
    /// to disable. Heuristic — never affects output, only tiering.
    min_trip_entry: u32 = 24,
    /// After this many *low-yield* trace entries (each committing fewer than
    /// `min_useful` iterations) an anchor is gated off so tier-0 owns the loop —
    /// the brake against re-entry thrash on type-unstable / branchy loops.
    max_penalty: u32 = 8,
    /// Gate backoff (replaces the old permanent blacklist). When an anchor is
    /// gated (low-yield penalty maxed, a recording abort, or a commit failure) it
    /// is held off tier-1 for a *cooldown window* measured in back-edges, after
    /// which it is retried once. Each re-failure doubles the window — a
    /// temporarily-unstable loop recovers cheaply, a hopeless one is retried
    /// exponentially less often. The window is keyed on the deterministic
    /// per-anchor back-edge counter, never wall-clock or RNG, so the retry
    /// schedule is reproducible (lune determinism). `backoff_base` is the first
    /// window; it doubles up to `backoff_max`.
    backoff_base: u32 = 128,
    /// Cap on the doubling cooldown window (back-edges).
    backoff_max: u32 = 1 << 16,
    /// After this many gate escalations on one anchor, give up permanently (the
    /// loop has proven hopeless — e.g. a host call in the body that aborts every
    /// recording, or strict alternation no straight-line trace can amortize).
    max_strikes: u32 = 6,
    /// Guard-failure count at which a side trace is recorded for this
    /// `(anchor, exit_pc)` pair.  When a guard at PC X in a trace anchored
    /// at A fails this many times, the next back-edge to A arms a new
    /// recording that captures the alternate path through the loop body.
    hotguard: u32 = 50,
    /// Record a per-trace **execution log** (`execlog.zig`) for the visualizer's
    /// iteration animation. Off by default (zero cost on the JIT path — the executor
    /// is comptime-specialized); the wasm playground flips it on. Independent of
    /// `execute` (it observes the same executor run).
    record_exec_log: bool = false,
    /// Exec-log detail cap: per trace entry, stop recording per-iteration events once
    /// this many iterations have committed (the side-exit is still recorded; the
    /// entry's `iterations` stays accurate). Bounds the spinning detail.
    exec_log_max_iters: u32 = 16,
    /// Exec-log entry cap: stop recording new entries (exit ramps) for a trace beyond
    /// this many. Bounds total volume for an oft-entered trace.
    exec_log_max_entries: u32 = 64,
    /// Tier-1b: compile a hot trace to native x86-64 machine code (`nativegen.zig`)
    /// and run that instead of the tier-1a IR-interpreter. Off by default; the CLI
    /// `--jit-native` flips it on. x86-64/Linux only — elsewhere (incl. wasm) the
    /// compiler bails and the trace silently stays on tier-1a. Mutually exclusive
    /// with `record_exec_log` (the viz instrumentation observes the interpreter).
    native_codegen: bool = false,
    /// Record an **abort log** (`TraceState.abort_log`): every recording that is
    /// abandoned appends/bumps a row keyed by `(anchor, reason, triggering
    /// opcode)`, with the partial IR length reached. Off by default (the abort
    /// path stays a single field write); the CLI `--dump-aborts` flips it on so a
    /// loop that never tiers up can be diagnosed (which opcode/reason kills it, and
    /// how far the trace got). Diagnostic only — never affects tiering or output.
    record_aborts: bool = false,
};

/// Direct-mapped hot-count table size (a power of two). A back-edge hashes its
/// `(proto, pc)` into this many `u16` slots; the table is a cheap pre-filter that
/// lets a *gated* anchor skip the per-back-edge hashmap bookkeeping in
/// `onBackEdge` entirely (it just decrements a slot and bails). Sized generously
/// — any real program has a handful of hot loops, so collisions (two anchors
/// sharing a slot) are rare and, when they happen, only cost extra slow-path
/// visits, never correctness. 2^11 = 2048 slots = 4 KiB inline in `TraceState`.
const HOTCOUNT_BITS = 11;
const HOTCOUNT_SIZE = 1 << HOTCOUNT_BITS;
/// Skip window installed on a *gated* anchor: the number of back-edges its
/// hot-count slot suppresses before the slow path re-checks the gate. Kept modest
/// so a transiently-gated loop whose cooldown elapses still re-enters its trace
/// within a small, bounded number of iterations (recovery responsiveness) while
/// still cutting the per-back-edge cost of a permanently-dead loop by ~this factor.
const GATE_SKIP: u16 = 64;

/// Hash `(proto, pc)` into a hot-count slot. Pointer-based, like the existing
/// `AutoHashMap(AnchorKey, …)` keys — trace timing already varies across runs by
/// address, which is sound because the trace cache is runtime-only state (never
/// serialized) and traces are output-transparent (== tier-0). A collision only
/// changes *which* back-edges take the slow path, never the result.
inline fn hotIndex(proto: *const Proto, pc: u32) usize {
    var h: usize = @intFromPtr(proto);
    h ^= @as(usize, pc) *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    return h & (HOTCOUNT_SIZE - 1);
}

/// One armed native link (P-E, doc 17 Increment 2.3): `parent`'s frameless exit slot
/// at `slot_index` currently jumps straight into `child`'s body. Keyed by trace
/// identity (not a raw slot address) so lifetime resets stay valid no matter which
/// end retires first — the slot address is re-derived from the live `parent` at reset.
pub const NativeLink = struct { parent: *Trace, slot_index: u32, child: *Trace };

/// All recorder state owned by a `Vm`: the hotness counters, the cache of
/// committed traces, and the single in-progress `Recorder`.
pub const TraceState = struct {
    gpa: std.mem.Allocator,
    config: TraceConfig = .{},
    /// Shared machine-code arena — all tier-1b native traces are co-located slices of
    /// this (P-D of the exit-branch-patching port, doc 17). Replaces the old one-
    /// `mmap`-per-trace model so a future increment can link trace→trace with a bare
    /// `rel32` jump. Lifetime ≥ every trace (deinited *after* the cache is freed).
    mcode_arena: nativegen.McodeArena,
    /// Back-edge counters keyed by loop-header anchor. Only touched on the *slow*
    /// path (when the hot-count pre-filter trips), so for a non-gated anchor it
    /// still counts every back-edge (the pre-filter leaves un-gated slots at 0),
    /// preserving the arm-at-`hotloop` timing exactly. A gated anchor's count is
    /// coarse (the pre-filter skips most of its back-edges), which is fine — the
    /// gate's own cooldown is driven by `tick`, not this.
    counters: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Monotonic global back-edge tick. Incremented on *every* back-edge in the
    /// dispatch loop — including ones the hot-count pre-filter skips — so it is the
    /// one clock that never freezes. The gate's `retry_at` cooldown is measured in
    /// these ticks, which is why a transiently-gated loop's cooldown keeps elapsing
    /// while the pre-filter is cheaply skipping its back-edges. Deterministic.
    tick: u64 = 0,
    /// Direct-mapped hot-count pre-filter (see `hotIndex`/`HOTCOUNT_SIZE`). A slot
    /// holds the number of back-edges to skip cheaply before re-consulting the slow
    /// path for the anchor(s) that hash there. Zero ⇒ take the slow path now. Set
    /// to `GATE_SKIP` when an anchor is found gated, so a dead loop's millions of
    /// back-edges cost an array decrement instead of three hashmap probes apiece.
    hotcount: [HOTCOUNT_SIZE]u16 = @splat(0),
    /// Committed traces. A linear scan is fine — the cache is small in Phase 5a
    /// and never invalidated.
    cache: std.ArrayListUnmanaged(*Trace) = .empty,
    /// Next stable `Trace.id` to hand out (P-B, doc 17). Monotonic; never decremented,
    /// so a retired trace's id is never reassigned and a baked `final_trace_id` can
    /// never alias a different live trace.
    next_trace_id: u32 = 0,
    /// Armed native links (P-E, doc 17 Increment 2.3). Each record is a `parent`
    /// trace whose frameless exit slot `parent.native.compiled.slots[slot_index]` has
    /// been written to jump directly into `child`'s body. Kept so a retiring trace can
    /// be made lifetime-safe: when `child` is destroyed its arena slot returns to the
    /// reuse free-list and could be overwritten by unrelated code, so every parent
    /// slot pointing at it must first be reset to `shared_exit`; and when `parent` is
    /// destroyed its slot array is freed, so its records must be dropped before any
    /// child-retire tries to write through them. `resetLinksTouching` handles both
    /// directions by trace *identity* (never a raw slot pointer), so it is correct
    /// regardless of retire order. Empty until arming lands (2.3b) → inert in 2.3a.
    armed_links: std.ArrayListUnmanaged(NativeLink) = .empty,
    /// Anchors currently held off tier-1 with a doubling cooldown (`Gate`). Set
    /// when a recording aborts, a commit fails, or the low-yield re-entry penalty
    /// maxes out. Unlike the old permanent blacklist, an anchor here is *retried*
    /// once its cooldown window of back-edges elapses; a re-failure doubles the
    /// window, and after `config.max_strikes` escalations it is abandoned for
    /// good. A loop that was only *temporarily* unstable (type-unstable early,
    /// then settled) recovers; see `isGated` / `gateAnchor`.
    gate: std.AutoHashMapUnmanaged(AnchorKey, Gate) = .empty,
    /// Re-entry penalty per anchor: a low-yield trace entry bumps it, a useful one
    /// clears it; at `config.max_penalty` the anchor is gated off with a doubling
    /// cooldown (`onSideExit` → `gateAnchor`).
    penalty: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Total trace entries executed (incremented in the dispatch loop before each
    /// `irinterp.execute`/native run). Diagnostic only — used to confirm the gate
    /// entry-check actually halts re-entry on a thrashing anchor, and a cheap
    /// signal for benchmark analysis (entries ≫ committed-iterations means a
    /// low-yield loop the JIT can't amortize).
    entries: u64 = 0,
    /// Diagnostic/test counters for nested-loop link execution. `link_ir_exits`
    /// counts continuations that actually reached the irinterp `.link` arm;
    /// `link_follow_count` counts those links being followed into the inner root.
    /// They are intentionally harmless in release builds and give tests a direct
    /// proof that Phase 3 is not inert.
    ///
    /// Since coherent-state chaining (doc 16, Phase 2–3) these aggregate *both*
    /// classes of `.link` burst that flow through the same driveChain code: the
    /// loop-done continuation (anchored at the inner-exit PC) and the prime-side
    /// entry ramp (anchored at the outer header). They cannot be told apart at the
    /// `.link` arm, so use `prime_side_chain_follows` (below) when you need the
    /// prime-path-specific count.
    link_ir_exits: u64 = 0,
    link_follow_count: u64 = 0,
    /// Phase 4 native-chain diagnostics. These mirror the tier-1a counters above,
    /// but only increment when both linked traces execute through native pages.
    native_link_exits: u64 = 0,
    native_link_follow_count: u64 = 0,
    /// 2.3b-1 (doc 17): count of `.link`-terminal slots actually armed in
    /// `driveChain` — a continuation `C`'s `.link` slot pointed straight at its inner
    /// root `I`'s `linked_entry`, so the next `C.run` fuses into `I` under the shared
    /// frame with no Zig re-entry. `> 0` is the "the arm actually fires" signal the
    /// 2.3b-1 differential test asserts (stdout equality alone cannot prove the slot
    /// path, only that the fused and unfused runs agree).
    native_link_arms: u64 = 0,
    /// 2.3c-1 (M1 half-fusion, doc 17): count of ordinary source-branch guard slots
    /// armed in `driveChain` — a skip trace's productive branch guard (e.g. nsieve's
    /// `guard_false(p[i])`) pointed straight at the prime-side ramp's `ordinary_entry`,
    /// so the next time that guard fires it jumps into the ramp under the shared frame
    /// (skip→ramp fuses into one native call, its `.link` terminal drained by the
    /// dispatcher's fused-`.link` consumer). Distinct from `native_link_arms` (the
    /// 2.3b-1 continuation→inner `.link`-terminal arms) so the 2.3c-1 differential test
    /// can prove THIS arm fires; `> 0` is the "skip→ramp arm actually happened" signal.
    native_source_link_arms: u64 = 0,
    /// 2.3c-1 (M1 half-fusion, doc 17): count of fused skip→prime-side receipts DRAINED
    /// by the dispatcher's M1 fused-`.link` consumer (interp.zig) — i.e. the arm above
    /// actually took effect and a native `ct.run` fused straight into the prime-side ramp
    /// (`final != ct`, provenance via `fusedSourceBranchLinkSlot`). Distinct from the arm
    /// counter: an arm can happen without ever firing (skip retired first); this counts
    /// the consumer path being taken. `> 0` proves the M1 consumer is exercised, not just
    /// wired, in the 2.3c-1 differential test.
    native_source_link_fused: u64 = 0,
    /// **Coherent-state chaining (doc 16, Phase 2) diagnostics.** `prime_side_arms`
    /// counts outer-header prime side-traces armed (a productive branch-guard went
    /// hot and we switched to `.full` to record the current prime iteration).
    /// `tier0_outer_body_entries` counts tier-0 executions of a traced anchor's body
    /// top — the design's required NEW signal for "how often the prime path drops to
    /// tier-0" (the back-edge counter returns early once any trace exists at the
    /// anchor, so it cannot measure this). Both are mode-invariant and give tests a
    /// direct proof Phase 2 is not inert.
    prime_side_arms: u64 = 0,
    tier0_outer_body_entries: u64 = 0,
    /// Counts prime side-trace link-bursts actually *entered* via the
    /// `.ordinary_header` chain (as opposed to a loop-done `.link` continuation,
    /// which bumps `native_link_exits`/`link_ir_exits` and is indistinguishable
    /// there). This is the Phase-2-specific "the prime chain fired, not merely
    /// recorded" signal the design demands — output equality alone can't prove it.
    prime_side_chain_follows: u64 = 0,
    /// The in-progress recording (at most one at a time in Phase 5a).
    rec: Recorder = .{},
    /// Reusable SSA-value scratch for the tier-1a executor (`irinterp.execute`),
    /// indexed by `Ref`. Grown to the longest trace executed and reused across
    /// every entry — never allocated per-iteration or per-entry. Not a GC root
    /// (the executor runs no safepoint; see `irinterp.zig`).
    values_scratch: std.ArrayListUnmanaged(Value) = .empty,
    /// 2.3c-2b (doc 17): scratch for ONE native continuation call's decoded
    /// per-transition ledger. `runLinkedBurst` fills it via
    /// `CompiledTrace.runCapturingLedger` and immediately replays it in
    /// `replayContinuationLedger`; the borrow lives only for that capture→replay
    /// window (no native call / resize / nested replay in between). Sized to
    /// `irinterp.LEDGER_CAP`, the native append's own bound, so a full span always
    /// fits. Not a GC root (holds decoded scalars, no `Value`s).
    ledger_scratch: [irinterp.LEDGER_CAP]irinterp.LedgerEntry = undefined,
    /// Last guard-failure instruction index, written by the dispatch loop when a
    /// trace side-exits with zero iterations. Used for per-guard PC recording
    /// (exit-PC-aware chaining). `maxInt(u32)` means no guard failed (clean exit
    /// or arith error).
    last_exit_instr: u32 = std.math.maxInt(u32),
    /// Per-guard failure counters for side-trace recording (step 4).  Keyed by
    /// `(anchor, exit_pc)` — each entry tracks how many times a specific guard
    /// in traces at `anchor` has failed.  When a counter crosses `hotguard`,
    /// `wants_side_trace` is set and the next back-edge records a side trace.
    guard_failures: std.AutoHashMapUnmanaged(GuardKey, u32) = .empty,
    /// When non-null, the next back-edge to this anchor will arm a side-trace
    /// recording (even if a trace already exists there).  Set by
    /// `countGuardFailure` when a guard-failure crosses `hotguard`; cleared
    /// by `onBackEdge` when the side trace is armed.
    wants_side_trace: ?AnchorKey = null,
    /// **Nested-loop trace linking (Phase 1).** When non-null, a *continuation*
    /// recording is pending at this (non-header) anchor — the bytecode PC tier-0
    /// resumes at after an inner numeric-`for` loop runs to completion (the inner
    /// loop-done `guard_true`'s recorded `exit_pc`). Unlike a root or side trace,
    /// this is **not** a back-edge target, so it cannot arm in `onBackEdge`;
    /// `maybeArmContinuation` sets it on a hot inner loop-done exit and
    /// `maybeStartContinuation` consumes it in the dispatch prologue the moment
    /// `cur_pc` reaches the anchor — *after* tier-0 has deopt-replayed the final
    /// inner iteration, so the continuation records the **outer** body forward, not
    /// a stray inner iteration. Recording the inner `for_prep` it then re-reaches
    /// still aborts (LINNER) until Phase 2 turns it into a `.link`. See
    /// `docs/design/15-nested-loop-linking.md`.
    pending_exit_anchor: ?AnchorKey = null,
    /// **Coherent-state chaining (doc 16, Phase 2).** Per-guard counters for
    /// *productive* source-level branch-guard exits (e.g. nsieve's `guard_false(p[i])`
    /// firing when a composite-skipping outer trace finally hits a prime). Kept in a
    /// map separate from `guard_failures` so productive-branch counting never
    /// cross-talks with the zero-exit side-trace machinery. Keyed by
    /// `(anchor, exit_pc)`; crosses `config.hotguard` → `wants_prime_side`.
    prime_exits: std.AutoHashMapUnmanaged(GuardKey, u32) = .empty,
    /// **Coherent-state chaining (doc 16, Phase 2).** When non-null, a productive
    /// branch-guard at this outer-header anchor has gone hot: the next such exit
    /// should arm an *immediate* replay of the current (prime) iteration — recording
    /// the taken branch forward through the inner `for_prep` and closing with a
    /// `.link` to the inner root — rather than the *next* iteration (which the
    /// `wants_side_trace`/`onBackEdge` path would record, and which is ~93% a
    /// composite in nsieve, the wrong path). Set by `countProductiveBranchExit`;
    /// consumed at the productive-exit site by handing off to `pending_replay_anchor`.
    wants_prime_side: ?AnchorKey = null,
    /// **Coherent-state chaining (doc 16, Phase 2).** When non-null, an outer-header
    /// prime side-trace recording is pending at this anchor. Unlike
    /// `pending_exit_anchor` (a *post-inner* continuation pc), this anchor is the
    /// failed trace's OWN coherent anchor — the registers are already coherent there
    /// on the productive exit, so tier-0 re-enters at the anchor and
    /// `maybeStartReplaySide` starts the `.side` recording the instant `cur_pc`
    /// reaches it, capturing the prime branch of that same iteration. Cleared by
    /// `maybeStartReplaySide` (consumed) or `clearPendingExitAnchor` (frame unwind).
    pending_replay_anchor: ?AnchorKey = null,
    /// Per-trace execution logs for the visualizer (`execlog.zig`), populated only
    /// when `config.record_exec_log`. Keyed by `trace_id` (cache index). Empty and
    /// untouched on the normal JIT path.
    exec_logs: std.ArrayListUnmanaged(execlog.TraceExecLog) = .empty,
    /// The recorder driving `exec_logs`, lazily created on first use so the off path
    /// allocates nothing. Reused (per-entry scratch retained) across every entry.
    exec_recorder: ?execlog.ExecLogRecorder = null,
    /// Aborted-recording diagnostic log, populated only when `config.record_aborts`
    /// (the `--dump-aborts` CLI flag). Deduped by `(anchor, reason, op)`; see
    /// `AbortRecord` and `logAbort`. Empty and untouched on the normal path.
    abort_log: std.ArrayListUnmanaged(AbortRecord) = .empty,

    pub fn init(gpa: std.mem.Allocator) TraceState {
        return .{ .gpa = gpa, .mcode_arena = nativegen.McodeArena.init(gpa) };
    }

    pub fn deinit(self: *TraceState) void {
        self.counters.deinit(self.gpa);
        self.gate.deinit(self.gpa);
        self.penalty.deinit(self.gpa);
        self.guard_failures.deinit(self.gpa);
        self.prime_exits.deinit(self.gpa);
        self.values_scratch.deinit(self.gpa);
        for (self.exec_logs.items) |*l| l.deinit(self.gpa);
        self.exec_logs.deinit(self.gpa);
        self.abort_log.deinit(self.gpa);
        if (self.exec_recorder) |*r| r.deinit();
        self.armed_links.deinit(self.gpa);
        // Free each trace (its `native.deinit()` returns mcode slots to the arena's
        // free-list) *before* tearing down the arena those slots live in.
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.deinit(self.gpa);
        self.mcode_arena.deinit();
        self.rec.deinit(self.gpa);
    }

    /// The `ExecLogRecorder` re-targeted at the execution log for `trace_id` (the
    /// trace's cache index), creating the recorder (lazily) and the per-trace log on
    /// first use. Returns null on OOM (the caller then runs the uninstrumented
    /// `execute`). Only called when `config.record_exec_log`.
    pub fn execRecorderFor(self: *TraceState, trace_id: u32) ?*execlog.ExecLogRecorder {
        if (self.exec_recorder == null) {
            self.exec_recorder = execlog.ExecLogRecorder.init(self.gpa, self.config.exec_log_max_iters, self.config.exec_log_max_entries);
        }
        const log = self.execLogFor(trace_id) catch return null;
        const rec = &self.exec_recorder.?;
        rec.retarget(log);
        return rec;
    }

    /// Find-or-create the `TraceExecLog` for `trace_id`. Linear scan — the cache is
    /// small and so is the set of executed traces.
    fn execLogFor(self: *TraceState, trace_id: u32) !*execlog.TraceExecLog {
        for (self.exec_logs.items) |*l| {
            if (l.trace_id == trace_id) return l;
        }
        try self.exec_logs.append(self.gpa, .{ .trace_id = trace_id });
        return &self.exec_logs.items[self.exec_logs.items.len - 1];
    }

    /// The trace cached for `(proto, pc)` with the highest hit count, or null.
    /// Frequency-based prioritisation: the trace that has committed the most
    /// useful iterations is returned first, so the common path is tried before
    /// rare alternatives.  Stable — does not thrash on alternating types.
    pub fn findTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto == proto and t.anchor.pc == pc) {
                if (best == null or t.hit_count > best_hits) {
                    best = t;
                    best_hits = t.hit_count;
                }
            }
        }
        return best;
    }

    /// Highest-hit cached root trace at `(proto, pc)`. Link hand-offs are only
    /// sound to a real loop-root terminal; a continuation at the same bytecode PC
    /// is not an entry target for `.link`.
    /// A `t` resolved from a fused exit's `final_trace_id` is only safe to consume
    /// as "the inner root that just ran under fusion at `pc`" when it has the exact
    /// shape `findLoopTrace` requires: a zero-input `.loop`-terminated root anchored
    /// at `(proto, pc)`. Used to FAIL CLOSED — a fused result must be interpreted as
    /// the trace whose id it baked, never substituted by a same-PC sibling; if the id
    /// resolves to the wrong shape/location the child's exit left `regs[]` with no
    /// known-coherent resume PC, so callers `@panic` (hard invariant failure) rather
    /// than indexing a foreign trace's `instrs` (OOB / misclassified exit /
    /// mis-accounting) or silently resuming at a PC that re-runs a committed loop.
    fn isInnerLoopRoot(t: *const Trace, proto: *const Proto, pc: u32) bool {
        return t.anchor.proto == proto and t.anchor.pc == pc and
            t.inputs.len == 0 and
            t.instrs.len != 0 and t.instrs[t.instrs.len - 1].op == .loop;
    }

    pub fn findLoopTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .loop) continue;
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// Highest-hit cached `.link` trace at `(proto, pc)` — i.e. a continuation
    /// (doc 15) or a prime side-trace (doc 16). This is the ping-pong *driver*
    /// the linked burst hands control to after an inner-root loop-done: it is
    /// anchored at the post-inner PC and advances the enclosing loop before
    /// linking back to the inner root. Distinct from `findLoopTrace`, which
    /// finds the `.loop`-terminated inner root itself.
    pub fn findLinkTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .link) continue;
            if (t.inputs.len != 0) continue;
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// Highest-`hit_count` trace at `(proto, pc)` that is not in `visited`, or
    /// null. Same-anchor walks (the dispatch trial loop and exit-PC chaining)
    /// use this with a growing `visited` set so they visit each candidate
    /// **exactly once** and always terminate: a single-`skip` cursor would make
    /// two equal-priority traces cycle `A→B→A→…` forever whenever both zero-exit
    /// on the same registers (e.g. two stale narrow-lane traces once the live
    /// array has widened past both — see widen-eviction).
    pub fn nextTraceExcluding(self: *const TraceState, proto: *const Proto, pc: u32, visited: []const *Trace) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        outer: for (self.cache.items) |t| {
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            for (visited) |v| {
                if (v == t) continue :outer;
            }
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// Is a trace already cached for this anchor? (Prevents re-arming.)
    pub fn hasTrace(self: *const TraceState, anchor: AnchorKey) bool {
        return self.findTrace(anchor.proto, anchor.pc) != null;
    }

    /// The cache index (`trace_id`) of a cached trace, or null if not present. This
    /// id is the exec-log key and the viz's trace-selection key. Linear scan (the
    /// cache is small; only the instrumented path calls this).
    pub fn traceIndex(self: *const TraceState, t: *const Trace) ?u32 {
        for (self.cache.items, 0..) |c, i| {
            if (c == t) return @intCast(i);
        }
        return null;
    }

    /// Resolve a stable `Trace.id` (P-B, doc 17 — baked into native exit code as
    /// `final_trace_id`) to its live `*Trace`, or null if no cached trace carries it
    /// (the trace retired, or the id is the `NO_TRACE_ID` sentinel). Linear scan,
    /// mirroring `traceIndex`; ids are unique, so at most one match.
    pub fn traceById(self: *const TraceState, id: u32) ?*Trace {
        for (self.cache.items) |c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// A reusable scratch slice of at least `n` `Value`s for the executor. Grows
    /// the backing buffer to the high-water mark and reuses it; never shrinks.
    pub fn valuesScratch(self: *TraceState, n: usize) ![]Value {
        if (self.values_scratch.items.len < n) {
            try self.values_scratch.resize(self.gpa, n);
        }
        return self.values_scratch.items[0..n];
    }

    /// Account for a trace entry that side-exited after committing `completed`
    /// iterations. A useful entry (>= `min_useful`) clears the anchor's penalty
    /// **and any gate** (the loop recovered — forget the backoff history) and
    /// bumps the trace's `hit_count` (frequency-based trace prioritisation); a
    /// low-yield one bumps the penalty, and at `max_penalty` the anchor is gated
    /// off with a doubling cooldown (`gateAnchor`).
    pub fn onSideExit(self: *TraceState, t: *Trace, completed: usize) void {
        const key = t.anchor;
        if (completed >= self.config.min_useful) {
            t.hit_count +|= 1;
            _ = self.penalty.remove(key);
            _ = self.gate.remove(key);
            return;
        }
        const gop = self.penalty.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.max_penalty) {
            self.gateAnchor(key);
        }
    }

    /// Gate an anchor whose recorded trace compiles to native-*unsupported* under
    /// `--jit-native`. Running such a trace on the tier-1a IR-interpreter is
    /// ~equal-to-slower than tier-0 on the bodies that hit this (shift-heavy
    /// sieves, etc.), so naively falling back to tier-1a makes `--jit-native`
    /// *regress* vs plain tier-0. Instead we gate the anchor and let tier-0 own
    /// the loop (the dispatch's hot-count pre-filter then skips the entry walk).
    ///
    /// Unlike the thrash path (`onSideExit`) there's no reason to wait
    /// `max_penalty` low-yield entries — "unsupported" is known the first time
    /// `nativeFor` compiles — so we gate immediately. Self-healing via the
    /// existing backoff: the gate's cooldown lets the anchor retry, and a later
    /// native-supported specialization that runs usefully clears the gate
    /// (`onSideExit`). Deterministic — `gateAnchor` keys only on the monotonic
    /// back-edge `tick`. The `isGated` guard avoids re-escalating an active gate.
    pub fn gateNativeUnsupported(self: *TraceState, anchor: AnchorKey) void {
        if (self.isGated(anchor)) return;
        self.gateAnchor(anchor);
    }

    /// Exit-PC chaining (step 3): after trace `failed` side-exited with
    /// `exit_instr`, look for a trace at the guard's bytecode PC and try to
    /// execute it. Returns the number of committed iterations if a side trace
    /// succeeded, or null if no trace was found / all failed. `regs` is the
    /// current register window (coherent for the loop header). The caller
    /// should `continue :outer` on success.
    /// **Unified coherent-state chain driver (design doc 16).** After trace
    /// `failed` side-exited at `result.exit_instr`, look for a compiled trace at
    /// the exit's bytecode PC and run it — chaining native→native (or ir→ir) for a
    /// bounded burst instead of dropping back to tier-0. Subsumes the old
    /// `tryChainExit` / `tryChainProductiveLoopDone` / `tryChainProductiveLoopDoneNative`
    /// trio; `tier` (comptime) and `materialization` recover their three behaviours
    /// exactly:
    ///   * `.ir`  + `.ordinary_header`        ≡ old `tryChainExit` (zero-exit path)
    ///   * `.ir`  + `.ir_numeric_for_done`    ≡ old `tryChainProductiveLoopDone`
    ///   * `.native_only` + `.native_numeric_for_done` ≡ old `tryChainProductiveLoopDoneNative`
    ///
    /// Returns the committed iteration count and the PC tier-0 should resume at
    /// (`resume_pc == null` ⇒ resume at `failed.anchor.pc`), or null if nothing
    /// ran (caller falls to tier-0 at the header, unchanged). `initially_excluded`
    /// seeds the candidate walk's visited set — the existing sites pass empty
    /// (their walk PC is the exit PC, disjoint from the dispatcher's anchor walk);
    /// Phase 2's anchor-coherent chaining will seed it with the same-anchor walk.
    pub fn driveChain(
        self: *TraceState,
        // 2.3c-1 (doc 17): mutable so the M1 half-fusion arm can point `failed`'s
        // source-branch guard slot at the prime-side ramp's `ordinary_entry`
        // (`armNativeLink` takes `parent: *Trace`). Read-only on every other path.
        failed: *Trace,
        result: irinterp.ExecResult,
        proto: *const Proto,
        regs: RegWindow,
        comptime tier: ChainTier,
        materialization: ExitMaterialization,
        initially_excluded: []const *Trace,
        // 2.3b-1 (doc 17): may this burst persistently arm a `.link` slot? False when
        // the caller has a safepoint-line/suspend recording active — an mcode fusion
        // removes the 8-hop `driveChain` observation boundary and would widen the
        // blackout (doc 17 must-fix). The flag is only consulted on the native path;
        // tier-1a never arms. Threaded from the dispatcher's Vm flags because those
        // live on `*Vm`, not visible here.
        safe_to_arm: bool,
    ) ?ChainResult {
        const exit_instr = result.exit_instr;
        if (exit_instr == std.math.maxInt(u32)) return null;
        const walk_pc = switch (materialization) {
            // Coherent-anchor chaining (doc 16): after an *ordinary* guard deopt the
            // registers are coherent at the failed trace's **anchor**, not the
            // guard's exit PC — a trace may only be entered at its own coherent
            // anchor. So chain to same-anchor siblings (including an outer-header
            // prime side-trace). The guard's `aux` is a lane ordinal for array
            // guards — irrelevant here; we resume at the anchor regardless of which
            // guard fired. `initially_excluded` (the dispatcher's same-anchor
            // `visited` set) keeps us from re-running the failed trace or any
            // sibling the cold walk already tried this back-edge.
            .ordinary_header => failed.anchor.pc,
            // Loop-done materializations chain to a `.link` continuation living at
            // the guard's *exit* PC (a real post-loop bytecode pc). Resolve it
            // through the op-gated accessor so an array-guard lane ordinal is never
            // mistaken for a PC, and reject a 0/anchor exit PC (nothing to chain to).
            else => blk: {
                const wp = guardExitPc(failed.instrs[exit_instr]) orelse return null;
                if (wp == 0 or wp == failed.anchor.pc) return null;
                break :blk wp;
            },
        };

        const loop_done_values: ?[]Value = switch (materialization) {
            .ir_numeric_for_done => |vals| vals,
            else => null,
        };

        // Visit each candidate at `walk_pc` exactly once (highest-hit first). A
        // growing `visited` set (rather than a single-`skip` cursor) is what makes
        // this terminate: two equal-priority candidates that both zero-exit would
        // otherwise cycle `A→B→A→…` forever. Seed it with `initially_excluded`.
        var visited: [8]*Trace = undefined;
        var nvisited: usize = 0;
        for (initially_excluded) |ex| {
            if (nvisited >= visited.len) break;
            visited[nvisited] = ex;
            nvisited += 1;
        }

        var st: ?*Trace = self.nextTraceExcluding(proto, walk_pc, visited[0..nvisited]);
        while (st) |sct| : (st = if (nvisited < visited.len)
            self.nextTraceExcluding(proto, walk_pc, visited[0..nvisited])
        else
            null)
        {
            if (nvisited < visited.len) {
                visited[nvisited] = sct;
                nvisited += 1;
            }
            // A candidate with synthetic upvalue/global inputs needs the dispatch
            // loop's per-entry seeding (no `*Vm` here), so it cannot be entered
            // through the chain path. Skip it — it still runs via the seeded
            // same-anchor walk.
            if (sct.inputs.len != 0) continue;
            const is_link = sct.instrs.len != 0 and sct.instrs[sct.instrs.len - 1].op == .link;
            // Loop-done chains (ir and native) only follow `.link` continuations;
            // an ordinary side trace at the post-loop PC is not a valid hand-off.
            if (loop_done_values != null and !is_link) continue;
            if (tier == .native_only and !is_link) continue;

            // Once a productive loop-done exit has committed, the ordinary loop-
            // header deopt path is no longer valid: tier-0 must resume at the PC
            // matching the now-committed state (the post-inner continuation PC,
            // advancing to the inner-root PC after a `.link` snapshot flush). For
            // native the commit already happened (`runLinkedLoopDone`); for tier-1a
            // loop-done we flush the failed trace's final iteration from scratch now.
            var flushed_resume_pc: ?u32 = null;
            var sresult: irinterp.ExecResult = undefined;
            var snt: *const nativegen.CompiledTrace = undefined;
            if (tier == .native_only) {
                snt = self.nativeFor(sct) orelse return .{ .completed = 0, .resume_pc = walk_pc };
                flushed_resume_pc = walk_pc;
                sresult = snt.run(regs);
            } else {
                const sbuf = self.valuesScratch(sct.instrs.len) catch continue;
                if (loop_done_values) |vals| {
                    if (!irinterp.flushNumericForLoopDone(failed, regs, vals, exit_instr)) return null;
                    flushed_resume_pc = walk_pc;
                }
                sresult = irinterp.execute(sct, regs, sbuf);
            }

            // --- linked burst: the continuation ran to its `.link` terminator, so
            // ping-pong continuation ⇄ inner-root for a bounded number of hops. ---
            // 2.3b-1: a *previous* burst may have persistently armed `sct`'s `.link`
            // slot → an inner root's `linked_entry`, so this initial run FUSED — `sct`
            // advanced its enclosing loop, hit the armed `.link`, and jumped straight
            // into the inner root, which ran and stamped the FINAL `final_trace_id` with
            // ITS id (≠ sct.id). That result never exits at `sct`'s own `.link` terminal
            // (its `exit_instr` indexes the inner), so recognize the fusion directly and
            // enter the burst with the inner result pre-loaded (`fused_inner`) — exactly
            // as if the continuation had reached its `.link` and we had then run inner.
            const sresult_fused = tier == .native_only and
                sresult.final_trace_id != irinterp.NO_TRACE_ID and
                sresult.final_trace_id != sct.id;
            if (is_link and (sresult.exit_instr == sct.instrs.len - 1 or sresult_fused)) {
                // 2.3c-1 (M1 half-fusion, doc 17): arm the failing trace's source-branch
                // guard slot -> this prime-side ramp's `ordinary_entry`, so the NEXT time
                // that guard fires it jumps straight into the ramp under the shared frame
                // (skip->ramp fuses into one native call; the ramp's `.link` receipt is
                // drained by the dispatcher's fused-`.link` consumer). Gated exactly like
                // 2.3b-1's continuation arm plus two M1-specific conditions:
                //  - `materialization == .ordinary_header`: only the coherent-anchor path,
                //    where `sct` is a same-anchor ramp (walk_pc == failed.anchor.pc) -- never
                //    a post-inner continuation, so this can only ever arm skip->ramp.
                //  - `isSourceBranchGuardExit(failed, exit_instr)`: `exit_instr` must be a
                //    real source-branch guard (excludes the zero-exit path's arbitrary
                //    guard and any loop-done guard; satisfies `.ordinary_guard`'s
                //    !isLoopDoneGuardIndex assert).
                // The ramp's OWN `.link` slot is never armed (2.3b-1 arms only the
                // continuation's), so the fused call stops at the ramp's `.link` = the M1
                // receipt, never skip->ramp->inner (= M2, which needs the deferred ledger).
                if (tier == .native_only and safe_to_arm and materialization == .ordinary_header and
                    sct.inputs.len == 0 and self.isSourceBranchGuardExit(failed, exit_instr, proto))
                {
                    if (self.nativeFor(sct)) |snat| {
                        if (snat.ordinary_entry) |oe| {
                            if (self.armNativeLink(failed, exit_instr, sct, oe, .ordinary_guard) catch false) {
                                self.native_source_link_arms +|= 1;
                            }
                        }
                    }
                }
                return self.runLinkedBurst(sct, sresult, sresult_fused, snt, tier, materialization, proto, regs, safe_to_arm);
            }

            // Not a completed link run.
            if (flushed_resume_pc) |target_pc| {
                self.onSideExit(sct, 0);
                return .{ .completed = 0, .resume_pc = target_pc };
            }
            if (sresult.completed > 0) {
                self.onSideExit(sct, sresult.completed);
                return .{ .completed = sresult.completed };
            }
            self.onSideExit(sct, 0);
            // Zero iterations, no flush owed (ordinary path): try the next candidate.
        }
        return null;
    }

    /// The linked ping-pong burst (doc 15/16), extracted from `driveChain` (2.3c-1) so
    /// the dispatcher's M1 fused-`.link` consumer can enter it directly with an
    /// already-run prime-side ramp result -- WITHOUT re-running the ramp (which would
    /// redo its `for_prep`). `sct` reached its `.link` terminal (or fused via a prior
    /// 2.3b-1 arm, `sresult_fused`); regs are coherent at the inner-root PC named by the
    /// `.link`. Runs inner, then continuation <-> inner for a bounded number of hops.
    /// `snt` is `sct`'s compiled trace (valid only when `tier == .native_only`; the burst
    /// reassigns it on the driver swap). Always returns a `ChainResult` (every path
    /// returns), so callers do `return self.runLinkedBurst(...)`.
    ///
    /// `pub` because the dispatcher's M1 fused-`.link` consumer (interp.zig) enters it
    /// directly with the already-run ramp receipt (see `fusedSourceBranchLinkSlot`).
    ///
    /// 2.3c-2b: outcome of replaying ONE native continuation call's per-transition
    /// ledger (`replayContinuationLedger`). Drives `runLinkedBurst`'s native call-B
    /// drain in place of the old scalar-field reads.
    const ContinuationReplay = union(enum) {
        /// The continuation reached its `.link` terminal, a fused inner ran to
        /// loop-done, and the hop budget remains → re-run the (still-armed)
        /// continuation for the next fused span.
        run_continuation,
        /// Standalone `.link` (slot un-armed): the continuation advanced the
        /// enclosing loop but no inner fused → resume by running inner fresh next
        /// hop (`continue :hop`). `resume_pc` already set to the inner-root PC.
        run_inner,
        /// Yield / finish: return this `ChainResult` to the dispatcher.
        return_result: ChainResult,
        /// Zero-progress continuation deopt (its own guard, no completion): break the
        /// hop loop and fall to the penalty-neutral post-loop tail.
        break_burst,
    };

    /// 2.3c-2b: replay ONE native continuation call's decoded ledger, reproducing the
    /// accounting the old scalar-field drain performed. Phase machine starting in the
    /// `continuation` phase. In 2.3c-2b nothing `I→C` is armed, so a single native
    /// continuation call fuses at most ONE inner and the ledger is ≤2 entries:
    ///   `[C.link]`          un-armed slot: standalone `.link`     → `run_inner`
    ///   `[C.<guard>]`       continuation's OWN deopt (no `.link`) → productive / break
    ///   `[C.link, I.exit]`  armed slot fused into the inner root  → drain the inner
    /// (2.3c-2c arms `I.loopdone→C`, closing the cycle into a longer ledger; the
    /// `entries.len <= 2` assert pins the current invariant so a stray arm trips loudly.)
    /// Mutates the burst cursors (`linked_completed`, `resume_pc`, `hops`) in place and
    /// charges `native_link_exits` on the `C.link` marker (replacing the old per-span
    /// and standalone-`.link` bumps). Resolution failures panic — the SAME hard
    /// invariant the scalar drain enforced (an unresolvable/mis-shaped fused id means
    /// `regs[]` has no known-coherent resume PC).
    fn replayContinuationLedger(
        self: *TraceState,
        entries: []const irinterp.LedgerEntry,
        current_link: *Trace,
        inner_pc: u32,
        proto: *const Proto,
        linked_completed: *usize,
        resume_pc: *u32,
        hops: *usize,
        max_hops: usize,
    ) ContinuationReplay {
        // 2.3c-2b models ≤2-entry ledgers only (one continuation exit + at most one
        // fused inner). A longer ledger means a FURTHER fused hop — the closed
        // `C→I→C…` cycle 2.3c-2c arms, whose full-ledger replay handles it. Until
        // then a >2 ledger is an unmodeled composition (e.g. `C.link→I.guard→R.link`
        // when an inner's own ordinary source guard is itself armed to a ramp):
        // replaying only entries 0-1 would DROP R's hop and misresume. Abort loudly in
        // EVERY build rather than silently mis-account — this is the same
        // "unexpected fused shape" hard-stop the old scalar drain took (it panicked on
        // a terminal that is not the expected inner root). `ledger_len` is always ≥1
        // (every native exit appends), release-guarded here so `entries[0]` can never
        // be OOB even if that invariant were ever violated.
        if (entries.len == 0 or entries.len > 2)
            @panic("replayContinuationLedger: ledger length outside the 2.3c-2b ≤2 model (2.3c-2c lifts this)");
        const e0 = entries[0];
        const c_owner = self.traceById(e0.id) orelse
            @panic("replayContinuationLedger: continuation id did not resolve");
        // 2.3b-1: call B is `snt.run(current_link)`; nothing routes a different
        // continuation into this call yet, so the first entry is current_link's own.
        std.debug.assert(c_owner == current_link);
        const c_is_link_terminal = e0.exit == current_link.instrs.len - 1 and
            current_link.instrs[current_link.instrs.len - 1].op == .link;
        if (!c_is_link_terminal) {
            // The continuation took its OWN guard/prologue exit before reaching
            // `.link` (matches the old scalar `completed>0 ? onSideExit+return :
            // break`). A fresh trampoline call zeroes `rbx`, so the continuation's
            // local == `cum[0]` == the old scalar `cresult.completed`.
            const c_local = e0.cum;
            if (c_local > 0) {
                self.onSideExit(current_link, c_local);
                return .{ .return_result = .{
                    .completed = linked_completed.* + c_local,
                    .resume_pc = resume_pc.*,
                } };
            }
            return .break_burst;
        }
        // `C.link` marker: the continuation advanced the enclosing loop and (if the
        // slot is armed) handed to inner. Charge `native_link_exits` here — this one
        // bump replaces BOTH the old per-fused-span bump and the standalone-`.link`
        // bump (byte-identical count; see doc 17 2.3c-2b).
        self.native_link_exits +|= 1;
        if (entries.len == 1) {
            // Standalone `.link` (slot un-armed): resume by running inner fresh.
            resume_pc.* = inner_pc;
            return .run_inner;
        }
        // Fused inner (entries[1]). Resolve STRICTLY by baked id + shape, exactly as
        // the old scalar drain — never substitute `findLoopTrace`'s current pick.
        const e1 = entries[1];
        const dinner = self.traceById(e1.id) orelse
            @panic("replayContinuationLedger: fused inner id did not resolve");
        if (!isInnerLoopRoot(dinner, proto, inner_pc))
            @panic("replayContinuationLedger: fused inner is not the expected inner root");
        // Per-segment local of entry 1 = `cum[1] − cum[0]` (== old `local_completed`).
        const flocal = e1.cum -% e0.cum;
        // Loop-done ⟺ the inner exit PC follows a `for_loop` (the static
        // discriminator; prologue-fail / array-guard / not-after-`for_loop` default
        // false, exactly as the scalar drain at the old lines 1748-1754).
        const fdone = if (e1.reason == .prologue_fail or e1.exit == std.math.maxInt(u32))
            false
        else if (guardExitPc(dinner.instrs[e1.exit])) |fpc|
            fpc >= 1 and proto.code[fpc - 1].op == .for_loop
        else
            false;
        if (!fdone) {
            // Mid-loop inner deopt: regs coherent at the inner header → resume tier-0
            // at `inner_pc`. (`linked_completed` is ≥1 here — this burst already
            // committed the hop that armed.)
            self.onSideExit(dinner, flocal);
            return .{ .return_result = .{
                .completed = if (linked_completed.* > 0) linked_completed.* else flocal,
                .resume_pc = inner_pc,
            } };
        }
        // Inner loop-done: one more enclosing iteration committed natively; coherent
        // state is post-inner at the continuation's anchor.
        self.onSideExit(dinner, if (flocal > 0) flocal else 1);
        linked_completed.* += 1;
        resume_pc.* = current_link.anchor.pc;
        hops.* += 1;
        if (hops.* >= max_hops) return .break_burst;
        return .run_continuation;
    }

    pub fn runLinkedBurst(
        self: *TraceState,
        sct: *Trace,
        sresult: irinterp.ExecResult,
        sresult_fused: bool,
        snt_in: *const nativegen.CompiledTrace,
        comptime tier: ChainTier,
        materialization: ExitMaterialization,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
    ) ChainResult {
        // Burst hop bound: matches the old `visited: [8]*Trace` cap (see the BURST BOUND
        // note below). A named const now that the walk's `visited` array is out of scope.
        const max_hops: usize = 8;
        var snt = snt_in;
        if (tier == .native_only) {
            self.native_link_exits +|= 1;
        } else {
            self.link_ir_exits +|= 1;
        }
        // Phase-2 chain-firing signal: this burst entered through the
        // coherent-anchor (outer-header prime side-trace) path, not a
        // loop-done continuation. Bump regardless of tier.
        if (materialization == .ordinary_header) self.prime_side_chain_follows +|= 1;
        var linked_completed: usize = 0;
        // The ping-pong *driver*: a `.link` trace anchored at the post-inner
        // PC that advances the enclosing loop and links back to the inner
        // root. Seeded with `sct` — which for a doc-15 continuation IS the
        // driver, but for a doc-16 prime side-trace is only the *entry ramp*
        // (anchored at the outer header, not the post-inner PC). After the
        // first inner loop-done we swap to the real continuation (below), so
        // the burst advances the outer loop natively instead of dropping to
        // tier-0. Mutable for exactly that swap.
        var current_link = sct;
        // The design's `coherent_pc` cursor: where tier-0 resumes when the
        // burst yields. Starts at the inner-root PC named by the `.link`.
        var resume_pc: u32 = @intCast(current_link.instrs[current_link.instrs.len - 1].aux);
        // 2.3b-1: carries an inner loop-done/mid result produced by a *fused*
        // continuation run (armed `.link` slot jumped straight into inner). The
        // loop top consumes it as this hop's inner result WITHOUT re-running
        // inner (which would double-commit its loop). Seeded from a fused initial
        // `sresult`; refilled by each fused `cresult` at the loop bottom. Only
        // ever non-null on the native path.
        var fused_inner: ?irinterp.ExecResult = if (sresult_fused) sresult else null;
        var hops: usize = 0;
        // BURST BOUND (native drain caveat): tier-1a commits at most `visited.len`
        // (8) enclosing iterations per burst. The native drain permits ONE more —
        // up to `visited.len + 1` (9) — because a hop's FIRST loop-done (the one
        // that arms) increments `linked_completed` without incrementing `hops`, and
        // the drain then runs up to `visited.len` further fused completions. The
        // extra completion is semantically insignificant (one more real iteration
        // committed natively vs. via tier-0) and the burst stays strictly bounded;
        // it only means the observation/safepoint blackout can span 9 native inner
        // loops rather than 8 (a heuristic maximum, not a correctness contract).
        hop: while (hops < max_hops) : (hops += 1) {
            const link_term = current_link.instrs[current_link.instrs.len - 1];
            const inner_pc: u32 = @intCast(link_term.aux);
            // Resolve THIS hop's inner root. When we hold a fused result (an armed
            // `current_link` slot `jmp`ed straight into a child), the child that
            // actually ran is the one whose id the exit baked — NOT necessarily the
            // current highest-hit trace at `inner_pc`. Under sibling traces at one
            // `inner_pc` (branch specialization / lane-widening) the armed slot may
            // target a trace `findLoopTrace` no longer picks; consuming that fused
            // result as a different sibling would index the wrong `instrs`
            // (out-of-bounds / misclassified exit) and mis-account. So a fused hop
            // resolves the runner STRICTLY by `final_trace_id` and validates its
            // shape — never substitutes another trace. A fused id always resolves
            // (P-B bakes a live id; nothing retires mid-burst); if it does NOT
            // resolve, or resolves to a non-inner-root shape, the child's exit
            // left `regs[]` in a state we can't map to any safe resume PC (neither
            // the inner header nor the post-inner continuation is known to be
            // coherent). `break` here would resume at `inner_pc` and re-run an
            // already-committed inner loop — silent double-count. So this is a
            // hard invariant failure, not a recoverable bail: panic.
            var inner: *Trace = undefined;
            if (fused_inner) |fr| {
                inner = self.traceById(fr.final_trace_id) orelse
                    @panic("driveChain: fused final_trace_id did not resolve");
                if (!isInnerLoopRoot(inner, proto, inner_pc))
                    @panic("driveChain: fused final trace is not the expected inner root");
            } else {
                inner = self.findLoopTrace(proto, inner_pc) orelse break;
            }
            if (inner.inputs.len != 0) break;
            if (tier == .native_only) self.native_link_follow_count +|= 1;
            self.link_follow_count +|= 1;

            var iresult: irinterp.ExecResult = undefined;
            var ibuf: []Value = &.{};
            if (fused_inner) |fr| {
                // A fused continuation run already executed `inner` under the
                // shared frame; its result IS this hop's inner result. Re-running
                // `inner` here would double-commit its loop, so consume the
                // carried result and skip the round-trip.
                std.debug.assert(tier == .native_only);
                iresult = fr;
                fused_inner = null;
            } else if (tier == .native_only) {
                const int_native = self.nativeFor(inner) orelse break;
                iresult = int_native.runLinkedLoopDone(regs);
            } else {
                ibuf = self.valuesScratch(inner.instrs.len) catch break;
                iresult = irinterp.execute(inner, regs, ibuf);
            }
            if (iresult.exit_instr == std.math.maxInt(u32)) break;
            // `iresult.completed` is the chain-cumulative counter (`rbx`), which a
            // fused inner INHERITS from its parent — inflated. All inner-recording
            // accounting must steer on the inner's OWN iteration count, so use
            // `local_completed` on the native path (== `completed` when unfused,
            // since a fresh trampoline entry zeroes `rbx`). Tier-1a never fuses, so
            // its `completed` already IS local (its `local_completed` is 0).
            const inner_local: usize = if (tier == .native_only)
                iresult.local_completed
            else
                iresult.completed;

            const inner_exit_pc = guardExitPc(inner.instrs[iresult.exit_instr]) orelse break;
            // The inner root reached its numeric loop-done ⟺ its exit PC
            // follows a `for_loop` (mode-invariant static bytecode; the same
            // discriminator `isSourceBranchGuardExit` uses inverted). This
            // must NOT be `inner_exit_pc == current_link.anchor.pc`: that
            // only holds when the driver is already the post-inner
            // continuation, and is false for a prime-side entry ramp anchored
            // at the outer header — which would misclassify a *completed*
            // inner loop as a mid-loop side-exit and resume tier-0 back at the
            // inner header, re-running the whole (idempotent) marking loop.
            const loop_done = inner_exit_pc >= 1 and
                proto.code[inner_exit_pc - 1].op == .for_loop;
            if (!loop_done) {
                if (inner_local > 0) {
                    self.onSideExit(inner, inner_local);
                    return .{
                        .completed = if (linked_completed > 0) linked_completed else inner_local,
                        .resume_pc = resume_pc,
                    };
                }
                self.onSideExit(inner, 0);
                break;
            }
            // Native committed the loop-done inside `runLinkedLoopDone`; the
            // tier-1a path still owes the final-iteration flush.
            if (tier == .ir) {
                if (!irinterp.flushNumericForLoopDone(inner, regs, ibuf, iresult.exit_instr)) break;
            }
            // Hole B (doc 16, Phase 3): hand the ping-pong to the continuation
            // anchored at the inner's post-loop PC. When the burst was seeded
            // by a prime-side entry ramp (anchored at the outer header), swap
            // the driver to that continuation so the *next* hop advances the
            // outer loop and re-enters the next iteration's inner loop
            // natively, rather than breaking to tier-0. When already on the
            // continuation (doc-15 steady state) this is a no-op. If no
            // continuation exists at the post-inner PC, resume tier-0 there —
            // NOT at the inner header — so the inner loop is not re-run.
            if (current_link.anchor.pc != inner_exit_pc) {
                const cont = self.findLinkTrace(proto, inner_exit_pc) orelse {
                    self.onSideExit(inner, if (inner_local > 0) inner_local else 1);
                    return .{ .completed = linked_completed + 1, .resume_pc = inner_exit_pc };
                };
                if (tier == .native_only) {
                    snt = self.nativeFor(cont) orelse {
                        self.onSideExit(inner, if (inner_local > 0) inner_local else 1);
                        return .{ .completed = linked_completed + 1, .resume_pc = inner_exit_pc };
                    };
                }
                current_link = cont;
            }
            resume_pc = current_link.anchor.pc;

            // Roll-up (doc 15 P3): the inner root running to its loop-done
            // exit completes exactly one enclosing-loop iteration — true even
            // when it reports `completed == 0` (a one-trip inner loop). It is
            // a successful hand-off, not a low-yield entry to penalize.
            self.onSideExit(inner, if (inner_local > 0) inner_local else 1);
            linked_completed += 1;

            // 2.3b-1: arm `current_link`'s `.link`-terminal slot → `inner`'s
            // `linked_entry`, so the NEXT run of `current_link` `jmp`s straight
            // into `inner` under the shared frame — the continuation→inner hop
            // fuses into one native call, no ~600 ns Zig re-entry. Gated on:
            //  - native tier (tier-1a has no slots);
            //  - `safe_to_arm` (no safepoint-line/suspend recording — an armed
            //    hop erases the 8-hop observation boundary, doc 17 must-fix);
            //  - `inner.inputs.len == 0` (a bare `jmp` can't seed inputs);
            //  - fail-closed same-inner check: the terminal slot we arm must
            //    actually name THIS inner's root PC, else stay unarmed.
            // CRITICAL: read the terminal from `current_link` HERE, AFTER the
            // possible driver swap above (prime-side ramp → continuation). The
            // hop-top `link_term` is the *ramp's* terminal; arming `current_link`'s
            // (now the continuation's) slot while validating the ramp's `aux` would
            // point the continuation's slot at a root its own `.link` doesn't name.
            // `findLinkTrace` only proved the continuation ends in `.link`, not that
            // its `aux == inner_pc`, so we must re-check the trace we actually arm.
            // The `.link` terminal is the last IR instr, so its slot index is
            // `instrs.len - 1` (slots are indexed by IR instr index). Persisted via
            // `armNativeLink` (registers the P-E backlink so a retiring `inner`
            // resets the slot before its mcode is reused).
            const arm_term = current_link.instrs[current_link.instrs.len - 1];
            if (tier == .native_only and safe_to_arm and inner.inputs.len == 0 and
                arm_term.op == .link and @as(u32, @intCast(arm_term.aux)) == inner_pc)
            {
                if (self.nativeFor(inner)) |inat| {
                    if (inat.linked_entry) |le| {
                        const slot: u32 = @intCast(current_link.instrs.len - 1);
                        if (self.armNativeLink(current_link, slot, inner, le, .link_terminal) catch false) {
                            self.native_link_arms +|= 1;
                        }
                    }
                }
            }

            // 2.3c-2b: run the continuation and REPLAY its per-transition ledger,
            // which authoritatively records each fused `C→I` hop the terminal-only
            // scalar fields hide (a `C.link` slot armed in 2.3b-1 makes `snt.run` jmp
            // straight into a child inner root under the shared frame — "outer
            // advanced + inner ran" collapsed into one native call). `replayContinuationLedger`
            // reproduces the exact accounting the old scalar drain did (byte-identical
            // in 2.3c-2b: ≤2-entry ledgers whose terminal == the scalar result); it
            // generalizes to the closed `C→I→C→…` cycle 2.3c-2c arms. Panics on an
            // unresolvable/mis-shaped fused id — the SAME hard invariant as before.
            if (tier == .native_only) {
                var cresult = snt.runCapturingLedger(regs, &self.ledger_scratch);
                while (true) {
                    switch (self.replayContinuationLedger(
                        self.ledger_scratch[0..cresult.ledger_len],
                        current_link,
                        inner_pc,
                        proto,
                        &linked_completed,
                        &resume_pc,
                        &hops,
                        max_hops,
                    )) {
                        // Re-run the still-armed continuation for the next fused span.
                        .run_continuation => cresult = snt.runCapturingLedger(regs, &self.ledger_scratch),
                        // Standalone `.link`: resume inner fresh next hop.
                        .run_inner => continue :hop,
                        .return_result => |cr| return cr,
                        // Hop budget / zero-progress deopt → penalty-neutral tail.
                        .break_burst => break :hop,
                    }
                }
            } else {
                // Tier-1a never fuses (no slots), so `execute` is always the
                // continuation's OWN single-exit result — replay the scalar terminal
                // exactly as before (no ledger to consume).
                const cbuf = self.valuesScratch(current_link.instrs.len) catch break;
                const cresult = irinterp.execute(current_link, regs, cbuf);
                if (cresult.exit_instr == current_link.instrs.len - 1) {
                    // Standalone `.link` at the continuation's terminal: `inner_pc` is
                    // this hop's entry-link target (stable across a prime-side→cont
                    // swap; the next hop recomputes it from `current_link`).
                    resume_pc = inner_pc;
                    continue;
                }
                if (cresult.completed > 0) {
                    self.onSideExit(current_link, cresult.completed);
                    return .{ .completed = linked_completed + cresult.completed, .resume_pc = resume_pc };
                }
                break;
            }
        }
        if (linked_completed > 0) {
            // A successful coherent chain burst is **penalty-neutral** for the
            // seed anchor — deliberately no `onSideExit` here. The burst
            // committed `linked_completed` enclosing iterations AND their whole
            // inner-loop bodies natively rather than dropping to tier-0. The raw
            // enclosing count is usually 1-2 (nsieve: one prime, then a composite
            // ends the cluster), which is BELOW `min_useful`, so the pre-fix
            // `onSideExit(sct, linked_completed)` took the low-yield branch and
            // bumped the seed's anchor penalty. On doc 16's prime path the seed
            // (the prime side-trace) *shares* its outer-header anchor with the
            // profitable skip trace, so that penalty gated BOTH and escalated to
            // a permanent strike within ~0.1% of the run — collapsing skip
            // coverage (21k native entries → ~15) and causing the whole Phase-2/3
            // regression. The seed's real profitability is already tracked by its
            // own standalone entries; a productive chain must not add a low-yield
            // strike here. (Clearing the penalty/gate instead — crediting it as
            // *useful* — was measured worse: it defeats the gate that parks the
            // anchor and thrashes on re-walk/recompile. Neutral is correct.)
            // Mode-invariant: `linked_completed` and the anchor match across
            // tier-1a/native, so no mode records a different penalty here.
            return .{ .completed = linked_completed, .resume_pc = resume_pc };
        }
        self.onSideExit(sct, 0);
        // A burst that committed nothing hasn't advanced `resume_pc` past its
        // initial inner-root PC, so this is the coherent resume target.
        return .{ .completed = 0, .resume_pc = resume_pc };
    }

    /// True when a native trace has a link-terminated continuation waiting at one
    /// of its numeric-for loop-done exits. The dispatcher uses this before native
    /// entry so the original run can commit the final iteration in linked mode;
    /// after a normal native deopt the pre-run snapshot needed for that commit is
    /// already gone.
    pub fn hasNativeLoopDoneLink(self: *const TraceState, failed: *const Trace, proto: *const Proto) bool {
        for (failed.instrs) |ins| {
            if (ins.op != .guard_true) continue;
            const exit_pc = guardExitPc(ins) orelse continue;
            if (exit_pc == 0 or exit_pc == failed.anchor.pc or exit_pc > proto.code.len) continue;
            if (proto.code[exit_pc - 1].op != .for_loop) continue;

            var visited: [8]*Trace = undefined;
            var nvisited: usize = 0;
            var st: ?*Trace = self.nextTraceExcluding(proto, exit_pc, visited[0..0]);
            while (st) |sct| : (st = if (nvisited < visited.len)
                self.nextTraceExcluding(proto, exit_pc, visited[0..nvisited])
            else
                null)
            {
                if (nvisited < visited.len) {
                    visited[nvisited] = sct;
                    nvisited += 1;
                }
                if (sct.inputs.len != 0) continue;
                if (sct.instrs.len != 0 and sct.instrs[sct.instrs.len - 1].op == .link) return true;
            }
        }
        return false;
    }

    /// **Nested-loop continuation arming (Phase 1).** Called on a *productive*
    /// (`completed > 0`) side-exit of a numeric-`for` trace whose terminal
    /// loop-continuation `guard_true` failed — i.e. the inner loop ran to
    /// completion. When that exit can reach an enclosing loop's back-edge (either
    /// immediately, or after straight-line outer-body work like nsieve's count
    /// update), this is a 2-level nest: arm a *continuation* recording anchored at
    /// `exit_pc`, the post-inner-loop pc, so it records the outer body forward and
    /// links back to this inner root instead of unrolling it.
    ///
    /// The recording does **not** begin here. tier-0 must first deopt-replay the
    /// inner loop's final iteration (the productive exit side-exits before
    /// committing it); `maybeStartContinuation` activates the recording once
    /// `cur_pc` reaches `exit_pc`, so the recorder's first op is the outer body,
    /// never a stray inner iteration.
    ///
    /// Conservative + self-limiting, and output-preserving: the scan is bounded,
    /// stops at returns, and only accepts a later back-edge whose target encloses
    /// the inner anchor; an already-traced, gated, or already-pending anchor is
    /// skipped. See `docs/design/15-nested-loop-linking.md`.
    pub fn maybeArmContinuation(self: *TraceState, failed: *const Trace, exit_instr: u32, proto: *const Proto) void {
        if (exit_instr == std.math.maxInt(u32)) return; // no guard identity
        if (self.rec.active or self.pending_exit_anchor != null) return;
        const ins = failed.instrs[exit_instr];
        // Only a loop-continuation `guard_true` failing marks "loop ran to
        // completion"; a body type-guard (`guard_int`/…) failing is a different,
        // mid-iteration exit and must not seed a continuation.
        if (ins.op != .guard_true) return;
        const exit_pc = guardExitPc(ins) orelse return;
        if (exit_pc == 0 or exit_pc == failed.anchor.pc) return;
        if (exit_pc >= proto.code.len) return;
        if (proto.code[exit_pc - 1].op != .for_loop) return;
        if (!continuationReachesEnclosingBackEdge(proto, exit_pc, failed.anchor.pc)) return;
        const key = AnchorKey{ .proto = proto, .pc = exit_pc };
        // Don't fight the normal machinery: a trace already cached here, or a gated
        // anchor (a prior continuation aborted → back off), is left alone.
        if (self.hasTrace(key) or self.isGated(key)) return;
        self.pending_exit_anchor = key;
    }

    fn continuationReachesEnclosingBackEdge(proto: *const Proto, start_pc: u32, inner_anchor: u32) bool {
        const scan_limit: usize = @min(proto.code.len, @as(usize, @intCast(start_pc)) + 128);
        var pc: usize = @intCast(start_pc);
        while (pc < scan_limit) : (pc += 1) {
            const ins = proto.code[pc];
            switch (ins.op) {
                .for_loop, .tfor_loop => {
                    const target = @as(i64, @intCast(pc)) + 1 + ins.aux;
                    if (target >= 0 and target <= @as(i64, @intCast(inner_anchor))) return true;
                },
                .ret, .halt => return false,
                else => {},
            }
        }
        return false;
    }

    /// Dispatch-prologue hook (Phase 1): activate a pending continuation recording
    /// the instant tier-0 reaches its (non-header) anchor pc. By construction this
    /// is *after* the inner loop's final-iteration deopt-replay, so the recorder's
    /// first instruction is the outer body. A no-op (one optional read) when
    /// nothing is pending — the common case. On allocator OOM the arm is dropped
    /// (recording simply doesn't start; tier-0 is unaffected).
    pub fn maybeStartContinuation(self: *TraceState, proto: *const Proto, cur_pc: u32) void {
        const key = self.pending_exit_anchor orelse return;
        if (self.rec.active) return; // never clobber an in-flight recording
        if (key.proto != proto or key.pc != cur_pc) return;
        self.pending_exit_anchor = null;
        self.rec.reset(self.gpa, key, proto.num_registers) catch return;
        // Mark this recording a continuation so `recForPrepLink` may close it with a
        // `.link` at the inner `for_prep` (a root recording, armed via `arm`, leaves
        // this `.root` and instead LINNER-aborts there — LuaJIT's model).
        self.rec.kind = .continuation;
    }

    /// Dispatch-prologue hook (doc 16, Phase 2): activate a pending *prime
    /// side-trace* recording the instant tier-0 reaches its anchor pc. Unlike
    /// `maybeStartContinuation`, the anchor is the failed trace's OWN coherent
    /// anchor (the outer header): the registers are already coherent there from the
    /// productive exit, so tier-0 re-enters at the anchor with no deopt-replay and the
    /// recorder's first instruction is the outer body's taken (prime) branch. Records
    /// forward through the inner `for_prep`; `recForPrepLink` closes it with a `.link`
    /// to the inner root (permitted because `kind == .side`). A no-op (one optional
    /// read) when nothing is pending. On allocator OOM the arm is dropped.
    pub fn maybeStartReplaySide(self: *TraceState, proto: *const Proto, cur_pc: u32) void {
        const key = self.pending_replay_anchor orelse return;
        if (self.rec.active) return; // never clobber an in-flight recording
        if (key.proto != proto or key.pc != cur_pc) return;
        self.pending_replay_anchor = null;
        self.rec.reset(self.gpa, key, proto.num_registers) catch return;
        self.rec.kind = .side;
    }

    /// Drop pending `.full`-pinning arms (continuation *and* prime-side replay).
    /// Used when VM execution leaves the dispatch loop before the `.full` prologue
    /// can consume them (error, suspension, or frame unwind), so the VM cannot stay
    /// pinned in `.full` mode behind a stale pending anchor.
    pub fn clearPendingExitAnchor(self: *TraceState) void {
        self.pending_exit_anchor = null;
        self.pending_replay_anchor = null;
    }

    /// Count a guard failure at `exit_pc` within a trace anchored at `anchor`.
    /// When the counter crosses `config.hotguard`, sets `wants_side_trace` so
    /// the next back-edge records a side trace for the alternate path.
    /// Called from the dispatch loop after a zero-iteration guard failure.
    pub fn countGuardFailure(self: *TraceState, anchor: AnchorKey, exit_pc: u32) void {
        // Don't bother counting if we already have multiple traces here —
        // additional side traces beyond the first few have diminishing returns
        // and cause unbounded cache growth on alternating-type loops.
        if (self.countTracesAt(anchor) >= 2) return;

        const key = GuardKey{ .anchor = anchor, .exit_pc = exit_pc };
        const gop = self.guard_failures.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_side_trace == null) {
            self.wants_side_trace = anchor;
        }
    }

    /// Count a fingerprint miss: no cached trace at `anchor` matched the
    /// current register types.  Uses the same side-trace threshold
    /// (`config.hotguard`) as `countGuardFailure`, but the key has
    /// `exit_pc == 0` to distinguish it from real guard failures.
    /// Called from the dispatch loop when all traces are skipped by
    /// fingerprint mismatch.
    pub fn countFingerprintMiss(self: *TraceState, anchor: AnchorKey) void {
        if (self.countTracesAt(anchor) >= 2) return;
        // exit_pc == 0 marks this as a fingerprint miss, not a specific
        // guard failure.  Shares the same counter namespace for the
        // hotguard threshold.
        const key = GuardKey{ .anchor = anchor, .exit_pc = 0 };
        const gop = self.guard_failures.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_side_trace == null) {
            self.wants_side_trace = anchor;
        }
    }

    /// **Coherent-state chaining (doc 16, Phase 2) discriminator.** True iff
    /// `failed.instrs[exit_instr]` is a *source-level branch guard* exit — a
    /// `guard_true`/`guard_false` whose exit PC is a real bytecode pc NOT immediately
    /// preceded by a `for_loop`. The `for_loop` predecessor marks a numeric-`for`
    /// *loop-done* guard (a continuation candidate, doc 15); everything else that is
    /// a branch guard is a prime-side-trace candidate. Shared by the counter, the
    /// arm gate, and the chain gate so all three agree on "what is a prime-side exit".
    ///
    /// Only numeric `for_loop` needs excluding: generic-for (`tfor_loop`) is
    /// unrecordable (the recorder aborts on it), so a loop-done guard for a
    /// generic-for never reaches a trace and can't reach this discriminator — there
    /// is no false-negative where a real branch guard is mistaken for a loop-done one.
    pub fn isSourceBranchGuardExit(self: *const TraceState, failed: *const Trace, exit_instr: u32, proto: *const Proto) bool {
        _ = self;
        if (exit_instr == std.math.maxInt(u32)) return false;
        const ins = failed.instrs[exit_instr];
        if (ins.op != .guard_true and ins.op != .guard_false) return false;
        const exit_pc = guardExitPc(ins) orelse return false;
        if (exit_pc == 0 or exit_pc == failed.anchor.pc) return false;
        if (exit_pc <= proto.code.len and proto.code[exit_pc - 1].op == .for_loop) return false;
        return true;
    }

    /// 2.3c-1 (M1 half-fusion, doc 17): recognize a fused skip→prime-side receipt by
    /// **armed-edge provenance**, returning `parent`'s source-branch guard slot index
    /// if this receipt came through a slot the M1 arm (`driveChain`) established, else
    /// null. The dispatcher calls this after a native run returned `final != ct` — some
    /// child performed the final exit — to decide whether it was the skip→ramp fusion.
    ///
    /// Two distinct fusions can surface `final != ct` at the top level once 2.3c lands,
    /// and they MUST be told apart by the armed slot's *guard shape*, not by
    /// `final.instrs[exit_instr].op == .link` (which OOBs on a fused prologue-fail and
    /// false-positives on the persistently-armed inner→continuation once 2.3c-2 lands):
    ///   - **2.3b-1 continuation→inner** (`.link_terminal` slot: `C.link →
    ///     I.linked_entry`): the armed slot is `C`'s `.link` terminal, NOT a source-
    ///     branch guard → `isSourceBranchGuardExit` false → excluded (falls through to
    ///     the existing `final`-routed handling).
    ///   - **2.3c-1 skip→prime-side** (`.ordinary_guard` slot: `skip.guard →
    ///     ramp.ordinary_entry`): the armed slot IS a source-branch guard of `ct` →
    ///     recognized here.
    ///
    /// Corroborating shape checks (all cheap, all mode-invariant): the armed record must
    /// name exactly `{parent = ct, child = final}`, `slot_index` must be an
    /// `isSourceBranchGuardExit` of `ct`, and `final.anchor == ct.anchor` (skip and its
    /// prime-side ramp are both anchored at the outer header). The CALLER still applies
    /// the `exit_reason == .normal ∧ exit_instr < final.instrs.len` bounds gate before
    /// indexing `final.instrs` — this helper only proves provenance, never touches the
    /// receipt fields.
    pub fn fusedSourceBranchLinkSlot(self: *const TraceState, parent: *Trace, child: *Trace, proto: *const Proto) ?u32 {
        if (parent == child) return null;
        if (child.anchor.proto != parent.anchor.proto or child.anchor.pc != parent.anchor.pc) return null;
        for (self.armed_links.items) |l| {
            if (l.parent != parent or l.child != child) continue;
            if (!self.isSourceBranchGuardExit(parent, l.slot_index, proto)) continue;
            return l.slot_index;
        }
        return null;
    }

    /// **Coherent-state chaining (doc 16, Phase 2).** Count a *productive*
    /// (`completed > 0`, gated by the caller) source-level branch-guard exit for
    /// prime-side-trace arming. A **source-level branch guard** is any
    /// `guard_true`/`guard_false` whose exit PC is NOT immediately preceded by a
    /// `for_loop` — that predecessor marks a numeric-`for` *loop-done* guard, which
    /// is handled by continuations (doc 15), never a prime side-trace. When the
    /// per-guard counter crosses `config.hotguard`, sets `wants_prime_side` so the
    /// productive-exit site arms an immediate replay of the current (prime)
    /// iteration. Symmetric with `countGuardFailure`, but on the *productive* path
    /// and in its own `prime_exits` map (no cross-talk with the zero-exit side-trace
    /// counters). Mode-invariant: keys only off the caller's `completed > 0` gate and
    /// guard identity (`exit_instr` → `guardExitPc` → `proto.code[exit_pc-1]`), all
    /// reported identically by tier-1a and native.
    pub fn countProductiveBranchExit(self: *TraceState, failed: *const Trace, exit_instr: u32, proto: *const Proto) void {
        if (!self.isSourceBranchGuardExit(failed, exit_instr, proto)) return;
        // Same diminishing-returns cap as `countGuardFailure` — this also bounds
        // prime side-traces to one per anchor: once the skip trace + prime side
        // coexist (`countTracesAt == 2`), counting stops and never re-arms.
        if (self.countTracesAt(failed.anchor) >= 2) return;

        const exit_pc = guardExitPc(failed.instrs[exit_instr]).?; // checked by the discriminator
        const key = GuardKey{ .anchor = failed.anchor, .exit_pc = exit_pc };
        const gop = self.prime_exits.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_prime_side == null) {
            self.wants_prime_side = failed.anchor;
        }
    }

    /// Remove all productive-branch counters for `anchor`. Called after a prime
    /// side-trace is armed so the counter resets and doesn't re-trigger. Mirrors
    /// `clearGuardFailures`.
    pub fn clearPrimeExits(self: *TraceState, anchor: AnchorKey) void {
        var to_remove: std.ArrayListUnmanaged(GuardKey) = .empty;
        var iter = self.prime_exits.keyIterator();
        while (iter.next()) |k| {
            if (k.anchor.proto == anchor.proto and k.anchor.pc == anchor.pc) {
                // OOM here is benign: a counter left behind just means the
                // per-anchor productive count keeps its value, and the
                // `countTracesAt(anchor) >= 2` cap in countProductiveBranchExit
                // already prevents re-arming once the prime side-trace exists.
                // Worst case is a stale map entry, never a correctness issue.
                to_remove.append(self.gpa, k.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            _ = self.prime_exits.remove(k);
        }
        to_remove.deinit(self.gpa);
    }

    /// How many cached traces are at this anchor? `pub` so the dispatcher's M1 fused
    /// consumer (interp.zig) can assert the skip+prime-side pair coexist (≥ 2).
    pub fn countTracesAt(self: *const TraceState, anchor: AnchorKey) usize {
        var n: usize = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto == anchor.proto and t.anchor.pc == anchor.pc) n += 1;
        }
        return n;
    }

    /// Widen-eviction predicate: is trace `t` permanently dead because the live
    /// array its `guard_lane` pins has monotonically widened past the trace's
    /// recorded lane?  A trace specialises on `tbl.array.lane == aux`; lanes only
    /// ever widen (`array.zig`, `Lane.canWidenTo`) and never re-narrow, so once
    /// the live table sits on a lane that cannot reach the recorded lane, the
    /// guard can never pass again.  Re-derived from the live `regs` (not the
    /// failing-guard index), so it holds identically whether the trace ran on
    /// tier-1a or native — it does not depend on which guard failed.
    ///
    /// Returns true if *any* of `t`'s entry `guard_lane`s is now unsatisfiable.
    /// Reading a now-wider lane off a *different* table that happens to flow
    /// through the same anchor is a benign false positive: eviction only drops a
    /// cache entry (tier-0 stays the oracle and the trace simply re-records), it
    /// can never change observable output.
    pub fn laneWidenedPast(self: *const TraceState, t: *const Trace, regs: RegWindow) bool {
        _ = self;
        for (t.instrs) |ins| {
            if (ins.op != .guard_lane) continue;
            // `guard_lane.a` indexes the table-producing instr; that is a
            // `slot_load` whose `aux` is the tier-0 register the table lives in.
            const ld_idx: usize = @intCast(ins.a);
            if (ld_idx >= t.instrs.len) continue;
            const ld = t.instrs[ld_idx];
            if (ld.op != .slot_load) continue;
            const reg: usize = @intCast(ld.aux);
            if (reg >= regs.len()) continue;
            const v = regs.get(reg);
            if (!v.isHeap() or v.heapType() != .table) continue;
            const live_lane = table_mod.Table.fromHeader(v.asHeap()).array.lane;
            const trace_lane: arr.Lane = @enumFromInt(ins.aux);
            if (live_lane != trace_lane and !live_lane.canWidenTo(trace_lane)) return true;
        }
        return false;
    }

    /// Remove a trace from the cache and free it. Used by widen-eviction to
    /// retire a permanently-dead trace so its per-anchor slot frees up for the
    /// stabilised wider-lane trace. Cache entries are `*Trace`, so removing one
    /// never invalidates pointers to the others — but the caller must NOT be
    /// mid-iteration over the cache through this trace (see the dispatch loop,
    /// which defers eviction until after its same-anchor walk completes).
    /// Arm a native link (P-E, doc 17 Increment 2.3): point `parent`'s frameless exit
    /// slot at `slot_index` to the absolute `target` (a child body entry), and record
    /// the dependency so the link can be reset if either end retires. Re-arming the
    /// same slot supersedes the prior record. No-op (returns) if `parent` is not a
    /// compiled frameless trace or the slot index is out of range. The registry append
    /// happens *before* the slot write so an OOM can never leave an armed-but-untracked
    /// slot (which would dangle on the child's retire).
    /// Returns `true` iff the link was actually armed (slot written + record kept).
    /// Returns `false` for the no-op cases — `parent` is not a compiled frameless
    /// trace, or `slot_index` is out of range — so the caller (2.3b `driveChain`)
    /// can keep its accounting identical across modes (P-F): a slot that did not
    /// arm must leave the dispatcher path unchanged.
    ///
    /// INVARIANT: this is the *only* place `CompiledTrace.slots[i]` is ever written
    /// to a non-`shared_exit` value. The entire P-E lifetime argument (a retiring
    /// child resets every parent slot pointing into it) depends on the registry
    /// seeing every armed slot — a direct `c.slots[i] = target` elsewhere would
    /// strand an untracked slot and reintroduce the S2 use-after-reuse.
    pub fn armNativeLink(self: *TraceState, parent: *Trace, slot_index: u32, child: *Trace, target: usize, kind: ArmKind) !bool {
        const c = switch (parent.native) {
            .compiled => |*cc| cc,
            else => return false,
        };
        if (slot_index >= c.slots.len) return false;
        // P-C option (b) invariant (2.3c-0a): a numeric-for loop-done guard's slot is
        // exclusively its linked-materialized exit. Enforce that the arm's declared kind
        // matches the slot's guard shape — a mismatch is a wiring bug (assert in debug),
        // and fail closed (leave the slot unarmed) in release. The emission half (0f)
        // already routes a loop-done ordinary deopt around `slot[ei]`; this closes the
        // arming half so no ordinary/link arm can ever write a loop-done slot (and no
        // loop-done arm can land on a non-loop-done slot).
        const is_loopdone = isLoopDoneGuardIndex(parent, slot_index);
        switch (kind) {
            .loop_done_linked => {
                std.debug.assert(is_loopdone);
                if (!is_loopdone) return false;
            },
            .link_terminal, .ordinary_guard => {
                std.debug.assert(!is_loopdone);
                if (is_loopdone) return false;
            },
        }
        // A re-arm of this exact slot supersedes any prior child it pointed at.
        // Mutate the existing record IN PLACE (no allocation) — the earlier
        // remove-then-append ordering could OOM after dropping the old record,
        // stranding the slot armed-but-untracked (2.3a review BUG-1). Because at
        // most one record exists per (parent, slot_index) — this loop guarantees
        // it — the first match is the only match.
        for (self.armed_links.items) |*l| {
            if (l.parent == parent and l.slot_index == slot_index) {
                l.child = child;
                c.slots[slot_index] = target;
                return true;
            }
        }
        // Fresh slot: append the record BEFORE writing the slot, so a failed append
        // leaves the slot at its prior `shared_exit` value with no dangling record.
        try self.armed_links.append(self.gpa, .{ .parent = parent, .slot_index = slot_index, .child = child });
        c.slots[slot_index] = target;
        return true;
    }

    /// Lifetime-safe teardown of every armed link touching `t` (P-E, doc 17). Called
    /// *before* `t.destroy` in `removeTrace`. Two directions, both keyed by trace
    /// identity so the result is independent of which end retires first:
    ///   - `t` is a link *target* (child): reset each surviving parent's slot back to
    ///     `shared_exit`, so once `t`'s arena slot returns to the reuse free-list no
    ///     parent still jumps into what may become foreign code.
    ///   - `t` is a link *source* (parent): its slot array is about to be freed, so
    ///     just drop the record (no slot to preserve) — a later child-retire must not
    ///     write through the freed slot.
    /// The slot address is re-derived from the live `parent` here, never cached, so it
    /// is always valid at the moment of the write.
    pub fn resetLinksTouching(self: *TraceState, t: *Trace) void {
        const shared_exit = self.mcode_arena.trampoline_exit orelse 0;
        var i: usize = self.armed_links.items.len;
        while (i > 0) {
            i -= 1;
            const link = self.armed_links.items[i];
            if (link.child != t and link.parent != t) continue;
            if (link.child == t and link.parent != t) {
                switch (link.parent.native) {
                    .compiled => |*c| if (link.slot_index < c.slots.len) {
                        c.slots[link.slot_index] = shared_exit;
                    },
                    else => {},
                }
            }
            _ = self.armed_links.swapRemove(i);
        }
    }

    /// Disarm-on-unsafe (2.3c-0e, doc 17; Bart's chosen cycle bound). Reset EVERY
    /// armed native link's parent slot back to `shared_exit` and clear the registry.
    /// Called from the dispatcher when it is about to run native while an
    /// observation/suspend/replay window is active (`safe_to_arm == false`), so no
    /// native→native handoff fires through a patched slot and skips the dispatcher's
    /// safepoint/GC boundary. The next handoff attempt then returns to the dispatcher,
    /// which re-establishes the boundary and — once safe again — may re-arm.
    ///
    /// Inert while nothing is armed (the guard makes it a single length check).
    /// Idempotent: after a call the registry is empty, so a second call is a no-op —
    /// which edge-triggers it in practice (disarm once on entering the unsafe window,
    /// then nothing until arming resumes). The slot address is re-derived from the
    /// live `parent`, never cached, exactly as `resetLinksTouching` does.
    pub fn disarmAllLinks(self: *TraceState) void {
        if (self.armed_links.items.len == 0) return;
        const shared_exit = self.mcode_arena.trampoline_exit orelse 0;
        for (self.armed_links.items) |link| {
            switch (link.parent.native) {
                .compiled => |*c| if (link.slot_index < c.slots.len) {
                    c.slots[link.slot_index] = shared_exit;
                },
                else => {},
            }
        }
        self.armed_links.clearRetainingCapacity();
    }

    pub fn removeTrace(self: *TraceState, t: *Trace) void {
        for (self.cache.items, 0..) |c, idx| {
            if (c == t) {
                const anchor = t.anchor;
                // P-E: reset/drop every armed native link touching `t` before its
                // mcode slot can be freed and reused (see `resetLinksTouching`).
                self.resetLinksTouching(t);
                _ = self.cache.swapRemove(idx);
                t.destroy(self.gpa);
                // Reopen the anchor for re-recording. `onBackEdge` only arms when
                // its hot-counter *crosses* `hotloop` (a one-shot `==`), so an
                // anchor whose counter is already past that point would never
                // re-record after losing its trace — the loop would run the rest
                // fully tier-0. Resetting the counter lets the next `hotloop`
                // back-edges re-arm a recording, which now observes the
                // stabilised wider lane. Only do this once the anchor has no
                // traces left (a still-populated anchor re-records via its own
                // side-trace path and `hasTrace` would block re-arming anyway).
                // Bounded by the lattice depth: an anchor widens at most
                // value←i64←i32←i16←i8 / boolean / f64 times before it stabilises.
                if (self.countTracesAt(anchor) == 0) {
                    if (self.counters.getPtr(anchor)) |cnt| cnt.* = 0;
                }
                return;
            }
        }
    }

    /// Remove all guard-failure entries for `anchor`. Called after a side
    /// trace is armed so the counter resets and doesn't re-trigger infinitely.
    fn clearGuardFailures(self: *TraceState, anchor: AnchorKey) void {
        var to_remove: std.ArrayListUnmanaged(GuardKey) = .empty;
        var iter = self.guard_failures.keyIterator();
        while (iter.next()) |k| {
            if (k.anchor.proto == anchor.proto and k.anchor.pc == anchor.pc) {
                to_remove.append(self.gpa, k.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            _ = self.guard_failures.remove(k);
        }
        to_remove.deinit(self.gpa);
    }

    /// Resolve (and memoize) the tier-1b native compilation of `t`. Returns a
    /// runnable `CompiledTrace` to take the native path, or `null` to fall back to
    /// the tier-1a IR-interpreter. The first call compiles lazily; the verdict
    /// (`.compiled` page / `.unsupported`) is cached on the trace and never
    /// recomputed. Off-target builds (e.g. wasm) always memoize `.unsupported`.
    pub fn nativeFor(self: *TraceState, t: *Trace) ?*const nativegen.CompiledTrace {
        switch (t.native) {
            .compiled => return &t.native.compiled,
            .unsupported => return null,
            .unattempted => {
                if (nativegen.compileInto(self.gpa, &self.mcode_arena, t)) |ct| {
                    t.native = .{ .compiled = ct };
                    return &t.native.compiled;
                }
                t.native = .unsupported;
                return null;
            },
        }
    }

    /// True while a recording is in flight (the interpreter's recording hook
    /// gates on this).
    pub fn isRecording(self: *const TraceState) bool {
        return self.rec.active;
    }

    /// Is this anchor currently gated off tier-1? True while a cooldown window is
    /// still running (back-edge count below `retry_at`) or the anchor has been
    /// permanently abandoned (`strikes >= max_strikes`). False when no gate exists
    /// or its cooldown has elapsed (eligible for one retry). Gates both recording
    /// re-arm (`onBackEdge`) and trace entry (the dispatch loop).
    pub fn isGated(self: *const TraceState, anchor: AnchorKey) bool {
        const g = self.gate.get(anchor) orelse return false;
        if (g.strikes >= self.config.max_strikes) return true;
        return self.tick < g.retry_at;
    }

    /// Install or escalate the gate on `anchor`: start (or double) the cooldown
    /// window and bump the strike count. The next eligibility is `retry_at` =
    /// current global `tick` + window; the window then doubles (capped at
    /// `backoff_max`) so a repeatedly-failing anchor is retried exponentially
    /// less often, and after `max_strikes` it is abandoned for good. Deterministic
    /// — keyed only on the monotonic back-edge tick, which keeps advancing even
    /// while the hot-count pre-filter is skipping this anchor's back-edges.
    fn gateAnchor(self: *TraceState, anchor: AnchorKey) void {
        const gop = self.gate.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .retry_at = 0, .window = self.config.backoff_base, .strikes = 0 };
        }
        const g = gop.value_ptr;
        g.strikes +|= 1;
        g.retry_at = self.tick +| g.window;
        g.window = @min(g.window *| 2, self.config.backoff_max);
    }

    /// Back-edge count recorded for an anchor (0 if never seen). A loop is "hot"
    /// once this reaches `config.hotloop`.
    pub fn backEdgeCount(self: *const TraceState, anchor: AnchorKey) u32 {
        return self.counters.get(anchor) orelse 0;
    }

    // --- hot-count pre-filter ----------------------------------------------

    /// Cheap front gate for the dispatch back-edge handler. Always advances the
    /// global `tick` (so gate cooldowns keep elapsing), then asks: can this
    /// back-edge skip the expensive slow path (`onBackEdge` + trace-entry lookup)?
    ///
    /// Returns `true` (skip — fall straight back to tier-0) when the anchor's
    /// hot-count slot is still counting down. Returns `false` (take the slow path)
    /// when the slot has reached 0, or while a recording is in flight (recording
    /// must see every back-edge so it can close on its own anchor). Only gated /
    /// dead loops ever get a non-zero slot, so hot traced loops and warming loops
    /// always take the slow path and behave exactly as before the pre-filter.
    pub inline fn skipBackEdge(self: *TraceState, proto: *const Proto, pc: u32) bool {
        self.tick +%= 1;
        if (self.rec.active) return false;
        const slot = &self.hotcount[hotIndex(proto, pc)];
        if (slot.* > 0) {
            slot.* -= 1;
            return true;
        }
        return false;
    }

    /// Called after a back-edge took the slow path *without* entering a trace (the
    /// dispatch loop skips this when a trace entry succeeded). If the anchor is
    /// gated, arm its hot-count slot with a `GATE_SKIP` window so the next batch of
    /// back-edges skips the hashmap bookkeeping entirely. `tick` keeps advancing
    /// across the skip, so the gate's cooldown still elapses on schedule and the
    /// anchor is reconsidered when the window expires.
    pub fn afterBackEdge(self: *TraceState, proto: *const Proto, pc: u32) void {
        if (self.isGated(.{ .proto = proto, .pc = pc })) {
            self.hotcount[hotIndex(proto, pc)] = GATE_SKIP;
        }
    }

    /// Install a precise hot-count skip of `n` back-edges on `anchor`. Used by the
    /// dispatch loop when it declines to enter a numeric-`for` trace on trip-count
    /// grounds: the rest of that short invocation (exactly `trip - 1` back-edges —
    /// the final `for_loop` exits without one) should run on tier-0 without each
    /// back-edge re-paying full `onBackEdge` bookkeeping, but the window must NOT
    /// bleed past this invocation or it could skip the entry of a following
    /// profitable (long) invocation at the same anchor. Because the count is exact,
    /// it never bleeds. Unlike `GATE_SKIP` this does not imply the anchor is gated.
    pub fn armShortLoopSkip(self: *TraceState, proto: *const Proto, pc: u32, n: u64) void {
        self.hotcount[hotIndex(proto, pc)] = @intCast(@min(n, std.math.maxInt(u16)));
    }

    // --- state machine -----------------------------------------------------

    /// Called by the interpreter whenever a back-edge fires (a backward/self jump
    /// to `target_pc`). Drives the trace lifecycle:
    ///  * **recording, this anchor** → the iteration closed cleanly: commit.
    ///  * **recording, another anchor** → an inner-loop back-edge: keep going
    ///    (the `maxrecord` budget bounds inner-loop unrolling).
    ///  * **not recording** → count this back-edge; on *crossing* `hotloop` (and
    ///    if the anchor is neither already traced nor blacklisted), arm a fresh
    ///    recording that begins on the next loop iteration (at the anchor).
    pub fn onBackEdge(self: *TraceState, proto: *const Proto, target_pc: u32, regs: RegWindow) void {
        if (self.rec.active) {
            if (self.rec.anchor.proto == proto and self.rec.anchor.pc == target_pc) {
                self.closeTrace(regs);
            }
            return;
        }
        const key = AnchorKey{ .proto = proto, .pc = target_pc };

        // Side-trace arming (step 4): a guard inside a trace at this anchor has
        // failed enough times — arm a new recording on the next iteration, even
        // though a trace already exists here. The side trace captures the
        // alternate path through the loop body. This legitimately targets an
        // already-traced anchor, so it must run *before* the has-trace fast path
        // below.
        if (self.wants_side_trace) |wanted| {
            if (wanted.proto == proto and wanted.pc == target_pc) {
                if (!self.isGated(key)) {
                    self.arm(proto, target_pc);
                    // Clear guard-failure counters for this anchor so we don't
                    // immediately re-trigger on the next outer-loop iteration.
                    self.clearGuardFailures(key);
                }
                self.wants_side_trace = null;
                return;
            }
        }

        // Hot native re-entry fast path. Once an anchor is traced, the warming
        // counter can never arm again (`hasTrace` already gated arming below) and
        // nothing functional reads it — only the warming phase and tests do. So
        // for a traced anchor we skip the per-back-edge hashmap bookkeeping
        // entirely: this removes a wyhash `counters.getOrPut` from *every*
        // tier-0 → native trace entry, which is the dominant remaining hash cost
        // on matmul-class loops that re-enter a native inner trace tens of
        // thousands of times. The dispatch loop's own trace-entry walk owns
        // re-entry from here; the cheap linear cache scan in `hasTrace` (a handful
        // of pointer compares) replaces the hash probe.
        if (self.hasTrace(key)) return;

        const gop = self.counters.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        const count = gop.value_ptr.*;
        // Arm a fresh recording when the anchor first becomes hot, or — if it was
        // gated off after an earlier failure — when its backoff cooldown elapses.
        // Each `==` fires exactly once at the crossing point, so we never re-arm
        // on every later iteration. A gated anchor whose cooldown is still running
        // (or that has exhausted `max_strikes`) is skipped by `isGated`. (The
        // `!hasTrace` arm guard is now redundant — we returned above for traced
        // anchors — so only `isGated` remains.)
        if (!self.isGated(key)) {
            // A gate entry that is no longer `isGated` means its `tick` cooldown has
            // just elapsed → take the one retry now. Arming starts a recording, so
            // the next back-edges are consumed by recording rather than re-arming;
            // we never loop re-arming. A fresh (un-gated) anchor arms on the exact
            // back-edge it first crosses `hotloop`.
            const arm_now = if (self.gate.contains(key))
                true // cooldown elapsed → one retry
            else
                count == self.config.hotloop; // first time crossing hot
            if (arm_now) self.arm(proto, target_pc);
        }
    }

    /// Begin recording at `target_pc`. Sizes the recorder's register map to the
    /// frame; recording proper begins at the next dispatch-loop iteration (which
    /// is the anchor instruction). On OOM we simply don't arm.
    fn arm(self: *TraceState, proto: *const Proto, target_pc: u32) void {
        self.rec.reset(self.gpa, .{ .proto = proto, .pc = target_pc }, proto.num_registers) catch return;
    }

    /// Abandon the in-flight recording: deactivate, remember why, and gate the
    /// anchor with exponential backoff so it is retried progressively less often
    /// (and abandoned after `max_strikes`). Tier-0 is untouched — nothing was ever
    /// executed from the trace.
    fn abort(self: *TraceState, reason: AbortReason) void {
        self.rec.abort_reason = reason;
        if (self.config.record_aborts) self.logAbort(reason);
        self.rec.active = false;
        self.gateAnchor(self.rec.anchor);
    }

    /// Append-or-bump the abort diagnostic log (`--dump-aborts`). Deduped by
    /// `(anchor.pc, reason, op)` so a loop aborting on every back-edge is one row
    /// with a growing `count`, not millions. A linear scan is fine — distinct
    /// abort sites are few (a handful of loops × a handful of reasons), and this is
    /// off the hot path entirely (only runs when `config.record_aborts`). On OOM we
    /// simply drop the row: a diagnostic must never perturb execution.
    fn logAbort(self: *TraceState, reason: AbortReason) void {
        const anchor = self.rec.anchor;
        for (self.abort_log.items) |*r| {
            if (r.anchor_pc == anchor.pc and r.proto == anchor.proto and
                r.reason == reason and r.op == self.rec.cur_op)
            {
                r.count += 1;
                return;
            }
        }
        self.abort_log.append(self.gpa, .{
            .proto = anchor.proto,
            .anchor_pc = anchor.pc,
            .abort_pc = self.rec.cur_pc,
            .op = self.rec.cur_op,
            .reason = reason,
            .ir_len = @intCast(self.rec.instrs.items.len),
        }) catch {};
    }

    /// Finalise a cleanly-closed recording into a cached `Trace`. A build failure
    /// is treated like an abort (discard + gate-with-backoff) so we never thrash.
    fn closeTrace(self: *TraceState, regs: RegWindow) void {
        _ = regs; // reserved: a richer exit snapshot will read live values here.
        self.commit() catch {
            self.gateAnchor(self.rec.anchor);
        };
        self.rec.active = false;
    }

    /// Copy the in-progress recording into an owned, cached `Trace`. The exit
    /// snapshot is every register the trace *defined* (its loop-carried writes).
    /// When `config.optimize`, the trace optimizer (`tropt.zig`) rewrites the IR
    /// first; an optimizer OOM falls back to caching the *unoptimized* trace
    /// (correct, just slower) rather than failing the commit.
    fn commit(self: *TraceState) !void {
        // The loop-carried writebacks, as slot-bound φ nodes (one per register the
        // trace defined, minus *dead temporaries*), spliced in just before the
        // terminal `loop`. A slot at/above `locals_watermark` is a compiler
        // expression temporary (set only by the anchoring numeric-`for`'s
        // `for_loop`; see `recForLoop`/`Recorder.locals_watermark`): dead at the
        // loop-header resume point on every path and after the loop, so tier-0
        // recomputes it on deopt and post-loop code never reads it — writing it
        // back is pure waste. The `entry_slots` (`readSlot`) guard is a safety net:
        // a slot the trace actually read is never dropped (it is `< watermark`
        // anyway). When the watermark is the `maxInt` sentinel (while / generic-
        // `for` / passed-through `for`), nothing is filtered.
        //
        // A slot-bound φ's init is implicit (`regs[slot]`, read each entry like the
        // matching `slot_load`), so `a` is 0; `b` is the body def (the update).
        // Flush the deferred read-modify-write stores (store-sinking) at the end of
        // the body, below every guard (the body guards + `recForLoop`'s continuation
        // `guard_true`, all already in the stream) and before the φ writebacks +
        // `.loop`. Sinking them below all side-exiting ops makes deopt-replay
        // idempotent: any guard failure leaves *all* of them un-executed, so tier-0
        // re-runs the whole iteration along the original source path and applies
        // exactly that path's stores once each. Flushed FRONT-TO-BACK in the recorded
        // (tier-0 bytecode) order — so two stores that alias the same slot land in the
        // VM's order and last-writer-wins matches tier-0 (`08-multi-store-sinking.md`).
        // This is exactly where inline (non-deferred) `astore`s sit — the body — so
        // the φ block stays contiguous before `.loop`. Gap B (doc 07) was the single
        // store; Gap C (doc 08) generalizes to an ordered set.
        for (self.rec.pending_stores[0..self.rec.pending_store_count]) |ps| {
            // `ps.op` is `.astore` for a packed-array RMW or `.hstore` for a
            // hash-field RMW (doc 11); both flush below every guard, in recorded
            // order, just before `.loop`. `lane_ord` is the array `Lane` ordinal
            // for `.astore` and unused (0) for `.hstore`.
            try self.rec.instrs.append(self.gpa, .{
                .op = ps.op,
                .a = ps.aref,
                .b = ps.value,
                .aux = ps.lane_ord,
            });
        }
        for (self.rec.reg_map, 0..) |s, slot| {
            if (s.state != .def) continue;
            // S2 (cross-frame tracing): callee slots are pure internal SSA
            // temporaries — defined-before-use inside the inlined body, dead at the
            // loop boundary, never loop-carried. Only anchor-frame slots may carry
            // across iterations (including the return-mapped `ret_dest..` writes,
            // which land back in the anchor window). Writing a callee slot back here
            // would make the `.loop` flush `regs.set` past the executor's real
            // `[0, anchor_num_registers)` window — a silent OOB slab write.
            if (slot >= self.rec.anchor_num_registers) continue;
            if (slot >= self.rec.locals_watermark and !self.readSlot(@intCast(slot))) continue;
            try self.rec.instrs.append(self.gpa, .{
                .op = .phi,
                .a = 0,
                .b = s.ref,
                .aux = @intCast(slot),
                .ty = self.rec.instrs.items[s.ref].ty,
            });
        }
        // Terminal: a continuation that re-reached an inner root closes with a
        // `.link` hand-off (doc 15, Phase 2) carrying the inner anchor pc in `aux`;
        // every other trace closes with the back-edge `.loop`. The φ block above is
        // the register hand-off snapshot in either case.
        if (self.rec.link_target) |lt| {
            try self.rec.instrs.append(self.gpa, .{ .op = .link, .aux = @intCast(lt) });
        } else {
            try self.rec.instrs.append(self.gpa, .{ .op = .loop });
        }

        const instrs = self.rec.instrs.items;
        const consts = self.rec.consts.items;
        const entry = self.rec.entry_slots.items;

        // Link traces are cached **unoptimized**: `tropt.optimize` asserts a `.loop`
        // terminal and its LICM/φ machinery is written for back-edge loops. Phase 3
        // executes link traces through `driveChain`, but the unoptimized straight-line
        // continuation is the intended hand-off shape. `dupe` preserves `.link`.
        const fields: tropt.Optimized = if (self.config.optimize and self.rec.link_target == null)
            tropt.optimize(self.gpa, instrs, consts) catch |e| switch (e) {
                // Never fail a commit (or thrash the anchor) over an optimizer
                // allocation failure: cache the unoptimized trace instead.
                error.OutOfMemory => try tropt.dupe(self.gpa, instrs, consts, entry),
            }
        else
            try tropt.dupe(self.gpa, instrs, consts, entry);
        errdefer {
            self.gpa.free(fields.instrs);
            self.gpa.free(fields.consts);
            self.gpa.free(fields.entry_slots);
        }

        // S3 (cross-frame tracing): pin the verifier's register-window bound to the
        // executor's *real* window (`anchor_num_registers`), not the grown
        // `reg_map.len` (which includes the callee scratch tail). A `slot_load`/`phi`
        // `aux` outside `[0, anchor_num_registers)` is exactly the OOB that S1/S2
        // prevent — so the verifier must reject it, not have its bound widened to
        // hide it.
        assertWellFormed(fields.instrs, fields.consts.len, self.rec.anchor_num_registers, @as(usize, self.rec.anchor_num_registers) + self.rec.input_seeds.items.len);

        // Compute the entry type fingerprint: for each guard_int/guard_float/
        // guard_number/guard_table that guards a slot_load, record the
        // (slot, type) pair.  This lets the dispatch loop skip non-matching
        // traces without a trial entry.
        var entry_guards: std.ArrayListUnmanaged(EntryGuard) = .empty;
        // Covers OOM during the append loop (and a failing `toOwnedSlice`, which
        // leaves the list intact). After `toOwnedSlice` succeeds the list owns
        // nothing, so the freed slice gets its own errdefer below.
        errdefer entry_guards.deinit(self.gpa);
        for (fields.instrs, 0..) |ins, i| {
            const egt: ?EntryGuardType = switch (ins.op) {
                .guard_int => .int,
                .guard_float => .float,
                .guard_number => .number,
                .guard_table => .table,
                else => null,
            };
            if (egt) |ty| {
                const ref: u32 = @intCast(ins.a);
                if (ref < i and fields.instrs[ref].op == .slot_load) {
                    const slot: u16 = @intCast(fields.instrs[ref].aux);
                    // Fingerprint only anchor-frame slots: a synthetic input slot
                    // (`>= anchor_num_registers`, cluster sub-lever 1) is not present
                    // in the narrow `RegWindow` `matchesFingerprint` reads, so adding
                    // it would be an out-of-window read. Its type is still pinned by
                    // the guard in the IR — a mismatch side-exits on a trial entry
                    // instead of being pre-filtered.
                    if (slot < self.rec.anchor_num_registers)
                        try entry_guards.append(self.gpa, .{ .slot = slot, .ty = ty });
                }
            }
        }
        const guards_owned = try entry_guards.toOwnedSlice(self.gpa);
        // Covers OOM in `create(Trace)` and the trailing `cache.append` (the
        // `fields` errdefer above frees the IR arrays; this frees the fingerprint).
        errdefer self.gpa.free(guards_owned);

        // Own the synthetic-input seeding recipe (cluster sub-lever 1). Empty for
        // the common trace (no upvalue/global-reached callee) — a static empty slice
        // needs no free (`destroy` guards on `len != 0`).
        const inputs_owned: []InputSeed = if (self.rec.input_seeds.items.len == 0)
            &.{}
        else
            try self.gpa.dupe(InputSeed, self.rec.input_seeds.items);
        errdefer if (inputs_owned.len != 0) self.gpa.free(inputs_owned);

        const t = try self.gpa.create(Trace);
        errdefer self.gpa.destroy(t);
        // Stable id (P-B): assigned once, never reused. A bump before a failed
        // `cache.append` leaves a harmless gap in the id space (ids need only be
        // unique, not contiguous).
        const new_id = self.next_trace_id;
        self.next_trace_id += 1;
        t.* = .{
            .id = new_id,
            .anchor = self.rec.anchor,
            .instrs = fields.instrs,
            .consts = fields.consts,
            .entry_slots = fields.entry_slots,
            .entry_guards = guards_owned,
            .inputs = inputs_owned,
        };
        try self.cache.append(self.gpa, t);
    }

    /// Debug-only structural verifier for the invariants the tier-1a executor
    /// (`irinterp.zig`) relies on, so a recorder bug can never become a wild read
    /// at execution time. Compiled out in release builds (`std.debug.assert`).
    ///   * the trace is non-empty and terminates in exactly one `loop`;
    ///   * every operand `Ref` is defined earlier (linear SSA: ref < its index);
    ///   * `slot_load`/`konst` `aux` is in register / const-pool bounds;
    ///   * every `phi` update `b` precedes the `loop` and its `aux` slot is a
    ///     register (or the internal sentinel).
    /// `num_registers` is the executor's real loop-carried window
    /// (`anchor_num_registers`) — the bound a `phi` flush may write back to (S2/S3).
    /// `input_limit` is that window *plus* the synthetic entry inputs (cluster
    /// sub-lever 1): a `slot_load` may read an input slot in
    /// `[num_registers, input_limit)`, but no `phi` ever names one (inputs are
    /// read-only, never `.def`), so the phi bound stays tight.
    fn assertWellFormed(instrs: []const IrInstr, consts_len: usize, num_registers: usize, input_limit: usize) void {
        std.debug.assert(instrs.len >= 1);
        const last = instrs.len - 1;
        // The trace terminates in exactly one terminal: `.loop` (root/continuation
        // back-edge) or `.link` (continuation hand-off to an inner root, doc 15).
        std.debug.assert(instrs[last].op == .loop or instrs[last].op == .link);
        for (instrs, 0..) |ins, i| {
            switch (ins.op) {
                .slot_load => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < input_limit),
                .konst => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len),
                .loop => std.debug.assert(i == last), // the only loop, and it is terminal
                // `.link` (doc 15): terminal hand-off to an inner root. Like `.loop`
                // it is the sole terminal; `aux` is the inner anchor pc, not an
                // operand ref, so nothing to bound-check beyond terminality.
                .link => std.debug.assert(i == last),
                // binary ops read both `a` and `b`.
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .eq, .ne, .lt, .le => {
                    std.debug.assert(ins.a < i and ins.b < i);
                },
                // unary ops and guards read `a` only.
                .neg, .not, .bnot, .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .guard_func => {
                    std.debug.assert(ins.a < i);
                },
                // `int_of_float` reads its sole float operand `a` (a prior node).
                .int_of_float => std.debug.assert(ins.a < i),
                // `guard_pure` reads the callee ref `a`; `fsqrt` reads its float
                // operand `a` — both prior nodes.
                .guard_pure, .fsqrt => std.debug.assert(ins.a < i),
                // `aref` pairs (table, index) into an address descriptor;
                // `astore`/`astore_append` read the `aref` (`a`) and the value (`b`).
                // `href` (table, key konst) and `hstore` (href, value) mirror them.
                .aref, .astore, .astore_append, .href, .hstore => std.debug.assert(ins.a < i and ins.b < i),
                // Grid cell access (doc 14, Phase 8): `garow` pairs (table,row),
                // `gcell` pairs (garow,col), `gstore` reads (gcell, value) — all two
                // prior operands. `gload` and the grid guards read one prior node.
                .garow, .gcell, .gstore, .guard_gcol => std.debug.assert(ins.a < i and ins.b < i),
                .gload, .guard_grid, .guard_stride, .guard_gpresent => std.debug.assert(ins.a < i),
                // `aload` and the array-access guards read one prior node
                // (the table value, or the `aref`). `guard_append` reads the `aref`.
                // `hload`/`guard_hash` read the `href` (`a`).
                .aload, .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits, .guard_append, .hload, .guard_hash => {
                    std.debug.assert(ins.a < i);
                },
                // φ: the init `a` is an ordinary backward ref (a < i); the update
                // `b` is the back-edge value and may reference a *later* node, like
                // an `exit_store.ref` — only required to precede the `loop` marker.
                // `aux` is the flush slot (a valid register) or the internal sentinel.
                .phi => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < last);
                    std.debug.assert(ins.aux == PHI_INTERNAL or
                        (ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < num_registers));
                },
                // Preheader region boundary (Phase E1): a pure marker, no operands.
                // Structural invariants (at most one; before any φ) are asserted in
                // the global pass below.
                .preheader => {},
            }
        }
        // Preheader structural rules (Phase E1 / LICM): at most one marker, and no
        // `phi` may precede it (loop-carried values must run every iteration, but a
        // φ before the marker would be skipped on iterations 2+).
        var preheader_idx: ?usize = null;
        for (instrs, 0..) |ins, i| {
            if (ins.op == .preheader) {
                std.debug.assert(preheader_idx == null); // at most one
                preheader_idx = i;
            }
        }
        if (preheader_idx) |ph| {
            for (instrs[0..ph]) |ins| std.debug.assert(ins.op != .phi);
        }
    }

    // --- per-instruction recording ----------------------------------------

    /// Mirror one executed tier-0 instruction into the trace IR, reading
    /// *pre-execution* operand values from `regs` to choose type guards. Tier-0
    /// still executes the instruction itself (next, in the dispatch loop) — this
    /// only records. Unsupported opcodes / types abort the recording.
    /// `pc` is the *post-increment* program counter (already advanced past
    /// `instr`), matching what `applyJump(pc, aux)` expects — `recForLoop` uses it
    /// to resolve the `for_loop` back-edge target against the trace anchor.
    /// `resolved` carries the live value of an upvalue/global read for the two
    /// arms that need it (`get_upval`/`get_global`) — the executor cannot resolve
    /// those (no `*Vm`, no closure), so the dispatch loop pre-resolves and passes
    /// it here. `Value.nil()` (and ignored) for every other opcode.
    pub fn recordInstr(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) void {
        if (self.rec.instrs.items.len >= self.config.maxrecord) return self.abort(.too_long);
        self.rec.cur_pc = pc;
        self.rec.cur_op = instr.op;
        self.recordOne(instr, regs, proto, pc, resolved) catch self.abort(.alloc);
    }

    fn recordOne(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) error{OutOfMemory}!void {
        switch (instr.op) {
            // loads & moves — define the destination, no guards.
            .load_nil => self.setReg(instr.a, try self.konst(Value.nil())),
            .load_bool => self.setReg(instr.a, try self.konst(Value.boolean(instr.b != 0))),
            .load_int => self.setReg(instr.a, try self.konst(Value.int(instr.aux))),
            .load_const => self.setReg(instr.a, try self.konst(proto.constants[instr.b])),
            .move => self.setReg(instr.a, try self.refOf(instr.b)),

            // arithmetic / bitwise / unary.
            .add => try self.recArith(.add, instr, regs),
            .sub => try self.recArith(.sub, instr, regs),
            .mul => try self.recArith(.mul, instr, regs),
            .div => try self.recArith(.div, instr, regs),
            .idiv => try self.recArith(.idiv, instr, regs),
            .mod => try self.recArith(.mod, instr, regs),
            .pow => try self.recArith(.pow, instr, regs),
            .band => try self.recBitwise(.band, instr, regs),
            .bor => try self.recBitwise(.bor, instr, regs),
            .bxor => try self.recBitwise(.bxor, instr, regs),
            .shl => try self.recBitwise(.shl, instr, regs),
            .shr => try self.recBitwise(.shr, instr, regs),
            .sar => try self.recBitwise(.sar, instr, regs),
            .neg => try self.recNeg(instr, regs),
            .not => try self.recNot(instr),
            .bnot => try self.recBnot(instr, regs),

            // comparisons (gt/ge normalise to lt/le with swapped operands).
            .eq => try self.recEq(.eq, instr, regs),
            .ne => try self.recEq(.ne, instr, regs),
            .lt => try self.recCompare(.lt, false, instr, regs),
            .le => try self.recCompare(.le, false, instr, regs),
            .gt => try self.recCompare(.lt, true, instr, regs),
            .ge => try self.recCompare(.le, true, instr, regs),

            // control flow.
            .jmp => {}, // straight-line trace: control flow is implicit.
            .jmp_if_false, .jmp_if_true => try self.recBranch(instr, regs),
            .for_loop => try self.recForLoop(instr, regs, pc),
            // Nested-loop trace linking (doc 15, Phase 2). A continuation recording
            // re-reaching an inner numeric-`for`'s `for_prep` whose loop header
            // already has a root trace records `for_prep`'s pre-decrement and closes
            // with a `.link` to that root, instead of unrolling the inner loop.
            // When no inner root exists yet (or the shape isn't linkable), this falls
            // back to the historical LINNER abort (`.nyi_opcode`) — byte-identical to
            // before — so the inner loop spawns its own root first.
            .for_prep => try self.recForPrepLink(instr, regs, proto, pc),

            // Cross-frame tracing: inline a Lua callee's body straight into the
            // trace (LuaJIT-style `lj_record_call`/`lj_record_ret`). A host
            // (`native`) call stays a trace barrier; anything we can't inline
            // (dynamic multret, vararg, `__call`, too deep) aborts cleanly and
            // tier-0 owns the loop.
            .call => try self.recCall(instr, regs, proto),
            .ret => if (self.rec.inline_depth == 0)
                // A `.ret` in the anchor frame closes the traced function itself —
                // the loop's back-edge always closes the trace first, so this is
                // only reached on an odd shape; abort rather than map results into a
                // caller we never inlined.
                self.abort(.cross_frame)
            else
                try self.recReturn(instr),
            // `.halt` ends the top-level chunk; never a return from an inlined
            // callee. Always a barrier.
            .halt => self.abort(.cross_frame),

            // Table read `t[k]`: an INTEGER key takes the lane-aware packed-array
            // path (Phase B; in-bounds dense narrow-lane slot only); a constant
            // STRING key takes the hash-field path (doc 11, `obj.field`); anything
            // else aborts cleanly. The key type is observed at record time.
            .get_index => if (regs.get(instr.c).isInt())
                try self.recArrayGet(instr, regs)
            else if (isStringKey(regs.get(instr.c)))
                try self.recHashGet(instr, regs)
            else
                self.abort(.bad_type),

            // Table write `t[k]=v`: INTEGER key → packed-array write (Phase B,
            // in-bounds in-lane, C1 deopt-replay rule); constant STRING key →
            // hash-field write (doc 11, present-key overwrite only); else abort.
            .set_index => if (regs.get(instr.b).isInt())
                try self.recArraySet(instr, regs)
            else if (isStringKey(regs.get(instr.b)))
                try self.recHashSet(instr, regs)
            else
                self.abort(.bad_type),

            // Fused two-level access `a[i][j]` / `a[i][j]=v` (doc 14, Phase 8). We
            // record ONLY when the container is already a flattened grid with an
            // int element lane and the access is a present, in-bounds, in-lane cell
            // — exactly the shape the grid native/oracle path models. Everything
            // else (nested tables not yet inflated, a grow/widen store, an f64 grid)
            // aborts to tier-0, which inflates / reshapes / runs the slow path.
            .get_index2 => try self.recGridGet(instr, regs),
            .set_index2 => try self.recGridSet(instr, regs),

            // Cluster sub-lever 1: a callee (or any loop-invariant value) reached
            // through an UPVALUE or GLOBAL. The executor cannot read these (no
            // `*Vm`, no closure), so we snapshot the loop-invariant value into a
            // dead slab slot above the anchor window (`slot_load` from a synthetic
            // input slot the dispatch loop re-seeds each entry) and — when it is a
            // function — pin its identity with `guard_func`. `set_upval`/`set_global`
            // stay aborts (not in this switch): a write in the traced region would
            // make the snapshot stale, so such loops keep running on tier-0.
            .get_upval => try self.recInputGet(.upvalue, instr.a, instr.b, resolved),
            .get_global => try self.recInputGet(.global, instr.a, instr.b, resolved),

            // tables, closures, concat, for_prep, len, …: each pulls in heap-effect
            // / cross-frame / invalidation machinery that is later work. Abort
            // cleanly.
            else => self.abort(.nyi_opcode),
        }
    }

    // --- recording helpers -------------------------------------------------

    /// Append an IR instruction, returning its SSA ref (its index).
    /// For simple type-guard ops (`guard_int`, `guard_float`, `guard_number`,
    /// `guard_true`, `guard_false`), the current bytecode PC is stored in
    /// `aux` so the executor can report which guard failed (per-guard PC
    /// recording for exit-PC chaining). Other ops keep their caller-set `aux`.
    fn emit(self: *TraceState, ins: IrInstr) !Ref {
        var ins_mut = ins;
        switch (ins_mut.op) {
            // `int_of_float` is value-producing but also side-exits, so it stamps
            // its PC for exit-PC chaining like the type guards (its `aux` is unused
            // for anything else — the result kind is `.int`, the operand is `a`).
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float => {
                ins_mut.aux = @intCast(self.rec.cur_pc);
            },
            else => {},
        }
        const ref: Ref = @intCast(self.rec.instrs.items.len);
        try self.rec.instrs.append(self.gpa, ins_mut);
        return ref;
    }

    /// Intern a constant into the trace's pool and emit a `konst` for it. A
    /// value seen before reuses its existing `konst` ref (and pool slot) — a
    /// `konst` is pure and operand-free, so sharing its ref is sound. This is
    /// what lets identical subexpressions (e.g. the two `i + 7` in
    /// `(i + 7) * (i + 7)`) end up with identical operand refs, so the
    /// optimizer's CSE can collapse them (see docs / TODO.md).
    fn konst(self: *TraceState, v: Value) !Ref {
        const key = konstKey(v);
        if (self.rec.konst_map.get(key)) |existing| return existing;
        const idx: i32 = @intCast(self.rec.consts.items.len);
        try self.rec.consts.append(self.gpa, v);
        const ref = try self.emit(.{ .op = .konst, .aux = idx, .ty = obsTypeOf(v) });
        try self.rec.konst_map.put(self.gpa, key, ref);
        return ref;
    }

    /// The SSA ref currently held by tier-0 register `slot`. The first read of a
    /// register emits a `slot_load` (a trace input) and records it in the entry
    /// snapshot.
    fn refOf(self: *TraceState, slot: u16) !Ref {
        // Translate the frame-relative `slot` into a `reg_map` index by the current
        // frame's absolute offset (0 for the anchor frame; cross-frame tracing
        // raises it inside an inlined callee). A `slot_load` is only ever emitted
        // for an anchor-frame slot: S1 pre-seeds every callee slot `.def` at the
        // inlining `.call`, so a callee index is never `.undef` here — the
        // executor's `slot_load aux` therefore always lands in `[0,
        // anchor_num_registers)`.
        const abs: usize = self.rec.base_off + slot;
        const s = &self.rec.reg_map[abs];
        if (s.state != .undef) return s.ref;
        const aux: i32 = @intCast(abs);
        const ref = try self.emit(.{ .op = .slot_load, .aux = aux, .ty = .unknown });
        try self.rec.entry_slots.append(self.gpa, @intCast(abs));
        s.* = .{ .ref = ref, .state = .input };
        return ref;
    }

    /// Record that tier-0 register `slot` (in the current frame) now holds the
    /// value produced by `ref` (a loop-carried write — surfaces in the exit
    /// snapshot). Offset by `base_off` like `refOf`.
    fn setReg(self: *TraceState, slot: u16, ref: Ref) void {
        self.rec.reg_map[self.rec.base_off + slot] = .{ .ref = ref, .state = .def };
    }

    /// Whether tier-0 register `slot` was *read* during this recording (i.e. it is
    /// in the entry snapshot). Used by `commit()` as a safety net so the dead-
    /// temporary filter never drops a slot the trace actually consumed.
    fn readSlot(self: *const TraceState, slot: u16) bool {
        return std.mem.indexOfScalar(u16, self.rec.entry_slots.items, slot) != null;
    }

    /// Emit a type guard for `ref` (deduplicated — an SSA value has one type).
    fn guard(self: *TraceState, ref: Ref, op: IrOp) !void {
        if (self.rec.guarded_refs.contains(ref)) return;
        try self.rec.guarded_refs.put(self.gpa, ref, {});
        _ = try self.emit(.{ .op = op, .a = ref });
    }

    fn guardInt(self: *TraceState, ref: Ref) !void {
        try self.guard(ref, .guard_int);
    }

    fn guardNum(self: *TraceState, ref: Ref, v: Value) !void {
        try self.guard(ref, if (v.isInt()) IrOp.guard_int else IrOp.guard_float);
    }

    fn recArith(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb);
        try self.guardNum(rc, vc);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = arithResultType(op, vb, vc) });
        self.setReg(instr.a, r);
    }

    fn recBitwise(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isInt() or !vc.isInt()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardInt(rb);
        try self.guardInt(rc);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .int });
        self.setReg(instr.a, r);
    }

    fn recNeg(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        if (!vb.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardNum(rb, vb);
        const r = try self.emit(.{ .op = .neg, .a = rb, .ty = if (vb.isInt()) .int else .float });
        self.setReg(instr.a, r);
    }

    /// `not` works on any value via Lua truthiness, so it needs no type guard —
    /// the IR `not` is defined over truthiness, like tier-0.
    fn recNot(self: *TraceState, instr: Instr) !void {
        const rb = try self.refOf(instr.b);
        const r = try self.emit(.{ .op = .not, .a = rb, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    fn recBnot(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        if (!vb.isInt()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardInt(rb);
        const r = try self.emit(.{ .op = .bnot, .a = rb, .ty = .int });
        self.setReg(instr.a, r);
    }

    fn recCompare(self: *TraceState, op: IrOp, swap: bool, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        var rb = try self.refOf(instr.b);
        var rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb);
        try self.guardNum(rc, vc);
        if (swap) {
            const t = rb;
            rb = rc;
            rc = t;
        }
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// Record `t[k]` (`get_index`, `dst=a b=table c=key`) as an array read.
    ///
    /// **Narrow lanes** (i8–i64/f64/u8/boolean): emits `guard_table` + `guard_lane`
    /// on the table ref, `guard_int` on the key, then `aref` + `guard_bounds` +
    /// `guard_present` + `aload`. The result is a scalar value.
    ///
    /// **`.value` lane — table elements** (the array-of-structs pattern): emits the
    /// same prefix but omits `guard_present` (`.value` lane has no presence bitmap —
    /// nil is in-band) and appends `guard_table` on the *loaded value*, verifying
    /// the element is a table with no metatable. The result is a heap table ref
    /// that subsequent `recHashGet`/`recHashSet` calls chain from (e.g. `bodies[i].x`).
    /// Native declines these traces (`laneKind(.value) → null`); tier-1a executes them.
    ///
    /// Aborts (leaving tier-0 untouched) when:
    ///   * non-table container or non-int key → `.bad_type`;
    ///   * out-of-bounds or hole at record time → `.bad_type`;
    ///   * `.value`-lane with a non-table element (function, string, scalar) →
    ///     `.nyi_opcode` (different guard/native path needed);
    ///   * element table has a metatable → `.has_metatable`.
    fn recArrayGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        // Deferred (sunk) stores must be the LAST array accesses in the trace: an
        // `aload` after any of them would read the pre-store value on-trace while
        // tier-0's deopt-replay (store-then-read) reads the post-store value —
        // divergence. Abort, exactly as the old C1 rule did (no regression). See
        // `docs/design/08-multi-store-sinking.md` §mechanism (and doc 07 §3.2).
        if (self.rec.pending_store_count > 0) return self.abort(.bad_type);
        const vtab = regs.get(instr.b);
        const vkey = regs.get(instr.c);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (!vkey.isInt()) return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent slot could fire `__index` (chunk 2a). Even a
        // present slot today could become a hole on a later iteration, so the only
        // sound conservative choice is to bail the whole trace to tier-0.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        const idx = vkey.asInt();
        if (idx < 1 or idx > @as(i64, @intCast(tbl.array.len))) return self.abort(.bad_type);
        const loaded = tbl.getInt(idx);
        if (loaded.isNil()) return self.abort(.bad_type); // hole — not a profitable trace

        if (lane == .value) {
            // The `.value` lane stores full 16-byte Values (tag+payload, nil in-band).
            // Accept only when the loaded element is a **table** — the array-of-structs
            // pattern (`bodies[i].x`). Other heap types (functions, strings) and scalars
            // in a `.value` lane stay nyi — they'd need a different guard + native path.
            if (!loaded.isHeap() or loaded.heapType() != .table) return self.abort(.nyi_opcode);
            const elem_tbl = table_mod.Table.fromHeader(loaded.asHeap());
            if (elem_tbl.metatable != null) return self.abort(.has_metatable);

            const lane_ord: i32 = @intFromEnum(lane); // 0 for .value
            const rtab = try self.refOf(instr.b);
            _ = try self.emit(.{ .op = .guard_table, .a = rtab });
            _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
            const rkey = try self.refOf(instr.c);
            try self.guardInt(rkey);
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            _ = try self.emit(.{ .op = .guard_bounds, .a = ref });
            // No guard_present: the `.value` lane has no presence bitmap — nil is
            // encoded in-band (tag == .nil). A nil element fails the guard_table
            // below (nil is not a heap_ref) and side-exits to tier-0. Correct.
            const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
            // Guard the loaded value is a table with no metatable. This is the type
            // guard analogous to guard_int/guard_float for scalar loads — it side-exits
            // when the element's type changes between iterations.
            _ = try self.emit(.{ .op = .guard_table, .a = rload });
            self.setReg(instr.a, rload);
            return;
        }

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(instr.b);
        _ = try self.emit(.{ .op = .guard_table, .a = rtab });
        _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
        const rkey = try self.refOf(instr.c);
        try self.guardInt(rkey);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        _ = try self.emit(.{ .op = .guard_bounds, .a = ref });
        _ = try self.emit(.{ .op = .guard_present, .a = ref });
        const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
        self.setReg(instr.a, rload);
    }

    /// Record `t[k]=v` (`set_index`, `a=table b=key c=value`) as a lane-aware
    /// packed-array write. Emits, in order: `guard_table` + `guard_lane` on the
    /// table ref, `guard_int` on the key, then `aref` + `guard_bounds` + `astore`
    /// — the FIRST mid-iteration heap mutation in the system. Aborts (leaving
    /// tier-0 untouched) unless the store is a *present, in-bounds, in-lane*
    /// slot whose value is deopt-replay-safe:
    ///   * non-table container or non-int key → `.bad_type` (hash-part / metatable
    ///     territory, out of scope);
    ///   * `.value`-lane array → `.nyi_opcode` (unpacked 16-B path is deferred —
    ///     and a heap value would need a write barrier the native ABI lacks);
    ///   * out-of-bounds (`k>len` would *grow*, `k<1` is the hash part) → `.bad_type`;
    ///   * `nil` value → `.bad_type` (a hole-punch / delete, not a normal store; B3
    ///     models presence-creating writes only — keeps `astore creates presence`);
    ///   * out-of-lane value (a value the current narrow lane can't hold would
    ///     *widen* — a shape change / allocation the native store can't do) →
    ///     `.bad_type`;
    ///   * **C1 (deopt-replay idempotence):** *any* packed-array read (`aload`)
    ///     recorded earlier in this trace → `.bad_type`. On a side-exit, tier-0
    ///     re-runs the aborted iteration against the *already-mutated* heap, so a
    ///     write whose value — OR whose very occurrence (control flow) — was decided
    ///     by a read could double-apply. A *data*-only check is unsound: a guard on a
    ///     read picks the branch, so `if t[i] then t[i]=false else t[i]=true end`
    ///     stores a constant yet replays differently. In a straight-line trace every
    ///     prior guard dominates this store, and every read-derived decision flows
    ///     through a guard, so "no earlier `aload` at all" covers both the data and
    ///     control channels with one obviously-sound rule. nsieve's sieve-clearing
    ///     loop is a pure write of `false` (no `aload`), so the rule costs it nothing.
    fn recArraySet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        // NB (Gap C): unlike the single-store original, a store arriving while other
        // stores are already deferred is NOT blanket-aborted here. An in-bounds RMW
        // store appends to `pending_stores` (the in-bounds path below); an *append*
        // store (which changes `len`) must still abort — handled in the append branch.
        // The `pending_store_count` checks live at those two sites, not at the top,
        // because we cannot tell append-vs-in-bounds until we know `idx`/`len` below.
        // See `docs/design/08-multi-store-sinking.md`.
        const vtab = regs.get(instr.a);
        const vkey = regs.get(instr.b);
        const vval = regs.get(instr.c);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (!vkey.isInt()) return self.abort(.bad_type);
        if (vval.isNil()) return self.abort(.bad_type); // hole-punch — out of scope
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent-key store could fire `__newindex` (chunk 2a);
        // the append path below stores to exactly such an absent key (`len+1`).
        // Abort the whole trace to tier-0, which does full `__newindex` dispatch.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        if (lane == .value) return self.abort(.nyi_opcode); // unpacked path deferred
        const idx = vkey.asInt();

        // Grow (append) store: `t[len+1] = v` extends the dense run by one. This is
        // the bulk of an array-fill loop (nsieve's `for i=2,m do p[i]=true end` after
        // its first rehash narrows to the boolean lane and drains the hash). Rather
        // than abort the whole trace (the historic behaviour — the fill then ran fully
        // tier-0), record an `astore_append` guarded so the realloc/migrate cases fall
        // back to tier-0 while the in-capacity common case runs native. Phase A: the
        // boolean lane (one in-band byte/slot) and the fixed-width int lanes
        // (i8…i64: width store + presence bit) — exactly the lanes the native
        // in-bounds `astore` lowers (`nativegen.laneKind`). `.f64` needs XMM stores
        // the array path does not yet emit, so it (and `.value`) still abort below.
        // The emitted IR sequence is lane-generic; `guard_fits` (below) supplies the
        // int lane's runtime range check, and the value's static `.int` kind comes
        // from its producing ref (the loop slot) — same as the in-bounds int store.
        if ((lane == .boolean or lane.isInt()) and
            idx == @as(i64, @intCast(tbl.array.len)) + 1 and
            tbl.hash.count() == 0 and
            tbl.array.fits(vval))
        {
            // Same C1 deopt-replay rule as `astore`: a prior packed-array read could
            // have steered this store's value or occurrence, and re-running the
            // iteration on a side-exit (against the now-longer array) would diverge.
            // (A non-empty `pending_stores` implies a prior `aload`, so this also
            // covers "append after a sunk store" — an append changes `len` and is
            // never deferred; `docs/design/08-multi-store-sinking.md` §soundness.)
            if (self.traceHasHeapLoad()) return self.abort(.bad_type);
            const rval = try self.refOf(instr.c);
            const lane_ord: i32 = @intFromEnum(lane);
            const rtab = try self.refOf(instr.a);
            _ = try self.emit(.{ .op = .guard_table, .a = rtab });
            _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
            const rkey = try self.refOf(instr.b);
            try self.guardInt(rkey);
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            // guard_append: hash-empty + `idx==len+1` + `len<cap`. The grow analogue
            // of guard_bounds — side-exits to tier-0 (which reallocs/migrates) when
            // any precondition fails, so the on-trace append never allocates.
            _ = try self.emit(.{ .op = .guard_append, .a = ref });
            // guard_fits: the value still fits the narrow lane (the oracle re-checks a
            // free-variable store; native bool already proves `.bool`). Same as astore.
            _ = try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord });
            _ = try self.emit(.{ .op = .astore_append, .a = ref, .b = rval, .aux = lane_ord });
            return;
        }

        if (idx < 1 or idx > @as(i64, @intCast(tbl.array.len))) return self.abort(.bad_type);
        // The value must fit the current lane unchanged — an out-of-lane store
        // would widen the array (shape change / allocation) which the native ABI
        // cannot perform; the prologue `guard_lane` then stays sufficient.
        if (!tbl.array.fits(vval)) return self.abort(.bad_type);

        // C1 / store-sinking: if this trace has already read the packed array, an
        // inline store would be deopt-unsound — on a side-exit *after* the store,
        // tier-0 re-runs the whole iteration against the mutated heap and a
        // read-modify-write double-applies (the read steered this store's value or
        // its control flow). Instead of aborting, DEFER the store: emit its address
        // + guards inline here, but stash the `astore` node and flush it at trace
        // close (`commit`) below every guard — incl. the `for_loop` continuation
        // guard — so every side-exit leaves the store un-executed and replay stores
        // exactly once. Gap C sinks up to `MAX_PENDING_STORES` such stores (the FFT
        // butterfly writes four), flushed in recorded order; a trace wanting more
        // aborts cleanly here. The post-store invariant (no later `aload`/append, in
        // `recArrayGet` and the append branch) keeps the sunk stores the trace's last
        // array accesses. A pure-write store (no prior `aload`) is deopt-idempotent on
        // its own and emits inline as before. See `docs/design/08-multi-store-sinking.md`.
        const defer_store = self.traceHasHeapLoad();
        if (defer_store and self.rec.pending_store_count >= MAX_PENDING_STORES)
            return self.abort(.bad_type);
        const rval = try self.refOf(instr.c);

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(instr.a);
        _ = try self.emit(.{ .op = .guard_table, .a = rtab });
        _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
        const rkey = try self.refOf(instr.b);
        try self.guardInt(rkey);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        _ = try self.emit(.{ .op = .guard_bounds, .a = ref });
        // Guard at runtime that the value still fits the recorded narrow lane: a
        // later iteration storing an out-of-lane value (an out-of-range/non-int int
        // into an int lane, a non-bool into the bool lane, a non-float into f64)
        // would force tier-0 to WIDEN the lane (alloc + relayout), which the native
        // store can't do mid-run and which would trip the tier-1a oracle's in-place
        // `setInLane` encode (`assert(fits(val))`) — so `guard_fits` side-exits
        // instead and lets tier-0 re-run + widen. Every narrow lane needs this: the
        // `astore` value can be a free variable (a loop-carried slot), not just a
        // constant, so the recorder cannot assume it stays in-lane. (`.value` aborts
        // above, so `lane` here is always narrow.) For the bool lane native lowers
        // this to nothing — the value is already proven `.bool` at analysis time —
        // but the oracle, which runs the raw trace, still needs the runtime check.
        _ = try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord });
        // No `guard_present`: `astore` *creates* presence (the slot is in-bounds by
        // `guard_bounds`; storing a non-nil value sets the presence bit). The store
        // is effectful and not register-defining, so nothing is `setReg`'d.
        if (defer_store) {
            // Read-modify-write: stash the store; `commit()` flushes it (and any
            // siblings) below every guard, just before `.loop`, in this recorded
            // order. The guards above (table/lane/int/bounds/fits) stay inline and
            // continue to dominate the sunk store. The cap was checked above.
            self.rec.pending_stores[self.rec.pending_store_count] =
                .{ .aref = ref, .value = rval, .lane_ord = lane_ord };
            self.rec.pending_store_count += 1;
        } else {
            _ = try self.emit(.{ .op = .astore, .a = ref, .b = rval, .aux = lane_ord });
        }
    }

    /// Record `a[i][j]` (`get_index2`, `dst=a tab=b row=c col=aux`) as a flattened-
    /// grid cell read (doc 14, Phase 8). Emits, in order: `guard_grid` + `guard_stride`
    /// on the table, `guard_int` on row + col, the `garow`/`gcell` address chain with
    /// `guard_bounds` (row) + `guard_gcol` (col), then `guard_gpresent` + `gload`.
    /// Aborts (leaving tier-0 untouched) unless the container is already a grid with an
    /// **int or f64** element lane and the access is a *present, in-bounds* cell — every
    /// other shape (a not-yet-inflated nested table, an out-of-bounds/hole cell) runs on
    /// tier-0.
    fn recGridGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        // Like recArrayGet: a grid load after a sunk store would read stale on-trace.
        if (self.rec.pending_store_count > 0) return self.abort(.bad_type);
        const col_reg: u16 = @intCast(instr.aux);
        const vtab = regs.get(instr.b);
        const vrow = regs.get(instr.c);
        const vcol = regs.get(col_reg);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (!vrow.isInt() or !vcol.isInt()) return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const ap = &tbl.array;
        if (ap.lane != .grid) return self.abort(.nyi_opcode); // not inflated → nested-table path (deferred)
        if (!ap.grid_elem.isInt() and ap.grid_elem != .f64) return self.abort(.nyi_opcode); // only int + f64 cells lower
        if (ap.stride > std.math.maxInt(i32)) return self.abort(.bad_type); // guard_stride aux is i32
        const row = vrow.asInt();
        const col = vcol.asInt();
        if (row < 1 or row > @as(i64, @intCast(ap.gridRows()))) return self.abort(.bad_type);
        if (col < 1 or col > @as(i64, @intCast(ap.stride))) return self.abort(.bad_type);
        const loaded = ap.gridGet(@intCast(row - 1), @intCast(col - 1));
        if (loaded.isNil()) return self.abort(.bad_type); // hole — not a profitable trace

        const ge: i32 = @intFromEnum(ap.grid_elem);
        const stride_aux: i32 = @intCast(ap.stride);
        const rtab = try self.refOf(instr.b);
        _ = try self.emit(.{ .op = .guard_grid, .a = rtab, .aux = ge });
        _ = try self.emit(.{ .op = .guard_stride, .a = rtab, .aux = stride_aux });
        const rrow = try self.refOf(instr.c);
        try self.guardInt(rrow);
        const rcol = try self.refOf(col_reg);
        try self.guardInt(rcol);
        const garow = try self.emit(.{ .op = .garow, .a = rtab, .b = rrow, .aux = ge });
        _ = try self.emit(.{ .op = .guard_bounds, .a = garow }); // row in [1,rows] (grid len == rows)
        const gcell = try self.emit(.{ .op = .gcell, .a = garow, .b = rcol, .aux = ge });
        // guard_gcol carries the column ref in `.b` (col in [1,stride]); native keeps
        // it live for the range-compare, the oracle re-reads gcell.b instead.
        _ = try self.emit(.{ .op = .guard_gcol, .a = gcell, .b = rcol });
        _ = try self.emit(.{ .op = .guard_gpresent, .a = gcell });
        const rload = try self.emit(.{ .op = .gload, .a = gcell, .aux = ge, .ty = obsTypeOf(loaded) });
        self.setReg(instr.a, rload);
    }

    /// Record `a[i][j]=v` (`set_index2`, `tab=a row=b col=c val=aux`) as a flattened-
    /// grid cell write (doc 14, Phase 8). Mirrors `recGridGet`'s addressing, then
    /// `guard_fits` + `gstore`. Aborts unless the store is an in-grid, in-bounds,
    /// in-lane cell write: a new row (`row>rows`) or column past `stride` would GROW
    /// the grid, and an out-of-lane value would WIDEN it — both reshape/realloc the
    /// flat buffer, which the on-trace store cannot do, so they run on tier-0 (the
    /// guards then side-exit on a later iteration that would reshape). Phase 8a keeps
    /// the C1 deopt-replay rule simple: a store after *any* heap read aborts (no
    /// store-sinking yet) — matmul's hot inner loop is read-only, so this is free.
    fn recGridSet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const val_reg: u16 = @intCast(instr.aux);
        const vtab = regs.get(instr.a);
        const vrow = regs.get(instr.b);
        const vcol = regs.get(instr.c);
        const vval = regs.get(val_reg);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (!vrow.isInt() or !vcol.isInt()) return self.abort(.bad_type);
        if (vval.isNil()) return self.abort(.bad_type); // hole-punch — out of scope
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const ap = &tbl.array;
        if (ap.lane != .grid) return self.abort(.nyi_opcode);
        if (!ap.grid_elem.isInt() and ap.grid_elem != .f64) return self.abort(.nyi_opcode); // only int + f64 cells lower
        if (ap.stride > std.math.maxInt(i32)) return self.abort(.bad_type);
        const row = vrow.asInt();
        const col = vcol.asInt();
        if (row < 1 or row > @as(i64, @intCast(ap.gridRows()))) return self.abort(.bad_type); // grow row → tier-0
        if (col < 1 or col > @as(i64, @intCast(ap.stride))) return self.abort(.bad_type); // grow stride → tier-0
        if (!arr.ArrayPart.laneFits(ap.grid_elem, vval)) return self.abort(.bad_type); // widen elem → tier-0
        // C1 (deopt-replay idempotence): a store after any prior heap read could
        // double-apply when a side-exit re-runs the iteration against the already-
        // mutated grid. Phase 8a aborts rather than sinking (see recArraySet for the
        // sinking machinery a later phase can extend to grids).
        if (self.traceHasHeapLoad()) return self.abort(.bad_type);

        const ge: i32 = @intFromEnum(ap.grid_elem);
        const stride_aux: i32 = @intCast(ap.stride);
        const rval = try self.refOf(val_reg);
        const rtab = try self.refOf(instr.a);
        _ = try self.emit(.{ .op = .guard_grid, .a = rtab, .aux = ge });
        _ = try self.emit(.{ .op = .guard_stride, .a = rtab, .aux = stride_aux });
        const rrow = try self.refOf(instr.b);
        try self.guardInt(rrow);
        const rcol = try self.refOf(instr.c);
        try self.guardInt(rcol);
        const garow = try self.emit(.{ .op = .garow, .a = rtab, .b = rrow, .aux = ge });
        _ = try self.emit(.{ .op = .guard_bounds, .a = garow });
        const gcell = try self.emit(.{ .op = .gcell, .a = garow, .b = rcol, .aux = ge });
        _ = try self.emit(.{ .op = .guard_gcol, .a = gcell, .b = rcol });
        _ = try self.emit(.{ .op = .guard_fits, .a = rval, .aux = ge });
        // No guard_gpresent: gstore *creates* presence (mirrors astore).
        _ = try self.emit(.{ .op = .gstore, .a = gcell, .b = rval, .aux = ge });
    }

    /// C1 support: has *any* heap read — a packed-array `aload`, a hash-field
    /// `hload` (doc 11), OR a grid-cell `gload` (doc 14) — been recorded so far in
    /// this trace? Used by `recArraySet`/`recHashSet`/`recGridSet` to decide whether a
    /// write is a read-modify-write that must be deopt-sunk (or, for grids in Phase 8a,
    /// aborted). This is the conservative-sound C1 rule: in a straight-line trace any
    /// earlier read can influence a later write through its value (data) or through a
    /// guard that selected the path (control), and a side-exit replays the iteration
    /// against the already-mutated heap. Rejecting on the mere presence of an earlier
    /// read covers both channels without per-value taint reasoning. A pure-write loop
    /// (no `aload`/`hload`/`gload`, e.g. nsieve's sieve clear) is unaffected. The three
    /// load kinds are pooled because an `aload`-then-`hstore` (or any cross pair) is
    /// just as deopt-unsound as same-kind RMW.
    fn traceHasHeapLoad(self: *const TraceState) bool {
        for (self.rec.instrs.items) |ins| {
            if (ins.op == .aload or ins.op == .hload or ins.op == .gload) return true;
        }
        return false;
    }

    /// Is `v` a heap **string** — i.e. an `obj.field`-shaped (hash-part) table key?
    /// The compiler lowers every `obj.field` to `get_index`/`set_index` with an
    /// interned-string key, so this is the gate that routes such accesses to the
    /// hash-field path (doc 11) instead of the integer-array path.
    fn isStringKey(v: Value) bool {
        return v.isHeap() and v.heapType() == .string;
    }

    /// H1 native seeding (Approach B, doc 11 §5). Register the loop-invariant
    /// **value-cell pointer** of a constant-key field access as a `hash_cell` entry
    /// input so the *native* path can read the cell from the slab prologue
    /// (`[rsi + slot*8]`), exactly as U0 hoists an upvalue/global. Returns the
    /// synthetic slab slot to stamp into `href.aux`, or `null` when the cell can't be
    /// seeded — in which case the trace is still valid at **tier-1a** (the oracle
    /// re-derives the cell from `href`'s `(table,key)` operands each iteration and
    /// ignores `aux`); only *native* execution declines for this entry.
    ///
    /// `rtab` must resolve to a `slot_load` so the dispatch loop can re-read the
    /// table value from an anchor slot every entry; a table produced on-trace (e.g. a
    /// call result) isn't seedable. `rkey` is the `konst` ref whose `aux` is the
    /// key's const-pool index — recorded as `source` so `seedTraceInputs` can recover
    /// the key `Value` and call `Table.fieldPtr`. `count` is the recorded
    /// `hash.count()` (the `guard_hash` aux) the seed re-validates at entry, the
    /// native analogue of the oracle's per-iteration `guard_hash` population check.
    ///
    /// Unlike `recInputGet`, exhausting the input budget is **not** an abort: the
    /// tier-1a trace stands, native just declines (returns `null`). An RMW's read and
    /// write `href`s dedup onto one slot via `hash_cell_dedup`.
    fn seedHashCell(self: *TraceState, rtab: Ref, rkey: Ref, count: u32) !?u16 {
        const tab_instr = self.rec.instrs.items[@intCast(rtab)];
        // The table must live in a re-readable anchor slot (a `slot_load`, which both
        // an ordinary register read and a U0-seeded upvalue/global resolve to). A
        // table computed on-trace has no entry slab slot to re-resolve from.
        if (tab_instr.op != .slot_load) return null;
        const table_reg: u16 = @intCast(tab_instr.aux);
        const key_const: u32 = @intCast(self.rec.instrs.items[@intCast(rkey)].aux);

        const dkey = (@as(u64, table_reg) << 32) | key_const;
        if (self.rec.hash_cell_dedup.get(dkey)) |slot| return slot;

        // Budget/index guards mirror `recInputGet`, but a miss declines native rather
        // than aborting the (still-valid-at-tier-1a) trace.
        if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return null;
        if (self.rec.next_input_slot == std.math.maxInt(u16)) return null;

        const slot = self.rec.next_input_slot;
        self.rec.next_input_slot += 1;
        try self.rec.input_seeds.append(self.gpa, .{
            .kind = .hash_cell,
            .source = key_const,
            .slot = slot,
            .table_reg = table_reg,
            .expected_count = count,
        });
        try self.rec.hash_cell_dedup.put(self.gpa, dkey, slot);
        return slot;
    }

    /// Record `t.field` (`get_index`, `dst=a b=table c=key`, key an interned
    /// string) as a hash-part field read. The string analogue of `recArrayGet`.
    /// Emits, in order: `guard_table`(table) → `href`(table, keyconst) →
    /// `guard_hash`(href, aux=recorded population) → `hload`(href) → the existing
    /// type-guard on the `hload` ref (`guard_int`/`guard_float`/…). The cell address
    /// is loop-invariant for a constant key (hoistable to the native prologue in
    /// H1), so the read mirrors the array `aref`/`aload` path. Aborts (leaving
    /// tier-0 untouched) unless the access is a *present, non-metatable, constant-
    /// key* hash field — the only shape the oracle/native path models:
    ///   * non-table container → `.bad_type`;
    ///   * `tbl.metatable != null` → `.has_metatable` (an absent slot could fire
    ///     `__index`; even a present slot could become absent on a later iteration);
    ///   * key absent from the hash part at record time → `.bad_type` (an absent-key
    ///     access is the migrate/`__index`/grow territory v1 excludes; the present-
    ///     key rule is what keeps the hoisted cell from dangling);
    ///   * computed (non-`konst`) key → `.bad_type` (a runtime-varying key cannot be
    ///     pinned to one cell — v1 scope; `t[expr]` stays tier-0);
    ///   * a pending (sunk) store precedes this load → `.bad_type` (same post-store
    ///     no-load rule as `recArrayGet`: a load after a deferred store would read
    ///     the pre-store value on-trace but the post-store value on deopt-replay).
    fn recHashGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        // Same post-store invariant as `recArrayGet`: a deferred store must be the
        // trace's last heap access (doc 08 §mechanism). A hash load after one would
        // diverge on deopt-replay. Array and hash loads/stores share the pool.
        if (self.rec.pending_store_count > 0) return self.abort(.bad_type);
        const vtab = regs.get(instr.b);
        const vkey = regs.get(instr.c);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const cell = tbl.fieldPtr(vkey) orelse return self.abort(.bad_type); // absent
        // Scalar-field restriction (the hash analogue of the narrow-array-lane rule).
        // A present cell holds a non-`nil` tagged `Value` of any type. We trace only
        // **int/float** fields, for two joined reasons: (1) the scalar exec-log
        // encoder (the cross-mode determinism oracle) cannot encode a heap value, so
        // `hload`'s logged value must be scalar; (2) only int/float have a *strict*
        // type guard (`guard_int`/`guard_float`) that pins the field's type so a later
        // iteration changing it side-exits — a `bool` field could silently become a
        // truthy heap value that `guard_true` would wave through. A bool/heap/string
        // field therefore aborts to tier-0, exactly as a `.value` array lane does.
        const fv = cell.*;
        if (!(fv.isInt() or fv.isFloat())) return self.abort(.nyi_opcode);
        // The key must be a recorded `konst` (the bytecode literal interned via
        // `load_const`), so its ref is provably the constant — no runtime key-
        // identity guard is needed and the cell is pinnable. A computed key reaches
        // here as a `slot_load`/arith ref and aborts (v1 scope).
        const rkey = try self.refOf(instr.c);
        if (self.rec.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

        const rtab = try self.refOf(instr.b);
        _ = try self.emit(.{ .op = .guard_table, .a = rtab });
        // Seed the loop-invariant cell pointer for native (H1); `href.aux` carries
        // the synthetic slab slot, or `-1` to mark "not seeded → native declines".
        // The tier-1a oracle ignores `aux`, so a `null` seed leaves H0 untouched.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count);
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
        _ = try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) });
        const rload = try self.emit(.{ .op = .hload, .a = ref, .ty = obsTypeOf(fv) });
        self.setReg(instr.a, rload);
        // Decompose the tagged-cell load into a typed load + the existing consumer
        // type-guard (mirrors `slot_load` + `guardNum`): native lowers `hload` to a
        // tag-check + payload load of the guarded kind. The oracle returns the whole
        // `Value`, so this guard is what makes the two agree on the side-exit
        // iteration (and pins the field type — int→float etc. side-exits).
        try self.guardNum(rload, fv);
    }

    /// Record `t.field = v` (`set_index`, `a=table b=key c=value`, key an interned
    /// string) as a hash-part field write. The string analogue of `recArraySet`'s
    /// in-bounds store. Present-key overwrite ONLY: the recorder rejects an absent
    /// key (an insert could grow/rehash and dangle every hoisted cell) and a `nil`
    /// value (a delete). Follows the same C1 store-sink discipline as `recArraySet`
    /// — a store following any heap load is deferred below every guard (`commit`).
    /// Aborts unless:
    ///   * non-table container → `.bad_type`;
    ///   * `nil` value (delete) → `.bad_type`;
    ///   * `tbl.metatable != null` → `.has_metatable` (`__newindex` territory);
    ///   * key absent at record time → `.bad_type` (insert — out of v1 scope);
    ///   * computed (non-`konst`) key → `.bad_type`;
    ///   * deferred-store cap (`MAX_PENDING_STORES`) exceeded → `.bad_type`.
    fn recHashSet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const vtab = regs.get(instr.a);
        const vkey = regs.get(instr.b);
        const vval = regs.get(instr.c);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (vval.isNil()) return self.abort(.bad_type); // delete — out of scope
        // Scalar-value restriction, the store mirror of `recHashGet`'s read rule: the
        // exec-log encoder is scalar-only, so the stored value (logged by its
        // producing `slot_load`/arith ref) must be int/float; a heap/bool field store
        // aborts to tier-0. Covers the int/float field arithmetic OOP code does
        // (`obj.x = obj.x + dt*vx`); reference fields (`obj.next = node`) stay tier-0.
        if (!(vval.isInt() or vval.isFloat())) return self.abort(.nyi_opcode);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        _ = tbl.fieldPtr(vkey) orelse return self.abort(.bad_type); // absent = insert
        const rkey = try self.refOf(instr.b);
        if (self.rec.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

        // C1 / store-sinking, identical to `recArraySet`: a write following any heap
        // read is a read-modify-write that must be deferred below every guard so a
        // side-exit leaves it un-executed and deopt-replay applies it exactly once.
        const defer_store = self.traceHasHeapLoad();
        if (defer_store and self.rec.pending_store_count >= MAX_PENDING_STORES)
            return self.abort(.bad_type);
        const rval = try self.refOf(instr.c);
        // Pin the **store value's** type (int/float). A hash cell holds a full tagged
        // `Value` with no lane to constrain it, so this guard is the analogue of the
        // array path's `guard_fits`: it is the sole guarantee the field stays scalar
        // on-trace. Without it, a value whose runtime type drifts (int→heap) would be
        // written into the cell, and a later `hload` would read a non-scalar into the
        // scalar-only exec log. Emitting it inline (it stays in the body even when the
        // store sinks) makes a drifted store value side-exit *before* the write lands.
        // Sound via the standard deduped `guardNum`: `guarded_refs` holds only numeric
        // guards (truthiness `guard_true`/`guard_false` are emitted raw, never
        // registered), so a prior guard on this ref is necessarily a matching
        // `guard_int`/`guard_float`.
        try self.guardNum(rval, vval);
        const rtab = try self.refOf(instr.a);
        _ = try self.emit(.{ .op = .guard_table, .a = rtab });
        // Seed the cell pointer for native (H1) — see `recHashGet`. An RMW's read and
        // write `href`s dedup onto the same slot via `seedHashCell`.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count);
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
        _ = try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) });
        // `hstore` is effectful (overwrites the present cell in place) and defines no
        // register. A present-key overwrite never grows the map, so `guard_hash`
        // (population) stays sufficient. The store value's type is pinned by the
        // `guardNum` above (native declines a heap value at H1).
        if (defer_store) {
            self.rec.pending_stores[self.rec.pending_store_count] =
                .{ .aref = ref, .value = rval, .lane_ord = 0, .op = .hstore };
            self.rec.pending_store_count += 1;
        } else {
            _ = try self.emit(.{ .op = .hstore, .a = ref, .b = rval });
        }
    }

    /// `eq`/`ne`. First cut: numeric operands only (the common loop-condition
    /// case); other types abort.
    fn recEq(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb);
        try self.guardNum(rc, vc);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// `jmp_if_false`/`jmp_if_true`: pin the *observed* truthiness of the tested
    /// register. Which path the trace records is whatever tier-0 took; the guard
    /// is what keeps the straight-line trace valid.
    fn recBranch(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const ra = try self.refOf(instr.a);
        const op: IrOp = if (regs.get(instr.a).isTruthy()) .guard_true else .guard_false;
        _ = try self.emit(.{ .op = op, .a = ra });
    }

    /// `for_loop` (numeric-for back-edge): record the increment and the
    /// loop-continuation guard, mirroring the opcode. The actual back-edge / close
    /// is handled by `onBackEdge`.
    fn recForLoop(self: *TraceState, instr: Instr, regs: RegWindow, pc: u32) !void {
        // Cross-frame tracing (Phase 0): never process a `for_loop` inside an
        // inlined callee. The `target == anchor.pc` watermark test below compares
        // raw pc integers across *different* protos, so a callee-internal loop
        // whose body pc coincides with the outer anchor pc would corrupt the
        // exit-snapshot watermark. Leaf callees in the target benchmark cluster are
        // straight-line; a callee with its own numeric-`for` aborts and runs tier-0.
        if (self.rec.inline_depth > 0) return self.abort(.cross_frame);
        const a = instr.a;

        // If *this* `for_loop` is the one whose back-edge defines the trace
        // anchor (its target == anchor.pc, computed exactly as the interpreter's
        // `applyJump`), then the trace re-enters / resumes at this numeric-`for`'s
        // body start. Its four control regs occupy `a..a+3` (idx, limit, step,
        // var), so every slot `>= a+4` is a compiler temporary — dead at the body
        // start on every resume path and after the loop. Record the watermark so
        // `commit()` can drop those slots from the exit snapshot. A `for_loop` the
        // trace merely passes through (different target) is ignored.
        const target: u32 = @intCast(@as(i64, pc) + instr.aux);
        if (target == self.rec.anchor.pc) self.rec.locals_watermark = @as(u32, a) + 4;
        const vidx = regs.get(a);
        const vlimit = regs.get(a + 1);
        const vstep = regs.get(a + 2);
        if (!vidx.isNumber() or !vlimit.isNumber() or !vstep.isNumber()) return self.abort(.bad_type);
        const ridx = try self.refOf(a);
        const rlimit = try self.refOf(a + 1);
        const rstep = try self.refOf(a + 2);
        try self.guardNum(ridx, vidx);
        try self.guardNum(rlimit, vlimit);
        try self.guardNum(rstep, vstep);

        // idx_next = idx + step
        const all_int = vidx.isInt() and vstep.isInt();
        const rnext = try self.emit(.{ .op = .add, .a = ridx, .b = rstep, .ty = if (all_int) .int else .float });

        // Float loop-limit specialization: when the index+step are int but the limit
        // is a **float** whose observed value is an exact integer, convert the
        // (loop-invariant) limit to an int once via `int_of_float`, so the body
        // compare is int-vs-int. tier-0 compares int-vs-float EXACTLY, and for an
        // integral limit `L` in i64 range `idx <= L ⟺ idx <= (i64)L` — so the trip
        // count and registers are byte-identical, while the native backend (which
        // bails on a mixed compare) can now lower it. A later non-integral limit
        // side-exits the op → tier-0 resumes the exact mixed compare. The `guard_float`
        // already emitted by `guardNum(rlimit, vlimit)` pins this trace to float-limit
        // entries. The limit is never written by the loop, so the exit snapshot is
        // unchanged. Only fires for an integral, in-range limit (else stays mixed,
        // bails to tier-1a as before).
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null)
            try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int })
        else
            rlimit;

        // loop continues while (ascending) idx_next <= limit, else limit <= idx_next.
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            try self.emit(.{ .op = .le, .a = rnext, .b = rlimit_cmp, .ty = .boolean })
        else
            try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rnext, .ty = .boolean });
        _ = try self.emit(.{ .op = .guard_true, .a = cmp });

        // publish the stepped index and the loop variable (R[a+3]).
        self.setReg(a, rnext);
        self.setReg(a + 3, rnext);
    }

    /// `for_prep` (numeric-for entry): the nested-loop **trace-link** site (doc 15,
    /// Phase 2 — the lune analogue of LuaJIT's `rec_loop_jit` / `LJ_TRLINK_ROOT`).
    ///
    /// A `for_prep` pre-decrements its index (`R[a] = init − step`) and jumps forward
    /// to the matching `for_loop`, whose back-edge target is the loop body start —
    /// which is exactly `for_prep`'s *post-increment* pc (`pc` here), so the inner
    /// loop's **root-trace anchor pc == `pc`**. If a root trace is already cached
    /// there, this recording (a continuation that fell out of the inner loop and
    /// recorded the outer body forward) records the pre-decrement and **links** to
    /// the inner root instead of recording the inner `for_loop`/unrolling. Otherwise
    /// it aborts `.nyi_opcode` (LINNER): let the inner loop spawn its own root first.
    /// The decision is a pure function of the cache + bytecode (no clock/RNG/address),
    /// so it is identical across every record/exec mode — P1 carries to P2.
    ///
    /// **P2 (the load-bearing hand-off invariant, doc 15).** The link hand-off must
    /// reproduce the inner root's *entry state* — the tier-0 registers it reads at its
    /// anchor (`entry_slots`). The inner root anchors at the loop **body start** (the
    /// `for_loop` back-edge target), which tier-0 first reaches only AFTER `for_prep`
    /// (`R[a] = init − step`) **and** the first `for_loop` (`R[a] += step → init`,
    /// publishing the visible loop var `R[a+3] = init`). So the byte-identical hand-off
    /// is `R[a] = init` **and** `R[a+3] = init` — the body reads the visible var
    /// `R[a+3]` at the trace top, and the `for_loop` at the trace bottom reads `R[a]`
    /// to step it, so BOTH are live entry inputs. (An earlier draft recorded only
    /// `R[a] = init − step` and left `R[a+3]` stale — verified wrong by dumping the
    /// inner root's `entry_slots`, which include the visible-var slot; the inner root
    /// would then re-run the first iteration and read a stale loop var.) `R[a+1]`
    /// (limit) / `R[a+2]` (step) are untouched by the loop and flow straight through.
    /// A first-iteration bounds guard (`init` within `limit`) gates the link: a
    /// zero-trip inner loop fails it and falls back to tier-0 rather than entering the
    /// inner root, which assumes ≥1 iteration. Phase 3 consumes this snapshot to follow
    /// the link through `driveChain`.
    fn recForPrepLink(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
        // A `for_prep` inside an inlined callee shares `recForLoop`'s cross-frame
        // hazard (raw-pc anchor comparison across protos); keep the historical abort.
        if (self.rec.inline_depth > 0) return self.abort(.nyi_opcode);
        // Only a *side* or *continuation* links (LuaJIT's model). A `.root` recording
        // that reaches an inner `for_prep` aborts LINNER — byte-identical to the
        // pre-Phase-2 behaviour — so it never anchors a link trace at a real
        // back-edge target.
        if (self.rec.kind == .root) return self.abort(.nyi_opcode);
        const a = instr.a;

        // Locate the matching `for_loop` (the forward jump target) and verify the
        // shape. `pc` is the post-increment pc, so `pc + instr.aux` is the `for_loop`
        // bytecode index (mirrors the interpreter's `applyJump(pc, aux)`), and that
        // `for_loop`'s back-edge target — the inner loop header / root anchor — is
        // `pc` itself (the instruction immediately after `for_prep`).
        const fl_i: i64 = @as(i64, pc) + instr.aux;
        if (fl_i < 0 or fl_i >= @as(i64, @intCast(proto.code.len))) return self.abort(.nyi_opcode);
        const fl_pc: u32 = @intCast(fl_i);
        if (proto.code[fl_pc].op != .for_loop) return self.abort(.nyi_opcode);
        const inner_anchor: u32 = pc; // body start == for_loop back-edge target
        // Cross-check the layout assumption: the `for_loop`'s own back-edge resolves
        // to `inner_anchor`. Treat a mismatch as an ordinary LINNER abort in release
        // builds too; otherwise a malformed bytecode shape could link to the wrong pc.
        if (@as(i64, @intCast(fl_pc)) + 1 + proto.code[fl_pc].aux != @as(i64, @intCast(inner_anchor)))
            return self.abort(.nyi_opcode);

        // LINNER (LuaJIT `rec_loop_jit`): only link if the inner loop header already
        // has a `.loop` root trace. Otherwise abort — the inner loop must trace as a
        // root first; once it does, a later continuation links here.
        const inner_key = AnchorKey{ .proto = proto, .pc = inner_anchor };
        if (self.findLoopTrace(inner_key.proto, inner_key.pc) == null) return self.abort(.nyi_opcode);

        // Reconstruct the inner root's entry state (discharges P2 — see the doc
        // comment). Guard init/limit/step are numbers (all three — tier-0 `for_prep`
        // type-checks `limit` too, so a non-number limit must side-exit here rather
        // than commit a bogus link); a non-number is not a numeric `for` we model, so
        // fall back to the abort.
        const vinit = regs.get(a);
        const vlimit = regs.get(a + 1);
        const vstep = regs.get(a + 2);
        if (!vinit.isNumber() or !vlimit.isNumber() or !vstep.isNumber()) return self.abort(.bad_type);
        const rinit = try self.refOf(a);
        const rlimit = try self.refOf(a + 1);
        const rstep = try self.refOf(a + 2);
        try self.guardNum(rinit, vinit);
        try self.guardNum(rlimit, vlimit);
        try self.guardNum(rstep, vstep);

        // First-iteration bounds test, mirroring `recForLoop`'s compare (incl. the
        // float-limit → int specialization so a mixed int/float compare stays lowerable
        // and byte-identical to tier-0's `idx <= limit`). tier-0 tests `(init−step)+step
        // = init` against `limit`, so we compare `init` directly. On failure the inner
        // loop runs zero times → side-exit to tier-0 instead of entering the inner root.
        const all_int = vinit.isInt() and vstep.isInt();
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null)
            try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int })
        else
            rlimit;
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            try self.emit(.{ .op = .le, .a = rinit, .b = rlimit_cmp, .ty = .boolean })
        else
            try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rinit, .ty = .boolean });
        _ = try self.emit(.{ .op = .guard_true, .a = cmp });

        // Publish the inner root's entry state: the control index `R[a]` and the visible
        // loop var `R[a+3]` both start at `init`. (limit `R[a+1]` / step `R[a+2]` are
        // untouched by the loop and already flow through the exit snapshot.)
        self.setReg(a, rinit);
        self.setReg(a + 3, rinit);

        // Close with the `.link` terminator (commit reads `link_target`). closeTrace
        // commits + clears `active`; a build failure gates the anchor, like any abort.
        self.rec.link_target = inner_anchor;
        self.closeTrace(regs);
    }

    /// Cross-frame tracing — inline a Lua callee's body straight into the trace
    /// (LuaJIT's `lj_record_call`). The dispatch loop keeps driving the recorder
    /// through the callee's bytecode after tier-0 pushes the frame, so all this
    /// does is: (1) emit a `guard_func` pinning the runtime callee to the recorded
    /// `Proto.id` (fails closed → deopt to tier-0, which really calls it); (2)
    /// **S1**-seed every callee slot `.def` so no callee index is ever read
    /// `.undef` (which would emit an OOB `slot_load`); (3) push a recorder frame and
    /// shift `base_off` into the callee window. The call's frame-push / param-copy /
    /// pop never executes on the trace — callee slots are pure internal SSA
    /// temporaries on the single anchor `RegWindow` (see the safety rails, doc 10).
    ///
    /// Aborts cleanly (tier-0 owns the loop) on every shape we don't inline:
    /// a host (`native`) callee is a trace barrier; a non-callable / `__call`
    /// metamethod, a vararg callee, dynamic multret (`all_results` arg or result
    /// window — no compile-time-fixed slots to seed/map), and exceeding
    /// `MAX_INLINE_DEPTH` or the `reg_map` reservation all abort.
    fn recCall(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto) !void {
        const callee = regs.get(instr.a);
        if (!callee.isHeap()) return self.abort(.cross_frame);
        switch (callee.heapType()) {
            // A host call crosses the embedding boundary — heap effects we can't
            // model on the trace — UNLESS the native is a pure deterministic builtin
            // the JIT may inline as a dedicated leaf op (e.g. `math.sqrt`). Anything
            // else stays the host barrier.
            .native => {
                const nat = function.Native.fromHeader(callee.asHeap());
                if (nat.pure) |pb| switch (pb) {
                    .sqrt => return self.recPureSqrt(instr, regs),
                };
                return self.abort(.host_barrier);
            },
            .function => {},
            // `__call` on a table/userdata, or anything else callable only via a
            // metamethod, is not a plain Lua-closure call. Not inlined.
            else => return self.abort(.cross_frame),
        }
        // Dynamic argument or result windows (`reg_top`-driven multret) have no
        // compile-time-fixed slot count to seed (args) or map (results). Abort;
        // fixed multret broadening is Phase 2.
        if (instr.b == bytecode.all_results) return self.abort(.cross_frame);
        if (instr.c == bytecode.all_results) return self.abort(.cross_frame);

        const cl = function.Closure.fromHeader(callee.asHeap());
        const cp = cl.proto;
        // A vararg callee's extra-args frame cursor isn't modelled on the trace.
        if (cp.is_vararg) return self.abort(.cross_frame);
        if (self.rec.inline_depth >= MAX_INLINE_DEPTH) return self.abort(.too_deep);

        // Callee window starts `caller_proto.num_registers` above the current
        // frame's base — exactly tier-0's `callee_base = base + caller.num_registers`,
        // in the recorder's anchor-relative `base_off` space. `proto` here is the
        // *caller* proto (the frame the `.call` executes in).
        const callee_base_off: u32 = self.rec.base_off + proto.num_registers;
        if (@as(usize, callee_base_off) + cp.num_registers > self.rec.reg_map.len)
            return self.abort(.too_deep);

        // (1) guard_func: pin the runtime callee to this proto's stable id. `aux`
        // carries `Proto.id` (a `u32`, NOT a pointer — pointers change across a
        // keyframe restore and would break replay). Fails closed in the executor.
        const callee_ref = try self.refOf(instr.a);
        _ = try self.emit(.{ .op = .guard_func, .a = callee_ref, .aux = @bitCast(cp.id) });

        // (2) S1: seed every callee slot `.def`. Param slots (`i < num_params` and
        // an arg was actually passed) take the caller arg's SSA ref; everything else
        // is `nil`, matching tier-0's nil-fill of an unset register. After this no
        // callee slot is `.undef`, so `refOf` never emits a `slot_load` on a callee
        // index (which would be an out-of-window trace input).
        const nargs: u16 = instr.b;
        var i: u16 = 0;
        while (i < cp.num_registers) : (i += 1) {
            const seed: Ref = if (i < cp.num_params and i < nargs)
                try self.refOf(@intCast(@as(usize, instr.a) + 1 + i))
            else
                try self.konst(Value.nil());
            self.rec.reg_map[callee_base_off + i] = .{ .ref = seed, .state = .def };
        }

        // (3) push the recorder frame and descend into the callee window.
        self.rec.frames[self.rec.inline_depth] = .{
            .base_off = self.rec.base_off,
            .ret_dest = instr.a,
            .ret_count = instr.c,
        };
        self.rec.inline_depth += 1;
        self.rec.base_off = callee_base_off;
    }

    /// Inline a `math.sqrt(x)` call (callee flagged `PureBuiltin.sqrt`, doc 12) as a
    /// leaf `fsqrt` producer instead of aborting `.host_barrier`. Emits, in order:
    /// `guard_pure(callee)` (re-prove the seeded callee is still this exact builtin —
    /// deduped like a type guard, LICM-hoistable since the callee is a once-seeded
    /// loop invariant), `guard_float(arg)` (pin the float operand), then
    /// `fsqrt(arg)` whose result lands directly in the call's destination register.
    /// NO frame push / NO `recReturn`: `fsqrt` is a leaf producer — the single value
    /// the call site wants is `instr.a` itself, with no callee window to model.
    fn recPureSqrt(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        // One fixed arg, one fixed result. Dynamic windows (`all_results`) and any
        // other arity have no leaf shape — abort, tier-0 owns the call.
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        // v1 is float-only: a non-float arg (int included) aborts so tier-0 owns the
        // int→float promotion. The observed-float arg is pinned by `guard_float`.
        const arg = regs.get(@intCast(@as(usize, instr.a) + 1));
        if (!arg.isFloat()) return self.abort(.bad_type);

        // `guard_pure` re-proves the callee identity. The callee ref is the seeded
        // loop-invariant input (so the guard checks the same value `seedTraceInputs`
        // re-resolves). Deduped against `guarded_refs` — one SSA value, one identity
        // check (a native callee never carries a numeric type guard, so reusing the
        // set is sound). `aux` carries the `PureBuiltin` ordinal, not a PC.
        const callee_ref = try self.refOf(instr.a);
        if (!self.rec.guarded_refs.contains(callee_ref)) {
            try self.rec.guarded_refs.put(self.gpa, callee_ref, {});
            _ = try self.emit(.{ .op = .guard_pure, .a = callee_ref, .aux = @intFromEnum(function.PureBuiltin.sqrt) });
        }
        const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
        try self.guard(arg_ref, .guard_float);
        const r = try self.emit(.{ .op = .fsqrt, .a = arg_ref, .ty = .float });
        self.setReg(instr.a, r);
    }

    /// Cross-frame tracing — close an inlined callee (LuaJIT's `lj_record_ret`).
    /// Only reached at `inline_depth > 0` (the anchor-frame `.ret` aborts). Maps the
    /// callee's result slots back into the caller's `ret_dest..` window, nil-padding
    /// to the call site's fixed `ret_count`, then pops the recorder frame and
    /// restores `base_off`. The result writes use *absolute* `reg_map` indices (the
    /// caller region is disjoint from and below the callee source region, so a
    /// single forward pass can read source then write dest without a buffer).
    fn recReturn(self: *TraceState, instr: Instr) !void {
        const d = self.rec.inline_depth - 1;
        const fr = self.rec.frames[d];
        // Dynamic result count — no fixed window to map. Abort (Phase 2 broadens
        // fixed multret; dynamic stays a barrier).
        if (instr.b == bytecode.all_results) return self.abort(.cross_frame);
        const produced: u16 = instr.b;
        const want: u16 = fr.ret_count;
        var k: u16 = 0;
        while (k < want) : (k += 1) {
            // `base_off` is still the callee window here, so `refOf` reads the
            // callee's result slots `instr.a + k`.
            const ref: Ref = if (k < produced)
                try self.refOf(@intCast(@as(usize, instr.a) + k))
            else
                try self.konst(Value.nil());
            self.rec.reg_map[@as(usize, fr.base_off) + fr.ret_dest + k] = .{ .ref = ref, .state = .def };
        }
        self.rec.base_off = fr.base_off;
        self.rec.inline_depth = d;
    }

    /// Cluster sub-lever 1 — record a `get_upval`/`get_global` as a synthetic entry
    /// input. The read's loop-invariant value (`resolved`, pre-resolved by the
    /// dispatch loop since the executor has no `*Vm`/closure) is snapshotted into a
    /// dead slab slot above the anchor window: emit a `slot_load` from that slot,
    /// register the (`kind`, `source`→`slot`) seeding recipe on the trace, and — for
    /// a function callee — pin its identity with `guard_func`. The dispatch loop
    /// re-seeds the slot every entry (so a cross-entry change deopts via the guard
    /// or a downstream type guard); a `set_upval`/`set_global` *inside* the traced
    /// region is not in the record switch, so it aborts — the snapshot can never go
    /// stale mid-run.
    fn recInputGet(self: *TraceState, comptime kind: InputKind, dest: u16, source: u16, resolved: Value) !void {
        // U0 seeds only *anchor-frame* reads: the dispatch loop resolves the
        // snapshot against the anchor frame's closure/proto at entry, so an
        // upvalue/global read inside an inlined callee (whose indices refer to a
        // different closure/proto) cannot be seeded — abort, tier-0 owns the loop.
        // This is also the doc-10 tripwire: the day an inlined callee's *own* body
        // reads an upvalue, `guard_func` must tighten from `Proto.id` to the
        // closure's `GcHeader.id` (two closures over one proto stop being
        // trace-identical once their captured upvalues are read).
        if (self.rec.inline_depth != 0) return self.abort(.cross_frame);

        const key = (@as(u64, @intFromEnum(kind)) << 32) | source;
        if (self.rec.input_dedup.get(key)) |ref| {
            // A repeat read of the same upvalue/global reuses the one snapshot.
            self.setReg(dest, ref);
            return;
        }
        // Cap the number of synthetic inputs a single trace may carry. The hard
        // limit is the executor window the dispatch loop must widen (checked against
        // `regCapacity` at entry); this cap bounds it cheaply and keeps a
        // pathological loop from growing the entry snapshot without bound.
        if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.too_deep);

        // Defensive: the synthetic slot counter is a `u16` seeded at
        // `anchor_num_registers`. A function with a near-`u16`-max register window
        // could push it to the wrap boundary; an `@intCast`-wrapped slot would fold
        // back *into* the live anchor window as a plausible in-window `slot_load`
        // that `assertWellFormed` (bound `anchor_num_registers + n_inputs`) cannot
        // catch — and `seedTraceInputs` would then clobber a live caller register.
        // Abort rather than wrap. (MAX_TRACE_INPUTS already bounds the count; this
        // bounds the *index*.)
        if (self.rec.next_input_slot == std.math.maxInt(u16)) return self.abort(.too_deep);

        const slot = self.rec.next_input_slot;
        self.rec.next_input_slot += 1;
        const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
        try self.rec.entry_slots.append(self.gpa, slot);
        try self.rec.input_seeds.append(self.gpa, .{ .kind = kind, .source = source, .slot = slot });
        try self.rec.input_dedup.put(self.gpa, key, ref);
        // Pin a *function* callee's identity so a different proto — or a value that
        // is no longer a function — side-exits. A non-function loop-invariant (e.g.
        // an upvalue table) needs no identity guard: its *type* is pinned by the
        // ordinary operand guard wherever the trace consumes it.
        if (resolved.isHeap() and resolved.heapType() == .function) {
            const cl = function.Closure.fromHeader(resolved.asHeap());
            _ = try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) });
        }
        self.setReg(dest, ref);
    }
};

/// Result type of a recorded arithmetic op given its observed operands. Mirrors
/// `arith.zig`: `/` and `^` are always float; otherwise int iff both operands are
/// int (matching tier-0's int/float promotion).
fn arithResultType(op: IrOp, vb: Value, vc: Value) ObsType {
    if (op == .div or op == .pow) return .float;
    return if (vb.isInt() and vc.isInt()) .int else .float;
}

fn obsTypeOf(v: Value) ObsType {
    return switch (v.tag) {
        .nil => .nil,
        .boolean => .boolean,
        .int => .int,
        .float => .float,
        .heap_ref => .heap,
        // TODO(Phase 8, doc 14): the fused grid-index path observes grid rows
        // directly; until it lands the recorder never sees a `row_view` operand
        // (grids are disabled), so this is unreachable.
        .row_view => unreachable,
    };
}

/// State of a tier-0 register within the recording: `undef` (never touched →
/// next read emits a `slot_load`), `input` (holds a `slot_load` ref — read but
/// not written, loop-invariant), or `def` (holds a computed ref — a loop-carried
/// write that surfaces in the exit snapshot).
const SlotState = enum { undef, input, def };

/// The SSA ref currently held by a tier-0 register, with how it got there.
const RegSlot = struct { ref: Ref = 0, state: SlotState = .undef };

/// Key for interning constants in the recorder's const pool. Built from the tag
/// plus the meaningful payload bits — NOT the raw 16-byte `Value`, which has
/// uninitialised padding between `tag` and `payload`. Immediates compare by
/// value; a `heap_ref` const (always a string literal) compares by object
/// identity, which is conservative and sufficient: the same pooled literal is the
/// same heap object, and consts are GC roots for the recording's lifetime, so no
/// address is reused mid-recording.
const KonstKey = struct { tag: u8, bits: u64 };

fn konstKey(v: Value) KonstKey {
    return .{
        .tag = @intFromEnum(v.tag),
        .bits = switch (v.tag) {
            .nil => 0,
            .boolean => @as(u64, @intFromBool(v.asBool())),
            .int => @bitCast(v.asInt()),
            .float => @bitCast(v.asFloat()),
            .heap_ref => @intFromPtr(v.asHeap()),
            // Never a trace constant (runtime transient).
            .row_view => unreachable,
        },
    };
}

/// The in-progress recording buffer. `TraceState` owns it and drives every
/// mutation through its own methods (`emit`/`refOf`/`recordInstr`/…); this struct
/// is just storage + cleanup. While `active` is false the interpreter never calls
/// into it.
/// A deferred read-modify-write array store, sunk below every guard at trace
/// close. `aref`/`value` are IR refs already emitted inline (the address node and
/// the value to store); `lane_ord` is the packed-array `Lane` ordinal (the
/// `astore`'s `aux`). See `Recorder.pending_stores`.
const PendingStore = struct { aref: Ref, value: Ref, lane_ord: i32, op: IrOp = .astore };

/// Maximum number of read-modify-write stores a single trace may sink (Gap C,
/// `docs/design/08-multi-store-sinking.md`). Caps the simultaneously-live value
/// registers the store-sinking holds from computation to the trace-close flush —
/// bounding native XMM/GP pressure. 4 covers the FFT butterfly (`v[i],v[i+1]` and
/// `v[j],v[j+1]` per iteration) exactly; a trace that wants more aborts cleanly.
const MAX_PENDING_STORES = 4;

/// Maximum nesting of inlined Lua calls a single trace may carry (cross-frame
/// tracing). Bounds the recorder's grown `reg_map` window and the depth of leaf
/// inlining. Down-recursion (the same proto re-inlined) is Phase 3; until then a
/// call beyond this depth aborts cleanly (`AbortReason.too_deep`) and tier-0 owns
/// the loop.
const MAX_INLINE_DEPTH = 3;

/// Per-inlined-frame register reservation in the recorder's grown `reg_map`. The
/// map is sized `anchor.num_registers + MAX_INLINE_DEPTH × MAX_CALLEE_REGS`; a
/// callee whose `num_registers` exceeds this reservation (or that would overflow
/// the map at depth) aborts cleanly rather than reading the slab out of bounds.
/// 256 covers every realistic leaf body the compiler emits.
const MAX_CALLEE_REGS = 256;

/// Maximum number of synthetic entry inputs (upvalue/global snapshots, cluster
/// sub-lever 1) a single trace may carry. Each is one slab slot the dispatch loop
/// re-seeds + widens the executor window by; 8 covers every realistic hot loop
/// (a handful of upvalue/global callees). A trace wanting more aborts cleanly.
const MAX_TRACE_INPUTS = 8;

/// One saved caller context for an inlined `.call`, popped at the matching
/// `.ret`. `base_off` is the caller frame's absolute slot offset (relative to the
/// anchor frame's base); `ret_dest`/`ret_count` mirror the call's `instr.a`/
/// `instr.c` (where results land in the caller, and how many it wants).
const InlineFrame = struct { base_off: u32, ret_dest: u16, ret_count: u16 };

/// Disposition of an in-flight recording, deciding whether it may close with a
/// `.link` terminator (doc 16). Only the *anchor* — where the recording started
/// and what already lives there — differs between the three; the link-permission
/// rule is "a `root` never links; a `side` or `continuation` may".
///
/// - `.root`      — the ordinary case. Armed by `arm` (hot-count or
///                  `wants_side_trace`) at an anchor that has no trace yet (or is
///                  a fresh root). A root that reaches an inner `for_prep` aborts
///                  LINNER (LuaJIT's model) so it never anchors a link trace on a
///                  real back-edge target.
/// - `.side`      — an outer-header prime side-trace (doc 16, Phase 2), armed by
///                  `maybeStartReplaySide` at the failed trace's own coherent
///                  anchor to record the *current* (e.g. prime) iteration's path.
///                  May close with a `.link` into an existing inner root.
/// - `.continuation` — a nested-loop continuation (doc 15), armed by
///                  `maybeStartContinuation` at a non-header exit pc after an
///                  inner loop's loop-done exit. May close with a `.link`.
pub const TraceKind = enum { root, side, continuation };

pub const Recorder = struct {
    active: bool = false,
    anchor: AnchorKey = .{ .proto = undefined, .pc = 0 },
    abort_reason: ?AbortReason = null,
    instrs: std.ArrayListUnmanaged(IrInstr) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    entry_slots: std.ArrayListUnmanaged(u16) = .empty,
    /// Refs already covered by a type guard, so we emit each at most once.
    guarded_refs: std.AutoHashMapUnmanaged(Ref, void) = .empty,
    /// Interns constants: a recurring literal reuses its `konst` instruction's
    /// ref (and pool slot) instead of emitting a fresh one, so identical
    /// subexpressions get identical operand refs and the optimizer's CSE can
    /// merge them. See `TraceState.konst`.
    konst_map: std.AutoHashMapUnmanaged(KonstKey, Ref) = .empty,
    /// Current SSA ref + state for each tier-0 register, sized to the recording
    /// frame's `num_registers`.
    reg_map: []RegSlot = &.{},
    /// Lowest register slot that is a *compiler temporary* at this trace's loop
    /// header — the live-locals watermark. Set only by the `for_loop` whose
    /// back-edge targets this trace's anchor (so it describes the loop the trace
    /// actually re-enters): for a numeric-`for` the control regs occupy
    /// `base..base+3`, so every slot `>= base+4` is an expression temporary, dead
    /// at every statement boundary (`compiler.zig:8-9`) and after the loop
    /// (`freeTo(base)`). `commit()` drops such slots from the exit snapshot — they
    /// are recomputed by tier-0 on deopt and never read post-loop. The `maxInt`
    /// sentinel means "unknown" (while / generic-`for` / a passed-through `for`),
    /// so nothing is filtered and behavior is unchanged.
    locals_watermark: u32 = std.math.maxInt(u32),
    /// Nested-loop trace linking (doc 15, Phase 2): when set, this recording is a
    /// *continuation* that re-reached an inner numeric-`for`'s `for_prep` whose loop
    /// header already has a root trace. The value is the inner root's anchor pc (a
    /// bytecode pc in this same proto). `commit()` then closes the trace with a
    /// `.link{aux=link_target}` terminator *instead of* `.loop`, and caches it
    /// unoptimized (link traces skip `tropt`). `null` for every ordinary
    /// root/continuation trace (closes with `.loop`). Reset to `null` by `reset`.
    link_target: ?u32 = null,
    /// Nested-loop trace linking (doc 15, Phase 2): true iff this recording is a
    /// *continuation* — armed at a non-header exit pc by `maybeStartContinuation`,
    /// recording the outer body after an inner loop's loop-done exit. Only a
    /// continuation may close with a `.link` when it re-reaches an inner `for_prep`
    /// (LuaJIT's model: a *root* recording that hits an inner loop aborts LINNER and
    /// lets the inner spawn the side trace, so the root never links). Crucially this
    /// keeps link anchors off real back-edge targets — a root at the outer header
    /// would anchor a link trace at the outer body start (a genuine loop header the
    /// dispatch loop *enters*), which Phase 2 cannot execute. Set by
    /// `maybeStartContinuation` (`.continuation`) or `maybeStartReplaySide`
    /// (`.side`); reset to `.root` by `reset` (every `arm`). `recForPrepLink`
    /// permits a `.link` close for `.side`/`.continuation` but never `.root`.
    kind: TraceKind = .root,
    /// Bytecode PC of the instruction currently being recorded. Set by
    /// `recordInstr` before `recordOne`; `emit` stores it in the `aux`
    /// field of guard instructions so the executor can report *which*
    /// guard failed (per-guard PC recording for exit-PC chaining).
    cur_pc: u32 = 0,
    /// Tier-0 opcode of the instruction currently being recorded. Set alongside
    /// `cur_pc` in `recordInstr`; read by `logAbort` (when `config.record_aborts`)
    /// to name the opcode that triggered an abort. `.halt` is a harmless initial
    /// placeholder — overwritten before any abort can reference it.
    cur_op: OpCode = .halt,
    /// Deferred (sunk) array stores: in-bounds `astore`s that follow an `aload` (a
    /// read-modify-write). Rather than abort the trace (the old C1 rule),
    /// `recArraySet` records each store's address + guards inline but stashes the
    /// `astore` node itself here; `commit()` flushes them — *front-to-back, in the
    /// recorded (tier-0 bytecode) order* — *after* every guard (incl. the `for_loop`
    /// continuation guard), just before the `.loop` terminator. Sinking them below
    /// all side-exits makes deopt-replay idempotent: any guard failure leaves *all*
    /// of them un-executed, so tier-0 re-runs the iteration along the original source
    /// path and applies exactly that path's stores once each. Flushing in recorded
    /// order keeps last-writer-wins identical between the trace and tier-0 even if two
    /// stores alias. See `docs/design/08-multi-store-sinking.md` (Gap C); doc 07 is
    /// the single-store original (Gap B).
    ///
    /// While `pending_store_count > 0`, any further *read* (`aload`) or *append*
    /// (`astore_append`) aborts the trace — the sunk stores must be the trace's last
    /// array accesses (no store-then-read divergence; append changes `len`). A further
    /// in-bounds RMW `astore` instead *appends* here, up to `MAX_PENDING_STORES`;
    /// exceeding the cap aborts. `count == 0` ⇒ no deferred store (the common case:
    /// pure-write loops emit inline as before).
    pending_stores: [MAX_PENDING_STORES]PendingStore = undefined,
    pending_store_count: usize = 0,

    // --- cross-frame tracing (inlined Lua calls) ---------------------------
    /// The anchor (outermost) frame's register count. The grown `reg_map` may be
    /// wider (it reserves space for inlined callee frames), so the executor's real
    /// register window is `[0, anchor_num_registers)`. `assertWellFormed` pins
    /// every `slot_load`/`phi` slot below this bound (S3), and `commit()` caps φ
    /// writeback to it (S2): callee slots are pure internal SSA temporaries, dead
    /// at the loop boundary, never loop-carried.
    anchor_num_registers: u16 = 0,
    /// Absolute slot offset of the frame currently being recorded, relative to the
    /// anchor frame's base. 0 for the anchor frame; `caller_base_off +
    /// caller_proto.num_registers` for an inlined callee. `refOf`/`setReg` add it
    /// to translate a frame-relative slot into a `reg_map` index, exactly as the
    /// interpreter's `callee_base = base + caller.num_registers` lays out windows.
    base_off: u32 = 0,
    /// Saved caller contexts for the currently-open inlined calls, indexed by
    /// `inline_depth - 1`. Pushed at an inlined `.call`, popped at the `.ret`.
    frames: [MAX_INLINE_DEPTH]InlineFrame = undefined,
    /// Number of inlined calls currently open (frame-stack depth). 0 at the anchor
    /// frame; a `.call` beyond `MAX_INLINE_DEPTH` aborts `.too_deep`.
    inline_depth: u8 = 0,

    // --- cluster sub-lever 1: upvalue/global-reached callee snapshots ---------
    /// Synthetic entry inputs accumulated this recording: each loop-invariant
    /// upvalue/global the dispatch loop must re-seed before entry (see `InputSeed`).
    /// Becomes the committed trace's `inputs`.
    input_seeds: std.ArrayListUnmanaged(InputSeed) = .empty,
    /// Dedup: maps `(kind, source)` (packed `u64`) → the synthetic `slot_load`'s
    /// SSA ref, so a repeated `get_upval`/`get_global` of the same source reuses one
    /// input slot + one `guard_func` instead of emitting another.
    input_dedup: std.AutoHashMapUnmanaged(u64, Ref) = .empty,
    /// Dedup for H1 `hash_cell` seeds: maps `(table_reg, key_const)` (packed `u64`)
    /// → the synthetic slab slot, so an RMW's read+write `href`s (and repeated reads
    /// of the same field) share one seeded cell pointer instead of consuming two of
    /// the `MAX_TRACE_INPUTS` budget. Separate from `input_dedup` because the value
    /// is a raw slot (no `slot_load` ref — `href` is the consumer via its `aux`).
    hash_cell_dedup: std.AutoHashMapUnmanaged(u64, u16) = .empty,
    /// Next synthetic input slab slot to hand out. Initialised to
    /// `anchor_num_registers` in `reset` (inputs live *above* the anchor window);
    /// bumped once per unique input. The slot is only ever a `slot_load` `aux` and
    /// an executor `RegWindow` index — never a `reg_map` index — so it does not
    /// collide with the inlined-callee scratch the `reg_map` tail reserves.
    next_input_slot: u16 = 0,

    pub fn deinit(self: *Recorder, gpa: std.mem.Allocator) void {
        self.input_seeds.deinit(gpa);
        self.input_dedup.deinit(gpa);
        self.hash_cell_dedup.deinit(gpa);
        self.instrs.deinit(gpa);
        self.consts.deinit(gpa);
        self.entry_slots.deinit(gpa);
        self.guarded_refs.deinit(gpa);
        self.konst_map.deinit(gpa);
        if (self.reg_map.len != 0) gpa.free(self.reg_map);
    }

    /// Clear the buffer and arm a fresh recording for `anchor` over a frame with
    /// `num_registers` registers. Reuses retained capacity; only (re)allocates
    /// `reg_map` when the register count changes.
    pub fn reset(self: *Recorder, gpa: std.mem.Allocator, anchor: AnchorKey, num_registers: u16) !void {
        self.instrs.clearRetainingCapacity();
        self.consts.clearRetainingCapacity();
        self.entry_slots.clearRetainingCapacity();
        self.guarded_refs.clearRetainingCapacity();
        self.konst_map.clearRetainingCapacity();
        self.input_seeds.clearRetainingCapacity();
        self.input_dedup.clearRetainingCapacity();
        self.hash_cell_dedup.clearRetainingCapacity();
        // Size the register map for the anchor frame **plus** reserved windows for
        // inlined callee frames (cross-frame tracing). The executor only ever
        // touches `[0, anchor_num_registers)`; the tail is scratch the recorder
        // uses to hold callee SSA temporaries while inlining.
        const wanted: usize = @as(usize, num_registers) + MAX_INLINE_DEPTH * MAX_CALLEE_REGS;
        if (self.reg_map.len != wanted) {
            if (self.reg_map.len != 0) gpa.free(self.reg_map);
            self.reg_map = try gpa.alloc(RegSlot, wanted);
        }
        @memset(self.reg_map, .{});
        self.anchor = anchor;
        self.abort_reason = null;
        self.locals_watermark = std.math.maxInt(u32);
        self.link_target = null;
        self.kind = .root;
        self.pending_store_count = 0;
        self.anchor_num_registers = num_registers;
        self.base_off = 0;
        self.inline_depth = 0;
        self.next_input_slot = num_registers;
        self.active = true;
    }
};

// ---------------------------------------------------------------------------
// Disassembly — same spirit as `bytecode.writeProto`. Invaluable for `--dump-
// traces` and for asserting trace shape in tests.
// ---------------------------------------------------------------------------

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
        => try w.print("%{d}", .{ins.a}),
        // `guard_pure` reads the callee `%a` and tags the builtin in `aux`.
        .guard_pure => try w.print("%{d}  [{s}]", .{ ins.a, @tagName(@as(function.PureBuiltin, @enumFromInt(ins.aux))) }),
        .loop, .preheader => {},
        // `.link` (doc 15): terminal hand-off; `aux` is the inner root's anchor pc.
        .link => try w.print("-> {d}", .{ins.aux}),
        // φ: a slot-bound φ prints `update=%b → r{slot}` (init is implicit
        // `regs[slot]`); an internal φ prints `init=%a update=%b → internal`.
        .phi => {
            if (ins.aux == PHI_INTERNAL) {
                try w.print("init=%{d} update=%{d} -> internal", .{ ins.a, ins.b });
            } else {
                try w.print("update=%{d} -> r{d}", .{ ins.b, ins.aux });
            }
        },
        else => try w.print("%{d}  %{d}", .{ ins.a, ins.b }),
    }
}

/// Disassemble a whole trace: header + entry slots + numbered IR (the slot-bound
/// `phi` rows are the loop-carried writebacks that `exit_stores` used to list).
pub fn writeTrace(w: *io.Writer, t: *const Trace) io.Writer.Error!void {
    try w.print("trace {s}:{d}  entry=[", .{ t.anchor.proto.name, t.anchor.pc });
    for (t.entry_slots, 0..) |s, i| {
        if (i != 0) try w.writeAll(" ");
        try w.print("r{d}", .{s});
    }
    try w.writeAll("]\n");
    for (t.instrs, 0..) |ins, i| {
        try w.print("  %{d:0>3}  ", .{i});
        try writeIrInstr(w, ins);
        try w.writeAll("\n");
    }
}

/// Render the abort log (`--dump-aborts`) as one aligned row per distinct
/// `(anchor, reason, opcode)`, sorted by `count` descending so the loops that
/// abort most — the ones actually keeping a program on tier-0 — are at the top.
/// `rows` is `state.abort_log.items`; the caller owns it (this only reads).
pub fn writeAborts(w: *io.Writer, rows: []AbortRecord) io.Writer.Error!void {
    // Sort a borrowed view in place by count desc, then anchor pc for stability.
    std.mem.sort(AbortRecord, rows, {}, struct {
        fn lt(_: void, a: AbortRecord, b: AbortRecord) bool {
            if (a.count != b.count) return a.count > b.count;
            if (a.anchor_pc != b.anchor_pc) return a.anchor_pc < b.anchor_pc;
            return @intFromEnum(a.op) < @intFromEnum(b.op);
        }
    }.lt);
    try w.print("{s:>12}  {s:>6}  {s:>7}  {s:<14}  {s:>6}  {s:<16}  {s}\n", .{
        "count", "anc@pc", "abrt@pc", "reason", "ir_len", "opcode", "anchor",
    });
    for (rows) |r| {
        try w.print("{d:>12}  {d:>6}  {d:>7}  {s:<14}  {d:>6}  {s:<16}  {s}\n", .{
            r.count,
            r.anchor_pc,
            r.abort_pc,
            @tagName(r.reason),
            r.ir_len,
            @tagName(r.op),
            r.proto.name,
        });
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

// ---------------------------------------------------------------------------
// Tests (Increment A): IR shape + disassembler + hotness counting.
// ---------------------------------------------------------------------------

const testing = std.testing;

// Test-only register-window adapters over the SoA lanes. The unit tests build flat
// `[]Value` register fixtures; `winRO` seeds shared scratch lanes from one and hands
// back a read-only window (recorder / fingerprint sites never write `regs` back).
// `TestRegs` owns its lanes and adds `commit()` for the few sites whose callee
// mutates the window and whose test then asserts on the post-run register state.
var winro_tags: [64]u8 = undefined;
var winro_pays: [64]u64 = undefined;
fn winRO(regs: []const Value) RegWindow {
    std.debug.assert(regs.len <= winro_tags.len);
    for (regs, 0..) |v, i| {
        winro_tags[i] = @intFromEnum(v.tag);
        winro_pays[i] = v.payload.bits;
    }
    return RegWindow.of(winro_tags[0..regs.len], winro_pays[0..regs.len]);
}

const TestRegs = struct {
    regs: []Value,
    tags: [64]u8 = undefined,
    pays: [64]u64 = undefined,
    fn view(self: *TestRegs) RegWindow {
        std.debug.assert(self.regs.len <= self.tags.len);
        for (self.regs, 0..) |v, i| {
            self.tags[i] = @intFromEnum(v.tag);
            self.pays[i] = v.payload.bits;
        }
        return RegWindow.of(self.tags[0..self.regs.len], self.pays[0..self.regs.len]);
    }
    fn commit(self: *TestRegs) void {
        for (self.regs, 0..) |*v, i| v.* = .{ .tag = @enumFromInt(self.tags[i]), .payload = .{ .bits = self.pays[i] } };
    }
};

test "IrInstr stays small" {
    // Cache-sensitive representation; keep it compact. Not serialised here (the
    // wire format is binschema, Phase 5b) — just guard against accidental bloat.
    try testing.expect(@sizeOf(IrInstr) <= 16);
}

test "writeTrace renders a hand-built counting-loop trace" {
    // A stand-in for `for i=lo,hi do acc = acc + i end`'s recorded body:
    //   %0 = slot_load r0   (acc)
    //   %1 = slot_load r1   (i)
    //   %2 = guard_int %0
    //   %3 = guard_int %1
    //   %4 = add %0 %1
    //   loop  (acc<-%4, i<-%1)
    const proto = Proto{ .code = &.{}, .name = "main" };
    var instrs = withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int },
        .{ .op = .slot_load, .aux = 1, .ty = .int },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .loop },
    }, &[_]SlotStore{ .{ .slot = 0, .ref = 4 }, .{ .slot = 1, .ref = 1 } });
    var entry = [_]u16{ 0, 1 };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry,
        .entry_guards = &.{},
    };

    var buf: [512]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    try writeTrace(&w, &t);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "trace main:5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "entry=[r0 r1]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "slot_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    // The two loop-carried writebacks now render as slot-bound φ rows.
    try testing.expect(std.mem.indexOf(u8, text, "update=%4 -> r0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "update=%1 -> r1") != null);
}

test "onBackEdge counts back-edges per anchor" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 1000; // high enough that nothing arms — pure counting

    const proto = Proto{ .code = &.{}, .name = "t" };
    const hot = AnchorKey{ .proto = &proto, .pc = 3 };
    const cold = AnchorKey{ .proto = &proto, .pc = 99 };

    var i: u32 = 0;
    while (i < 10) : (i += 1) state.onBackEdge(&proto, 3, RegWindow.empty);
    state.onBackEdge(&proto, 99, RegWindow.empty); // a single, cold back-edge elsewhere

    try testing.expectEqual(@as(u32, 10), state.backEdgeCount(hot));
    try testing.expectEqual(@as(u32, 1), state.backEdgeCount(cold));
    try testing.expectEqual(@as(usize, 0), state.cache.items.len); // never armed
}

test "crossing the hotness threshold arms a recording" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 3;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    try testing.expect(!state.isRecording());
    state.onBackEdge(&proto, 7, RegWindow.empty); // 1
    state.onBackEdge(&proto, 7, RegWindow.empty); // 2 — not yet hot
    try testing.expect(!state.isRecording());
    state.onBackEdge(&proto, 7, RegWindow.empty); // 3 == hotloop → arm
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(u32, 7), state.rec.anchor.pc);
}

test "recArrayGet: t[k] on a bool lane records the full guarded read sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // nsieve's bool sieve → a narrow boolean lane.
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (3) ; `get_index r0, r1, r2`  →  r0 = t[3]
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // a clean record — no abort
    const ops = state.rec.instrs.items;
    // slot_load(table), guard_table, guard_lane, slot_load(key), guard_int,
    // aref, guard_bounds, guard_present, aload.
    try testing.expectEqual(@as(usize, 9), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_table, ops[1].op);
    try testing.expectEqual(IrOp.guard_lane, ops[2].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[2].aux);
    try testing.expectEqual(IrOp.slot_load, ops[3].op);
    try testing.expectEqual(IrOp.guard_int, ops[4].op);
    try testing.expectEqual(IrOp.aref, ops[5].op);
    try testing.expectEqual(ops[0].a, ops[5].a); // aref.table == the table slot_load... (ref check below)
    try testing.expectEqual(@as(Ref, 0), ops[5].a); // table ref
    try testing.expectEqual(@as(Ref, 3), ops[5].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[6].op);
    try testing.expectEqual(@as(Ref, 5), ops[6].a); // guards the aref
    try testing.expectEqual(IrOp.guard_present, ops[7].op);
    try testing.expectEqual(@as(Ref, 5), ops[7].a);
    try testing.expectEqual(IrOp.aload, ops[8].op);
    try testing.expectEqual(@as(Ref, 5), ops[8].a); // loads through the aref
    try testing.expectEqual(ObsType.boolean, ops[8].ty); // bool lane → boolean
}

test "recArrayGet aborts: non-table container, non-int key, hole, and out-of-bounds" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };

    const Case = struct { tab: Value, key: Value, why: AbortReason };
    const cases = [_]Case{
        .{ .tab = Value.int(7), .key = Value.int(3), .why = .bad_type }, // not a table
        .{ .tab = Value.heap(&t.header), .key = Value.boolean(true), .why = .bad_type }, // non-int key
        .{ .tab = Value.heap(&t.header), .key = Value.int(1), .why = .bad_type }, // hole at 1
        .{ .tab = Value.heap(&t.header), .key = Value.int(9999), .why = .bad_type }, // out of bounds
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), c.tab, c.key };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording()); // aborted
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recArrayGet records a .value-lane table element (array-of-structs)" {
    const gpa = testing.allocator;
    // Create a table whose array part holds a table — forces .value lane.
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const outer = try table_mod.Table.create(gpa);
    defer outer.destroy(gpa);
    try outer.set(gpa, Value.int(1), Value.heap(&inner.header));
    try testing.expectEqual(arr.Lane.value, outer.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&outer.header), Value.int(1) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    // Recording should succeed — the .value-lane table path emits IR.
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(?AbortReason, null), state.rec.abort_reason);
    // Verify the IR sequence: the last two instructions should be
    // aload(.value, ty=.heap) followed by guard_table (on the loaded element).
    const instrs = state.rec.instrs.items;
    const last = instrs[instrs.len - 1];
    try testing.expectEqual(IrOp.guard_table, last.op);
    const aload_ref = last.a;
    const aload_ins = instrs[@intCast(aload_ref)];
    try testing.expectEqual(IrOp.aload, aload_ins.op);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.value)), aload_ins.aux);
}

test "recArrayGet aborts on a .value-lane non-table element — nyi scope cut" {
    const gpa = testing.allocator;
    // Force .value lane by storing a table then a boolean at different indices.
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.heap(&inner.header)); // → .value lane
    try t.set(gpa, Value.int(2), Value.boolean(true)); // stays .value (can't narrow)
    try testing.expectEqual(arr.Lane.value, t.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    // Access index 2 (the boolean) — non-table element in .value lane → nyi_opcode.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.nyi_opcode, state.rec.abort_reason.?);
}

test "abort log records (anchor, reason, opcode) and dedups recurrences" {
    const gpa = testing.allocator;
    // Force .value lane by storing a table at [1] and a boolean at [2].
    // Accessing [2] (a non-table in .value lane) triggers nyi_opcode.
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.heap(&inner.header)); // → .value lane
    try t.set(gpa, Value.int(2), Value.boolean(true)); // stays .value
    try testing.expectEqual(arr.Lane.value, t.array.lane);

    const proto = Proto{ .code = &.{}, .name = "loop", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.record_aborts = true; // what --dump-aborts flips on

    // Access index 2 (the boolean, not the table) → nyi_opcode.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    // Re-arm and abort the same anchor/op three times: a real loop aborts on every
    // back-edge, and the log must collapse that to one row with count == 3.
    for (0..3) |_| {
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 7 }, proto.num_registers);
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 9, Value.nil());
    }

    try testing.expectEqual(@as(usize, 1), state.abort_log.items.len);
    const row = state.abort_log.items[0];
    try testing.expectEqual(@as(u64, 3), row.count);
    try testing.expectEqual(@as(u32, 7), row.anchor_pc);
    try testing.expectEqual(@as(u32, 9), row.abort_pc);
    try testing.expectEqual(OpCode.get_index, row.op);
    try testing.expectEqual(AbortReason.nyi_opcode, row.reason);
    // `ir_len` is the CUMULATIVE partial-trace length at abort time. This anchor
    // records nothing before the aborting `get_index`, so it is 0. In a real loop
    // (nbody's `bodies[i]`, array3d's `a[i][j]`) the loop header contributes a few
    // IR instrs first, so the same abort shows ir_len≈2 — "got this far, then died".
    try testing.expectEqual(@as(u32, 0), row.ir_len);

    // A distinct reason at the same anchor is a separate row.
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 7 }, proto.num_registers);
    state.recordInstr(Instr.opAB(.new_table, 0, 0), winRO(&regs), &proto, 3, Value.nil());
    try testing.expectEqual(@as(usize, 2), state.abort_log.items.len);

    // With the flag off, nothing is logged.
    var quiet = TraceState.init(gpa);
    defer quiet.deinit();
    try quiet.rec.reset(gpa, .{ .proto = &proto, .pc = 7 }, proto.num_registers);
    quiet.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 9, Value.nil());
    try testing.expectEqual(@as(usize, 0), quiet.abort_log.items.len);
}

test "recArrayGet/recArraySet abort on a metatable-bearing table (chunk 2a)" {
    const gpa = testing.allocator;
    // A dense boolean array — exactly the shape the recorder would otherwise
    // trace (`recArrayGet`/`recArraySet` lower it) — but carrying a metatable.
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    const mt = try table_mod.Table.create(gpa);
    defer mt.destroy(gpa);
    t.metatable = mt; // the metatable edge the access might dispatch through

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };

    // get_index: present, in-bounds, bool-lane — would record without a metatable.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index in-bounds in-lane store.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&t.header), Value.int(3), Value.boolean(false) };
        state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index append store (`t[len+1]=true`) — the path that would fire
    // `__newindex` on an absent key.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&t.header), Value.int(33), Value.boolean(true) };
        state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
}

test "recArraySet: t[k]=false on a bool lane records the full guarded write sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (3), r0 = value (false); `set_index a=1 b=2 c=0` → t[3]=false.
    var regs = [_]Value{ Value.boolean(false), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // clean record — no abort
    const ops = state.rec.instrs.items;
    // value resolved first (for the C1 taint scan): slot_load(value), then
    // slot_load(table), guard_table, guard_lane, slot_load(key), guard_int, aref,
    // guard_bounds, guard_fits, astore. No guard_present — astore creates presence.
    // guard_fits is now emitted for the bool lane too (value-stability: a non-bool
    // free-variable store side-exits to tier-0 instead of tripping the oracle).
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op); // value (r0)
    try testing.expectEqual(IrOp.slot_load, ops[1].op); // table (r1)
    try testing.expectEqual(IrOp.guard_table, ops[2].op);
    try testing.expectEqual(IrOp.guard_lane, ops[3].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[3].aux);
    try testing.expectEqual(IrOp.slot_load, ops[4].op); // key (r2)
    try testing.expectEqual(IrOp.guard_int, ops[5].op);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(@as(Ref, 1), ops[6].a); // table ref
    try testing.expectEqual(@as(Ref, 4), ops[6].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[7].op);
    try testing.expectEqual(@as(Ref, 6), ops[7].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[8].op);
    try testing.expectEqual(@as(Ref, 0), ops[8].a); // range-checks the false slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[8].aux);
    try testing.expectEqual(IrOp.astore, ops[9].op);
    try testing.expectEqual(@as(Ref, 6), ops[9].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 0), ops[9].b); // value = the false slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[9].aux);
}

test "recArraySet: a bool-lane append (t[len+1]=true) records the guarded grow sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // Fill 2..32 (index 1 stays a hole) so the table rehashes to the boolean lane and
    // drains its hash — exactly nsieve's init-loop steady state. len is the high-water
    // mark (32); the next store t[33] is the append successor (idx == len+1).
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);
    try testing.expectEqual(@as(usize, 0), t.hash.count()); // hash drained → migrate is a no-op
    const len_before = t.array.len;
    const append_key: i64 = @as(i64, @intCast(len_before)) + 1;

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (len+1), r0 = value (true); `set_index a=1 b=2 c=0`.
    var regs = [_]Value{ Value.boolean(true), Value.heap(&t.header), Value.int(append_key) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // clean record — the append path, no abort
    const ops = state.rec.instrs.items;
    // Same prologue as the in-bounds store, but guard_bounds → guard_append and
    // astore → astore_append: slot_load(value), slot_load(table), guard_table,
    // guard_lane, slot_load(key), guard_int, aref, guard_append, guard_fits,
    // astore_append.
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(IrOp.guard_append, ops[7].op);
    try testing.expectEqual(@as(Ref, 6), ops[7].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[8].op);
    try testing.expectEqual(IrOp.astore_append, ops[9].op);
    try testing.expectEqual(@as(Ref, 6), ops[9].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 0), ops[9].b); // value = the true slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[9].aux);

    // The recorder must NOT have mutated the table — recording is side-effect free.
    try testing.expectEqual(len_before, t.array.len);
}

test "recArraySet aborts: non-table, non-int key, OOB, out-of-lane value, .value lane" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    // A separate .value-lane table: a heap value can only live in the .value lane
    // (eager commit leaves it there — laneForValue of a heap ref is .value).
    const tv = try table_mod.Table.create(gpa);
    defer tv.destroy(gpa);
    try tv.set(gpa, Value.int(1), Value.heap(&tv.header));
    try testing.expectEqual(arr.Lane.value, tv.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    const Case = struct { tab: Value, key: Value, val: Value, why: AbortReason };
    const cases = [_]Case{
        // not a table container.
        .{ .tab = Value.int(7), .key = Value.int(3), .val = Value.boolean(false), .why = .bad_type },
        // non-int key (hash-part territory).
        .{ .tab = Value.heap(&t.header), .key = Value.boolean(true), .val = Value.boolean(false), .why = .bad_type },
        // out of bounds (k > len would grow the array).
        .{ .tab = Value.heap(&t.header), .key = Value.int(9999), .val = Value.boolean(false), .why = .bad_type },
        // out-of-lane value (an int into a bool lane would widen → shape change).
        .{ .tab = Value.heap(&t.header), .key = Value.int(3), .val = Value.int(5), .why = .bad_type },
        // nil value — a hole-punch / delete, out of B3 scope.
        .{ .tab = Value.heap(&t.header), .key = Value.int(3), .val = Value.nil(), .why = .bad_type },
        // .value-lane array — deferred scope cut.
        .{ .tab = Value.heap(&tv.header), .key = Value.int(1), .val = Value.int(20), .why = .nyi_opcode },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ c.val, c.tab, c.key };
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recArraySet defers an RMW store (store-sinking) instead of aborting" {
    // The old C1 rule aborted any store that followed a packed read. Store-sinking
    // (Gap B) instead DEFERS the single store and flushes it below every guard at
    // trace close, so a read-modify-write records and runs native. See
    // `docs/design/07-rmw-store-sinking.md`.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key. First: r0 = t[r2] (a packed read → aload). The recorder's
    // get_index executes against the live table; r0 then logically holds t[3] = true.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.nil() };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording()); // the read records cleanly

    // Now t[k] = (the value just read), an RMW. The store defers (sinks) rather
    // than aborting: the trace stays live and `pending_store` is armed.
    regs[0] = Value.boolean(true); // r0 = t[3], a boolean
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_store_count);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.boolean)), state.rec.pending_stores[0].lane_ord);
    // The store is deferred — NOT yet in the instruction stream (it lands at commit).
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);

    // A subsequent packed read must abort: the sunk store has to be the LAST array
    // access (else on-trace store-then-read would diverge from tier-0 replay).
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
}

test "recArraySet sinks a read-steered const store (control channel) instead of aborting" {
    // `if t[i] then t[i]=false else t[i]=true end`: a guard on a read picks the
    // branch, so even a *constant* store could replay differently after a deopt.
    // Store-sinking handles this too — the store sits below the branch guard, so on
    // any side-exit the store has not executed and tier-0 re-runs the read+branch
    // cleanly. The trace records (deferred), no longer aborts.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key. r0 = t[r2] (a packed read).
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(false) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    // Branch on the read (a guard), then store a *constant* false (r3). The store
    // sinks below the branch guard — still recording, store deferred.
    state.recordInstr(Instr.opABC(.jmp_if_true, 0, 0, 0), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_store_count);
}

test "recArraySet sinks multiple RMW stores (Gap C: butterfly shape)" {
    // All reads precede all stores (the FFT butterfly shape): read t[3], read t[4],
    // then store t[3], store t[4]. Both stores are RMW (follow reads) → both defer
    // and sink, so `pending_store_count == 2` and neither `astore` is in the stream
    // yet (they flush at commit, in this recorded order). Under Gap B's single-store
    // rule the SECOND store aborted; Gap C records it. See `docs/design/08-...`.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 8 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key 3, r3 = key 4. r0 = t[3], r4 = t[4] (both reads first).
    var regs = [_]Value{
        Value.nil(),         Value.heap(&t.header), Value.int(3), Value.int(4),
        Value.boolean(true), Value.nil(),           Value.nil(),  Value.nil(),
    };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil()); // r0 = t[3]
    state.recordInstr(Instr.opABC(.get_index, 4, 1, 3), winRO(&regs), &proto, 0, Value.nil()); // r4 = t[4]
    try testing.expect(state.isRecording());

    // Tier-0 would have loaded the read values into r0/r4; mirror that so the
    // RMW stores below carry in-lane (boolean) values, not the initial nils.
    regs[0] = Value.boolean(true); // r0 = t[3]
    regs[4] = Value.boolean(true); // r4 = t[4]

    // Now write both back: t[3] = r0, t[4] = r4. Both defer.
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 4), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 2), state.rec.pending_store_count);
    // Recorded order preserved: store #0 → key 3's aref, store #1 → key 4's aref.
    try testing.expect(state.rec.pending_stores[0].aref != state.rec.pending_stores[1].aref);
    // Neither store is in the stream yet — they flush at commit.
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);
}

test "recArraySet aborts when sunk stores exceed MAX_PENDING_STORES" {
    // One read arms deferral; then MAX_PENDING_STORES in-bounds RMW stores defer, and
    // the next one exceeds the cap and aborts cleanly (no regression — it aborted
    // under Gap B too, just one store sooner). Guards the bounded buffer.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key, r3 = bool value. One read to arm deferral.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());

    // MAX_PENDING_STORES deferred stores (distinct in-bounds keys 3..3+MAX-1) record.
    var k: i64 = 3;
    while (k < 3 + @as(i64, MAX_PENDING_STORES)) : (k += 1) {
        regs[2] = Value.int(k);
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(state.isRecording());
    }
    try testing.expectEqual(@as(usize, MAX_PENDING_STORES), state.rec.pending_store_count);

    // One more store exceeds the cap → abort.
    regs[2] = Value.int(3 + @as(i64, MAX_PENDING_STORES));
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
}

// --- pure-builtin tracing (math.sqrt → guard_pure/fsqrt, doc 12) --------------

/// A do-nothing `NativeFn` body for recorder unit tests: the recorder never
/// *calls* the native (it inlines `fsqrt` directly), it only reads the heap
/// `Native`'s `pure` tag, so the body is irrelevant.
fn sqrtStub(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    _ = args;
    return Value.nil();
}

test "recPureSqrt: sqrt(float) records guard_pure, guard_float, fsqrt" {
    const gpa = testing.allocator;
    const nat = try function.Native.create(gpa, &sqrtStub, "math.sqrt");
    defer nat.destroy(gpa);
    nat.pure = .sqrt;

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r0 = sqrt (callee + result dest), r1 = arg (a float). `call r0, 1, 1`.
    var regs = [_]Value{ Value.heap(&nat.header), Value.float(2.0), Value.nil() };
    state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // a clean record — no abort
    const ops = state.rec.instrs.items;
    // slot_load(callee), guard_pure, slot_load(arg), guard_float, fsqrt.
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_pure, ops[1].op);
    try testing.expectEqual(@as(Ref, 0), ops[1].a); // guards the seeded callee ref
    try testing.expectEqual(@as(i32, @intFromEnum(function.PureBuiltin.sqrt)), ops[1].aux);
    try testing.expectEqual(IrOp.slot_load, ops[2].op);
    try testing.expectEqual(IrOp.guard_float, ops[3].op);
    try testing.expectEqual(@as(Ref, 2), ops[3].a); // guards the arg ref
    try testing.expectEqual(IrOp.fsqrt, ops[4].op);
    try testing.expectEqual(@as(Ref, 2), ops[4].a); // fsqrt reads the arg ref
    try testing.expectEqual(ObsType.float, ops[4].ty);
    // The call's destination register holds the fsqrt result (ref 4), not the callee.
    try testing.expectEqual(@as(Ref, 4), try state.refOf(0));
}

test "recPureSqrt aborts: bad arity, non-float arg, and a non-pure native" {
    const gpa = testing.allocator;
    const sq = try function.Native.create(gpa, &sqrtStub, "math.sqrt");
    defer sq.destroy(gpa);
    sq.pure = .sqrt;
    const plain = try function.Native.create(gpa, &sqrtStub, "print");
    defer plain.destroy(gpa); // pure == null

    const Case = struct { callee: *function.Native, arg: Value, b: u16, c: u16, why: AbortReason };
    const cases = [_]Case{
        // sqrt(a, b): two args → no leaf shape.
        .{ .callee = sq, .arg = Value.float(2.0), .b = 2, .c = 1, .why = .cross_frame },
        // x, y = sqrt(a): two results → no leaf shape.
        .{ .callee = sq, .arg = Value.float(2.0), .b = 1, .c = 2, .why = .cross_frame },
        // sqrt(int): v1 is float-only; tier-0 owns the int→float promotion.
        .{ .callee = sq, .arg = Value.int(4), .b = 1, .c = 1, .why = .bad_type },
        // print(x): a native with no `pure` tag stays the host barrier.
        .{ .callee = plain, .arg = Value.float(2.0), .b = 1, .c = 1, .why = .host_barrier },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&c.callee.header), c.arg, Value.nil() };
        state.recordInstr(Instr.opABC(.call, 0, c.b, c.c), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "per-guard PC recording: guard_int aux carries the bytecode PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A 3-register frame: r0=r1+r2, both ints, at PC 42.
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    var regs = [_]Value{ Value.nil(), Value.int(10), Value.int(20) };
    state.recordInstr(Instr.opABC(.add, 0, 1, 2), winRO(&regs), &proto, 42, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // Expected: slot_load(r1), slot_load(r2), guard_int(r1), guard_int(r2), add
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.slot_load, ops[1].op);
    try testing.expectEqual(IrOp.guard_int, ops[2].op);
    try testing.expectEqual(@as(i32, 42), ops[2].aux); // PC stored in aux
    try testing.expectEqual(IrOp.guard_int, ops[3].op);
    try testing.expectEqual(@as(i32, 42), ops[3].aux); // PC stored in aux
    try testing.expectEqual(IrOp.add, ops[4].op);
    try testing.expectEqual(@as(i32, 0), ops[4].aux); // add doesn't use aux
}

test "per-guard PC recording: guard_true aux carries the branch PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r0 is truthy (int 1), so jmp_if_false emits guard_true at PC 7.
    var regs = [_]Value{ Value.int(1), Value.nil() };
    state.recordInstr(Instr.opABC(.jmp_if_false, 0, 0, 0), winRO(&regs), &proto, 7, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // Expected: slot_load(r0), guard_true
    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_true, ops[1].op);
    try testing.expectEqual(@as(i32, 7), ops[1].aux); // PC stored in aux
}

test "driveChain ordinary_header: chains to a same-anchor sibling" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Trace A at PC 10: the trace whose guard "fails" (faked by calling
    // driveChain directly). After an *ordinary* guard exit the registers are
    // coherent at A's anchor (pc 10), so the driver chains to a same-anchor
    // sibling there — NOT to the guard's exit PC.
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .guard_int, .a = 0, .aux = 20 }, // %1: guard r0 (aux is exit PC, ignored for ordinary chaining)
        .{ .op = .loop }, // %2
    };
    const consts_a = [_]Value{};
    var trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .anchor = .{ .proto = undefined, .pc = 10 },
        .instrs = @constCast(&instrs_a),
        .consts = @constCast(&consts_a),
        .entry_slots = &entry_a,
        .entry_guards = &.{},
    };

    // Trace B: a sibling at the SAME anchor (pc 10) — a simple counting loop
    // (r0 from 0 to 3). Reached only because A is in `initially_excluded`.
    var entry_b = [_]u16{ 0, 1 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (counter)
        .{ .op = .slot_load, .aux = 1 }, // %1: r1 (limit)
        .{ .op = .guard_int, .a = 0, .aux = 10 }, // %2
        .{ .op = .guard_int, .a = 1, .aux = 10 }, // %3
        .{ .op = .konst, .aux = 0 }, // %4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // %5: r0 + 1
        .{ .op = .lt, .a = 5, .b = 1 }, // %6: (r0+1) < limit
        .{ .op = .guard_true, .a = 6, .aux = 10 }, // %7
        .{ .op = .phi, .a = 0, .b = 5, .aux = 0, .ty = .int }, // %8: r0 ← r0+1
        .{ .op = .loop }, // %9
    };
    const consts_b = [_]Value{Value.int(1)};
    var trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .anchor = .{ .proto = undefined, .pc = 10 }, // same anchor as A
        .instrs = @constCast(&instrs_b),
        .consts = @constCast(&consts_b),
        .entry_slots = &entry_b,
        .entry_guards = &.{},
    };

    // Put both traces in the cache.
    try state.cache.append(gpa, trace_a);
    try state.cache.append(gpa, trace_b);

    // Set proto on anchors (needed for findTrace lookup).
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    trace_a.anchor.proto = &proto;
    trace_b.anchor.proto = &proto;

    // Regs: r0=0, r1=4 → Trace B should run 3 iterations (0,1,2;
    // iteration 3 computes 3<4 which is true, runs, then 4<4 fails).
    var regs = [_]Value{ Value.int(0), Value.int(4) };

    // Fake a guard failure in Trace A at instr index 1 (the guard_int), and
    // exclude A (the dispatcher's `visited` set) so the driver walks to B.
    var tr_regs = TestRegs{ .regs = &regs };
    const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false);
    tr_regs.commit(); // the chained side trace mutated the window — reflect it back
    try testing.expect(chained != null);
    try testing.expectEqual(@as(usize, 3), chained.?.completed); // Trace B ran 3 iters
    try testing.expect(chained.?.resume_pc == null);
    try testing.expectEqual(@as(i64, 3), regs[0].asInt()); // r0 carried to 3

    // Remove traces from cache before deinit — they have stack-allocated
    // arrays that must not be freed by destroy().
    state.cache.clearRetainingCapacity();
    // Free the Trace heap allocations ourselves (instrs/consts/entry_slots
    // are stack memory, so skip those fields by not calling destroy).
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "armNativeLink / resetLinksTouching: P-E registry directionality" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // No trampoline is built in this unit test, so the value a reset restores
    // (the "unarmed" slot) is `trampoline_exit orelse 0` == 0.
    const SHARED_EXIT: usize = 0;
    try testing.expectEqual(@as(?usize, null), state.mcode_arena.trampoline_exit);

    // Two compiled-trace stubs. Only `.slots` is touched by the registry, so the
    // `.page` may stay undefined and we never call `destroy` on these.
    const parent_slots = try gpa.alloc(usize, 3);
    defer gpa.free(parent_slots);
    @memset(parent_slots, SHARED_EXIT);
    const child_slots = try gpa.alloc(usize, 1);
    defer gpa.free(child_slots);
    @memset(child_slots, SHARED_EXIT);

    var parent: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = child_slots, .gpa = gpa } },
    };

    const CHILD_BODY: usize = 0xDEAD_BEEF;

    // Arm: slot 1 of parent points at the child body; exactly one record tracked.
    try testing.expect(try state.armNativeLink(&parent, 1, &child, CHILD_BODY, .link_terminal));
    try testing.expectEqual(CHILD_BODY, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    // Re-arming the SAME slot supersedes the prior record IN PLACE (no duplicate,
    // no realloc — the record count stays 1 and the new target is written).
    const CHILD_BODY2: usize = 0xF00D;
    try testing.expect(try state.armNativeLink(&parent, 1, &child, CHILD_BODY2, .link_terminal));
    try testing.expectEqual(CHILD_BODY2, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    // Child retires (target side): parent's slot resets to shared_exit, record dropped.
    state.resetLinksTouching(&child);
    try testing.expectEqual(SHARED_EXIT, parent_slots[1]);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Out-of-range slot index is a no-op → returns false, no OOB write, no record.
    try testing.expect(!try state.armNativeLink(&parent, 99, &child, CHILD_BODY, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // A non-compiled parent is a no-op → returns false.
    var unsup: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .unsupported,
    };
    try testing.expect(!try state.armNativeLink(&unsup, 0, &child, CHILD_BODY, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Parent-retire direction: re-arm, then reset touching the PARENT (source).
    // The record is dropped WITHOUT writing through the (about-to-be-freed) slot,
    // and a subsequent child-retire must find no record — no write, no crash.
    try testing.expect(try state.armNativeLink(&parent, 2, &child, CHILD_BODY, .link_terminal));
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
    state.resetLinksTouching(&parent);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    // A parent-side reset leaves the slot value untouched (its array is freed anyway).
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
    // Later child-retire is a clean no-op now that the record is gone.
    state.resetLinksTouching(&child);
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
}

test "armNativeLink: P-C option (b) invariant — arm kind matches slot guard shape" {
    // 2.3c-0a: a numeric-for loop-done guard's slot is EXCLUSIVELY its linked-
    // materialized exit. `armNativeLink` enforces that the caller's declared `ArmKind`
    // matches the slot's guard shape: only `.loop_done_linked` may target a loop-done
    // slot, and `.ordinary_guard`/`.link_terminal` may target a non-loop-done one.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A proto whose code[0] is a `for_loop` and code[1] is not: a `guard_true` deopting
    // to pc 1 (== the instruction AFTER the for_loop) is a numeric-for loop-done guard,
    // while one deopting to pc 2 (after a non-for_loop) is an ordinary guard.
    const proto = Proto{ .code = &.{ Instr.op0(.for_loop), Instr.op0(.ret) }, .name = "t", .num_registers = 2 };

    // Production shape: exactly one slot per IR instr (no reserved trailing cell — the
    // loop-done ordinary deopt reaches `shared_exit` via `NativeResult.exit_target`, not
    // a slot). instr 0 = loop-done guard (exit_pc 1); instr 1 = ordinary guard (exit_pc 2).
    const pinstrs = try gpa.alloc(IrInstr, 2);
    defer gpa.free(pinstrs);
    pinstrs[0] = .{ .op = .guard_true, .aux = 1 };
    pinstrs[1] = .{ .op = .guard_true, .aux = 2 };
    const parent_slots = try gpa.alloc(usize, pinstrs.len);
    defer gpa.free(parent_slots);
    @memset(parent_slots, 0);
    var parent: Trace = .{
        .anchor = .{ .proto = &proto, .pc = 0 },
        .instrs = pinstrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = &.{}, .gpa = gpa } },
    };

    // Classifier: slot 0 IS a loop-done guard; slot 1 (ordinary guard) is not.
    try testing.expect(isLoopDoneGuardIndex(&parent, 0));
    try testing.expect(!isLoopDoneGuardIndex(&parent, 1));

    // The loop-done slot accepts only a `.loop_done_linked` arm.
    const BODY: usize = 0x1234;
    try testing.expect(try state.armNativeLink(&parent, 0, &child, BODY, .loop_done_linked));
    try testing.expectEqual(BODY, parent_slots[0]);

    // The non-loop-done slot accepts an ordinary-guard arm (and never a loop-done one).
    try testing.expect(try state.armNativeLink(&parent, 1, &child, BODY, .ordinary_guard));
    try testing.expectEqual(BODY, parent_slots[1]);

    // An index at/past `slots.len` (== instrs.len) is out of range for EVERY arm kind —
    // there is no reserved off-table cell to accidentally address (blocker-2 fix).
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, BODY, .ordinary_guard));
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, BODY, .link_terminal));
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, BODY, .loop_done_linked));

    // Reset so the leak-checked registry is empty at deinit.
    state.resetLinksTouching(&child);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
}

test "driveChain ordinary_header: chains at the anchor, not a guard's lane ordinal" {
    // Regression: ordinary-exit chaining walks the failed trace's ANCHOR (where the
    // registers are coherent), never a guard's `aux`. `guard_lane`/`guard_fits`
    // store a lane ordinal in `aux`, not a bytecode PC — a decoy trace anchored at
    // that ordinal (pc 2) must never be entered. Here A's guard_lane has aux=2; the
    // driver walks A's anchor (pc 10) instead, so the decoy at pc 2 is unreachable.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };

    // Trace A: the failing trace at pc 10. Its instr index 1 is a guard_lane with
    // aux=2 (a lane ordinal that happens to equal the decoy's anchor pc).
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (the table)
        .{ .op = .guard_lane, .a = 0, .aux = 2 }, // %1: lane ordinal 2 — NOT a PC
        .{ .op = .loop }, // %2
    };
    const consts_a = [_]Value{};
    const trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .anchor = .{ .proto = &proto, .pc = 10 },
        .instrs = @constCast(&instrs_a),
        .consts = @constCast(&consts_a),
        .entry_slots = &entry_a,
        .entry_guards = &.{},
    };

    // Decoy trace anchored at pc 2 — a plain counting loop that, if (wrongly)
    // entered, would commit iterations and mutate r0.
    var entry_b = [_]u16{ 0, 1 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .slot_load, .aux = 1 }, // %1: r1
        .{ .op = .konst, .aux = 0 }, // %2: 1
        .{ .op = .add, .a = 0, .b = 2 }, // %3: r0+1
        .{ .op = .lt, .a = 3, .b = 1 }, // %4: (r0+1) < r1
        .{ .op = .guard_true, .a = 4, .aux = 2 }, // %5
        .{ .op = .phi, .a = 0, .b = 3, .aux = 0, .ty = .int }, // %6: r0 ← r0+1
        .{ .op = .loop }, // %7
    };
    const consts_b = [_]Value{Value.int(1)};
    const trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .anchor = .{ .proto = &proto, .pc = 2 }, // collides with the lane ordinal
        .instrs = @constCast(&instrs_b),
        .consts = @constCast(&consts_b),
        .entry_slots = &entry_b,
        .entry_guards = &.{},
    };

    try state.cache.append(gpa, trace_a);
    try state.cache.append(gpa, trace_b);

    var regs = [_]Value{ Value.int(0), Value.int(4) };
    // Exclude A (the dispatcher's `visited` set). The driver walks A's anchor
    // (pc 10), finds no other sibling there, and must NOT reach the decoy at pc 2.
    var tr_regs = TestRegs{ .regs = &regs };
    const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false);
    tr_regs.commit(); // commit so a (buggy) decoy mutation would surface — keeps the test's teeth
    try testing.expect(chained == null);
    try testing.expectEqual(@as(i64, 0), regs[0].asInt()); // r0 untouched — no decoy ran

    state.cache.clearRetainingCapacity();
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "matchesFingerprint: empty fingerprint always matches" {
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.int(1), Value.float(3.14), Value.nil() };
    try testing.expect(t.matchesFingerprint(winRO(&regs)));
}

test "nextTraceExcluding: visits each anchor trace once, highest-hit first, then null" {
    // The dispatch walk's termination guarantee: with the visited set growing by
    // one each step, `nextTraceExcluding` returns hit-count-descending and never
    // repeats — so two equal-priority traces can't cycle `A→B→A→…`. We pin both
    // the ordering and the terminating `null`.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 0 };
    const loop_only = [_]IrInstr{.{ .op = .loop }};

    // Three traces at the same anchor (pc 10) with distinct hit counts, plus a
    // decoy at a different anchor (pc 99) that must never be returned.
    var traces: [4]*Trace = undefined;
    const specs = [_]struct { pc: u32, hits: u64 }{
        .{ .pc = 10, .hits = 5 },
        .{ .pc = 10, .hits = 1 },
        .{ .pc = 10, .hits = 3 },
        .{ .pc = 99, .hits = 100 },
    };
    for (&traces, specs) |*slot, spec| {
        const tr = try gpa.create(Trace);
        tr.* = .{
            .anchor = .{ .proto = &proto, .pc = spec.pc },
            .instrs = @constCast(&loop_only),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .hit_count = spec.hits,
        };
        slot.* = tr;
        try state.cache.append(gpa, tr);
    }
    defer {
        state.cache.clearRetainingCapacity();
        for (traces) |tr| gpa.destroy(tr);
    }

    var visited: [8]*Trace = undefined;
    var n: usize = 0;
    // Expected visit order at pc 10: hits 5, then 3, then 1; pc 99 never appears.
    const expect_hits = [_]u64{ 5, 3, 1 };
    for (expect_hits) |h| {
        const next = state.nextTraceExcluding(&proto, 10, visited[0..n]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(h, next.hit_count);
        visited[n] = next;
        n += 1;
    }
    // All three visited → the walk terminates.
    try testing.expect(state.nextTraceExcluding(&proto, 10, visited[0..n]) == null);
}

test "matchesFingerprint: matching types" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .int },
        .{ .slot = 1, .ty = .float },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    var regs = [_]Value{ Value.int(42), Value.float(3.14) };
    try testing.expect(t.matchesFingerprint(winRO(&regs)));
}

test "matchesFingerprint: mismatched int/float" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .int },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    // Register holds a float, but the trace expects int.
    var regs = [_]Value{Value.float(2.5)};
    try testing.expect(!t.matchesFingerprint(winRO(&regs)));
}

test "matchesFingerprint: guard_number accepts both int and float" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .number },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    try testing.expect(t.matchesFingerprint(winRO(@constCast(&[_]Value{Value.int(1)}))));
    try testing.expect(t.matchesFingerprint(winRO(@constCast(&[_]Value{Value.float(1.5)}))));
    try testing.expect(!t.matchesFingerprint(winRO(@constCast(&[_]Value{Value.nil()}))));
    try testing.expect(!t.matchesFingerprint(winRO(@constCast(&[_]Value{Value.boolean(true)}))));
}

test "matchesFingerprint: guard_table" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .table },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    try testing.expect(!t.matchesFingerprint(winRO(@constCast(&[_]Value{Value.int(1)}))));
    try testing.expect(!t.matchesFingerprint(winRO(@constCast(&[_]Value{Value.float(1.0)}))));
}
