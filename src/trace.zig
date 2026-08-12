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
const jitdbg = @import("jitdbg.zig");
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
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float => @intCast(ins.aux),
        else => null,
    };
}

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

// ---------------------------------------------------------------------------
// GuardProvenance (doc 17, §A4 / landing step A-i / 9-B)
//
// The guest-logical identity of a trace exit, stamped at emission and remapped
// through `tropt` to committed-instruction indices. The Part-A region-accounting
// classifier keys on this, NOT on IR position: recording is guest-value-dependent
// (`guardNum` picks int/float by observed value, `recBranch` picks true/false by
// taken path, the realized guard subset varies by heap shape, LICM/CSE shift
// positions) and `guardExitPc` cannot even supply a PC for array/table/grid
// guards. See the H-1c grounding for the closed role/operand vocabulary and why
// `occurrence` was dropped (the physical exit → provenance map is many-to-one).
// This is transient JIT-tiering metadata: a side table, never an `IrInstr` field
// (which would bump the wire schema, `traceser.zig`), never a `.snapshot` root.
// ---------------------------------------------------------------------------

/// One inlined call edge in a guard's inline-path prefix (H-1a). `path` is an
/// ordered *sequence* (recursion to `MAX_INLINE_DEPTH` is reachable), so the two
/// guards from `f(a); f(b)` inlined at distinct call sites get distinct identity.
pub const CallEdge = struct { caller_proto_id: u32, call_pc: u32 };

/// Which of a branch guard's two out-edges the recording committed to. A *static*
/// property of the recorded trace (not an observed value): `recBranch` emits
/// `guard_true`/`guard_false` by the taken path, and those are opposite CFG edges
/// of the region (nsieve's edge 1 = `skip.guard_false`, edge 4 = `cont.guard_true`
/// fail). `.neutral` for every non-branch guard. (Round-1 review, BLOCKER 1.)
pub const Polarity = enum(u8) { neutral, taken, fallthrough };

/// Closed structural vocabulary of guard *roles* (H-1c). NOT the IR op enum — the
/// op is a runtime *view* of the same site (`guard_int`/`guard_float` are both
/// `operand_type`; `guard_true`/`guard_false` are both `branch_cond`). A recording
/// realizes a runtime-selected *subset* of an opcode's static slot list, but each
/// realized role is stable across re-recording of the same-shaped trace.
pub const GuardRole = enum(u8) {
    operand_type, // arith/compare/eq/bitwise/neg/bnot operand; numeric-for control reg
    branch_cond, // jmp_if_true/false condition
    limit_int, // for_loop/for_prep float-limit → int specialization (int_of_float)
    loop_done, // for_loop / for_prep-first-iter continuation test (guard_true)
    container_type, // get/set_index container tag (guard_table)
    container_lane, // array element-lane (guard_lane)
    key_type, // array/grid index type (guard_int on the key)
    bounds, // array/grid bounds check (guard_bounds)
    present, // array/grid presence (guard_present / guard_gpresent)
    element_type, // .value-lane loaded element (fused: guard_table on the load)
    append_precond, // array append precondition (guard_append)
    value_fits, // narrow-lane store fits (guard_fits)
    hash_struct, // const-key hash table structure (guard_hash)
    value_type, // hash store value / hload'd field type
    field_type, // fused native hload producer-exit
    grid_shape, // grid table shape (guard_grid)
    grid_stride, // grid stride (guard_stride)
    row_type, // grid row index type
    col_type, // grid column index type
    row_bounds, // grid row in [1,rows] (guard_bounds on garow)
    col_bounds, // grid column resolution / in [1,stride] (guard_gcol)
    callee_identity, // closure identity (call / get_upval / get_global — guard_func)
    callee_pure, // pure-builtin identity (guard_pure)
};

/// Static register designator for the guarded operand (H-1c). Covers `a`/`b`/`c`,
/// the derived numeric-for control offsets `a+1`/`a+2`, register-valued `aux`
/// (grid col/value), the loaded value of a fused producer-exit, and `none` for
/// guards with no register operand (bounds/present/loop_done). Re-recording-stable:
/// it tracks the *source* register, not the normalized IR operand (the `recCompare`
/// gt/ge swap happens after emission, so `operand` still names the source reg).
pub const OperandDesig = enum(u8) { none, a, b, c, a1, a2, aux, loaded };

/// The guest-static identity of a materialized guard exit (H-1c: `occurrence`
/// dropped — unrolled physical copies deliberately share one tag, which is correct
/// for the consumer: every copy is the same guest check, exits to the same guest PC).
/// `path[0..inline_depth]` is the inline call-edge prefix; the leaf is
/// `{source_proto_id, source_pc}` (`source_pc = cur_pc − 1`).
pub const GuardProvenance = struct {
    path: [MAX_INLINE_DEPTH]CallEdge = undefined,
    inline_depth: u8 = 0,
    source_proto_id: u32,
    source_pc: u32,
    role: GuardRole,
    operand: OperandDesig,
    polarity: Polarity = .neutral,
};

/// The inline-path leaf of a `.link` terminal (edge 2). Same shape as a guard's
/// path prefix + leaf, minus role/operand/polarity — a `.link` is not a guard.
pub const LinkTerminalProvenance = struct {
    path: [MAX_INLINE_DEPTH]CallEdge = undefined,
    inline_depth: u8 = 0,
    source_proto_id: u32,
    source_pc: u32,
};

/// Provenance of a trace exit. Most exits are guards; edge 2 exits through a
/// `.link` terminal (not a guard — synthesized at commit from `recForPrepLink`,
/// `trace.zig` §3.3, round-6/7), so that variant carries only the path + leaf.
pub const ExitProvenance = union(enum) {
    guard: GuardProvenance,
    link_terminal: LinkTerminalProvenance,
};

/// A committed-trace exit-provenance entry: the *committed* instruction index the
/// exit is at, plus its provenance. `Trace.exit_prov` is a slice of these sorted
/// by `index` (alloc-once at commit; guards are a minority of instrs), queried via
/// `Trace.provAt`. Built by remapping the recorder's dense lockstep table through
/// `tropt`'s compaction map (A-i.1).
pub const ExitProvEntry = struct { index: u32, prov: ExitProvenance };

fn exitProvEntryLess(_: void, a: ExitProvEntry, b: ExitProvEntry) bool {
    return a.index < b.index;
}

/// Physical classification key for the region-accounting layer (doc 17 §A3.3): a
/// concrete trace exit = `{Trace.id, exit_instr}`. `accountRegionProfit` receives
/// an `?ExitKey` — real guard/`.link_terminal` receipts carry the key; synthetic
/// scalar-burst / prologue-fail events with no real instruction index pass `null`.
/// Inert in A-ii (the profit half is a no-op; nothing constructs a non-null key
/// until A-iv threads it per-site — §A8-ii).
pub const ExitKey = struct { trace_id: u32, exit_instr: u32 };

/// A recorded guest program-point `{proto_id, source_pc}` (doc 17 §A3.5 / §A8-ii,
/// A-ii.3). `Trace.rec_path` is the ordered sequence captured one-per-`recordInstr`;
/// A-ii.4 unions member traces' paths into each `RegionDef`'s membership set. Keyed
/// by `proto.id` (guest-logical), `source_pc = recording pc − 1` (post-increment,
/// matching `guardSourcePc` / the A-i `cur_pc −| 1` discipline).
pub const ProgramPoint = struct { proto_id: u32, source_pc: u32 };

/// The persistent, guest-logical identity of a structural trace-graph edge (doc 17
/// §A3.3 / §A8-ii, A-ii.2): a source anchor `{proto_id, pc}`, the exit's
/// `ExitProvenance` (A-i), and the successor anchor `{proto_id, pc}`. Keyed by
/// `proto.id` (guest-logical), never a `*Proto`, so a re-recorded logically-identical
/// edge (new `Trace.id`) computes the same id. Anchors are `{proto, pc}` — a bare
/// `succ_pc` would alias successors at the same PC in different protos.
///
/// `order`/`eql`/`hash` are **field-wise** honoring `inline_depth` (only
/// `path[0..inline_depth]` is live): `ExitProvenance` is a padded tagged union with a
/// fixed-size `path` array + an inactive arm, so `std.mem.asBytes`/full-union `eql`
/// would compare garbage (round-11/12 review).
pub const StructuralEdgeId = struct {
    anchor_proto_id: u32,
    anchor_pc: u32,
    exit: ExitProvenance,
    succ_anchor_proto_id: u32,
    succ_anchor_pc: u32,

    pub fn order(a: StructuralEdgeId, b: StructuralEdgeId) std.math.Order {
        switch (std.math.order(a.anchor_proto_id, b.anchor_proto_id)) {
            .eq => {},
            else => |o| return o,
        }
        switch (std.math.order(a.anchor_pc, b.anchor_pc)) {
            .eq => {},
            else => |o| return o,
        }
        switch (exitOrder(a.exit, b.exit)) {
            .eq => {},
            else => |o| return o,
        }
        switch (std.math.order(a.succ_anchor_proto_id, b.succ_anchor_proto_id)) {
            .eq => {},
            else => |o| return o,
        }
        return std.math.order(a.succ_anchor_pc, b.succ_anchor_pc);
    }

    pub fn eql(a: StructuralEdgeId, b: StructuralEdgeId) bool {
        return a.order(b) == .eq;
    }

    /// Strict-less-than for `std.sort` (context-free comparator form).
    pub fn lessThan(_: void, a: StructuralEdgeId, b: StructuralEdgeId) bool {
        return a.order(b) == .lt;
    }

    pub fn hash(e: StructuralEdgeId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&e.anchor_proto_id));
        h.update(std.mem.asBytes(&e.anchor_pc));
        hashExit(&h, e.exit);
        h.update(std.mem.asBytes(&e.succ_anchor_proto_id));
        h.update(std.mem.asBytes(&e.succ_anchor_pc));
        return h.final();
    }
};

fn u32Order(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Field-wise canonical order over the live inline path prefix (both depths already
/// proven equal by the caller before it reaches here).
fn pathOrder(a: []const CallEdge, b: []const CallEdge) std.math.Order {
    for (a, b) |ae, be| {
        switch (u32Order(ae.caller_proto_id, be.caller_proto_id)) {
            .eq => {},
            else => |o| return o,
        }
        switch (u32Order(ae.call_pc, be.call_pc)) {
            .eq => {},
            else => |o| return o,
        }
    }
    return .eq;
}

fn exitOrder(a: ExitProvenance, b: ExitProvenance) std.math.Order {
    const at: u8 = @intFromEnum(std.meta.activeTag(a));
    const bt: u8 = @intFromEnum(std.meta.activeTag(b));
    switch (std.math.order(at, bt)) {
        .eq => {},
        else => |o| return o,
    }
    switch (a) {
        .guard => |ag| {
            const bg = b.guard;
            switch (u32Order(ag.source_proto_id, bg.source_proto_id)) {
                .eq => {},
                else => |o| return o,
            }
            switch (u32Order(ag.source_pc, bg.source_pc)) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(@intFromEnum(ag.role), @intFromEnum(bg.role))) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(@intFromEnum(ag.operand), @intFromEnum(bg.operand))) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(@intFromEnum(ag.polarity), @intFromEnum(bg.polarity))) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(ag.inline_depth, bg.inline_depth)) {
                .eq => {},
                else => |o| return o,
            }
            return pathOrder(ag.path[0..ag.inline_depth], bg.path[0..bg.inline_depth]);
        },
        .link_terminal => |al| {
            const bl = b.link_terminal;
            switch (u32Order(al.source_proto_id, bl.source_proto_id)) {
                .eq => {},
                else => |o| return o,
            }
            switch (u32Order(al.source_pc, bl.source_pc)) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(al.inline_depth, bl.inline_depth)) {
                .eq => {},
                else => |o| return o,
            }
            return pathOrder(al.path[0..al.inline_depth], bl.path[0..bl.inline_depth]);
        },
    }
}

fn hashExit(h: *std.hash.Wyhash, exit: ExitProvenance) void {
    const tag: u8 = @intFromEnum(std.meta.activeTag(exit));
    h.update(std.mem.asBytes(&tag));
    switch (exit) {
        .guard => |g| {
            h.update(std.mem.asBytes(&g.source_proto_id));
            h.update(std.mem.asBytes(&g.source_pc));
            const role: u8 = @intFromEnum(g.role);
            const operand: u8 = @intFromEnum(g.operand);
            const polarity: u8 = @intFromEnum(g.polarity);
            h.update(std.mem.asBytes(&role));
            h.update(std.mem.asBytes(&operand));
            h.update(std.mem.asBytes(&polarity));
            h.update(std.mem.asBytes(&g.inline_depth));
            for (g.path[0..g.inline_depth]) |ce| {
                h.update(std.mem.asBytes(&ce.caller_proto_id));
                h.update(std.mem.asBytes(&ce.call_pc));
            }
        },
        .link_terminal => |l| {
            h.update(std.mem.asBytes(&l.source_proto_id));
            h.update(std.mem.asBytes(&l.source_pc));
            h.update(std.mem.asBytes(&l.inline_depth));
            for (l.path[0..l.inline_depth]) |ce| {
                h.update(std.mem.asBytes(&ce.caller_proto_id));
                h.update(std.mem.asBytes(&ce.call_pc));
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Region model (doc 17 §A3.3 / §A3.5 / §A8-ii, A-ii.4)
//
// A *region* is a strongly-connected component of the structural trace graph
// (`StructuralEdgeId` edges over `{proto_id, pc}` anchor nodes) that contains a
// cycle — the guest-logical unit the exit-branch-patching gate reasons about. A-ii
// made discovery/classification queryable; A-iv consumes it only into transient
// `region_profit`. No selection/gating path reads that accumulator yet.
// ---------------------------------------------------------------------------

/// Opaque interned handle for a region (doc 17 §A3.3): assigned sequentially by the
/// intern map, NEVER a bare hash. Interned on the region's canonical sorted INTERNAL
/// `StructuralEdgeId` set, so a re-recorded logically-identical region (new
/// `Trace.id`s) re-interns to the SAME id.
pub const RegionId = enum(u64) { _ };

/// Per-activation identity and accounting payload for doc 17 A-iv/A-vii. The map
/// is transient tiering state: it is never serialized. As of A-vii-c the window
/// flushes drive the penalty/gate state machine (keyed by the region OWNER
/// anchor); the accumulator itself is still never a selection input.
pub const RegionKey = struct {
    region_id: RegionId,
    activation: u64,
};

pub const RegionAccum = struct {
    outer_traversals: u64 = 0,
    window_base: u64 = 0,
    root_frame_depth: u32,
    root_call_seq: u64,
    /// A-vii qualification latch (doc 17 §A8-iii seam): true once this activation
    /// has committed at least one complete `N = min_useful` window. Structural
    /// eligibility (`RegionDef.armable`) is not profitability — A-vii-d's arm site
    /// requires BOTH. Activation-local: a fresh `openRegion` starts false.
    useful_window_seen: bool = false,
};

/// Destination knowledge carried by a concrete trace receipt. A selected trace
/// is classified through `dest_entry_regions`; `.deferred` deliberately retains
/// the source accumulator until a later receipt/program-point resolves departure.
pub const RegionDestination = union(enum) {
    deferred,
    known_trace: u32,
    terminal_outside,
};

const RegionContext = struct {
    depth: u32,
    call_seq: u64,
};

fn regionIdLess(_: void, a: RegionId, b: RegionId) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

/// Minimal region shape descriptor (doc 17 §A8-ii). A-vii reads `kind` to pick the
/// arming strategy; `member_count` is the anchor-node count of the cycle.
pub const RegionClassifier = struct {
    kind: enum { self_loop, cross_trace_cycle },
    member_count: u32,
};

/// Discovery-owned arm-time proof for one bridge-capable internal region edge.
/// The descriptor and both slot sets are canonical-sorted and owned by RegionDef.
pub const RegionBridgeDef = struct {
    edge: StructuralEdgeId,
    successor: AnchorKey,
    required_slots: []u16,
    invariant_slots: []u16,
};

/// A discovered region definition (doc 17 §A3.1 / §A3.5). Proto/VM-lifetime: kept in
/// `region_defs`, NEVER retirement-cleaned, cleared only on `clearCache`. Owns its
/// `members`/`member_points`/`bridges` slices.
pub const RegionDef = struct {
    /// The region's INTERNAL edges only (both endpoints in the SCC), canonical-sorted
    /// and deduped — the identity basis interned to the `RegionId`. Owned.
    members: []StructuralEdgeId,
    /// Membership program-point SET (doc 17 §A3.5): the union of member traces'
    /// recorded `{proto_id, source_pc}` paths (A-ii.3) plus each internal edge's
    /// validated handoff endpoints, sorted + deduped. Owned. A-iv's tier-0 region
    /// observer keys on this; A-ii uses it for the def-consistency rebind check.
    member_points: []ProgramPoint,
    /// Gate/penalty blast-radius key = the region's loop-root `{proto, root_pc}`
    /// (doc 17 §A2.6). Borrows a `*Proto` that outlives the region (proto lifetime ≥
    /// trace lifetime; both bounded by the `clearCache` epoch that frees `region_defs`).
    owner: AnchorKey,
    classifier: RegionClassifier,
    /// Bridge-capable internal edges and their whole-cycle liveness proofs. Owned;
    /// rebuilt on every successful discovery pass, including a same-id re-record.
    bridges: []RegionBridgeDef = &.{},
    /// Live arming eligibility, RECOMPUTED at every discovery rebind (A-vii-d.0):
    /// `armable = owner-unique ∧ membership-complete ∧ !tombstoned`. Recomputation
    /// is what makes armability reachable at all — a cycle is necessarily minted
    /// BEFORE its external-entry side trace records (the cycle triggers minting;
    /// the entry arrives later by hotguard), so first sight is always
    /// owner-not-unique and a frozen first-sight bit could never rise. Only
    /// `tombstoned` is sticky. The classification-index build excludes
    /// `armable == false` regions.
    armable: bool,
    /// The fail-closed sticky bit (split out of `armable` by A-vii-d.0): set by the
    /// runtime tombstone (`invalidateRegion` — validation failure, classification
    /// ambiguity, gate) AND by a def-inconsistent or truncated rebind (§A3.5
    /// finding 3). Never cleared for the lifetime of the `RegionId`; while set,
    /// recomputation can never re-arm the region. Distinguishes "the graph was
    /// incomplete when we looked" (recoverable) from "this region misbehaved"
    /// (permanent).
    tombstoned: bool = false,
};

fn freeRegionBridges(gpa: std.mem.Allocator, bridges: []RegionBridgeDef) void {
    for (bridges) |b| {
        gpa.free(b.required_slots);
        gpa.free(b.invariant_slots);
    }
    gpa.free(bridges);
}

fn cloneRegionBridges(gpa: std.mem.Allocator, src: []const RegionBridgeDef) ![]RegionBridgeDef {
    const out = try gpa.alloc(RegionBridgeDef, src.len);
    errdefer gpa.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |b| {
        gpa.free(b.required_slots);
        gpa.free(b.invariant_slots);
    };
    for (src, out) |s, *d| {
        const required = try gpa.dupe(u16, s.required_slots);
        const invariants = gpa.dupe(u16, s.invariant_slots) catch |err| {
            gpa.free(required);
            return err;
        };
        d.* = .{
            .edge = s.edge,
            .successor = s.successor,
            .required_slots = required,
            .invariant_slots = invariants,
        };
        initialized += 1;
    }
    return out;
}

/// Interns a canonical-sorted `[]StructuralEdgeId` SET → a stable `RegionId`
/// (doc 17 §A3.3 / §A8-ii, A-ii.4). Hand-written (not `AutoHashMap`) because the key
/// is a variable-length slice compared by ELEMENT-WISE `StructuralEdgeId.eql` over the
/// sorted set — `std.mem.eql` would compare the padded tagged-union bytes. The 64-bit
/// fold of the per-edge hashes only selects the bucket; every hit is confirmed by set
/// equality, and a genuine hash collision (equal fold, unequal set) mints a DISTINCT
/// id. Owns a copy of each interned sorted slice. Buckets are `foldedHash → head entry
/// index`, chained intrusively through `Entry.next`, so a `internAssumeCapacity` after
/// `reserve(n)` is infallible (the transactional-publish requirement, §A8-ii).
pub const RegionInternMap = struct {
    pub const empty: RegionInternMap = .{};

    const Entry = struct { edges: []StructuralEdgeId, id: RegionId, next: i64 = -1 };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    buckets: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn foldHash(edges: []const StructuralEdgeId) u64 {
        var h = std.hash.Wyhash.init(0);
        for (edges) |e| {
            const eh = e.hash();
            h.update(std.mem.asBytes(&eh));
        }
        return h.final();
    }

    fn setsEqual(a: []const StructuralEdgeId, b: []const StructuralEdgeId) bool {
        if (a.len != b.len) return false;
        for (a, b) |ae, be| {
            if (!ae.eql(be)) return false;
        }
        return true;
    }

    /// Read-only lookup: the interned id for this sorted set, or null if absent. Used
    /// by discovery to distinguish rebind (existing id) from first-sight WITHOUT
    /// mutating (mutation is deferred to the infallible publish phase).
    fn lookup(self: *const RegionInternMap, edges: []const StructuralEdgeId) ?RegionId {
        const h = foldHash(edges);
        var idx: i64 = if (self.buckets.get(h)) |x| @intCast(x) else return null;
        while (idx >= 0) {
            const e = self.entries.items[@intCast(idx)];
            if (setsEqual(e.edges, edges)) return e.id;
            idx = e.next;
        }
        return null;
    }

    /// Reserve capacity for `n` new interns so the matching `internAssumeCapacity`
    /// calls are infallible (transactional publish). `n` is an upper bound —
    /// intra-pass hash collisions reuse a bucket slot.
    fn reserve(self: *RegionInternMap, gpa: std.mem.Allocator, n: usize) !void {
        try self.entries.ensureUnusedCapacity(gpa, n);
        try self.buckets.ensureUnusedCapacity(gpa, @intCast(n));
    }

    /// Insert a NEW region (caller has confirmed via `lookup` that it is absent) with
    /// a caller-owned duped edge slice + assigned id. Infallible after a covering
    /// `reserve`. Takes ownership of `owned_edges`.
    fn internAssumeCapacity(self: *RegionInternMap, owned_edges: []StructuralEdgeId, id: RegionId) void {
        const h = foldHash(owned_edges);
        const new_idx: u32 = @intCast(self.entries.items.len);
        const head: i64 = if (self.buckets.get(h)) |x| @intCast(x) else -1;
        self.entries.appendAssumeCapacity(.{ .edges = owned_edges, .id = id, .next = head });
        self.buckets.putAssumeCapacity(h, new_idx);
    }

    fn clear(self: *RegionInternMap, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.edges);
        self.entries.clearRetainingCapacity();
        self.buckets.clearRetainingCapacity();
    }

    fn deinit(self: *RegionInternMap, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.edges);
        self.entries.deinit(gpa);
        self.buckets.deinit(gpa);
    }
};

fn programPointLess(_: void, a: ProgramPoint, b: ProgramPoint) bool {
    if (a.proto_id != b.proto_id) return a.proto_id < b.proto_id;
    return a.source_pc < b.source_pc;
}

fn programPointsEqual(a: []const ProgramPoint, b: []const ProgramPoint) bool {
    if (a.len != b.len) return false;
    for (a, b) |ae, be| {
        if (ae.proto_id != be.proto_id or ae.source_pc != be.source_pc) return false;
    }
    return true;
}

fn appendUniqueSlot(list: *std.ArrayListUnmanaged(u16), gpa: std.mem.Allocator, slot: u16) !bool {
    for (list.items) |s| if (s == slot) return false;
    try list.append(gpa, slot);
    return true;
}

/// A physical classification index `K → sorted []RegionId` (doc 17 §A3.1). Wholesale-
/// rebuilt per discovery pass; owns each value slice. `freeRegionSetMap` releases the
/// per-entry slices + the map backing.
fn freeRegionSetMap(comptime K: type, map: *std.AutoHashMapUnmanaged(K, []RegionId), gpa: std.mem.Allocator) void {
    var it = map.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    map.deinit(gpa);
}

/// Scratch accumulator for a physical classification index during discovery: appends
/// `RegionId`s per key (deduped), then `finalize`s into an owned-slice map.
fn RegionSetBuilder(comptime K: type) type {
    return struct {
        const Self = @This();
        m: std.AutoHashMapUnmanaged(K, std.ArrayListUnmanaged(RegionId)) = .empty,

        fn add(self: *Self, gpa: std.mem.Allocator, key: K, id: RegionId) !void {
            const gop = try self.m.getOrPut(gpa, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |x| {
                if (x == id) return; // dedup
            }
            try gop.value_ptr.append(gpa, id);
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.m.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            self.m.deinit(gpa);
        }

        /// Materialize into an owned-slice map with each id list sorted. Fallible; the
        /// caller's `errdefer freeRegionSetMap` covers a mid-materialize OOM.
        fn finalize(self: *Self, gpa: std.mem.Allocator) !std.AutoHashMapUnmanaged(K, []RegionId) {
            var out: std.AutoHashMapUnmanaged(K, []RegionId) = .empty;
            errdefer freeRegionSetMap(K, &out, gpa);
            try out.ensureUnusedCapacity(gpa, self.m.count());
            var it = self.m.iterator();
            while (it.next()) |e| {
                std.mem.sort(RegionId, e.value_ptr.items, {}, regionIdLess);
                const owned = try gpa.dupe(RegionId, e.value_ptr.items);
                out.putAssumeCapacity(e.key_ptr.*, owned);
            }
            return out;
        }
    };
}

/// Remap the recorder's dense, emission-indexed exit-provenance table (A-i.1) into
/// the committed trace's compact, sorted `[]ExitProvEntry`, keyed by committed
/// instruction index. `old_to_new` is `tropt`'s compaction map (emission index →
/// committed index, `null` for a dropped instr); pass `null` for the identity map
/// (the `dupe` path — link + unoptimized traces preserve indices 1:1). Only
/// non-`null` provenance whose instruction survived compaction is carried over
/// (the many-to-one dedup already happened at stamp time).
///
/// `link_terminal` (A-i.4) carries the `.link` terminal's provenance and its
/// committed index. The `.link`/`.loop` terminal is appended directly to `instrs`
/// at commit — it never went through `emit`, so it has NO lockstep `rec_exit_prov`
/// slot; it is injected here as one extra entry. `null` for every non-link trace
/// (a `.loop` terminal is a back-edge, not an exit).
///
/// Returns a static empty slice when there is nothing to carry (no alloc). Caller
/// owns the result.
pub fn buildExitProv(
    gpa: std.mem.Allocator,
    rec_exit_prov: []const ?ExitProvenance,
    old_to_new: ?[]const ?Ref,
    link_terminal: ?ExitProvEntry,
) ![]ExitProvEntry {
    if (old_to_new) |m| std.debug.assert(m.len >= rec_exit_prov.len);
    var count: usize = if (link_terminal != null) 1 else 0;
    for (rec_exit_prov, 0..) |p, i| {
        if (p == null) continue;
        const survived = if (old_to_new) |m| m[i] != null else true;
        if (survived) count += 1;
    }
    if (count == 0) return &.{};
    const out = try gpa.alloc(ExitProvEntry, count);
    errdefer gpa.free(out);
    var k: usize = 0;
    for (rec_exit_prov, 0..) |p, i| {
        const prov = p orelse continue;
        const committed: u32 = if (old_to_new) |m| (m[i] orelse continue) else @intCast(i);
        out[k] = .{ .index = committed, .prov = prov };
        k += 1;
    }
    if (link_terminal) |lt| {
        out[k] = lt;
        k += 1;
    }
    std.debug.assert(k == count);
    // Committed indices are already ascending for guards/fused producers (neither is
    // hoisted into the preheader, so compaction preserves their relative order), but
    // sort defensively so `Trace.provAt`'s binary search is correct regardless of any
    // future LICM change.
    std.mem.sort(ExitProvEntry, out, {}, exitProvEntryLess);
    return out;
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
    return t.anchor.proto.code[guardSourcePc(g).?].op == .for_loop;
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
    /// Part A edge-4 bridge: a composite ordinary guard whose stub commits the
    /// dominance-scoped phi snapshot before entering the child's ordinary entry.
    region_bridge,
};

/// A-v emitted bridge-capable stubs without publishing an edge into any of them.
/// A-vii-d flipped this to true once the full chain landed: the replay grammar
/// (A-vii-a), the arm-time S⊆E validator (A-vii-b), the consumption-keyed profit
/// gate (A-vii-c/c.1/c.2), reachable armability (A-vii-d.0), and the
/// `tryArmRegionBridge` arm site in `driveChain`. Flipping it back to false
/// restores the pre-A-vii world: stubs still emit, but every `.region_bridge`
/// arm attempt release-panics in `armNativeLink` (deliberate tripwire).
const region_bridge_arming_enabled = true;

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

    /// Exit provenance (doc 17, A-i / 9-B): the guest-logical identity of each
    /// side-exit / `.link` terminal, keyed by *committed* instruction index, sorted
    /// by index (alloc-once at commit — guards are a minority of instrs). Empty for
    /// hand-built test traces and until A-i.3 stamps sites. Runtime-only — transient
    /// JIT-tiering metadata, never serialized, never a `.snapshot` root. Read by the
    /// Part-A region classifier via `provAt`; freed in `destroy`.
    exit_prov: []ExitProvEntry = &.{},
    /// Whether `exit_prov` is the COMPLETE exit table (doc 17 §A8-ii, A-ii.4 fail-soft).
    /// `false` iff the commit-time `buildExitProv` OOM'd and this trace was committed with
    /// an EMPTY exit table rather than aborting the commit (same fail-soft rationale as
    /// `rec_path_complete` — a `commit` error gates the anchor and perturbs tiering, and
    /// `exit_prov` is inert region metadata read by nothing on the selection path). A
    /// truncated table means this trace contributes NO structural edges, so the whole edge
    /// graph is missing edges; region discovery then arms/mints NOTHING that pass (a
    /// dropped *boundary* edge could otherwise shrink an owner's competing-entry count and
    /// spuriously flip a region armable). Default `true`. Runtime-only — not serialized.
    exit_prov_complete: bool = true,
    /// Ordered recorded guest program-points (doc 17 §A8-ii, A-ii.3), dup'd from the
    /// recorder at commit; the membership-set basis A-ii.4 unions per region. Empty
    /// when membership was *unavailable* (a recorder-path OOM flipped `rec_path_ok`)
    /// or for hand-built test traces. Owned; freed in `destroy`. Not serialized.
    rec_path: []ProgramPoint = &.{},
    /// Whether `rec_path` is the COMPLETE recorded membership (doc 17 §A8-ii, A-ii.4
    /// fail-soft — round-14 review finding 3). `false` iff a recorder-path OOM
    /// (`rec_path_ok` flipped) OR the commit-time `rec_path` dup OOM'd truncated it, so
    /// the two "empty" cases (unavailable vs legitimately empty) are distinguishable.
    /// Region discovery fails any region containing an incomplete member CLOSED
    /// (`armable = false`) rather than minting it on truncated membership. Default
    /// `true` (a legitimately-empty path — incl. hand-built test traces — is complete).
    /// Runtime-only — not serialized.
    rec_path_complete: bool = true,

    /// The exit provenance at committed instruction index `idx`, or `null` if that
    /// instruction is not a tracked exit. Binary search over the sorted table.
    pub fn provAt(self: *const Trace, idx: u32) ?ExitProvenance {
        var lo: usize = 0;
        var hi: usize = self.exit_prov.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.exit_prov[mid];
            if (e.index == idx) return e.prov;
            if (e.index < idx) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Free a heap-allocated trace and its arrays.
    pub fn destroy(self: *Trace, gpa: std.mem.Allocator) void {
        self.native.deinit();
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        if (self.exit_prov.len != 0) gpa.free(self.exit_prov);
        if (self.rec_path.len != 0) gpa.free(self.rec_path); // A-ii.3
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
    /// The recording tried to inline a call into a **dynamic** proto (a
    /// `load`/`loadfile`/`dofile` chunk, `Proto.dynamic`). Never traced: its
    /// closure isn't retained durably, so a trace over it could sole-root its
    /// proto-literal konsts and diverge string-intern ids between `.off` and record
    /// modes (docs/design/17 H-2 part 1). The static caller keeps running tier-0.
    dynamic_proto,
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
    /// Runtime gate for the compile-gated live JIT debug log (`src/jitdbg.zig`).
    /// Only meaningful in a `-Djit-debug=true` build (otherwise every jitdbg call
    /// site is compiled out and this bool is inert). The CLI `--jit-debug` flag
    /// sets it; tests set it on exactly the VM under investigation. Diagnostic
    /// only — stderr, never program output.
    debug_log: bool = false,
    /// Runtime gate for JIT execution-coverage accounting (native-vs-tier-0 loop
    /// iterations + TSC time, per anchor). Off by default; when off the added cost is
    /// a handful of predictable, well-predicted branches (at the back-edge, trace-exec
    /// entry/exit, and each `onSideExit`) that skip all the counting — no map op,
    /// counter, or `rdtsc` runs. Set by the CLI `--jit-coverage`/`--jit-stats` flags
    /// (NOT `--time`, which stays uninstrumented so its timing is clean) and forced on
    /// by the WASM entry (the viz always instruments). When on, each interpreted
    /// back-edge is classified covered/uncovered via the per-anchor `has_trace` flag
    /// (O(1), no `findTrace` scan) and charged its cycles, and trace runs add their
    /// committed iteration count + bracketed cycles. Diagnostic only — never affects
    /// tiering, hot-counts, gating, snapshots, replay, or output; the report and the
    /// nondeterministic TSC values go only to stderr.
    coverage: bool = false,
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
    // Mix in u64 explicitly: the golden-ratio constant is 64-bit, so a `usize`
    // accumulator overflows on a 32-bit target (wasm32). On a 64-bit target this is
    // byte-identical to the old `usize` math (usize == u64); the final mask keeps
    // the result within `HOTCOUNT_SIZE`, so the `@intCast` back to usize is safe.
    var h: u64 = @intFromPtr(proto);
    h ^= @as(u64, pc) *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    return @intCast(h & (HOTCOUNT_SIZE - 1));
}

/// One armed native link (P-E, doc 17 Increment 2.3): `parent`'s frameless exit slot
/// at `slot_index` currently jumps straight into `child`'s body. Keyed by trace
/// identity (not a raw slot address) so lifetime resets stay valid no matter which
/// end retires first — the slot address is re-derived from the live `parent` at reset.
pub const NativeLink = struct {
    parent: *Trace,
    slot_index: u32,
    child: *Trace,
    /// A-vii-d.1: the arm kind is part of the record so replay can validate a
    /// `.region_bridge` row against the exact provenance that armed it (review
    /// blocker 3: never a global historical `region_defs` scan).
    kind: ArmKind,
    /// Set only for `.region_bridge` arms: the exact live region the arm was
    /// proven against. Every discovery rebuild disarms region-bridge links whose
    /// region is no longer live-armable (fail-closed on topology transitions).
    region_id: ?RegionId = null,
};

/// Per-anchor JIT execution-coverage tally (`TraceState.coverage` value). `traced`
/// = loop iterations committed by trace runs (tier-1b native, or tier-1a IR-interp)
/// anchored here; `interp` = interpreted (tier-0) back-edges taken at this anchor.
/// `has_trace` flips true once a trace is committed at this anchor (at commit, and
/// defensively on any trace run), so `noteInterpIter` can classify each interpreted
/// back-edge covered-vs-uncovered in O(1) — a single map probe it already does —
/// with no `findTrace` cache scan on the hot path. Accumulated only when
/// `config.coverage`.
///
/// `*_cycles` are the TSC (`readCycles`) time attribution, so the report can weigh
/// iterations by cost — a traced iteration is ~10-20× cheaper than a tier-0 one, so
/// iteration% badly overstates JIT effectiveness. `traced_cycles` = cycles spent
/// running trace code committed *at this anchor*, attributed per hop: every trace
/// run (direct dispatch or a `driveChain` hop) charges the span since the previous
/// hop boundary (`last_hop_tsc`) to *its own* anchor in `onSideExit`, so a chain hop
/// into an inner/continuation trace bills the inner anchor — cycles now mirror
/// iterations per anchor, not lumped onto the entry anchor. The one residual: a
/// *fused* native run that executes several hops in one mcode burst replays them
/// through `onSideExit` back-to-back after the burst, so the whole burst's cycles
/// land on the first replayed hop's anchor (genuinely unsplittable without per-hop
/// TSC reads inside mcode). `interp_cycles` = cycles of the tier-0 body iterations charged at this
/// anchor's back-edge — *self time* for an innermost loop, but it leaks the
/// outer-body-head into the innermost loop at a nesting boundary (one small span per
/// outer iteration). Both are approximate per anchor; only the aggregate split
/// (`TraceState.cycles_*` vs `run_cycles`) is exact. Zero on non-x86_64 (no TSC).
pub const AnchorCoverage = struct {
    traced: u64 = 0,
    interp: u64 = 0,
    traced_cycles: u64 = 0,
    interp_cycles: u64 = 0,
    has_trace: bool = false,
};

/// Read the CPU cycle counter (x86_64 `rdtsc`) for coverage time attribution.
/// Non-serializing — fine for coarse ratios over millions of samples, and we avoid
/// `rdtscp`/`cpuid` fences (too slow for a per-back-edge hook). Returns 0 on
/// non-x86_64 (e.g. the wasm VM), which makes every cycle delta 0 → the report shows
/// n/a time rather than garbage. Diagnostic only: the value is gated on
/// `config.coverage`, lives solely in the stderr/report path, and never feeds
/// tiering, hot-counts, snapshots, replay, or program output — so its inherent
/// nondeterminism can't leak into anything observable (docs/design/02).
pub inline fn readCycles() u64 {
    if (@import("builtin").target.cpu.arch != .x86_64) return 0;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// Cycle delta `now - prev`, clamped to 0 when `now < prev`. `rdtsc` is not
/// serializing and, across a core/vCPU migration on a non-invariant-TSC box, a
/// later read can come back *smaller* than an earlier one. A raw wrapping subtract
/// would then yield a delta near `maxInt(u64)` and, through the saturating adds,
/// permanently pin the cycle totals near the maximum — corrupting the whole report.
/// Dropping the odd backward span to 0 keeps the diagnostic robust (at worst a
/// single mis-measured span is lost, not the entire run).
pub inline fn cycleDelta(now: u64, prev: u64) u64 {
    return if (now > prev) now - prev else 0;
}

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
    /// A-vii-d.1: at most one bridge-arm request recorded by `replayLedger` when
    /// it walks a terminal composite `.deopt` row, drained by the ledger DRIVERS
    /// via `drainPendingBridgeArm` after the replay returns (never mid-walk —
    /// review blocker 5: a mid-ledger `invalidateRegion → disarmAllLinks` could
    /// erase the armed provenance later `.region_bridge` rows validate against).
    /// Cleared at every `replayLedger` entry so a stale request can never leak
    /// across ledgers.
    pending_bridge_arm: ?ExitKey = null,
    /// A-vii-d.1: nonzero while a `replayLedger` walk is in progress. While set,
    /// `disarmAllLinks` DEFERS (records `pending_disarm_all`) instead of
    /// mutating the armed-link registry: later rows of the very ledger being
    /// walked validate their transitions against that registry (armed-edge
    /// provenance — fused M1 / loop-done / bridge rows all prove "this jump was
    /// armed" by finding the record), and a mid-walk disarm erases the proof of
    /// transitions that already physically happened. Measured on nsieve: the
    /// region gate's `flushRegionWindow` striking to `max_penalty` on row 0 of
    /// a fused `[skip.deopt(M1), ramp.link]` ledger disarmed everything and
    /// panicked row 0's own "armed source-branch ramp" validation. The ledger
    /// DRIVERS apply the deferred disarm via `applyPendingDisarms` immediately
    /// after the walk returns, BEFORE acting on the directive — so no native
    /// code ever runs between the deferral and its application.
    replay_walk_depth: u32 = 0,
    /// The deferred `disarmAllLinks` request (see `replay_walk_depth`).
    pending_disarm_all: bool = false,
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
    /// Pure ephemeral structural-edge cache (doc 17 §A3.3 / §A8-ii, A-ii.2):
    /// `{Trace.id, exit_instr} → StructuralEdgeId`. Rebuilt WHOLESALE from the current
    /// cache at every commit AND every retirement (never surgically mutated), dropped
    /// in `clearCache`, freed in `deinit`. NOT a source of truth — the region
    /// classifier (A-ii.4) will consume it. **Inert: read by nothing in A-ii ⇒
    /// byte-identical.** A rebuild reserves capacity BEFORE clearing the prior snapshot,
    /// so a commit-path OOM RETAINS it and a retirement-path OOM fail-closes to EMPTY
    /// (both region-neutral while read-by-nothing).
    edge_cache: std.AutoHashMapUnmanaged(ExitKey, StructuralEdgeId) = .empty,
    /// Discovered region definitions keyed by interned `RegionId` (doc 17 §A3.1 /
    /// §A8-ii, A-ii.4). **Proto/VM-lifetime**: accumulated as traces commit, NEVER
    /// cleaned by `removeTrace` (a GC-physical retire must not diverge
    /// `gc_stress on/off`), cleared ONLY wholesale in `clearCache` (the epoch boundary
    /// where protos may be freed). Owns each `RegionDef`'s `members`/`member_points`.
    /// **Inert: read by nothing in A-ii ⇒ byte-identical.**
    region_defs: std.AutoHashMapUnmanaged(RegionId, RegionDef) = .empty,
    /// Interns a region's canonical sorted INTERNAL edge SET → its `RegionId` (same
    /// Proto/VM lifetime as `region_defs`). Hash-bucketed; a hit confirmed by
    /// element-wise set equality (collision mints a distinct id).
    region_intern: RegionInternMap = .empty,
    /// Next `RegionId` to mint (monotonic; mirrors `next_trace_id`). A discovery pass
    /// that OOMs before publishing does NOT bump it — the tentative ids it staged are
    /// simply never used (ids need only be unique, not contiguous).
    next_region_id: u64 = 0,
    /// Physical classification index (doc 17 §A3.1 / §A3.3): a concrete trace exit
    /// `{Trace.id, exit_instr}` → the regions it belongs to (internal edges + boundary
    /// exits that LEAVE the region from a member anchor). **Physical + transient**:
    /// WHOLESALE-rebuilt per discovery pass AND per `removeTrace` from the surviving
    /// cache; excludes `armable == false` regions. Owns each `[]RegionId`. Queried by
    /// `classifyExit` (unread by production in A-ii). A retirement-rebuild OOM publishes
    /// EMPTY (fail-closed — the prior set references a dead trace).
    source_exit_regions: std.AutoHashMapUnmanaged(ExitKey, []RegionId) = .empty,
    /// Physical classification index (doc 17 §A3.1): a concrete `Trace.id` → the
    /// regions entered by landing in it (destination of an internal edge; physical
    /// members only). Same lifetime/rebuild/ownership rules as `source_exit_regions`.
    dest_entry_regions: std.AutoHashMapUnmanaged(u32, []RegionId) = .empty,
    /// A-iv: persistent across physical trace retirement/re-arm, bounded by live
    /// activation lifetime and cleared on activation death / restore / epoch end.
    /// Opening a logical region is the only operation that may grow this map;
    /// the per-op observer only probes/removes existing entries.
    region_profit: std.AutoHashMapUnmanaged(RegionKey, RegionAccum) = .empty,
    region_context: ?RegionContext = null,
    /// Inert diagnostics used by the A-iv guards to prove full-window and
    /// remainder flushes occurred. No tiering path consumes either counter.
    region_profit_flushes: u64 = 0,
    region_profit_flushed_work: u64 = 0,
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
    /// 2.3c-2e (2c-E, doc 17): count of loop-done slots actually armed — an inner
    /// root `I`'s numeric-`for` loop-done guard slot pointed at its continuation
    /// `C`'s `ordinary_entry`, closing the native `C↔I` cycle. Bumped only by
    /// `armLoopDoneLink` (the single shared fail-closed arm helper). `> 0` is the
    /// "the I→C arm actually happened" signal for the E2 differential tests.
    native_loopdone_link_arms: u64 = 0,
    /// 2.3c-2e (2c-E, doc 17): count of fused `I.loop_done_linked → C` edges DRAINED
    /// by `replayLedger`'s NON-last `.loop_done_linked` arm — i.e. the arm above
    /// actually took effect and a native run fused straight from an inner loop-done
    /// into its continuation without Zig re-entry. Distinct from the arm counter (an
    /// arm can happen without ever firing); `> 0` proves the fused edge is exercised.
    native_loopdone_link_fused: u64 = 0,
    /// 2c-F (2c-E, doc 17): count of armed slots RESET by `disarmAllLinks` when the
    /// dispatcher opens an observation/suspend/replay window over a VM that already
    /// holds a live armed native cycle (`!safe_to_arm`). Bumped by the number of
    /// slots each `disarmAllLinks` returns to `shared_exit`; `> 0` is the "the
    /// blackout actually tore down a live cycle" signal for the disarm integration
    /// test (a byte-identical run under an open window cannot, by itself, prove a
    /// non-empty registry was torn down — the counter can).
    native_link_disarms: u64 = 0,
    /// A-vii-d (doc 17 §A-vii.2): count of composite bridge slots actually armed by
    /// `tryArmRegionBridge` — a region member's composite ordinary guard slot pointed
    /// at the registered successor's `ordinary_entry`, so the next time that guard
    /// fires natively the stub commits the dominance-scoped phi snapshot and jumps
    /// STRAIGHT into the cross-anchor child (edge 4, no Zig re-entry). `> 0` is the
    /// "the region-profit gate qualified a region and the arm actually happened"
    /// signal for the A-vii-d differential tests.
    native_region_bridge_arms: u64 = 0,
    /// A-vii-d: count of `.region_bridge` ledger rows DRAINED by `replayLedger` —
    /// i.e. the arm above actually took effect and a native run fused through the
    /// composite bridge stub into the cross-anchor successor. Distinct from the arm
    /// counter (an arm can happen without ever firing: the parent may retire, or the
    /// guard may never fail again); `> 0` proves the fused edge-4 hop is exercised.
    native_region_bridge_fused: u64 = 0,
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
    /// **JIT execution-coverage accounting** (gated on `config.coverage`). Measures
    /// the gap between what the JIT *traces* and what actually runs *as a trace*, in
    /// the natural unit of a trace JIT — loop iterations (back-edges). `iters_traced`
    /// = iterations committed by a trace run (tier-1b native, or tier-1a IR-interp
    /// when native is off/unavailable — either way NOT the tier-0 bytecode
    /// interpreter), summed in `onSideExit`; `iters_tier0_covered` = interpreted
    /// back-edges at an anchor that HAS a compiled trace (the smell: covered code
    /// that keeps falling back to tier-0); `iters_tier0_uncovered` = interpreted
    /// back-edges at an anchor with no trace. Total loop iterations = the sum of the
    /// three; "covered by a trace" = traced + tier0_covered; "ran as a trace" =
    /// traced / total.
    iters_traced: u64 = 0,
    iters_tier0_covered: u64 = 0,
    iters_tier0_uncovered: u64 = 0,
    /// **Cycle (time) attribution** for the same three classes, via `readCycles`
    /// (x86_64 TSC; 0 elsewhere). Iteration counts flatter the JIT — a traced
    /// iteration is ~10-20× cheaper than a tier-0 one — so these weigh each class by
    /// actual cost. `cycles_traced` = cycles inside the dispatcher's trace-exec
    /// bracket (native/tier-1a run + chaining); `cycles_tier0_covered` /
    /// `cycles_tier0_uncovered` = cycles of tier-0 body iterations charged at their
    /// back-edge, split by whether a trace exists at the anchor. The report's
    /// `cycles_other` is the residual `run_cycles - (the three)`: it is genuinely
    /// non-loop straight-line code PLUS the small per-trace-entry work that falls
    /// between a back-edge stamp and the trace bracket (trace lookup, fingerprint,
    /// input seeding) — a slop term, not pure non-loop time. The three classes are
    /// disjoint and, being sub-intervals of the run bracket, sum to ≤ `run_cycles`,
    /// so the partition with `cycles_other` holds; only the class *labels* carry the
    /// documented slop, and the per-anchor split additionally has a nesting-boundary
    /// leak (see `AnchorCoverage`). Backward-TSC spans are dropped to 0 (`cycleDelta`).
    cycles_traced: u64 = 0,
    cycles_tier0_covered: u64 = 0,
    cycles_tier0_uncovered: u64 = 0,
    /// Total run cycles (TSC), stamped around the whole `Vm.run` (0 if never set:
    /// coverage off, non-x86_64, or a run driven via the `start()`/`exec()` resume
    /// path, which is NOT instrumented — coverage timing assumes the one-shot `run()`
    /// entry the CLI uses). The denominator for the time-based percentages;
    /// `cycles_other = run_cycles - traced - tier0_*`. When 0 the report shows time
    /// as n/a rather than dividing by zero.
    run_cycles: u64 = 0,
    /// Monotonic wall-clock nanoseconds over the same `Vm.run` bracket as
    /// `run_cycles` (stamped by the CLI from its host clock — the VM core holds no
    /// platform clock). Pairs with `run_cycles` so a consumer can recover the TSC
    /// frequency (`run_cycles / run_nanos`) and convert the per-class cycle counts to
    /// real time. 0 whenever `run_cycles` is (coverage off, non-x86_64, wasm, or the
    /// resume path) — the visualizer then shows time as n/a. Diagnostic only.
    run_nanos: u64 = 0,
    /// TSC of the last tier-0 coverage "event" (back-edge hook, or trace-region exit)
    /// — the start of the current tier-0 span. `noteInterpIter` charges
    /// `now - last_event_tsc` to the anchor. Seeded to the run-start TSC so the first
    /// span isn't a huge bogus delta. Scratch, not reported.
    last_event_tsc: u64 = 0,
    /// TSC of the last trace-hop boundary — the start of the current hop's execution
    /// span. Stamped at trace-region entry (dispatcher `|buf|` block) and re-stamped
    /// by every `onSideExit`, which charges `now - last_hop_tsc` of *this hop's*
    /// execution to *this hop's own anchor* (`t.anchor`). This is what makes per-anchor
    /// traced time mirror the per-anchor iteration count: a chain hop into an inner
    /// trace bills its cycles to the inner anchor, not the outer entry anchor. Scratch,
    /// not reported. (A fused native span that replays several hops in one mcode run is
    /// the one residual: the whole span lands on the first replayed hop — genuinely
    /// unsplittable, since they ran as one instruction stream.)
    last_hop_tsc: u64 = 0,
    /// Per-anchor breakdown of the same accounting, keyed by loop-header anchor, so
    /// the report (and the viz) can attribute traced/interpreted iterations + cycles
    /// to a specific source region. Populated only when `config.coverage`; freed in
    /// `deinit`. `AnchorCoverage` fields mirror the aggregates above, partitioned by
    /// anchor.
    coverage: std.AutoHashMapUnmanaged(AnchorKey, AnchorCoverage) = .empty,
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

    // --- live debug logging (jitdbg) ------------------------------------------
    //
    // The permanent replacement for hand-added `std.debug.print` scaffolding.
    // Compiled out entirely unless the build sets `-Djit-debug=true`; silent at
    // run time unless `config.debug_log` (CLI `--jit-debug`, or set per-VM in a
    // test). See src/jitdbg.zig for the gate contract.

    /// One live debug line, double-gated (comptime `-Djit-debug` + runtime
    /// `config.debug_log`). Stderr only — never program output.
    pub inline fn dbg(self: *const TraceState, comptime fmt: []const u8, args: anytype) void {
        if (comptime jitdbg.enabled) {
            if (self.config.debug_log) jitdbg.log(fmt, args);
        }
    }

    /// Dump the `guard_failures` map (one line per `(anchor, exit_pc)` key with
    /// its count). The on-demand version of the ad-hoc iterator loops we used to
    /// paste into tests. Same double gate as `dbg`.
    pub fn dbgDumpGuardFailures(self: *TraceState) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            jitdbg.log("guard_failures ({d} keys):", .{self.guard_failures.count()});
            var it = self.guard_failures.iterator();
            while (it.next()) |e| {
                jitdbg.log("  anchor pc={d} exit_pc={d} -> {d}", .{
                    e.key_ptr.anchor.pc, e.key_ptr.exit_pc, e.value_ptr.*,
                });
            }
        }
    }

    /// Dump the trace cache (one line per trace: index, id, anchor pc, input/
    /// instr counts, native state, hit count, terminal op). Same double gate.
    pub fn dbgDumpCache(self: *TraceState) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            jitdbg.log("trace cache ({d} traces, {d} armed links):", .{
                self.cache.items.len, self.armed_links.items.len,
            });
            for (self.cache.items, 0..) |t, i| {
                const term: IrOp = if (t.instrs.len != 0) t.instrs[t.instrs.len - 1].op else .loop;
                jitdbg.log("  [{d}] id={d} anchor pc={d} instrs={d} inputs={d} term={s} native={s} hits={d}", .{
                    i,                  t.id,         t.anchor.pc,
                    t.instrs.len,       t.inputs.len, @tagName(term),
                    @tagName(t.native), t.hit_count,
                });
            }
        }
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
        self.coverage.deinit(self.gpa);
        self.edge_cache.deinit(self.gpa); // A-ii.2 (values are plain structs; no per-entry free)
        // A-ii.4: region model. `region_defs` values own members/member_points; the
        // intern map owns its edge slices; the physical indices own their []RegionId.
        var rd_it = self.region_defs.valueIterator();
        while (rd_it.next()) |d| {
            self.gpa.free(d.members);
            self.gpa.free(d.member_points);
            freeRegionBridges(self.gpa, d.bridges);
        }
        self.region_defs.deinit(self.gpa);
        self.region_intern.deinit(self.gpa);
        freeRegionSetMap(ExitKey, &self.source_exit_regions, self.gpa);
        freeRegionSetMap(u32, &self.dest_entry_regions, self.gpa);
        self.region_profit.deinit(self.gpa);
        // Free each trace (its `native.deinit()` returns mcode slots to the arena's
        // free-list) *before* tearing down the arena those slots live in.
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.deinit(self.gpa);
        self.mcode_arena.deinit();
        self.rec.deinit(self.gpa);
    }

    /// Record one interpreted (tier-0) loop back-edge at `(proto, pc)`, plus the
    /// `cycles` the just-completed tier-0 body iteration took (a `readCycles` delta;
    /// 0 on non-x86_64), for coverage accounting. Classifies it covered (a trace has
    /// been committed at this anchor — the "has a trace but ran interpreted" fallback
    /// smell) vs uncovered via the per-anchor `has_trace` flag — an O(1) map probe,
    /// NOT a `findTrace` cache scan, so this stays cheap on the 10M-back-edge hot path
    /// (coverage is opt-in via `--jit-coverage`/`--jit-stats`, never on the timed
    /// `--time`/bench path). Caller gates on `config.coverage`. On OOM the per-anchor
    /// row is lost but the aggregates are still bumped (counted uncovered — no map
    /// entry means no known trace).
    pub fn noteInterpIter(self: *TraceState, proto: *const Proto, pc: u32, cycles: u64) void {
        const gop = self.coverage.getOrPut(self.gpa, .{ .proto = proto, .pc = pc }) catch {
            self.iters_tier0_uncovered +|= 1;
            self.cycles_tier0_uncovered +|= cycles;
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.interp +|= 1;
        gop.value_ptr.interp_cycles +|= cycles;
        if (gop.value_ptr.has_trace) {
            self.iters_tier0_covered +|= 1;
            self.cycles_tier0_covered +|= cycles;
        } else {
            self.iters_tier0_uncovered +|= 1;
            self.cycles_tier0_uncovered +|= cycles;
        }
    }

    /// Record `n` loop iterations committed by a trace run anchored at `anchor`, for
    /// coverage accounting. Called from `onSideExit` — the single per-trace-commit
    /// hook every trace run (tier-1a and tier-1b, direct and every `driveChain` hop)
    /// funnels through exactly once with its OWN committed count, so summing here is
    /// double-count-free. Also flips `has_trace` (a run implies a trace exists — a
    /// belt-and-suspenders guard beside the commit-time `markAnchorTraced`). Caller
    /// gates on `config.coverage`. OOM on the per-anchor map is swallowed (the
    /// aggregate `iters_traced` still holds). Time is attributed alongside in
    /// `noteTracedCycles`, also from `onSideExit` — per hop, to this same anchor.
    pub fn noteTraceIters(self: *TraceState, anchor: AnchorKey, n: u64) void {
        self.iters_traced +|= n;
        const gop = self.coverage.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.traced +|= n;
        gop.value_ptr.has_trace = true;
    }

    /// Charge `cycles` (a `readCycles` delta) of trace-execution time to `anchor`, for
    /// the time-based coverage split. Called from `onSideExit` once per hop with the
    /// span since the previous hop boundary (`last_hop_tsc`), so time is attributed to
    /// the hop's own anchor — the exact time counterpart of the iteration count that
    /// `noteTraceIters` sums per hop. Bumps the aggregate `cycles_traced` and the
    /// per-anchor `traced_cycles`. Caller gates on `config.coverage`; OOM on the
    /// per-anchor map is swallowed (the aggregate still holds).
    pub fn noteTracedCycles(self: *TraceState, anchor: AnchorKey, cycles: u64) void {
        self.cycles_traced +|= cycles;
        const gop = self.coverage.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.traced_cycles +|= cycles;
    }

    /// Mark `anchor` as having a committed trace, for coverage classification. Called
    /// once per trace commit (gated on `config.coverage`), so interpreted back-edges
    /// taken after the commit are classified covered (fallback-despite-a-trace) while
    /// warmup back-edges before it stay uncovered. O(1). OOM swallowed.
    pub fn markAnchorTraced(self: *TraceState, anchor: AnchorKey) void {
        const gop = self.coverage.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.has_trace = true;
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
    /// iterations. The tier-side-exit accounting hook (doc 17 §A3.2), split as of
    /// A-ii.1 and made authoritative on the region side by A-vii-c:
    ///   • `accountTraceRun` — per-segment SELECTION accounting: coverage/cycle
    ///     receipts + the `hit_count` bump for useful (`>= min_useful`) segments.
    ///     As of A-vii-c it no longer touches `penalty`/`gate`.
    ///   • `accountRegionProfit` — the region-profit half (§A3.5). Its window and
    ///     remainder flushes (`flushRegionWindow`) now OWN the penalty/gate state
    ///     machine, keyed by the region owner anchor. A useful full window clears
    ///     the owner's penalty and gate; low-yield remainders strike, and at
    ///     `max_penalty` gate the owner with the doubling cooldown (`gateAnchor`)
    ///     and conservatively disarm all links.
    /// **A-vii-c regionless fallback, A-vii-c.1 consumption form (Bart's decision,
    /// 2026-08-11/12).** The region machine can only gate what discovery
    /// describes, and discovery mints regions exclusively for cycle-bearing SCCs
    /// of the CROSS-ANCHOR structural-edge graph — a plain loop trace or a
    /// same-anchor sibling group has no region at all, so moving the whole penalty
    /// machine to region windows would leave exactly the thrash shapes the gate
    /// exists for (sibling ping-pong committing ~1 iteration per entry, measured
    /// 961 entries/2000 iterations on the parity loop) permanently ungated.
    ///
    /// The ownership boundary is therefore per RECEIPT, keyed on *consumption*:
    /// `accountRegionProfit` reports whether it credited nonzero work to a live
    /// region accumulator, and the legacy per-trace machine runs iff it did not.
    /// Exactly one machine accounts every trace-run receipt, provable from these
    /// three lines rather than inferred from a membership index — which is what
    /// closes the A-vii-c review blocker: physical membership does NOT imply the
    /// region machine can gate a given receipt (a member's prologue failure,
    /// unresolved-guard exit, or any structurally zero-work exit reaches no
    /// window, and R2-1 keeps zero-work flushes silent), so membership-keyed
    /// suppression left those shapes ungated by both machines. Consumption-keyed
    /// suppression cannot: whatever the region machine does not take, the pre-flip
    /// machine still handles.
    ///
    /// This path is null-keyed, so it never consumes and is exactly the pre-flip
    /// per-trace behaviour.
    pub inline fn onSideExit(self: *TraceState, t: *Trace, completed: usize) void {
        self.accountTraceRun(t, completed);
        if (!self.accountRegionProfit(null, 0, .deferred))
            self.accountLegacyThrash(t, completed);
    }

    /// Concrete receipt variant. Selection keeps its historical per-segment
    /// `completed`; logical-region work is independent (`region_work`) because an
    /// inner loop-done contributes one outer traversal even when its local loop
    /// count is large.
    pub inline fn onSideExitReceipt(
        self: *TraceState,
        t: *Trace,
        completed: usize,
        exit_instr: u32,
        region_work: usize,
        dest: RegionDestination,
    ) void {
        self.accountTraceRun(t, completed);
        const key: ?ExitKey = if (exit_instr < t.instrs.len)
            .{ .trace_id = t.id, .exit_instr = exit_instr }
        else
            null;
        // A-vii-c.1: region-first, then legacy iff unconsumed. The two verdicts can
        // only ever touch the same anchor when this receipt's own region closed and
        // flushed against an owner that happens to be `t.anchor`; applying the
        // receipt-local verdict last keeps the most recent evidence authoritative.
        if (!self.accountRegionProfit(key, region_work, dest))
            self.accountLegacyThrash(t, completed);
    }

    /// The pre-A-vii-c per-trace profitability machine, verbatim — applied to every
    /// receipt the region machine did not consume (see `onSideExit`). A useful segment
    /// (`completed >= min_useful`) clears the anchor's penalty and gate; a
    /// low-yield one strikes, and at `max_penalty` the anchor is gated off with
    /// the doubling cooldown (`gateAnchor`). A receipt the region machine DID
    /// consume never reaches this: the region window flush owns that verdict,
    /// keyed on the owner anchor (`flushRegionWindow`).
    inline fn accountLegacyThrash(self: *TraceState, t: *Trace, completed: usize) void {
        const key = t.anchor;
        if (completed >= self.config.min_useful) {
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

    /// A-vii-c.1: the selection receipt for a ledger row whose REGION receipt was
    /// already accounted at the top of `replayLedger`'s per-entry loop. This is
    /// deliberately not `onSideExit`: that wrapper would (a) send a second,
    /// null-keyed region receipt for a row the region machine has already seen and
    /// (b) unconditionally apply the legacy verdict, so a row the region window
    /// consumed would be charged by BOTH machines. The row's own `region_consumed`
    /// is the boundary, exactly as at `onSideExitReceipt`.
    inline fn accountLedgerRow(self: *TraceState, t: *Trace, completed: usize, region_consumed: bool) void {
        self.accountTraceRun(t, completed);
        if (!region_consumed) self.accountLegacyThrash(t, completed);
    }

    fn sameAnchor(a: AnchorKey, b: AnchorKey) bool {
        return a.proto == b.proto and a.pc == b.pc;
    }

    /// The authoritative profitability state machine as of A-vii-c (doc 17
    /// §A8-iii, A-vii.1): every full `N = min_useful` window and every nonzero
    /// (`0 < r < N`) region-exit remainder flows through here, and the old
    /// per-trace penalty/gate decision is applied to the **region owner anchor**
    /// (`RegionDef.owner` — the gate/penalty blast-radius key, §A3.2):
    ///   • `work >= N` (a full window) — the region recovered: remove the owner's
    ///     penalty and gate.
    ///   • `0 < work < N` (a remainder) — a low-yield strike: bump the owner's
    ///     penalty; at `max_penalty`, gate the owner AND conservatively
    ///     `disarmAllLinks()` (deliberate whole-registry blast radius, same
    ///     fail-closed choice as `invalidateRegion`; A-vii-d.1 gave
    ///     `NativeLink` a `region_id`, but only `.region_bridge` links carry
    ///     it — M1/loop-done links still have no region identity, so targeted
    ///     teardown remains unsound here). NB: this can fire MID-`replayLedger`
    ///     walk (the accounting runs per ledger row) — `disarmAllLinks` defers
    ///     under `replay_walk_depth` so the walk's own armed-edge validations
    ///     stay sound, and the ledger driver applies it right after.
    ///   • `work == 0` — no-op (R2-1: a zero-work flush must never strike).
    /// A region whose def has vanished (observer-closed after a logical-map wipe)
    /// has no owner anchor to gate; its work still counts in the diagnostics.
    fn flushRegionWindow(self: *TraceState, key: RegionKey, work: u64) void {
        if (work == 0) return;
        self.region_profit_flushes +|= 1;
        self.region_profit_flushed_work +|= work;
        const def = self.region_defs.get(key.region_id) orelse return;
        const owner = def.owner;
        if (work >= self.config.min_useful) {
            _ = self.penalty.remove(owner);
            _ = self.gate.remove(owner);
            return;
        }
        const gop = self.penalty.getOrPut(self.gpa, owner) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.max_penalty) {
            self.gateAnchor(owner);
            self.disarmAllLinks();
        }
    }

    fn closeRegion(self: *TraceState, key: RegionKey) void {
        const accum = self.region_profit.get(key) orelse return;
        const remainder = accum.outer_traversals - accum.window_base;
        self.flushRegionWindow(key, remainder);
        _ = self.region_profit.remove(key);
    }

    fn activeRegionFor(self: *const TraceState, activation: u64) ?RegionKey {
        var best: ?RegionKey = null;
        var it = self.region_profit.keyIterator();
        while (it.next()) |key| {
            if (key.activation != activation) continue;
            if (best == null or @intFromEnum(key.region_id) < @intFromEnum(best.?.region_id))
                best = key.*;
        }
        return best;
    }

    fn openRegion(self: *TraceState, id: RegionId, ctx: RegionContext) ?RegionKey {
        const def = self.region_defs.get(id) orelse return null;
        if (!def.armable) return null;

        // H-3 replacement: close a different live region at the same activation
        // and owner before publishing the replacement. Scanning is activation-
        // bounded (max physical call depth), and opening—not nextOp—is the cold path.
        var collision: ?RegionKey = null;
        var it = self.region_profit.keyIterator();
        while (it.next()) |key| {
            if (key.activation != ctx.call_seq or key.region_id == id) continue;
            const old_def = self.region_defs.get(key.region_id) orelse continue;
            if (sameAnchor(old_def.owner, def.owner)) {
                if (collision != null) @panic("region_profit cardinality violated before replacement");
                collision = key.*;
            }
        }
        if (collision) |old| self.closeRegion(old);

        const key: RegionKey = .{ .region_id = id, .activation = ctx.call_seq };
        const gop = self.region_profit.getOrPut(self.gpa, key) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{
            .root_frame_depth = ctx.depth,
            .root_call_seq = ctx.call_seq,
        };

        var count: usize = 0;
        var check = self.region_profit.keyIterator();
        while (check.next()) |live| {
            if (live.activation != ctx.call_seq) continue;
            const live_def = self.region_defs.get(live.region_id) orelse continue;
            if (sameAnchor(live_def.owner, def.owner)) count += 1;
        }
        if (count > 1) @panic("region_profit cardinality violated after replacement");
        return key;
    }

    fn invalidateRegion(self: *TraceState, id: RegionId) void {
        self.dbg("region: invalidate id={d} (runtime tombstone)", .{@intFromEnum(id)});
        if (self.region_defs.getPtr(id)) |def| {
            def.armable = false;
            def.tombstoned = true; // fail-closed: recomputation must never re-arm
        }
        while (true) {
            var victim: ?RegionKey = null;
            var it = self.region_profit.keyIterator();
            while (it.next()) |key| {
                if (key.region_id == id) {
                    victim = key.*;
                    break;
                }
            }
            if (victim) |key| self.closeRegion(key) else break;
        }
        self.disarmAllLinks();
    }

    const RegionBridgeDecision = struct {
        child: *Trace,
        bridge: *const RegionBridgeDef,
    };

    fn traceInRegion(self: *const TraceState, trace_id: u32, id: RegionId) bool {
        for (self.dest_entry_regions.get(trace_id) orelse &.{}) |candidate| {
            if (candidate == id) return true;
        }
        return false;
    }

    /// Arm-only child lookup for an already-discovered bridge edge. Selection is
    /// identical to `findTrace`: highest hit_count, stable first-on-tie, with the
    /// additional physical-membership proof that excludes same-anchor siblings.
    fn resolveRegionBridgeChild(
        self: *const TraceState,
        id: RegionId,
        bridge: *const RegionBridgeDef,
    ) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto != bridge.successor.proto or t.anchor.pc != bridge.successor.pc)
                continue;
            if (!self.traceInRegion(t.id, id)) continue;
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    fn slotInSortedSet(slots: []const u16, wanted: u16) bool {
        for (slots) |slot| {
            if (slot == wanted) return true;
            if (slot > wanted) return false;
        }
        return false;
    }

    /// A-vii-b's allocation-free, publish-incapable arm-time validator. It resolves
    /// a physical member child and returns only a decision; it cannot install a
    /// NativeLink. Any failed proof tombstones the region and globally disarms the
    /// existing link registry through the established invalidation path.
    fn validateRegionBridge(
        self: *TraceState,
        id: RegionId,
        parent: *const Trace,
        exit_instr: u32,
    ) ?RegionBridgeDecision {
        const def = self.region_defs.getPtr(id) orelse return null;
        if (!def.armable) return null;
        const edge = self.edge_cache.get(.{
            .trace_id = parent.id,
            .exit_instr = exit_instr,
        }) orelse {
            self.invalidateRegion(id);
            return null;
        };
        var bridge: ?*const RegionBridgeDef = null;
        for (def.bridges) |*candidate| {
            if (candidate.edge.eql(edge)) {
                if (bridge != null) {
                    self.invalidateRegion(id);
                    return null;
                }
                bridge = candidate;
            }
        }
        const b = bridge orelse {
            self.invalidateRegion(id);
            return null;
        };
        const child = self.resolveRegionBridgeChild(id, b) orelse {
            self.invalidateRegion(id);
            return null;
        };

        for (b.required_slots) |slot| {
            if (!nativegen.compositeBridgeEmitsSlot(parent, exit_instr, slot) and
                !slotInSortedSet(b.invariant_slots, slot))
            {
                self.invalidateRegion(id);
                return null;
            }
        }
        if (child.inputs.len != 0) {
            self.invalidateRegion(id);
            return null;
        }
        return .{ .child = child, .bridge = b };
    }

    /// A-vii-d (doc 17 §A-vii.2): the region-bridge arm site. Called from
    /// `driveChain`'s native-only path when a composite bridge candidate deopts —
    /// BESIDE the M1 `.ordinary_guard` arms, never inside them (a composite
    /// candidate is exactly the shape `.ordinary_guard` refuses; the two arm
    /// kinds have disjoint slot populations by construction). Arm-only: it never
    /// steers this deopt, so the surrounding chain walk proceeds unchanged either
    /// way — an armed slot pays off on the NEXT native composite exit, matching
    /// the M1 arm timing.
    ///
    /// Step 1 resolves the unique live source region for this exact exit and
    /// requires the PROFITABILITY qualification on top of structural armability:
    /// the activation's accumulator must have latched `useful_window_seen` (at
    /// least one complete `min_useful` window flushed through the gate machine).
    /// Structural eligibility alone (`RegionDef.armable`) is not profit — both
    /// are required, per the §A8-iii seam. Zero region candidates decline
    /// silently (not a member exit); ambiguity tombstones every candidate, same
    /// verdict `chooseSource` renders. Steps 2–3 delegate the structural proof to
    /// `validateRegionBridge` (unique registered edge, membership-proven child,
    /// S⊆E∪invariants, zero-input child — each failure tombstones + disarms) and
    /// then publish through `armNativeLink(.region_bridge)`.
    ///
    /// The compiled-child/`ordinary_entry` pre-checks exist because
    /// `armNativeLink`'s `.region_bridge` arm treats a missing re-guarding entry
    /// as a wiring bug (release-`@panic`): at THIS call site an uncompiled or
    /// entry-less child is ordinary ineligibility (its compile may simply be
    /// pending), so decline silently and keep the panic as a backstop.
    fn tryArmRegionBridge(self: *TraceState, failed: *Trace, exit_instr: u32) void {
        // Step 1 — unique live region for {failed, exit_instr}.
        const candidates = self.classifyExit(.{ .trace_id = failed.id, .exit_instr = exit_instr });
        if (candidates.len == 0) {
            self.dbg("bridge-arm: decline t={d} ei={d} (no region candidate)", .{ failed.id, exit_instr });
            return;
        }
        if (candidates.len > 1) {
            self.dbg("bridge-arm: decline t={d} ei={d} (ambiguous {d} candidates, invalidating)", .{ failed.id, exit_instr, candidates.len });
            for (candidates) |id| self.invalidateRegion(id);
            return;
        }
        const id = candidates[0];
        const def = self.region_defs.get(id) orelse return;
        if (!def.armable or def.classifier.kind != .cross_trace_cycle) {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (armable={} kind={s})", .{ failed.id, exit_instr, @intFromEnum(id), def.armable, @tagName(def.classifier.kind) });
            return;
        }
        // Profitability: the ACTIVE accumulator for the current activation must
        // belong to this region and have committed a full min_useful window.
        const ctx = self.region_context orelse {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (no activation context)", .{ failed.id, exit_instr, @intFromEnum(id) });
            return;
        };
        const active = self.activeRegionFor(ctx.call_seq) orelse {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (no active region for seq={d})", .{ failed.id, exit_instr, @intFromEnum(id), ctx.call_seq });
            return;
        };
        if (active.region_id != id) {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (active region is rid={d})", .{ failed.id, exit_instr, @intFromEnum(id), @intFromEnum(active.region_id) });
            return;
        }
        const accum = self.region_profit.get(active) orelse return;
        if (!accum.useful_window_seen) {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (no useful window yet, traversals={d})", .{ failed.id, exit_instr, @intFromEnum(id), accum.outer_traversals });
            return;
        }
        // Steps 2–3 — structural proof, then publish.
        const decision = self.validateRegionBridge(id, failed, exit_instr) orelse {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (structural proof failed, region invalidated)", .{ failed.id, exit_instr, @intFromEnum(id) });
            return;
        };
        const child = decision.child;
        const child_c = switch (child.native) {
            .compiled => |*cc| cc,
            else => {
                self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (child id={d} not compiled)", .{ failed.id, exit_instr, @intFromEnum(id), child.id });
                return;
            },
        };
        if (child_c.ordinary_entry == null) {
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (child id={d} has no ordinary_entry)", .{ failed.id, exit_instr, @intFromEnum(id), child.id });
            return;
        }
        const armed = self.armNativeLink(failed, exit_instr, child, .region_bridge) catch false;
        if (armed) {
            // Stamp the exact region the arm was proven against on the record
            // (A-vii-d.1 review blocker 3): `replayLedger`'s `.region_bridge`
            // arm validates through THIS id, and discovery rebuilds disarm the
            // link the moment the region stops being live-armable.
            for (self.armed_links.items) |*l| {
                if (l.parent == failed and l.slot_index == exit_instr) {
                    l.region_id = id;
                    break;
                }
            }
            self.native_region_bridge_arms +|= 1;
        }
    }

    /// A-vii-d.1: the shared receipt-sited arm entry. Every place a native
    /// composite-candidate deopt is OBSERVED with `safe_to_arm` in hand funnels
    /// through here — the dispatcher-entered `driveChain` head, the chain-run
    /// exits, and the post-replay pending drain. Cheap and fail-closed: every
    /// gate declines silently.
    fn maybeArmCompositeExit(self: *TraceState, t: *Trace, exit_instr: u32, safe_to_arm: bool) void {
        if (!safe_to_arm) return;
        if (exit_instr == std.math.maxInt(u32) or exit_instr >= t.instrs.len) return;
        if (!nativegen.isCompositeBridgeCandidate(t, exit_instr)) return;
        self.tryArmRegionBridge(t, exit_instr);
    }

    /// A-vii-d.1 (review blocker 5): drain the at-most-one pending bridge-arm
    /// request `replayLedger` recorded for a terminal composite `.deopt` row.
    /// Arming (and its failure path, `invalidateRegion → disarmAllLinks`) must
    /// never run MID-ledger — it could erase the armed provenance later
    /// `.region_bridge` rows validate against — so the ledger drivers call this
    /// immediately after `replayLedger` returns, before acting on its directive.
    fn drainPendingBridgeArm(self: *TraceState, safe_to_arm: bool) void {
        const key = self.pending_bridge_arm orelse return;
        self.pending_bridge_arm = null;
        const t = self.traceById(key.trace_id) orelse return;
        self.maybeArmCompositeExit(t, key.exit_instr, safe_to_arm);
    }

    /// A-vii-d.1: apply a `disarmAllLinks` that was deferred because it fired
    /// mid-`replayLedger` walk (see `replay_walk_depth`). Every ledger DRIVER
    /// calls this immediately after the walk returns, BEFORE the pending
    /// bridge-arm drain (a disarm-then-re-arm re-validates all its gates;
    /// arm-then-disarm would silently erase the fresh arm) and before acting
    /// on the directive, so the disarm lands before any native re-entry.
    fn applyPendingDisarms(self: *TraceState) void {
        if (!self.pending_disarm_all) return;
        self.pending_disarm_all = false;
        // Fail-closed: a walk that struck the gate arms nothing this round —
        // drop any pending bridge-arm request rather than disarm-then-re-arm
        // into a complex the gate just condemned. It can re-arm on the next
        // composite observation, gates permitting.
        self.pending_bridge_arm = null;
        self.disarmAllLinks();
    }

    fn chooseSource(self: *TraceState, candidates: []const RegionId, ctx: RegionContext) ?RegionKey {
        const active = self.activeRegionFor(ctx.call_seq);
        if (active) |a| {
            for (candidates) |id| if (id == a.region_id) return a;
            self.closeRegion(a);
        }
        if (candidates.len == 0) return null;
        if (candidates.len == 1) return self.openRegion(candidates[0], ctx);
        for (candidates) |id| self.invalidateRegion(id);
        return null;
    }

    fn applyDestination(self: *TraceState, selected: ?RegionKey, dest: RegionDestination, ctx: RegionContext) void {
        if (dest == .deferred) return;
        const candidates: []const RegionId = switch (dest) {
            .deferred => unreachable,
            .known_trace => |trace_id| self.dest_entry_regions.get(trace_id) orelse &.{},
            .terminal_outside => &.{},
        };

        if (selected) |source| {
            for (candidates) |id| if (id == source.region_id) return;
            self.closeRegion(source);
            if (dest == .terminal_outside or candidates.len == 0) return;
        }
        if (candidates.len == 1) {
            _ = self.openRegion(candidates[0], ctx);
        } else if (candidates.len > 1) {
            for (candidates) |id| self.invalidateRegion(id);
        }
    }

    /// Region-profit receipt processor (doc 17 §A3.5). Null-keyed synthetic
    /// events are region-neutral. Concrete events normalize/open the physical
    /// source, credit its committed work, flush every complete min_useful window,
    /// then apply destination classification. As of A-vii-c this is the ONLY
    /// full-window consumer: each complete `N` window flows through the
    /// authoritative `flushRegionWindow` gate machine and latches the
    /// activation's `useful_window_seen` qualification bit (§A8-iii seam).
    ///
    /// **Returns whether this receipt was CONSUMED** — i.e. whether nonzero work
    /// was credited to a live region accumulator, so that the region window
    /// machine has taken ownership of its profitability verdict. This is the
    /// A-vii-c.1 accounting boundary: a caller that also runs per-trace selection
    /// accounting applies the legacy per-trace gate (`accountLegacyThrash`) iff
    /// the region machine did NOT consume. Every trace-run receipt is therefore
    /// accounted by exactly one machine, by construction rather than by inference
    /// from a membership index. Non-consumption covers every shape the region
    /// machine cannot gate: a null key (synthetic scalar site), no live activation
    /// context, an exit absent from the edge cache, an ambiguous/tombstoned
    /// candidate set, and a structurally zero-work receipt (R2-1 keeps zero-work
    /// flushes silent, so a member's repeated zero-work exits must stay legacy-
    /// gated or nothing would ever gate them).
    pub fn accountRegionProfit(self: *TraceState, key: ?ExitKey, work: usize, dest: RegionDestination) bool {
        const exit_key = key orelse return false;
        const ctx = self.region_context orelse return false;
        var consumed = false;
        const selected = self.chooseSource(self.classifyExit(exit_key), ctx);
        if (selected) |source| {
            if (self.region_profit.getPtr(source)) |accum| {
                if (work != 0) {
                    consumed = true;
                    accum.outer_traversals +|= @intCast(work);
                    const n: u64 = @intCast(self.config.min_useful);
                    if (n != 0) while (accum.outer_traversals - accum.window_base >= n) {
                        self.flushRegionWindow(source, n);
                        accum.useful_window_seen = true;
                        accum.window_base += n;
                    };
                }
            }
        }
        self.applyDestination(selected, dest, ctx);
        return consumed;
    }

    /// Set the current physical activation and close accumulators whose recorded
    /// membership no longer contains this tier-0 departure point. No allocation;
    /// the common empty-map path is one count test.
    pub fn observeRegionProgramPoint(self: *TraceState, proto_id: u32, pc: u32, depth: u32, call_seq: u64) void {
        self.region_context = .{ .depth = depth, .call_seq = call_seq };
        if (self.region_profit.count() == 0) return;
        const point: ProgramPoint = .{ .proto_id = proto_id, .source_pc = pc };
        while (true) {
            var victim: ?RegionKey = null;
            var it = self.region_profit.iterator();
            while (it.next()) |entry| {
                const accum = entry.value_ptr.*;
                if (depth > accum.root_frame_depth) continue;
                const def = self.region_defs.get(entry.key_ptr.region_id) orelse {
                    victim = entry.key_ptr.*;
                    break;
                };
                var inside = false;
                for (def.member_points) |member| {
                    if (member.proto_id == point.proto_id and member.source_pc == point.source_pc) {
                        inside = true;
                        break;
                    }
                }
                if (!inside or (depth == accum.root_frame_depth and call_seq != accum.root_call_seq)) {
                    victim = entry.key_ptr.*;
                    break;
                }
            }
            if (victim) |dead| self.closeRegion(dead) else break;
        }
    }

    pub fn dropRegionActivation(self: *TraceState, call_seq: u64) void {
        while (true) {
            var victim: ?RegionKey = null;
            var it = self.region_profit.keyIterator();
            while (it.next()) |key| {
                if (key.activation == call_seq) {
                    victim = key.*;
                    break;
                }
            }
            if (victim) |dead| self.closeRegion(dead) else break;
        }
        if (self.region_context != null and self.region_context.?.call_seq == call_seq)
            self.region_context = null;
    }

    pub fn resetRegionProfit(self: *TraceState) void {
        self.region_profit.clearRetainingCapacity();
        self.region_context = null;
    }

    pub inline fn regionProfitCount(self: *const TraceState) usize {
        return self.region_profit.count();
    }

    pub inline fn setRegionContext(self: *TraceState, depth: u32, call_seq: u64) void {
        self.region_context = .{ .depth = depth, .call_seq = call_seq };
    }

    /// Per-segment SELECTION accounting. As of A-vii-c (doc 17 §A8-iii, A-vii.1)
    /// this half keeps ONLY the coverage/cycle receipts and the per-trace
    /// `hit_count` increment — it no longer reads or writes `penalty`/`gate`.
    /// The profitability decision moved to the region window flush
    /// (`flushRegionWindow`), keyed by the region OWNER anchor. The same executed
    /// transition stream therefore still produces the same `hit_count` ordering
    /// inputs; only the separate gate consumes normalized region windows.
    pub inline fn accountTraceRun(self: *TraceState, t: *Trace, completed: usize) void {
        const key = t.anchor;
        // JIT coverage (gated): this is the single per-trace-commit hook — every
        // trace run (tier-1a/1b, direct dispatch or a `driveChain` hop) reaches here
        // exactly once with its OWN committed count AND its own anchor. Summing
        // `completed` is the "ran as a trace, not tier-0" iteration total; charging
        // the cycle span since the last hop boundary attributes this hop's *time* to
        // *its own anchor* — so a chain hop into an inner trace bills the inner anchor,
        // never the outer entry anchor. Both are disjoint from the interpreted
        // back-edge accounting in the dispatcher (Rule #3: self-consistent).
        if (self.config.coverage) {
            if (completed > 0) self.noteTraceIters(key, completed);
            // Even a zero-progress hop executed trace code (it side-exited), so it is
            // charged too; a bookkeeping-only `onSideExit` merely charges ~0 (the
            // boundary was just advanced by the prior real hop).
            const now = readCycles();
            self.noteTracedCycles(key, cycleDelta(now, self.last_hop_tsc));
            self.last_hop_tsc = now;
        }
        if (completed >= self.config.min_useful) {
            t.hit_count +|= 1;
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
        // A-vii-d (doc 17 §A-vii.2): region-bridge arm site — beside the M1
        // `.ordinary_guard` arms below, never inside them. Native path only,
        // observation-blackout gated (`safe_to_arm`, same rule as every other
        // persistent arm), and only for the composite-guard shape the M1 arm
        // refuses. Arm-only: steering below is unaffected this deopt.
        if (tier == .native_only) self.maybeArmCompositeExit(failed, exit_instr, safe_to_arm);
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
                // 2c-E: capture the hop-0 per-transition ledger. Every armed slot a
                // hop-0 candidate can fire is its `.link` terminal or (M1) an
                // ordinary source-branch guard, so a MULTI-entry ledger here starts
                // at `sct`'s own exit and describes the whole fused span.
                sresult = snt.runCapturingLedger(regs, &self.ledger_scratch);
                // A ledger deeper than the ONE fused hop the scalar `fused_inner`
                // mechanism models (`ledger_len == 2`, the `[C.link, I.x]` shape —
                // kept scalar as the byte-identical compatibility seam; do NOT
                // "simplify" it into the replay route, that shifts the hop cursor
                // and the re-arm supersede) is replay-owned: drain the WHOLE span
                // through `driveSeedLedger`, which charges no wrapper preamble
                // (`replayLedger`'s `.link_terminal` arm owns each
                // `native_link_exits`). Arm the M1 half-fusion first under exactly
                // the gates the ≤2 path below uses — the `failed→sct` edge is valid
                // regardless of how deep `sct`'s own span fused.
                // A-vii-d.1: a hop-0 ledger OPENED by the seed's armed composite
                // bridge (`[C.region_bridge, S.…]`, exactly 2 rows) is replay-owned
                // too — the scalar `sresult_fused` seam below models only the
                // `[C.link, I.x]` shape and would consume the bridged successor as
                // a fused INNER (wrong anchor, wrong resume — measured panic on
                // nsieve the moment the bridge armed).
                const bridge_headed = sresult.ledger_len >= 2 and
                    self.ledger_scratch[0].kind == .region_bridge;
                if (sresult.ledger_len > 2 or bridge_headed) {
                    if (safe_to_arm and materialization == .ordinary_header and
                        sct.inputs.len == 0 and self.isSourceBranchGuardExit(failed, exit_instr, proto))
                    {
                        if (self.armNativeLink(failed, exit_instr, sct, .ordinary_guard) catch false) {
                            self.native_source_link_arms +|= 1;
                        }
                    }
                    // 2c-E site 2 (deep-span variant): under the loop-done
                    // materialization `failed` is the inner root whose loop-done just
                    // committed and `sct` the continuation at its post-loop PC — arm
                    // the reverse `I→C` edge before draining `sct`'s own fused span.
                    if (materialization == .native_numeric_for_done) {
                        self.armLoopDoneLink(failed, exit_instr, sct, safe_to_arm);
                    }
                    return self.driveSeedLedger(
                        sct,
                        self.ledger_scratch[0..sresult.ledger_len],
                        proto,
                        regs,
                        safe_to_arm,
                        materialization,
                    );
                }
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
                if (!sresult_fused) _ = self.accountRegionProfit(
                    .{ .trace_id = sct.id, .exit_instr = sresult.exit_instr },
                    0,
                    .deferred,
                );
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
                    if (self.armNativeLink(failed, exit_instr, sct, .ordinary_guard) catch false) {
                        self.native_source_link_arms +|= 1;
                    }
                }
                // 2c-E site 2 (loop-done hop-0): `failed`'s numeric-for loop-done
                // committed under the native materialization and `sct` is the `.link`
                // continuation at its post-loop PC (`walk_pc` == guardExitPc). Arm the
                // reverse `I→C` edge so the NEXT loop-done jumps straight into
                // `sct`'s `ordinary_entry`; every shape gate lives in the fail-closed
                // helper (`.native_numeric_for_done` only arises on the native tier).
                if (tier == .native_only and materialization == .native_numeric_for_done) {
                    self.armLoopDoneLink(failed, exit_instr, sct, safe_to_arm);
                }
                return self.runLinkedBurst(sct, sresult, sresult_fused, snt, tier, materialization, proto, regs, safe_to_arm);
            }

            // Not a completed link run.
            // A-vii-d.1 (review blocker 4, gap 2): composite deopts on nsieve
            // surface HERE — inside the chain-run, on the chained trace `sct` —
            // not at `driveChain`'s head (measured: "not a completed link run",
            // sct=cont). Arm-only; the receipt/steering below is unaffected.
            if (tier == .native_only) self.maybeArmCompositeExit(sct, sresult.exit_instr, safe_to_arm);
            if (flushed_resume_pc) |target_pc| {
                self.onSideExitReceipt(sct, 0, sresult.exit_instr, 0, .deferred);
                return .{ .completed = 0, .resume_pc = target_pc };
            }
            if (sresult.completed > 0) {
                self.onSideExitReceipt(sct, sresult.completed, sresult.exit_instr, sresult.completed, .deferred);
                return .{ .completed = sresult.completed };
            }
            self.onSideExitReceipt(sct, 0, sresult.exit_instr, 0, .deferred);
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
    /// 2.3c-2c: terminal disposition of draining ONE native call's per-transition
    /// ledger (`replayLedger`). The drain OWNS all per-transition accounting
    /// (`onSideExit`, `native_link_exits`, the `linked_completed`/`resume_pc`/`hops`
    /// cursors); this union only tells the caller what TERMINAL steering to apply
    /// once the whole ledger is walked (Q-arch-3: replay does accounting, caller does
    /// terminal steering). The four variants are the call-B set; 2.3c-2d extends it
    /// with dispatcher-steering variants when the dispatcher also captures.
    const LedgerReplay = union(enum) {
        /// The last entry was an inner loop-done that materialized LINKED and whose
        /// `I→C` edge is NOT fused in THIS ledger (unarmed at that exit, or a forced
        /// yield), and the hop budget remains → re-run the carried continuation for the
        /// next fused span. `resume_pc` set to the continuation anchor (= the loop-done
        /// guard's post-loop PC). 2.3c-2d (P1a): carries the EXACT continuation to run
        /// (`cont`), so a `C1 → I → C2` sibling-continuation transition re-runs `C2`,
        /// not the seed — the caller must `nativeFor()` this trace, never reuse the old
        /// `snt`.
        run_continuation: *Trace,
        /// The last entry was a `.link` terminal whose slot is un-armed (standalone
        /// `.link`) or force-yielded: the continuation advanced the enclosing loop but
        /// no inner fused → resume by running inner fresh next hop (`continue :hop`).
        /// `resume_pc` set to the inner-root PC that `.link` names. 2.3c-2d (P1a):
        /// carries the `.link` DRIVER (the continuation whose `.link.aux` names the
        /// inner); the caller sets `current_link` to it and lets the hop top re-resolve
        /// the inner from `.link.aux`, preserving sibling-selection.
        run_inner_from: *Trace,
        /// Yield / finish: return this `ChainResult` to the dispatcher.
        return_result: ChainResult,
        /// Zero-progress continuation deopt (its own guard, no completion), or the hop
        /// budget is spent after a linked loop-done: break the hop loop and fall to the
        /// penalty-neutral post-loop tail.
        break_burst,
    };

    /// 2.3c-2d: which native-entry site seeded the ledger being replayed. Governs the
    /// ONE origin-dependent decision in `replayLedger`: whether the FIRST entry consumes
    /// a re-run hop. A `continuation_call` (call B) seed is a continuation whose first
    /// entry is its own `.link`/guard and every inner loop-done consumes a hop. An
    /// `inner_call` (call A) seed is an inner root whose FIRST entry is its loop-done —
    /// that completion is the "free" first hop the native burst-bound note already
    /// grants (it increments `linked_completed` without a hop), so it must NOT consume
    /// the re-run cursor, else a trailing `run_inner_from → continue :hop` double-counts
    /// `hops`. `dispatcher_root` (2.3c-2d D2) is the dispatcher's direct native entry.
    const ReplayOrigin = enum { continuation_call, inner_call, dispatcher_root };

    /// 2.3c-2d D2b-i: the mutable hop-loop state shared by every burst entry. The
    /// fresh-entry wrapper (`runLinkedBurst`) builds a zero-progress cursor; the
    /// dispatcher's replayed-M1 handoff (2.3c-2d D2b-ii) hands over an
    /// already-accounted cursor after `replayLedger` has drained the M1 prefix. Both
    /// then run the SAME `driveBurstCore` hop loop + tail from this state, so the
    /// core has exactly one implementation of the continuation⇄inner ping-pong.
    ///   `current_link`   — the `.link` driver this hop dispatches (mutated on swap).
    ///   `linked_completed` — cumulative outer-loop iterations committed so far.
    ///   `resume_pc`      — where tier-0 resumes when the burst yields.
    ///   `hops`           — hops taken (bounded by `max_hops`).
    ///   `start_at_continuation` — 2c-E: the handed-over cursor came from a
    ///       `replayLedger` terminal `.run_continuation`, i.e. the ledger's last
    ///       entry was an inner loop-done that ALREADY committed (linked
    ///       materialization) with no fused successor. The first hop iteration must
    ///       therefore enter at call B (run `current_link`, the carried
    ///       continuation) and SKIP call A — the hop-top inner run — else it would
    ///       re-run an inner whose loop-done already committed (double-commit).
    ///       Consumed exactly once by `driveBurstCore`'s first iteration.
    const BurstCursor = struct {
        current_link: *Trace,
        linked_completed: usize,
        resume_pc: u32,
        hops: usize,
        start_at_continuation: bool = false,
    };

    /// 2.3c-2c: the single authoritative drain of ONE native call's per-transition
    /// ledger. A fused native span (`C→I→C→…` chained under the shared frame) returns
    /// ONE `NativeResult` whose scalar fields describe only the TERMINAL body; the
    /// ledger records every intermediate exit so we can replay the hops we never
    /// re-entered Zig to observe. This walks `entries[0..n]` as a GRAPH — each entry is
    /// classified by `(owner, exit, kind)`, its transition accounted, and only the
    /// LAST entry produces a terminal `LedgerReplay`. It does not hard-code `C/I`
    /// alternation — successor edges are validated by shape, not position — but at
    /// 2.3c-2c it models exactly ONE fused grammar: the `C.link → I.loop_done_linked
    /// → C.link → …` cycle that 2.3c-2e arms. Every other multi-entry shape is an
    /// unmodeled call-B grammar and release-`@panic`s at its emit-site kind arm (the
    /// fused ordinary-guard `.deopt→ramp` M1 shape is deferred to 2.3c-2d; an armed
    /// `C.link→I.guard→R.link` inner-to-sibling chain to a later sub-step). Panicking
    /// is deliberate: a mis-mapped resume PC would silently double-count an
    /// already-committed loop, so an unclassifiable entry MUST hard-stop, never walk on.
    ///
    /// Accounting ownership (Q-arch-3): this function owns EVERY per-transition side
    /// effect — `native_link_exits` on each `.link` marker, `onSideExit` on each body's
    /// productive/zero exit, and the `linked_completed`/`resume_pc`/`hops` cursors. The
    /// caller only applies the returned terminal directive. Per the Q1/Q2 rulings we
    /// account every entry BEFORE any re-run bound; `hops >= max_hops` may only decline
    /// the NEXT re-run at span end (the `run_continuation`→`break_burst` swap on the
    /// last entry), never early-return mid-ledger.
    ///
    /// Seeded at `seed_owner` (call B: the continuation `current_link`) with
    /// `inner_pc` = the inner-root PC that seed's `.link` names. On the ≤2-entry
    /// ledgers that exist before `I→C` is armed (2.3c-2e) this reproduces the old
    /// scalar drain byte-for-byte:
    ///   `[C.link]`          un-armed slot: standalone `.link`     → `run_inner`
    ///   `[C.<guard>]`       continuation's OWN deopt (no `.link`) → productive / break
    ///   `[C.link, I.exit]`  armed slot fused into the inner root  → drain the inner
    fn replayLedger(
        self: *TraceState,
        entries: []const irinterp.LedgerEntry,
        seed_owner: *Trace,
        inner_pc: u32,
        proto: *const Proto,
        linked_completed: *usize,
        resume_pc: *u32,
        hops: *usize,
        max_hops: usize,
        origin: ReplayOrigin,
        safe_to_arm: bool,
    ) LedgerReplay {
        // `ledger_len` is always ≥1 (every native exit appends exactly once) and ≤CAP
        // (the append is bounds-guarded; the forced-yield cap keeps a closed cycle
        // under CAP). Release-guard both so `entries[k]` is never OOB even if that
        // invariant were ever violated upstream.
        if (entries.len == 0 or entries.len > irinterp.LEDGER_CAP)
            @panic("replayLedger: ledger length outside [1, LEDGER_CAP]");
        // A-vii-d.1: never inherit a bridge-arm request from a previous ledger.
        self.pending_bridge_arm = null;
        // A-vii-d.1: defer any `disarmAllLinks` for the duration of the walk
        // (see `replay_walk_depth`); the driver applies it right after.
        self.replay_walk_depth += 1;
        defer self.replay_walk_depth -= 1;

        // Running cursors as the graph is walked:
        //   `cont`    — the continuation whose anchor is the coherent resume for a
        //               terminal inner loop-done (init: the seed; updated when a fused
        //               `I→C` edge dispatches into the next continuation).
        //   `link_pc` — the inner-root PC named by the most-recent `.link` marker, i.e.
        //               where tier-0 resumes if an inner mid-loop-deopts (init: the
        //               seed's `inner_pc`).
        //   `prev_cum`— `cum` of the previous entry, for per-segment `local` deltas
        //               (`cum[-1] == 0`, the trampoline-zeroed call-start `rbx`).
        var cont: *Trace = seed_owner;
        var link_pc: u32 = inner_pc;
        var prev_cum: usize = 0;

        var k: usize = 0;
        while (k < entries.len) : (k += 1) {
            const e = entries[k];
            const is_last = k + 1 == entries.len;
            // A-vii-d.1: this row's owner was entered through an armed composite
            // bridge (`.region_bridge` — the PREVIOUS row). A bridged successor
            // runs mode 0 (`ordinary_entry`), so its terminal contract differs
            // from the linked C⇄I grammar: coherent at its OWN anchor (which the
            // bridge row published into `resume_pc`), ordinary-mode loop-done
            // included — never `link_pc`.
            const entered_via_bridge = k > 0 and entries[k - 1].kind == .region_bridge;
            const owner = self.traceById(e.id) orelse
                @panic("replayLedger: entry owner id did not resolve");
            // First owner must be the seed (call B enters `seed_owner` directly).
            if (k == 0 and owner != seed_owner)
                @panic("replayLedger: first ledger owner is not the seed");
            // `cum` is monotonic non-decreasing (the enclosing counter only grows).
            if (e.cum < prev_cum)
                @panic("replayLedger: ledger cum decreased");
            // A forced yield can only be the LAST entry of a FULL ledger — an armed
            // chain source that saw `ledger_len >= LEDGER_CAP` jumped to `shared_exit`
            // instead of its successor, so nothing follows it AND the ledger is exactly
            // at CAP (the append is bounds-guarded, so it never exceeds CAP).
            if (e.outcome == .yielded and !(is_last and entries.len == irinterp.LEDGER_CAP))
                @panic("replayLedger: forced-yield entry is not the last of a full ledger");
            const local = e.cum - prev_cum;

            // Static owner shape: a continuation ends in `.link`, an inner root in
            // `.loop`. Used per-kind to reject a kind on the wrong owner shape.
            const ends_link = owner.instrs.len != 0 and
                owner.instrs[owner.instrs.len - 1].op == .link;
            const ends_loop = owner.instrs.len != 0 and
                owner.instrs[owner.instrs.len - 1].op == .loop;

            // A-iv consumes the same per-transition ledger the steering machine
            // validates below. Work and structural transition are orthogonal:
            // loop-done is one outer traversal, deopt carries its segment-local
            // committed work, and link/prologue receipts carry none. A concrete
            // fused successor is known only when the next ledger row exists.
            const region_key: ?ExitKey = if (e.kind != .prologue_fail and e.exit < owner.instrs.len)
                .{ .trace_id = owner.id, .exit_instr = e.exit }
            else
                null;
            const region_work: usize = switch (e.kind) {
                .loop_done_linked => 1,
                .deopt => local,
                .link_terminal, .prologue_fail, .region_bridge => 0,
            };
            const region_dest: RegionDestination = if (!is_last)
                .{ .known_trace = entries[k + 1].id }
            else
                .deferred;
            // A-vii-c.1: this row's region receipt. The kind arms below pair their
            // per-trace SELECTION receipt with this verdict via `accountLedgerRow`
            // — never via `onSideExit`, which would both re-enter the region machine
            // with a second null-keyed receipt and charge the legacy machine for a
            // row the region window already consumed. (Receipts the arms raise for a
            // DIFFERENT trace than this row's owner — the `succ` zero-exits — keep
            // `onSideExit`: they have no region row of their own, so they are
            // unconsumed by construction and legacy owns them.)
            const region_consumed = self.accountRegionProfit(region_key, region_work, region_dest);

            // Classify STRICTLY by the static emit-site `kind` (never re-derive the
            // materialization contract from the exit PC — an ordinary `.deopt` whose PC
            // happens to follow a `for_loop` has a DIFFERENT resume contract than a
            // `.loop_done_linked`, so kind is authoritative). Each arm validates its own
            // static contract; any mismatch is a release-`@panic` rather than a silent
            // mis-walk that could double-count an already-committed loop.
            switch (e.kind) {
                .region_bridge => {
                    // A bridge commits its distinct cross-anchor snapshot before
                    // entering the successor. It is therefore never terminal or a
                    // forced yield, and any provenance mismatch is unrecoverable:
                    // falling back would replay from the wrong register image.
                    if (!(e.reason == .normal and e.outcome == .normal and !is_last))
                        @panic("replayLedger: region_bridge is terminal, yielded, or non-normal");
                    if (!nativegen.isCompositeBridgeCandidate(owner, e.exit))
                        @panic("replayLedger: region_bridge exit is not a composite guard");
                    const succ = self.traceById(entries[k + 1].id) orelse
                        @panic("replayLedger: region_bridge successor id did not resolve");

                    // The physical armed-link registry proves that this exact
                    // parent slot entered this exact successor. Composite guards
                    // cannot alias M1: `.ordinary_guard` refuses to arm them.
                    // A-vii-d.1 (review blocker 3): the armed link carries the
                    // EXACT region it was armed under; validate through that one
                    // def — never a global scan over historical `region_defs`,
                    // which could match a stale tombstoned region whose edge
                    // happens to share this (anchor, exit) shape.
                    var armed_region: ?RegionId = null;
                    for (self.armed_links.items) |link| {
                        if (link.parent == owner and link.slot_index == e.exit and link.child == succ) {
                            if (link.kind != .region_bridge)
                                @panic("replayLedger: region_bridge row matched a non-bridge armed link");
                            armed_region = link.region_id orelse
                                @panic("replayLedger: region_bridge armed link has no region provenance");
                            break;
                        }
                    }
                    const region_id = armed_region orelse
                        @panic("replayLedger: region_bridge has no armed provenance");

                    // Resolve the one persistent structural edge bound to this
                    // committed exit — in the armed region's def ONLY. Do not
                    // trust guardExitPc or the next row as the resume source:
                    // RegionDef owns the validated skip anchor.
                    const prov = owner.provAt(e.exit) orelse
                        @panic("replayLedger: region_bridge exit has no provenance");
                    const def = self.region_defs.getPtr(region_id) orelse
                        @panic("replayLedger: region_bridge armed region no longer exists");
                    if (!def.armable)
                        @panic("replayLedger: region_bridge edge is tombstoned");
                    var registered: ?StructuralEdgeId = null;
                    for (def.members) |edge| {
                        if (edge.anchor_proto_id != owner.anchor.proto.id or
                            edge.anchor_pc != owner.anchor.pc or
                            exitOrder(edge.exit, prov) != .eq)
                            continue;
                        if (registered != null)
                            @panic("replayLedger: duplicate region_bridge edge");
                        registered = edge;
                    }
                    const edge = registered orelse
                        @panic("replayLedger: region_bridge edge is not registered");
                    if (edge.succ_anchor_proto_id != succ.anchor.proto.id or
                        edge.succ_anchor_pc != succ.anchor.pc)
                        @panic("replayLedger: region_bridge successor mismatches registered edge");

                    // Selection sees the parent's actual committed segment (with a
                    // synthetic minimum of one); region-profit above independently
                    // receives structural work zero and the concrete successor.
                    //
                    // A-vii-c.1 boundary note — the ONE deliberate exception to
                    // "unconsumed ⇒ legacy". A `.region_bridge` transition always
                    // carries `region_work == 0` (the outer traversal is billed by the
                    // `.loop_done_linked` rows), so it never consumes; but unlike every
                    // other unconsumed receipt, its region ownership is PROVEN right
                    // here by the replay grammar above — an armed backlink plus a
                    // unique live registered edge, @panic on anything less. Running the
                    // legacy machine on it would strike the owner once per intra-region
                    // HOP, while the region window that clears those strikes completes
                    // only once per `min_useful` traversals — two independently
                    // configurable rates (they coincide only because the defaults make
                    // `max_penalty == min_useful == 8`), so a hop-dense region would
                    // reach the gate before its window ever cleared it: precisely the
                    // productive regions this arc exists to build. So this site stays
                    // selection-only. REACHABLE since A-vii-d/d.1 (arming live); the
                    // A-vii-a replay test pins the no-owner-penalty contract
                    // (`penalty.get(cont.anchor) == null` after a bridge row) and the
                    // bridged-successor test pins the `.loop`-ending successor shape.
                    self.accountTraceRun(owner, @max(local, 1));
                    self.native_region_bridge_fused +|= 1;
                    resume_pc.* = edge.succ_anchor_pc;
                },
                .link_terminal => {
                    // A continuation reached its single-contract `.link` terminal.
                    if (!(e.reason == .normal and ends_link and e.exit == owner.instrs.len - 1))
                        @panic("replayLedger: link_terminal entry is not owner's .link");
                    // One `native_link_exits` bump per `.link` marker — this replaces
                    // BOTH the old per-fused-span bump and the standalone-`.link` bump.
                    self.native_link_exits +|= 1;
                    const owner_inner_pc: u32 = @intCast(owner.instrs[owner.instrs.len - 1].aux);
                    if (is_last) {
                        // Standalone `.link` (slot un-armed) OR a forced yield: the
                        // continuation advanced the enclosing loop but no inner fused
                        // here. Resume by running inner fresh at the PC `.link` names.
                        // P1a: carry the `.link` DRIVER (this owner) so the caller sets
                        // `current_link` to it and the hop top re-resolves the inner from
                        // `.link.aux` — preserving sibling-selection.
                        resume_pc.* = owner_inner_pc;
                        return .{ .run_inner_from = owner };
                    }
                    // Armed → dispatched into the linked inner root (entries[k+1]).
                    // Validate the successor is that inner root; a fused id always
                    // resolves (P-B bakes a live id, nothing retires mid-span). This is
                    // the same strict "resolve by baked id + shape, never substitute
                    // `findLoopTrace`'s pick" invariant the old scalar drain enforced.
                    const succ = self.traceById(entries[k + 1].id) orelse
                        @panic("replayLedger: fused successor id did not resolve");
                    if (!isInnerLoopRoot(succ, proto, owner_inner_pc))
                        @panic("replayLedger: fused successor is not the expected inner root");
                    // 2c-E: a fused `C.link → I` edge IS a continuation→inner follow —
                    // the same event the physical call-A hop top charges via its
                    // follow counters. Charge it here so a `run_continuation` handover
                    // that SKIPS call A (`start_at_continuation`) stays
                    // accounting-exact with the unfused decomposition.
                    self.native_link_follow_count +|= 1;
                    self.link_follow_count +|= 1;
                    // Advance the link cursor; the `.link` marker itself takes no
                    // `onSideExit` (only the bodies that commit iterations do).
                    cont = owner;
                    link_pc = owner_inner_pc;
                },
                .loop_done_linked => {
                    // An inner root reached its numeric-`for` loop-done in LINKED
                    // materialization: the final iteration's stores + phi snapshot are
                    // committed, so regs are coherent at the continuation anchor. Owner
                    // must be an inner root and the exit must be a loop-done guard.
                    if (!(e.reason == .normal and ends_loop and isLoopDoneGuardIndex(owner, e.exit)))
                        @panic("replayLedger: loop_done_linked entry is not a linked inner loop-done");
                    // The loop-done guard's post-loop PC: where regs are coherent after
                    // the final iteration committed LINKED. Compute BEFORE accounting so
                    // the resume is always the continuation anchor (P1a fix: an inner-seed
                    // `[I.loop_done_linked, …]` where `cont` still == the seed `I` would
                    // otherwise resume at `I.anchor.pc`, wrong; `post_pc` == the following
                    // continuation's anchor in every modeled shape).
                    const post_pc = guardExitPc(owner.instrs[e.exit]) orelse
                        @panic("replayLedger: fused loop-done has no exit PC");
                    // One more enclosing iteration committed natively. Account BEFORE
                    // the re-run bound (Q1/Q2: never early-return mid-ledger).
                    self.accountLedgerRow(owner, if (local > 0) local else 1, region_consumed);
                    linked_completed.* += 1;
                    resume_pc.* = post_pc;
                    // A `.inner_call` seed's FIRST entry is its own loop-done — that
                    // completion is the "free" first hop the native burst-bound already
                    // grants (it bumps `linked_completed` without a hop). It must NOT
                    // consume the re-run cursor, else a trailing `run_inner_from →
                    // continue :hop` double-increments `hops` (codex D1 ruling).
                    const first_inner = (origin == .inner_call and k == 0);
                    if (!first_inner) hops.* += 1;
                    if (is_last) {
                        // 2c-E site 3 (arming CONVERGENCE): a TERMINAL loop-done means
                        // this `I→C` edge was NOT fused — the slot is unarmed (or a
                        // forced yield steered around it, in which case the re-arm is
                        // an in-place supersede, harmless). Arm it now so the NEXT
                        // occurrence of this exit fuses; sibling inners reached only
                        // through replay thereby converge to armed without ever
                        // passing through a scalar arm site. Runs BEFORE the hop
                        // budget check — the scalar site (call A) also arms on the
                        // burst's last hop.
                        self.armLoopDoneLink(owner, e.exit, cont, safe_to_arm);
                        // The burst may re-run the still-armed continuation. The hop
                        // budget only declines THIS next re-run.
                        if (hops.* >= max_hops) return .break_burst;
                        // 2c-E: the directive EXECUTES `cont`, so an anchor/shape
                        // mismatch is not merely "ineligible" — it is an invalid
                        // steering directive (regs are coherent at `post_pc`; running
                        // a continuation anchored elsewhere would misresume). Release-
                        // validate the full continuation contract before handing it up.
                        if (!(cont.inputs.len == 0 and cont.instrs.len != 0 and
                            cont.instrs[cont.instrs.len - 1].op == .link and
                            cont.anchor.proto == proto and cont.anchor.pc == post_pc))
                            @panic("replayLedger: terminal loop-done carries an invalid continuation");
                        return .{ .run_continuation = cont };
                    }
                    // `I→C` fused (2.3c-2e): the next entry is the continuation reached
                    // via the loop-done→ordinary_entry arm. Validate the successor is a
                    // `.link` continuation anchored at this inner's post-loop PC.
                    const succ = self.traceById(entries[k + 1].id) orelse
                        @panic("replayLedger: fused continuation id did not resolve");
                    if (!(succ.inputs.len == 0 and succ.instrs.len != 0 and
                        succ.instrs[succ.instrs.len - 1].op == .link and
                        succ.anchor.proto == proto and succ.anchor.pc == post_pc))
                        @panic("replayLedger: fused successor is not the expected continuation");
                    // 2c-E: the armed `I.loopdone → C.ordinary_entry` edge actually
                    // fired in native code — the consumer-side proof of the arm.
                    self.native_loopdone_link_fused +|= 1;
                    cont = succ;
                },
                .deopt => {
                    // The shared `deopt_exit` flush: an ordinary per-guard side exit.
                    // Two modeled shapes at 2.3c-2c, BOTH terminal:
                    //   (a) the seed continuation's OWN source-branch guard before it
                    //       reached `.link` (owner ends `.link`) → the enclosing loop
                    //       ended; resume at the running cursor.
                    //   (b) an inner mid-loop body guard (owner ends `.loop`, exit NOT a
                    //       loop-done guard) → regs coherent at the inner header.
                    // A NON-last `.deopt` is a fused ordinary-guard→successor hop (the M1
                    // `source-branch→ramp` shape). Its per-transition accounting is the
                    // dispatcher's `fusedSourceBranchLinkSlot` steering, folded into this
                    // drain only when the dispatcher itself captures (2.3c-2d). Until
                    // then it is an unmodeled call-B grammar → loud release-panic (the
                    // same hard-stop the old ≤2 drain took on any >2 ledger), never a
                    // silent mis-walk.
                    if (e.reason != .normal)
                        @panic("replayLedger: .deopt entry has a non-normal reason");
                    if (!is_last) {
                        // 2.3c-2d (D2b-ii): the fused ordinary-guard→successor M1 shape
                        // — `owner` (the skip trace) hit its ARMED source-branch guard
                        // and jumped straight into a prime-side entry ramp (`succ`).
                        // This is the ONLY non-last `.deopt` grammar modeled; validate
                        // it strictly by armed-edge provenance (never the `.link` opcode,
                        // which OOBs on a fused prologue-fail) and replay the exact
                        // steering the old scalar dispatcher M1 recognizer did.
                        if (e.outcome != .normal)
                            @panic("replayLedger: fused M1 .deopt is a forced yield");
                        if (e.exit >= owner.instrs.len)
                            @panic("replayLedger: fused M1 .deopt exit index out of range");
                        if (!self.isSourceBranchGuardExit(owner, e.exit, proto))
                            @panic("replayLedger: fused M1 .deopt exit is not a source-branch guard");
                        const succ = self.traceById(entries[k + 1].id) orelse
                            @panic("replayLedger: fused M1 successor id did not resolve");
                        if ((self.fusedSourceBranchLinkSlot(owner, succ, proto) orelse
                            @panic("replayLedger: fused M1 successor is not an armed source-branch ramp")) != e.exit)
                            @panic("replayLedger: fused M1 armed slot does not match the exit guard");
                        std.debug.assert(self.countTracesAt(owner.anchor) >= 2);
                        // The ramp commits ZERO of its OWN iterations, so its `cum`
                        // equals the skip's (`entry_rbx == skip_local`). `local` here is
                        // therefore the skip trace's own committed count, and
                        // `onSideExit(owner, local)` below reproduces the old
                        // `onSideExit(ct, skip_local)` exactly.
                        if (entries[k + 1].cum != e.cum)
                            @panic("replayLedger: fused M1 ramp committed its own iterations (cum advanced)");
                        self.native_source_link_fused +|= 1;
                        self.accountLedgerRow(owner, local, region_consumed);
                        // Sub-case (b): the ramp deopted at an internal guard BEFORE its
                        // `.link` — terminal. Replay the old dispatcher steering
                        // `onSideExit(ramp, 0); resume owner.anchor.pc`. (`succ.cum ==
                        // owner.cum`, so `succ`'s own `local` is 0 regardless.) Resume at
                        // `owner`'s OWN anchor — the source trace's coherent header — NOT
                        // `seed_owner`'s: for the flat 2-entry M1 they coincide (owner is
                        // the seed), but a future nested `[…, I.deopt(armed), R.deopt]`
                        // would resume at `I.anchor.pc`, not the outer seed. `succ` (`R`)
                        // must be the LAST entry — a `.deopt` M1 edge whose ramp deopt is
                        // itself followed by more entries is an unmodeled grammar, so
                        // hard-stop rather than silently drop the tail.
                        if (entries[k + 1].kind == .deopt) {
                            if (k + 2 != entries.len)
                                @panic("replayLedger: fused M1 sub-case (b) ramp deopt is not the last entry");
                            self.onSideExit(succ, 0);
                            return .{ .return_result = .{
                                .completed = linked_completed.*,
                                .resume_pc = owner.anchor.pc,
                            } };
                        }
                        // Sub-case (c) (2c-E): the ramp's HOISTED entry-type prologue
                        // failed after the armed jump — pre-commit, so the cumulative
                        // counter is unchanged (validated above) and regs are still
                        // coherent at the source trace's anchor header. Replay the
                        // unarmed native steering exactly: unarmed, `driveChain` runs
                        // the ramp fresh, its prologue fails, and — because the native
                        // tier always owes a flush (`flushed_resume_pc = walk_pc`) —
                        // the "Not a completed link run" tail short-circuits with
                        // `onSideExit(ramp, 0)` + resume at `walk_pc == owner.anchor.pc`
                        // WITHOUT retrying further candidates (the retry tail is
                        // tier-1a-only). Terminal by contract; anything after it is an
                        // unmodeled grammar.
                        if (entries[k + 1].kind == .prologue_fail) {
                            if (k + 2 != entries.len)
                                @panic("replayLedger: fused M1 sub-case (c) ramp prologue-fail is not the last entry");
                            const se = entries[k + 1];
                            if (!(se.reason == .prologue_fail and se.exit == std.math.maxInt(u32) and
                                se.outcome == .normal))
                                @panic("replayLedger: fused M1 sub-case (c) entry violates the prologue-fail contract");
                            if (!(succ.instrs.len != 0 and succ.instrs[succ.instrs.len - 1].op == .link))
                                @panic("replayLedger: fused M1 sub-case (c) ramp does not end in .link");
                            self.onSideExit(succ, 0);
                            return .{ .return_result = .{
                                .completed = linked_completed.*,
                                .resume_pc = owner.anchor.pc,
                            } };
                        }
                        // Sub-case (a): the ramp reached its `.link` terminal. This is a
                        // coherent-anchor (prime-side) burst entry — charge the firing
                        // signal HERE, tied to confirmed M1 source-guard provenance (the
                        // old `runLinkedBurst(.ordinary_header)` preamble bump; the
                        // dispatcher mapping no longer owns it). Then fall through — the
                        // next iteration's `.link_terminal` arm charges the one
                        // `native_link_exits`, sets `resume_pc` to the ramp's inner-root
                        // PC, and returns `run_inner_from(ramp)`. Any other successor kind
                        // is an unmodeled grammar → hard-stop.
                        if (entries[k + 1].kind != .link_terminal)
                            @panic("replayLedger: fused M1 successor is not .link_terminal (a), .deopt (b), or .prologue_fail (c)");
                        self.prime_side_chain_follows +|= 1;
                        prev_cum = e.cum;
                        continue;
                    }
                    // The exit must name an interior deopt-producing instruction on
                    // `owner`. The set of ops that deopt is BROADER than `guardExitPc`'s
                    // `guard_*`/`int_of_float` (it includes array-bounds / store-type
                    // guards, etc.), so we validate the way the dispatcher does
                    // (interp.zig:2708 trusts `exit_instr < instrs.len`) — by bounds —
                    // and additionally exclude the `.link`/`.loop` TERMINATOR ops, which
                    // are the successful-completion path and never a deopt source. This
                    // rejects an out-of-range index and `exit == maxInt` (which belongs
                    // to `.prologue_fail`) without over-rejecting a legitimate guard.
                    if (e.exit >= owner.instrs.len)
                        @panic("replayLedger: .deopt exit index out of range");
                    const exit_op = owner.instrs[e.exit].op;
                    if (exit_op == .link or exit_op == .loop)
                        @panic("replayLedger: .deopt exit names a terminator, not a guard");
                    // A-vii-d.1: a terminal composite-candidate deopt is the fused-span
                    // observation of the edge-4 exit. Record the at-most-one pending
                    // arm request; the ledger DRIVER drains it after this replay
                    // returns (never mid-walk — review blocker 5).
                    if (e.outcome == .normal and nativegen.isCompositeBridgeCandidate(owner, e.exit))
                        self.pending_bridge_arm = .{ .trace_id = owner.id, .exit_instr = e.exit };
                    // A-vii-d.1: (b') bridged successor — an ordinary-mode
                    // (`ordinary_entry`) body entered through the composite
                    // bridge. Checked BEFORE the `ends_link` split (codex
                    // post-landing blocker): bridge validation requires zero
                    // inputs + `ordinary_entry` but not a `.loop` terminator,
                    // so a `.link`-ending successor is legal — routing it to
                    // the legacy seed-continuation path would drop its
                    // zero-progress receipt and let the hop-0 tail charge the
                    // BRIDGE PARENT a second time (`onSideExit(seed, 0)`),
                    // even though the `.region_bridge` row already accounted
                    // it. Bridged deopts follow the coherent-anchor discipline
                    // (regs coherent at the successor's OWN anchor, the H-1b
                    // re-execute convention), NOT the linked-inner `link_pc`
                    // contract — and an ordinary-mode loop-done deopt is
                    // legitimate here (mode 0 bypasses the linked slot). The
                    // bridge row already published the successor's validated
                    // anchor into `resume_pc`; hard-verify the two agree
                    // rather than trusting either alone.
                    if (entered_via_bridge) {
                        if (!(ends_link or ends_loop))
                            @panic("replayLedger: bridged successor deopt on a non-body owner shape");
                        if (resume_pc.* != owner.anchor.pc)
                            @panic("replayLedger: bridged successor deopt resume mismatches its anchor");
                        self.accountLedgerRow(owner, local, region_consumed);
                        return .{ .return_result = .{
                            .completed = linked_completed.* + local,
                            .resume_pc = resume_pc.*,
                        } };
                    }
                    if (ends_link) {
                        // (a) continuation own guard — terminal.
                        if (local > 0) {
                            self.accountLedgerRow(owner, local, region_consumed);
                            return .{ .return_result = .{
                                .completed = linked_completed.* + local,
                                .resume_pc = resume_pc.*,
                            } };
                        }
                        return .break_burst;
                    }
                    if (!ends_loop)
                        @panic("replayLedger: .deopt owner is neither continuation nor inner root");
                    // (b) inner body guard. An ordinary-materialization loop-done deopt
                    // (exit PC after `for_loop`) has a DIFFERENT resume contract (tier-0
                    // at the post-loop PC, final iteration uncommitted) and cannot occur
                    // in a linked call-B fusion (the inner is entered at `linked_entry`,
                    // so its loop-done materializes `.loop_done_linked`). Reject it loudly
                    // rather than mis-resume at the inner header (which would re-run the
                    // whole inner loop).
                    if (isLoopDoneGuardIndex(owner, e.exit))
                        @panic("replayLedger: ordinary-mode inner loop-done in a linked fusion is unmodeled");
                    self.accountLedgerRow(owner, local, region_consumed);
                    return .{ .return_result = .{
                        .completed = if (linked_completed.* > 0) linked_completed.* else local,
                        .resume_pc = link_pc,
                    } };
                },
                .prologue_fail => {
                    // A hoisted entry-type guard failed pre-commit: `exit = -1`,
                    // `reason = .prologue_fail`, `outcome = .normal`, and — because the
                    // guard fails BEFORE any `.loop` back-edge — the cumulative counter
                    // is unchanged across this segment, so `local == 0`. Always terminal
                    // (never a chain source) and never a forced yield. A nonzero `local`
                    // would contradict "no iteration committed": release-panic rather
                    // than silently charge phantom progress.
                    if (!(e.reason == .prologue_fail and e.exit == std.math.maxInt(u32) and
                        e.outcome == .normal and local == 0))
                        @panic("replayLedger: prologue_fail entry violates its static contract");
                    if (!is_last)
                        @panic("replayLedger: prologue_fail is terminal but not last");
                    // A-vii-d.1: bridged successor prologue-fail — checked
                    // BEFORE the `ends_link` split (codex post-landing
                    // blocker; same reasoning as the bridged `.deopt` arm: a
                    // `.link`-ending successor is bridge-legal and must not
                    // fall into the seed-continuation `break_burst`, which
                    // drops its zero-progress receipt and double-charges the
                    // bridge parent in the hop-0 tail). The bridge committed
                    // its cross-anchor snapshot, then the successor's hoisted
                    // entry guards failed PRE-commit, so regs are still
                    // coherent at the successor's anchor (which the bridge row
                    // published into `resume_pc`). Zero-progress charge;
                    // resume there, never at the stale `link_pc`.
                    if (entered_via_bridge) {
                        if (!(ends_link or ends_loop))
                            @panic("replayLedger: bridged successor prologue-fail on a non-body owner shape");
                        if (resume_pc.* != owner.anchor.pc)
                            @panic("replayLedger: bridged successor prologue-fail resume mismatches its anchor");
                        self.accountLedgerRow(owner, 0, region_consumed);
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = resume_pc.*,
                        } };
                    }
                    if (ends_link) {
                        // Seed continuation prologue-fail (local == 0): nothing committed
                        // here → break the burst (matches old scalar `c_local == 0 →
                        // break_burst`).
                        return .break_burst;
                    }
                    if (!ends_loop)
                        @panic("replayLedger: prologue_fail owner is neither continuation nor inner root");
                    // Inner prologue-fail (local == 0): matches the old `fdone == false`
                    // mid-loop path — record the zero-progress side exit and resume
                    // tier-0 at the inner header, carrying any earlier chain progress.
                    self.accountLedgerRow(owner, 0, region_consumed);
                    return .{ .return_result = .{
                        .completed = if (linked_completed.* > 0) linked_completed.* else 0,
                        .resume_pc = link_pc,
                    } };
                },
            }
            prev_cum = e.cum;
        }
        // Every entry is either terminal (returns above) or a validated chain source
        // whose successor is the next entry — so the loop always returns before it
        // runs out of entries. Reaching here means the LAST entry was a chain source
        // with no successor, i.e. an unmodeled grammar.
        @panic("replayLedger: ledger ended on a chain source with no terminal");
    }

    /// Fresh-entry wrapper: a burst that STARTS at `sct` (a doc-15 continuation or a
    /// doc-16 prime-side entry ramp). Charges the one-time burst-entry counters
    /// (`native_link_exits`/`link_ir_exits` and, for the coherent-anchor path,
    /// `prime_side_chain_follows`), then enters the shared `driveBurstCore` from a
    /// zero-progress cursor. The dispatcher's 2.3c-2d replayed-M1 entry enters the
    /// SAME core from an already-accounted cursor WITHOUT this preamble (the replayed
    /// ramp `.link` already charged `native_link_exits` inside `replayLedger`).
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
        if (tier == .native_only) {
            self.native_link_exits +|= 1;
        } else {
            self.link_ir_exits +|= 1;
        }
        // Phase-2 chain-firing signal: this burst entered through the
        // coherent-anchor (outer-header prime side-trace) path, not a
        // loop-done continuation. Bump regardless of tier.
        if (materialization == .ordinary_header) self.prime_side_chain_follows +|= 1;
        const cursor = BurstCursor{
            .current_link = sct,
            .linked_completed = 0,
            // The design's `coherent_pc` cursor: where tier-0 resumes when the
            // burst yields. Starts at the inner-root PC named by the `.link`.
            .resume_pc = @intCast(sct.instrs[sct.instrs.len - 1].aux),
            .hops = 0,
        };
        // 2.3b-1: a *fused* continuation run (armed `.link` slot jumped straight into
        // inner) hands the inner loop-done/mid result forward so the core consumes it
        // WITHOUT re-running inner. Only ever non-null on the native path.
        const fused_inner: ?irinterp.ExecResult = if (sresult_fused) sresult else null;
        return self.driveBurstCore(sct, cursor, fused_inner, snt_in, tier, proto, regs, safe_to_arm);
    }

    /// The shared continuation⇄inner-root ping-pong core. Runs from an already-built
    /// `cursor` — fresh zero-progress from `runLinkedBurst`, or an already-accounted
    /// cursor the dispatcher hands over after a `replayLedger` M1 drain (2.3c-2d
    /// D2b-ii). `seed` is the burst's origin trace, used only by the zero-progress
    /// tail's `onSideExit(seed, 0)`. This function owns NO one-time entry counters —
    /// its caller charges those before handing over the cursor.
    fn driveBurstCore(
        self: *TraceState,
        seed: *Trace,
        cursor: BurstCursor,
        fused_inner_in: ?irinterp.ExecResult,
        snt_in: *const nativegen.CompiledTrace,
        comptime tier: ChainTier,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
    ) ChainResult {
        // Burst hop bound: matches the old `visited: [8]*Trace` cap (see the BURST BOUND
        // note below). A named const now that the walk's `visited` array is out of scope.
        const max_hops: usize = 8;
        var snt = snt_in;
        var linked_completed: usize = cursor.linked_completed;
        // The ping-pong *driver*: a `.link` trace anchored at the post-inner
        // PC that advances the enclosing loop and links back to the inner
        // root. Seeded from the cursor — for a doc-15 continuation IS the
        // driver, but for a doc-16 prime side-trace is only the *entry ramp*
        // (anchored at the outer header, not the post-inner PC). After the
        // first inner loop-done we swap to the real continuation (below), so
        // the burst advances the outer loop natively instead of dropping to
        // tier-0. Mutable for exactly that swap.
        var current_link = cursor.current_link;
        var resume_pc: u32 = cursor.resume_pc;
        var fused_inner: ?irinterp.ExecResult = fused_inner_in;
        var hops: usize = cursor.hops;
        // 2c-E: a `.run_continuation` handover enters at call B on its FIRST hop
        // iteration (see `BurstCursor.start_at_continuation`). Consumed once.
        var start_call_b = cursor.start_at_continuation;
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
            // Call A — resolve and run this hop's inner root, classify its exit,
            // swap the driver, roll up the completed enclosing iteration, and arm
            // the `C.link → I.linked_entry` slot. A handed-over `.run_continuation`
            // cursor skips the whole section (its terminal inner loop-done ALREADY
            // committed inside the drained ledger; re-entering the hop top would
            // re-run it), entering call B directly — as does the call-A drain's own
            // `.run_continuation` directive below.
            call_a: {
                if (start_call_b) {
                    start_call_b = false;
                    break :call_a;
                }
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
                    // 2.3c-2d (D1): capture the per-transition ledger in LINKED mode (the
                    // linked counterpart of call B's `runCapturingLedger` — a literal
                    // `runCapturingLedger` swap would flip mode 1→0 and stop committing the
                    // final inner iteration, corrupting coherent resume).
                    iresult = int_native.runLinkedLoopDoneCapturing(regs, &self.ledger_scratch);
                    // 2c-E (call-A drain): `ledger_len > 1` means the inner FUSED forward
                    // through an armed slot — its loop-done → a continuation's
                    // `ordinary_entry` (the 2c-E arm), or an M1-armed mid-loop
                    // source-branch guard → a ramp — so the ledger holds the whole fused
                    // span and the scalar classification below can only see the TERMINAL
                    // body. Drain it through the authoritative `replayLedger` graph-walk.
                    // Origin `.inner_call`: the seed's own k==0 loop-done is the "free"
                    // first hop and must not consume the re-run cursor (codex D1). The
                    // drain owns ALL per-transition accounting (`onSideExit`,
                    // `native_link_exits`, the cursors); this arm only applies the
                    // terminal steering:
                    //   run_continuation → fall into call B THIS hop iteration (the span
                    //                      already ran the inner; looping to the hop top
                    //                      would re-run it),
                    //   run_inner_from   → next hop re-resolves the inner from `.link.aux`,
                    //   return_result    → the burst is done, hand the receipt up,
                    //   break_burst      → penalty-neutral tail.
                    if (iresult.ledger_len > 1) {
                        const call_a_directive = self.replayLedger(
                            self.ledger_scratch[0..iresult.ledger_len],
                            inner,
                            inner_pc,
                            proto,
                            &linked_completed,
                            &resume_pc,
                            &hops,
                            max_hops,
                            .inner_call,
                            safe_to_arm,
                        );
                        // A-vii-d.1: drain the pending bridge-arm request AFTER the
                        // walk, BEFORE acting on the directive (review blocker 5).
                        self.applyPendingDisarms();
                        self.drainPendingBridgeArm(safe_to_arm);
                        switch (call_a_directive) {
                            .run_continuation => |c| {
                                current_link = c;
                                snt = self.nativeFor(c) orelse break :hop;
                                break :call_a;
                            },
                            .run_inner_from => |d| {
                                current_link = d;
                                continue :hop;
                            },
                            .return_result => |cr| return cr,
                            .break_burst => break :hop,
                        }
                    }
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

                const inner_guard = inner.instrs[iresult.exit_instr];
                const inner_exit_pc = guardExitPc(inner_guard) orelse break;
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
                    proto.code[guardSourcePc(inner_guard).?].op == .for_loop;
                if (!loop_done) {
                    if (inner_local > 0) {
                        self.onSideExitReceipt(inner, inner_local, iresult.exit_instr, 0, .deferred);
                        return .{
                            .completed = if (linked_completed > 0) linked_completed else inner_local,
                            .resume_pc = resume_pc,
                        };
                    }
                    self.onSideExitReceipt(inner, 0, iresult.exit_instr, 0, .deferred);
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
                        self.onSideExitReceipt(inner, if (inner_local > 0) inner_local else 1, iresult.exit_instr, 1, .deferred);
                        return .{ .completed = linked_completed + 1, .resume_pc = inner_exit_pc };
                    };
                    if (tier == .native_only) {
                        snt = self.nativeFor(cont) orelse {
                            self.onSideExitReceipt(inner, if (inner_local > 0) inner_local else 1, iresult.exit_instr, 1, .deferred);
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
                self.onSideExitReceipt(inner, if (inner_local > 0) inner_local else 1, iresult.exit_instr, 1, .{ .known_trace = current_link.id });
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
                    const slot: u32 = @intCast(current_link.instrs.len - 1);
                    if (self.armNativeLink(current_link, slot, inner, .link_terminal) catch false) {
                        self.native_link_arms +|= 1;
                    }
                }
                // 2c-E site 1 (the REVERSE edge): arm `inner`'s loop-done slot →
                // `current_link`'s `ordinary_entry`, closing the native `C↔I` cycle.
                // `current_link` is read AFTER the driver swap above, so it is the
                // continuation anchored at the inner's post-loop PC (the swap's
                // `findLinkTrace(proto, inner_exit_pc)` pick, or the already-correct
                // doc-15 driver); `iresult.exit_instr` is the loop-done guard this
                // scalar path just classified. All shape/eligibility gates live in
                // the fail-closed helper.
                if (tier == .native_only) {
                    self.armLoopDoneLink(inner, iresult.exit_instr, current_link, safe_to_arm);
                }
            }

            // Call B.
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
                    const call_b_directive = self.replayLedger(
                        self.ledger_scratch[0..cresult.ledger_len],
                        current_link,
                        inner_pc,
                        proto,
                        &linked_completed,
                        &resume_pc,
                        &hops,
                        max_hops,
                        .continuation_call,
                        safe_to_arm,
                    );
                    // A-vii-d.1: drain the pending bridge-arm request AFTER the
                    // walk, BEFORE acting on the directive (review blocker 5).
                    self.applyPendingDisarms();
                    self.drainPendingBridgeArm(safe_to_arm);
                    switch (call_b_directive) {
                        // Re-run the carried continuation for the next fused span.
                        // P1a: re-resolve its native compilation (a `C1 → I → C2`
                        // sibling swap makes `c != current_link`); never reuse the old
                        // `snt`. On the same-C nsieve cycle `c == current_link` and
                        // `nativeFor(c) == snt`, so this is byte-identical.
                        .run_continuation => |c| {
                            current_link = c;
                            snt = self.nativeFor(c) orelse break :hop;
                            cresult = snt.runCapturingLedger(regs, &self.ledger_scratch);
                        },
                        // Standalone `.link`: carry the `.link` DRIVER as the running
                        // link cursor and resume inner fresh next hop (the hop top
                        // re-resolves the inner from its `.link.aux`).
                        .run_inner_from => |d| {
                            current_link = d;
                            continue :hop;
                        },
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
                    _ = self.accountRegionProfit(
                        .{ .trace_id = current_link.id, .exit_instr = cresult.exit_instr },
                        0,
                        .deferred,
                    );
                    // Standalone `.link` at the continuation's terminal: `inner_pc` is
                    // this hop's entry-link target (stable across a prime-side→cont
                    // swap; the next hop recomputes it from `current_link`).
                    resume_pc = inner_pc;
                    continue;
                }
                if (cresult.completed > 0) {
                    self.onSideExitReceipt(current_link, cresult.completed, cresult.exit_instr, cresult.completed, .deferred);
                    return .{ .completed = linked_completed + cresult.completed, .resume_pc = resume_pc };
                }
                _ = self.accountRegionProfit(
                    if (cresult.exit_instr < current_link.instrs.len)
                        .{ .trace_id = current_link.id, .exit_instr = cresult.exit_instr }
                    else
                        null,
                    0,
                    .deferred,
                );
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
        self.onSideExit(seed, 0);
        // A burst that committed nothing hasn't advanced `resume_pc` past its
        // initial inner-root PC, so this is the coherent resume target.
        return .{ .completed = 0, .resume_pc = resume_pc };
    }

    /// 2.3c-2d D2b-ii: the dispatcher's direct-native-entry ledger drain. When a
    /// dispatcher native entry at `seed` (an ordinarily-dispatched trace — e.g. the
    /// nsieve skip trace) fuses forward through an armed slot, its `NativeResult`
    /// carries a MULTI-ENTRY per-transition ledger describing the whole fused span.
    /// This drains that span through the SAME `replayLedger` graph-walk the in-burst
    /// continuation call uses (origin `.dispatcher_root`), then maps the terminal
    /// directive onto the shared `driveBurstCore`. It replaces the bespoke scalar M1
    /// recognizer the dispatcher used through 2.3c-1: `replayLedger` reproduces its
    /// `onSideExit(ct, skip_local)` + sub-case (a)/(b) steering exactly (see the
    /// `.deopt` non-last arm), and — because it owns per-transition accounting — the
    /// only entry counter left for THIS caller is the coherent-anchor firing signal
    /// (`prime_side_chain_follows`, the old `runLinkedBurst(.ordinary_header)` bump).
    /// `entries` must be the captured `ledger_scratch[0..ledger_len]`; the caller has
    /// already gated on `ran_native and ledger_len > 1 and exit_reason == .normal`.
    pub fn driveDispatcherLedger(
        self: *TraceState,
        seed: *Trace,
        entries: []const irinterp.LedgerEntry,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
    ) ChainResult {
        const max_hops: usize = 8;
        var linked_completed: usize = 0;
        var resume_pc: u32 = seed.anchor.pc;
        var hops: usize = 0;
        // The seed is a directly-dispatched trace (never a `.link`), so it has no
        // inner-root PC of its own; `inner_pc` only seeds `replayLedger`'s `link_pc`
        // fallback for an inner mid-loop-deopt before any `.link` marker — which the
        // modeled M1 grammar never reaches (its first `.link` sets the real cursor).
        // Pass the seed anchor as an inert placeholder.
        const inner_pc: u32 = seed.anchor.pc;
        const dispatcher_directive = self.replayLedger(entries, seed, inner_pc, proto, &linked_completed, &resume_pc, &hops, max_hops, .dispatcher_root, safe_to_arm);
        // A-vii-d.1: drain the pending bridge-arm request AFTER the walk,
        // BEFORE acting on the directive (review blocker 5).
        self.applyPendingDisarms();
        self.drainPendingBridgeArm(safe_to_arm);
        switch (dispatcher_directive) {
            // M1 sub-case (a): the replayed ramp reached `.link`. `replayLedger` has
            // already charged both counters this burst owns — `native_link_exits` (its
            // `.link_terminal` arm) and `prime_side_chain_follows` (its M1 `.deopt`
            // sub-case (a) fall-through, tied to source-guard provenance). Continue the
            // burst from the inner root the ramp names; charge nothing more here.
            .run_inner_from => |d| {
                const snt = self.nativeFor(d) orelse
                    @panic("driveDispatcherLedger: run_inner_from target has no native code");
                const cursor = BurstCursor{
                    .current_link = d,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                };
                return self.driveBurstCore(d, cursor, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            // A closed `I→C` cycle drained to a re-runnable continuation (2c-E):
            // continue the burst from it. The drained span's terminal inner loop-done
            // ALREADY committed, so the burst must enter at call B (run `c` itself) —
            // `start_at_continuation` makes the first hop iteration skip call A, which
            // would otherwise re-run the just-committed inner (double-commit).
            .run_continuation => |c| {
                const snt = self.nativeFor(c) orelse
                    @panic("driveDispatcherLedger: run_continuation target has no native code");
                const cursor = BurstCursor{
                    .current_link = c,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                    .start_at_continuation = true,
                };
                return self.driveBurstCore(c, cursor, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            // M1 sub-case (b) (ramp deopted before `.link`) and every other terminal
            // shape: `replayLedger` already applied the transition accounting and
            // baked the coherent resume PC into the directive — return it verbatim.
            .return_result => |cr| return cr,
            // Zero-progress / hop-budget terminal → penalty-neutral tail.
            .break_burst => return .{ .completed = linked_completed, .resume_pc = resume_pc },
        }
    }

    /// 2c-E: the hop-0 deep-fusion drain. `driveChain`'s FIRST candidate run
    /// (`hop-0`) captures its per-transition ledger; a `ledger_len == 2` receipt keeps
    /// the historical scalar `fused_inner` path (the byte-identical compatibility
    /// seam — wrapper preamble, hop-top follow counters, hop position, re-arm
    /// supersede all preserved), while a DEEPER span (`> 2`: the seed's `.link` fused
    /// into an inner whose armed loop-done fused onward, possibly across sibling
    /// continuations) is drained here through the same authoritative `replayLedger`
    /// graph-walk the other capture sites use.
    ///
    /// Accounting contract (differs from `runLinkedBurst`'s wrapper): NO
    /// `native_link_exits` preamble charge — `replayLedger`'s `.link_terminal` arm
    /// owns one bump per `.link` marker, including the seed's own first `.link`
    /// (entry 0); a wrapper precharge would double-count it. The coherent-anchor
    /// firing signal (`prime_side_chain_follows`) IS charged here for the
    /// `.ordinary_header` path, mirroring the wrapper (defensive: unreachable today —
    /// a prime-side ramp's own `.link` slot is never armed, so a ramp cannot open a
    /// deep span — but the mirror keeps the two entries' contracts aligned). Origin
    /// `.continuation_call`: the seed is a `.link` driver whose first entry is its own
    /// terminal, so every inner loop-done in the span consumes a hop — this counts
    /// hop-0's first fused inner one hop earlier than the historical scalar
    /// decomposition, which is acceptable for a topology that had no correct prior
    /// execution contract (it changes only where a bounded burst yields, never
    /// committed work or resume coherence).
    fn driveSeedLedger(
        self: *TraceState,
        seed: *Trace,
        entries: []const irinterp.LedgerEntry,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
        materialization: ExitMaterialization,
    ) ChainResult {
        // Release-validate the hop-0 grammar before replaying (codex, 2c-E review):
        // the ledger must have been captured from THIS seed and must open with the
        // seed's own `.link` terminal — every armed slot a hop-0 `.link` candidate
        // can fire first is that terminal (its ordinary guards would classify as M1
        // `.deopt`, which is a dispatcher-root grammar, not a chain-candidate one)
        // — OR (A-vii-d.1) with the seed's armed composite bridge: the seed's
        // composite branch guard fired mid-run and jumped straight into the
        // registered successor's `ordinary_entry`, so the span starts at that
        // `.region_bridge` receipt (2 rows minimum: bridge + successor terminal).
        const e0 = entries[0];
        if (e0.id != seed.id)
            @panic("driveSeedLedger: first entry does not belong to the seed");
        switch (e0.kind) {
            .link_terminal => {
                if (entries.len < 3)
                    @panic("driveSeedLedger: expected a deep (>2-entry) hop-0 ledger");
                if (!(seed.instrs.len != 0 and seed.instrs[seed.instrs.len - 1].op == .link))
                    @panic("driveSeedLedger: seed does not end in .link");
                if (e0.exit != seed.instrs.len - 1)
                    @panic("driveSeedLedger: first entry is not the seed's .link terminal");
            },
            .region_bridge => {
                if (entries.len < 2)
                    @panic("driveSeedLedger: bridge-headed ledger has no successor row");
                if (!nativegen.isCompositeBridgeCandidate(seed, e0.exit))
                    @panic("driveSeedLedger: bridge-headed first entry is not a composite guard of the seed");
            },
            else => @panic("driveSeedLedger: first entry is neither the seed's .link terminal nor its composite bridge"),
        }
        // Coherent-anchor firing signal, mirroring `runLinkedBurst`'s wrapper.
        if (materialization == .ordinary_header) self.prime_side_chain_follows +|= 1;
        const max_hops: usize = 8;
        var linked_completed: usize = 0;
        // For a bridge-headed span the seed's `.link` never fired, so there is no
        // inner-root cursor to seed — pass the seed anchor as an inert placeholder
        // (the bridged terminal contract resumes via `resume_pc`, never `link_pc`).
        const seed_inner_pc: u32 = if (seed.instrs.len != 0 and seed.instrs[seed.instrs.len - 1].op == .link)
            @intCast(seed.instrs[seed.instrs.len - 1].aux)
        else
            seed.anchor.pc;
        var resume_pc: u32 = seed_inner_pc;
        var hops: usize = 0;
        const seed_directive = self.replayLedger(entries, seed, seed_inner_pc, proto, &linked_completed, &resume_pc, &hops, max_hops, .continuation_call, safe_to_arm);
        // A-vii-d.1: drain the pending bridge-arm request AFTER the walk,
        // BEFORE acting on the directive (review blocker 5).
        self.applyPendingDisarms();
        self.drainPendingBridgeArm(safe_to_arm);
        switch (seed_directive) {
            // Terminal inner loop-done, un-fused: enter the burst at call B with the
            // carried continuation (the drained span already ran the inner).
            .run_continuation => |c| {
                const snt = self.nativeFor(c) orelse
                    @panic("driveSeedLedger: run_continuation target has no native code");
                const cursor = BurstCursor{
                    .current_link = c,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                    .start_at_continuation = true,
                };
                return self.driveBurstCore(c, cursor, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            // Standalone `.link` terminal: run the named inner fresh next hop.
            .run_inner_from => |d| {
                const snt = self.nativeFor(d) orelse
                    @panic("driveSeedLedger: run_inner_from target has no native code");
                const cursor = BurstCursor{
                    .current_link = d,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                };
                return self.driveBurstCore(d, cursor, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            .return_result => |cr| return cr,
            // The normal burst tail: penalty-neutral when the span committed,
            // one zero-progress charge on the seed otherwise.
            .break_burst => {
                if (linked_completed > 0)
                    return .{ .completed = linked_completed, .resume_pc = resume_pc };
                self.onSideExit(seed, 0);
                return .{ .completed = 0, .resume_pc = resume_pc };
            },
        }
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
            if (proto.code[guardSourcePc(ins).?].op != .for_loop) continue;

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
        if (proto.code[guardSourcePc(ins).?].op != .for_loop) return;
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
        // Consume the pending arm FIRST (above), then decline to record a dynamic
        // proto (docs/design/17 H-2 part 1). Guarding before the null-clear would
        // leave a matching dynamic pending arm set, permanently pinning `.full`
        // dispatch (`runFastPath`) until execution unwinds.
        if (key.proto.dynamic) return;
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
        // Consume the pending arm FIRST, then decline a dynamic proto — same
        // `.full`-pinning hazard as `maybeStartContinuation` (docs/design/17 H-2 p1).
        if (key.proto.dynamic) return;
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
        if (exit_pc <= proto.code.len and proto.code[guardSourcePc(ins).?].op == .for_loop) return false;
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
    /// guard identity (`exit_instr` → `guardSourcePc` → `proto.code[source_pc]`), all
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

    /// True iff some cached trace at `(proto, pc)` has inner-loop-root shape. Used by
    /// `.link_terminal` successor resolution (A-ii.2) to confirm the named inner root
    /// is bound — the `isInnerLoopRoot` shape (`inputs.len == 0` + `.loop` terminal)
    /// that `findLoopTrace` omits.
    fn hasInnerRootAt(self: *const TraceState, proto: *const Proto, pc: u32) bool {
        for (self.cache.items) |t| {
            if (isInnerLoopRoot(t, proto, pc)) return true;
        }
        return false;
    }

    /// A-vii-d.1: the closing `for_loop` pc of the numeric loop whose body starts
    /// at anchor `pc` — i.e. the unique `for_loop` op whose back-edge target is
    /// `pc`. Null when none or ambiguous (fail-closed: the anchor then cannot be
    /// elected as a closed region's enclosing owner). Static bytecode only; the
    /// body span of the loop is `[pc, result]`.
    fn forLoopEndFor(proto: *const Proto, pc: u32) ?u32 {
        var found: ?u32 = null;
        for (proto.code, 0..) |ins, i| {
            if (ins.op != .for_loop) continue;
            const target: i64 = @as(i64, @intCast(i)) + 1 + ins.aux;
            if (target == pc) {
                if (found != null) return null; // ambiguous
                found = @intCast(i);
            }
        }
        return found;
    }

    const SuccAnchor = struct { proto_id: u32, pc: u32 };

    /// Resolve the guest-logical successor **anchor** `{proto_id, pc}` of one keyed
    /// exit `e` of trace `t` (doc 17 §A8-ii, A-ii.2), following `driveChain`'s
    /// resolution faithfully but keyed by anchor, not the concrete successor trace:
    ///   • `.link_terminal` → the named inner root at `(t.proto, link.aux)`, iff a
    ///     trace of inner-root shape is bound there.
    ///   • a guard exit → `(t.proto, wp)` where `wp = guardExitPc(...)` (non-null only
    ///     for the numeric/branch guards `driveChain` chains on), iff `wp != 0`,
    ///     `wp != t.anchor.pc`, and a trace is bound at `(t.proto, wp)`.
    /// The successor proto is `t.anchor.proto` — the same-proto assumption
    /// `driveChain` makes (it threads one `proto` into `nextTraceExcluding`); a
    /// cross-proto inlined-callee resume is a known deferred refinement (§A8-ii).
    /// Returns `null` (no structural edge) for any exit whose successor is not a
    /// compatibly-bound trace, or a non-PC-carrying guard.
    fn resolveSuccessorAnchor(self: *const TraceState, t: *const Trace, e: ExitProvEntry) ?SuccAnchor {
        const proto = t.anchor.proto;
        switch (e.prov) {
            .link_terminal => {
                const li = t.instrs[e.index];
                if (li.op != .link) return null; // defensive: a .link_terminal must sit on a .link
                if (li.aux < 0) return null;
                const succ_pc: u32 = @intCast(li.aux);
                if (!self.hasInnerRootAt(proto, succ_pc)) return null;
                return .{ .proto_id = proto.id, .pc = succ_pc };
            },
            .guard => {
                if (guardExitPc(t.instrs[e.index])) |wp| {
                    if (wp != 0 and wp != t.anchor.pc and
                        self.countTracesAt(.{ .proto = proto, .pc = wp }) != 0)
                        return .{ .proto_id = proto.id, .pc = wp };
                }
                // A-vii-d.1 overlay: composite bridge candidates get the
                // opposite-polarity static-CFG successor (with the crossed
                // for_loop continue proof gating publication). Every other
                // guard keeps the ordinary rule above — their deopt semantics
                // use the H-1b re-execute convention and their exits stay out
                // of the structural graph unless a trace anchors at the exit pc.
                return self.resolveCompositeBridgeSuccessor(t, e);
            },
        }
    }

    /// A-vii-d.1 (doc 17): overlay structural-successor resolution for a composite
    /// bridge candidate exit. A branch guard's committed exit pc is the H-1b
    /// re-execute pc (`source_pc + 1`), never the opposite path's landing anchor,
    /// so the ordinary `resolveSuccessorAnchor` rule can never discover the
    /// cont→skip edge-4 transition. This overlay derives the successor from the
    /// static CFG instead: take the OPPOSITE-polarity target of the source
    /// `jmp_if_*` (the deopt re-executes the branch and, by construction of the
    /// guard, takes the edge the recording did not), then walk across ONLY
    /// unconditional `jmp` ops and at most ONE numeric `for_loop` continue edge
    /// (bounded, no revisits — any other op declines: the handoff would not be a
    /// clean anchor-to-anchor transition) until a pc with a bound trace.
    ///
    /// **The continue proof gates discovery** (d.1 review blocker 1): a crossed
    /// `for_loop` has TWO successors, and publishing the continue edge without
    /// proof would corrupt SCC construction / owner election / gate keying, not
    /// merely the arm. `compositeContinueProof` demands the exact `recForLoop`
    /// dataflow shape in the parent IR, dominating the composite guard — which
    /// simultaneously proves the loop-exit edge is excluded (the continue guard
    /// PASSED on every native execution that reaches the composite guard) and
    /// that the crossed op's written slots `{a, a+3}` are re-materialized by the
    /// bridge snapshot with the exact stepped value.
    fn resolveCompositeBridgeSuccessor(self: *const TraceState, t: *const Trace, e: ExitProvEntry) ?SuccAnchor {
        const g = switch (e.prov) {
            .guard => |gp| gp,
            .link_terminal => return null,
        };
        // Non-inlined, same-proto, polarity-carrying branch provenance only
        // (d.1 review blocker: never widen an inlined exit using the parent
        // proto's bytecode).
        if (g.inline_depth != 0) return null;
        if (g.role != .branch_cond or g.polarity == .neutral) return null;
        const proto = t.anchor.proto;
        if (g.source_proto_id != proto.id) return null;
        if (!nativegen.isCompositeBridgeCandidate(t, e.index)) return null;
        if (g.source_pc >= proto.code.len) return null;
        const bop = proto.code[g.source_pc];
        switch (bop.op) {
            .jmp_if_true, .jmp_if_false => {},
            else => return null,
        }
        // Post-fetch jump convention (`applyJump(source_pc + 1, aux)`): the
        // interpreter applies branch offsets to the already-incremented pc.
        const fallthrough_pc: i64 = @as(i64, g.source_pc) + 1;
        const jump_pc: i64 = fallthrough_pc + bop.aux;
        // The guard fails ⇒ the deopt takes the CFG edge the recording did NOT:
        // recorded `.fallthrough` fails onto the jump edge and vice versa.
        var pc_i: i64 = if (g.polarity == .fallthrough) jump_pc else fallthrough_pc;

        var crossed_for_loop: ?u32 = null;
        var steps: usize = 0;
        while (steps < 16) : (steps += 1) {
            if (pc_i < 0 or pc_i >= proto.code.len) return null;
            const pc: u32 = @intCast(pc_i);
            // Landing back on the source's own anchor is a self-edge, not a
            // cross-anchor handoff — decline (same rule as the ordinary arm).
            if (pc == t.anchor.pc) return null;
            if (self.countTracesAt(.{ .proto = proto, .pc = pc }) != 0) {
                if (crossed_for_loop) |flp| {
                    if (!compositeContinueProof(t, e.index, flp)) return null;
                }
                return .{ .proto_id = proto.id, .pc = pc };
            }
            const ins = proto.code[pc];
            switch (ins.op) {
                .jmp => pc_i = pc_i + 1 + ins.aux,
                .for_loop => {
                    if (crossed_for_loop != null) return null; // at most one
                    crossed_for_loop = pc;
                    pc_i = pc_i + 1 + ins.aux; // continue edge = the back-edge target
                },
                else => return null,
            }
        }
        return null;
    }

    /// The exact-dataflow continue proof for one crossed numeric `for_loop` at
    /// bytecode pc `flp` (d.1 review blocker 2: provenance-tag matching is
    /// many-to-one and insufficient — the proof is relational, tied by IR refs).
    /// Requires, all with committed indices `< composite_ei`:
    ///   - the dominance-scoped emitted set E holds slot-bound phis for BOTH
    ///     slots the crossed `for_loop` writes — `a` (idx) and `a+3` (var) —
    ///     with the SAME update ref `R`, and `t.instrs[R]` is the `add` that
    ///     steps the index (`recForLoop` publishes the one `rnext` to both);
    ///   - a committed `.loop_done` guard (non-inlined, same proto, source pc
    ///     == `flp`) whose guarded `le` compare CONSUMES `R` — i.e. the loop
    ///     continue condition over exactly the value the bridge will commit
    ///     passed before the composite guard could fire.
    /// Limit/step are not written by `for_loop`, so they may legitimately remain
    /// edge-invariant; this proof is what gives `invariant = S \ E` its
    /// soundness for the crossed-op slots (doc 17 A-vii-d.1 item 2).
    fn compositeContinueProof(t: *const Trace, composite_ei: u32, flp: u32) bool {
        const proto = t.anchor.proto;
        if (flp >= proto.code.len or proto.code[flp].op != .for_loop) return false;
        const base: u16 = proto.code[flp].a;

        // Fetch the dominance-scoped phi update refs for idx and var.
        var idx_ref: ?u16 = null;
        var var_ref: ?u16 = null;
        var emitted = nativegen.compositeBridgeEmissions(t, composite_ei);
        while (emitted.next()) |p| {
            if (p.aux == @as(i32, @intCast(base))) idx_ref = p.b;
            if (p.aux == @as(i32, @intCast(base)) + 3) var_ref = p.b;
        }
        const r = idx_ref orelse return false;
        if (var_ref != r) return false;
        if (r >= t.instrs.len or t.instrs[r].op != .add) return false;

        // Find a dominating loop-continue guard for THIS for_loop whose compare
        // consumes exactly `r`.
        for (t.exit_prov) |ep| {
            if (ep.index >= composite_ei) break; // sorted ascending
            const gp = switch (ep.prov) {
                .guard => |gg| gg,
                .link_terminal => continue,
            };
            if (gp.role != .loop_done or gp.inline_depth != 0) continue;
            if (gp.source_proto_id != proto.id or gp.source_pc != flp) continue;
            const gi = t.instrs[ep.index];
            if (gi.op != .guard_true) continue;
            const cmp_ref = gi.a;
            if (cmp_ref >= t.instrs.len) continue;
            const cmp = t.instrs[cmp_ref];
            if (cmp.op != .le) continue;
            if (cmp.a == r or cmp.b == r) return true;
        }
        return false;
    }

    /// Rebuild the ephemeral `edge_cache` WHOLESALE from the current cache (doc 17
    /// §A8-ii, A-ii.2): for every keyed exit of every cached trace with a compatibly-bound
    /// successor, record `{Trace.id, exit_instr} → StructuralEdgeId`. Called at every commit
    /// and every retirement (never surgically mutated). **Inert: read by nothing in A-ii ⇒
    /// byte-identical.**
    ///
    /// **Transactional + fail-closed** (round-12 finding 2, round-14 finding 6): the rebuild
    /// reserves capacity BEFORE clearing (so the happy-path publish loop is infallible), but
    /// on ANY OOM it fails CLOSED to an EMPTY cache — never retains the prior snapshot. The
    /// retain option was removed because it is not safe: a boundary edge (excluded from
    /// `RegionId`) added by the very commit that triggers this rebuild can invalidate a prior
    /// region's owner (`both_count` 1→2), so a retained snapshot is not merely "the new trace
    /// stays unclassified" — it can keep a now-stale region armed. Empty is region-neutral
    /// (arm nothing) and auto-recovers on the next successful rebuild.
    fn rebuildEdgeCache(self: *TraceState) void {
        self.rebuildEdgeCacheFallible() catch self.edge_cache.clearRetainingCapacity();
    }

    fn rebuildEdgeCacheFallible(self: *TraceState) !void {
        // Upper bound on live edges: one per recorded exit across every cached trace
        // (`resolveSuccessorAnchor` yields 0 or 1 edge per entry, never more).
        var upper: usize = 0;
        for (self.cache.items) |t| upper += t.exit_prov.len;
        // Cap the reservation well below where the map's u32 `capacityForSize` — which does
        // `ceilPowerOfTwo(u32, ...) catch unreachable` past ~1.7e9 — would PANIC, and below
        // the `@intCast` u32 cast's own trap point (round-14 review finding 4). An
        // over-large graph is turned into a SOFT OOM here so it flows through
        // `rebuildEdgeCache`'s fail-closed `catch` instead of trapping — preserving the
        // inert/fail-soft contract. Unreachable in practice: a billion trace exits is many
        // GB of metadata, so we'd OOM in the append loops long before reaching it.
        const max_edges: usize = 1 << 30;
        if (upper > max_edges) return error.OutOfMemory;
        // Reserve BEFORE clearing so an OOM here retains the prior published snapshot.
        try self.edge_cache.ensureTotalCapacity(self.gpa, @intCast(upper));
        self.edge_cache.clearRetainingCapacity();
        for (self.cache.items) |t| {
            for (t.exit_prov) |e| {
                const succ = self.resolveSuccessorAnchor(t, e) orelse continue;
                const eid: StructuralEdgeId = .{
                    .anchor_proto_id = t.anchor.proto.id,
                    .anchor_pc = t.anchor.pc,
                    .exit = e.prov,
                    .succ_anchor_proto_id = succ.proto_id,
                    .succ_anchor_pc = succ.pc,
                };
                self.edge_cache.putAssumeCapacity(.{ .trace_id = t.id, .exit_instr = e.index }, eid);
            }
        }
    }

    fn clearPhysicalRegionIndices(self: *TraceState) void {
        freeRegionSetMap(ExitKey, &self.source_exit_regions, self.gpa);
        freeRegionSetMap(u32, &self.dest_entry_regions, self.gpa);
        self.source_exit_regions = .empty;
        self.dest_entry_regions = .empty;
    }

    /// Rebuild the region model from the current trace graph (doc 17 §A8-ii, A-ii.4):
    /// discover the strongly-connected cycles of the `StructuralEdgeId` graph, intern
    /// each to a stable `RegionId`, accumulate persistent `RegionDef`s, and rebuild the
    /// physical classification indices wholesale. **Transactional + fail-closed:** all
    /// fallible allocation completes in scratch before any live map is touched; the publish
    /// phase is infallible. An OOM never propagates through `commit`/`removeTrace` and never
    /// leaves half-applied state — the LOGICAL maps (`region_defs`/`region_intern`) are
    /// untouched (all their mutation is post-reserve infallible publish) and the PHYSICAL
    /// indices fail CLOSED to EMPTY (round-14 finding 6: retaining the prior physical
    /// snapshot is unsafe — the commit that triggers this rebuild can add a boundary edge
    /// that invalidates a prior region's owner, so a retained snapshot could keep a stale
    /// region armed; empty is region-neutral and auto-recovers on the next successful pass).
    /// **Inert in A-ii** (read by nothing on the selection path) ⇒ byte-identical.
    fn rebuildRegions(self: *TraceState) void {
        self.rebuildRegionsFallible() catch {
            self.clearPhysicalRegionIndices();
            // A-vii-d.1 (review blocker 3): the physical indices failed closed
            // to empty, so no region is live-armable — every armed bridge
            // link's provenance is now unvalidatable. Disarm them all.
            self.disarmStaleRegionBridgeLinks(&.{});
        };
    }

    fn rebuildRegionsFallible(self: *TraceState) !void {
        const gpa = self.gpa;

        // A-i exit_prov fail-soft (graph completeness): if ANY cached trace committed a
        // truncated `exit_prov` (a `buildExitProv` OOM), the structural edge graph is
        // missing that trace's edges, so the SCCs / owners discovered this pass could
        // differ from the complete graph — a dropped *boundary* edge can spuriously flip a
        // region armable. Conservatively bail: RETAIN the prior LOGICAL defs (`region_defs`
        // / `region_intern` — untouched, so a stable prior classification survives) and
        // publish EMPTY physical indices (`classifyExit` region-neutral ⇒ arm nothing). We
        // also mint NOTHING new here, so no def is ever built from a sparse graph. The
        // first COMPLETE pass after the incomplete trace retires re-discovers and re-arms.
        for (self.cache.items) |t| {
            if (!t.exit_prov_complete) {
                self.clearPhysicalRegionIndices();
                // A-vii-d.1 (review blocker 3): fail closed on the truncated
                // graph — no region is live-armable this pass, so no armed
                // bridge link's provenance can be re-validated. Disarm all.
                self.disarmStaleRegionBridgeLinks(&.{});
                return;
            }
        }

        // Guest-logical anchor node identity {proto_id, pc} — NOT a concrete `Trace`
        // pointer (round-11 finding 1: node identity must not depend on mutable
        // `hit_count` / `findTrace` selection).
        const AnchorId = struct { proto_id: u32, pc: u32 };
        const Edge = struct { from: u32, to: u32, eid: StructuralEdgeId, key: ExitKey };

        // proto_id → *Proto (1:1 within an epoch), for the owner `AnchorKey` + the
        // `hasInnerRootAt` loop-root predicate. Every graph node is an anchor of a bound
        // trace, so every node's proto_id is present.
        var proto_by_id: std.AutoHashMapUnmanaged(u32, *const Proto) = .empty;
        defer proto_by_id.deinit(gpa);
        for (self.cache.items) |t| try proto_by_id.put(gpa, t.anchor.proto.id, t.anchor.proto);

        // 1. Nodes + edges from the ephemeral structural-edge cache.
        var nodes: std.ArrayListUnmanaged(AnchorId) = .empty;
        defer nodes.deinit(gpa);
        var node_index: std.AutoHashMapUnmanaged(AnchorId, u32) = .empty;
        defer node_index.deinit(gpa);
        var edges: std.ArrayListUnmanaged(Edge) = .empty;
        defer edges.deinit(gpa);

        var ec_it = self.edge_cache.iterator();
        while (ec_it.next()) |kv| {
            const eid = kv.value_ptr.*;
            const from_id = AnchorId{ .proto_id = eid.anchor_proto_id, .pc = eid.anchor_pc };
            const to_id = AnchorId{ .proto_id = eid.succ_anchor_proto_id, .pc = eid.succ_anchor_pc };
            const fi = blk: {
                const gop = try node_index.getOrPut(gpa, from_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(nodes.items.len);
                    try nodes.append(gpa, from_id);
                }
                break :blk gop.value_ptr.*;
            };
            const ti = blk: {
                const gop = try node_index.getOrPut(gpa, to_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(nodes.items.len);
                    try nodes.append(gpa, to_id);
                }
                break :blk gop.value_ptr.*;
            };
            try edges.append(gpa, .{ .from = fi, .to = ti, .eid = eid, .key = kv.key_ptr.* });
        }
        const nnodes = nodes.items.len;

        // 2. CSR adjacency (edge indices per from-node), then iterative Tarjan SCC.
        var offsets = try gpa.alloc(u32, nnodes + 1);
        defer gpa.free(offsets);
        @memset(offsets, 0);
        for (edges.items) |e| offsets[e.from + 1] += 1;
        for (1..nnodes + 1) |i| offsets[i] += offsets[i - 1];
        var adj = try gpa.alloc(u32, edges.items.len);
        defer gpa.free(adj);
        {
            var cursor = try gpa.alloc(u32, nnodes);
            defer gpa.free(cursor);
            for (0..nnodes) |i| cursor[i] = offsets[i];
            for (edges.items, 0..) |e, ei| {
                adj[cursor[e.from]] = @intCast(ei);
                cursor[e.from] += 1;
            }
        }

        const comp = try gpa.alloc(u32, nnodes);
        defer gpa.free(comp);
        var ncomp: u32 = 0;
        {
            const UNVISITED: i64 = -1;
            const idx_of = try gpa.alloc(i64, nnodes);
            defer gpa.free(idx_of);
            @memset(idx_of, UNVISITED);
            const lowlink = try gpa.alloc(i64, nnodes);
            defer gpa.free(lowlink);
            const on_stack = try gpa.alloc(bool, nnodes);
            defer gpa.free(on_stack);
            @memset(on_stack, false);
            var tstack: std.ArrayListUnmanaged(u32) = .empty;
            defer tstack.deinit(gpa);
            const Frame = struct { v: u32, cursor: u32 };
            var dfs: std.ArrayListUnmanaged(Frame) = .empty;
            defer dfs.deinit(gpa);
            var next_index: i64 = 0;

            for (0..nnodes) |s| {
                if (idx_of[s] != UNVISITED) continue;
                idx_of[s] = next_index;
                lowlink[s] = next_index;
                next_index += 1;
                try tstack.append(gpa, @intCast(s));
                on_stack[s] = true;
                try dfs.append(gpa, .{ .v = @intCast(s), .cursor = 0 });
                while (dfs.items.len > 0) {
                    const top = &dfs.items[dfs.items.len - 1];
                    const v = top.v;
                    const start = offsets[v];
                    const end = offsets[v + 1];
                    if (top.cursor < end - start) {
                        const ei = adj[start + top.cursor];
                        top.cursor += 1;
                        const w = edges.items[ei].to;
                        if (idx_of[w] == UNVISITED) {
                            idx_of[w] = next_index;
                            lowlink[w] = next_index;
                            next_index += 1;
                            try tstack.append(gpa, w);
                            on_stack[w] = true;
                            try dfs.append(gpa, .{ .v = w, .cursor = 0 });
                        } else if (on_stack[w]) {
                            lowlink[v] = @min(lowlink[v], idx_of[w]);
                        }
                    } else {
                        if (lowlink[v] == idx_of[v]) {
                            while (true) {
                                const w = tstack.pop().?;
                                on_stack[w] = false;
                                comp[w] = ncomp;
                                if (w == v) break;
                            }
                            ncomp += 1;
                        }
                        _ = dfs.pop();
                        if (dfs.items.len > 0) {
                            const parent = dfs.items[dfs.items.len - 1].v;
                            lowlink[parent] = @min(lowlink[parent], lowlink[v]);
                        }
                    }
                }
            }
        }

        // Component sizes + self-edge flags → cycle-bearing candidates.
        const comp_size = try gpa.alloc(u32, ncomp);
        defer gpa.free(comp_size);
        @memset(comp_size, 0);
        for (0..nnodes) |n| comp_size[comp[n]] += 1;
        const has_self = try gpa.alloc(bool, ncomp);
        defer gpa.free(has_self);
        @memset(has_self, false);
        for (edges.items) |e| {
            if (e.from == e.to) has_self[comp[e.from]] = true;
        }

        // 3. Gather one Candidate per cycle-bearing SCC (all scratch, fallible).
        const Candidate = struct {
            comp: u32,
            sorted_internal: []StructuralEdgeId,
            member_points: []ProgramPoint,
            member_trace_ids: []u32,
            bridges: []RegionBridgeDef,
            owner: AnchorKey,
            classifier: RegionClassifier,
            armable_owner: bool,
            /// Finding 3 (recorder-path completeness): true iff every physical member
            /// trace was found by id AND carries a complete recorded path
            /// (`rec_path_complete`). A truncated/absent membership must never mint or keep
            /// an armable region — the discovered `member_points` would be a subset of the
            /// real footprint, so arming on it could patch an exit whose region the def
            /// under-describes. Gates `armable` on first-sight AND forces a rebind tombstone.
            membership_complete: bool,
        };
        var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
        defer {
            for (candidates.items) |c| {
                gpa.free(c.sorted_internal);
                gpa.free(c.member_points);
                gpa.free(c.member_trace_ids);
                freeRegionBridges(gpa, c.bridges);
            }
            candidates.deinit(gpa);
        }

        for (0..ncomp) |cc| {
            const c: u32 = @intCast(cc);
            if (!(comp_size[c] >= 2 or has_self[c])) continue;

            // 3a. Internal edges (both endpoints in c), sorted + deduped → identity set.
            var internal_list: std.ArrayListUnmanaged(StructuralEdgeId) = .empty;
            defer internal_list.deinit(gpa);
            var mt_list: std.ArrayListUnmanaged(u32) = .empty;
            defer mt_list.deinit(gpa);
            for (edges.items) |e| {
                if (comp[e.from] == c and comp[e.to] == c) {
                    try internal_list.append(gpa, e.eid);
                    try mt_list.append(gpa, e.key.trace_id);
                }
            }
            std.mem.sort(StructuralEdgeId, internal_list.items, {}, StructuralEdgeId.lessThan);
            var uniq_internal: std.ArrayListUnmanaged(StructuralEdgeId) = .empty;
            defer uniq_internal.deinit(gpa);
            for (internal_list.items) |eid| {
                if (uniq_internal.items.len == 0 or !uniq_internal.items[uniq_internal.items.len - 1].eql(eid))
                    try uniq_internal.append(gpa, eid);
            }
            const sorted_internal = try gpa.dupe(StructuralEdgeId, uniq_internal.items);
            errdefer gpa.free(sorted_internal);

            // 3b. Physical member trace ids = the realizers of the internal edges.
            std.mem.sort(u32, mt_list.items, {}, std.sort.asc(u32));
            var uniq_mt: std.ArrayListUnmanaged(u32) = .empty;
            defer uniq_mt.deinit(gpa);
            for (mt_list.items) |tid| {
                if (uniq_mt.items.len == 0 or uniq_mt.items[uniq_mt.items.len - 1] != tid)
                    try uniq_mt.append(gpa, tid);
            }
            const member_trace_ids = try gpa.dupe(u32, uniq_mt.items);
            errdefer gpa.free(member_trace_ids);

            // 3c. Membership program-points: internal-edge handoff endpoints ∪ member
            // traces' recorded paths (A-ii.3), sorted + deduped.
            var mp_list: std.ArrayListUnmanaged(ProgramPoint) = .empty;
            defer mp_list.deinit(gpa);
            for (uniq_internal.items) |eid| {
                try mp_list.append(gpa, .{ .proto_id = eid.anchor_proto_id, .source_pc = eid.anchor_pc });
                try mp_list.append(gpa, .{ .proto_id = eid.succ_anchor_proto_id, .source_pc = eid.succ_anchor_pc });
            }
            // membership_complete (finding 3): every member trace must be findable AND
            // carry a complete recorded path, else the collected `member_points` are a
            // subset of the true footprint and the region must not be armable.
            var membership_complete = true;
            for (member_trace_ids) |tid| {
                if (self.traceById(tid)) |t| {
                    if (!t.rec_path_complete) membership_complete = false;
                    for (t.rec_path) |pp| try mp_list.append(gpa, pp);
                } else {
                    membership_complete = false;
                }
            }
            std.mem.sort(ProgramPoint, mp_list.items, {}, programPointLess);
            var uniq_mp: std.ArrayListUnmanaged(ProgramPoint) = .empty;
            defer uniq_mp.deinit(gpa);
            for (mp_list.items) |pp| {
                if (uniq_mp.items.len == 0 or !(uniq_mp.items[uniq_mp.items.len - 1].proto_id == pp.proto_id and uniq_mp.items[uniq_mp.items.len - 1].source_pc == pp.source_pc))
                    try uniq_mp.append(gpa, pp);
            }
            const member_points = try gpa.dupe(ProgramPoint, uniq_mp.items);
            errdefer gpa.free(member_points);

            // 3d. Whole-cycle backward liveness.  Seed each anchor with the union of
            // its physical member traces' entry slots, then propagate successor live-in
            // sets backwards over every internal edge until stable. A dominating
            // slot-bound phi defines (kills) that slot on the edge; the shared A-v E
            // query is the one definition of that dominance fact. Thus live_in[to] is
            // exactly successor entry_slots union values live through later cycle edges.
            const live_in = try gpa.alloc(std.ArrayListUnmanaged(u16), nnodes);
            defer {
                for (live_in) |*set| set.deinit(gpa);
                gpa.free(live_in);
            }
            for (live_in) |*set| set.* = .empty;
            for (member_trace_ids) |tid| {
                const t = self.traceById(tid) orelse continue;
                const ni = node_index.get(.{ .proto_id = t.anchor.proto.id, .pc = t.anchor.pc }) orelse
                    return error.RegionGraphInconsistent;
                for (t.entry_slots) |slot| _ = try appendUniqueSlot(&live_in[ni], gpa, slot);
            }
            var changed = true;
            while (changed) {
                changed = false;
                for (edges.items) |e| {
                    if (comp[e.from] != c or comp[e.to] != c) continue;
                    const parent = self.traceById(e.key.trace_id) orelse continue;
                    for (live_in[e.to].items) |slot| {
                        if (nativegen.compositeBridgeEmitsSlot(parent, e.key.exit_instr, slot)) continue;
                        if (try appendUniqueSlot(&live_in[e.from], gpa, slot)) changed = true;
                    }
                }
            }
            for (live_in) |*set| std.mem.sort(u16, set.items, {}, std.sort.asc(u16));

            // Retain one canonical descriptor per bridge-capable structural edge.
            // `required_slots` is the successor fixed-point set. A required slot is
            // edge-invariant iff no realization of this structural edge emits it.
            var bridge_list: std.ArrayListUnmanaged(RegionBridgeDef) = .empty;
            defer bridge_list.deinit(gpa);
            errdefer for (bridge_list.items) |b| {
                gpa.free(b.required_slots);
                gpa.free(b.invariant_slots);
            };
            for (edges.items) |e| {
                if (comp[e.from] != c or comp[e.to] != c) continue;
                const parent = self.traceById(e.key.trace_id) orelse continue;
                if (!nativegen.isCompositeBridgeCandidate(parent, e.key.exit_instr)) continue;

                var existing: ?*RegionBridgeDef = null;
                for (bridge_list.items) |*b| {
                    if (b.edge.eql(e.eid)) {
                        existing = b;
                        break;
                    }
                }
                if (existing) |b| {
                    // Multiple physical realizations of one logical edge: retain only
                    // invariants proven unchanged by every realization.
                    var common: std.ArrayListUnmanaged(u16) = .empty;
                    defer common.deinit(gpa);
                    for (b.invariant_slots) |slot| {
                        if (!nativegen.compositeBridgeEmitsSlot(parent, e.key.exit_instr, slot))
                            try common.append(gpa, slot);
                    }
                    const replacement = try gpa.dupe(u16, common.items);
                    gpa.free(b.invariant_slots);
                    b.invariant_slots = replacement;
                    continue;
                }

                const required = try gpa.dupe(u16, live_in[e.to].items);
                errdefer gpa.free(required);
                var inv_list: std.ArrayListUnmanaged(u16) = .empty;
                defer inv_list.deinit(gpa);
                for (required) |slot| {
                    if (!nativegen.compositeBridgeEmitsSlot(parent, e.key.exit_instr, slot))
                        try inv_list.append(gpa, slot);
                }
                const invariants = try gpa.dupe(u16, inv_list.items);
                errdefer gpa.free(invariants);
                const succ_node = nodes.items[e.to];
                const succ_proto = proto_by_id.get(succ_node.proto_id) orelse
                    return error.RegionGraphInconsistent;
                try bridge_list.append(gpa, .{
                    .edge = e.eid,
                    .successor = .{ .proto = succ_proto, .pc = succ_node.pc },
                    .required_slots = required,
                    .invariant_slots = invariants,
                });
            }
            std.mem.sort(RegionBridgeDef, bridge_list.items, {}, struct {
                fn less(_: void, a: RegionBridgeDef, b: RegionBridgeDef) bool {
                    return a.edge.order(b.edge) == .lt;
                }
            }.less);
            const bridges = try gpa.dupe(RegionBridgeDef, bridge_list.items);
            bridge_list.clearRetainingCapacity();
            errdefer freeRegionBridges(gpa, bridges);

            // 3e. Owner predicate (round-12 finding 4): the unique SCC anchor that is
            // both external-entry (dest of an incoming boundary edge) AND loop-root
            // (a bound trace of inner-root shape); else a deterministic placeholder +
            // armable=false.
            var both_count: usize = 0;
            var owner_node: u32 = 0;
            var smallest: ?AnchorId = null;
            for (0..nnodes) |n| {
                if (comp[n] != c) continue;
                const a = nodes.items[n];
                if (smallest == null or a.proto_id < smallest.?.proto_id or (a.proto_id == smallest.?.proto_id and a.pc < smallest.?.pc))
                    smallest = a;
                var is_ext = false;
                for (edges.items) |e| {
                    if (e.to == @as(u32, @intCast(n)) and comp[e.from] != c) {
                        is_ext = true;
                        break;
                    }
                }
                const proto = proto_by_id.get(a.proto_id) orelse return error.RegionGraphInconsistent;
                const has_root = self.hasInnerRootAt(proto, a.pc);
                // A-vii-d.1: a fully-CLOSED cycle (the whole traced kernel is one
                // SCC — exactly what closing edge 4 produces) has NO incoming
                // boundary edge at all: the region is entered by the DISPATCHER,
                // which creates no structural edge. Generalize "external entry"
                // with a static enclosure test: a member is dispatcher-entry-
                // shaped if its numeric loop's body span contains every other
                // same-proto member (the outermost loop root of the cycle).
                // Cross-proto members and non-numeric (while) roots conservatively
                // fail the test — the region then simply stays unarmable, the
                // pre-d.1 status quo.
                const enclosing = !is_ext and blk: {
                    const flp = forLoopEndFor(proto, a.pc) orelse break :blk false;
                    for (0..nnodes) |m| {
                        if (comp[m] != c or m == n) continue;
                        const b = nodes.items[m];
                        if (b.proto_id != a.proto_id) break :blk false;
                        if (b.pc <= a.pc or b.pc > flp) break :blk false;
                    }
                    break :blk true;
                };
                self.dbg("region: owner-scan comp={d} node proto={d} pc={d} ext_entry={} enclosing={} inner_root={}", .{
                    c, a.proto_id, a.pc, is_ext, enclosing, has_root,
                });
                if ((is_ext or enclosing) and has_root) {
                    both_count += 1;
                    owner_node = @intCast(n);
                }
            }
            const owner_anchor: AnchorId = if (both_count == 1) nodes.items[owner_node] else (smallest orelse return error.RegionGraphInconsistent);
            const owner_proto = proto_by_id.get(owner_anchor.proto_id) orelse return error.RegionGraphInconsistent;
            const owner: AnchorKey = .{ .proto = owner_proto, .pc = owner_anchor.pc };

            try candidates.append(gpa, .{
                .comp = c,
                .sorted_internal = sorted_internal,
                .member_points = member_points,
                .member_trace_ids = member_trace_ids,
                .bridges = bridges,
                .owner = owner,
                .classifier = .{
                    .kind = if (comp_size[c] == 1) .self_loop else .cross_trace_cycle,
                    .member_count = comp_size[c],
                },
                .armable_owner = both_count == 1,
                .membership_complete = membership_complete,
            });
        }

        // Deterministic tentative-id assignment: sort candidates by their canonical
        // internal edge set, so a pass that first-sees ≥2 NEW regions mints ids in a
        // graph-order-independent order (replay-stable).
        std.mem.sort(Candidate, candidates.items, {}, struct {
            fn less(_: void, a: Candidate, b: Candidate) bool {
                var i: usize = 0;
                while (i < a.sorted_internal.len and i < b.sorted_internal.len) : (i += 1) {
                    switch (a.sorted_internal[i].order(b.sorted_internal[i])) {
                        .lt => return true,
                        .gt => return false,
                        .eq => {},
                    }
                }
                return a.sorted_internal.len < b.sorted_internal.len;
            }
        }.less);

        // 4. Intern + stage (all scratch, fallible). Reserve staged capacity up front so
        // the per-candidate appends are infallible AFTER the ownership-transferring dupes
        // (no half-transferred double-free window).
        const StagedIntern = struct { edges: []StructuralEdgeId, id: RegionId };
        const StagedDef = struct { id: RegionId, def: RegionDef };
        const ActiveRegion = struct { id: RegionId, comp: u32, armable: bool, member_trace_ids: []u32 };
        var staged_interns: std.ArrayListUnmanaged(StagedIntern) = .empty;
        defer {
            for (staged_interns.items) |s| gpa.free(s.edges);
            staged_interns.deinit(gpa);
        }
        var staged_defs: std.ArrayListUnmanaged(StagedDef) = .empty;
        defer {
            for (staged_defs.items) |s| {
                gpa.free(s.def.members);
                gpa.free(s.def.member_points);
                freeRegionBridges(gpa, s.def.bridges);
            }
            staged_defs.deinit(gpa);
        }
        const StagedBridgeUpdate = struct { id: RegionId, bridges: []RegionBridgeDef };
        var staged_bridge_updates: std.ArrayListUnmanaged(StagedBridgeUpdate) = .empty;
        defer {
            for (staged_bridge_updates.items) |s| freeRegionBridges(gpa, s.bridges);
            staged_bridge_updates.deinit(gpa);
        }
        var staged_tombstones: std.ArrayListUnmanaged(RegionId) = .empty;
        defer staged_tombstones.deinit(gpa);
        const StagedOwnerUpdate = struct { id: RegionId, owner: AnchorKey };
        var staged_owner_updates: std.ArrayListUnmanaged(StagedOwnerUpdate) = .empty;
        defer staged_owner_updates.deinit(gpa);
        // A-vii-d.0: rebind-recomputed armability, staged like the owner updates so
        // a fallible mid-pass failure publishes nothing.
        const StagedArmableUpdate = struct { id: RegionId, armable: bool };
        var staged_armable_updates: std.ArrayListUnmanaged(StagedArmableUpdate) = .empty;
        defer staged_armable_updates.deinit(gpa);
        var active_regions: std.ArrayListUnmanaged(ActiveRegion) = .empty;
        defer {
            for (active_regions.items) |a| gpa.free(a.member_trace_ids);
            active_regions.deinit(gpa);
        }
        try staged_interns.ensureUnusedCapacity(gpa, candidates.items.len);
        try staged_defs.ensureUnusedCapacity(gpa, candidates.items.len);
        try staged_tombstones.ensureUnusedCapacity(gpa, candidates.items.len);
        try staged_owner_updates.ensureUnusedCapacity(gpa, candidates.items.len);
        try staged_armable_updates.ensureUnusedCapacity(gpa, candidates.items.len);
        try staged_bridge_updates.ensureUnusedCapacity(gpa, candidates.items.len);
        try active_regions.ensureUnusedCapacity(gpa, candidates.items.len);

        var new_id_counter: u64 = self.next_region_id;
        for (candidates.items) |cand| {
            if (self.region_intern.lookup(cand.sorted_internal)) |existing_id| {
                // Rebind: confirm compatible membership or fail closed (§A3.5).
                const stored = self.region_defs.getPtr(existing_id) orelse return error.RegionGraphInconsistent;
                const compatible = programPointsEqual(stored.member_points, cand.member_points);
                // Finding 3: an incomplete membership tombstones the region too — the
                // stored def may have been minted from a complete pass and must not stay
                // armable once a truncated pass appears (fail-closed, sticky).
                if (!compatible or !cand.membership_complete) staged_tombstones.appendAssumeCapacity(existing_id);
                // Finding 5 (review, boundary-edge evolution) + A-vii-d.0 correction:
                // armability is RECOMPUTED from the current graph on every rebind, in
                // BOTH directions. Boundary edges are excluded from `RegionId`, so a
                // graph change flips `both_count` without changing the id: 1→2 must
                // disarm (a stale `stored.armable=true` would wrong-arm — finding 5's
                // original point), and 0→1 must ARM — the case the original
                // `stored.armable and …` conjunction made unreachable. A cycle is
                // necessarily first seen BEFORE its external-entry side trace records
                // (the internal cycle is what triggers minting; the entry source is a
                // guard-hot side trace recorded later), so first sight is always
                // owner-not-unique and a monotone-decreasing bit could never rise:
                // measured on nsieve, `both_count` goes 0→0→1 across rebuilds while
                // the frozen bit stayed false. Only `tombstoned` is sticky — an
                // incompatible or truncated rebind, or any runtime `invalidateRegion`,
                // permanently pins the region off regardless of what the graph says.
                const eff_armable = compatible and cand.membership_complete and
                    cand.armable_owner and !stored.tombstoned;
                if (eff_armable != stored.armable)
                    self.dbg("region: rebind id={d} armable {}->{} (owner_unique={} membership_complete={} tombstoned={} bridges={d})", .{
                        @intFromEnum(existing_id),
                        stored.armable,
                        eff_armable,
                        cand.armable_owner,
                        cand.membership_complete,
                        stored.tombstoned,
                        cand.bridges.len,
                    });
                staged_armable_updates.appendAssumeCapacity(.{ .id = existing_id, .armable = eff_armable });
                // Keep the stored owner fresh: the unique external-entry loop-root can MOVE
                // to a different anchor with the internal edge set (hence the id) unchanged,
                // so the arm site must track the current owner, not the first-sight one.
                staged_owner_updates.appendAssumeCapacity(.{ .id = existing_id, .owner = cand.owner });
                const bridge_copy = try cloneRegionBridges(gpa, cand.bridges);
                staged_bridge_updates.appendAssumeCapacity(.{ .id = existing_id, .bridges = bridge_copy });
                const mt_copy = try gpa.dupe(u32, cand.member_trace_ids);
                active_regions.appendAssumeCapacity(.{ .id = existing_id, .comp = cand.comp, .armable = eff_armable, .member_trace_ids = mt_copy });
            } else {
                // First sight: mint an id and stage the intern + def (armable per owner).
                const new_id: RegionId = @enumFromInt(new_id_counter);
                // Finding 3: an incomplete membership can never mint an armable region.
                const first_armable = cand.armable_owner and cand.membership_complete;
                const edges_copy = try gpa.dupe(StructuralEdgeId, cand.sorted_internal);
                errdefer gpa.free(edges_copy);
                const members_copy = try gpa.dupe(StructuralEdgeId, cand.sorted_internal);
                errdefer gpa.free(members_copy);
                const points_copy = try gpa.dupe(ProgramPoint, cand.member_points);
                errdefer gpa.free(points_copy);
                const bridge_copy = try cloneRegionBridges(gpa, cand.bridges);
                errdefer freeRegionBridges(gpa, bridge_copy);
                const mt_copy = try gpa.dupe(u32, cand.member_trace_ids);
                errdefer gpa.free(mt_copy);
                staged_interns.appendAssumeCapacity(.{ .edges = edges_copy, .id = new_id });
                staged_defs.appendAssumeCapacity(.{ .id = new_id, .def = .{
                    .members = members_copy,
                    .member_points = points_copy,
                    .owner = cand.owner,
                    .classifier = cand.classifier,
                    .bridges = bridge_copy,
                    .armable = first_armable,
                } });
                active_regions.appendAssumeCapacity(.{ .id = new_id, .comp = cand.comp, .armable = first_armable, .member_trace_ids = mt_copy });
                self.dbg("region: mint id={d} kind={s} members={d} armable={} (owner_unique={} membership_complete={} bridges={d})", .{
                    @intFromEnum(new_id),
                    @tagName(cand.classifier.kind),
                    cand.classifier.member_count,
                    first_armable,
                    cand.armable_owner,
                    cand.membership_complete,
                    cand.bridges.len,
                });
                new_id_counter += 1;
            }
        }

        // 5. Physical classification indices (scratch, fallible), then finalize.
        var src_builder = RegionSetBuilder(ExitKey){};
        defer src_builder.deinit(gpa);
        var dst_builder = RegionSetBuilder(u32){};
        defer dst_builder.deinit(gpa);

        // source_exit: every RESOLVED exit of a physical member of an armable region —
        // internal edges AND boundary exits that leave the region from a member anchor.
        for (edges.items) |e| {
            const c = comp[e.from];
            var ar: ?ActiveRegion = null;
            for (active_regions.items) |a| {
                if (a.comp == c) {
                    ar = a;
                    break;
                }
            }
            const R = ar orelse continue;
            if (!R.armable) continue;
            var is_member = false;
            for (R.member_trace_ids) |tid| {
                if (tid == e.key.trace_id) {
                    is_member = true;
                    break;
                }
            }
            if (!is_member) continue; // sibling non-member exit at a member anchor
            try src_builder.add(gpa, e.key, R.id);
        }
        // dest_entry: every physical member of an armable region (in a strongly-connected
        // component every member anchor is the destination of an internal edge).
        for (active_regions.items) |a| {
            if (!a.armable) continue;
            for (a.member_trace_ids) |tid| try dst_builder.add(gpa, tid, a.id);
        }

        var new_source = try src_builder.finalize(gpa);
        errdefer freeRegionSetMap(ExitKey, &new_source, gpa);
        var new_dest = try dst_builder.finalize(gpa);
        errdefer freeRegionSetMap(u32, &new_dest, gpa);

        // A-vii-d.1 (review blocker 3): the live-armable region-id set for the
        // stale-bridge disarm sweep in the publish phase (fallible scratch).
        // `active_regions[i].armable` already reflects this pass's tombstones —
        // `eff_armable` conjoins `compatible ∧ membership_complete`, the exact
        // tombstone conditions — so this set equals post-publish armability.
        var live_armable_ids: std.ArrayListUnmanaged(RegionId) = .empty;
        defer live_armable_ids.deinit(gpa);
        try live_armable_ids.ensureUnusedCapacity(gpa, active_regions.items.len);
        for (active_regions.items) |a| {
            if (a.armable) live_armable_ids.appendAssumeCapacity(a.id);
        }

        // Reserve capacity on the live LOGICAL maps (last fallible step).
        try self.region_intern.reserve(gpa, staged_interns.items.len);
        try self.region_defs.ensureUnusedCapacity(gpa, @intCast(staged_defs.items.len));

        // ======== PUBLISH (infallible) ========
        for (staged_interns.items) |s| self.region_intern.internAssumeCapacity(s.edges, s.id);
        staged_interns.clearRetainingCapacity(); // ownership moved into region_intern
        for (staged_defs.items) |s| self.region_defs.putAssumeCapacity(s.id, s.def);
        staged_defs.clearRetainingCapacity(); // ownership moved into region_defs
        for (staged_owner_updates.items) |u| {
            if (self.region_defs.getPtr(u.id)) |d| d.owner = u.owner;
        }
        // A-vii-d.0: publish recomputed armability BEFORE the tombstones so a
        // rebind that both recomputed and tombstoned stays fail-closed (the
        // tombstone below re-clears armable and sets the sticky bit).
        for (staged_armable_updates.items) |u| {
            if (self.region_defs.getPtr(u.id)) |d| d.armable = u.armable;
        }
        for (staged_bridge_updates.items) |u| {
            if (self.region_defs.getPtr(u.id)) |d| {
                freeRegionBridges(gpa, d.bridges);
                d.bridges = u.bridges;
            }
        }
        staged_bridge_updates.clearRetainingCapacity();
        for (staged_tombstones.items) |id| {
            self.dbg("region: tombstone id={d} at physical rebuild", .{@intFromEnum(id)});
            if (self.region_defs.getPtr(id)) |d| {
                d.armable = false;
                d.tombstoned = true;
            }
        }
        self.next_region_id = new_id_counter;
        freeRegionSetMap(ExitKey, &self.source_exit_regions, gpa);
        freeRegionSetMap(u32, &self.dest_entry_regions, gpa);
        self.source_exit_regions = new_source;
        self.dest_entry_regions = new_dest;
        // A-vii-d.1 (review blocker 3): disarm every `.region_bridge` link
        // whose armed region did not survive this pass live + armable. Runs
        // LAST in the publish phase, against the just-published state.
        self.disarmStaleRegionBridgeLinks(live_armable_ids.items);
    }

    /// Classify a physical trace exit to the regions it belongs to (doc 17 §A3.3 /
    /// §A8-ii, A-ii.4): a pure query over `source_exit_regions`. A-iv consumes it
    /// only for inert accumulator updates; no tier-selection path reads the result.
    pub fn classifyExit(self: *const TraceState, key: ExitKey) []const RegionId {
        return self.source_exit_regions.get(key) orelse &.{};
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
    /// slot at `slot_index` to the entry selected from `child` by `kind`, and record
    /// the dependency so the link can be reset if either end retires. Re-arming the
    /// same slot supersedes the prior record. The registry append happens *before*
    /// the slot write so an OOM can never leave an armed-but-untracked slot (which
    /// would dangle on the child's retire).
    /// Returns `true` iff the link was actually armed (slot written + record kept).
    /// Returns `false` (a clean no-op — no slot write, no record) for EVERY reject
    /// case, so the caller (2.3b `driveChain`) keeps its accounting identical across
    /// modes (P-F): `parent` is not a compiled frameless trace; `slot_index` is out
    /// of range; the arm `kind` does not match the slot's guard shape (loop-done vs.
    /// non-loop-done, the P-C option-(b) invariant); `child` is not a compiled trace;
    /// or `child` lacks the entry `kind` selects (`.link_terminal`→`linked_entry`,
    /// `.ordinary_guard`/`.loop_done_linked`→`ordinary_entry`). Deriving the target
    /// from `child`+`kind` here (never trusting a caller-supplied address) is what
    /// makes the S2 provenance argument hold by construction.
    ///
    /// INVARIANT: this is the *only* place `CompiledTrace.slots[i]` is ever written
    /// to a non-`shared_exit` value. The entire P-E lifetime argument (a retiring
    /// child resets every parent slot pointing into it) depends on the registry
    /// seeing every armed slot — a direct `c.slots[i] = target` elsewhere would
    /// strand an untracked slot and reintroduce the S2 use-after-reuse.
    pub fn armNativeLink(self: *TraceState, parent: *Trace, slot_index: u32, child: *Trace, kind: ArmKind) !bool {
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
            .link_terminal => {
                std.debug.assert(!is_loopdone);
                if (is_loopdone) return false;
            },
            .ordinary_guard => {
                std.debug.assert(!is_loopdone);
                if (is_loopdone) return false;
                // A-v bridge candidates must remain at shared_exit. In particular,
                // the older M1 ordinary-source arm must not accidentally publish a
                // composite back-edge into the new armed body.
                if (nativegen.isCompositeBridgeCandidate(parent, slot_index)) return false;
            },
            .region_bridge => {
                std.debug.assert(!is_loopdone);
                if (is_loopdone) return false;
            },
        }
        // The child/target association is derived here, never trusted from a caller.
        // A `.link` terminal must enter linked loop-done mode; both ordinary guard
        // and linked loop-done handoffs must clear that mode at `ordinary_entry`.
        // These are the only two valid cross-trace entry points. `compileImpl`
        // release-validates that each stored address lies inside this child's live
        // mcode page before publishing the CompiledTrace.
        const child_c = switch (child.native) {
            .compiled => |*cc| cc,
            else => return false,
        };
        const target = switch (kind) {
            .link_terminal => child_c.linked_entry orelse return false,
            .ordinary_guard, .loop_done_linked => child_c.ordinary_entry orelse return false,
            // A-vii is the first increment allowed to call this arm. Missing the
            // required re-guarding entry is therefore a wiring bug, not ordinary
            // ineligibility: fail loudly before publishing an unsafe bare jump.
            .region_bridge => blk: {
                const entry = child_c.ordinary_entry orelse
                    @panic("armNativeLink(.region_bridge): child has no ordinary_entry");
                if (!region_bridge_arming_enabled)
                    @panic("armNativeLink(.region_bridge): A-v stub is intentionally unarmed");
                break :blk entry;
            },
        };
        // A re-arm of this exact slot supersedes any prior child it pointed at.
        // Mutate the existing record IN PLACE (no allocation) — the earlier
        // remove-then-append ordering could OOM after dropping the old record,
        // stranding the slot armed-but-untracked (2.3a review BUG-1). Because at
        // most one record exists per (parent, slot_index) — this loop guarantees
        // it — the first match is the only match.
        for (self.armed_links.items) |*l| {
            if (l.parent == parent and l.slot_index == slot_index) {
                l.child = child;
                l.kind = kind;
                l.region_id = null; // a `.region_bridge` caller re-stamps after arming
                c.slots[slot_index] = target;
                self.dbg("arm (re-arm): parent id={d} pc={d} slot={d} -> child id={d} pc={d} kind={s}", .{
                    parent.id, parent.anchor.pc, slot_index, child.id, child.anchor.pc, @tagName(kind),
                });
                return true;
            }
        }
        // Fresh slot: append the record BEFORE writing the slot, so a failed append
        // leaves the slot at its prior `shared_exit` value with no dangling record.
        try self.armed_links.append(self.gpa, .{ .parent = parent, .slot_index = slot_index, .child = child, .kind = kind });
        c.slots[slot_index] = target;
        self.dbg("arm: parent id={d} pc={d} slot={d} -> child id={d} pc={d} kind={s}", .{
            parent.id, parent.anchor.pc, slot_index, child.id, child.anchor.pc, @tagName(kind),
        });
        return true;
    }

    /// 2.3c-2e (2c-E): the single shared arm point for the loop-done half of the
    /// native cycle — point inner root `inner`'s numeric-`for` loop-done guard slot
    /// at continuation `cont`'s `ordinary_entry`, so the next time that loop-done
    /// fires natively it commits the linked snapshot and jumps STRAIGHT into the
    /// continuation under the shared frame (no Zig re-entry). Fail-closed and
    /// opportunistic: every gate below `return`s silently (an unarmed slot keeps the
    /// dispatcher path, which is always correct); it never panics.
    ///
    /// Target contract: `ordinary_entry`, NOT `linked_entry` — the continuation is a
    /// `.link` trace with no numeric-for loop-done of its own, and `ordinary_entry`
    /// clears any inherited linked mode (entry-stub contract, 2.3c-0c).
    fn armLoopDoneLink(self: *TraceState, inner: *Trace, guard_idx: u32, cont: *Trace, safe_to_arm: bool) void {
        // Observation blackout (2.3c-0e): never widen an armed cycle while suspend /
        // replay-line recording is active.
        if (!safe_to_arm) return;
        // The exit must be a real in-bounds loop-done guard on `inner`. Checked
        // explicitly HERE, not delegated to `armNativeLink`'s kind invariant: that
        // invariant's debug half is an assert (a wiring-bug tripwire), whereas a
        // mid-loop or prologue-fail exit index is a legitimately reachable input at
        // the call sites and must no-op silently.
        if (guard_idx == std.math.maxInt(u32) or guard_idx >= inner.instrs.len) return;
        if (!isLoopDoneGuardIndex(inner, guard_idx)) return;
        const post_pc = guardExitPc(inner.instrs[guard_idx]) orelse return;
        // Continuation eligibility (P-G): a zero-input `.link` trace anchored exactly
        // at the guard's post-loop PC in the same proto — the shape `replayLedger`'s
        // `.loop_done_linked` successor validation release-panics on, so anything
        // else must stay unarmed.
        if (cont.inputs.len != 0) return;
        if (!(cont.instrs.len != 0 and cont.instrs[cont.instrs.len - 1].op == .link)) return;
        if (!(cont.anchor.proto == inner.anchor.proto and cont.anchor.pc == post_pc)) return;
        // `ordinary_entry` is optional — a missing entry (e.g. a test stub or an
        // unsupported compile) leaves the slot unarmed, never `.?`-traps.
        _ = self.nativeFor(cont) orelse return;
        const armed = self.armNativeLink(inner, guard_idx, cont, .loop_done_linked) catch false;
        if (armed) self.native_loopdone_link_arms +|= 1;
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
            self.dbg("retire-reset: link parent id={d} slot={d} child id={d} (retiring id={d})", .{
                link.parent.id, link.slot_index, link.child.id, t.id,
            });
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
        // A-vii-d.1: never mutate the registry mid-`replayLedger` walk — later
        // rows validate against it (see `replay_walk_depth`). Defer; the ledger
        // driver applies it right after the walk, before any native re-entry.
        if (self.replay_walk_depth > 0) {
            self.pending_disarm_all = true;
            return;
        }
        if (self.armed_links.items.len == 0) return;
        self.dbg("disarmAllLinks: resetting {d} armed links", .{self.armed_links.items.len});
        self.native_link_disarms +|= @intCast(self.armed_links.items.len);
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

    /// A-vii-d.1 (review blocker 3): disarm ONE armed link by registry index —
    /// reset its parent's physical slot to the shared trampoline exit, count the
    /// disarm, and drop the record. Infallible (publish-phase safe). Uses
    /// `swapRemove`, so callers iterating the registry must walk BACKWARDS.
    fn disarmLinkAt(self: *TraceState, idx: usize) void {
        const link = self.armed_links.items[idx];
        self.native_link_disarms +|= 1;
        const shared_exit = self.mcode_arena.trampoline_exit orelse 0;
        switch (link.parent.native) {
            .compiled => |*c| if (link.slot_index < c.slots.len) {
                c.slots[link.slot_index] = shared_exit;
            },
            else => {},
        }
        _ = self.armed_links.swapRemove(idx);
    }

    /// A-vii-d.1 (review blocker 3) — the stale-region lifecycle rule: a
    /// `.region_bridge` link is only valid while the exact region it was armed
    /// under stays live AND armable. Disarm every bridge link whose armed
    /// `region_id` is not in `live_armable` (the region ids the pass that just
    /// published considers live and armable; pass `&.{}` to fail closed and
    /// disarm ALL bridge links). Fail-closed is mandatory, not tidy-up:
    /// `replayLedger`'s `.region_bridge` arm `@panic`s on a row whose armed
    /// region no longer validates, so the physical slot must be reset the
    /// moment the region dies. Infallible (publish-phase safe).
    fn disarmStaleRegionBridgeLinks(self: *TraceState, live_armable: []const RegionId) void {
        var i = self.armed_links.items.len;
        while (i > 0) {
            i -= 1;
            const link = self.armed_links.items[i];
            if (link.kind != .region_bridge) continue;
            const keep = blk: {
                const rid = link.region_id orelse {
                    // An un-stamped bridge link is a broken arm-path
                    // invariant; fail closed rather than leaving an
                    // unvalidatable slot armed.
                    self.dbg("bridge-disarm: un-stamped region_bridge link parent={d} ei={d}", .{ link.parent.id, link.slot_index });
                    break :blk false;
                };
                for (live_armable) |lid| {
                    if (lid == rid) break :blk true;
                }
                self.dbg("bridge-disarm: stale region id={d} parent={d} ei={d}", .{ @intFromEnum(rid), link.parent.id, link.slot_index });
                break :blk false;
            };
            if (!keep) self.disarmLinkAt(i);
        }
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
                    // Coverage (gated): the anchor no longer has a trace, so tier-0
                    // back-edges taken during the re-recording window must classify
                    // as *uncovered* again, not "fallback despite a trace". Clear the
                    // flag; `markAnchorTraced`/`noteTraceIters` re-set it if a fresh
                    // trace commits here. (Total iteration count is unaffected either
                    // way — only the covered/uncovered split.)
                    if (self.config.coverage) {
                        if (self.coverage.getPtr(anchor)) |cov| cov.has_trace = false;
                    }
                }
                // A-ii.2: a retired trace changes which edges remain resolvable for
                // SURVIVING traces (not just its own), so rebuild the whole edge cache
                // from the surviving cache — never a surgical key delete. Any OOM fails
                // closed to EMPTY (region-neutral).
                self.rebuildEdgeCache();
                // A-ii.4: rebuild the physical region indices from the surviving graph
                // (region_defs persists; the physical indices fail closed to EMPTY on OOM).
                self.rebuildRegions();
                return;
            }
        }
    }

    /// Retire the entire trace cache mid-VM-life, freeing every trace and resetting
    /// all derived tiering + diagnostic state — WITHOUT tearing down `mcode_arena`
    /// (the VM keeps running; each `destroy` returns its mcode slots to the arena's
    /// free-list for reuse). Called from `Vm.beginTopLevelEpoch` at a fresh
    /// `run`/`start` entry (docs/design/17 H-2 part 3), *after* `disarmAllLinks`, so a
    /// trace's proto-literal string konsts stop rooting interned strings across the
    /// epoch boundary — otherwise a record mode carries a static literal alive into
    /// the next epoch while `.off` sweeps it, diverging the re-interned id.
    ///
    /// Precondition: `disarmAllLinks` has already reset every armed parent slot and
    /// emptied `armed_links`, so no inbound native link touches any cached trace and
    /// no per-trace `resetLinksTouching` is needed here.
    pub fn clearCache(self: *TraceState) void {
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.clearRetainingCapacity();

        // Anchor-keyed tiering state: reset so the next epoch re-warms cleanly and no
        // stale entry references a freed trace or blocks re-recording. (Mirrors the
        // per-anchor reset `removeTrace` does, applied wholesale.)
        self.counters.clearRetainingCapacity();
        @memset(&self.hotcount, 0);
        self.gate.clearRetainingCapacity();
        self.penalty.clearRetainingCapacity();
        self.guard_failures.clearRetainingCapacity();
        self.prime_exits.clearRetainingCapacity();
        self.wants_side_trace = null;
        self.wants_prime_side = null;
        self.pending_exit_anchor = null;
        self.pending_replay_anchor = null;

        // Trace-index-keyed and `*Proto`-borrowing diagnostic state — unsafe to retain
        // across the boundary (docs/design/17 H-2 part 3):
        //  * `exec_logs` are keyed by `trace_id` == cache index, so a cleared cache
        //    would alias epoch N's log at index 0; and log events can hold string
        //    `Value`s that are NOT in the GC root walk, so a later sweep would dangle
        //    them once the trace-const root is gone. Free them and drop the recorder's
        //    current log target.
        for (self.exec_logs.items) |*l| l.deinit(self.gpa);
        self.exec_logs.clearRetainingCapacity();
        if (self.exec_recorder) |*r| r.log = null;
        //  * `coverage` keys borrow a `*Proto` that reporters dereference, and
        //    `has_trace` classifies later iterations — both wrong once the owning
        //    chunk may be freed / the trace retired. Scalar lifetime aggregates
        //    (`iters_traced`, `cycles_traced`, `run_cycles`, …) are pure `u64`s and
        //    stay.
        self.coverage.clearRetainingCapacity();
        //  * `abort_log` rows borrow a `*Proto` (rendered as `r.proto.name`) — a
        //    diagnostic UAF across independently-owned chunks. Drop them.
        self.abort_log.clearRetainingCapacity();

        // A-ii.2: the structural-edge cache is keyed by `Trace.id` and references a
        // now-freed cache — drop it wholesale (rebuilt as fresh traces commit).
        self.edge_cache.clearRetainingCapacity();

        // A-ii.4: the region model. This is the ONE place the Proto/VM-lifetime logical
        // maps (region_defs/region_intern) are cleared — the epoch boundary where protos
        // (borrowed by RegionDef.owner) may be freed. The physical indices go with them.
        var rd_it = self.region_defs.valueIterator();
        while (rd_it.next()) |d| {
            self.gpa.free(d.members);
            self.gpa.free(d.member_points);
            freeRegionBridges(self.gpa, d.bridges);
        }
        self.region_defs.clearRetainingCapacity();
        self.region_intern.clear(self.gpa);
        self.clearPhysicalRegionIndices();
        self.resetRegionProfit();
        self.region_profit_flushes = 0;
        self.region_profit_flushed_work = 0;
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
        // Never anchor a recording in a dynamic proto (docs/design/17 H-2 part 1).
        // This single choke point covers BOTH root arming (`onBackEdge`) and
        // side-trace arming (`wants_side_trace`), which both funnel through `arm`.
        if (proto.dynamic) return;
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
        // The `tropt` compaction map is transient — used only to remap the exit
        // provenance below, never stored in the `Trace`. Free it on every exit path.
        defer fields.freeMap(self.gpa);

        // Remap the recorder's emission-indexed exit provenance (A-i.1) into the
        // committed, compact `Trace.exit_prov`, keyed by committed instr index. The
        // `dupe` path (link + unoptimized traces) hands back a null map ⇒ identity.
        //
        // A-i.4: the `.link` terminal (edge 2) carries its own provenance on
        // `pending_link_provenance`. It is the trace's last instr — appended directly
        // above, never through `emit`, so it has no lockstep slot — and a link trace
        // always takes the `dupe` (identity) path, so its committed index is
        // `fields.instrs.len − 1`. Release invariant (both set together only in
        // `recForPrepLink`): a `.link` terminal ⇔ a pending link provenance.
        if ((self.rec.link_target != null) != (self.rec.pending_link_provenance != null))
            @panic("commit: link_target / pending_link_provenance invariant violated");
        const link_term: ?ExitProvEntry = if (self.rec.pending_link_provenance) |lp|
            .{ .index = @intCast(fields.instrs.len - 1), .prov = lp }
        else
            null;
        // **FAIL-SOFT (round-14 review, A-i exit_prov parity with `rec_path`):** an OOM in
        // `buildExitProv` must NOT abort the commit — `closeTrace` gates the anchor on a
        // commit error, perturbing tiering, and `exit_prov` is inert region metadata (read
        // only by `provAt` + the A-ii region classifier, nothing on the selection path). On
        // OOM commit an EMPTY exit table and mark `exit_prov_complete = false` so region
        // discovery treats the edge graph as incomplete and arms/mints nothing that pass.
        // `buildExitProv`'s single alloc is `errdefer`-guarded, so a failure leaks nothing.
        var exit_prov_complete = true;
        var exit_prov_owned: []ExitProvEntry = &.{};
        if (buildExitProv(self.gpa, self.rec.exit_prov.items, fields.old_to_new, link_term)) |ok| {
            exit_prov_owned = ok;
        } else |_| {
            exit_prov_complete = false;
        }
        errdefer if (exit_prov_owned.len != 0) self.gpa.free(exit_prov_owned);

        // A-ii.3/A-ii.4: dup the recorder's ordered program-point path into the
        // committed trace. **FAIL-SOFT (round-14 review finding 1):** an OOM here must
        // NOT abort the commit — `closeTrace` gates the anchor on a commit error, which
        // would perturb tiering, and `rec_path` is inert region metadata. On ANY
        // unavailability (recorder-path OOM flipped `rec_path_ok`, OR this dup OOMs)
        // commit an empty path and mark membership INCOMPLETE (finding 3), so region
        // discovery fails any region containing this trace CLOSED (`armable = false`)
        // rather than minting on truncated membership. Owned; freed in `destroy`.
        var rec_path_complete = self.rec.rec_path_ok;
        const rec_path_owned: []ProgramPoint = if (self.rec.rec_path_ok and self.rec.rec_path.items.len != 0)
            (self.gpa.dupe(ProgramPoint, self.rec.rec_path.items) catch blk: {
                rec_path_complete = false;
                break :blk &.{};
            })
        else
            &.{};
        errdefer if (rec_path_owned.len != 0) self.gpa.free(rec_path_owned);

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
            .exit_prov = exit_prov_owned,
            .exit_prov_complete = exit_prov_complete,
            .rec_path = rec_path_owned,
            .rec_path_complete = rec_path_complete,
        };
        try self.cache.append(self.gpa, t);
        // Coverage (gated): a trace now exists at this anchor, so subsequent
        // interpreted back-edges here are "fallback despite a trace."
        if (self.config.coverage) self.markAnchorTraced(t.anchor);
        // A-ii.2: refresh the structural-edge cache — the new trace may add edges
        // FROM itself AND make pre-existing traces' exits newly resolvable. Fail-soft
        // (never fails the commit); any OOM fails CLOSED to an empty cache (round-14
        // finding 6 — this new trace can add a boundary edge that invalidates a prior
        // region's owner, so retaining the prior snapshot could keep a stale arm).
        self.rebuildEdgeCache();
        // A-ii.4: rediscover regions over the refreshed graph. Fail-soft; inert (read by
        // nothing in A-ii); any OOM fails CLOSED to empty physical indices (arm nothing).
        self.rebuildRegions();
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
        self.rec.cur_proto_id = proto.id; // leaf proto for GuardProvenance (A-i.3)
        // A-ii.3: capture the recorded program-point for region membership. Fail-soft
        // — an OOM here marks membership unavailable and continues; it must NEVER
        // abort the trace (that would change trace selection → non-byte-identical).
        if (self.rec.rec_path_ok) {
            self.rec.rec_path.append(self.gpa, .{ .proto_id = proto.id, .source_pc = pc -| 1 }) catch {
                self.rec.rec_path_ok = false;
            };
        }
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
    /// `guard_true`, `guard_false`), the current **post-increment resume/exit PC**
    /// (`rec.cur_pc`, = source-opcode PC + 1) is stored in `aux` so the executor
    /// can report which guard failed and chain to the exit PC. `guardExitPc` reads
    /// it back; `guardSourcePc` recovers the owning source opcode. Other ops keep
    /// their caller-set `aux`.
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
        // Grow the exit-provenance table in lockstep (A-i.1): one `null` per append,
        // so `exit_prov.items[ref]` is always addressable. Guard / fused-producer
        // sites overwrite their slot via `stampProv` (A-i.3); everything else stays
        // `null`. If this append OOMs, `emit` returns the error → the recording
        // aborts → `reset` clears both lists back to equal length, so a transient
        // length skew never outlives the failed recording.
        try self.rec.exit_prov.append(self.gpa, null);
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

    /// Stamp the exit provenance (doc 17, A-i.3) of the guard / fused-producer just
    /// emitted at emission index `ref` — the lockstep `exit_prov` slot already exists
    /// (appended by `emit`). The leaf is the currently-recording opcode:
    /// `source_proto_id = cur_proto_id`, `source_pc = cur_pc − 1` (`cur_pc` is the
    /// post-increment resume PC), with the live inline-path prefix. Behaviour-neutral:
    /// nothing reads `exit_prov` until Part A (A-ii).
    fn stampProv(self: *TraceState, ref: Ref, role: GuardRole, operand: OperandDesig, polarity: Polarity) void {
        self.rec.exit_prov.items[ref] = .{
            .guard = .{
                .path = pathFromFrames(&self.rec.frames, self.rec.inline_depth),
                .inline_depth = self.rec.inline_depth,
                .source_proto_id = self.rec.cur_proto_id,
                // `cur_pc` is the post-increment resume PC (= source-opcode PC + 1), so the
                // owning guest opcode is `cur_pc − 1` (same convention as `guardSourcePc`).
                // In production `cur_pc ≥ 1` always; saturating subtraction is identical for
                // every real input and only maps the synthetic `pc = 0` test sentinel to 0
                // (which `guardSourcePc` likewise treats as "no loop-body guard PC").
                .source_pc = self.rec.cur_pc -| 1,
                .role = role,
                .operand = operand,
                .polarity = polarity,
            },
        };
    }

    /// Emit a type guard for `ref` (deduplicated — an SSA value has one type). Stamps
    /// its provenance `(role, operand)` (A-i.3) only when it actually emits: a deduped
    /// guard (already covered) emits nothing, and the existing guard keeps its own
    /// stamp (the many-to-one static-slot → guard map, H-1c).
    fn guard(self: *TraceState, ref: Ref, op: IrOp, role: GuardRole, operand: OperandDesig) !void {
        if (self.rec.guarded_refs.contains(ref)) return;
        try self.rec.guarded_refs.put(self.gpa, ref, {});
        const gref = try self.emit(.{ .op = op, .a = ref });
        self.stampProv(gref, role, operand, .neutral);
    }

    fn guardInt(self: *TraceState, ref: Ref, role: GuardRole, operand: OperandDesig) !void {
        try self.guard(ref, .guard_int, role, operand);
    }

    fn guardNum(self: *TraceState, ref: Ref, v: Value, role: GuardRole, operand: OperandDesig) !void {
        try self.guard(ref, if (v.isInt()) IrOp.guard_int else IrOp.guard_float, role, operand);
    }

    fn recArith(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb, .operand_type, .b);
        try self.guardNum(rc, vc, .operand_type, .c);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = arithResultType(op, vb, vc) });
        self.setReg(instr.a, r);
    }

    fn recBitwise(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isInt() or !vc.isInt()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardInt(rb, .operand_type, .b);
        try self.guardInt(rc, .operand_type, .c);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .int });
        self.setReg(instr.a, r);
    }

    fn recNeg(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        if (!vb.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardNum(rb, vb, .operand_type, .b);
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
        try self.guardInt(rb, .operand_type, .b);
        const r = try self.emit(.{ .op = .bnot, .a = rb, .ty = .int });
        self.setReg(instr.a, r);
    }

    fn recCompare(self: *TraceState, op: IrOp, swap: bool, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        var rb = try self.refOf(instr.b);
        var rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb, .operand_type, .b);
        try self.guardNum(rc, vc, .operand_type, .c);
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
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, .b, .neutral);
            self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, .b, .neutral);
            const rkey = try self.refOf(instr.c);
            try self.guardInt(rkey, .key_type, .c);
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
            // No guard_present: the `.value` lane has no presence bitmap — nil is
            // encoded in-band (tag == .nil). A nil element fails the guard_table
            // below (nil is not a heap_ref) and side-exits to tier-0. Correct.
            const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
            // Fused native producer-exit (A-i.3): native `.value` `aload` side-exits at
            // the load when the loaded tag is non-heap (`nativegen.zig`), with no
            // `guard_*` node — so the exit identity rides the `aload` itself.
            self.stampProv(rload, .element_type, .loaded, .neutral);
            // Guard the loaded value is a table with no metatable. This is the type
            // guard analogous to guard_int/guard_float for scalar loads — it side-exits
            // when the element's type changes between iterations. (tier-1a path.)
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rload }), .element_type, .loaded, .neutral);
            self.setReg(instr.a, rload);
            return;
        }

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(instr.b);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, .b, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, .b, .neutral);
        const rkey = try self.refOf(instr.c);
        try self.guardInt(rkey, .key_type, .c);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_present, .a = ref }), .present, .none, .neutral);
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
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, .a, .neutral);
            self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, .a, .neutral);
            const rkey = try self.refOf(instr.b);
            try self.guardInt(rkey, .key_type, .b);
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            // guard_append: hash-empty + `idx==len+1` + `len<cap`. The grow analogue
            // of guard_bounds — side-exits to tier-0 (which reallocs/migrates) when
            // any precondition fails, so the on-trace append never allocates.
            self.stampProv(try self.emit(.{ .op = .guard_append, .a = ref }), .append_precond, .none, .neutral);
            // guard_fits: the value still fits the narrow lane (the oracle re-checks a
            // free-variable store; native bool already proves `.bool`). Same as astore.
            self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord }), .value_fits, .c, .neutral);
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
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, .a, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, .a, .neutral);
        const rkey = try self.refOf(instr.b);
        try self.guardInt(rkey, .key_type, .b);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
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
        self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord }), .value_fits, .c, .neutral);
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
        self.stampProv(try self.emit(.{ .op = .guard_grid, .a = rtab, .aux = ge }), .grid_shape, .b, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_stride, .a = rtab, .aux = stride_aux }), .grid_stride, .b, .neutral);
        const rrow = try self.refOf(instr.c);
        try self.guardInt(rrow, .row_type, .c);
        const rcol = try self.refOf(col_reg);
        try self.guardInt(rcol, .col_type, .aux);
        const garow = try self.emit(.{ .op = .garow, .a = rtab, .b = rrow, .aux = ge });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = garow }), .row_bounds, .none, .neutral); // row in [1,rows]
        const gcell = try self.emit(.{ .op = .gcell, .a = garow, .b = rcol, .aux = ge });
        // guard_gcol carries the column ref in `.b` (col in [1,stride]); native keeps
        // it live for the range-compare, the oracle re-reads gcell.b instead.
        self.stampProv(try self.emit(.{ .op = .guard_gcol, .a = gcell, .b = rcol }), .col_bounds, .none, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_gpresent, .a = gcell }), .present, .none, .neutral);
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
        self.stampProv(try self.emit(.{ .op = .guard_grid, .a = rtab, .aux = ge }), .grid_shape, .a, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_stride, .a = rtab, .aux = stride_aux }), .grid_stride, .a, .neutral);
        const rrow = try self.refOf(instr.b);
        try self.guardInt(rrow, .row_type, .b);
        const rcol = try self.refOf(instr.c);
        try self.guardInt(rcol, .col_type, .c);
        const garow = try self.emit(.{ .op = .garow, .a = rtab, .b = rrow, .aux = ge });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = garow }), .row_bounds, .none, .neutral);
        const gcell = try self.emit(.{ .op = .gcell, .a = garow, .b = rcol, .aux = ge });
        self.stampProv(try self.emit(.{ .op = .guard_gcol, .a = gcell, .b = rcol }), .col_bounds, .none, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = ge }), .value_fits, .aux, .neutral);
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
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, .b, .neutral);
        // Seed the loop-invariant cell pointer for native (H1); `href.aux` carries
        // the synthetic slab slot, or `-1` to mark "not seeded → native declines".
        // The tier-1a oracle ignores `aux`, so a `null` seed leaves H0 untouched.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count);
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
        // Fused native producer-exit (A-i.3): native `href` side-exits at the address
        // node on cell-resolution failure (`nativegen.zig`), no `guard_*` — same guest
        // hash access as `guard_hash`, so it shares `(hash_struct, b)`.
        self.stampProv(ref, .hash_struct, .b, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, .b, .neutral);
        const rload = try self.emit(.{ .op = .hload, .a = ref, .ty = obsTypeOf(fv) });
        // Fused native producer-exit (A-i.3): native `hload` side-exits at the load on
        // a field-type change, no `guard_*` node — same site as the consumer guardNum.
        self.stampProv(rload, .field_type, .loaded, .neutral);
        self.setReg(instr.a, rload);
        // Decompose the tagged-cell load into a typed load + the existing consumer
        // type-guard (mirrors `slot_load` + `guardNum`): native lowers `hload` to a
        // tag-check + payload load of the guarded kind. The oracle returns the whole
        // `Value`, so this guard is what makes the two agree on the side-exit
        // iteration (and pins the field type — int→float etc. side-exits).
        try self.guardNum(rload, fv, .field_type, .loaded);
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
        try self.guardNum(rval, vval, .value_type, .c);
        const rtab = try self.refOf(instr.a);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, .a, .neutral);
        // Seed the cell pointer for native (H1) — see `recHashGet`. An RMW's read and
        // write `href`s dedup onto the same slot via `seedHashCell`.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count);
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
        // Fused native producer-exit (A-i.3): native `href` cell-resolution failure.
        self.stampProv(ref, .hash_struct, .a, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, .a, .neutral);
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
        try self.guardNum(rb, vb, .operand_type, .b);
        try self.guardNum(rc, vc, .operand_type, .c);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// `jmp_if_false`/`jmp_if_true`: pin the *observed* truthiness of the tested
    /// register. Which path the trace records is whatever tier-0 took; the guard
    /// is what keeps the straight-line trace valid.
    fn recBranch(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        const ra = try self.refOf(instr.a);
        const truthy = regs.get(instr.a).isTruthy();
        const op: IrOp = if (truthy) .guard_true else .guard_false;
        const gref = try self.emit(.{ .op = op, .a = ra });
        // Branch polarity IS part of the identity (A-i.3, round-1 BLOCKER 1): the
        // true-exit and false-exit of one `if` are opposite CFG edges of the region.
        // Polarity names which guest CFG edge the RECORDED path took, keyed on the
        // branch's *jump-taken* edge (opcode-relative), NOT raw truthiness: a
        // `jmp_if_false` jumps when the value is falsy, a `jmp_if_true` when truthy.
        // So the recorded path took the branch iff `(op == jmp_if_true) == truthy`.
        const jumped = (instr.op == .jmp_if_true) == truthy;
        self.stampProv(gref, .branch_cond, .a, if (jumped) .taken else .fallthrough);
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
        try self.guardNum(ridx, vidx, .operand_type, .a);
        try self.guardNum(rlimit, vlimit, .operand_type, .a1);
        try self.guardNum(rstep, vstep, .operand_type, .a2);

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
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null) blk: {
            const iof = try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int });
            self.stampProv(iof, .limit_int, .a1, .neutral); // float-limit → int side-exit
            break :blk iof;
        } else rlimit;

        // loop continues while (ascending) idx_next <= limit, else limit <= idx_next.
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            try self.emit(.{ .op = .le, .a = rnext, .b = rlimit_cmp, .ty = .boolean })
        else
            try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rnext, .ty = .boolean });
        const done_g = try self.emit(.{ .op = .guard_true, .a = cmp });
        self.stampProv(done_g, .loop_done, .none, .neutral); // loop-continuation test

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
        try self.guardNum(rinit, vinit, .operand_type, .a);
        try self.guardNum(rlimit, vlimit, .operand_type, .a1);
        try self.guardNum(rstep, vstep, .operand_type, .a2);

        // First-iteration bounds test, mirroring `recForLoop`'s compare (incl. the
        // float-limit → int specialization so a mixed int/float compare stays lowerable
        // and byte-identical to tier-0's `idx <= limit`). tier-0 tests `(init−step)+step
        // = init` against `limit`, so we compare `init` directly. On failure the inner
        // loop runs zero times → side-exit to tier-0 instead of entering the inner root.
        const all_int = vinit.isInt() and vstep.isInt();
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null) blk: {
            const iof = try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int });
            self.stampProv(iof, .limit_int, .a1, .neutral);
            break :blk iof;
        } else rlimit;
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            try self.emit(.{ .op = .le, .a = rinit, .b = rlimit_cmp, .ty = .boolean })
        else
            try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rinit, .ty = .boolean });
        self.stampProv(try self.emit(.{ .op = .guard_true, .a = cmp }), .loop_done, .none, .neutral);

        // Publish the inner root's entry state: the control index `R[a]` and the visible
        // loop var `R[a+3]` both start at `init`. (limit `R[a+1]` / step `R[a+2]` are
        // untouched by the loop and already flow through the exit snapshot.)
        self.setReg(a, rinit);
        self.setReg(a + 3, rinit);

        // Close with the `.link` terminator (commit reads `link_target`). closeTrace
        // commits + clears `active`; a build failure gates the anchor, like any abort.
        // A-i.4: stamp the `.link` terminal's provenance (edge 2). `for_prep` is the
        // owning guest opcode, so `source_pc = pc − 1` (= `cur_pc − 1`, this recorded
        // op), and `inline_depth == 0` here (the guard at the top of this fn aborts any
        // inlined `for_prep`), so the path prefix is empty. Set together with
        // `link_target` so the commit-time ⇔ invariant holds by construction.
        self.rec.link_target = inner_anchor;
        self.rec.pending_link_provenance = .{ .link_terminal = .{
            .path = pathFromFrames(&self.rec.frames, self.rec.inline_depth),
            .inline_depth = self.rec.inline_depth,
            .source_proto_id = self.rec.cur_proto_id,
            .source_pc = self.rec.cur_pc -| 1,
        } };
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
        // Never inline a call into a dynamic proto (docs/design/17 H-2 part 1): a
        // static trace embedding a `load`ed callee's proto-literal konsts would
        // sole-root them past the callee's lifetime and diverge intern ids across
        // modes. Abort cleanly; the static caller keeps running tier-0.
        if (cp.dynamic) return self.abort(.dynamic_proto);
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
        self.stampProv(try self.emit(.{ .op = .guard_func, .a = callee_ref, .aux = @bitCast(cp.id) }), .callee_identity, .a, .neutral);

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

        // (3) push the recorder frame and descend into the callee window. Record the
        // inline call edge (A-i.2): `proto` is the caller here, and `cur_pc` is the
        // `.call`'s post-increment PC, so the source `.call` opcode is at `cur_pc − 1`.
        self.rec.frames[self.rec.inline_depth] = .{
            .base_off = self.rec.base_off,
            .ret_dest = instr.a,
            .ret_count = instr.c,
            .caller_proto_id = proto.id,
            .call_pc = self.rec.cur_pc - 1,
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
            self.stampProv(try self.emit(.{ .op = .guard_pure, .a = callee_ref, .aux = @intFromEnum(function.PureBuiltin.sqrt) }), .callee_pure, .a, .neutral);
        }
        const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
        try self.guard(arg_ref, .guard_float, .operand_type, .a1);
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
            // Operand is the destination register `dest` (H-1c: `(callee_identity, dest)`),
            // which `recInputGet` receives as `instr.a` of the get_upval/get_global.
            self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
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
const InlineFrame = struct {
    base_off: u32,
    ret_dest: u16,
    ret_count: u16,
    /// The inline call *edge* that opened this frame (doc 17, A-i.2 / H-1a): the
    /// caller proto's globally-unique id and the `.call` opcode's PC. Together with
    /// the sibling frames on `Recorder.frames[0..inline_depth]` these form a guard's
    /// ordered inline-path prefix (`currentPath`), so the two guards from `f(a);
    /// f(b)` inlined at distinct call sites get distinct `GuardProvenance`. Set in
    /// `recCall`'s push; read by `currentPath`. Behaviour-neutral (recorder-only).
    caller_proto_id: u32,
    call_pc: u32,
};

/// Build a guard's ordered inline-path prefix (doc 17, A-i.2) from the recorder's
/// live inline-frame stack: `path[i]` is the call edge that opened frame `i`.
/// `depth` (= `Recorder.inline_depth`, ≤ `MAX_INLINE_DEPTH`) is the meaningful
/// length; entries `[depth, MAX_INLINE_DEPTH)` are left undefined (a
/// `GuardProvenance` carries its own `inline_depth`, so consumers only read the
/// prefix). Pure — the identity substrate `stampProv` (A-i.3) reads.
fn pathFromFrames(frames: []const InlineFrame, depth: u8) [MAX_INLINE_DEPTH]CallEdge {
    var path: [MAX_INLINE_DEPTH]CallEdge = undefined;
    for (0..depth) |i| path[i] = .{
        .caller_proto_id = frames[i].caller_proto_id,
        .call_pc = frames[i].call_pc,
    };
    return path;
}

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
    /// Exit provenance (doc 17, A-i / 9-B), grown in **lockstep with every `emit`**:
    /// `emit` appends one `null` per IR append, and guard / fused-producer sites
    /// overwrite their slot via `stampProv` (A-i.3). So `exit_prov.items[ref]` is the
    /// provenance (if any) of the instruction at emission index `ref`, for every
    /// `emit`-appended instr. The φ writeback block and the `.link`/`.loop` terminal
    /// are appended to `instrs` *directly at commit* (after recording), NOT via
    /// `emit`, so they have no lockstep slot — the array covers exactly the
    /// `emit`-appended prefix, which is where all guards and fused producers live.
    /// The `.link` terminal's provenance rides `pending_link_provenance` instead
    /// (A-i.4). At commit the whole table is remapped through `tropt`'s compaction
    /// map into the committed, compact `Trace.exit_prov`. Recorder scratch —
    /// cleared/retained like `instrs`.
    exit_prov: std.ArrayListUnmanaged(?ExitProvenance) = .empty,
    /// Ordered recorded guest program-points (doc 17 §A8-ii, A-ii.3): one
    /// `{proto_id, source_pc}` per `recordInstr`, the membership-set basis A-ii.4
    /// unions per region. Recorder scratch — dup'd into `Trace.rec_path` at commit,
    /// cleared/retained like `instrs`. **Fail-soft:** if an append OOMs, `rec_path_ok`
    /// flips false and the recording continues (membership becomes *unavailable* for
    /// this trace, `Trace.rec_path` commits empty) — it must NEVER abort the trace.
    rec_path: std.ArrayListUnmanaged(ProgramPoint) = .empty,
    rec_path_ok: bool = true,
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
    /// Transport for the `.link` terminal's exit provenance (doc 17, A-i.4 / edge 2):
    /// the `.link` op is synthesized at COMMIT (not at `recForPrepLink`, and link
    /// traces bypass `tropt.optimize`), so `recForPrepLink` stashes the terminal's
    /// `.link_terminal` provenance here and `commit` consumes it when it appends the
    /// `.link`. Release invariant: `link_target != null ⇔ pending_link_provenance !=
    /// null`. Reset to `null` by `reset` (every abort/re-arm) alongside `link_target`.
    pending_link_provenance: ?ExitProvenance = null,
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
    /// **Post-increment resume/exit PC** of the instruction currently being
    /// recorded (= its source-opcode PC + 1; the tier-0 fetch advances one
    /// fixed-width `Instr` before the recording mirror). Set by `recordInstr`
    /// before `recordOne`; `emit` stores it in the `aux` field of guard
    /// instructions so the executor can report *which* guard failed and chain to
    /// the exit PC. NOT the source-opcode index — `guardSourcePc` recovers that.
    cur_pc: u32 = 0,
    /// Tier-0 opcode of the instruction currently being recorded. Set alongside
    /// `cur_pc` in `recordInstr`; read by `logAbort` (when `config.record_aborts`)
    /// to name the opcode that triggered an abort. `.halt` is a harmless initial
    /// placeholder — overwritten before any abort can reference it.
    cur_op: OpCode = .halt,
    /// Globally-unique id of the proto whose opcode is currently being recorded —
    /// the *leaf* proto (the anchor proto, or an inlined callee's proto once
    /// `recCall` descends). Set alongside `cur_pc`/`cur_op` in `recordInstr`. Read by
    /// `stampProv` (A-i.3) as a guard's `source_proto_id`, so a guard from an inlined
    /// callee is attributed to the callee, not the anchor. Default 0 (harmless before
    /// the first `recordInstr`).
    cur_proto_id: u32 = 0,
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
        self.exit_prov.deinit(gpa);
        self.rec_path.deinit(gpa);
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
        self.exit_prov.clearRetainingCapacity();
        self.rec_path.clearRetainingCapacity();
        self.rec_path_ok = true;
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
        self.pending_link_provenance = null;
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

/// Percentage `x / total * 100` as an `f64`, or 0 when `total == 0`.
fn pctOf(x: u64, total: u64) f64 {
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(x)) * 100.0 / @as(f64, @floatFromInt(total));
}

/// One per-anchor coverage row, materialized from the `coverage` map for sorted
/// display (a hashmap has no stable iteration order; the report must be
/// reproducible — Rule Z-3). Carries both the iteration counts and the cycle
/// (time) attribution so the table can weigh loops by cost, not just count.
const CoverageRow = struct {
    name: []const u8,
    /// Stable serialization id of the anchor's proto — the sort tiebreak, so two
    /// distinct protos that share a name (and pc) still order deterministically
    /// (a `Proto` pointer would order by ASLR-dependent address).
    proto_id: u32,
    pc: u32,
    traced: u64,
    interp: u64,
    traced_cycles: u64,
    interp_cycles: u64,
};

/// Render the JIT stats report to `w` (stderr, via `--jit-coverage`/`--jit-stats`).
/// Reads only — never mutates `ts`. `full = false` prints just the one-line coverage
/// summary (for `--jit-coverage`); `full = true` prints the whole block: the event
/// counters, the aggregate native-vs-tier-0 split by BOTH iterations and time, and a
/// per-anchor table. Iteration% flatters the JIT (a traced iteration is ~10-20×
/// cheaper than a tier-0 one), so the time split — present only on x86_64, where
/// `readCycles` returns a real TSC — is the one to trust. Requires `ts.config.coverage`
/// to have been on during the run, else the counts are all zero (the event counters
/// are always live).
pub fn writeJitStats(w: *io.Writer, ts: *const TraceState, full: bool) io.Writer.Error!void {
    const traced = ts.iters_traced;
    const covered_interp = ts.iters_tier0_covered;
    const uncovered = ts.iters_tier0_uncovered;
    const total = traced +| covered_interp +| uncovered;
    // "covered by a trace" = a compiled trace exists at the anchor = ran-as-trace
    // plus fell-back-despite-a-trace.
    const covered = traced +| covered_interp;

    // Time attribution (TSC cycles). `run` is the whole-run denominator so the three
    // loop classes plus `other` (straight-line / non-loop code) partition it.
    const c_traced = ts.cycles_traced;
    const c_cov = ts.cycles_tier0_covered;
    const c_unc = ts.cycles_tier0_uncovered;
    const c_loop = c_traced +| c_cov +| c_unc;
    const run = ts.run_cycles;
    const has_time = run > 0;
    // Clamp: TSC skew across the per-region brackets can make the loop sum slightly
    // exceed the single outer bracket; never report negative "other".
    const c_other = if (run > c_loop) run - c_loop else 0;

    if (!full) {
        // One-liner for --jit-coverage. `fallback` = the smell: had a trace, ran
        // tier-0. The time fragment is what de-misleads the iteration percentages.
        try w.print(
            "lune: jit coverage — iters: traced {d:.1}% / fallback {d:.1}%",
            .{ pctOf(traced, total), pctOf(covered_interp, total) },
        );
        if (has_time) {
            try w.print(
                "  |  time: traced {d:.1}% / tier-0 {d:.1}% (covered-fallback {d:.1}%)\n",
                .{ pctOf(c_traced, run), pctOf(c_cov +| c_unc, run), pctOf(c_cov, run) },
            );
        } else {
            try w.writeAll("  (time: n/a on this target)\n");
        }
        return;
    }

    try w.writeAll("lune: JIT stats\n");
    try w.writeAll("  event counters:\n");
    try w.print("    trace entries:        {d}\n", .{ts.entries});
    try w.print("    link arms:            native={d} source={d} loopdone={d} bridge={d}\n", .{ ts.native_link_arms, ts.native_source_link_arms, ts.native_loopdone_link_arms, ts.native_region_bridge_arms });
    try w.print("    link fused:           source={d} loopdone={d} bridge={d}\n", .{ ts.native_source_link_fused, ts.native_loopdone_link_fused, ts.native_region_bridge_fused });
    try w.print("    link disarms:         {d}\n", .{ts.native_link_disarms});
    try w.print("    native link exits:    {d} (follows={d})\n", .{ ts.native_link_exits, ts.native_link_follow_count });
    try w.print("    ir link exits:        {d} (follows={d})\n", .{ ts.link_ir_exits, ts.link_follow_count });
    try w.print("    prime-side:           arms={d} chain-follows={d} tier0-body-entries={d}\n", .{ ts.prime_side_arms, ts.prime_side_chain_follows, ts.tier0_outer_body_entries });

    try w.writeAll("  coverage by loop iterations (count — flatters the JIT):\n");
    try w.print("    traced (ran as trace):  {d:>12}  ({d:.1}%)\n", .{ traced, pctOf(traced, total) });
    try w.print("    tier-0, has-trace:      {d:>12}  ({d:.1}%)   <- fallback despite a trace\n", .{ covered_interp, pctOf(covered_interp, total) });
    try w.print("    tier-0, no-trace:       {d:>12}  ({d:.1}%)\n", .{ uncovered, pctOf(uncovered, total) });
    try w.print("    total:                  {d:>12}\n", .{total});
    try w.print("    covered by a trace:     {d:.1}%   ran as a trace: {d:.1}%\n", .{ pctOf(covered, total), pctOf(traced, total) });

    if (has_time) {
        try w.writeAll("  coverage by time (TSC cycles — the honest split):\n");
        try w.print("    traced (ran as trace):  {d:>12}  ({d:.1}% of run)\n", .{ c_traced, pctOf(c_traced, run) });
        try w.print("    tier-0, has-trace:      {d:>12}  ({d:.1}% of run)   <- fallback despite a trace\n", .{ c_cov, pctOf(c_cov, run) });
        try w.print("    tier-0, no-trace:       {d:>12}  ({d:.1}% of run)\n", .{ c_unc, pctOf(c_unc, run) });
        try w.print("    other (non-loop):       {d:>12}  ({d:.1}% of run)\n", .{ c_other, pctOf(c_other, run) });
        try w.print("    run total:              {d:>12}\n", .{run});
        if (ts.run_nanos > 0) {
            // Wall time pairs with the TSC total to recover the effective clock
            // (cycles/ns = GHz), turning the cycle percentages above into real time.
            const ns: f64 = @floatFromInt(ts.run_nanos);
            const ghz = @as(f64, @floatFromInt(run)) / ns;
            try w.print("    run wall time:          {d:>9.3} ms   (~{d:.2} GHz effective)\n", .{ ns / 1_000_000.0, ghz });
        }
        try w.print("    ran as a trace: {d:.1}% of run   ({d:.1}% of loop time)\n", .{ pctOf(c_traced, run), pctOf(c_traced, c_loop) });
    } else {
        try w.writeAll("  coverage by time: n/a (no TSC on this target)\n");
    }

    // Per-anchor table, sorted (proto name, pc, proto id) for reproducibility. Fixed
    // buffer: real programs have a handful of hot loops, so it never fills. If it
    // ever DID overflow, the kept subset is the first 256 in hash-map order (which is
    // layout-dependent) — only then is *which* rows survive nondeterministic; the
    // shown rows are always sorted. A `truncated` note flags the (unrealistic) case.
    var rows: [256]CoverageRow = undefined;
    var n: usize = 0;
    var truncated = false;
    var it = ts.coverage.iterator();
    while (it.next()) |e| {
        if (n == rows.len) {
            truncated = true;
            break;
        }
        rows[n] = .{
            .name = e.key_ptr.proto.name,
            .proto_id = e.key_ptr.proto.id,
            .pc = e.key_ptr.pc,
            .traced = e.value_ptr.traced,
            .interp = e.value_ptr.interp,
            .traced_cycles = e.value_ptr.traced_cycles,
            .interp_cycles = e.value_ptr.interp_cycles,
        };
        n += 1;
    }
    std.mem.sort(CoverageRow, rows[0..n], {}, struct {
        fn lt(_: void, a: CoverageRow, b: CoverageRow) bool {
            const c = std.mem.order(u8, a.name, b.name);
            if (c != .eq) return c == .lt;
            if (a.pc != b.pc) return a.pc < b.pc;
            return a.proto_id < b.proto_id;
        }
    }.lt);
    if (n > 0) {
        // Columns: iteration split (traced/interp + trace%), then the time view —
        // this anchor's share of the whole run and how much of ITS OWN time was
        // traced. `run%`/`traced%time` are the ones that expose a hot loop that
        // "has a trace" yet spends its time interpreted. Time cols blank when no TSC.
        try w.writeAll("  per-anchor (loop header):\n");
        try w.print("    {s:<18}  {s:>11}  {s:>11}  {s:>6}   {s:>6}  {s:>8}\n", .{ "anchor", "traced-it", "interp-it", "trc%it", "run%", "trc%time" });
        for (rows[0..n]) |r| {
            var name_pc_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&name_pc_buf, "{s}:{d}", .{ r.name, r.pc }) catch "?";
            const anchor_cycles = r.traced_cycles +| r.interp_cycles;
            if (has_time) {
                try w.print("    {s:<18}  {d:>11}  {d:>11}  {d:>5.1}%   {d:>5.1}%  {d:>7.1}%\n", .{
                    label,                     r.traced,
                    r.interp,                  pctOf(r.traced, r.traced +| r.interp),
                    pctOf(anchor_cycles, run), pctOf(r.traced_cycles, anchor_cycles),
                });
            } else {
                try w.print("    {s:<18}  {d:>11}  {d:>11}  {d:>5.1}%   {s:>6}  {s:>8}\n", .{
                    label, r.traced, r.interp, pctOf(r.traced, r.traced +| r.interp), "n/a", "n/a",
                });
            }
        }
        if (truncated) try w.writeAll("    … (per-anchor table truncated at 256 anchors)\n");
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

test "guardSourcePc: source-opcode PC is exit PC − 1 (H-1b), pinned independently" {
    const gpa = testing.allocator;

    // (1) Recorded path. Record a real `get_index` as if its opcode sat at a known
    // bytecode index N: the tier-0 dispatch loop hands `recordInstr` the
    // POST-INCREMENT pc (N+1) (interp.zig:1762), so the emitted `guard_int` must
    // report source-opcode N and resume/exit N+1. We assert against the
    // INDEPENDENTLY chosen N — not `source+1 == exit`, which is tautological given
    // `guardSourcePc := exit − 1`.
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    const N: u32 = 5; // chosen known source-opcode index
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, N + 1, Value.nil());
    try testing.expect(state.isRecording());

    var saw_guard = false;
    for (state.rec.instrs.items) |ins| {
        if (guardExitPc(ins)) |exit_pc| {
            try testing.expectEqual(@as(u32, N + 1), exit_pc); // stamped post-increment pc
            try testing.expectEqual(@as(u32, N), guardSourcePc(ins).?); // owning opcode
            saw_guard = true;
        }
    }
    try testing.expect(saw_guard); // the bool-lane get_index emits a PC-carrying guard_int

    // (2) emit-fixture for the two ops a simple recorded op can't reach:
    // `guard_number` (the production `guardNum` only ever picks int/float,
    // trace.zig ~4165) and `int_of_float`. Set the recorder's post-increment pc to a
    // known M+1 and emit each directly; both must stamp `aux` and report source M /
    // exit M+1.
    var st2 = TraceState.init(gpa);
    defer st2.deinit();
    try st2.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    const M: u32 = 11;
    st2.rec.cur_pc = M + 1;
    inline for (.{ IrOp.guard_number, IrOp.int_of_float }) |op| {
        const ref = try st2.emit(.{ .op = op, .a = 0 });
        const ins = st2.rec.instrs.items[ref];
        try testing.expectEqual(@as(u32, M + 1), guardExitPc(ins).?);
        try testing.expectEqual(@as(u32, M), guardSourcePc(ins).?);
    }

    // (3) a non-PC-carrying op yields null from BOTH accessors (never a category error).
    try testing.expectEqual(@as(?u32, null), guardExitPc(.{ .op = .aload, .a = 0 }));
    try testing.expectEqual(@as(?u32, null), guardSourcePc(.{ .op = .aload, .a = 0 }));

    // (4) the 0 sentinel ("no usable PC") maps to null through the source accessor too.
    try testing.expectEqual(@as(?u32, null), guardSourcePc(.{ .op = .guard_true, .a = 0, .aux = 0 }));
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
        .native = .{ .compiled = .{ .page = undefined, .slots = child_slots, .gpa = gpa, .linked_entry = 0xDEAD_BEEF } },
    };
    const CHILD_BODY: usize = 0xDEAD_BEEF;
    const CHILD_BODY2: usize = 0xF00D;
    var child2: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .linked_entry = CHILD_BODY2 } },
    };

    // Arm: slot 1 of parent points at the child body; exactly one record tracked.
    try testing.expect(try state.armNativeLink(&parent, 1, &child, .link_terminal));
    try testing.expectEqual(CHILD_BODY, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    // Re-arming the SAME slot supersedes the prior record IN PLACE (no duplicate,
    // no realloc — the record count stays 1 and the new target is written).
    try testing.expect(try state.armNativeLink(&parent, 1, &child2, .link_terminal));
    try testing.expectEqual(CHILD_BODY2, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    // Retiring the superseded child does not touch the re-armed slot.
    state.resetLinksTouching(&child);
    try testing.expectEqual(CHILD_BODY2, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    // Current child retires (target side): parent resets and the record is dropped.
    state.resetLinksTouching(&child2);
    try testing.expectEqual(SHARED_EXIT, parent_slots[1]);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Out-of-range slot index is a no-op → returns false, no OOB write, no record.
    try testing.expect(!try state.armNativeLink(&parent, 99, &child, .link_terminal));
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
    try testing.expect(!try state.armNativeLink(&unsup, 0, &child, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Parent-retire direction: re-arm, then reset touching the PARENT (source).
    // The record is dropped WITHOUT writing through the (about-to-be-freed) slot,
    // and a subsequent child-retire must find no record — no write, no crash.
    try testing.expect(try state.armNativeLink(&parent, 2, &child, .link_terminal));
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
    state.resetLinksTouching(&parent);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    // A parent-side reset leaves the slot value untouched (its array is freed anyway).
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
    // Later child-retire is a clean no-op now that the record is gone.
    state.resetLinksTouching(&child);
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
}

test "disarmAllLinks (2c-E / 2.3c-0e): resets EVERY armed slot on entering the observation blackout" {
    // The disarm-on-unsafe path (dispatcher calls `disarmAllLinks` when
    // `!safe_to_arm` — suspend / replay-line recording / exec-log active). Unlike
    // `resetLinksTouching` (one retiring trace), this resets the WHOLE registry so
    // no armed cycle widens the observation blackout. Arm a full C↔I cycle (two
    // links), then one `disarmAllLinks` must return BOTH slots to shared_exit and
    // empty the registry — and be idempotent (a second call is a no-op).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const SHARED_EXIT: usize = 0; // no trampoline in this unit test
    try testing.expectEqual(@as(?usize, null), state.mcode_arena.trampoline_exit);

    const inner_slots = try gpa.alloc(usize, 1);
    defer gpa.free(inner_slots);
    @memset(inner_slots, SHARED_EXIT);
    const cont_slots = try gpa.alloc(usize, 1);
    defer gpa.free(cont_slots);
    @memset(cont_slots, SHARED_EXIT);

    var inner: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = inner_slots, .gpa = gpa, .linked_entry = 0xBBBB } },
    };
    var cont: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = cont_slots, .gpa = gpa, .linked_entry = 0xAAAA } },
    };

    const I_TO_C: usize = 0xAAAA;
    const C_TO_I: usize = 0xBBBB;
    // Arm both edges of the cycle (kinds are `.link_terminal` here — the guard-shape
    // invariant is exercised elsewhere; these stubs have empty instrs so no slot is
    // a loop-done). inner.slot[0] → C, cont.slot[0] → I.
    try testing.expect(try state.armNativeLink(&inner, 0, &cont, .link_terminal));
    try testing.expect(try state.armNativeLink(&cont, 0, &inner, .link_terminal));
    try testing.expectEqual(I_TO_C, inner_slots[0]);
    try testing.expectEqual(C_TO_I, cont_slots[0]);
    try testing.expectEqual(@as(usize, 2), state.armed_links.items.len);

    // One disarm resets BOTH slots and empties the registry, and the tear-down
    // counter reflects exactly the two slots reset.
    state.disarmAllLinks();
    try testing.expectEqual(SHARED_EXIT, inner_slots[0]);
    try testing.expectEqual(SHARED_EXIT, cont_slots[0]);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(u64, 2), state.native_link_disarms);

    // Idempotent: a second call on the now-empty registry is a clean no-op — and
    // the counter does NOT advance (the early `len == 0` return fires first).
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(u64, 2), state.native_link_disarms);
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
        .native = .{ .compiled = .{ .page = undefined, .slots = &.{}, .gpa = gpa, .linked_entry = 0x5678, .ordinary_entry = 0x1234 } },
    };

    // Classifier: slot 0 IS a loop-done guard; slot 1 (ordinary guard) is not.
    try testing.expect(isLoopDoneGuardIndex(&parent, 0));
    try testing.expect(!isLoopDoneGuardIndex(&parent, 1));

    // The loop-done slot accepts only a `.loop_done_linked` arm.
    const ORDINARY_ENTRY: usize = 0x1234;
    try testing.expect(try state.armNativeLink(&parent, 0, &child, .loop_done_linked));
    try testing.expectEqual(ORDINARY_ENTRY, parent_slots[0]);

    // The non-loop-done slot accepts an ordinary-guard arm (and never a loop-done one).
    try testing.expect(try state.armNativeLink(&parent, 1, &child, .ordinary_guard));
    try testing.expectEqual(ORDINARY_ENTRY, parent_slots[1]);

    // An index at/past `slots.len` (== instrs.len) is out of range for EVERY arm kind —
    // there is no reserved off-table cell to accidentally address (blocker-2 fix).
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, .ordinary_guard));
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, .link_terminal));
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, .loop_done_linked));

    // Reset so the leak-checked registry is empty at deinit.
    state.resetLinksTouching(&child);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
}

test "replayLedger M1 sub-case (c): fused [skip.deopt, ramp.prologue_fail] replays the unarmed steering" {
    // 2c-E: an M1-armed source-branch guard jumped skip → ramp, and the ramp's
    // HOISTED entry-type prologue failed pre-commit. `replayLedger` must replay the
    // unarmed native steering exactly: charge the skip's own committed count
    // (onSideExit(skip, local)), charge the ramp's zero-progress entry
    // (onSideExit(ramp, 0)), and resume at the skip's anchor header — WITHOUT
    // retrying further candidates (the native tier's flushed_resume_pc short-circuit;
    // codex 2c-E ruling: sub-case (c) is a (b)-analog).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity(); // stack-backed traces: never destroy()

    // proto.code[1] is NOT a for_loop, so skip's guard_true (exit_pc 2) classifies as
    // a source-branch guard, never a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.ret) }, .name = "t", .num_registers = 1 };

    // The skip trace: a directly-dispatched loop trace at the outer header (pc 10)
    // whose instr 0 is the armed source-branch guard. Compiled stub so the M1 arm's
    // provenance record can exist (`armNativeLink` requires a slot table).
    const skip_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // source-branch guard, exit_pc 2
        .{ .op = .loop },
    };
    const skip_slots = try gpa.alloc(usize, skip_instrs.len);
    defer gpa.free(skip_slots);
    @memset(skip_slots, 0);
    var skip: Trace = .{
        .id = 101,
        .anchor = .{ .proto = &proto, .pc = 10 },
        .instrs = @constCast(&skip_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = skip_slots, .gpa = gpa } },
    };
    // The prime-side entry ramp: same anchor (skip + ramp coexist at the outer
    // header), ends in `.link` (sub-case (c) validates the ramp shape).
    const ramp_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var ramp: Trace = .{
        .id = 102,
        .anchor = .{ .proto = &proto, .pc = 10 },
        .instrs = @constCast(&ramp_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xBEEF } },
    };
    try state.cache.append(gpa, &skip);
    try state.cache.append(gpa, &ramp);

    // Establish the M1 armed-edge provenance the fused `.deopt` validation demands.
    try testing.expect(try state.armNativeLink(&skip, 0, &ramp, .ordinary_guard));

    // The fused receipt: skip committed 9 iterations then its armed guard fired
    // (`.deopt`, non-last), the ramp's prologue failed pre-commit (cum unchanged).
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 9, .id = 101, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 9, .id = 102, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&skip, &entries, &proto, tr_regs.view(), false);

    // Terminal receipt: nothing chain-committed, resume at the skip's own header.
    try testing.expectEqual(@as(usize, 0), r.completed);
    try testing.expectEqual(@as(?u32, 10), r.resume_pc);
    // onSideExit(skip, 9): 9 >= min_useful(8) → useful entry, hit_count bumped.
    try testing.expectEqual(@as(u64, 1), skip.hit_count);
    // onSideExit(ramp, 0): low-yield → one penalty on the SHARED outer-header anchor.
    try testing.expectEqual(@as(u32, 1), state.penalty.get(.{ .proto = &proto, .pc = 10 }).?);
    // The fused M1 recognition fired exactly once; no `.link` marker was replayed.
    try testing.expectEqual(@as(u64, 1), state.native_source_link_fused);
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
}

test "replayLedger dispatcher grammar: [I.loop_done_linked, C.prologue_fail] commits the loop-done, breaks the burst" {
    // 2c-E (dispatcher gate widening): once I.loopdone → C.ordinary_entry is armed,
    // a dispatcher-rooted native run of the inner can fuse into a continuation whose
    // hoisted prologue then fails. The loop-done COMMITTED (linked materialization),
    // so the receipt must carry completed == 1 and resume at the continuation anchor;
    // the continuation's pre-commit prologue-fail terminates the burst with no
    // phantom charge on the continuation.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The inner root at pc 5: ends `.loop`, instr 0 is the loop-done guard.
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .id = 201,
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    // The continuation at the post-loop pc 2: zero-input, ends `.link` back to pc 5.
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var cont: Trace = .{
        .id = 202,
        .anchor = .{ .proto = &proto, .pc = 2 },
        .instrs = @constCast(&cont_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try state.cache.append(gpa, &inner);
    try state.cache.append(gpa, &cont);

    // One committed enclosing iteration (cum 0→1), then the fused continuation's
    // prologue failed pre-commit (cum unchanged).
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = 201, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 202, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);

    // The loop-done committed: one enclosing iteration, coherent at the continuation
    // anchor (pc 2) — the prologue-fail must NOT erase that progress.
    try testing.expectEqual(@as(usize, 1), r.completed);
    try testing.expectEqual(@as(?u32, 2), r.resume_pc);
    // onSideExit(inner, 1): low-yield → one penalty on the inner anchor.
    try testing.expectEqual(@as(u32, 1), state.penalty.get(.{ .proto = &proto, .pc = 5 }).?);
    // The continuation's pre-commit fail takes NO onSideExit (break_burst tail).
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    // No `.link` marker in this grammar.
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
}

test "replayLedger A-vii-c.1: rows a live region CONSUMES take no legacy strike (no double charge)" {
    // The A-vii-c.1 re-review blocker: `replayLedger` accounts a region receipt per
    // row and then, in the kind arms, took a per-trace selection receipt through
    // `onSideExit` — which unconditionally applies the legacy verdict. Once an
    // armable region exists, a consumed row would be charged by BOTH machines. The
    // arms now go through `accountLedgerRow`, which honours the row's own
    // `region_consumed`. This is the positive control; the
    // `[I.loop_done_linked, C.prologue_fail]` grammar test above is the negative one
    // (no region ⇒ the identical shape still strikes).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .id = 77, .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .id = 201,
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 9 }, // an own guard: the `.deopt` exit
        .{ .op = .link, .aux = 5 },
    };
    var cont: Trace = .{
        .id = 202,
        .anchor = .{ .proto = &proto, .pc = 2 },
        .instrs = @constCast(&cont_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try state.cache.append(gpa, &inner);
    try state.cache.append(gpa, &cont);

    // A live ARMABLE region owning both anchors' exits. Both rows must classify to
    // the SAME region (a different one would close the active accumulator), and the
    // first row's destination (202) must be indexed too or `applyDestination` closes
    // the region as a departure.
    const owner: AnchorKey = .{ .proto = &proto, .pc = 5 };
    const rid: RegionId = @enumFromInt(11);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{ .{ .proto_id = 77, .source_pc = 5 }, .{ .proto_id = 77, .source_pc = 2 } }),
        .owner = owner,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 201, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    try state.source_exit_regions.put(gpa, .{ .trace_id = 202, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    try state.dest_entry_regions.put(gpa, 202, try gpa.dupe(RegionId, &.{rid}));
    state.setRegionContext(1, 5);

    // [I.loop_done_linked (work 1), C.deopt local=3 (work 3)] — both sub-min_useful,
    // so the PRE-flip machine would have struck both anchors.
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = 201, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 4, .id = 202, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);
    try testing.expectEqual(@as(usize, 4), r.completed);

    // Both rows were consumed by the region window machine, so NEITHER anchor took a
    // legacy strike — the double-charge the re-review caught.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    // ...and the work really landed on the region: 1 + 3 traversals, still short of
    // the N=8 window, so no flush yet.
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };
    try testing.expectEqual(@as(u64, 4), state.region_profit.get(key).?.outer_traversals);
    try testing.expectEqual(@as(u64, 0), state.region_profit_flushes);
    // Selection still moved per segment on both traces.
    try testing.expectEqual(@as(u64, 0), inner.hit_count); // 1 < min_useful
    try testing.expectEqual(@as(u64, 0), cont.hit_count); // 3 < min_useful
}

test "driveSeedLedger: a deep hop-0 ledger [C.link, I.done, C.deopt] charges each transition exactly once" {
    // 2c-E (hop-0 >2 split): a chain candidate's FIRST run fused `.link → inner →
    // continuation-deopt` in one native call. `driveSeedLedger` must hand the whole
    // span to `replayLedger` with NO wrapper `native_link_exits` precharge — the
    // `.link_terminal` arm owns exactly one bump per marker — and the terminal
    // continuation deopt must roll its own local count into the receipt.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The seed continuation at pc 2: an own guard (the k=2 terminal deopt names it)
    // then the `.link` terminal to the inner root at pc 7.
    const cont_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 9 }, // C's own source-branch guard
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .id = 301,
        .anchor = .{ .proto = &proto, .pc = 2 },
        .instrs = @constCast(&cont_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    // The inner root at pc 7: ends `.loop`, loop-done guard exits to pc 2 (== C's anchor).
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .id = 302,
        .anchor = .{ .proto = &proto, .pc = 7 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try state.cache.append(gpa, &cont);
    try state.cache.append(gpa, &inner);

    // C reached `.link` (cum 0), the fused inner committed one enclosing iteration
    // (cum 1), the re-entered C advanced twice more then deopted at its own guard
    // (cum 3, local 2).
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = 301, .exit = 1, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 1, .id = 302, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 3, .id = 301, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveSeedLedger(&cont, &entries, &proto, tr_regs.view(), false, .native_numeric_for_done);

    // Terminal continuation deopt with local 2: completed = linked_completed(1) + 2,
    // resume at the loop-done's post-loop pc (the continuation anchor, 2).
    try testing.expectEqual(@as(usize, 3), r.completed);
    try testing.expectEqual(@as(?u32, 2), r.resume_pc);
    // EXACTLY one `native_link_exits` — the seed's own `.link` marker, charged by the
    // replay's `.link_terminal` arm. A wrapper precharge would make this 2.
    try testing.expectEqual(@as(u64, 1), state.native_link_exits);
    // Not a coherent-anchor (prime-side) entry: no chain-follow firing signal.
    try testing.expectEqual(@as(u64, 0), state.prime_side_chain_follows);
    // onSideExit(inner, 1) and onSideExit(cont, 2), one penalty each (both < min_useful).
    try testing.expectEqual(@as(u32, 1), state.penalty.get(.{ .proto = &proto, .pc = 7 }).?);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(.{ .proto = &proto, .pc = 2 }).?);
}

test "jit coverage: per-hop cycles bill each hop's own anchor, never the entry anchor" {
    // The load-bearing anti-misattribution guarantee. A chain runs several hops
    // through `onSideExit`, each with its OWN anchor. Before the per-hop fix the
    // whole trace-exec span was charged to the *entry* anchor, so inner/continuation
    // anchors got iterations but zero cycles — the time split was untrustworthy.
    // This drives two hops at DISTINCT anchors with a cycle-burning spin *between*
    // them and asserts each anchor is billed its own span (both strictly > 0) and
    // the aggregate is exactly the sum — proving hop B's cycles land on anchor B,
    // not lumped onto entry anchor A.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.coverage = true;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 1 };

    // Minimal traces: `onSideExit` touches only `t.anchor` and `t.hit_count`.
    var entry = [_]u16{0};
    const instrs = [_]IrInstr{.{ .op = .loop }};
    const consts = [_]Value{};
    const trace_a = try gpa.create(Trace);
    defer gpa.destroy(trace_a);
    trace_a.* = .{
        .anchor = .{ .proto = &proto, .pc = 10 },
        .instrs = @constCast(&instrs),
        .consts = @constCast(&consts),
        .entry_slots = &entry,
        .entry_guards = &.{},
    };
    const trace_b = try gpa.create(Trace);
    defer gpa.destroy(trace_b);
    trace_b.* = .{
        .anchor = .{ .proto = &proto, .pc = 20 }, // DISTINCT anchor
        .instrs = @constCast(&instrs),
        .consts = @constCast(&consts),
        .entry_slots = &entry,
        .entry_guards = &.{},
    };

    const is_x86 = @import("builtin").target.cpu.arch == .x86_64;
    // Spin until rdtsc has advanced by `min` cycles — guarantees a strictly
    // positive span on x86_64; a no-op elsewhere (readCycles is 0 there).
    const spin = struct {
        fn burn(min: u64) void {
            if (@import("builtin").target.cpu.arch != .x86_64) return;
            const start = readCycles();
            while (readCycles() -% start < min) {}
        }
    }.burn;

    // Establish the hop boundary; the span up to onSideExit(A) bills anchor A.
    state.last_hop_tsc = readCycles();
    spin(4000);
    state.onSideExit(trace_a, 5);
    // The span between the two commits bills anchor B, not A.
    spin(4000);
    state.onSideExit(trace_b, 3);

    const cov_a = state.coverage.get(.{ .proto = &proto, .pc = 10 }).?;
    const cov_b = state.coverage.get(.{ .proto = &proto, .pc = 20 }).?;

    // Iterations: each hop bills its OWN committed count to its OWN anchor.
    try testing.expectEqual(@as(u64, 5), cov_a.traced);
    try testing.expectEqual(@as(u64, 3), cov_b.traced);
    try testing.expectEqual(@as(u64, 8), state.iters_traced);

    if (is_x86) {
        // Anti-misattribution: hop B's cycles landed on anchor B, not on entry A.
        // Both anchors carry a strictly positive, independently-earned span.
        try testing.expect(cov_a.traced_cycles > 0);
        try testing.expect(cov_b.traced_cycles > 0);
        // No cycles leaked or double-charged: aggregate == sum of per-anchor.
        try testing.expectEqual(
            state.cycles_traced,
            cov_a.traced_cycles + cov_b.traced_cycles,
        );
    }
}

test "driveBurstCore start_at_continuation: a run_continuation handover does not re-run the inner (real native)" {
    // 2c-E (the dormant double-run fix): a `replayLedger` terminal `run_continuation`
    // means the span's LAST inner loop-done already committed. The handed-over burst
    // must enter at call B (run the continuation) and SKIP call A — entering call A
    // first would try to run the inner again before the continuation. Proven with a
    // REAL native continuation: the correct path runs C exactly once (its register
    // effect is observable) and then breaks at the hop top when the inner has no
    // native code; the buggy call-A-first path would break BEFORE C ever ran.
    const builtin = @import("builtin");
    if (comptime !(builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The inner root at pc 7 — deliberately NATIVE-UNCOMPILABLE (an `add` on an
    // unproven operand bails codegen), so the hop top's `nativeFor(inner) orelse
    // break` ends the burst right after the continuation runs.
    const inner_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 0 }, // no covering guard_int → codegen bails
        .{ .op = .guard_true, .a = 1, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .id = 401,
        .anchor = .{ .proto = &proto, .pc = 7 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    // The continuation at pc 2 — genuinely compilable: r0 += 1 then `.link` to pc 7.
    // Its register effect (+1 on r0) is the witness that C ran exactly once.
    const cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .guard_int, .a = 0 }, // %1
        .{ .op = .konst, .aux = 0 }, // %2: 1
        .{ .op = .add, .a = 0, .b = 2 }, // %3: r0 + 1
        .{ .op = .phi, .b = 3, .aux = 0 }, // %4: r0 ← r0+1
        .{ .op = .link, .aux = 7 }, // %5
    };
    const cont_consts = [_]Value{Value.int(1)};
    var cont: Trace = .{
        .id = 402,
        .anchor = .{ .proto = &proto, .pc = 2 },
        .instrs = @constCast(&cont_instrs),
        .consts = @constCast(&cont_consts),
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    defer cont.native.deinit(); // lazily compiled below; free before the arena dies
    try state.cache.append(gpa, &inner);
    try state.cache.append(gpa, &cont);

    // A dispatcher-rooted span ending in a committed-but-unfused inner loop-done:
    // [I.done, C.link, I.done] → replay returns run_continuation(C) with hops=2 and
    // the burst enters at call B.
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = 401, .exit = 2, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 402, .exit = 5, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 2, .id = 401, .exit = 2, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(5)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);
    tr_regs.commit();

    // C ran natively EXACTLY once: r0 advanced 5 → 6. The buggy call-A-first path
    // breaks on `nativeFor(inner) == null` before C runs, leaving r0 == 5 (and would
    // report resume_pc == 2 instead of the post-C inner-root pc 7).
    try testing.expectEqual(@as(i64, 6), regs[0].asInt());
    // Replay committed 2 enclosing iterations; C's standalone `.link` then steered
    // `run_inner_from` → hop top → inner has no native code → burst ends at pc 7.
    try testing.expectEqual(@as(usize, 2), r.completed);
    try testing.expectEqual(@as(?u32, 7), r.resume_pc);
    // Two `.link` markers total: the synthetic k=1 entry + C's real native run.
    try testing.expectEqual(@as(u64, 2), state.native_link_exits);
    // Two continuation→inner follows: the fused `C.link → I` edge inside the
    // replayed span (2c-E: the non-last `.link_terminal` arm charges it, mirroring
    // the physical hop top) + the hop top resolving the inner once (the post-C hop).
    try testing.expectEqual(@as(u64, 2), state.native_link_follow_count);
    // The fused `I.loopdone → C` edge (entry 0 → 1) drained through the non-last
    // `.loop_done_linked` arm — the consumer-side counter fires even though nothing
    // was armed by THIS test (the ledger is synthetic).
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_fused);
    // The inner's codegen verdict memoized as unsupported (that's what ended the burst).
    try testing.expect(inner.native == .unsupported);
    // Both inner loop-dones charged low-yield entries on the inner anchor.
    try testing.expectEqual(@as(u32, 2), state.penalty.get(.{ .proto = &proto, .pc = 7 }).?);
}

test "replayLedger A-vii-a: region_bridge validates registered cross-anchor edge and accounts selection" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity(); // traces are stack-owned
    state.config.min_useful = 3;

    // The composite guard names bytecode exit PC 14, deliberately distinct from
    // the registered skip anchor PC 20. A successful result at 20 therefore proves
    // replay derived its coherent cursor from RegionDef, not guardExitPc.
    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    const proto = Proto{ .id = 41, .code = &code, .name = "region-bridge-replay", .num_registers = 1 };
    const guard_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 13,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 3, .prov = guard_prov }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 14 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .id = 601,
        .anchor = .{ .proto = &proto, .pc = 29 },
        .instrs = &cont_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_prov = &cont_prov,
    };
    var skip_instrs = [_]IrInstr{
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var skip: Trace = .{
        .id = 602,
        .anchor = .{ .proto = &proto, .pc = 20 },
        .instrs = &skip_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont, 3));
    try state.cache.append(gpa, &cont);
    try state.cache.append(gpa, &skip);

    // Synthesize the otherwise-unreachable A-vii-a inputs directly: the physical
    // backlink and the persistent registered edge. Missing, duplicate, tombstoned,
    // or successor-mismatched variants are explicit release-@panic branches in the
    // replay arm; this Zig stdlib has no in-process panic-expectation test helper.
    const rid: RegionId = @enumFromInt(91);
    try state.armed_links.append(gpa, .{ .parent = &cont, .slot_index = 3, .child = &skip, .kind = .region_bridge, .region_id = rid });
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = cont.anchor.pc,
            .exit = guard_prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = skip.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{}),
        .owner = cont.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });

    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
        .{ .cum = 5, .id = skip.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(
        &entries,
        &cont,
        7,
        &proto,
        &linked_completed,
        &resume_pc,
        &hops,
        8,
        .dispatcher_root,
        false,
    );

    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u32, 20), result.resume_pc);
    try testing.expectEqual(@as(usize, 2), result.completed);
    try testing.expectEqual(@as(u32, 20), resume_pc);
    // local=3 is nonzero and reaches accountTraceRun(cont, 3): at N=3 it is a
    // useful selection completion, so the owner gains exactly one hit and no
    // low-yield penalty. The terminal skip's own local=2 remains independently low.
    try testing.expectEqual(@as(u64, 1), cont.hit_count);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(cont.anchor));
    try testing.expectEqual(@as(u32, 1), state.penalty.get(skip.anchor).?);
}

test "A-vii-d.1 overlay: composite guard resolves the opposite-polarity CFG successor (jmp walk, polarity flip, self-edge decline)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // Static CFG: jmp_if_true at 5 (jump target 6+4=10); fallthrough pc 6 is an
    // unconditional jmp to 8. A recorded-`.taken` composite guard therefore fails
    // onto the FALLTHROUGH edge (6 → jmp → 8); a recorded-`.fallthrough` one onto
    // the JUMP edge (10). No trace is bound at the H-1b exit pc 6, so the
    // ordinary `guardExitPc` rule yields nothing — only the overlay resolves.
    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 4);
    code[6] = Instr.opAx(.jmp, 0, 1);
    const proto = Proto{ .id = 51, .code = &code, .name = "overlay", .num_registers = 1 };

    const mkProv = struct {
        fn f(p: Polarity) ExitProvenance {
            return .{ .guard = .{
                .source_proto_id = 51,
                .source_pc = 5,
                .role = .branch_cond,
                .operand = .a,
                .polarity = p,
            } };
        }
    }.f;
    var taken_prov = [_]ExitProvEntry{.{ .index = 3, .prov = mkProv(.taken) }};
    var ft_prov = [_]ExitProvEntry{.{ .index = 3, .prov = mkProv(.fallthrough) }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 6 }, // exit pc 6 → source jmp_if at 5
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{ .id = 701, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &taken_prov };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont, 3));

    // No successor trace bound anywhere yet → both polarities decline.
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&cont, cont.exit_prov[0]));

    // Bind skip@8 (reached from the fallthrough edge via the jmp at 6).
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .loop } };
    var skip: Trace = .{ .id = 702, .anchor = .{ .proto = &proto, .pc = 8 }, .instrs = &skip_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &skip);
    const succ_taken = state.resolveSuccessorAnchor(&cont, cont.exit_prov[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 51), succ_taken.proto_id);
    try testing.expectEqual(@as(u32, 8), succ_taken.pc);

    // Recorded `.fallthrough` fails onto the JUMP edge (pc 10) instead.
    var other_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .loop } };
    var other: Trace = .{ .id = 703, .anchor = .{ .proto = &proto, .pc = 10 }, .instrs = &other_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &other);
    cont.exit_prov = &ft_prov;
    const succ_ft = state.resolveSuccessorAnchor(&cont, cont.exit_prov[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 10), succ_ft.pc);

    // Self-edge decline: the same shape anchored at 8 walks 6 → jmp → 8 == its
    // own anchor — never a cross-anchor handoff.
    var selfy: Trace = .{ .id = 704, .anchor = .{ .proto = &proto, .pc = 8 }, .instrs = &cont_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &taken_prov };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&selfy, 3));
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&selfy, selfy.exit_prov[0]));
}

test "A-vii-d.1 overlay: a crossed for_loop is published ONLY under the exact-dataflow continue proof" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // jmp_if_true at 5; the fallthrough pc 6 is a numeric for_loop whose
    // continue edge lands at 6+1+2 = 9, where the successor trace is bound.
    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 10);
    code[6] = Instr.opAx(.for_loop, 0, 2); // base register a=0; continue target 9
    const proto = Proto{ .id = 52, .code = &code, .name = "overlay-forloop", .num_registers = 8 };

    const branch_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = 52,
        .source_pc = 5,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    const loopdone_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = 52,
        .source_pc = 6,
        .role = .loop_done,
        .operand = .a,
        .polarity = .neutral,
    } };

    // The exact recForLoop shape (proof-satisfying): one add (R=2) stepping the
    // index, a dominating loop-continue guard whose `le` consumes R, and
    // slot-bound phis for BOTH for_loop-written slots {a=0, a+3=3} sharing R.
    var good_prov = [_]ExitProvEntry{
        .{ .index = 4, .prov = loopdone_prov },
        .{ .index = 7, .prov = branch_prov },
    };
    var good_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0
        .{ .op = .konst, .aux = 0 }, // %1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = R
        .{ .op = .le, .a = 2, .b = 1 }, // %3 consumes R
        .{ .op = .guard_true, .a = 3, .aux = 7 }, // %4 loop-done (source pc 6)
        .{ .op = .phi, .b = 2, .aux = 0 }, // idx slot
        .{ .op = .phi, .b = 2, .aux = 3 }, // var slot, same R
        .{ .op = .guard_true, .a = 0, .aux = 6 }, // %7 composite (source pc 5)
        .{ .op = .link, .aux = 9 },
    };
    var good: Trace = .{ .id = 711, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &good_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &good_prov };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&good, 7));

    var skip_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .loop } };
    var skip: Trace = .{ .id = 712, .anchor = .{ .proto = &proto, .pc = 9 }, .instrs = &skip_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &skip);

    const succ = state.resolveSuccessorAnchor(&good, good.exit_prov[1]) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 9), succ.pc);

    // Proof violation 1: the var slot's phi is missing (bound to a different
    // slot) — the crossed op's written set is not fully re-materialized.
    var noval_instrs = good_instrs;
    noval_instrs[6] = .{ .op = .phi, .b = 2, .aux = 4 }; // not base+3
    var noval: Trace = .{ .id = 713, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &noval_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &good_prov };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&noval, 7));
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&noval, noval.exit_prov[1]));

    // Proof violation 2: no dominating loop-continue guard consuming R (the
    // le compares a different ref) — the continue edge is unproven.
    var nocmp_instrs = good_instrs;
    nocmp_instrs[3] = .{ .op = .le, .a = 0, .b = 1 }; // consumes %0, not R
    var nocmp: Trace = .{ .id = 714, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &nocmp_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &good_prov };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&nocmp, 7));
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&nocmp, nocmp.exit_prov[1]));
}

test "A-vii-d.1 bridged successor terminal: a loop-body successor deopt resumes at ITS anchor, ordinary loop-done included" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();
    state.config.min_useful = 3;

    // Same wiring as the A-vii-a replay test, but the bridged successor ends
    // `.loop` — the REAL nsieve shape (an outer-header body trace), not the
    // synthetic `.link` skip. Its terminal deopt must resume at its OWN anchor
    // (the coherent-anchor discipline for ordinary-mode runs), never `link_pc`,
    // and an ordinary-mode loop-done deopt is legitimate (mode 0 bypasses the
    // linked slot).
    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    code[19] = Instr.opAx(.for_loop, 0, 2); // makes skip's guard a loop-done index
    const proto = Proto{ .id = 42, .code = &code, .name = "bridged-loop-succ", .num_registers = 1 };
    const guard_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 13,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 3, .prov = guard_prov }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 14 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{ .id = 621, .anchor = .{ .proto = &proto, .pc = 29 }, .instrs = &cont_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_prov };
    // skip@25 ends `.loop`; its guard's exit pc 20 sits right after the
    // for_loop at 19 → `isLoopDoneGuardIndex` is TRUE for exit 0.
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var skip: Trace = .{ .id = 622, .anchor = .{ .proto = &proto, .pc = 25 }, .instrs = &skip_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont, 3));
    try testing.expect(isLoopDoneGuardIndex(&skip, 0));
    try state.cache.append(gpa, &cont);
    try state.cache.append(gpa, &skip);

    const rid: RegionId = @enumFromInt(92);
    try state.armed_links.append(gpa, .{ .parent = &cont, .slot_index = 3, .child = &skip, .kind = .region_bridge, .region_id = rid });
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = cont.anchor.pc,
            .exit = guard_prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = skip.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{}),
        .owner = cont.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });

    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
        .{ .cum = 5, .id = skip.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false);
    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    // Resume at skip's OWN anchor (25) — the bridge row published it — with the
    // successor's committed local rolled up; `link_pc` (7) must never surface.
    try testing.expectEqual(@as(u32, 25), result.resume_pc);
    try testing.expectEqual(@as(usize, 2), result.completed);
    try testing.expectEqual(@as(u64, 1), state.native_region_bridge_fused);
}

test "A-vii-d.1 bridged .link successor (codex blocker): zero-progress deopt and prologue-fail return the bridged contract, never break_burst" {
    // A bridged successor ending `.link` is legal (bridge validation requires
    // zero inputs + ordinary_entry, not a `.loop` terminator). Its
    // zero-progress terminal rows must take the bridged contract — charge the
    // SUCCESSOR and resume at its anchor — never the seed-continuation
    // `break_burst`, whose hop-0 tail would charge the BRIDGE PARENT a second
    // time on top of the `.region_bridge` row's own accounting.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();
    state.config.min_useful = 3;

    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    const proto = Proto{ .id = 43, .code = &code, .name = "bridged-link-succ", .num_registers = 1 };
    const guard_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 13,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 3, .prov = guard_prov }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 14 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{ .id = 631, .anchor = .{ .proto = &proto, .pc = 29 }, .instrs = &cont_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_prov };
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .link, .aux = 7 } };
    var skip: Trace = .{ .id = 632, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &skip_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &cont);
    try state.cache.append(gpa, &skip);
    const rid: RegionId = @enumFromInt(93);
    try state.armed_links.append(gpa, .{ .parent = &cont, .slot_index = 3, .child = &skip, .kind = .region_bridge, .region_id = rid });
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = cont.anchor.pc,
            .exit = guard_prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = skip.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{}),
        .owner = cont.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });

    // (a) Zero-progress deopt (cum unchanged across the successor segment).
    {
        const entries = [_]irinterp.LedgerEntry{
            .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
            .{ .cum = 3, .id = skip.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        };
        var linked_completed: usize = 0;
        var resume_pc: u32 = 999;
        var hops: usize = 0;
        const dir = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false);
        const result = switch (dir) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult, // break_burst = the bug
        };
        try testing.expectEqual(@as(u32, 20), result.resume_pc);
        try testing.expectEqual(@as(usize, 0), result.completed);
    }
    // (b) Prologue-fail (pre-commit, exit = maxInt, local == 0).
    {
        const entries = [_]irinterp.LedgerEntry{
            .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
            .{ .cum = 3, .id = skip.id, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
        };
        var linked_completed: usize = 0;
        var resume_pc: u32 = 999;
        var hops: usize = 0;
        const dir = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false);
        const result = switch (dir) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult, // break_burst = the bug
        };
        try testing.expectEqual(@as(u32, 20), result.resume_pc);
        try testing.expectEqual(@as(usize, 0), result.completed);
    }
    // The bridge parent was charged ONLY by its `.region_bridge` rows (useful
    // at N=3): no penalty ever lands on the parent anchor from the successor's
    // zero-progress terminals.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(cont.anchor));
}

test "A-vii-d.1 disarm deferral: disarmAllLinks defers mid-replay-walk; applyPendingDisarms applies it and drops the pending arm" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "t", .num_registers = 1 };
    var p_i = [_]IrInstr{.{ .op = .loop }};
    var parent: Trace = .{ .id = 801, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &p_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var c_i = [_]IrInstr{.{ .op = .loop }};
    var child: Trace = .{ .id = 802, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &c_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.armed_links.append(gpa, .{ .parent = &parent, .slot_index = 0, .child = &child, .kind = .ordinary_guard });

    // Mid-walk: the registry must stay intact (later rows of the ledger being
    // walked validate against it) and the request must be recorded.
    state.replay_walk_depth = 1;
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    try testing.expect(state.pending_disarm_all);
    try testing.expectEqual(@as(u64, 0), state.native_link_disarms);

    // Driver-side application: registry cleared, counter charged, and any
    // pending bridge-arm request from the same walk dropped (fail-closed —
    // never disarm-then-re-arm into a complex the gate just condemned).
    state.replay_walk_depth = 0;
    state.pending_bridge_arm = .{ .trace_id = 801, .exit_instr = 0 };
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expect(!state.pending_disarm_all);
    try testing.expectEqual(@as(?ExitKey, null), state.pending_bridge_arm);
    try testing.expectEqual(@as(u64, 1), state.native_link_disarms);

    // Idempotent when nothing is pending.
    state.applyPendingDisarms();
    try testing.expectEqual(@as(u64, 1), state.native_link_disarms);
}

test "A-vii-d.1 stale-region lifecycle: a rebuild disarms region_bridge links whose region is no longer live-armable; other kinds survive" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "t", .num_registers = 1 };
    var p_i = [_]IrInstr{.{ .op = .loop }};
    var parent: Trace = .{ .id = 811, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &p_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var c_i = [_]IrInstr{.{ .op = .loop }};
    var child: Trace = .{ .id = 812, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &c_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    // One bridge link armed under a region this pass will NOT re-discover
    // (empty cache → empty live-armable set) and one M1 link, which the
    // targeted sweep must never touch.
    try state.armed_links.append(gpa, .{ .parent = &parent, .slot_index = 0, .child = &child, .kind = .region_bridge, .region_id = @enumFromInt(9) });
    try state.armed_links.append(gpa, .{ .parent = &parent, .slot_index = 1, .child = &child, .kind = .ordinary_guard });

    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    try testing.expect(state.armed_links.items[0].kind == .ordinary_guard);
    try testing.expectEqual(@as(u64, 1), state.native_link_disarms);
}

test "A-vii-d.1 two-phase arming: a terminal composite deopt records ONE pending arm request, never arms mid-walk" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 4);
    const proto = Proto{ .id = 53, .code = &code, .name = "pending-arm", .num_registers = 1 };
    const guard_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 5,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 3, .prov = guard_prov }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 6 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{ .id = 821, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_prov };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont, 3));
    try state.cache.append(gpa, &cont);

    // A terminal composite `.deopt` (the seed's OWN guard) must record the
    // pending request and change nothing else — the armed-link registry stays
    // untouched until a DRIVER drains the request after the walk.
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 2, .id = cont.id, .exit = 3, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    _ = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false);
    const pending = state.pending_bridge_arm orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 821), pending.trace_id);
    try testing.expectEqual(@as(u32, 3), pending.exit_instr);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // A later walk with a non-composite terminal clears the stale request
    // (never inherited across ledgers).
    var plain_prov = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .guard = .{ .source_proto_id = proto.id, .source_pc = 1, .role = .operand_type, .operand = .a } } }};
    var plain_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .link, .aux = 7 } };
    var plain: Trace = .{ .id = 822, .anchor = .{ .proto = &proto, .pc = 21 }, .instrs = &plain_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &plain_prov };
    try state.cache.append(gpa, &plain);
    const entries2 = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = plain.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    _ = state.replayLedger(&entries2, &plain, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false);
    try testing.expectEqual(@as(?ExitKey, null), state.pending_bridge_arm);
}

test "replayLedger forced yield (2c-B/2c-E): a CAP-length ledger ending .yielded replays cleanly" {
    // The forced-yield cap (2c-B): a closed native C↔I cycle keeps appending a
    // per-transition ledger entry; at `LEDGER_CAP` (32) the armed chain source
    // jumps to `shared_exit` instead of its successor and stamps the last entry
    // `.yielded`. `replayLedger` must ACCEPT exactly that shape — a full ledger
    // whose final entry is `.yielded` — without tripping the structural guard
    // (which panics on a `.yielded` that is NOT last-of-full), account every
    // committed enclosing iteration, and hand back a resume directive.
    //
    // Shape: 16 alternating `[I.loop_done_linked(fused), C.link_terminal]` pairs =
    // 32 entries; the terminal (a `.link`) is stamped `.yielded`. No arming
    // happens (the terminal is a `.link`, not a loop-done), so plain non-compiled
    // traces suffice and this runs on every host.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .id = 501,
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 }, // links back to the inner root at pc 5
    };
    var cont: Trace = .{
        .id = 502,
        .anchor = .{ .proto = &proto, .pc = 2 },
        .instrs = @constCast(&cont_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try state.cache.append(gpa, &inner);
    try state.cache.append(gpa, &cont);

    // Build the CAP-length alternating ledger. Even index = I.loop_done_linked
    // (fused into the next C), odd = C.link_terminal (fused back into the next I),
    // except the final C.link which is the forced-yield terminal.
    var entries: [irinterp.LEDGER_CAP]irinterp.LedgerEntry = undefined;
    var iter: usize = 0;
    while (iter < irinterp.LEDGER_CAP) : (iter += 1) {
        const is_inner = (iter % 2 == 0);
        const enclosing = iter / 2 + 1; // 1,1,2,2,3,3,… — one increment per I.done
        const is_last = iter + 1 == irinterp.LEDGER_CAP;
        entries[iter] = if (is_inner) .{
            .cum = enclosing,
            .id = 501,
            .exit = 0,
            .reason = .normal,
            .kind = .loop_done_linked,
            .outcome = .normal,
        } else .{
            .cum = enclosing,
            .id = 502,
            .exit = 0,
            .reason = .normal,
            .kind = .link_terminal,
            .outcome = if (is_last) .yielded else .normal,
        };
    }

    var linked_completed: usize = 0;
    var resume_pc: u32 = 0;
    var hops: usize = 0;
    // safe_to_arm = false: the terminal is a `.link` (never arms), and this test
    // isolates the forced-yield ACCEPTANCE, not arming.
    const dir = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false);

    // Every one of the 16 loop-dones committed an enclosing iteration.
    try testing.expectEqual(@as(usize, 16), linked_completed);
    // The forced-yield `.link` terminal resumes by running the inner fresh at the
    // PC it names (pc 5), carrying itself as the `.link` driver.
    switch (dir) {
        .run_inner_from => |owner| try testing.expectEqual(@as(*Trace, &cont), owner),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 5), resume_pc);
    // 16 `.link` markers seen (one per C.link entry).
    try testing.expectEqual(@as(u64, 16), state.native_link_exits);
}

test "replayLedger convergence (2c-E site 3): a TERMINAL loop_done_linked arms the I→C slot" {
    // The convergence arm (trace.zig site 3, the `is_last` branch of
    // `.loop_done_linked`): a sibling inner reached ONLY through replay — never
    // through a scalar arm site (call A / driveChain) — must still converge to
    // armed, so the NEXT occurrence of its loop-done fuses. Here a synthetic
    // TERMINAL `[I.done(fused), C.link, I.done]` ledger drains through
    // `replayLedger` with `safe_to_arm = true`; the terminal `I.done` has no
    // successor to fuse into, so it arms `I.slot[loop-done] → C.ordinary_entry`
    // in place and hands back `run_continuation(C)`.
    //
    // Hand-built `.compiled` stubs (page undefined, heap `slots`) — same pattern
    // as the P-E registry test — so this needs no real codegen and runs on every
    // host: `replayLedger` only READS trace shape and ACCOUNTS/ARMS, it never
    // executes native code. `armLoopDoneLink` needs both halves `.compiled`
    // (inner as the arm's parent, cont for `nativeFor(cont).ordinary_entry`).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    // Drop the hand-built stubs from the cache before deinit: their `page` is
    // undefined, so `destroy`→`native.deinit`→`page.deinit` would fault. We free
    // the two `slots` arrays ourselves below.
    defer state.cache.clearRetainingCapacity();

    // code[1] is a for_loop, so the inner's guard_true (exit_pc 2) is a loop-done.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // instr 0: loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    const inner_slots = try gpa.alloc(usize, inner_instrs.len);
    defer gpa.free(inner_slots);
    @memset(inner_slots, 0); // 0 == "unarmed" (no trampoline in this unit test)
    var inner: Trace = .{
        .id = 301,
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = inner_slots, .gpa = gpa } },
    };
    // The continuation at post-loop pc 2: zero-input, ends `.link` back to pc 5.
    // Its `ordinary_entry` is the exact address the arm must write into the inner's
    // loop-done slot (the fused hop targets ORDINARY mode — 2.3c-0c).
    const CONT_ORDINARY_ENTRY: usize = 0xC0FFEE_1234;
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    const cont_slots = try gpa.alloc(usize, cont_instrs.len);
    defer gpa.free(cont_slots);
    @memset(cont_slots, 0);
    var cont: Trace = .{
        .id = 302,
        .anchor = .{ .proto = &proto, .pc = 2 },
        .instrs = @constCast(&cont_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = cont_slots, .gpa = gpa, .ordinary_entry = CONT_ORDINARY_ENTRY } },
    };
    try state.cache.append(gpa, &inner);
    try state.cache.append(gpa, &cont);

    // [I.done(fused) → C.link → I.done(terminal)]: the first loop-done fuses into
    // C, C links back to the inner root, and the second loop-done is TERMINAL (no
    // successor) — the convergence-arm site.
    const entries = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = 301, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 302, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 2, .id = 301, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
    };

    var linked_completed: usize = 0;
    var resume_pc: u32 = 0;
    var hops: usize = 0;
    const dir = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, true);

    // The terminal loop-done armed the convergence edge EXACTLY once, writing the
    // continuation's `ordinary_entry` into the inner's loop-done slot (instr 0).
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_arms);
    try testing.expectEqual(CONT_ORDINARY_ENTRY, inner_slots[0]);
    // One armed-link record: parent = inner, slot = 0 (the loop-done instr), child = cont.
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    const rec = state.armed_links.items[0];
    try testing.expectEqual(@as(*Trace, &inner), rec.parent);
    try testing.expectEqual(@as(u32, 0), rec.slot_index);
    try testing.expectEqual(@as(*Trace, &cont), rec.child);
    // The one INTERIOR loop-done (k=0) fused; the terminal one (k=2) did not.
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_fused);
    // The directive runs the continuation (regs coherent at its anchor, pc 2).
    switch (dir) {
        .run_continuation => |c| try testing.expectEqual(@as(*Trace, &cont), c),
        else => return error.TestUnexpectedResult,
    }
    // Two enclosing iterations committed (one per loop-done), resume at pc 2.
    try testing.expectEqual(@as(usize, 2), linked_completed);
    try testing.expectEqual(@as(u32, 2), resume_pc);

    // Manually drop the armed record BEFORE the deferred cache-clear so no dangling
    // record references the stack traces after the test frame unwinds. (Both slots
    // are freed by the earlier `defer gpa.free`; the stubs are never `destroy`d.)
    state.armed_links.clearRetainingCapacity();
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

fn testGuardProv(pc: u32, role: GuardRole, operand: OperandDesig) ExitProvenance {
    return .{ .guard = .{ .source_proto_id = 7, .source_pc = pc, .role = role, .operand = operand } };
}

test "buildExitProv: remap through a compaction map, drop non-survivors, sort (A-i.1)" {
    const gpa = testing.allocator;
    const a = testGuardProv(10, .operand_type, .b);
    const b = testGuardProv(20, .branch_cond, .a);
    // %0 no prov; %1 = A → committed 1; %2 = B → DROPPED (map null); %3 no prov.
    const rec = [_]?ExitProvenance{ null, a, b, null };
    const map = [_]?Ref{ 0, 1, null, 2 };
    const out = try buildExitProv(gpa, &rec, &map, null);
    defer if (out.len != 0) gpa.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].index);
    try testing.expectEqual(@as(u32, 10), out[0].prov.guard.source_pc);
}

test "buildExitProv: null map is the identity (dupe path), result stays sorted (A-i.1)" {
    const gpa = testing.allocator;
    const a = testGuardProv(10, .operand_type, .b);
    const b = testGuardProv(20, .branch_cond, .a);
    const rec = [_]?ExitProvenance{ null, a, null, b }; // committed == emission (identity)
    const out = try buildExitProv(gpa, &rec, null, null);
    defer if (out.len != 0) gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].index);
    try testing.expectEqual(@as(u32, 3), out[1].index);
    // Sorted ascending → binary search via provAt works.
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = @constCast(out) };
    try testing.expect(t.provAt(0) == null);
    try testing.expectEqual(@as(u32, 10), t.provAt(1).?.guard.source_pc);
    try testing.expect(t.provAt(2) == null);
    try testing.expectEqual(@as(u32, 20), t.provAt(3).?.guard.source_pc);
    try testing.expect(t.provAt(4) == null);
}

test "pathFromFrames: f(a);f(b) at distinct call sites give distinct inline paths (A-i.2)" {
    // Same callee proto inlined at two different `.call` PCs must yield distinct
    // provenance — the collision H-1a fixes. `pathFromFrames` distinguishes them by
    // `call_pc` even though `caller_proto_id` is identical.
    const frames = [_]InlineFrame{
        .{ .base_off = 0, .ret_dest = 0, .ret_count = 0, .caller_proto_id = 3, .call_pc = 11 },
        .{ .base_off = 8, .ret_dest = 0, .ret_count = 0, .caller_proto_id = 3, .call_pc = 42 },
    };
    const p1 = pathFromFrames(&frames, 1);
    try testing.expectEqual(@as(u32, 3), p1[0].caller_proto_id);
    try testing.expectEqual(@as(u32, 11), p1[0].call_pc);
    const p2 = pathFromFrames(&frames, 2);
    try testing.expectEqual(@as(u32, 11), p2[0].call_pc);
    try testing.expectEqual(@as(u32, 42), p2[1].call_pc); // second edge is the distinguisher
    // Depth-0 (anchor frame, no inlining) reads no edges.
    _ = pathFromFrames(&frames, 0);
}

test "buildExitProv: empty when nothing survives → static slice, no alloc (A-i.1)" {
    const gpa = testing.allocator;
    const a = testGuardProv(10, .operand_type, .b);
    const rec = [_]?ExitProvenance{ null, a, null };
    const map = [_]?Ref{ 0, null, 1 }; // the only prov is dropped
    const out = try buildExitProv(gpa, &rec, &map, null);
    try testing.expectEqual(@as(usize, 0), out.len); // static empty; no free needed
}

test "A-i.3 stamp: arith operand guards carry (operand_type, b/c) and source_pc = pc−1" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.int(10), Value.int(20) };
    // add r0,r1,r2 at guest PC 42 → post-increment cur_pc, so source_pc == 41.
    state.recordInstr(Instr.opABC(.add, 0, 1, 2), winRO(&regs), &proto, 42, Value.nil());
    const prov = state.rec.exit_prov.items;
    // instrs: slot_load, slot_load, guard_int(r1)=#2, guard_int(r2)=#3, add → lockstep len 5.
    try testing.expectEqual(state.rec.instrs.items.len, prov.len);
    const g1 = prov[2].?.guard;
    try testing.expectEqual(GuardRole.operand_type, g1.role);
    try testing.expectEqual(OperandDesig.b, g1.operand);
    try testing.expectEqual(@as(u32, 41), g1.source_pc); // cur_pc − 1
    try testing.expectEqual(Polarity.neutral, g1.polarity);
    const g2 = prov[3].?.guard;
    try testing.expectEqual(OperandDesig.c, g2.operand);
    try testing.expectEqual(@as(u32, 41), g2.source_pc);
    // Non-guard nodes (loads, the arith result) carry no provenance.
    try testing.expect(prov[0] == null);
    try testing.expect(prov[1] == null);
    try testing.expect(prov[4] == null);
}

test "A-i.3 stamp: int↔float re-record keeps guard identity (only the IR op differs)" {
    const gpa = testing.allocator;
    // Re-recording the same guest site with a float operand must yield the SAME
    // (role, operand, source_pc) — the identity keys on the guest site, not the
    // observed type. Only the emitted IR op flips guard_int → guard_float.
    inline for (.{ .{ Value.int(10), Value.int(20), IrOp.guard_int }, .{ Value.float(1.5), Value.float(2.5), IrOp.guard_float } }) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), c[0], c[1] };
        state.recordInstr(Instr.opABC(.add, 0, 1, 2), winRO(&regs), &proto, 42, Value.nil());
        try testing.expectEqual(c[2], state.rec.instrs.items[2].op); // op differs by type
        const g = state.rec.exit_prov.items[2].?.guard;
        try testing.expectEqual(GuardRole.operand_type, g.role); // identity does NOT
        try testing.expectEqual(OperandDesig.b, g.operand);
        try testing.expectEqual(@as(u32, 41), g.source_pc);
    }
}

test "A-i.3 stamp: branch polarity keys on the guest jump-taken edge, not raw truthiness" {
    const gpa = testing.allocator;
    // Polarity names which guest CFG edge the recorded path took, keyed on the
    // opcode's *jump-taken* edge — NOT truthiness. `jmp_if_false` jumps when falsy;
    // `jmp_if_true` jumps when truthy. So for one operand value the two opcodes give
    // OPPOSITE polarity, while the guard op (true/false) tracks truthiness alone.
    // { opcode, operand, expected guard op, expected polarity }.
    inline for (.{
        .{ bytecode.OpCode.jmp_if_false, Value.int(1), IrOp.guard_true, Polarity.fallthrough }, // truthy: doesn't jump
        .{ bytecode.OpCode.jmp_if_false, Value.boolean(false), IrOp.guard_false, Polarity.taken }, // falsy: jumps
        .{ bytecode.OpCode.jmp_if_true, Value.int(1), IrOp.guard_true, Polarity.taken }, // truthy: jumps
        .{ bytecode.OpCode.jmp_if_true, Value.boolean(false), IrOp.guard_false, Polarity.fallthrough }, // falsy: doesn't jump
    }) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ c[1], Value.nil() };
        state.recordInstr(Instr.opABC(c[0], 0, 0, 0), winRO(&regs), &proto, 7, Value.nil());
        try testing.expectEqual(c[2], state.rec.instrs.items[1].op);
        const g = state.rec.exit_prov.items[1].?.guard;
        try testing.expectEqual(GuardRole.branch_cond, g.role);
        try testing.expectEqual(OperandDesig.a, g.operand);
        try testing.expectEqual(@as(u32, 6), g.source_pc); // 7 − 1
        try testing.expectEqual(c[3], g.polarity);
    }
}

test "buildExitProv: a .link terminal entry is injected and sorts last (A-i.4)" {
    const gpa = testing.allocator;
    // A guard at emission %1 (survives as committed 1) plus the `.link` terminal at
    // committed index 4 (appended directly at commit — no lockstep slot). The link
    // entry must appear in the output, sorted after the guard.
    const g = testGuardProv(10, .operand_type, .b);
    const rec = [_]?ExitProvenance{ null, g, null };
    const link = ExitProvEntry{ .index = 4, .prov = .{ .link_terminal = .{ .source_proto_id = 7, .source_pc = 41 } } };
    const out = try buildExitProv(gpa, &rec, null, link);
    defer if (out.len != 0) gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].index); // guard first
    try testing.expect(out[0].prov == .guard);
    try testing.expectEqual(@as(u32, 4), out[1].index); // link terminal last
    try testing.expect(out[1].prov == .link_terminal);
    try testing.expectEqual(@as(u32, 41), out[1].prov.link_terminal.source_pc);
}

test "A-i.4 transport: recForPrepLink commits a .link trace carrying .link_terminal provenance" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    // The inner root below is stack-allocated (never heap-freed); the committed link
    // trace IS heap-allocated. Free the committed one explicitly, then drop both cache
    // pointers before `deinit` so it never calls `destroy` on the stack trace.
    var committed: ?*Trace = null;
    defer state.deinit();
    defer {
        if (committed) |ct| ct.destroy(gpa);
        state.cache.clearRetainingCapacity();
    }

    // Bytecode shape: `for_prep` recorded at post-increment pc 5 (its guest opcode is
    // at index 4), jumping +2 to the `for_loop` at index 7, whose back-edge (−3) lands
    // on the inner-root anchor pc 5. Only code[7] is read by recForPrepLink.
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.load_nil);
    code[7] = Instr.opJ(.for_loop, -3);
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 4 };

    // A pre-existing inner `.loop` root at (proto, 5) — LINNER only links if one exists.
    const inner_instrs = [_]IrInstr{.{ .op = .loop }};
    var inner: Trace = .{
        .id = 900,
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = @constCast(&inner_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try state.cache.append(gpa, &inner);

    // Arm a *continuation* recording (a `.root` recording aborts LINNER at for_prep).
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 2 }, proto.num_registers);
    state.rec.kind = .continuation;

    // for_prep a=0 aux=+2, control regs R[0..2] = init/limit/step (all int).
    var regs = [_]Value{ Value.int(1), Value.int(10), Value.int(1), Value.nil() };
    state.recordInstr(Instr.opAx(.for_prep, 0, 2), winRO(&regs), &proto, 5, Value.nil());

    // Recording closed (committed a `.link` trace). The new trace is last in cache.
    try testing.expect(!state.isRecording());
    const t = state.cache.items[state.cache.items.len - 1];
    committed = t; // hand to the cleanup defer
    try testing.expect(t.id != 900); // not the pre-seeded inner root
    const last = t.instrs.len - 1;
    try testing.expectEqual(IrOp.link, t.instrs[last].op);
    try testing.expectEqual(@as(i32, 5), t.instrs[last].aux); // links to inner anchor pc 5

    // The `.link` terminal's provenance is present at the terminal's committed index.
    const prov = t.provAt(@intCast(last)) orelse return error.MissingLinkProvenance;
    try testing.expect(prov == .link_terminal);
    try testing.expectEqual(@as(u32, 4), prov.link_terminal.source_pc); // cur_pc 5 − 1
    try testing.expectEqual(@as(u8, 0), prov.link_terminal.inline_depth); // never inlined
}

test "A-vii-c split: regionless onSideExit keeps the legacy gate; bare accountTraceRun is selection-only" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    // The A-vii-c ownership boundary (replacing the pre-flip A-ii.1 equivalence
    // pin): the `onSideExit` wrapper on a REGIONLESS trace reproduces the full
    // pre-flip behavior via `accountLegacyThrash` (strikes → gate at max_penalty;
    // a useful segment clears both), while bare `accountTraceRun` now touches
    // ONLY coverage + `hit_count` — never `penalty`/`gate`.
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 1 };
    var t_wrap: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var t_bare: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 1 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    // Feed exactly max_penalty low-yield events through both entry points.
    var i: u32 = 0;
    while (i < state.config.max_penalty) : (i += 1) {
        state.onSideExit(&t_wrap, 0);
        state.accountTraceRun(&t_bare, 0);
    }
    // The regionless wrapper gates exactly like the pre-flip machine; the bare
    // selection half no longer strikes at all.
    try testing.expect(state.isGated(t_wrap.anchor));
    try testing.expect(!state.isGated(t_bare.anchor));
    try testing.expectEqual(@as(u32, state.config.max_penalty), state.penalty.get(t_wrap.anchor).?);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(t_bare.anchor));
    try testing.expectEqual(@as(u64, 0), t_wrap.hit_count);
    try testing.expectEqual(@as(u64, 0), t_bare.hit_count);

    // A useful exit bumps hit_count through BOTH entry points, and clears the
    // wrapper anchor's penalty AND gate (legacy recovery semantics).
    state.onSideExit(&t_wrap, state.config.min_useful);
    state.accountTraceRun(&t_bare, state.config.min_useful);
    try testing.expectEqual(@as(u64, 1), t_wrap.hit_count);
    try testing.expectEqual(@as(u64, 1), t_bare.hit_count);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(t_wrap.anchor));
    try testing.expect(!state.isGated(t_wrap.anchor));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    try testing.expectEqual(@as(usize, 0), state.gate.count());
}

test "A-vii-c gate machine: N=8 windows qualify+clear the owner, sub-N remainders strike, max_penalty gates and disarms" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A live self-loop region with a real owner anchor (the A-iv harness idiom).
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .id = 61, .code = &code, .name = "gate", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(3);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{.{ .proto_id = 61, .source_pc = 0 }}),
        .owner = .{ .proto = &proto, .pc = 0 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    const owner: AnchorKey = .{ .proto = &proto, .pc = 0 };
    const exit: ExitKey = .{ .trace_id = 9, .exit_instr = 0 };
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };
    // This test pins the design constant N = min_useful = 8 (doc 17 §A8-iii test 4).
    try testing.expectEqual(@as(u32, 8), state.config.min_useful);

    // (1) Seven traversals: no complete window — no flush, no qualification, no strike.
    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 7, .deferred);
    try testing.expect(!state.region_profit.get(key).?.useful_window_seen);
    try testing.expectEqual(@as(u64, 0), state.region_profit_flushes);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));

    // Pre-seed a penalty AND an active gate on the owner: the full window must clear BOTH.
    try state.penalty.put(gpa, owner, 3);
    state.gateAnchor(owner);
    try testing.expect(state.isGated(owner));

    // (2) The eighth traversal completes exactly one N window: one useful flush,
    // qualification latched, owner penalty and gate both removed.
    _ = state.accountRegionProfit(exit, 1, .deferred);
    try testing.expect(state.region_profit.get(key).?.useful_window_seen);
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));
    try testing.expect(!state.isGated(owner));

    // (3) Exact-N exit: the observer-driven close right after a full window emits
    // NO zero-remainder flush (R2-1) and no spurious strike.
    state.observeRegionProgramPoint(61, 1, 1, 5);
    try testing.expectEqual(@as(usize, 0), state.regionProfitCount());
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));

    // (4) Arm a link, then repeated 1-traversal open/exit cycles each flush an
    // r=1 low-yield remainder striking the OWNER; at max_penalty the owner gates
    // and the gate install conservatively disarms EVERY armed link.
    const SHARED_EXIT: usize = 0;
    const parent_slots = try gpa.alloc(usize, 1);
    defer gpa.free(parent_slots);
    @memset(parent_slots, SHARED_EXIT);
    var link_parent: Trace = .{
        .id = 71,
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa, .linked_entry = 0xAAAA } },
    };
    var link_child: Trace = .{
        .id = 72,
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = &.{}, .gpa = gpa, .linked_entry = 0xBBBB } },
    };
    try testing.expect(try state.armNativeLink(&link_parent, 0, &link_child, .link_terminal));
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    var j: u32 = 0;
    while (j < state.config.max_penalty) : (j += 1) {
        state.setRegionContext(1, 5);
        _ = state.accountRegionProfit(exit, 1, .deferred);
        state.observeRegionProgramPoint(61, 1, 1, 5); // departure → r=1 remainder strike
    }
    try testing.expectEqual(@as(u32, state.config.max_penalty), state.penalty.get(owner).?);
    try testing.expect(state.isGated(owner));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(SHARED_EXIT, parent_slots[0]);

    // (5) A-vii-c.1: the accounting boundary is CONSUMPTION, not membership. This
    // is the contract the A-vii-c review blocker turned on — physical membership
    // in a live region does NOT imply the region machine can gate a given receipt,
    // so suppressing the legacy machine on membership left a member's zero-work
    // and unclassified exits ungated by BOTH machines (measured shape: the
    // dispatcher's zero-iteration path at interp.zig, whose own comment reads
    // "apply the penalty"). Exactly one machine must account every receipt.
    var member_instrs = [_]IrInstr{ .{ .op = .slot_load, .aux = 0 }, .{ .op = .loop } };
    var member: Trace = .{ .id = 9, .anchor = .{ .proto = &proto, .pc = 1 }, .instrs = &member_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.dest_entry_regions.put(gpa, 9, try gpa.dupe(RegionId, &.{rid}));
    state.penalty.clearRetainingCapacity();
    state.gate.clearRetainingCapacity();

    // (5a) CONSUMED — exit 0 is classified into the live region and carries nonzero
    // work, so the region window owns the verdict and the member anchor is untouched
    // even though the segment itself was low-yield.
    state.setRegionContext(1, 5);
    state.onSideExitReceipt(&member, 0, 0, 1, .deferred);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));
    try testing.expectEqual(@as(u64, 1), state.region_profit.get(key).?.outer_traversals);

    // (5b) NOT consumed — same classified exit of the same live member, but zero
    // structural work. R2-1 keeps zero-work flushes silent, so if this did not fall
    // through to the legacy machine nothing would ever gate it: it must strike.
    state.onSideExitReceipt(&member, 0, 0, 0, .deferred);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(member.anchor).?);

    // (5c) NOT consumed — nonzero work, but exit 1 is absent from the edge cache,
    // so no accumulator receives it. Also a strike.
    state.onSideExitReceipt(&member, 0, 1, 4, .deferred);
    try testing.expectEqual(@as(u32, 2), state.penalty.get(member.anchor).?);

    // (5d) An unconsumed USEFUL segment still recovers the anchor the legacy way,
    // and the selection half bumps hit_count on every useful receipt regardless of
    // which machine took the profitability verdict.
    state.onSideExitReceipt(&member, state.config.min_useful, 1, 0, .deferred);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));
    try testing.expectEqual(@as(u64, 1), member.hit_count);

    // (5e) Tombstoning the region makes even a nonzero-work classified exit
    // unconsumable (`openRegion` refuses a non-armable def) — so the member reverts
    // to the legacy machine immediately, without waiting for a physical rebuild.
    state.region_defs.getPtr(rid).?.armable = false;
    state.setRegionContext(1, 5);
    state.onSideExitReceipt(&member, 0, 0, 1, .deferred);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(member.anchor).?);
}

test "A-iv region_profit: windows persist across physical re-entry and observer closes only on departure" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .id = 41, .code = &code, .name = "region", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(7);
    const points = try gpa.dupe(ProgramPoint, &.{.{ .proto_id = 41, .source_pc = 0 }});
    const members = try gpa.dupe(StructuralEdgeId, &.{});
    try state.region_defs.put(gpa, rid, .{
        .members = members,
        .member_points = points,
        .owner = .{ .proto = &proto, .pc = 0 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    const source_set = try gpa.dupe(RegionId, &.{rid});
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, source_set);

    state.setRegionContext(1, 99);
    _ = state.accountRegionProfit(.{ .trace_id = 9, .exit_instr = 0 }, 3, .deferred);
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    const key: RegionKey = .{ .region_id = rid, .activation = 99 };
    try testing.expectEqual(@as(u64, 3), state.region_profit.get(key).?.outer_traversals);

    // Physical retirement/re-arm does not touch region_profit: another receipt for
    // the same logical id resumes the same window and crosses N=8 exactly once.
    _ = state.accountRegionProfit(.{ .trace_id = 9, .exit_instr = 0 }, 5, .deferred);
    try testing.expectEqual(@as(u64, 8), state.region_profit.get(key).?.outer_traversals);
    try testing.expectEqual(@as(u64, 8), state.region_profit.get(key).?.window_base);
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    state.observeRegionProgramPoint(41, 0, 1, 99);
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    state.observeRegionProgramPoint(41, 1, 1, 99);
    try testing.expectEqual(@as(usize, 0), state.regionProfitCount());
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes); // exact-N exit: no zero remainder
}

test "A-iv region_profit: activation cleanup drops only the dying activation" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const a: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 10 };
    const b: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 11 };
    try state.region_profit.put(gpa, a, .{ .outer_traversals = 2, .root_frame_depth = 1, .root_call_seq = 10 });
    try state.region_profit.put(gpa, b, .{ .outer_traversals = 4, .root_frame_depth = 2, .root_call_seq = 11 });
    state.dropRegionActivation(11);
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    try testing.expect(state.region_profit.contains(a));
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(u64, 4), state.region_profit_flushed_work);
}

test "A-iv region_profit: same-activation owner collision flushes old before replacement" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .id = 55, .code = &code, .name = "cardinality", .num_registers = 1 };
    const r1: RegionId = @enumFromInt(1);
    const r2: RegionId = @enumFromInt(2);
    inline for (.{ r1, r2 }) |rid| {
        try state.region_defs.put(gpa, rid, .{
            .members = try gpa.dupe(StructuralEdgeId, &.{}),
            .member_points = try gpa.dupe(ProgramPoint, &.{.{ .proto_id = 55, .source_pc = 0 }}),
            .owner = .{ .proto = &proto, .pc = 0 },
            .classifier = .{ .kind = .self_loop, .member_count = 1 },
            .armable = true,
        });
    }
    const ctx: RegionContext = .{ .depth = 1, .call_seq = 77 };
    const old = state.openRegion(r1, ctx).?;
    state.region_profit.getPtr(old).?.outer_traversals = 3;
    _ = state.openRegion(r2, ctx).?; // direct H-3 collision/replacement path
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    try testing.expect(state.region_profit.contains(.{ .region_id = r2, .activation = 77 }));
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(u64, 3), state.region_profit_flushed_work);
}

test "A-ii.2 edge_cache: a 2-anchor cont↔inner cycle resolves both structural edges" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity(); // traces are stack-allocated; drop pointers pre-deinit

    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 1 };

    // cont @pc2: a `.link` terminal (instrs[1], aux=7) to the inner root at pc7.
    var cont_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 9 }, .{ .op = .link, .aux = 7 } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 1, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var cont: Trace = .{ .id = 301, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_prov };

    // inner root @pc7: loop-done guard_true (instrs[0], aux=2 == cont anchor), ends `.loop`.
    var inner_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var inner_prov = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .guard = .{ .source_proto_id = 0, .source_pc = 6, .role = .loop_done, .operand = .none } } }};
    var inner: Trace = .{ .id = 302, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_prov };

    try state.cache.append(gpa, &cont);
    try state.cache.append(gpa, &inner);
    state.rebuildEdgeCache();

    // Both structural edges present: cont --link--> inner(pc7), inner --loop_done--> cont(pc2).
    try testing.expectEqual(@as(usize, 2), state.edge_cache.count());
    const e_link = state.edge_cache.get(.{ .trace_id = 301, .exit_instr = 1 }) orelse return error.MissingLinkEdge;
    try testing.expect(e_link.exit == .link_terminal);
    try testing.expectEqual(@as(u32, 2), e_link.anchor_pc);
    try testing.expectEqual(@as(u32, 7), e_link.succ_anchor_pc);
    const e_guard = state.edge_cache.get(.{ .trace_id = 302, .exit_instr = 0 }) orelse return error.MissingGuardEdge;
    try testing.expect(e_guard.exit == .guard);
    try testing.expectEqual(@as(u32, 7), e_guard.anchor_pc);
    try testing.expectEqual(@as(u32, 2), e_guard.succ_anchor_pc);

    // Wholesale rebuild from the SURVIVING cache after inner leaves: cont's `.link` now
    // has no inner root bound, and inner's own edge is gone → empty. (Simulate the
    // retirement rebuild path without `destroy` on a stack trace.)
    _ = state.cache.swapRemove(1); // drop &inner
    state.rebuildEdgeCache();
    try testing.expectEqual(@as(usize, 0), state.edge_cache.count());
}

test "A-ii.2 canonicalEql/order: field-wise, ignores the dead path tail and the inactive arm" {
    // Two guard edges identical in every LIVE field but with different garbage in
    // path[inline_depth..] must be equal (field-wise, not raw bytes). And the exit-tag
    // orders guard (0) before link_terminal (1), giving a strict total order.
    var g_a: GuardProvenance = .{ .source_proto_id = 0, .source_pc = 6, .role = .loop_done, .operand = .none };
    var g_b: GuardProvenance = .{ .source_proto_id = 0, .source_pc = 6, .role = .loop_done, .operand = .none };
    g_a.path[0] = .{ .caller_proto_id = 111, .call_pc = 222 }; // dead (inline_depth == 0)
    g_b.path[0] = .{ .caller_proto_id = 333, .call_pc = 444 }; // different dead garbage
    const ea: StructuralEdgeId = .{ .anchor_proto_id = 0, .anchor_pc = 7, .exit = .{ .guard = g_a }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 2 };
    const eb: StructuralEdgeId = .{ .anchor_proto_id = 0, .anchor_pc = 7, .exit = .{ .guard = g_b }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 2 };
    try testing.expect(ea.eql(eb));
    try testing.expectEqual(ea.hash(), eb.hash());
    try testing.expect(ea.order(eb) == .eq);

    // A link-terminal edge at the same anchors sorts AFTER a guard edge (tag order),
    // and the order is antisymmetric.
    const el: StructuralEdgeId = .{ .anchor_proto_id = 0, .anchor_pc = 7, .exit = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 6, .inline_depth = 0 } }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 2 };
    try testing.expect(ea.order(el) == .lt);
    try testing.expect(el.order(ea) == .gt);
    try testing.expect(!ea.eql(el));
}

test "A-ii.3 rec_path: recordInstr captures {proto_id, pc−1}; reset clears (re-record stable)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = 42, .name = "t", .num_registers = 2 };
    var regs = [_]Value{ Value.int(0), Value.int(0) };

    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    // Two safe guest ops (load_int: define a reg from an immediate, no guard, no abort)
    // recorded at post-increment pcs 3 and 4 → source_pc 2 and 3.
    state.recordInstr(Instr.opAx(.load_int, 0, 1), winRO(&regs), &proto, 3, Value.nil());
    state.recordInstr(Instr.opAx(.load_int, 1, 2), winRO(&regs), &proto, 4, Value.nil());
    try testing.expect(state.rec.rec_path_ok);
    try testing.expectEqual(@as(usize, 2), state.rec.rec_path.items.len);
    try testing.expectEqual(ProgramPoint{ .proto_id = 42, .source_pc = 2 }, state.rec.rec_path.items[0]);
    try testing.expectEqual(ProgramPoint{ .proto_id = 42, .source_pc = 3 }, state.rec.rec_path.items[1]);

    // Re-record stability: a fresh reset clears the path and re-arms availability.
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    try testing.expectEqual(@as(usize, 0), state.rec.rec_path.items.len);
    try testing.expect(state.rec.rec_path_ok);
}

test "A-ii.3 rec_path: a committed trace carries its recorded path (freed on destroy)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    var committed: ?*Trace = null;
    defer state.deinit();
    defer {
        if (committed) |ct| ct.destroy(gpa);
        state.cache.clearRetainingCapacity();
    }

    // Same recForPrepLink→commit harness as the A-i.4 test: a continuation that
    // re-reaches an inner `for_prep` commits a `.link` trace. Its rec_path captures
    // the single recorded for_prep at source_pc 4 (post-increment pc 5 − 1).
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.load_nil);
    code[7] = Instr.opJ(.for_loop, -3);
    const proto = Proto{ .code = &code, .id = 9, .name = "t", .num_registers = 4 };
    const inner_instrs = [_]IrInstr{.{ .op = .loop }};
    var inner: Trace = .{ .id = 900, .anchor = .{ .proto = &proto, .pc = 5 }, .instrs = @constCast(&inner_instrs), .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &inner);

    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 2 }, proto.num_registers);
    state.rec.kind = .continuation;
    var regs = [_]Value{ Value.int(1), Value.int(10), Value.int(1), Value.nil() };
    state.recordInstr(Instr.opAx(.for_prep, 0, 2), winRO(&regs), &proto, 5, Value.nil());

    try testing.expect(!state.isRecording());
    const t = state.cache.items[state.cache.items.len - 1];
    committed = t;
    try testing.expect(t.id != 900);
    try testing.expectEqual(@as(usize, 1), t.rec_path.len);
    try testing.expectEqual(ProgramPoint{ .proto_id = 9, .source_pc = 4 }, t.rec_path[0]);
}

// ---- A-ii.4 region discovery / interning / classification (inert) ----------
//
// Helpers build a synthetic trace graph over one proto with stack-allocated `Trace`s,
// then call `rebuildEdgeCache` + `rebuildRegions` directly (as the commit/retire path
// does) and assert on the discovered regions. `defer state.cache.clearRetainingCapacity`
// drops the (stack) cache pointers before `deinit`, exactly as the A-ii.2 test does; the
// region maps own HEAP copies independent of the stack traces, so `deinit` frees them
// cleanly.

fn guardProv(source_pc: u32, role: GuardRole) ExitProvenance {
    return .{ .guard = .{ .source_proto_id = 0, .source_pc = source_pc, .role = role, .operand = .none } };
}

test "A-ii.4 discovery: skip→ramp→inner→cont→skip cycle — owner==skip@14 ∧ armable, one stable RegionId" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // The 4-node cycle. `skip@14` and `inner@7` end `.loop` (loop-root shape); `cont@20`
    // does not. `extern@30` supplies the incoming boundary edge into skip@14, so skip is
    // the UNIQUE external-entry ∧ loop-root anchor → owner.
    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 14 }, .instrs = &skip_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &skip_p };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ramp_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ramp_p };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_p };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // 5 structural edges (4 internal cycle + 1 incoming boundary), one discovered region.
    try testing.expectEqual(@as(usize, 5), state.edge_cache.count());
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());

    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    const def = state.region_defs.get(rid).?;
    // Owner predicate (round-13 load-bearing): skip@14, armable.
    try testing.expectEqual(@as(*const Proto, &proto), def.owner.proto);
    try testing.expectEqual(@as(u32, 14), def.owner.pc);
    try testing.expect(def.armable);
    try testing.expect(def.classifier.kind == .cross_trace_cycle);
    try testing.expectEqual(@as(u32, 4), def.classifier.member_count);
    try testing.expectEqual(@as(usize, 4), def.members.len); // 4 internal edges

    // Classification: a member's internal exit is credited to R; the non-member
    // external trace's exit is not (candidate SETS, not A-iv credit).
    const skip_regions = state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 });
    try testing.expectEqual(@as(usize, 1), skip_regions.len);
    try testing.expectEqual(rid, skip_regions[0]);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 5, .exit_instr = 0 }).len);
    // dest_entry: the four cycle members are entries; the external trace is not.
    try testing.expect(state.dest_entry_regions.get(1) != null);
    try testing.expect(state.dest_entry_regions.get(5) == null);
}

test "A-vii-d.0 armability recovery: first-sight unarmable arms on the rebind that brings the entry edge; tombstone is sticky" {
    // The reason no recorded shape ever armed (A-vii-d.0): the internal cycle is
    // what triggers minting, and its external-entry side trace records LATER (by
    // hotguard), so first sight is always owner-not-unique. Armability must
    // therefore be recomputed per rebind — frozen-at-first-sight can never rise
    // (measured on nsieve: both_count 0→0→1 across rebuilds). Only the tombstone
    // is sticky.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const P_ID: u32 = 8;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // The same 4-node cycle as the discovery pin above, but WITHOUT the external
    // trace: skip@14 is a loop-root yet nothing outside the component enters it.
    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 14 }, .instrs = &skip_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &skip_p };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ramp_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ramp_p };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_p };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont }) |t| try state.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // (1) First sight: cycle discovered, but no external entry yet ⇒ NOT armable,
    // NOT tombstoned, and excluded from the physical indices.
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(!state.region_defs.get(rid).?.armable);
    try testing.expect(!state.region_defs.get(rid).?.tombstoned);
    try testing.expect(state.dest_entry_regions.get(1) == null);

    // (2) The external-entry side trace records (the guard-hot side trace that in
    // real programs always arrives AFTER the cycle): the rebind re-interns the
    // SAME RegionId and armability recovers.
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p };
    try state.cache.append(gpa, &ext);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count()); // same logical region
    try testing.expect(state.region_defs.get(rid).?.armable);
    try testing.expect(!state.region_defs.get(rid).?.tombstoned);
    try testing.expect(state.dest_entry_regions.get(1) != null); // members indexed again

    // (3) A runtime tombstone is STICKY: the identical graph rebinding afterwards
    // must not re-arm (fail-closed for cause, per invalidateRegion).
    state.invalidateRegion(rid);
    try testing.expect(!state.region_defs.get(rid).?.armable);
    try testing.expect(state.region_defs.get(rid).?.tombstoned);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expect(!state.region_defs.get(rid).?.armable);
    try testing.expect(state.region_defs.get(rid).?.tombstoned);
    try testing.expect(state.dest_entry_regions.get(1) == null);
}

test "A-ii.4 finding-3: a member with an incomplete recorded path mints the region NON-armable" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // Same owner-bearing 5-trace graph as the armable test above, but one physical member
    // (`skip`) carries a TRUNCATED recorded path (rec_path_complete=false, as a recorder-
    // path OOM or a commit-time dup OOM would leave it). The region must still be
    // discovered — its structural identity is unaffected — but must NOT be armable, and no
    // member exit may be classified (the def's member_points under-describe the footprint).
    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 14 }, .instrs = &skip_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &skip_p, .rec_path_complete = false };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ramp_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ramp_p };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_p };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // The region is still discovered (structural identity is unaffected by rec_path).
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const def = state.region_defs.get(kit.next().?.*).?;
    // …but incomplete membership forces it CLOSED, and no member exit is classified.
    try testing.expect(!def.armable);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expect(state.dest_entry_regions.get(1) == null);
    try testing.expectEqual(@as(u32, 0), state.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.dest_entry_regions.count());
}

test "A-ii.4 exit_prov fail-soft: an incomplete-exit_prov trace disarms the whole pass, logical defs retained, auto-recovers" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // The armable 5-trace graph again. Phase 1: fully complete → region armed. Phase 2:
    // taint the graph by marking one cached trace's `exit_prov` INCOMPLETE (as a
    // commit-time `buildExitProv` OOM would) — the whole discovery pass must arm nothing
    // (physical indices empty) yet RETAIN the logical def, and mint no new def. Phase 3:
    // clear the taint → the region re-arms (auto-recovery). We flip only the flag (leaving
    // `exit_prov` populated) to exercise the graph-completeness gate in isolation.
    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 14 }, .instrs = &skip_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &skip_p };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ramp_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ramp_p };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_p };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.cache.append(gpa, t);

    // Phase 1 — complete graph: region armed.
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_defs.get(rid).?.armable);
    try testing.expectEqual(@as(usize, 1), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);

    // Phase 2 — taint one trace's exit_prov: the pass arms NOTHING, but keeps the def.
    ext.exit_prov_complete = false;
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count()); // logical retained
    try testing.expect(state.region_defs.get(rid).?.armable); // logical bit intrinsic, untouched
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expectEqual(@as(u32, 0), state.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.dest_entry_regions.count());

    // Phase 3 — clear the taint: the region re-arms (same id), physical indices repopulate.
    ext.exit_prov_complete = true;
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit3 = state.region_defs.keyIterator();
    try testing.expectEqual(rid, kit3.next().?.*);
    const regs = state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 });
    try testing.expectEqual(@as(usize, 1), regs.len);
    try testing.expectEqual(rid, regs[0]);
}

test "A-ii.4 finding-5: a boundary edge added on rebind flips both_count 1→2, re-gating armable off (same id)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    // Phase 1: the armable skip→ramp→inner→cont→skip cycle with ONE incoming boundary
    // (ext→skip@14) → skip is the unique external-entry ∧ loop-root → both_count==1, armed.
    // Phase 2: add a SECOND incoming boundary (ext2→inner@7) — inner@7 also ends `.loop`,
    // so it too becomes external-entry ∧ loop-root → both_count==2. The INTERNAL edge set
    // is unchanged, so the region re-interns to the SAME id, but the current owner analysis
    // (`cand.armable_owner`) is now false, so the rebind must DISARM it despite the stored
    // armable bit (finding 5). The owner is refreshed to the deterministic placeholder.
    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 14 }, .instrs = &skip_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &skip_p };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ramp_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ramp_p };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_p };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_defs.get(rid).?.armable);
    try testing.expectEqual(@as(u32, 14), state.region_defs.get(rid).?.owner.pc); // owner=skip@14
    try testing.expectEqual(@as(usize, 1), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);

    // Phase 2: add ext2 → inner@7 (a second external-entry into a loop-root). both_count→2.
    var ext2_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }};
    var ext2_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(39, .branch_cond) }};
    var ext2: Trace = .{ .id = 6, .anchor = .{ .proto = &proto, .pc = 40 }, .instrs = &ext2_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext2_p };
    try state.cache.append(gpa, &ext2);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // SAME region id (internal edge set unchanged), but disarmed by the current owner
    // analysis, and no member exit is classified. The stored owner is refreshed away from
    // skip@14 to the deterministic placeholder (canonically-smallest anchor of the SCC).
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit2 = state.region_defs.keyIterator();
    try testing.expectEqual(rid, kit2.next().?.*);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expectEqual(@as(u32, 0), state.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.dest_entry_regions.count());
    try testing.expectEqual(@as(u32, 2), state.region_defs.get(rid).?.owner.pc); // placeholder = smallest anchor (ramp@2)
}

test "A-ii.4 finding-6: a region-rebuild OOM fails CLOSED — physical indices emptied, logical defs retained" {
    // A `FailingAllocator` forces `rebuildRegionsFallible` to OOM on a SECOND pass after a
    // good first pass armed a region. The disposition must NOT retain the prior physical
    // snapshot (which a graph-changing commit could have made stale) — it fails CLOSED to
    // EMPTY physical indices, while the LOGICAL defs (untouched by the aborted pass) survive.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = fa.allocator();
    var state = TraceState.init(gpa);
    defer {
        fa.fail_index = std.math.maxInt(usize); // let teardown allocate freely
        state.deinit();
    }
    defer state.cache.clearRetainingCapacity();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 14 }, .instrs = &skip_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &skip_p };
    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ramp_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ramp_p };
    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &inner_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &inner_p };
    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p };
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p };
    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.cache.append(gpa, t);

    // Phase 1 — good pass: region armed, physical indices populated.
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.source_exit_regions.count() > 0);
    try testing.expect(state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len == 1);

    // Phase 2 — arm the allocator to fail the NEXT allocation, then re-discover regions over
    // the (still-valid, phase-1) edge cache. The region rebuild OOMs on its first scratch
    // alloc → fail-closed. (We call ONLY rebuildRegions so the failure is in the region pass,
    // not the edge-cache pass.)
    fa.fail_index = fa.alloc_index; // next alloc returns error.OutOfMemory
    state.rebuildRegions();

    // Physical indices emptied (fail-closed), logical defs retained (untouched).
    try testing.expectEqual(@as(u32, 0), state.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.dest_entry_regions.count());
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit2 = state.region_defs.keyIterator();
    try testing.expectEqual(rid, kit2.next().?.*);
}

test "A-ii.4 re-record stability: the same guest-logical graph (new Trace.ids) re-interns to the SAME RegionId" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // A minimal non-armable 2-node cycle A@2 ↔ B@7. Build it twice with DIFFERENT
    // Trace.ids and assert the interned RegionId is unchanged (identity is guest-logical:
    // StructuralEdgeId keys on proto_id/pc/provenance, never Trace.id).
    const buildCycle = struct {
        fn go(st: *TraceState, g: std.mem.Allocator, p: *const Proto, id_a: u32, id_b: u32) !void {
            const a_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }});
            const a_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }});
            const a = try g.create(Trace);
            a.* = .{ .id = id_a, .anchor = .{ .proto = p, .pc = 2 }, .instrs = a_i, .consts = try g.alloc(Value, 0), .entry_slots = try g.alloc(u16, 0), .entry_guards = try g.alloc(EntryGuard, 0), .exit_prov = a_p };
            const b_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
            const b_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }});
            const b = try g.create(Trace);
            b.* = .{ .id = id_b, .anchor = .{ .proto = p, .pc = 7 }, .instrs = b_i, .consts = try g.alloc(Value, 0), .entry_slots = try g.alloc(u16, 0), .entry_guards = try g.alloc(EntryGuard, 0), .exit_prov = b_p };
            try st.cache.append(g, a);
            try st.cache.append(g, b);
        }
    }.go;

    try buildCycle(&state, gpa, &proto, 1, 2);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid1 = kit.next().?.*;

    // Retire both (heap traces → real destroy), then re-record with fresh ids.
    while (state.cache.items.len > 0) state.removeTrace(state.cache.items[0]);
    try buildCycle(&state, gpa, &proto, 11, 12);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    // Still ONE region, and the SAME id (not a second def).
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    try testing.expect(state.region_defs.get(rid1) != null);

    while (state.cache.items.len > 0) state.removeTrace(state.cache.items[0]);
}

test "A-vii-b discovered bridge descriptor validates inertly and rejects incomplete proofs or seeded children" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    var code: [41]Instr = undefined;
    for (&code) |*ins| ins.* = Instr.op0(.ret);
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    code[28] = Instr.opAx(.jmp_if_true, 0, 0);
    code[39] = Instr.opAx(.jmp_if_true, 0, 0);
    const proto = Proto{ .code = &code, .id = 77, .name = "a-vii-b", .num_registers = 4 };

    // cont@29 --composite--> skip@14 --ordinary--> cont@29.  skip's direct
    // entry set is {r0,r1}; cont additionally needs r2, so the cycle fixed point
    // makes the bridge descriptor S={r0,r1,r2}. E={r0}, invariants={r1,r2}.
    var cont_i = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .slot_load, .aux = 2 },
        .{ .op = .guard_true, .a = 0, .aux = 14 },
        .{ .op = .phi, .b = 0, .aux = 0 },
        .{ .op = .loop },
    };
    var cont_p = [_]ExitProvEntry{.{ .index = 3, .prov = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 13,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } } }};
    const parent_slots = try gpa.alloc(usize, cont_i.len);
    defer gpa.free(parent_slots);
    @memset(parent_slots, 0); // no trampoline in this unit test: shared_exit == 0
    var cont: Trace = .{
        .id = 1,
        .anchor = .{ .proto = &proto, .pc = 29 },
        .instrs = &cont_i,
        .consts = &.{},
        .entry_slots = @constCast(&[_]u16{2}),
        .entry_guards = &.{},
        .exit_prov = &cont_p,
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };

    var skip_i = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_true, .a = 0, .aux = 29 },
        .{ .op = .loop },
    };
    var skip_p = [_]ExitProvEntry{.{ .index = 2, .prov = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 28,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } } }};
    var skip: Trace = .{
        .id = 2,
        .anchor = .{ .proto = &proto, .pc = 14 },
        .instrs = &skip_i,
        .consts = &.{},
        .entry_slots = @constCast(&[_]u16{ 0, 1 }),
        .entry_guards = &.{},
        .exit_prov = &skip_p,
        .hit_count = 9,
    };
    // Same-anchor decoy has a higher hit count but is not a physical region member.
    var sibling: Trace = .{
        .id = 3,
        .anchor = skip.anchor,
        .instrs = &skip_i,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .hit_count = 100,
    };
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 39,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } } }};
    var ext: Trace = .{
        .id = 4,
        .anchor = .{ .proto = &proto, .pc = 40 },
        .instrs = &ext_i,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_prov = &ext_p,
    };
    for ([_]*Trace{ &cont, &skip, &sibling, &ext }) |t| try state.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var ids = state.region_defs.keyIterator();
    const rid = ids.next().?.*;
    var def = state.region_defs.getPtr(rid).?;
    try testing.expect(def.armable);
    try testing.expectEqual(@as(usize, 1), def.bridges.len);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, def.bridges[0].required_slots);
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, def.bridges[0].invariant_slots);

    const decision = state.validateRegionBridge(rid, &cont, 3) orelse
        return error.TestUnexpectedResult;
    try testing.expect(decision.child == &skip); // member filter defeats higher-hit sibling
    try testing.expect(def.armable);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[3]);

    // Re-discovery with fresh physical ids must replace, not retain, descriptor
    // storage. Corrupt the old proof first; the rebuilt same logical RegionId restores it.
    def.bridges[0].invariant_slots[1] = 99;
    cont.id = 11;
    skip.id = 12;
    sibling.id = 13;
    ext.id = 14;
    state.rebuildEdgeCache();
    state.rebuildRegions();
    def = state.region_defs.getPtr(rid).?;
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, def.bridges[0].invariant_slots);
    try testing.expect(state.dest_entry_regions.get(skip.id) != null);

    // Rejection A: S still contains live-through r2, but neither E nor the
    // (deliberately damaged) invariant proof contains it.
    def.bridges[0].invariant_slots[1] = 99;
    try testing.expect(state.validateRegionBridge(rid, &cont, 3) == null);
    try testing.expect(!def.armable);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[3]);

    // Rejection B is independent of S/E: restore the discovered proof/armable bit,
    // then make the selected physical child require dispatcher input seeding.
    def.armable = true;
    def.bridges[0].invariant_slots[1] = 2;
    skip.inputs = @constCast(&[_]InputSeed{undefined});
    try testing.expect(state.validateRegionBridge(rid, &cont, 3) == null);
    try testing.expect(!def.armable);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[3]);
}

test "A-ii.4 intern identity is the edge SET (distinct sets → distinct ids; identical set → same id)" {
    // White-box on RegionInternMap: identity is the element-wise-compared sorted set, not
    // object bytes and not merely the 64-bit fold. (A genuine Wyhash fold collision is
    // unforgeable, so the set-equality guard is validated by distinct-set / same-set
    // behaviour: a different set never aliases an existing id, an identical one always does.)
    const gpa = testing.allocator;
    var m: RegionInternMap = .empty;
    defer m.deinit(gpa);

    const setA = [_]StructuralEdgeId{.{ .anchor_proto_id = 0, .anchor_pc = 2, .exit = guardProv(1, .branch_cond), .succ_anchor_proto_id = 0, .succ_anchor_pc = 7 }};
    const setB = [_]StructuralEdgeId{.{ .anchor_proto_id = 0, .anchor_pc = 2, .exit = guardProv(1, .branch_cond), .succ_anchor_proto_id = 0, .succ_anchor_pc = 9 }}; // different succ pc

    try testing.expect(m.lookup(&setA) == null);
    try m.reserve(gpa, 2);
    m.internAssumeCapacity(try gpa.dupe(StructuralEdgeId, &setA), @enumFromInt(100));
    m.internAssumeCapacity(try gpa.dupe(StructuralEdgeId, &setB), @enumFromInt(200));

    try testing.expectEqual(@as(RegionId, @enumFromInt(100)), m.lookup(&setA).?);
    try testing.expectEqual(@as(RegionId, @enumFromInt(200)), m.lookup(&setB).?);
    // A re-presented identical set (fresh slice, same contents) resolves to its id.
    const setA2 = [_]StructuralEdgeId{setA[0]};
    try testing.expectEqual(@as(RegionId, @enumFromInt(100)), m.lookup(&setA2).?);
}

test "A-ii.4 sibling boundary edge: only the physical MEMBER's exits are credited to R" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // Cycle A@2 ↔ B@7 made armable by an external entry X@40→A@2 with A loop-root. A
    // SIBLING A'@2 realizes only a boundary edge A→C@30 (C outside the cycle) — it shares
    // A's anchor but realizes NO internal edge, so it is NOT a physical member.
    var a_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 7 }, .{ .op = .loop } };
    var a_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .loop_done) }};
    var ta: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &a_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &a_p };

    var b_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }};
    var b_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }};
    var tb: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &b_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &b_p };

    var as_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 30 }}; // sibling at @2 → C@30
    var as_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }};
    var tas: Trace = .{ .id = 3, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &as_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &as_p };

    var c_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 99 }}; // C@30 resolves to nothing
    var c_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var tc: Trace = .{ .id = 4, .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &c_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &c_p };

    var x_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }}; // X@40 → A@2 (incoming boundary)
    var x_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(39, .branch_cond) }};
    var tx: Trace = .{ .id = 5, .anchor = .{ .proto = &proto, .pc = 40 }, .instrs = &x_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &x_p };

    for ([_]*Trace{ &ta, &tb, &tas, &tc, &tx }) |t| try state.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    const def = state.region_defs.get(rid).?;
    try testing.expectEqual(@as(u32, 2), def.owner.pc); // A@2 is external-entry ∧ loop-root
    try testing.expect(def.armable);

    // Member A's internal exit → R; the SIBLING A''s boundary exit at the same anchor → ∅.
    try testing.expectEqual(rid, state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 })[0]);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 3, .exit_instr = 0 }).len);
    // dest_entry: members {A=1, B=2} only — never the sibling A'(3) or the outside X(5)/C(4).
    try testing.expect(state.dest_entry_regions.get(1) != null);
    try testing.expect(state.dest_entry_regions.get(2) != null);
    try testing.expect(state.dest_entry_regions.get(3) == null);
    try testing.expect(state.dest_entry_regions.get(5) == null);
}

test "A-ii.4 rebind tombstone: same edge set, incompatible member_points → armable flips false, purged from physical" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // An armable 2-node cycle A@2 ↔ B@7 (X@40→A external entry, A loop-root), where A
    // carries a recorded-path point. Re-record with the SAME edge set but a DIFFERENT
    // A.rec_path → member_points mismatch → def-consistency tombstone.
    const buildArmable = struct {
        fn go(st: *TraceState, g: std.mem.Allocator, p: *const Proto, ids: [3]u32, a_pt: ProgramPoint) !void {
            const a_i = try g.dupe(IrInstr, &[_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 7 }, .{ .op = .loop } });
            const a_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .loop_done) }});
            const a_path = try g.dupe(ProgramPoint, &[_]ProgramPoint{a_pt});
            const a = try g.create(Trace);
            a.* = .{ .id = ids[0], .anchor = .{ .proto = p, .pc = 2 }, .instrs = a_i, .consts = try g.alloc(Value, 0), .entry_slots = try g.alloc(u16, 0), .entry_guards = try g.alloc(EntryGuard, 0), .exit_prov = a_p, .rec_path = a_path };
            const b_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
            const b_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }});
            const b = try g.create(Trace);
            b.* = .{ .id = ids[1], .anchor = .{ .proto = p, .pc = 7 }, .instrs = b_i, .consts = try g.alloc(Value, 0), .entry_slots = try g.alloc(u16, 0), .entry_guards = try g.alloc(EntryGuard, 0), .exit_prov = b_p };
            const x_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
            const x_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(39, .branch_cond) }});
            const x = try g.create(Trace);
            x.* = .{ .id = ids[2], .anchor = .{ .proto = p, .pc = 40 }, .instrs = x_i, .consts = try g.alloc(Value, 0), .entry_slots = try g.alloc(u16, 0), .entry_guards = try g.alloc(EntryGuard, 0), .exit_prov = x_p };
            for ([_]*Trace{ a, b, x }) |t| try st.cache.append(g, t);
        }
    }.go;

    try buildArmable(&state, gpa, &proto, .{ 1, 2, 3 }, .{ .proto_id = P_ID, .source_pc = 100 });
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    var kit = state.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_defs.get(rid).?.armable);
    try testing.expect(state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len == 1); // published

    // Re-record with a DIFFERENT A.rec_path (source_pc 200) → incompatible membership.
    while (state.cache.items.len > 0) state.removeTrace(state.cache.items[0]);
    try buildArmable(&state, gpa, &proto, .{ 11, 12, 13 }, .{ .proto_id = P_ID, .source_pc = 200 });
    state.rebuildEdgeCache();
    state.rebuildRegions();
    // Same id (edge set unchanged), but tombstoned + purged from the physical index.
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    try testing.expect(!state.region_defs.get(rid).?.armable);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 11, .exit_instr = 0 }).len);

    while (state.cache.items.len > 0) state.removeTrace(state.cache.items[0]);
}

test "A-ii.4 lifetime: removeTrace preserves region_defs (logical); clearCache empties it" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // A plain (non-armable) 2-node cycle on HEAP traces so removeTrace/clearCache can
    // `destroy` them. region_defs still gets one entry (first-sight always defines).
    const a_i = try gpa.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }});
    const a = try gpa.create(Trace);
    a.* = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = a_i, .consts = try gpa.alloc(Value, 0), .entry_slots = try gpa.alloc(u16, 0), .entry_guards = try gpa.alloc(EntryGuard, 0), .exit_prov = try gpa.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }}) };
    const b_i = try gpa.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
    const b = try gpa.create(Trace);
    b.* = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = b_i, .consts = try gpa.alloc(Value, 0), .entry_slots = try gpa.alloc(u16, 0), .entry_guards = try gpa.alloc(EntryGuard, 0), .exit_prov = try gpa.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }}) };
    try state.cache.append(gpa, a);
    try state.cache.append(gpa, b);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());

    // removeTrace breaks the cycle but must NOT clean region_defs (logical persistence).
    state.removeTrace(b);
    try testing.expectEqual(@as(usize, 1), state.region_defs.count());
    // The physical index rebuilt from the surviving graph (cycle gone) → empty.
    try testing.expectEqual(@as(usize, 0), state.source_exit_regions.count());

    // clearCache is the ONE place the logical maps are cleared.
    state.clearCache();
    try testing.expectEqual(@as(usize, 0), state.region_defs.count());
    try testing.expectEqual(@as(usize, 0), state.region_intern.entries.items.len);
}
