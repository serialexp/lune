//! Trace recorder, trace IR, and the trace lifecycle — the heart of the JIT.
//!
//! A tracing JIT works by watching tier-0 execute, noticing when a loop runs
//! *hot*, and **recording** one iteration of that loop into a linear,
//! single-assignment IR specialised to the types it actually observed. The
//! execution tiers (`irinterp.zig`: tier-1a IR interpreter; `nativegen.zig`:
//! tier-1b native codegen) *execute* that IR. Recording is deliberately
//! *transparent* — tier-0 still performs every operation, so a program's
//! observable behaviour is identical whether the recorder is on or off. That
//! invariant is the recorder's decisive correctness test (`interp.zig`, the
//! `expectProgram` matrix).
//!
//! What lives here:
//!   * the **trace IR** — `IrOp`/`IrInstr`/`Trace`, plus a disassembler. This is
//!     the cache-sensitive representation the architecture reserves for the JIT
//!     (docs/design/00-architecture.md §Value representation), kept separate from
//!     the tier-0 bytecode (`bytecode.zig`).
//!   * the **recorder** — `TraceState` (hotness counters, the trace cache, and
//!     the in-progress `Recorder`) and its state machine (`onBackEdge`).
//!   * the **lifecycle machinery** that grew around them: side traces and hot-exit
//!     wants, the peel (doc 39/40), chain/burst dispatch (`driveChain`,
//!     `replayLedger`), native link arming and exit-branch patching (doc 17),
//!     regions and provenance, gates/backoff, and cache invalidation.
//!
//! Policy is set by docs/design/01-trace-lifecycle.md and refined by docs 15-40.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
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
const string_mod = @import("string.zig");
const gc = @import("gc.zig");
// Doc 30 c4: the recorder's P2/P3 surface — the SAME pure cores tier-0 and
// the shims run (census, locate, init resolution), never a re-derivation.
const string_stdlib = @import("stdlib/string.zig");
const pattern_mod = @import("stdlib/pattern.zig");

// ---------------------------------------------------------------------------
// Trace IR
// ---------------------------------------------------------------------------

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

// -------------------------------------------------------------------------
// Trace-graph identities and the region data model live in leaf modules now
// (`trace_types.zig`, `trace_region.zig`). Re-exported here so every existing
// `trace.X` spelling keeps resolving and the move stays behaviour-free.
// -------------------------------------------------------------------------

pub const trace_types = @import("trace_types.zig");
pub const trace_region = @import("trace_region.zig");

pub const CallEdge = trace_types.CallEdge;
pub const Polarity = trace_types.Polarity;
pub const GuardRole = trace_types.GuardRole;
pub const OperandDesig = trace_types.OperandDesig;
pub const GuardProvenance = trace_types.GuardProvenance;
pub const LinkTerminalProvenance = trace_types.LinkTerminalProvenance;
pub const ExitProvenance = trace_types.ExitProvenance;
pub const ExitProvEntry = trace_types.ExitProvEntry;
pub const ExitKey = trace_types.ExitKey;
pub const ProgramPoint = trace_types.ProgramPoint;
pub const StructuralEdgeId = trace_types.StructuralEdgeId;
pub const AnchorKey = trace_types.AnchorKey;
pub const MAX_INLINE_DEPTH = trace_types.MAX_INLINE_DEPTH;
pub const exitOrder = trace_types.exitOrder;
pub const exitProvEntryLess = trace_types.exitProvEntryLess;

pub const RegionId = trace_region.RegionId;
pub const RegionKey = trace_region.RegionKey;
pub const RegionAccum = trace_region.RegionAccum;
pub const RegionDestination = trace_region.RegionDestination;
pub const RegionContext = trace_region.RegionContext;
pub const RegionClassifier = trace_region.RegionClassifier;
pub const RegionBridgeDef = trace_region.RegionBridgeDef;
pub const RegionDef = trace_region.RegionDef;
pub const RegionInternMap = trace_region.RegionInternMap;
pub const ObserverSpan = trace_region.ObserverSpan;
pub const ObserverFast = trace_region.ObserverFast;
pub const ObserverHot = trace_region.ObserverHot;
pub const freeRegionBridges = trace_region.freeRegionBridges;
pub const cloneRegionBridges = trace_region.cloneRegionBridges;
pub const freeRegionSetMap = trace_region.freeRegionSetMap;
pub const RegionSetBuilder = trace_region.RegionSetBuilder;
pub const programPointsEqual = trace_region.programPointsEqual;
pub const appendUniqueSlot = trace_region.appendUniqueSlot;
pub const programPointLess = trace_region.programPointLess;

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
/// Populate `t.bridge_cand` / `t.bridge_cand_built` by evaluating the pure
/// `nativegen.isCompositeBridgeCandidate` oracle once per instruction index
/// (doc 17 §T.9). Call once, at commit, after `t` is fully populated.
///
/// FAIL-SOFT by design: on OOM the memo is simply left unbuilt and
/// `Trace.isBridgeCandidate` falls back to the oracle. There is deliberately no
/// error return — a commit must never fail because an accelerator could not be
/// allocated.
pub fn buildBridgeCandMemo(gpa: std.mem.Allocator, t: *Trace) void {
    if (t.instrs.len == 0) {
        // Nothing to memoize, but mark it built: the oracle returns false for every
        // index on an empty trace, which an empty bitset reproduces exactly.
        t.bridge_cand_built = true;
        return;
    }
    const bytes = gpa.alloc(u8, (t.instrs.len + 7) / 8) catch return;
    @memset(bytes, 0);
    for (0..t.instrs.len) |i| {
        if (nativegen.isCompositeBridgeCandidate(t, i))
            bytes[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
    }
    t.bridge_cand = bytes;
    t.bridge_cand_built = true;
}

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
    if (t.anchor.proto.code[guardSourcePc(g).?].op != .for_loop) return false;
    // Inlined-callee corner: a callee-internal `for_loop` guard at `inline_depth > 0` has its
    // `guardSourcePc` in the callee's proto, not the anchor's. If the callee's pc
    // coincidentally maps to a `for_loop` in the anchor proto, this would falsely
    // match. Reject inlined-callee guards via the exit provenance table.
    if (t.provAt(@intCast(idx))) |prov| switch (prov) {
        .guard => |gp| if (gp.inline_depth > 0) return false,
        .link_terminal => return false, // a link terminal is never a loop-done guard
    };
    return true;
}

/// Doc 38 — the WHILE twin of `isLoopDoneGuardIndex`, returning the post-loop
/// resume PC on a match (null otherwise). A while loop compiles to
/// `<cond>; jmp_if_false <past_end>; <body>; jmp <back_to_cond>`, so its
/// loop-done exit is the CONDITION guard: a `guard_true` (recBranch pinned the
/// observed continue direction) whose source opcode is the `jmp_if_false`.
/// Classified structurally, tied to the trace's own anchor: the branch's jump
/// target must be exactly one past a backward `jmp` that returns to
/// `t.anchor.pc` — that shape IS the while loop this trace is the root of, and
/// it cannot match an inner while unrolled inside the trace (its back-edge
/// targets the inner header, not our anchor).
///
/// Two structural differences from the numeric-for loop-done:
///  * the guard sits at the trace TOP (before the body), so the failing pass
///    ran only the condition prefix — completed iterations already committed
///    at their `.loop` terminals and NO final-iteration flush is owed;
///  * the post-loop PC is the branch's JUMP TARGET, not `guardExitPc` (which
///    is the fall-through = the loop body start).
/// Same doc-37 provenance rule as the numeric classifier: an inlined-callee
/// guard's `guardSourcePc` is in the callee's proto — reject depth > 0.
pub fn whileLoopDonePostPc(t: *const Trace, idx: usize) ?u32 {
    if (idx >= t.instrs.len) return null;
    const g = t.instrs[idx];
    if (g.op != .guard_true) return null;
    const src_pc = guardSourcePc(g) orelse return null;
    const proto = t.anchor.proto;
    if (src_pc >= proto.code.len) return null;
    const br = proto.code[src_pc];
    if (br.op != .jmp_if_false) return null;
    // Post-loop pc = the branch's jump target (post-increment base, like
    // `applyJump`): `(src_pc + 1) + aux`. Must be a forward, in-bounds exit.
    const post_i: i64 = @as(i64, src_pc) + 1 + br.aux;
    if (post_i <= @as(i64, src_pc) or post_i >= @as(i64, @intCast(proto.code.len))) return null;
    const post: u32 = @intCast(post_i);
    if (post == 0) return null;
    // The instruction immediately before the post-loop pc must be this loop's
    // backward `jmp`, returning exactly to the trace's anchor (the condition).
    const back = proto.code[post - 1];
    if (back.op != .jmp) return null;
    if (@as(i64, post) + back.aux != @as(i64, t.anchor.pc)) return null;
    if (t.provAt(@intCast(idx))) |prov| switch (prov) {
        .guard => |gp| if (gp.inline_depth > 0) return null,
        .link_terminal => return null,
    };
    return post;
}

/// Doc 38: boolean twin of `whileLoopDonePostPc` for classification-only sites.
pub fn isWhileLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    return whileLoopDonePostPc(t, idx) != null;
}

/// Doc 40 Phase 0 (codex finding 3): is a while-loop-done exit's "zero
/// completions ⇒ regs coherent at the post-loop pc" claim actually true for
/// this trace? For an ordinary trace, always — the condition guard sits at the
/// trace top, before any of the final pass's body ran (the doc 38 zero-trip
/// argument). For a PEELED trace (doc 39) the claim breaks in the STEADY
/// region: the run-once region is a real tier-0 iteration, and a
/// zero-completion deopt deliberately leaves the carried-slot boxes untouched
/// — so a steady-region loop-done firing at zero local completions has
/// *executed* (but never flushed) iteration 1, and the post-loop pc is NOT
/// coherent. Such an exit must take the ordinary deopt-replay path (tier-0
/// re-runs from the entry state), never the `.while_done` chain. A
/// run-once-region loop-done (idx before the marker) stays chain-safe: zero
/// completions there really is zero iterations.
pub fn whileDoneCoherentAtZero(t: *const Trace, idx: usize) bool {
    if (!t.peeled) return true;
    for (t.instrs[0..@min(idx, t.instrs.len)]) |ins| {
        if (ins.op == .preheader) return false; // marker precedes the exit → steady region
    }
    return true;
}

/// Doc 38: either loop-done kind — numeric-for OR while. Use at accounting
/// sites where "the loop ran to completion" matters regardless of loop shape
/// (hot-exit exclusion, receipt region-work). Kind-specific machinery (the
/// native linked materialization, `flushNumericForLoopDone`) keeps using the
/// specific classifiers.
pub fn isAnyLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    return isLoopDoneGuardIndex(t, idx) or isWhileLoopDoneGuardIndex(t, idx);
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
    /// Part S (doc 17): native SIBLING HANDOFF. An anchor-coherent ordinary deopt
    /// exit whose child is a trace at the SAME anchor as the parent — the native
    /// compilation of doc 16's coherent-anchor chain. The parent's carried-home
    /// flush leaves regs coherent at the shared anchor, so the child's ordinary
    /// entry (its own compiled prologue guards re-validating types) is exactly the
    /// state an ordinary dispatcher re-entry would have produced. Reuses the
    /// ordinary-guard slot and stub verbatim; only the arm kind and the replay
    /// production are new.
    sibling_handoff,
};

// Region-bridge arming (A-vii-d): always on since the full chain landed — the
// replay grammar (A-vii-a), the arm-time S⊆E validator (A-vii-b), the
// consumption-keyed profit gate (A-vii-c/c.1/c.2), reachable armability
// (A-vii-d.0), and the `tryArmRegionBridge` arm site in `driveChain`. The
// staged flip-switch (`region_bridge_arming_enabled`) was folded once the
// increments were history.
//
// Part S (§S) — the native sibling handoff. Always on.
//
// The mechanism: patching a hot ordinary-guard exit to jump straight into a
// same-anchor sibling's ordinary entry, fusing skip⇄continuation ping-pong into
// one native call (on nsieve it fuses the majority of dispatcher bursts).
//
// History of the soundness scare (2026-08-12/13), kept because the diagnosis
// path is instructive: an earlier revision of this comment declared the §S
// premise ("a zero-progress pre-effect deopt is coherent at the anchor")
// FALSIFIED, because the A-viii outer-cycle repro printed 108 where the unfused
// run prints 109 even after both premise halves (`exitIsPreEffect`, the
// `term_local == 0` charge filter) were in place. That verdict was wrong. The
// dropped iteration was never a register-coherence failure at the handoff at
// all — it was `replayLedger`'s TERMINAL arm resuming at the stale linked
// `link_pc` when a burst mixed `.link_terminal` rows with a later handoff row,
// so tier-0 resumed inside the previous prime's finished inner loop and the
// middle `for_loop` advanced past the in-flight iteration (the missing prime is
// 307, the first zero-trip). The fix is entry-PROVENANCE, not snapshots: a row
// whose owner was entered at its anchor (handoff successor, like a bridged
// successor) terminal-resumes at the anchor, never `link_pc` — see
// `next_entry = .via_handoff` in `replayLedger`. With that fix A-viii prints 109 with
// arming ON, the full suite is green, and all six output-identity controls
// hash byte-identical.
//
// The premise therefore stands as designed, with eligibility enforced at
// `siblingHandoffEligible`: compiled native, in-bounds, not a loop-done or
// bridge slot, not already armed, no preceding heap effect on the trace
// (`exitIsPreEffect`), and the guard must be sourced at a real conditional
// branch opcode (`jmp_if_*`) — a non-branch guard (e.g. a zero-trip loop-entry
// check sourced at `for_prep`) would ping-pong parent⇄sibling to LEDGER_CAP
// instead of committing an iteration per transition (measured: +128% on
// nsieve before the branch-source rule).
//
// Part B-2b (doc 17 §B.5): hotexit-provenance relation and disposable arm —
// always on (the `provenance_arming_enabled` flip-switch was folded).

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
    /// Doc 38: a while-loop-done exit (either tier — the tier is `driveChain`'s
    /// comptime param). The condition guard sits at the trace TOP, so the
    /// failing pass ran only the condition prefix: completed iterations already
    /// committed at their `.loop` terminals and NO flush is owed on any tier.
    /// The chain walks at the post-loop pc (`whileLoopDonePostPc`), which is
    /// the condition branch's jump target — NOT `guardExitPc`.
    while_done,
};

/// Doc 20 (patched trace entry): one registry slot binding a `.jfor_loop` or
/// `.jloop`
/// patched into a per-VM code image to its qualified root trace. Slots are
/// **stable-address** (§R2-6): each is its own heap allocation, the index in
/// `TraceState.entry_patches` is baked into the image instruction's `.b`, and
/// tombstoned slots are reused via `entry_patch_free` — never compacted.
/// Doc 20 §R4-2: per-trace entry-patch lifecycle. Suppression is split by
/// reason because the arms have different wake behaviour (§R5-2, §R6-2):
/// `.suppressed_incumbent` is woken only by its recorded incumbent's
/// tombstone; `.suppressed_capacity` by ANY tombstone; `.suppressed_permanent`
/// (not-`.compiled`, ambiguous patch pc — properties that never change) is
/// never woken, the trace simply keeps entering via the walk.
pub const EntryPatchState = enum {
    eligible,
    pending,
    bound,
    suppressed_incumbent,
    suppressed_capacity,
    suppressed_permanent,
};

pub const EntryPatch = struct {
    /// The bound root. Valid to dereference ONLY while `live` (§R7-2):
    /// `removeTrace` clears `live` through `Trace.entry_slot` BEFORE
    /// `t.destroy` frees the allocation; the drain resolves `trace_id`
    /// through `traceById` and never follows this pointer.
    trace: *Trace,
    /// Non-reused id for drain-time identity; `traceById` returning null
    /// means the trace is already destroyed (§R7-2).
    trace_id: u32,
    proto: *const Proto,
    /// Instruction index of the patched loop-closing instruction in the image.
    patch_pc: u32,
    /// Canonical content, restored on unpatch (debug-asserted identical to
    /// `proto.code[patch_pc]`, which is the ground truth anyway).
    orig: Instr,
    /// Cleared by any unpatch mark; the arm inspects it BEFORE the
    /// post-return drain, never after (§R2-4, §R7-1).
    live: bool = true,
    /// Set with `live = false` by `markEntryPatchPending`; consumed by the
    /// safe-point drain (§R5-1 same-turn).
    pending_unpatch: bool = false,
    /// Slot is dead and on (or headed for) the free-list.
    tombstone: bool = false,
    /// Non-productive patched entries since the last productive one; at
    /// `patch_strikes` the arm marks pending unpatch (§R6-1).
    strikes: u8 = 0,
    /// EntryPlan (§R1-4/6), the structural half of seeding memoized at patch
    /// time. The input-slot → seed-source map already lives on the trace
    /// (`Trace.inputs`); the only piece `seedTraceInputs` re-derives per entry
    /// is the scratch-size high-water mark (`max(num_registers, max input
    /// slot + 1)`) — memoized here. Seed VALUES are still re-resolved every
    /// entry and every fail-closed check stays in `enterSelectedTrace`; the
    /// plan is never claimed total.
    seed_count: u32,
};

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
    /// Why the LAST escalation fired (doc 38 yield gate). A `.low_trip_while`
    /// dispatch gate is exempt from the clear-on-productive paths: the very
    /// receipts that would clear it (1–2-trip completions) are the evidence it
    /// gates on. It expires only via the standard cooldown, after which a
    /// probe window that clears the yield bar simply never re-gates
    /// (`noteWhileYield`). All other reasons keep doc 31 D2 semantics.
    reason: GateReason,
};

/// Doc 31 D3: why an anchor was gated — carried in the jit-debug receipt line
/// (`gate[dispatch:legacy_thrash]` vs `gate[record:record_abort]`) so a
/// receipts log self-explains which machine gated. The first three are
/// dispatch-gate sources, the last two record-gate sources (doc 31 §3).
pub const GateReason = enum {
    legacy_thrash,
    region_decay,
    native_unsupported,
    /// Doc 38 yield gate: a while anchor whose entries average below
    /// `config.while_yield_min_avg` trips over a `while_yield_window`-entry
    /// probe. Each entry is productive (a completion, often 1–2 trips, half
    /// zero-trip on fft_bitreverse) but the per-entry runtime turnstile
    /// (entry + seam re-entry; our exits are not patched branches) costs more
    /// than tier-0 running the same 0–2 iterations. Dispatch-gate source;
    /// exempt from clear-on-productive (see `Gate.reason`).
    low_trip_while,
    record_abort,
    commit_failure,
};

/// Doc 38 yield-gate accumulator (`TraceState.while_yield`): entries and total
/// completed iterations observed for one while anchor over the current probe
/// window. Both saturate; the verdict compares `iters` against
/// `entries * while_yield_min_avg` at `entries == while_yield_window`.
pub const WhileYield = struct {
    entries: u32,
    iters: u32,
};

/// Identifies a guard-failure site: the trace anchor and the bytecode PC of the
/// failing guard instruction (stored in the guard's `aux` field by the per-guard
/// PC recording, step 2).  Used to count how often a specific guard fails, so
/// side-trace recording (step 4) can be triggered at the right threshold.
pub const GuardKey = struct { anchor: AnchorKey, exit_pc: u32 };

/// Key of one burst-TERMINAL exit site (jitdbg telemetry, doc 17 Part B): the
/// (trace, exit instruction, materialization kind, outcome) whose ledger row was
/// the last of a burst — i.e. the exact site that returned control to the runtime.
pub const DbgTerminalKey = struct {
    trace_id: u32,
    exit_instr: u32,
    kind: irinterp.LedgerKind,
    outcome: irinterp.LedgerOutcome,
};

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
pub const InputKind = enum(u8) { upvalue, global, hash_cell, callee_upvalue };

/// One synthetic entry input the dispatch loop resolves and writes into the slab
/// before trace entry. For `upvalue`/`global`: `source` is the upvalue index
/// (`closure.upvalues[source]`) or the global key's constant-pool index
/// (`proto.constants[source]`); `slot` is the synthetic frame-relative slab slot
/// (== the seeding `slot_load`'s `aux`), always `>= anchor_num_registers`. For
/// `callee_upvalue` (inlined-callee upvalues): `source` is the upvalue index in the *inlined
/// callee's* closure, and `callee_slot` is the anchor-slab slot where that
/// callee's closure lives at entry time — the seed resolves through
/// `Closure.fromHeader(regGet(base + callee_slot)).upvalues[source]`. The
/// callee's own seed (kind=`upvalue` or a regular `slot_load`) is always
/// earlier in the seed array, so `callee_slot` is populated before this seed
/// runs. For `hash_cell` (H1): `source` is the **key**'s constant-pool index,
/// `table_reg` is the anchor slot holding the table value, and `expected_count`
/// is the recorded `hash.count()` (the `guard_hash` aux) the seed re-checks for
/// native eligibility. Runtime-only — not serialized (precedent: `entry_guards`).
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
    /// `callee_upvalue` only (inlined-callee upvalues): anchor-slab slot where the inlined callee's
    /// closure lives at entry time. The callee was already seeded (as an `upvalue`
    /// or regular `slot_load` input) before this seed, so `regGet(base +
    /// callee_slot)` is valid by the time this seed runs.
    callee_slot: u16 = 0,
};

/// Doc 22 §B.1: the per-VM native seeding context. A seeded trace's entry
/// prologue (B-ii) and `driveChain`'s tier-1a seeding twin (B-iii) resolve
/// entry inputs *from native/chain code*, where no `*Vm` argument exists — so
/// the VM publishes everything the seeding helper needs into this struct once
/// per episode (`Vm.prepareNativeEpisode`), and compiled pages bake `&ctx` as
/// an imm64. Hence it MUST be heap-allocated with a stable address: `Vm` is a
/// by-value struct that may move; this ctx may not. Owned by `TraceState`
/// (created by `Vm.initBare`, freed in `TraceState.deinit`).
///
/// Freshness: a baked `&ctx` outlives episodes, so consumers must check that
/// the ctx describes the CURRENT activation before trusting it — `proto` and
/// `call_seq` are the stamp (`stubEnterable`, B-iv). `proto == null` means "no
/// episode prepared yet" and can never read as fresh.
///
/// All pointers are `anyopaque` because trace.zig cannot name `Vm`/`Closure`/
/// `Proto` (interp.zig imports trace.zig, not vice versa); `seed_fn` (installed
/// once by `Vm.initBare`, pointing at interp.zig's C-ABI seeding twin) casts
/// them back.
pub const NativeSeedCtx = struct {
    /// `seed_fn` result grammar (u64 for C-ABI simplicity; doc 22 §B.2).
    pub const SEED_OK: u64 = 1;
    /// A hash_cell seed failed validation (metatable appeared, key vanished,
    /// `hash.count()` drifted): the entry must not run natively this episode.
    pub const SEED_HASH_DECLINE: u64 = 2;
    /// The seed slots don't fit the register slab (`base + count > capacity`):
    /// nothing was written; the candidate itself is unusable at this depth.
    pub const SEED_CAPACITY_DECLINE: u64 = 3;

    /// `*Vm`, valid for the prepared episode only.
    vm: *anyopaque = undefined,
    /// `*const function.Closure` of the anchor frame (upvalue seeds).
    closure: *const anyopaque = undefined,
    /// Anchor frame base into the register slab.
    base: usize = 0,
    /// `Vm.regCapacity()` at episode start (capacity-decline check).
    reg_capacity: usize = 0,
    /// `*const Proto` of the anchor frame — half the freshness stamp, and the
    /// constant pool for global/hash_cell key resolution. `null` ⇒ never fresh.
    proto: ?*const anyopaque = null,
    /// The anchor frame's activation token — the other half of the stamp.
    call_seq: u64 = 0,
    /// The C-ABI seeding twin (interp.zig `nativeSeedFn`): resolves the plan's
    /// ACTIVE seeds into the slab, returns SEED_OK / SEED_HASH_DECLINE /
    /// SEED_CAPACITY_DECLINE. Installed once at VM init; never reassigned.
    ///
    /// The plan travels BY VALUE (`plan_bits`, the `SeedPlan.bits` bitmap): the
    /// caller is JIT-emitted prologue code that bakes its arguments as imm64s at
    /// compile time, and `&CompiledTrace.seed_plan` has no stable address to bake
    /// (`compileImpl` returns the struct by value). `&t` and `&ctx` bake fine —
    /// committed traces are heap-allocated and immutable, the ctx is heap-allocated
    /// by design. (Recorded deviation from doc 22 §B.1's `*const SeedPlan` sketch.)
    seed_fn: *const fn (ctx: *const NativeSeedCtx, t: *const Trace, plan_bits: u64) callconv(.c) u64,
    /// The tier-1a seeding twin (interp.zig `nativeSeedTier1aFn`; doc 22 §B.3),
    /// called from `driveChain`'s chain seams (`seedForTier1a`) before each
    /// `irinterp.execute` of a seeded successor. Unlike the C-ABI plan twin it
    /// resolves the FULL input set — tier-1a's `slot_load`s read every synthetic
    /// slot; seed plans are a native-page concept (carried-heap rewrites) that
    /// never deactivates tier-1a's needs — and it is a plain Zig fn pointer (the
    /// callers are chain seams, not JIT-emitted code, so nothing is baked).
    /// Same tri-state result grammar. Optional so hand-built test ctxs that only
    /// exercise the C-ABI prologue keep compiling; consumers fail closed.
    seed_tier1a_fn: ?*const fn (ctx: *const NativeSeedCtx, t: *const Trace) u64 = null,
};

/// A completed, cached trace: the recorded IR plus the entry/exit snapshots that
/// connect it back to tier-0 register slots. The IR is immutable once
/// committed; a trace leaves the cache only wholesale (`removeTrace` /
/// `clearCache` — see the lifecycle doc).
pub const Trace = struct {
    /// Stable, monotonically-assigned identity (P-B, doc 17). Unlike the cache
    /// index (`traceIndex`, which `swapRemove` shuffles), this is assigned once at
    /// finalize from `TraceState.next_trace_id` and NEVER reused — so it can be
    /// baked into native exit code as `final_trace_id` and resolved back via
    /// `traceById` even after unrelated traces retire. Default 0 for hand-built test
    /// traces that never go through finalize (they don't chain, so id collisions are
    /// harmless — the dispatcher's id path only runs for real recorded traces).
    id: u32 = 0,
    /// Doc 20 §R7-2: back-reference to this trace's entry-patch registry slot
    /// while entry-patch-bound, else null. Lets `removeTrace` mark the slot
    /// (clear `live`, set pending) in O(1) BEFORE destruction, and lets
    /// qualification assert a trace never binds two slots.
    entry_slot: ?u16 = null,
    /// Doc 20 §R4-2: the per-trace entry-patch state machine. The receipt
    /// funnel (`accountTraceRun`) may make exactly ONE transition —
    /// `.eligible → .pending` — behind a single state compare, so a `.bound`
    /// trace's productive receipts cost one never-taken branch. Every other
    /// transition happens at the safe-point drain (`drainEntryPatchWork`) or
    /// an unpatch (`unpatchSlot`), all deterministic events.
    entry_patch: EntryPatchState = .eligible,
    /// Valid ONLY while `entry_patch == .suppressed_incumbent`: the registry
    /// slot index of the live incumbent that blocked this trace's install.
    /// Its tombstone (and only its) wakes this trace back to `.eligible`.
    entry_patch_incumbent: u16 = 0,
    anchor: AnchorKey,
    /// Doc 38 unroll-first policy: this trace's recording unrolled at least one
    /// inner-while back-edge inline. When such a trace's anchor is gated for
    /// legacy thrash, that gate is evidence unrolling does not cover this
    /// outer loop's trip variance (`unroll_fail`).
    unrolled_while: bool = false,
    /// Doc 39: this trace was committed from a type-stabilizing PEEL — its
    /// `preheader` run-once region is a real tier-0 iteration (iteration 1,
    /// original int semantics), not an LICM-hoisted invariant block. SEMANTIC
    /// state, serialized (schema v bump): the first back-edge completes TWO
    /// tier-0 iterations, and a deopt at zero local completions must leave the
    /// carried-slot boxes untouched (tier-0 replays iteration 1 from the entry
    /// state). Cannot be inferred from the marker — an LICM'd trace carries the
    /// same marker but its preheader completes ZERO iterations.
    peeled: bool = false,
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
    /// Consecutive native-prologue refusals for this candidate. Any body entry
    /// resets the streak; a maxed streak suppresses only this trace.
    consec_refusals: u32 = 0,
    /// Doc 24 D3: the trace's static allocation bound `A` — the number of
    /// `.alloc`-kind ops the recorded body contains (0 = non-allocating, the
    /// arc-A status quo). Mirrors the entry `guard_gc`'s `aux` (stamped from the
    /// same counter at commit, so it stays an upper bound even if the optimizer
    /// CSEs an `.alloc` away). Read by the observation blackout: while
    /// suspension/keyframe observation is armed, the dispatcher and the chain
    /// walk decline to enter any trace with `alloc_bound > 0` (doc 24 D3,
    /// codex #2). Runtime-only — not serialized (recomputable from the IR).
    alloc_bound: u32 = 0,

    /// Doc 26 D1: the IR contains `supper`/`slower`, whose heap-only kernels
    /// are sound ONLY because the session's Unicode-version pin
    /// (`Vm.unicode_version_pinned`) was committed before this trace could
    /// commit and is monotone for the VM's lifetime. Debug asserts check the
    /// pin at commit, at trace entry, and at link ARMING (a patched
    /// native→native transfer has no vm in reach; by monotonicity a pin that
    /// held at arm time holds forever after). Runtime-only, recomputable.
    requires_unicode_pin: bool = false,

    /// B-iv.3 backoff: the exit whose composite-bridge arm pipeline last ran in
    /// full and declined because the child's page was not stub-enterable.
    /// `maybeArmCompositeExit` short-circuits on a hit, so a durably
    /// non-enterable child costs ONE full pipeline run per
    /// (activation x `region_defs_gen`) instead of one per terminal composite
    /// deopt. Purely an accelerator: it can only skip work that would have
    /// declined identically, never change an arm decision that would otherwise
    /// have been made. `maxInt` = no memo. Runtime-only — not serialized.
    bridge_decline_exit: u32 = std.math.maxInt(u32),
    /// `region_defs_gen` the memo was stamped under; 0 = never stamped.
    bridge_decline_gen: u32 = 0,
    /// `region_context.call_seq` the memo was stamped under.
    bridge_decline_seq: u64 = 0,

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
    /// `exit_prov` is region metadata off the tier-selection path, though the Part-A
    /// classifier and successor resolution do consume it). A
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

    /// Memoized `nativegen.isCompositeBridgeCandidate` (doc 17 §T.9), one bit per
    /// committed instruction index, LSB-first. That oracle is a PURE function of
    /// immutable recorded data (`instrs`, `anchor.proto.code`, `provAt`) that ends in
    /// an O(`instrs`) scan, and the seam calls it once per receipt from eight sites —
    /// 4.68% of nsieve N=9 wall-clock spent recomputing a constant. Alloc-once at
    /// commit; owned; freed in `destroy`; never serialized.
    ///
    /// `bridge_cand_built` distinguishes "not built" from "built and all-zero" — the
    /// build is FAIL-SOFT (an OOM must not abort the commit, same rationale as
    /// `exit_prov`), and hand-built test traces never go through commit at all. When
    /// false, `isBridgeCandidate` falls back to calling the oracle, so the memo is a
    /// pure accelerator: results are identical either way, by construction.
    bridge_cand: []const u8 = &.{},
    bridge_cand_built: bool = false,

    /// Memo for `TraceState.anchorPopulation`: the `countTracesAt(anchor)` result as
    /// of `TraceState.cache_gen == anchor_pop_gen`. Gen 0 = never computed (state
    /// gens start at 1). Pure accelerator — recomputed on any cache mutation.
    anchor_pop_gen: u32 = 0,
    anchor_pop: u32 = 0,

    /// Memo for `TraceState.hasNativeLoopDoneLink` — a pure function of this
    /// trace's instrs (fixed after commit), its dispatch proto (fixed: the
    /// anchor proto), and the trace cache contents (covered by
    /// `TraceState.cache_gen`). Ran per NATIVE DISPATCH before; now one gen
    /// compare in steady state. Gen 0 = never computed.
    ldl_memo_gen: u32 = 0,
    ldl_memo: bool = false,

    /// Pall's per-snapshot exit hotcount (`snap->count`, lj_trace.c
    /// `trace_hotside`): one taken-exit counter per committed instruction index,
    /// bumped by `noteTakenExit` on EVERY taken exit through that instruction.
    /// `EXIT_COUNT_DONE` (255, LuaJIT's `SNAPCOUNT_DONE`) latches once a side
    /// trace triggered by this exit commits — the exit is never counted again.
    /// Alloc-once at commit (FAIL-SOFT: an OOM leaves it empty and
    /// `noteTakenExit` bounds-checks, costing hotness, never correctness — same
    /// rationale as `bridge_cand`); empty for hand-built test traces; owned;
    /// freed in `destroy`; never serialized. Per-receipt cost is one direct
    /// byte RMW — no hashing (the Part S lesson below: a per-receipt hashmap
    /// probe was a measured 15% regression).
    exit_counts: []u8 = &.{},

    /// Part S — the sibling-handoff watch, deliberately a THREE-SCALAR, one-slot,
    /// allocation-free counter rather than a `(trace, exit) -> u32` side map.
    ///
    /// The first cut of Part S kept a `sibling_counts` hashmap keyed by `ExitKey` and
    /// resolved its owner with a `traceById` linear scan, both executed on EVERY
    /// dispatcher burst terminal (472k times on nsieve N=9). Measured: the bookkeeping
    /// cost more than the handoff saved — a 26% burst reduction that came out 15%
    /// SLOWER on the clock. The counter therefore has to be free, not merely cheap:
    ///
    ///   * one watched exit at a time (`sibling_watch_exit`), so a receipt is a `u32`
    ///     compare and an increment — no hashing, no probe, no allocation;
    ///   * eligibility is only consulted when the watch MOVES, not per receipt;
    ///   * `sibling_arms` is a COUNT, and its only per-receipt job is the `== 0` fast
    ///     reject in `hasArmedSiblingHandoff`.
    ///
    /// A count rather than a bool because a trace can have several hot exits and each
    /// deserves its own handoff. The first cut latched a bool on the first arm, which
    /// silently capped nsieve at ONE arm: exit 9 fused, and exit 16 — still terminating
    /// 304k bursts, half the remaining seam — could never be watched again. After the
    /// arm the watch resets so the next exit can qualify; an exit that is already armed
    /// is rejected by `siblingHandoffEligible`, so it cannot re-arm.
    ///
    /// Determinism is unchanged: all three are pure functions of the receipt stream,
    /// in receipt order. The one-slot watch is *less* eager than a full per-exit map
    /// (two co-hot exits qualify one after the other, not simultaneously), which can
    /// only ever DELAY an arm — never arm something a map wouldn't have.
    sibling_watch_exit: u32 = std.math.maxInt(u32),
    sibling_watch_count: u32 = 0,
    sibling_arms: u32 = 0,
    /// Single-slot INELIGIBLE-exit memo for `noteSiblingTerminal`: the last exit
    /// whose `siblingHandoffEligible` came back false. Repeat receipts at that
    /// exit are one `u32` compare instead of a full eligibility re-scan (measured:
    /// nsieve terminated 84k bursts/run at one statically-ineligible exit, each
    /// re-running the armed-links scan + bridge memo + branch-source test — ~5%
    /// wall-clock). Sound because eligibility for a fixed `(trace, exit)` is
    /// static EXCEPT for the armed-slot exclusion, so the memo is cleared wherever
    /// the arm set touching this trace changes (`clearSiblingLatch`, a successful
    /// sibling arm).
    sibling_reject_exit: u32 = std.math.maxInt(u32),

    /// Freeze-after-qualify membership memo (task #70, the runtime-seam kill): the
    /// last `regionMemberPoint(rid, anchor)` answer for this trace, keyed by
    /// `(region_defs_gen, rid)`. `replayLedger`'s frozen fast path asks "is this
    /// row's owner anchored inside the live region's footprint" once per ROW; the
    /// answer is a pure function of the trace anchor (immutable) and the region
    /// def's `member_points`/`armable` (invalidated by bumping
    /// `TraceState.region_defs_gen` at every `region_defs` mutation), so two
    /// scalars + a bool replace a per-row footprint scan. Gen 0 never matches
    /// (`region_defs_gen` starts at 1), so a fresh trace always recomputes.
    region_memo_rid: u64 = std.math.maxInt(u64),
    region_memo_gen: u32 = 0,
    region_memo_member: bool = false,

    /// Memoized `nativegen.isCompositeBridgeCandidate(self, idx)` — see `bridge_cand`.
    /// Falls back to the oracle when the memo was not built.
    pub fn isBridgeCandidate(self: *const Trace, idx: usize) bool {
        if (!self.bridge_cand_built)
            return nativegen.isCompositeBridgeCandidate(self, idx);
        if (idx >= self.instrs.len) return false; // oracle's own bound
        return (self.bridge_cand[idx >> 3] >> @intCast(idx & 7)) & 1 != 0;
    }

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
    /// LuaJIT's `SNAPCOUNT_DONE` (lj_jit.h): a side trace for this exit has been
    /// committed — stop counting it. Saturation caps at `DONE - 1` so an exit can
    /// never drift into DONE by counting alone.
    pub const EXIT_COUNT_DONE: u8 = 255;

    pub fn destroy(self: *Trace, gpa: std.mem.Allocator) void {
        self.native.deinit();
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        if (self.exit_prov.len != 0) gpa.free(self.exit_prov);
        if (self.rec_path.len != 0) gpa.free(self.rec_path); // A-ii.3
        if (self.bridge_cand.len != 0) gpa.free(self.bridge_cand); // §T.9 memo
        if (self.exit_counts.len != 0) gpa.free(self.exit_counts); // hotexit counters
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
    /// Cross-frame inlining exceeded `MAX_INLINE_DEPTH`. (Deep/unbounded
    /// recursion is Phase 3.) Exactly the call-nesting meaning the name says —
    /// the reservation-overflow and input-budget conditions that used to share
    /// this tag have their own reasons below (`frame_bounds`, `input_cap`), so
    /// an abort table names WHICH limit fired (the LATEST-94 misdiagnosis came
    /// from having to guess).
    too_deep,
    /// An inlined callee window (`recCall`) or a dynamic return write
    /// (`recReturn`, multret shapes) would overflow the recorder's grown
    /// `reg_map` reservation. Abort rather than panic on an OOB slab access;
    /// tier-0 owns the loop.
    frame_bounds,
    /// The synthetic entry-input machinery refused: the trace already carries
    /// `MAX_TRACE_INPUTS` upvalue/global/hash-cell snapshots (a pure-policy
    /// backstop — see the constant's comment), or the synthetic slot index
    /// would wrap its `u16`. The trace's actual usage is visible as
    /// `inputs=N/cap` in `--dump-traces`/`--dump-native`.
    input_cap,
    /// Doc 38 / LuaJIT `LJ_TRERR_LLEAVE` ("leaving loop in root trace"): a ROOT
    /// recording anchored at a `while`/`repeat` header observed its own loop's
    /// exit direction on the condition branch. A root must loop back to form a
    /// root trace — recording onward would wander into the enclosing loop and
    /// commit a rotated outer trace at the inner anchor (frequently
    /// type-unstable across the enclosing back-edge, e.g. `local k = 64` int
    /// vs the loop body's float — the analyze RV-3 bail), clogging the anchor
    /// the nested-loop continuation machinery needs for the loop-BODY root.
    /// Repeated `loop_leave` strikes at an anchor mark a low-trip-count loop;
    /// `recWhileLink` then lets an outer root unroll it (LuaJIT's
    /// `innerloopleft` fallback).
    loop_leave,
    /// Doc 39: a type-stabilizing peel (int-entry/float-body carried slots)
    /// recorded its second pass and the carried kinds STILL mismatched — a
    /// genuine per-iteration flip-flop, or a forbidden effect surfaced on the
    /// body pass (a path iteration 1 didn't take). Ordinary strike semantics:
    /// such a shape was uncompilable before the peel existed and stays so.
    type_instability,
    /// An error unwound through the dispatch loop while this recording was
    /// active (doc 26 D1a). The raise itself is not part of the recorded IR, so
    /// letting the recording survive the unwind would stitch post-catch
    /// instructions (an enclosing `pcall`'s continuation) onto the partial
    /// iteration — a Franken-path that could commit if control re-reached the
    /// anchor. Reachable today via `schar1` (records under `guard_int`, then
    /// tier-0's `string.char` raises on an out-of-range value under an
    /// enclosing pcall); `Vm.execWith`'s errdefer kills the recording at the
    /// innermost unwind instead.
    raised,
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
    /// Doc 39: type-stabilizing peel for int-entry/float-body plain-while
    /// roots (numeric φ widening). Off = every close is a first-return close
    /// (pre-doc-39 behaviour); tests and A/B isolation flip it.
    peel: bool = true,
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
    ///
    /// DEMOTED to dead config by doc 20 Phase 1 (default 0 = disabled): the
    /// trip gate was a symptom of the per-back-edge discovery/selection
    /// cascade the patched entry removes, and the #69/#73 low-yield gate
    /// machine is the real thrash brake (full-board experiment: fft −34%,
    /// everything else in noise). Kept one release for A/B, then deleted.
    min_trip_entry: u32 = 0,
    /// Doc 20 §R6-1: consecutive non-productive patched entries (seed
    /// decline, prologue fail-closed, zero-progress exit) tolerated before
    /// the `.jfor_loop` arm marks its own slot pending unpatch — the anchor
    /// then re-decides through the virgin warming cascade (Open Q2's rebind
    /// policy is a measured follow-up). Productive entries reset the count.
    patch_strikes: u8 = 4,
    /// After this many *low-yield* trace entries (each committing fewer than
    /// `min_useful` iterations) an anchor is gated off so tier-0 owns the loop —
    /// the brake against re-entry thrash on type-unstable / branchy loops.
    max_penalty: u32 = 8,
    /// Consecutive entry refusals tolerated before suppressing this candidate.
    max_entry_refusals: u32 = 32,
    /// Part B-2b: complete-ledger zero-progress alternations tolerated before
    /// retiring the logical provenance edge and its disposable physical arm.
    max_edge_strikes: u8 = 3,
    /// Gate-fix arc (2026-08-12, codex BLOCKER 2): a QUALIFIED activation's
    /// consumed zero-work receipts are intra-complex transitions, but a streak
    /// of this many with NO intervening credited work is decay — it flushes one
    /// synthetic low-yield strike through the window gate machine and restarts.
    /// Sized so healthy branchy fusion (nsieve: a handful of barren transitions
    /// per credited scan segment) never trips it, while a barren-only spin is
    /// gated within `max_barren_run * max_penalty` receipts. Deterministic —
    /// a pure function of receipt counts.
    max_barren_run: u32 = 64,
    /// Freeze-after-qualify (task #70): consecutive useful windows after which a
    /// live activation FREEZES and `replayLedger` prices its member→member ledger
    /// rows through the allocation-free direct-credit fast path instead of the
    /// full classify/choose/destination hash pipeline. 2 = one window to qualify
    /// (`useful_window_seen`), one more to prove it wasn't a fluke. Any strike
    /// unfreezes. Heuristic — never affects output, only tiering cost.
    freeze_windows: u32 = 2,
    /// Enables production discovery/publication of silent exit cycles. Kept as
    /// an explicit gate while B-3 coverage is measured and hardened.
    silent_promotion_enabled: bool = true,
    /// Maximum promoted transitions executed by one native call before the
    /// universal silent drain regains control. This replaces the ordinary
    /// eight-hop steering bound only while a promoted set is active.
    silent_budget: usize = 4096,
    /// Number of identical, consecutive full-ledger cycle detections required
    /// before publishing a promotion.
    promote_after: u32 = 4,
    /// Gate backoff (replaces the old permanent blacklist). When an anchor is
    /// gated (low-yield penalty maxed, a recording abort, or a commit failure) it
    /// is held off tier-1 for a *cooldown window* measured in back-edges, after
    /// which it is retried once. Each re-failure doubles the window — a
    /// temporarily-unstable loop recovers cheaply, a hopeless one is retried
    /// exponentially less often. The window is keyed on the deterministic
    /// per-anchor back-edge counter, never wall-clock or RNG, so the retry
    /// schedule is reproducible (mahina determinism). `backoff_base` is the first
    /// window; it doubles up to `backoff_max`.
    backoff_base: u32 = 128,
    /// Cap on the doubling cooldown window (back-edges).
    backoff_max: u32 = 1 << 16,
    /// After this many gate escalations on one anchor, give up permanently (the
    /// loop has proven hopeless — e.g. a host call in the body that aborts every
    /// recording, or strict alternation no straight-line trace can amortize).
    max_strikes: u32 = 6,
    /// Doc 38 LLEAVE retry budget (LuaJIT `innerloopleft` analog, but reason-
    /// specific where LuaJIT's penalty slot conflates less). A `loop_leave`
    /// abort below this per-anchor count does NOT strike the record gate — the
    /// anchor silently retries at its next hot event, because which pass a
    /// recording lands on (cond-true → the loop-body root we want, cond-false
    /// → LLEAVE) is a race against the loop's trip pattern, not evidence the
    /// loop is untraceable. At/past the budget the loop has PROVEN a low/zero
    /// remaining-trip pattern: `loop_leave` starts striking the gate normally
    /// AND `recWhileLink` lets an enclosing root unroll the loop instead of
    /// aborting LINNER. Deterministic — a pure per-anchor abort count.
    lleave_fast_retries: u32 = 8,
    /// Doc 38 unroll-first policy: proven unroll failures at one OUTER anchor
    /// (recording aborts while unrolled + thrash gates on committed unrolled
    /// roots) before `recWhileLink` stops unrolling there and decomposes into
    /// inner-root + link (LINNER). 2 = LuaJIT `innerloopleft` penalty parity.
    unroll_fail_flip: u32 = 2,
    /// Doc 38 glue-sibling eligibility: maximum observed average trips/entry
    /// (from the `while_yield` accumulator) at which a while anchor's
    /// loop-done exit still accrues side-trace hotness — i.e. may grow the
    /// cond-false GLUE sibling (`guard_false → outer body → loop`, the
    /// figure-eight). Cost model: the glue fusion's benefit is amortizing the
    /// per-instance entry+seam turnstile, which dominates only for low-trip
    /// whiles (nest avg 5: glue = 78 cyc/it vs 137 decomposed; fft avg 1.5).
    /// For high-trip whiles the body loop already amortizes the seam and the
    /// glue family is measured pure downside (nsieve-bit-fp avg ~30+: glue
    /// formation was a 2.7× bench regression vs the root+link chain). Below
    /// the minimum sample (8 entries) hotness does not accrue (conservative:
    /// glue formation defers until the trip pattern is observed).
    while_glue_max_avg: u32 = 8,
    /// Doc 38 yield gate probe window: how many while-loop-done ENTRY receipts
    /// are accumulated per anchor before the average-trip verdict. Small enough
    /// that a hopeless turnstile (fft_bitreverse: 25.5M entries/run at ~1.5
    /// trips avg) gates within noise; large enough that a bursty-but-healthy
    /// while (mixed zero-trip and long instances) shows its true average.
    while_yield_window: u32 = 64,
    /// Minimum average trips per entry (integer, compared as
    /// `iters < entries * min_avg`) a while anchor must sustain over a probe
    /// window to stay dispatched. Below it, entering the trace costs more in
    /// runtime turnstile (entry + seam) than tier-0 running the same 0–2
    /// iterations, so the anchor is dispatch-gated (`.low_trip_while`).
    /// Recovery is probe-based: post-cooldown windows that clear the bar
    /// never re-gate. Pure deterministic counters — no clocks, no RNG.
    while_yield_min_avg: u32 = 3,
    /// Guard-failure count at which a side trace is recorded for this
    /// `(anchor, exit_pc)` pair.  When a guard at PC X in a trace anchored
    /// at A fails this many times, the next back-edge to A arms a new
    /// recording that captures the alternate path through the loop body.
    hotguard: u32 = 50,
    /// LuaJIT-faithful hot-exit threshold (lj_jit.h `JIT_P_hotexit` = 10, consumed
    /// by `trace_hotside`, lj_trace.c:798): the number of TAKEN exits through one
    /// `(trace, exit_instr)` — productive or not — before a side trace is wanted
    /// there. This is Pall's model verbatim: every taken exit increments the
    /// exit's own counter (`snap->count`); segment productivity is never
    /// consulted; a successful side-trace commit latches the counter to DONE
    /// (`SNAPCOUNT_DONE`) so the exit is never counted again. See
    /// `noteTakenExit`.
    hotexit: u8 = 10,
    /// Maximum distinct traces cached per anchor before `countGuardFailure` /
    /// `countFingerprintMiss` stop counting (i.e. before side-trace recording at
    /// that anchor is refused). Four remains the economic bound until native exit
    /// branches can jump directly into side traces without a runtime sibling walk.
    max_traces_per_anchor: usize = 4,
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
    /// `region_defs_gen` at the moment the `.region_bridge` arm pipeline last
    /// fully validated this link (`tryArmRegionBridge` stamps it with
    /// `region_id`). The already-armed early-out in `maybeArmCompositeExit`
    /// honors the arm only while this gen is current: a discovery rebuild
    /// replaces `def.bridges`/membership under the same region id without
    /// touching the link (the stale-link sweep checks region LIVENESS, not the
    /// exact bridge proof — codex review of f613c98), so a gen mismatch forces
    /// one full re-validation instead of trusting obsolete provenance forever.
    armed_gen: u32 = 0,
    /// Replay-walk memo for `.region_bridge` rows: the unique registered edge the
    /// slow resolution (provAt → def lookup → members scan, all release-panicking)
    /// produced, stamped with `region_defs_gen`. On a gen match the row grammar
    /// validates the successor against this edge directly — the defs have not
    /// changed since the full proof ran, so every slow-path verdict is unchanged
    /// by construction. Gen 0 = never resolved (state gens start at 1).
    bridge_edge: ?StructuralEdgeId = null,
    bridge_edge_gen: u32 = 0,
};

pub const PromotedEdge = struct {
    parent: *Trace,
    exit: u32,
    kind: nativegen.ExitPatchKind,
    child: *Trace,
    arm_kind: ArmKind,
    resume_pc: u32,
};

/// B-3d (doc 17 §B3.16 D2): the promoted unit is the frozen region's armed-edge
/// SET in canonical (parent id, exit) order — no ring order exists and none is
/// stored. A ring is just a set whose automaton happens to be periodic; every
/// per-edge fact reporting needs is MEASURED into `summary` by the epilogues
/// (`firings`/`last_ordinal`/`last_productive_ordinal`), never reconstructed
/// from position.
const PromotedSet = struct {
    edges: []PromotedEdge,
    summary: []nativegen.SilentSummaryCell,
    metadata: []nativegen.SilentExitMetadata,
    region_key: RegionKey,
    id: u32,
};

const PromotionRejects = struct {
    bridge_member: u64 = 0,
    region_mismatch: u64 = 0,
    open_chain: u64 = 0,
    no_patch_point: u64 = 0,
    child_mismatch: u64 = 0,
    cap: u64 = 0,
    /// B-3d (§B3.17 R1): `promoteSet` refused because the region already owns a
    /// live set — one set per region key is an ENFORCED invariant, and candidacy
    /// must restart from fully-reporting windows after the owning set demotes.
    region_owned: u64 = 0,
};

const PromotionDemotions = struct {
    activation: u64 = 0,
    region_close: u64 = 0,
    slot_mutation: u64 = 0,
    trace_invalidation: u64 = 0,
    teardown: u64 = 0,
    /// B-3d.1 (doc 17 §B3.17 R2): a low-yield window verdict unfroze the region's
    /// accumulator, so its live promotion was demoted in the same act — patches
    /// never outlive the frozen state that justified them, and the drain's
    /// frozen-accumulator check stays a true invariant instead of a latent crash.
    unfreeze: u64 = 0,
    /// B-3d (§B3.17 R1): a NEW armable member edge armed into a region that owns
    /// a live set — the set no longer covers the region's armed-edge population,
    /// so it demotes and candidacy regrows with the region-total candidate.
    membership_growth: u64 = 0,
};

/// Part B-2a (doc 17 §B.5): the persistent logical relation between the
/// side exit that caused a side trace to be recorded and that committed child.
/// The physical sibling-handoff arm is disposable; this relation survives it.
/// B-2b creates these at registered side-trace commit and republishes their
/// disposable physical arms at dispatcher safe points.
pub const ProvenanceEdge = struct {
    parent_id: u32,
    exit_instr: u32,
    child_id: u32,
    strikes: u8 = 0,
};

pub const ProvenanceAction = enum { strike, reset };

pub const ProvenanceVerdict = struct {
    parent_id: u32,
    exit_instr: u32,
    child_id: u32,
    action: ProvenanceAction,
};

const SilentProvenanceEvidence = struct {
    parent_id: u32,
    exit_instr: u32,
    child_id: u32,
    saw_productive: bool = false,
    saw_return_without_progress: bool = false,
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
    /// Read-only heap channel for the builtin fold arms (doc 23 D2): the
    /// dispatch loop refreshes this right before every `recordInstr` call
    /// (interp.zig), the same supply-what-the-recorder-can't-reach pattern as
    /// the `resolved` parameter — never a stored self-pointer trusted across
    /// calls. Folds use it for `internedLookup` ONLY (the arc-A invariant:
    /// recording never creates a guest heap object). Null in bare test
    /// harnesses that build a `TraceState` without a VM; fold arms then abort
    /// `.bad_type` and every other recorder path is unaffected.
    rec_heap: ?*const gc.Heap = null,
    /// MUTABLE execution-heap channel (doc 24 D5): the heap the tier-1a
    /// executor's `.alloc` arms and tier-1b's baked callouts/`guard_gc`
    /// allocate against. Unlike `rec_heap` (refreshed defensively per
    /// `recordInstr`), this may be stored once: `Vm.heap` is itself
    /// heap-allocated with a stable address for exactly this purpose (see the
    /// `Vm.heap` field doc). Set by `Vm.initBare`; null in bare test harnesses,
    /// where allocating traces fail closed (tier-1a side-exits the `.alloc`
    /// arm, `compileInto` declines the page).
    exec_heap: ?*gc.Heap = null,
    /// Shared machine-code arena — all tier-1b native traces are co-located slices of
    /// this (P-D of the exit-branch-patching port, doc 17). Replaces the old one-
    /// `mmap`-per-trace model so a future increment can link trace→trace with a bare
    /// `rel32` jump. Lifetime ≥ every trace (deinited *after* the cache is freed).
    mcode_arena: nativegen.McodeArena,
    /// Doc 22 §B.1: the per-VM native seeding context (see `NativeSeedCtx`).
    /// Created by `Vm.initBare` (NOT `TraceState.init`, which stays infallible —
    /// its ~120 call sites are hand-built test states that never run native
    /// seeded entries and leave this null); freed here in `deinit`. Compiled
    /// pages bake the pointer as an imm64, so it is assigned once and never
    /// reallocated for the VM's lifetime.
    native_seed_ctx: ?*NativeSeedCtx = null,
    /// Back-edge counters keyed by loop-header anchor. Only touched on the *slow*
    /// path (when the hot-count pre-filter trips), so for a non-gated anchor it
    /// still counts every back-edge (the pre-filter leaves un-gated slots at 0),
    /// preserving the arm-at-`hotloop` timing exactly. A gated anchor's count is
    /// coarse (the pre-filter skips most of its back-edges), which is fine — the
    /// gate's own cooldown is driven by `tick`, not this.
    counters: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Doc 20: per-VM copy-on-patch code images (§R1 fix). Canonical
    /// `Proto.code` is NEVER mutated; the first patch into a proto clones its
    /// code here and patches mutate only the clone. ONLY the dispatch fetch
    /// reads images (`codeFor`); recorder/predicates/visualiser/keyframes
    /// read canonical by construction. Lifetime is epoch-stable (§R2-2):
    /// freed only in `dropEntryPatchState` (epoch clear / deinit), never on
    /// last-unpatch. Empty forever on an unpatched run (§T7).
    code_images: std.AutoHashMapUnmanaged(*const Proto, []Instr) = .empty,
    /// Doc 20 §R2-1/§R3-4: monotone generation bumped on every image
    /// create/publish; `execImpl` re-resolves its cached `code` local in the
    /// back-edge epilogue when this differs from the generation it cached.
    /// `u64` so wrap-aliasing is structurally unreachable.
    image_gen: u64 = 0,
    /// Doc 20 §R2-6: the entry-patch registry. Indexed by the `.b` operand of
    /// patched `.jfor_loop` / `.jloop` instructions; each slot is its own allocation
    /// (stable addresses), tombstoned + reused via `entry_patch_free`.
    entry_patches: std.ArrayListUnmanaged(*EntryPatch) = .empty,
    entry_patch_free: std.ArrayListUnmanaged(u16) = .empty,
    /// Count of pending-unpatch marks awaiting the safe-point drain. A bare
    /// counter (not a list) so `markEntryPatchPending` cannot OOM mid-grammar
    /// (§R2-4); the drain early-outs at 0 and scans slots only when dirty.
    entry_patch_dirty: u32 = 0,
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
    /// Committed traces. A linear scan is fine — the cache stays small (dozens,
    /// not thousands) and dispatch goes through per-anchor lookups.
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
    /// regardless of retire order. Populated by `armNativeLink` (2.3b+).
    armed_links: std.ArrayListUnmanaged(NativeLink) = .empty,
    /// B-3b.2 silent-cycle registry. `promoted_exit_owners` is the exclusive
    /// physical-exit ownership index required by §B3.9(4); ids, rather than list
    /// indices, remain stable across swap-removal.
    promoted_sets: std.ArrayListUnmanaged(PromotedSet) = .empty,
    promoted_exit_owners: std.AutoHashMapUnmanaged(ExitKey, u32) = .empty,
    next_promoted_set_id: u32 = 1,
    promotion_candidate: []PromotedEdge = &.{},
    promotion_candidate_run: u32 = 0,
    promotion_candidate_region: ?RegionKey = null,
    /// Cycle ids queued while replay is validating the armed-link registry.
    /// Capacity is reserved before promotion publication, so queuing is infallible.
    pending_demote: std.ArrayListUnmanaged(PendingDemotion) = .empty,
    /// Part B-2b: persistent hotexit-provenance relations. Edges are expected to
    /// be few, so lifecycle operations deliberately use linear scans.
    provenance_edges: std.ArrayListUnmanaged(ProvenanceEdge) = .empty,
    /// Part B-2b drain gate: the physical sibling arms are a disposable cache,
    /// but RE-publishing is only needed after an event that could have changed
    /// what's publishable — a new edge, a disarm, or a trace retirement. The
    /// drain runs at every dispatcher safe point (per walk), so without this
    /// flag its edge×armed_links scan becomes a permanent per-walk tax
    /// (measured 5.7% of nsieve-bit wall). Set at every invalidating event;
    /// cleared by a drain pass that ends with nothing transiently deferred.
    provenance_arms_pending: bool = false,
    /// B-2b episode gate. `provenance_edges` is GLOBAL across protos, but the
    /// drain always runs inside ONE frame's episode, and a seeded child anchored
    /// in a different proto is not enterable under it. Such an edge is neither
    /// armable now nor permanently declined, so folding it into
    /// `provenance_arms_pending` (retried at every safe point) latched that flag
    /// permanently and defeated the gate it exists to keep shut. Tracked
    /// separately and re-opened ONLY when the live episode identity changes.
    provenance_arms_episode_pending: bool = false,
    /// The `liveEpisodeProto()` the last drain pass ran under. `null` (no fresh
    /// episode) is a distinct value from every proto pointer, so the pass-level
    /// staleness seam re-opens correctly too.
    provenance_drain_episode: ?*const anyopaque = null,
    /// Trace-cache mutation generation: bumped on every `cache` append/remove/clear.
    /// Keys the per-trace `anchor_pop_*` memo so hot-path anchor-population queries
    /// (`anchorPopulation`) are one compare in steady state instead of an O(cache)
    /// `countTracesAt` scan per receipt. Starts at 1 so a fresh trace's memo (gen 0)
    /// always recomputes; wrap-around collision would need 2^32 mutations inside one
    /// trace's lifetime — not reachable.
    cache_gen: u32 = 1,
    /// O(1) `traceById` index: slot `id` holds the live committed trace with that
    /// id, or null (retired / gap / never registered). Ids are monotonic and never
    /// reused (P-B), so the array only grows with commits. Maintained fail-soft: a
    /// grow-OOM at commit simply leaves the id unindexed and `traceById` falls back
    /// to the linear cache scan (hand-built test traces appended straight to
    /// `cache` take that fallback too), so results are identical by construction.
    trace_by_id: std.ArrayListUnmanaged(?*Trace) = .empty,
    /// A-vii-d.1: at most one bridge-arm request recorded by `replayLedger` when
    /// it walks a terminal composite `.deopt` row, drained by the ledger DRIVERS
    /// via `drainPendingBridgeArm` after the replay returns (never mid-walk —
    /// review blocker 5: a mid-ledger `invalidateRegion → disarmAllLinks` could
    /// erase the armed provenance later `.region_bridge` rows validate against).
    /// Cleared at every `replayLedger` entry so a stale request can never leak
    /// across ledgers.
    pending_bridge_arm: ?ExitKey = null,
    /// Part S: one-shot arm request. Set when a `Trace.sibling_watch_count` crosses
    /// `hotguard`; consumed by `tryArmSiblingHandoff` at the dispatcher's NEXT
    /// successful same-anchor trace entry — so the armed child is the trace the
    /// deterministic dispatch actually ran, never a hit-count guess made here.
    pending_sibling_arm: ?ExitKey = null,
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
    /// Doc 31 D1: anchors currently held off *recording* (never dispatch) with
    /// the same doubling cooldown. Set on recording aborts and commit
    /// failures — LuaJIT's `penalty_pc` analog: a failed recording backs off
    /// RE-RECORDING at its start anchor; a committed trace at the same anchor
    /// keeps dispatching. Recording eligibility consults BOTH maps
    /// (`recordingBarred`); dispatch consults only `gate`. At `max_strikes`
    /// the anchor is permanently record-blacklisted (survives trace
    /// retirement — accepted `penalty_pc` blacklist semantics, doc 31 §3).
    record_gate: std.AutoHashMapUnmanaged(AnchorKey, Gate) = .empty,
    /// Doc 38: per-anchor count of `loop_leave` aborts (a while/repeat root
    /// recording that observed its own loop's exit direction). Below
    /// `config.lleave_fast_retries` the abort is a silent retry (no record-gate
    /// strike); at/past it, the anchor is treated as a proven low-trip loop —
    /// gate strikes resume AND `recWhileLink`'s innerloopleft check lets an
    /// enclosing root unroll it. Reset wholesale with the gates (epoch
    /// boundary) so a freed proto's key never lingers.
    lleave_count: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Doc 38 unroll-first policy: per-OUTER-anchor count of proven unroll
    /// failures — a root recording that unrolled an inner while and then
    /// aborted, or a committed unrolled root whose anchor got gated for
    /// legacy thrash. At `config.unroll_fail_flip` the outer anchor stops
    /// unrolling and `recWhileLink` decomposes (LINNER) instead. Mirrors
    /// LuaJIT's `innerloopleft` evidence counter with the roles REVERSED:
    /// LuaJIT tries the inner root first because its side exits are patched
    /// branches; mahina's exits re-enter the runtime per inner completion, so
    /// unrolling is the profitable default (measured: unroll 17 cyc/it vs
    /// decomposed ~95 cyc/it on a bounded-variance nest) and decomposition is
    /// the escape for trip variance unrolling cannot cover (nsieve-bit-fp:
    /// decomposition 4x faster than failed unrolling). Reset wholesale with
    /// the gates (epoch boundary).
    unroll_fail: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Doc 38 yield gate accumulator: per-anchor (entries, iters) over the
    /// current probe window, fed by every ENTERED receipt whose exit is a
    /// while-loop-done guard (`noteWhileYield`). Reset per verdict and on the
    /// epoch boundary with the gates.
    while_yield: std.AutoHashMapUnmanaged(AnchorKey, WhileYield) = .empty,
    /// Re-entry penalty per anchor: a low-yield trace entry bumps it, a
    /// productive one clears it (doc 31 D2); at `config.max_penalty` the anchor
    /// is gated off with a doubling cooldown (`onSideExit` → `gateAnchor`).
    penalty: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Pure ephemeral structural-edge cache (doc 17 §A3.3 / §A8-ii, A-ii.2):
    /// `{Trace.id, exit_instr} → StructuralEdgeId`. Rebuilt WHOLESALE from the current
    /// cache at every commit AND every retirement (never surgically mutated), dropped
    /// in `clearCache`, freed in `deinit`. NOT a source of truth — consumed by the
    /// region classifier and region-bridge validation (`validateRegionBridge`).
    /// A rebuild reserves capacity BEFORE clearing the prior snapshot, so a
    /// commit-path OOM RETAINS it and a retirement-path OOM fail-closes to EMPTY
    /// (both region-neutral: an empty cache arms nothing).
    edge_cache: std.AutoHashMapUnmanaged(ExitKey, StructuralEdgeId) = .empty,
    /// Discovered region definitions keyed by interned `RegionId` (doc 17 §A3.1 /
    /// §A8-ii, A-ii.4). **Proto/VM-lifetime**: accumulated as traces commit, NEVER
    /// cleaned by `removeTrace` (a GC-physical retire must not diverge
    /// `gc_stress on/off`), cleared ONLY wholesale in `clearCache` (the epoch boundary
    /// where protos may be freed). Owns each `RegionDef`'s `members`/`member_points`.
    /// Consumed by the arming path (`armable` flips, `edgeMemberOfRegion`).
    region_defs: std.AutoHashMapUnmanaged(RegionId, RegionDef) = .empty,
    /// Invalidation generation for `Trace.region_memo_*` (freeze-after-qualify,
    /// task #70). Bumped at EVERY `region_defs` mutation — new/updated defs and
    /// every `armable` flip — so per-trace footprint-membership memos never
    /// outlive the def state they were computed against. Starts at 1 so a fresh
    /// trace's memo gen 0 can never spuriously match.
    region_defs_gen: u32 = 1,
    /// Single-slot cache of the qualified-live-activation resolution inside
    /// `qualifiedActiveMember` (task #70 seam work): the `activeRegionFor` map
    /// iteration + `region_profit.getPtr` + qualification check for one
    /// `call_seq`. `act_cache_gen == 0` means invalid; it is zeroed by
    /// `refreshObserverFast` (the single hook every `region_profit` mutation
    /// already runs through, so the cached `accum` pointer can never dangle) and
    /// by the `useful_window_seen` flip (which changes the cached verdict without
    /// mutating the map). The `region_defs_gen` half of the key covers footprint
    /// changes.
    act_cache_seq: u64 = 0,
    act_cache_gen: u32 = 0,
    act_cache: ?MemberAccum = null,
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
    /// `classifyExit`, whose result feeds `tryArmRegionBridge`. A retirement-rebuild
    /// OOM publishes EMPTY (fail-closed — the prior set references a dead trace).
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
    /// A-vii-e.1: single-accumulator observer fast path (see `ObserverFast`).
    observer_fast: ?ObserverFast = null,
    /// A-vii-e.2: inline hot-span cache over `observer_fast` (see `ObserverHot`).
    observer_hot: ObserverHot = .{},
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
    /// The subset of `entries` where the dispatcher actually committed to running
    /// **native** code (`nativeFor(ct)` resolved and `ran_native` was set), as
    /// opposed to falling back to the tier-1a IR interpreter or the exec-log
    /// recorder. Diagnostic only — no tiering path reads it.
    ///
    /// `entries` alone cannot carry R2-4's claim ("an open observation window
    /// removes the native→native handoffs, not the traces"): it is bumped before
    /// the native-vs-IR choice is made, so a run that silently fell back to
    /// tier-1a for every entry would still advance it. This counter is the one
    /// that says native trace bodies are still being entered *through the
    /// dispatcher*, which is exactly the post-blackout state R2-4 describes.
    native_entries: u64 = 0,
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
    /// Doc 22 §B.2/§B.6 diagnostics: seed-prologue declines observed at any
    /// drain seam — the dispatcher's direct-entry handlers (interp.zig, scalar
    /// `ledger_len <= 1`), `replayLedger`'s fused/silent decline rows, and
    /// `driveChain`'s tier-1a chain seams. Output equality alone cannot prove
    /// a decline path actually fired (the §B.6 decline-determinism tests need
    /// the witness), and no tiering path reads them.
    seed_hash_declines: u64 = 0,
    seed_capacity_declines: u64 = 0,
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
    /// Part S: how many sibling-handoff slots were armed / actually fired natively.
    sibling_handoff_arms: u64 = 0,
    sibling_handoff_fused: u64 = 0,
    /// 2.3c-1 (M1 half-fusion, doc 17): count of fused skip→prime-side receipts DRAINED
    /// by the dispatcher's M1 fused-`.link` consumer (interp.zig) — i.e. the arm above
    /// actually took effect and a native `ct.run` fused straight into the prime-side ramp
    /// (`final != ct`, provenance via `hasArmedSourceBranchLinkAt`). Distinct from the arm
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
    silent_promotions: u64 = 0,
    silent_demotions: u64 = 0,
    silent_promotion_candidates: u64 = 0,
    silent_rejects: PromotionRejects = .{},
    silent_demotion_reasons: PromotionDemotions = .{},
    silent_bursts_drained: u64 = 0,
    silent_transitions_total: u64 = 0,
    silent_budget_exhaustions: u64 = 0,
    silent_barren_exhaustions: u64 = 0,
    silent_suffix_drains: u64 = 0,
    silent_hops_total: u64 = 0,
    /// One-call staging for sibling provenance. Silent prefix evidence is
    /// merged with the reporting suffix before one final verdict is applied.
    silent_provenance: [PROVENANCE_VERDICT_CAP]SilentProvenanceEvidence = undefined,
    silent_provenance_len: usize = 0,
    /// A-viii (doc 17 §A8 step 8): the high-water mark of `armed_links.len` — the
    /// most handoff edges ever armed SIMULTANEOUSLY. The per-kind arm counters are
    /// lifetime totals, so they cannot distinguish "the three edges of the outer
    /// cycle were live at once" (a closed armed cycle, which is what the disarm
    /// path must be able to tear down) from "three edges each armed and torn down
    /// in turn". This peak can: `>= 3` with a `.region_bridge` among the kinds is
    /// the outer cycle `skip→…→cont→skip` standing complete. Diagnostic only — no
    /// selection path reads it, so it cannot perturb the 10-mode equivalence.
    native_link_peak: usize = 0,
    /// A-vii-d (doc 17 §A-vii.2): count of composite bridge slots actually armed by
    /// `tryArmRegionBridge` — a region member's composite ordinary guard slot pointed
    /// at the registered successor's `ordinary_entry`, so the next time that guard
    /// fires natively the stub commits the dominance-scoped phi snapshot and jumps
    /// STRAIGHT into the cross-anchor child (edge 4, no Zig re-entry). `> 0` is the
    /// "the region-profit gate qualified a region and the arm actually happened"
    /// signal for the A-vii-d differential tests.
    native_region_bridge_arms: u64 = 0,
    /// How many times `tryArmRegionBridge` ran its pipeline — i.e. got PAST
    /// `maybeArmCompositeExit`'s memo gates and paid for `classifyExit` + the
    /// def/profit probes + `validateRegionBridge` (which alone measured 2.4% of
    /// nsieve N=5). The ratio against `native_region_bridge_arms` is the memo's
    /// hit rate: a durably non-enterable child should show ONE attempt per
    /// activation, not one per composite deopt. Diagnostics only — never read by
    /// a decision, so it cannot perturb the byte-identical stream.
    native_region_bridge_arm_attempts: u64 = 0,
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
    /// Steering-seam time: TSC cycles spent inside the OUTERMOST `replayLedger`
    /// walk (per-receipt ledger validation + steering), and how many such walks
    /// ran. The walk executes inside the dispatcher's trace-exec bracket, so this
    /// is a sub-interval of `cycles_traced` — the report subtracts it to split
    /// "traced" into native execution proper vs runtime seam (the split perf
    /// attributes to `replayLedger` self-time vs `[JIT]`). Gated on
    /// `config.coverage` exactly like every other TSC read; nested walks
    /// (`replay_walk_depth > 0` at entry) are not re-bracketed, so no
    /// double-counting. x86_64 only (0 elsewhere).
    cycles_seam: u64 = 0,
    seam_walks: u64 = 0,
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
    /// The in-progress recording (at most one at a time).
    rec: Recorder = .{},
    /// Reusable SSA-value scratch for the tier-1a executor (`irinterp.execute`),
    /// indexed by `Ref`. Reused across every entry — never allocated
    /// per-iteration or per-entry. Not a GC root (the executor runs no
    /// safepoint; see `irinterp.zig`).
    ///
    /// **Segmented, because trace execution NESTS and the frames must not move.**
    /// The dispatcher takes a frame for the trace it enters and keeps it live
    /// across `driveChain` (it is the `.ir_numeric_for_done` payload); the
    /// candidate walk takes a frame per candidate; `runLinkedBurst` takes one
    /// per hop. A single flat growable buffer cannot serve that shape: growing
    /// it to fit an inner frame reallocates, and every outer frame's slice
    /// becomes a dangling pointer into freed memory. That was a real
    /// use-after-free — `--trace bench/luajit/nsieve-bit.lua 6` (38-instr entry,
    /// 59-instr candidate) and `--trace bench/luajit/scimark-sparse.lua 3000`
    /// (44 → 57) both moved the buffer, in ReleaseFast as well as Debug, and
    /// `flushNumericForLoopDone` then read the freed block. Release only printed
    /// the right answer because the process allocator neither scrubs a freed
    /// block nor had reused it yet.
    ///
    /// So the backing is a list of independently-allocated chunks: appending a
    /// chunk moves the list of *slices*, never the `Value`s a live frame points
    /// at. Frames are carved bump-style within a chunk and released in LIFO
    /// order via `valuesMark`/`valuesRelease` — which is what makes a chunk at
    /// or above `values_cur` provably dead and therefore safe to reallocate when
    /// an oversized frame needs it. Each chunk holds at least
    /// `values_chunk_slots`, and a frame larger than that simply gets a chunk of
    /// its own, so no frame ever straddles a chunk boundary and no invariant
    /// depends on `config.maxrecord`.
    values_chunks: std.ArrayListUnmanaged([]Value) = .empty,
    /// Index into `values_chunks` of the chunk currently being carved from.
    values_cur: u32 = 0,
    /// The un-carved tail of `values_chunks[values_cur]` — everything in that
    /// chunk after the deepest live frame. Kept as a slice rather than an offset
    /// so the push fast path is one length compare and a subslice: this runs on
    /// every trace entry, and chasing `values_cur → chunks.items.ptr → chunk →
    /// len` instead measured +1.3–2.2% on nsieve and scimark-fft. Empty before
    /// the first chunk exists, which the fast path's length check rejects.
    values_free: []Value = &.{},
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
    /// Burst-terminal telemetry (jitdbg builds only — never touched otherwise).
    /// One record per `driveDispatcherLedger` entry: burst ledger length histogram
    /// plus a per-(trace,exit,kind) count of the TERMINAL row — i.e. exactly the
    /// exits that hand control back to the runtime. This is the target list for
    /// exit-branch patching (doc 17 Part B): every entry here is a runtime
    /// round-trip that a patched transition or freeze could eliminate.
    dbg_burst_len_hist: [irinterp.LEDGER_CAP + 1]u64 = @splat(0),
    dbg_burst_terminals: std.AutoHashMapUnmanaged(DbgTerminalKey, u64) = .empty,
    /// B-3c telemetry: composition of silent-burst SUFFIX ledgers — every
    /// materialized row a burst still produced despite live promotion, keyed
    /// like the terminals. These rows are what end bursts (ledger-full) and
    /// what the suffix replay walks, so they are the remaining seam feedstock:
    /// any hot key here is a candidate for a further promoted set.
    dbg_silent_suffix_rows: std.AutoHashMapUnmanaged(DbgTerminalKey, u64) = .empty,
    /// B-3a seam gate input: every replay row is partitioned by whether its physical
    /// armed edge belongs to any bridge-free closed directed subcycle.
    dbg_patchable_cycle_rows: u64 = 0,
    dbg_other_replay_rows: u64 = 0,
    /// When non-null, the next back-edge to this anchor will arm a side-trace
    /// recording (even if a trace already exists there).  Set by
    /// `countGuardFailure` when a guard-failure crosses `hotguard`; cleared
    /// by `onBackEdge` when the side trace is armed.
    wants_side_trace: ?AnchorKey = null,
    /// Provenance of the pending `wants_side_trace` when it came from a hot exit
    /// (`noteTakenExit`): the parent `(trace id, exit index)` to DONE-latch once
    /// the side trace commits — Pall's `snap->count = SNAPCOUNT_DONE` at side-
    /// trace link (lj_trace.c:535). Null for fingerprint-miss wants (those have
    /// no single parent exit). Follows the want through consume →
    /// `pending_replay_src` → `Recorder.side_src`; cleared wherever the want is
    /// dropped, so `side_want_src != null ⇒ wants_side_trace != null`.
    side_want_src: ?ExitKey = null,
    /// `side_want_src` after `consumeSideTraceWantAtResume` moved the want into
    /// `pending_replay_anchor`; transferred to `Recorder.side_src` by
    /// `maybeStartReplaySide`, cleared with `pending_replay_anchor`.
    pending_replay_src: ?ExitKey = null,
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
    /// **Coherent-state chaining (doc 16, Phase 2).** When non-null, a
    /// branch-guard at this outer-header anchor has gone hot: the next such exit
    /// should arm an *immediate* replay of the current (prime) iteration — recording
    /// the taken branch forward through the inner `for_prep` and closing with a
    /// `.link` to the inner root — rather than the *next* iteration (which the
    /// `wants_side_trace`/`onBackEdge` path would record, and which is ~93% a
    /// composite in nsieve, the wrong path). Set by `noteTakenExit` (the unified
    /// hotexit counter routes source-branch guard exits here at the `hotexit`
    /// threshold — the separate hotguard-50 per-anchor map is gone);
    /// consumed at the productive-exit site by handing off to `pending_replay_anchor`.
    wants_prime_side: ?AnchorKey = null,
    /// Hotexit provenance for `wants_prime_side` (mirrors `side_want_src`): the
    /// parent `(trace, exit)` to DONE-latch when the prime side trace commits.
    /// Handed to `pending_replay_src` at the consumption site; cleared wherever
    /// `wants_prime_side` is dropped.
    prime_want_src: ?ExitKey = null,
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
    /// Part S: does an armed `.sibling_handoff` link exist for exactly this
    /// (parent, exit) → child triple? The replay-side proof of the arm.
    pub fn hasArmedSiblingHandoff(self: *const TraceState, parent: *const Trace, exit_instr: u32, child: *const Trace) bool {
        // Fast reject: `sibling_arms` counts this parent's armed handoffs and is
        // maintained by every arm/disarm path, so `== 0` is an exact necessary
        // condition for the scan below to find anything. This runs once per non-final
        // `.deopt` row in the hot replay walk; the registry scan must not.
        if (parent.sibling_arms == 0) return false;
        for (self.armed_links.items) |l| {
            if (l.kind == .sibling_handoff and l.parent == parent and
                l.slot_index == exit_instr and l.child == child) return true;
        }
        return false;
    }

    /// Part S / §S-a: the ANCHOR-COHERENCE proof for a handoff exit — does no
    /// heap-mutating op precede `exit_instr` in the trace body?
    ///
    /// This is the eligibility check the first cut of Part S omitted, and omitting it
    /// is not a subtlety: a native deopt flushes CARRIED HOMES only (invariants stay at
    /// their entry values, internal phis are never flushed), so the flushed register
    /// image is the anchor state OF THE CURRENT ITERATION. Handing that to a
    /// same-anchor sibling therefore re-runs the current iteration from its top — sound
    /// exactly when the iteration has not yet mutated the heap, and silently wrong
    /// otherwise. Measured: without this check the A-viii outer-cycle test prints 108
    /// where the unfused run prints 109, one iteration dropped.
    ///
    /// A linear scan rather than a `bridge_cand`-style per-trace bitset on purpose:
    /// this is consulted only when the watch MOVES and again at arm time, both cold.
    /// A memo here would buy nothing and cost a build/free/serialize lifecycle.
    ///
    /// The store ops here are `tropt.kindOf`'s `.astore` class. `sgm_setpos`
    /// (kind `.setpos`, doc 30) is a store too, but it is NEVER emitted inline —
    /// it only enters the IR through the pending-store sink, below every guard —
    /// so no exit can precede one and the scan need not name it. That safety
    /// lives in `commit`'s sinking discipline, not here: if `sgm_setpos` ever
    /// gains an inline emission path it must join this list. Guards (which
    /// side-exit but mutate nothing) and `int_of_float` are deliberately fine.
    /// The doc-24 allocating producers (`tostr_*`, snew, `scap_str`) also fall
    /// through: they only intern (grow the heap), never mutate guest-visible
    /// state, so re-running the iteration re-interns identically (D2 id-stream).
    fn exitIsPreEffect(t: *const Trace, exit_instr: u32) bool {
        const n = @min(@as(usize, exit_instr), t.instrs.len);
        for (t.instrs[0..n]) |ins| switch (ins.op) {
            .astore, .astore_append, .hstore, .gstore => return false,
            else => {},
        };
        return true;
    }

    /// Part S: is `exit_instr` of `t` an anchor-coherent ordinary deopt exit that
    /// the sibling-handoff stub can drive? The stub is the existing ordinary-guard
    /// path (resolve through `slot[ei]` → flush carried homes → append → forced-yield
    /// → `jmp`), so eligibility is exactly the set of exits that path owns.
    fn siblingHandoffEligible(self: *const TraceState, t: *Trace, exit_instr: u32) bool {
        const c = switch (t.native) {
            .compiled => |*cc| cc,
            else => return false,
        };
        if (exit_instr >= c.slots.len or exit_instr >= t.instrs.len) return false;
        // Already armed here: the slot is taken, so counting it again could only
        // produce a redundant arm. Consulted on the watch-MOVE path only, never
        // per receipt, so the registry scan stays off the hot path.
        if (t.sibling_arms != 0) {
            for (self.armed_links.items) |l| {
                if (l.kind == .sibling_handoff and l.parent == t and l.slot_index == exit_instr)
                    return false;
            }
        }
        // Loop-done slots belong to `.loop_done_linked` (P-C option (b)), and the
        // ordinary loop-done deopt bypasses `slot[ei]` entirely in emission.
        if (isLoopDoneGuardIndex(t, exit_instr)) return false;
        // Bridge candidates run the A-v bridge stub body, not the plain path.
        if (t.isBridgeCandidate(exit_instr)) return false;
        // The anchor-coherence proof. Without it the handoff is not
        // semantics-preserving — see `exitIsPreEffect`.
        if (!exitIsPreEffect(t, exit_instr)) return false;
        // PROGRESS, not just soundness: only a SOURCE-BRANCH guard may arm. A branch
        // guard failing means the program took the OTHER branch at the shared anchor
        // decision — exactly the case the same-anchor sibling was recorded for, so the
        // handoff completes the iteration natively. Any other guard kind (zero-trip
        // loop-entry checks, bounds, type) says nothing about which branch holds:
        // the sibling re-runs the iteration, its OWN branch guard fails, and the
        // armed pair PING-PONGS until the ledger cap forces a yield. Measured on
        // nsieve N=9: arming the zero-trip exit ei=16 turned 304k two-row bursts
        // into 304k THIRTY-TWO-row yield bursts — +128% wall-clock from a mechanism
        // that is a −7% win when it arms branch guards only.
        //
        // `isSourceBranchGuardExit` alone is NOT that test: it excludes only
        // `for_loop`-sourced guards, so a `for_prep`-sourced zero-trip check (nsieve's
        // ei=16, guard_true over `le i+i, m`) passes it while telling us nothing about
        // the anchor branch. Require the POSITIVE property instead: the guard's source
        // opcode is a conditional branch — the one bytecode shape where "this guard
        // failed" and "the sibling's branch was taken" are the same statement.
        if (!self.isSourceBranchGuardExit(t, exit_instr, t.anchor.proto)) return false;
        const src_pc = guardSourcePc(t.instrs[exit_instr]) orelse return false;
        if (src_pc >= t.anchor.proto.code.len) return false;
        switch (t.anchor.proto.code[src_pc].op) {
            .jmp_if_false, .jmp_if_true, .jmp_if_not_nil => {},
            else => return false,
        }
        return true;
    }

    /// Part S: charge one burst-terminal receipt to `(trace, exit)` and, on crossing
    /// `hotguard`, request an arm. Pure function of the receipt stream.
    fn noteSiblingTerminal(self: *TraceState, t: *Trace, exit_instr: u32) void {
        // Steady state (a request already in flight): one optional load and out. See
        // `Trace.sibling_watch_exit` for why this path has to be free, not just cheap.
        if (self.pending_sibling_arm != null) return;
        // Single-slot ineligible memo: a terminal at the last known-ineligible exit
        // is one compare and out — never a re-scan. Cleared on any arm/disarm event
        // touching this trace (the only non-static eligibility input).
        if (t.sibling_reject_exit == exit_instr) return;
        if (t.sibling_watch_exit != exit_instr) {
            self.dbg("sibling-watch-move: t={d} ei={d} (from ei={d} count={d}) eligible={}", .{
                t.id,                                       exit_instr, t.sibling_watch_exit, t.sibling_watch_count,
                self.siblingHandoffEligible(t, exit_instr),
            });
            // The watch moves at most once per distinct eligible exit; eligibility
            // (which touches `native.compiled`, the loop-done predicate and the
            // bridge memo) is therefore NOT on the per-receipt path. An ineligible
            // exit leaves the watch untouched, so it cannot starve the eligible one.
            if (!self.siblingHandoffEligible(t, exit_instr)) {
                t.sibling_reject_exit = exit_instr;
                return;
            }
            t.sibling_watch_exit = exit_instr;
            t.sibling_watch_count = 0;
        }
        t.sibling_watch_count +|= 1;
        if (t.sibling_watch_count == self.config.hotguard)
            self.pending_sibling_arm = .{ .trace_id = t.id, .exit_instr = exit_instr };
    }

    /// Part S: consume a pending arm request now that the dispatcher has actually
    /// selected and entered `child`. The armed target is therefore the trace the
    /// deterministic dispatch ran — `hit_count` never enters the contract.
    pub fn tryArmSiblingHandoff(self: *TraceState, child: *Trace, safe_to_arm: bool) void {
        const key = self.pending_sibling_arm orelse return;
        if (!safe_to_arm) return; // keep pending; observation window owns the slot
        const parent = self.traceById(key.trace_id) orelse {
            self.pending_sibling_arm = null; // parent retired: request is stale
            return;
        };
        if (parent == child) return; // not a sibling handoff; wait for a real sibling
        if (child.anchor.proto != parent.anchor.proto or child.anchor.pc != parent.anchor.pc)
            return; // different anchor: this entry is not the one the request meant
        self.pending_sibling_arm = null;
        _ = self.publishSiblingArm(parent, key.exit_instr, child);
    }

    /// Shared Part-S / Part-B publication funnel. On success only, publish the
    /// physical sibling arm and perform the complete Part-S latch/counter update.
    pub fn publishSiblingArm(self: *TraceState, parent: *Trace, exit_instr: u32, child: *Trace) bool {
        if (!(self.armNativeLink(parent, exit_instr, child, .sibling_handoff) catch false))
            return false;
        self.dbg("sibling-arm: t={d} ei={d} op={s} -> t={d}", .{
            parent.id, exit_instr, @tagName(parent.instrs[exit_instr].op), child.id,
        });
        self.sibling_handoff_arms +|= 1;
        // Fast-reject key for `hasArmedSiblingHandoff`; decremented by every
        // disarm path via `clearSiblingLatch`.
        parent.sibling_arms +|= 1;
        // Release the watch so this parent's NEXT hot exit can qualify. The
        // just-armed exit is now rejected by `siblingHandoffEligible`, so the
        // watch cannot simply land back on it.
        parent.sibling_watch_exit = std.math.maxInt(u32);
        parent.sibling_watch_count = 0;
        return true;
    }

    /// Record one dispatcher burst's ledger for the Part-B terminal telemetry
    /// (jitdbg builds only; comptime-false → zero cost in normal builds). Called
    /// from `driveDispatcherLedger` with the full burst ledger.
    pub fn dbgNoteBurst(self: *TraceState, entries: []const irinterp.LedgerEntry) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            const len = @min(entries.len, self.dbg_burst_len_hist.len - 1);
            self.dbg_burst_len_hist[len] += 1;
            if (entries.len == 0) return;
            const t = entries[entries.len - 1];
            const gop = self.dbg_burst_terminals.getOrPut(self.gpa, .{
                .trace_id = t.id,
                .exit_instr = t.exit,
                .kind = t.kind,
                .outcome = t.outcome,
            }) catch return; // telemetry: drop on OOM, never fail the burst
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    /// B-3c: aggregate a silent burst's suffix-ledger rows (jitdbg builds only).
    pub fn dbgNoteSuffixLedger(self: *TraceState, entries: []const irinterp.LedgerEntry) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            for (entries) |row| {
                const gop = self.dbg_silent_suffix_rows.getOrPut(self.gpa, .{
                    .trace_id = row.id,
                    .exit_instr = row.exit,
                    .kind = row.kind,
                    .outcome = row.outcome,
                }) catch return; // telemetry: drop on OOM, never fail the drain
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    fn armedEdgeInBridgeFreeCycle(self: *const TraceState, parent: *const Trace, exit_instr: u32) bool {
        var first_child: ?*Trace = null;
        for (self.armed_links.items) |link| {
            if (link.parent == parent and link.slot_index == exit_instr and link.kind != .region_bridge) {
                first_child = link.child;
                break;
            }
        }
        const child = first_child orelse return false;
        if (child == parent) return true;

        var pending: [64]*Trace = undefined;
        var seen: [64]*Trace = undefined;
        var pending_len: usize = 1;
        var seen_len: usize = 0;
        pending[0] = child;
        while (pending_len > 0) {
            pending_len -= 1;
            const cur = pending[pending_len];
            if (cur == parent) return true;
            var duplicate = false;
            for (seen[0..seen_len]) |s| if (s == cur) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            if (seen_len == seen.len) return false;
            seen[seen_len] = cur;
            seen_len += 1;
            for (self.armed_links.items) |link| {
                if (link.parent != cur or link.kind == .region_bridge) continue;
                if (pending_len == pending.len) return false;
                pending[pending_len] = link.child;
                pending_len += 1;
            }
        }
        return false;
    }

    fn dbgNoteReplayRow(self: *TraceState, owner: *Trace, exit_instr: u32) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            if (self.armedEdgeInBridgeFreeCycle(owner, exit_instr))
                self.dbg_patchable_cycle_rows +|= 1
            else
                self.dbg_other_replay_rows +|= 1;
        }
    }

    /// Dump the burst-terminal telemetry: ledger-length histogram + every terminal
    /// site sorted is left to the reader (use sort(1)). Same double gate as the
    /// other dbgDump* helpers. This is the Part-B patch target list: each line is
    /// "this exit site handed control back to the runtime N times".
    pub fn dbgDumpBurstStats(self: *TraceState) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            var total: u64 = 0;
            for (self.dbg_burst_len_hist) |c| total += c;
            jitdbg.log("burst stats: {d} dispatcher bursts", .{total});
            const replay_total = self.dbg_patchable_cycle_rows +| self.dbg_other_replay_rows;
            jitdbg.log("  B-3 seam rows: bridge-free-closed={d} rest={d} total={d}", .{
                self.dbg_patchable_cycle_rows, self.dbg_other_replay_rows, replay_total,
            });
            jitdbg.log("  silent: candidates={d} promotions={d} demotions={d} bursts={d} transitions={d} hops={d} budget={d} barren={d} suffix={d}", .{
                self.silent_promotion_candidates, self.silent_promotions,
                self.silent_demotions,            self.silent_bursts_drained,
                self.silent_transitions_total,    self.silent_hops_total,
                self.silent_budget_exhaustions,   self.silent_barren_exhaustions,
                self.silent_suffix_drains,
            });
            jitdbg.log("  silent rejects: bridge={d} region={d} open={d} child-mismatch={d} no-patch={d} cap={d} region-owned={d}", .{
                self.silent_rejects.bridge_member,
                self.silent_rejects.region_mismatch,
                self.silent_rejects.open_chain,
                self.silent_rejects.child_mismatch,
                self.silent_rejects.no_patch_point,
                self.silent_rejects.cap,
                self.silent_rejects.region_owned,
            });
            jitdbg.log("  silent demotions: activation={d} region-close={d} slot={d} trace={d} teardown={d} unfreeze={d} growth={d}", .{
                self.silent_demotion_reasons.activation,
                self.silent_demotion_reasons.region_close,
                self.silent_demotion_reasons.slot_mutation,
                self.silent_demotion_reasons.trace_invalidation,
                self.silent_demotion_reasons.teardown,
                self.silent_demotion_reasons.unfreeze,
                self.silent_demotion_reasons.membership_growth,
            });
            for (self.dbg_burst_len_hist, 0..) |c, len| {
                if (c != 0) jitdbg.log("  burst-len {d}: {d}", .{ len, c });
            }
            var it = self.dbg_burst_terminals.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                jitdbg.log("  terminal t={d} ei={d} kind={s} outcome={s}: {d}", .{
                    k.trace_id,          k.exit_instr,  @tagName(k.kind),
                    @tagName(k.outcome), e.value_ptr.*,
                });
            }
            var sit = self.dbg_silent_suffix_rows.iterator();
            while (sit.next()) |e| {
                const k = e.key_ptr.*;
                jitdbg.log("  suffix-row t={d} ei={d} kind={s} outcome={s}: {d}", .{
                    k.trace_id,          k.exit_instr,  @tagName(k.kind),
                    @tagName(k.outcome), e.value_ptr.*,
                });
            }
        }
    }

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
        self.dbgDumpBurstStats(); // jitdbg-only burst-terminal telemetry (Part B)
        self.demoteAllSets();
        if (self.pending_demote.items.len != 0)
            @panic("TraceState.deinit: promotion demotion deferred during teardown");
        self.dbg_burst_terminals.deinit(self.gpa);
        self.dbg_silent_suffix_rows.deinit(self.gpa);
        self.counters.deinit(self.gpa);
        self.gate.deinit(self.gpa);
        self.record_gate.deinit(self.gpa);
        self.lleave_count.deinit(self.gpa);
        self.unroll_fail.deinit(self.gpa);
        self.while_yield.deinit(self.gpa);
        self.penalty.deinit(self.gpa);
        self.guard_failures.deinit(self.gpa);
        for (self.values_chunks.items) |c| self.gpa.free(c);
        self.values_chunks.deinit(self.gpa);
        for (self.exec_logs.items) |*l| l.deinit(self.gpa);
        self.exec_logs.deinit(self.gpa);
        self.abort_log.deinit(self.gpa);
        if (self.exec_recorder) |*r| r.deinit();
        self.armed_links.deinit(self.gpa);
        self.pending_demote.deinit(self.gpa);
        if (self.promotion_candidate.len != 0) self.gpa.free(self.promotion_candidate);
        self.promoted_exit_owners.deinit(self.gpa);
        self.promoted_sets.deinit(self.gpa);
        self.provenance_edges.deinit(self.gpa);
        self.trace_by_id.deinit(self.gpa);
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
        self.freeObserverFast(); // A-vii-e.1: owned bitset copies
        // Doc 20 §R2-2: VM teardown is the other legal image-free point.
        self.dropEntryPatchState();
        self.code_images.deinit(self.gpa);
        self.entry_patches.deinit(self.gpa);
        self.entry_patch_free.deinit(self.gpa);
        // Free each trace (its `native.deinit()` returns mcode slots to the arena's
        // free-list) *before* tearing down the arena those slots live in.
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.deinit(self.gpa);
        self.mcode_arena.deinit();
        // Doc 22 §B.1: the seeding ctx outlives every compiled page (pages bake
        // `&ctx` as an imm64), so it is freed only after the cache + arena are
        // gone. Null for hand-built test states (see the field doc).
        if (self.native_seed_ctx) |ctx| self.gpa.destroy(ctx);
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
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
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
    /// shape `findLoopTrace` requires: a `.loop`-terminated root anchored at
    /// `(proto, pc)`. Used to FAIL CLOSED — a fused result must be interpreted as
    /// the trace whose id it baked, never substituted by a same-PC sibling; if the id
    /// resolves to the wrong shape/location the child's exit left `regs[]` with no
    /// known-coherent resume PC, so callers `@panic` (hard invariant failure) rather
    /// than indexing a foreign trace's `instrs` (OOB / misclassified exit /
    /// mis-accounting) or silently resuming at a PC that re-runs a committed loop.
    /// B-iv.3 (doc 22 §B.5): seeded roots pass — shape is anchor + `.loop`
    /// terminal only; enterability is `stubEnterable`'s job, not shape's.
    fn isInnerLoopRoot(t: *const Trace, proto: *const Proto, pc: u32) bool {
        return t.anchor.proto == proto and t.anchor.pc == pc and
            t.instrs.len != 0 and t.instrs[t.instrs.len - 1].op == .loop;
    }

    pub fn findLoopTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
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
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .link) continue;
            // B-iv.3 (doc 22 §B.5): seeded continuations are selectable — the
            // tier-1a seams seed via §B.3 and a native page seeds itself at
            // entry (§B.4 prologue), declining cleanly through the B-iv.2
            // directives when stale.
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// B-4 (doc 17 §B4.3 D1'–D4'): the ONE canonical loop-done continuation
    /// selector every loop-done funnel shares — the drain's terminal directive
    /// and the arm sites resolve through this, never through the replay
    /// cursor's path history, so the armed relation per `(inner, exit)` is a
    /// stable pure function of the cache and cannot alternate (§B4.7 MAJOR-2).
    pub const LoopDoneCont = struct { arm: ?*Trace, run: ?*Trace };

    pub fn resolveLoopDoneCont(self: *TraceState, proto: *const Proto, post_pc: u32, regs: ?RegWindow) LoopDoneCont {
        // (1) Build the pure, canonically ordered candidate list FIRST — the
        // `findLinkTrace` structural P-G predicate only (`.link`-tailed,
        // anchored at `(proto, post_pc)`; B-iv.3 admits seeded candidates —
        // enterability is probed downstream); nothing in this pass
        // triggers compilation. Ranking: `hit_count` desc, then LOWEST trace id
        // (deterministic and stable across `cache.swapRemove` reshuffles —
        // §B4.7 tie-break correction). Fixed buffer, allocation-free: this runs
        // per terminal loop-done event. Overflow drops the lowest-ranked tail
        // (a pc with more than 8 eligible continuations exceeds
        // `max_traces_per_anchor` by 2× — unreachable today, bounded anyway).
        var buf: [8]*Trace = undefined;
        var n: usize = 0;
        for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto != proto or t.anchor.pc != post_pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .link) continue;
            var pos: usize = n;
            for (buf[0..n], 0..) |p, idx| {
                if (t.hit_count > p.hit_count or (t.hit_count == p.hit_count and t.id < p.id)) {
                    pos = idx;
                    break;
                }
            }
            if (pos >= buf.len) continue;
            const limit = @min(n + 1, buf.len);
            var j: usize = limit - 1;
            while (j > pos) : (j -= 1) buf[j] = buf[j - 1];
            buf[pos] = t;
            n = limit;
        }
        // (2) ARM target: probe `nativeFor` strictly in ranking order and stop
        // at the FIRST runnable candidate — an `.unsupported` (or
        // compile-failing, memoized) high-hit candidate must skip, not shadow,
        // a runnable sibling (§B4.7 BLOCKER). Probing here, before the run
        // resolution, pins the canonical lazy-compile order (D4').
        var arm_target: ?*Trace = null;
        for (buf[0..n]) |t| {
            if (self.nativeFor(t) != null) {
                arm_target = t;
                break;
            }
        }
        // (3) RUN target, resolved AFTER the arm probe over the same list:
        // when `regs` are provided, fingerprint-matching runnable candidates
        // rank strictly above non-matching ones; otherwise (and when nothing
        // matches) it falls back to the arm target — a mismatching candidate is
        // safe to ATTEMPT (the native prologue fails closed pre-commit), just
        // never preferred. The run choice never touches the armed slot.
        var run: ?*Trace = arm_target;
        if (regs) |r| {
            for (buf[0..n]) |t| {
                if (self.nativeFor(t) == null) continue;
                if (t.matchesFingerprint(r)) {
                    run = t;
                    break;
                }
            }
        }
        return .{ .arm = arm_target, .run = run };
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
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
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
    /// Bump a memo-invalidation generation, skipping the reserved 0 ("never
    /// computed") on u32 wrap — otherwise, ~2^32 mutations in, a freshly
    /// initialized memo (gen 0) would be trusted without ever computing (codex
    /// review of f613c98; same hazard for both `cache_gen` and
    /// `region_defs_gen`).
    fn bumpGen(gen: *u32) void {
        gen.* +%= 1;
        if (gen.* == 0) gen.* = 1;
    }

    pub fn traceById(self: *const TraceState, id: u32) ?*Trace {
        // O(1) fast path via the id index; a hit is authoritative. A null slot or
        // out-of-range id falls back to the linear scan — that covers hand-built
        // test traces appended straight to `cache` (never indexed) and any
        // fail-soft grow-OOM at commit. For real retired ids both paths miss.
        if (id < self.trace_by_id.items.len) {
            if (self.trace_by_id.items[id]) |t| return t;
        }
        for (self.cache.items) |c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// A frame of the executor value scratch: where `valuesRelease` must rewind
    /// to. Take it BEFORE the matching `valuesPush`, release it after the last
    /// read of the pushed slice — the release ends the frame's lifetime, so a
    /// `defer` must sit in a scope that outlives every use of the buffer, not in
    /// the block that happens to acquire it.
    /// A mark records the chunk and the OFFSET INTO IT, not the free slice
    /// itself. Storing the slice looks cheaper and is wrong at the base: the
    /// first mark of a session is taken before any chunk exists, so its free
    /// slice is empty, and releasing to it left `values_free` empty even though
    /// chunk 0 was by then allocated and idle. Every subsequent push then missed
    /// the fast path and took the chunk-acquiring one — the cold path ran once
    /// per trace entry (0.65% of scimark-fft, ~45M instructions) and the stack
    /// ping-ponged between two chunks forever. An offset reconstructs correctly
    /// from a base mark, because offset 0 of chunk 0 is the whole chunk.
    pub const ValuesMark = struct { cur: u32, used: u32 };

    /// Slots per scratch chunk (64 KiB at 16 B/`Value`). A frame bigger than
    /// this gets its own exactly-sized chunk, so this is a packing knob only —
    /// no correctness invariant rests on it, and in particular it need not track
    /// `config.maxrecord`.
    const values_chunk_slots: usize = 4096;

    pub fn valuesMark(self: *const TraceState) ValuesMark {
        return .{ .cur = self.values_cur, .used = self.valuesUsed() };
    }

    /// Rewind to `mark`, ending the lifetime of every frame pushed after it.
    /// `cur` has to travel with the offset: a push that spilled into a later
    /// chunk must hand that chunk back, or each release would strand one.
    pub fn valuesRelease(self: *TraceState, mark: ValuesMark) void {
        self.values_cur = mark.cur;
        self.values_free = if (mark.cur < self.values_chunks.items.len)
            self.values_chunks.items[mark.cur][mark.used..]
        else
            &.{};
    }

    /// How far into the current chunk the deepest live frame reaches. Derived
    /// from `values_free` rather than stored, so the push fast path writes one
    /// field instead of two.
    fn valuesUsed(self: *const TraceState) u32 {
        if (self.values_cur >= self.values_chunks.items.len) return 0;
        return @intCast(self.values_chunks.items[self.values_cur].len - self.values_free.len);
    }

    /// Carve a fresh `n`-slot frame for `irinterp.execute`'s `values`. The
    /// returned slice stays valid until the matching `valuesRelease`, INCLUDING
    /// across nested pushes — that stability is the whole point of the segmented
    /// backing (see `values_chunks`). Contents are undefined; the executor
    /// writes every `Ref` it reads.
    pub inline fn valuesPush(self: *TraceState, n: usize) ![]Value {
        // Fits in what is left of the chunk we are already carving from. Also
        // the `n == 0` case (a trace with no instructions), which takes nothing.
        // Split hot/cold: this arm is taken on essentially every trace entry and
        // wants to inline into the dispatcher, while the chunk-acquiring arm
        // below runs a handful of times per process and carries the fallible
        // allocation. Folding them into one body left the whole thing outlined
        // and cost ~1% of scimark-fft in call overhead on the native path — the
        // path that does not even use the buffer.
        if (self.values_free.len >= n) {
            const out = self.values_free[0..n];
            self.values_free = self.values_free[n..];
            return out;
        }
        return self.valuesPushNewChunk(n);
    }

    fn valuesPushNewChunk(self: *TraceState, n: usize) ![]Value {
        @branchHint(.cold);
        // Take the NEXT chunk whole rather than straddling. By the
        // LIFO discipline every chunk from here up holds no live frame, so an
        // undersized one may be freed and replaced outright. Nothing below
        // mutates `values_cur`/`values_free` until all fallible work has
        // succeeded, so a failed push leaves the stack exactly as it found it
        // (the callers absorb the error by declining the entry).
        const next: u32 = if (self.values_chunks.items.len == 0) 0 else self.values_cur + 1;
        if (next == self.values_chunks.items.len) {
            const c = try self.gpa.alloc(Value, @max(n, values_chunk_slots));
            errdefer self.gpa.free(c);
            try self.values_chunks.append(self.gpa, c);
        } else if (self.values_chunks.items[next].len < n) {
            const c = try self.gpa.alloc(Value, n);
            self.gpa.free(self.values_chunks.items[next]);
            self.values_chunks.items[next] = c;
        }
        self.values_cur = next;
        const chunk = self.values_chunks.items[next];
        self.values_free = chunk[n..];
        return chunk[0..n];
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
    pub inline fn onSideExit(self: *TraceState, t: *Trace, completed: usize, charge_kind: ChargeKind) void {
        self.accountTraceRun(t, completed);
        if (charge_kind == .entry_refusal) {
            accountCandidateCharge(t, charge_kind);
            return;
        }
        if (self.accountRegionProfit(null, 0, .deferred)) {
            accountCandidateCharge(t, charge_kind);
            return;
        }
        // Gate-fix arc (2026-08-12): a synthetic steering charge fired while a
        // live QUALIFIED activation's footprint contains `t`'s anchor is an
        // intra-complex transition — the region window/close verdicts own its
        // profitability, exactly as for keyed member receipts. Without this the
        // fused dispatcher's own zero-progress charges (`onSideExit(ramp, 0)`,
        // `onSideExit(seed, 0)`) re-condemn the complex through the legacy
        // machine (measured on nsieve: 83,940 `completed=0` strikes/run on the
        // scan anchor, all from these sites, gating the anchor the region
        // machine had just qualified). Consumed-as-barren: a sustained streak
        // still strikes (`noteBarrenConsumed`, codex BLOCKER 2).
        if (self.qualifiedActiveMember(t.anchor.proto, t.anchor.pc)) |m| {
            accountCandidateCharge(t, charge_kind);
            self.noteBarrenConsumed(m.key, m.accum);
            return;
        }
        self.accountLegacyThrash(t, completed, std.math.maxInt(u32), charge_kind);
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
        charge_kind: ChargeKind,
    ) void {
        self.accountTraceRun(t, completed);
        if (charge_kind == .entry_refusal) {
            accountCandidateCharge(t, charge_kind);
            return;
        }
        // Doc 38 yield gate: every ENTERED receipt that ended at a while-loop-
        // done guard feeds the per-anchor trip accumulator — regardless of
        // which profitability machine (region or legacy) consumes the receipt
        // below, because the turnstile cost being measured (entry + seam
        // re-entry per 0–2-trip completion) is real either way.
        if (exit_instr < t.instrs.len and isWhileLoopDoneGuardIndex(t, exit_instr)) {
            self.noteWhileYield(t.anchor, completed);
        }
        const key: ?ExitKey = if (exit_instr < t.instrs.len)
            .{ .trace_id = t.id, .exit_instr = exit_instr }
        else
            null;
        // A-vii-c.1: region-first, then legacy iff unconsumed. The two verdicts can
        // only ever touch the same anchor when this receipt's own region closed and
        // flushed against an owner that happens to be `t.anchor`; applying the
        // receipt-local verdict last keeps the most recent evidence authoritative.
        if (!self.accountRegionProfit(key, region_work, dest)) {
            self.accountLegacyThrash(t, completed, exit_instr, charge_kind);
        } else {
            accountCandidateCharge(t, charge_kind);
        }
    }

    /// Doc 38 glue-sibling eligibility (see `Config.while_glue_max_avg`): may
    /// this anchor's while-loop-done exit accrue side-trace hotness (and so
    /// grow the cond-false glue sibling)? Deterministic — reads the
    /// `while_yield` probe accumulator: requires a minimum sample of 8
    /// entries in the current window AND an observed average strictly below
    /// the glue ceiling. Consulted by the dispatch loop's hot-exit counting.
    pub fn whileDoneHotnessEligible(self: *const TraceState, anchor: AnchorKey) bool {
        const wy = self.while_yield.get(anchor) orelse return false;
        if (wy.entries < 8) return false;
        return wy.iters < wy.entries *| self.config.while_glue_max_avg;
    }

    /// Doc 38 yield gate: remove `anchor`'s dispatch gate UNLESS it is a
    /// `.low_trip_while` yield gate — those are cleared only by
    /// `noteWhileYield` on a genuinely high-trip completion, because the
    /// receipts reaching the ordinary clear-on-productive paths (1–2-trip
    /// while completions) are precisely the evidence the yield gate exists to
    /// act on. Every other reason keeps its doc 31 D2 clear semantics.
    fn clearDispatchGate(self: *TraceState, anchor: AnchorKey) void {
        // Single-hash form (getEntry + removeByPtr, not getPtr + remove):
        // this runs on every productive receipt, and the extra hash of the
        // two-op form was a measured ~2% of a scimark-lu run.
        const e = self.gate.getEntry(anchor) orelse return;
        if (e.value_ptr.reason == .low_trip_while) return;
        self.gate.removeByPtr(e.key_ptr);
    }

    /// Doc 38 yield gate: account one while-loop-done ENTRY receipt
    /// (`completed` = trips this entry ran; 0 for a zero-trip completion —
    /// the top-of-trace condition guard observed "done" before any body ran).
    /// Rationale: a while completion at ANY trip count is productive-shaped,
    /// so neither the legacy strike machine nor the region machine can see the
    /// per-entry runtime turnstile (entry + seam re-entry; our exits are not
    /// patched branches) that makes a 0–2-trip while NET SLOWER on the trace
    /// tier than on tier-0 — fft_bitreverse pays it 25.5M times per run at
    /// ~1.5 trips average, a measured +17% wall regression. This is the
    /// LuaJIT-shape-free analog of the demoted `min_trip_entry` config: gate
    /// on OBSERVED trips, not a predicted minimum. Pure deterministic
    /// counters (mahina determinism): a `while_yield_window`-entry probe per
    /// anchor; average below `while_yield_min_avg` ⇒ dispatch gate with the
    /// standard doubling cooldown; `max_strikes` abandons the anchor to
    /// tier-0 for good. Recovery is probe-based, not per-receipt: after the
    /// cooldown the anchor free-runs one more window, and a probe whose
    /// average clears the bar simply never re-gates. (A per-receipt "one
    /// high-trip completion lifts the gate" rule was tried first and
    /// oscillated: chain-driven entries — driveChain does not consult the
    /// dispatch gate — kept delivering occasional 6-trip completions that
    /// un-gated an anchor still averaging <1 trip/entry, measured live on
    /// fft_bitreverse pc=55: `entries=64 iters=58 -> gate` then
    /// `completed=6 -> ungate`, forever.)
    fn noteWhileYield(self: *TraceState, anchor: AnchorKey, completed: usize) void {
        const min_avg = self.config.while_yield_min_avg;
        if (min_avg == 0) return; // knob disabled
        const gop = self.while_yield.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{ .entries = 0, .iters = 0 };
        gop.value_ptr.entries +|= 1;
        gop.value_ptr.iters +|= @as(u32, @intCast(@min(completed, std.math.maxInt(u32))));
        if (gop.value_ptr.entries >= self.config.while_yield_window) {
            const entries = gop.value_ptr.entries;
            const iters = gop.value_ptr.iters;
            gop.value_ptr.* = .{ .entries = 0, .iters = 0 };
            if (iters < entries *| min_avg) {
                self.dbg("while-yield: anchor pc={d} probe entries={d} iters={d} (< {d}) -> gate", .{ anchor.pc, entries, iters, entries *| min_avg });
                self.gateAnchor(anchor, .low_trip_while);
            }
        }
    }

    /// The pre-A-vii-c per-trace profitability machine, verbatim — applied to every
    /// receipt the region machine did not consume (see `onSideExit`). A useful segment
    /// (`completed >= min_useful`) clears the anchor's penalty and gate; a
    /// low-yield one strikes, and at `max_penalty` the anchor is gated off with
    /// the doubling cooldown (`gateAnchor`). A receipt the region machine DID
    /// consume never reaches this: the region window flush owns that verdict,
    /// keyed on the owner anchor (`flushRegionWindow`).
    /// `exit_instr` is the failing IR exit when the caller knows it (a real
    /// deopt receipt), `maxInt(u32)` otherwise. It feeds the Option-A rule
    /// below and nothing else.
    inline fn accountLegacyThrash(self: *TraceState, t: *Trace, completed: usize, exit_instr: u32, charge_kind: ChargeKind) void {
        accountCandidateCharge(t, charge_kind);
        if (charge_kind == .entry_refusal) return;
        const key = t.anchor;
        // Pall's model (hotexit arc): a PRODUCTIVE segment is never a strike,
        // however short. LuaJIT has no `min_useful` analog at all — a trace that
        // commits 2 iterations and exits is fine; its hot exit just spawns a side
        // trace within `hotexit` takes and coverage grows until exits are rare
        // (`trace_hotside`, lj_trace.c:798; the only backoff machine,
        // `penalty_pc`, fires exclusively on recording ABORTS). Our per-segment
        // strike machine was the non-Pall invention, and it starved exactly the
        // workloads the side-trace/chaining machinery exists for: nsieve's scan
        // loop at small sieve sizes has prime-gap segments of 1–5 iterations —
        // every receipt struck, the anchor gated within 8 entries, and a gated
        // anchor gets no dispatch, so exit hotness never accrued (N=3: 38 traced
        // vs 140k interpreted iterations, 88% of the run tier-0 WITH a trace).
        //
        // Doc 31 D2 (clear-on-productive): the CLEAR threshold, too, was
        // non-Pall — clearing only at `completed >= min_useful` let isolated
        // zero-progress receipts at *designed* exits ratchet the penalty
        // monotonically on loops whose instances physically yield fewer than
        // `min_useful` iterations (str_gmatch: 7 tokens/instance, exhaustion
        // and guard_gc zeros ratcheted to a gate the productive receipts
        // could never un-earn — 2.6% native residency on a healthy trace).
        // ANY productive receipt now clears the penalty and the dispatch
        // gate. Every real turnstile still gates: pathological anchors
        // (gc_stress admission failure, corrupted iterator state, type-flip
        // loops) produce CONSECUTIVE zeros with no productive receipt in
        // between, and reach `max_penalty` exactly as before. Never clears
        // `record_gate` — productive dispatch is not evidence about
        // recording (doc 31 §4).
        //
        // What remains below is the zero-progress half only: an entry that
        // commits NOTHING is pure turnstile cost (our exits re-enter the runtime;
        // LuaJIT's are patched branches), so repeated zero-yield entries still
        // gate — with Option-A headroom for shape-guard exits so the side-trace
        // machinery wins the race while capacity remains.
        if (completed > 0) {
            _ = self.penalty.remove(key);
            self.clearDispatchGate(key);
            return;
        }
        // Doc 38: a zero-COMPLETION loop-done receipt (a while whose top-of-
        // trace condition guard observed "done" before any body ran) is a
        // completed empty loop — evidence of NEITHER productivity NOR thrash.
        // It must not strike (task #62's completions-are-not-thrash, extended
        // to the legacy machine) and must not clear (it did no work to earn
        // one). Without this, fft_bitreverse's ~50% zero-trip instances
        // alternate strike/clear forever — penalty churn on a healthy anchor.
        if (exit_instr != std.math.maxInt(u32) and exit_instr < t.instrs.len and
            isAnyLoopDoneGuardIndex(t, exit_instr)) return;
        const gop = self.penalty.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        // Option A: give a real side-exit counter enough deterministic headroom to
        // reach `hotexit`, but retain the finite legacy gate. Without direct
        // native exit-branch stitching, permanently exempting zero-progress guard
        // exits creates an enter/exit runtime turnstile on variable loop shapes.
        const side_headroom = exit_instr != std.math.maxInt(u32) and
            exit_instr < t.instrs.len and
            isSideExitGuardOp(t.instrs[exit_instr].op) and
            self.countTracesAt(key) < self.config.max_traces_per_anchor;
        const limit = if (side_headroom)
            self.config.max_penalty +| self.config.hotexit
        else
            self.config.max_penalty;
        if (gop.value_ptr.* >= limit) {
            self.dbg("legacy-strike: anchor pc={d} completed={d} penalty={d} -> gate", .{ key.pc, completed, gop.value_ptr.* });
            // Doc 38 unroll-first policy: thrash-gating an anchor whose trace
            // unrolled an inner while is runtime proof that sibling coverage
            // cannot absorb the trip variance — the second evidence source for
            // the `recWhileLink` decomposition flip (the first is recording
            // aborts of unrolling roots, in `abort`).
            if (t.unrolled_while) {
                if (self.unroll_fail.getOrPut(self.gpa, key)) |ugop| {
                    if (!ugop.found_existing) ugop.value_ptr.* = 0;
                    ugop.value_ptr.* +|= 1;
                    self.dbg("unroll-fail (thrash gate): anchor pc={d} count={d}", .{ key.pc, ugop.value_ptr.* });
                } else |_| {}
            }
            self.gateAnchor(key, .legacy_thrash);
        } else {
            self.dbg("legacy-strike: anchor pc={d} completed={d} penalty={d}/{d}", .{ key.pc, completed, gop.value_ptr.*, limit });
        }
    }

    /// A-vii-c.1: the selection receipt for a ledger row whose REGION receipt was
    /// already accounted at the top of `replayLedger`'s per-entry loop. This is
    /// deliberately not `onSideExit`: that wrapper would (a) send a second,
    /// null-keyed region receipt for a row the region machine has already seen and
    /// (b) unconditionally apply the legacy verdict, so a row the region window
    /// consumed would be charged by BOTH machines. The row's own `region_consumed`
    /// is the boundary, exactly as at `onSideExitReceipt`.
    /// `exit_instr`: the row's own exit index for `.deopt` rows (Option-A
    /// evidence), `maxInt(u32)` for rows with no failing-guard identity
    /// (loop-done, prologue-fail).
    inline fn accountLedgerRow(self: *TraceState, t: *Trace, completed: usize, exit_instr: u32, region_consumed: bool, charge_kind: ChargeKind) void {
        self.accountTraceRun(t, completed);
        if (!region_consumed) {
            self.accountLegacyThrash(t, completed, exit_instr, charge_kind);
        } else {
            accountCandidateCharge(t, charge_kind);
        }
    }

    inline fn accountCandidateCharge(t: *Trace, charge_kind: ChargeKind) void {
        switch (charge_kind) {
            .entered => t.consec_refusals = 0,
            .entry_refusal => t.consec_refusals +|= 1,
        }
    }

    /// Bulk image of sequential frozen-region ledger rows for one trace. Native
    /// summaries retain exactly the two selection-domain aggregates those calls
    /// mutate: total executed work and the number of qualifying rows. Because a
    /// promoted set is bound to a consumed frozen region, the legacy
    /// penalty/strike half is unreachable here; accepting an unconsumed image
    /// would be inexact (row ordering is intentionally not present in the ABI),
    /// so it is a release contract failure.
    fn accountLedgerRowsBulk(
        self: *TraceState,
        t: *Trace,
        completed: usize,
        qualifying_rows: u64,
        region_consumed: bool,
    ) void {
        if (!region_consumed)
            @panic("driveSilentBurst: bulk selection row was not region-consumed");
        accountCandidateCharge(t, .entered);
        if (self.config.coverage) {
            if (completed > 0) self.noteTraceIters(t.anchor, completed);
            // Iteration totals remain exact. Per-trace TSC attribution cannot be:
            // the promoted set executed as one uninterrupted native span, so
            // there is no per-member timestamp boundary to reconstruct here.
            // Charge the drain-time span once per summarized member as diagnostic
            // attribution only, matching doc 17's explicit redefinition.
            const now = readCycles();
            self.noteTracedCycles(t.anchor, cycleDelta(now, self.last_hop_tsc));
            self.last_hop_tsc = now;
        }
        t.hit_count +|= qualifying_rows;
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
    pub fn flushRegionWindow(self: *TraceState, key: RegionKey, work: u64) void {
        if (work == 0) return;
        self.region_profit_flushes +|= 1;
        self.region_profit_flushed_work +|= work;
        const def = self.region_defs.get(key.region_id) orelse return;
        const owner = def.owner;
        if (work >= self.config.min_useful) {
            _ = self.penalty.remove(owner);
            self.clearDispatchGate(owner);
            return;
        }
        // Freeze-after-qualify (task #70): any low-yield verdict unfreezes the
        // activation and restarts the useful-window streak — a decaying region
        // must fall back to full per-row pricing immediately.
        if (self.region_profit.getPtr(key)) |accum| {
            accum.frozen = false;
            accum.useful_streak = 0;
        }
        // B-3d.1 (doc 17 §B3.17 R2, both round-2 reviewers confirmed the hole):
        // an unfreeze while this region owns a live promotion previously left the
        // silent patches ARMED with their frozen precondition gone — the next
        // same-region native call would fire a silent epilogue and the next drain
        // would hit the frozen-accumulator release panic. Demote in the same act
        // (queued mid-walk, immediate at depth 0 — this can fire per ledger row
        // inside a walk, including from the drained burst's own barren-exhaustion
        // path). Placed here rather than at any single caller so EVERY unfreeze
        // entry point is covered.
        self.demotePromotionsForRegionReason(key, .unfreeze);
        const gop = self.penalty.getOrPut(self.gpa, owner) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.max_penalty) {
            self.dbg("disarm-reason: window gate-strike owner pc={d} work={d}", .{ owner.pc, work });
            self.gateAnchor(owner, .region_decay);
            // B-2b / §B.6: only this explicit region-owner condemnation event
            // deletes logical provenance. Ordinary temporary gates preserve it.
            self.condemnProvenanceEdgesAt(owner);
            self.disarmAllLinks();
        } else {
            self.dbg("window-strike: owner pc={d} work={d} penalty={d}/{d}", .{ owner.pc, work, gop.value_ptr.*, self.config.max_penalty });
        }
    }

    pub fn closeRegion(self: *TraceState, key: RegionKey) void {
        const accum = self.region_profit.get(key) orelse return;
        const remainder = accum.outer_traversals - accum.window_base;
        self.flushRegionWindow(key, remainder);
        // B-3a hook: physical exit patches owned by this activation must be restored
        // before its accumulator disappears. Promotion storage arrives in B-3b.
        self.demotePromotionsForRegion(key);
        self.resetPromotionCandidate();
        _ = self.region_profit.remove(key);
        self.refreshObserverFast();
    }

    fn demotePromotionsForRegion(self: *TraceState, key: RegionKey) void {
        self.demotePromotionsForRegionReason(key, .region_close);
    }

    /// Backwards over `promoted_sets` because `demoteSetReason` swapRemoves at
    /// depth 0 (mid-walk it queues instead) — forward iteration would skip entries.
    fn demotePromotionsForRegionReason(self: *TraceState, key: RegionKey, reason: DemotionReason) void {
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            if (std.meta.eql(self.promoted_sets.items[i].region_key, key))
                self.demoteSetReason(i, reason);
        }
    }

    /// B-3a hook at every native-call origin. B-3b performs the conservative global
    /// activation sweep here, demoting every live promotion whose RegionKey differs
    /// from the current active key before any patched code can run.
    pub fn prepareNativeEntry(self: *TraceState) void {
        // This is on every native entry; preserve the empty-registry common case
        // as one length branch before resolving activation state.
        if (self.promoted_sets.items.len == 0) return;
        const active = if (self.region_context) |ctx| self.activeRegionFor(ctx.call_seq) else null;
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            if (active == null or !std.meta.eql(self.promoted_sets.items[i].region_key, active.?))
                self.demoteSetReason(i, .activation);
        }
    }

    /// One authoritative staging image for every native-call origin. The barren
    /// bound is absolute: `cur_zero_run` begins at the active activation's current
    /// streak and native compares it directly with `max_barren_run`.
    pub fn silentStaging(self: *TraceState) nativegen.SilentStaging {
        // Nothing is promoted ⇒ no patch targets a silent epilogue ⇒ no native code
        // can read any of these fields. Resolving the activation here would put an
        // `activeRegionFor` walk + a `region_profit` hashmap lookup on EVERY native
        // call, which measured +10% on pi_leibniz (a workload that promotes nothing
        // at all: 0 bursts, 0 promotions) — the same per-call-cost failure mode as
        // the A-vii-e.1 observer scan. Stage zeros behind one predictable branch;
        // the real staging cost is paid only while patched code exists, where it is
        // amortized across thousands of silent transitions.
        if (self.promoted_sets.items.len == 0) return .{};
        var zero_run: u64 = 0;
        if (self.region_context) |ctx| {
            if (self.activeRegionFor(ctx.call_seq)) |key| {
                if (self.region_profit.get(key)) |accum| zero_run = accum.barren_run;
            }
        }
        return .{
            .silent_budget = self.config.silent_budget,
            .barren_budget = self.config.max_barren_run,
            .cur_zero_run = zero_run,
        };
    }

    fn freeObserverFast(self: *TraceState) void {
        // Every `region_profit` mutation funnels through here (refreshObserverFast
        // and resetRegionProfit both call it) — the cached `accum` pointer in
        // `act_cache` must not survive any of them (see `act_cache_*`).
        self.act_cache_gen = 0;
        self.act_cache = null;
        // The inline cache borrows a span's `words`, so it dies with the owner —
        // unconditionally, even when there is nothing to free (a null
        // `observer_fast` still means "no valid hot span").
        self.observer_hot = .{};
        if (self.observer_fast) |f| {
            for (f.spans) |s| self.gpa.free(s.words);
            self.gpa.free(f.spans);
            self.observer_fast = null;
        }
    }

    /// A-vii-e.1: rebuild the observer fast path from the current single
    /// accumulator (null it otherwise). Cold path — runs only when the
    /// `region_profit` map mutates. See `ObserverFast` for the contract.
    fn refreshObserverFast(self: *TraceState) void {
        self.freeObserverFast();
        if (self.region_profit.count() != 1) return;
        var it = self.region_profit.iterator();
        const entry = it.next().?;
        const def = self.region_defs.get(entry.key_ptr.region_id) orelse return; // slow path closes it
        const points = def.member_points; // sorted by (proto_id, source_pc), deduped
        if (points.len == 0) return;
        // Group by consecutive proto_id runs. Discovery publishes member_points
        // sorted by (proto_id, source_pc), but hand-built test defs may not be —
        // so take min/max per run instead of first/last, and let the probe below
        // check every span (a non-contiguous proto grouping just yields more
        // spans, never a wrong verdict).
        var nspans: usize = 1;
        for (points[1..], points[0 .. points.len - 1]) |cur, prev| {
            if (cur.proto_id != prev.proto_id) nspans += 1;
        }
        const spans = self.gpa.alloc(ObserverSpan, nspans) catch return;
        var filled: usize = 0;
        var i: usize = 0;
        while (i < points.len) {
            const pid = points[i].proto_id;
            var j = i;
            var base = points[i].source_pc;
            var max_pc = base;
            while (j < points.len and points[j].proto_id == pid) : (j += 1) {
                base = @min(base, points[j].source_pc);
                max_pc = @max(max_pc, points[j].source_pc);
            }
            // Size the bitset in u64 (codex e.1 review, MAJOR): `(limit - base) + 63`
            // in u32 overflows for a near-maxInt(u32) pc range, and even a
            // non-overflowing pathological range (hand-built defs; real member pcs
            // are bounded by proto code length) would allocate an absurd bitset.
            // Cap the per-proto range; over the cap (or at the u32 wrap point) the
            // cache stays null and the slow path runs — same verdicts either way.
            const range: u64 = @as(u64, max_pc) - base + 1;
            const observer_span_max_range: u64 = 1 << 22; // 4M pcs → 512 KiB bitset, far above any real proto
            if (range > observer_span_max_range or max_pc == std.math.maxInt(u32)) {
                for (spans[0..filled]) |s| self.gpa.free(s.words);
                self.gpa.free(spans);
                return;
            }
            const limit = max_pc + 1;
            const nwords: usize = @intCast((range + 63) / 64);
            const words = self.gpa.alloc(u64, nwords) catch {
                for (spans[0..filled]) |s| self.gpa.free(s.words);
                self.gpa.free(spans);
                return;
            };
            @memset(words, 0);
            for (points[i..j]) |pp| {
                const off = pp.source_pc - base;
                words[off >> 6] |= @as(u64, 1) << @intCast(off & 63);
            }
            spans[filled] = .{ .proto_id = pid, .base_pc = base, .limit_pc = limit, .words = words };
            filled += 1;
            i = j;
        }
        self.observer_fast = .{
            .key = entry.key_ptr.*,
            .root_frame_depth = entry.value_ptr.root_frame_depth,
            .root_call_seq = entry.value_ptr.root_call_seq,
            .spans = spans,
        };
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

    pub fn openRegion(self: *TraceState, id: RegionId, ctx: RegionContext) ?RegionKey {
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
        if (collision) |old| {
            self.dbg("close-reason: openRegion same-owner replacement rid={d} -> rid={d}", .{ @intFromEnum(old.region_id), @intFromEnum(id) });
            self.closeRegion(old);
        }

        const key: RegionKey = .{ .region_id = id, .activation = ctx.call_seq };
        // Codex-flagged BLOCKER: the pinned stdlib's `getOrPut` calls
        // `growIfNeeded(1)` BEFORE the lookup, so it can reallocate the map even
        // when `found_existing` — and the `found_existing` path below skips
        // `refreshObserverFast`, which is what normally invalidates `act_cache`.
        // A cached `*RegionAccum` would then dangle into freed map storage while
        // its generation key still matches. Invalidate unconditionally before any
        // potentially-growing `getOrPut`.
        self.act_cache_gen = 0;
        self.act_cache = null;
        const gop = self.region_profit.getOrPut(self.gpa, key) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{
            .root_frame_depth = ctx.depth,
            .root_call_seq = ctx.call_seq,
        };
        self.dbg("openRegion: rid={d} seq={d} found_existing={}", .{ @intFromEnum(id), ctx.call_seq, gop.found_existing });

        var count: usize = 0;
        var check = self.region_profit.keyIterator();
        while (check.next()) |live| {
            if (live.activation != ctx.call_seq) continue;
            const live_def = self.region_defs.get(live.region_id) orelse continue;
            if (sameAnchor(live_def.owner, def.owner)) count += 1;
        }
        if (count > 1) @panic("region_profit cardinality violated after replacement");
        // Rebuild the observer cache only when the map actually mutated. The
        // common steady-state call here is `applyDestination` re-selecting the
        // ALREADY-open region (found_existing, no collision) — one per fused
        // chain receipt — and unconditionally freeing + reallocating the bitset
        // spans (and killing the e.2 inline hot cache) measured 9.6% of nsieve
        // wall time. A no-op open leaves the cache exactly as valid as it was.
        if (collision != null or !gop.found_existing) self.refreshObserverFast();
        return key;
    }

    pub fn invalidateRegion(self: *TraceState, id: RegionId) void {
        self.resetPromotionCandidate();
        self.dbg("region: invalidate id={d} (runtime tombstone)", .{@intFromEnum(id)});
        if (self.region_defs.getPtr(id)) |def| {
            def.armable = false;
            def.tombstoned = true; // fail-closed: recomputation must never re-arm
            self.demoteSetsForRegionDefsMutation();
            bumpGen(&self.region_defs_gen); // invalidate Trace.region_memo_*
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
        self.dbg("disarm-reason: region invalidate id={d}", .{@intFromEnum(id)});
        self.disarmAllLinks();
    }

    const RegionBridgeDecision = struct {
        child: *Trace,
        bridge: *const RegionBridgeDef,
    };

    /// Why a bridge validation ended, which the old `?RegionBridgeDecision` could
    /// not express: a null conflated "structurally disproved, region tombstoned,
    /// never ask again" with "proof held, the child's page just is not enterable
    /// from here". The caller needs them apart — the first is self-limiting
    /// because the tombstone stops the next attempt, the second is not, and the
    /// full arm pipeline was re-running on every terminal composite deopt
    /// forever against a child that could not become enterable within the
    /// activation.
    pub const RegionBridgeVerdict = union(enum) {
        /// Proof held; arm this child through this bridge.
        ok: RegionBridgeDecision,
        /// Structural disproof. The region has been tombstoned by this call.
        invalidated,
        /// The proof held; the child's page is not enterable. Nothing was
        /// tombstoned, and the region stays intact. Durable for this activation
        /// (see `stubEnterability`: a bridge child that is not
        /// dispatcher-selected may never compile, and a foreign-proto child
        /// never becomes enterable from here), so the caller memoizes rather
        /// than retrying every composite deopt.
        child_not_enterable,
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
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
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
    pub fn validateRegionBridge(
        self: *TraceState,
        id: RegionId,
        parent: *const Trace,
        exit_instr: u32,
    ) RegionBridgeVerdict {
        const def = self.region_defs.getPtr(id) orelse return .invalidated;
        if (!def.armable) return .invalidated;
        const edge = self.edge_cache.get(.{
            .trace_id = parent.id,
            .exit_instr = exit_instr,
        }) orelse {
            self.invalidateRegion(id);
            return .invalidated;
        };
        var bridge: ?*const RegionBridgeDef = null;
        for (def.bridges) |*candidate| {
            if (candidate.edge.eql(edge)) {
                if (bridge != null) {
                    self.invalidateRegion(id);
                    return .invalidated;
                }
                bridge = candidate;
            }
        }
        const b = bridge orelse {
            self.invalidateRegion(id);
            return .invalidated;
        };
        const child = self.resolveRegionBridgeChild(id, b) orelse {
            self.invalidateRegion(id);
            return .invalidated;
        };

        for (b.required_slots) |slot| {
            if (!nativegen.compositeBridgeEmitsSlot(parent, exit_instr, slot) and
                !slotInSortedSet(b.invariant_slots, slot))
            {
                self.invalidateRegion(id);
                return .invalidated;
            }
        }
        // B-iv.3 (doc 22 §B.5): a seeded child is bridgeable when its page is
        // stub-enterable (compiled + `ordinary_entry` + fresh episode ctx). NOT
        // a structural disproof — the region stays intact and is NOT tombstoned,
        // unlike every check above, because a later validation under a fresh
        // episode may succeed. (Pre-B-iv a seeded child was structurally barred,
        // which is what justified the invalidate.)
        if (child.inputs.len != 0 and
            self.stubEnterability(child, .ordinary, child.anchor.proto) != .ok)
        {
            return .child_not_enterable;
        }
        return .{ .ok = .{ .child = child, .bridge = b } };
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
    /// S⊆E∪invariants) and then publish through `armNativeLink(.region_bridge)`.
    ///
    /// Two failure classes, deliberately different (B-iv.3): a STRUCTURAL
    /// disproof tombstones the region and disarms, which is self-limiting
    /// because the tombstone stops the next attempt. A child whose page is not
    /// stub-enterable is NOT a disproof — the region stays intact — so it is
    /// memoized per (activation, `region_defs_gen`) instead, or the pipeline
    /// would re-run on every terminal composite deopt forever. `armNativeLink`'s
    /// release-`@panic` on a missing re-guarding entry stays as the backstop it
    /// was always described as; `validateRegionBridge` now answers that question
    /// itself, so the arm site no longer repeats the check.
    fn tryArmRegionBridge(self: *TraceState, failed: *Trace, exit_instr: u32) void {
        self.native_region_bridge_arm_attempts +|= 1;
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
        const decision = switch (self.validateRegionBridge(id, failed, exit_instr)) {
            .ok => |d| d,
            .invalidated => {
                self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (structural proof failed, region invalidated)", .{ failed.id, exit_instr, @intFromEnum(id) });
                return;
            },
            .child_not_enterable => {
                // Region intact — nothing was tombstoned, so nothing stops the
                // next composite deopt from re-running this whole pipeline
                // (classifyExit + def/profit probes + the structural proof, of
                // which validateRegionBridge alone measured 2.4% of nsieve N=5).
                // The decline is durable for this activation, so memoize it.
                // Stamped ONLY here: the earlier gates (no candidate, ambiguous,
                // not armable, no useful window yet) must NOT be memoized —
                // `useful_window_seen` latches WITHIN an activation, so caching
                // that decline would delay a legitimate arm by a whole activation.
                failed.bridge_decline_exit = exit_instr;
                failed.bridge_decline_gen = self.region_defs_gen;
                failed.bridge_decline_seq = ctx.call_seq;
                self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (child not stub-enterable — region intact, memoized for this activation)", .{ failed.id, exit_instr, @intFromEnum(id) });
                return;
            },
        };
        const child = decision.child;
        // The other half of the same durable decline: an unseeded child whose
        // page is not ready. `validateRegionBridge` scopes its enterability
        // clause to seeded children, so this is where a not-yet-compiled or
        // entry-less ordinary child lands. It used to return silently, which is
        // what let the pipeline re-run on every composite deopt — a bridge child
        // is frequently never dispatcher-selected (that non-selection is the
        // reason the bridge exists), so it can stay uncompiled for the life of
        // the program. Memoize it exactly like the seeded case; the activation
        // key means a later compile is still picked up on the next activation.
        if (self.stubEnterability(child, .ordinary, child.anchor.proto) != .ok) {
            failed.bridge_decline_exit = exit_instr;
            failed.bridge_decline_gen = self.region_defs_gen;
            failed.bridge_decline_seq = ctx.call_seq;
            self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (child id={d} page not enterable — memoized for this activation)", .{ failed.id, exit_instr, @intFromEnum(id), child.id });
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
                    l.armed_gen = self.region_defs_gen; // full pipeline just validated
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
        if (!t.isBridgeCandidate(exit_instr)) return;
        // Already armed as a bridge AND the defs generation is unchanged since
        // the arm pipeline last fully validated this link → nothing to do.
        // Without this, every burst whose terminal composite deopt drains
        // through here re-ran the WHOLE arm pipeline (classifyExit → def/profit
        // hash probes → the `validateRegionBridge` structural proof) only for
        // `armNativeLink` to supersede an identical arm — a measured seam cost
        // (validateRegionBridge alone was 2.4% of nsieve N=5). The gen stamp is
        // what makes the skip sound (codex review of f613c98): a discovery
        // rebuild can replace the region's `bridges`/membership under the SAME
        // region id without disarming the link (the stale-link sweep checks
        // region liveness only), so between rebuilds the proof is unchanged by
        // construction and after one the mismatched gen forces a full
        // re-validation (which also re-picks the child by current `hit_count`).
        for (self.armed_links.items) |l| {
            if (l.parent == t and l.slot_index == exit_instr and l.kind == .region_bridge and
                l.armed_gen == self.region_defs_gen) return;
        }
        // The negative twin of the skip above: this exit ran the full pipeline
        // and declined because the child's page was not stub-enterable, which is
        // durable for the activation. Strictly more conservative than the
        // positive memo — that one re-validates on `region_defs_gen` alone,
        // while this also requires the same activation, so it re-checks more
        // often. `region_defs_gen` covers rebuilds of bridges/membership;
        // `call_seq` covers the activation, hence the live episode identity;
        // and a child's `.unattempted -> .compiled` transition (which bumps no
        // generation) is retried at the next activation, a natural bound.
        if (t.bridge_decline_exit == exit_instr and t.bridge_decline_gen == self.region_defs_gen) {
            if (self.region_context) |rctx| {
                if (t.bridge_decline_seq == rctx.call_seq) return;
            }
        }
        self.tryArmRegionBridge(t, exit_instr);
    }

    /// A-vii-d.1 (review blocker 5): drain the at-most-one pending bridge-arm
    /// request `replayLedger` recorded for a terminal composite `.deopt` row.
    /// Arming (and its failure path, `invalidateRegion → disarmAllLinks`) must
    /// never run MID-ledger — it could erase the armed provenance later
    /// `.region_bridge` rows validate against — so the ledger drivers call this
    /// immediately after `replayLedger` returns, before acting on its directive.
    pub fn drainPendingBridgeArm(self: *TraceState, safe_to_arm: bool) void {
        const key = self.pending_bridge_arm orelse return;
        self.pending_bridge_arm = null;
        const t = self.traceById(key.trace_id) orelse return;
        self.maybeArmCompositeExit(t, key.exit_instr, safe_to_arm);
    }

    /// B-2b: republish disposable physical sibling arms from persistent hotexit
    /// provenance. Called only at dispatcher/runtime safe points. Observation
    /// windows retain the logical edges and retry when arming becomes safe again.
    pub fn drainProvenanceArms(self: *TraceState, safe_to_arm: bool) void {
        if (self.provenance_edges.items.len == 0) return;
        if (!safe_to_arm) return;
        // Event-driven gate: the drain runs at every dispatcher safe point, so
        // its edge×armed_links scan must be O(1) on the steady state (it was
        // 5.7% of nsieve-bit wall as an unconditional per-walk scan). A pass
        // that ends with nothing transiently deferred settles the cache; any
        // publication-invalidating event (new edge, disarm, retire, re-arm
        // displacement) re-opens it.
        // The episode half re-opens on a change of live episode identity only —
        // never merely because time passed, which is what made the old single
        // flag latch forever.
        if (!self.provenance_arms_pending) {
            if (!self.provenance_arms_episode_pending) return;
            if (self.liveEpisodeProto() == self.provenance_drain_episode) return;
        }
        var deferred = false;
        var episode_deferred = false;
        var i = self.provenance_edges.items.len;
        while (i > 0) {
            i -= 1;
            const edge = self.provenance_edges.items[i];
            const parent = self.traceById(edge.parent_id) orelse {
                _ = self.provenance_edges.swapRemove(i);
                continue;
            };
            const child = self.traceById(edge.child_id) orelse {
                _ = self.provenance_edges.swapRemove(i);
                continue;
            };
            const compiled = switch (parent.native) {
                .compiled => |*c| c,
                else => {
                    // Transient: the parent compiles lazily on dispatcher
                    // selection — keep the drain pending so this edge is
                    // re-evaluated once it has.
                    deferred = true;
                    self.dbg("provenance-drain: t={d} ei={d} decline: parent not compiled", .{ edge.parent_id, edge.exit_instr });
                    continue;
                },
            };
            if (edge.exit_instr >= parent.instrs.len or edge.exit_instr >= compiled.slots.len) {
                self.dbg("provenance-drain: t={d} ei={d} decline: slot bounds (slots={d})", .{ edge.parent_id, edge.exit_instr, compiled.slots.len });
                continue;
            }
            if (!exitIsPreEffect(parent, edge.exit_instr)) {
                self.dbg("provenance-drain: t={d} ei={d} decline: not pre-effect", .{ edge.parent_id, edge.exit_instr });
                continue;
            }
            if (parent.anchor.proto != child.anchor.proto or parent.anchor.pc != child.anchor.pc) continue;
            // B-iv.3 (doc 22 §B.5): seeded children are drainable — the arm
            // funnel's validator (`armNativeLink`) gates enterability via
            // `stubEnterable`, so no separate input filter here.
            if (parent.isBridgeCandidate(edge.exit_instr)) {
                self.dbg("provenance-drain: t={d} ei={d} decline: bridge candidate", .{ edge.parent_id, edge.exit_instr });
                continue;
            }
            if (isLoopDoneGuardIndex(parent, edge.exit_instr)) {
                self.dbg("provenance-drain: t={d} ei={d} decline: loop-done guard", .{ edge.parent_id, edge.exit_instr });
                continue;
            }
            // Compile on demand: compilation is LAZY (a trace compiles when the
            // dispatcher first enters it natively), and a provenance child may
            // never be dispatcher-selected at all — that non-selection is the
            // very reason the edge exists (nsieve's skip trace is entered only
            // through this arm). Waiting for `.compiled` would deadlock the
            // publication forever; `nativeFor` compiles idempotently and caches
            // `.unsupported`, which per §B.6(5) deletes the edge (never rescan
            // a permanently-unsupported child).
            if (self.nativeFor(child) == null) {
                self.dbg("provenance-drain: t={d} ei={d} decline: child t={d} native-unsupported (edge deleted)", .{ edge.parent_id, edge.exit_instr, edge.child_id });
                _ = self.provenance_edges.swapRemove(i);
                continue;
            }
            // Doc 40: the doc-39 v1 fusion exclusion (no arm into or out of a
            // PEELED trace — `armNativeLink`) is PERMANENT for these traces:
            // `peeled` is immutable on a committed trace, so the publish below
            // would refuse on every rescan. Charging that refusal to the
            // transient flag left the drain pending forever — re-scanned at
            // every dispatcher safe point, ~9% of scimark-fft wall once the
            // reverse peel gave these anchors real (peeled) children. Delete
            // the edge exactly like the unsupported-child case: it can never
            // arm while either trace lives, and lifting the exclusion (the
            // doc-40 open question) re-creates edges through new commits.
            // AFTER the `nativeFor` probe, deliberately: the drain's
            // compile-on-demand is what compiles a provenance child the
            // dispatcher never selects, and the runtime chain (`driveChain`
            // DOES follow peeled traces) needs that page — delete the arm
            // edge, keep the compilation.
            if (parent.peeled or child.peeled) {
                self.dbg("provenance-drain: t={d} ei={d} decline: peeled fusion exclusion (edge deleted)", .{ edge.parent_id, edge.exit_instr });
                _ = self.provenance_edges.swapRemove(i);
                continue;
            }
            var already_armed = false;
            for (self.armed_links.items) |link| {
                if (link.kind == .sibling_handoff and link.parent == parent and
                    link.slot_index == edge.exit_instr and link.child == child)
                {
                    already_armed = true;
                    break;
                }
            }
            if (already_armed) continue;
            // Classify the child's enterability BEFORE attempting to publish, so
            // the two reasons an arm can fail are not both charged to the
            // transient flag. `armNativeLink` gates on the same predicate, so a
            // decline here is exactly the publish that would have failed.
            switch (self.stubEnterability(child, .ordinary, child.anchor.proto)) {
                .ok => {},
                // Permanent for this compilation. (`.unsupported` was already
                // deleted by the `nativeFor` probe above, so this is a page
                // without an `ordinary_entry`.) Decline; do NOT defer — a
                // recompile or retire re-opens the drain through the
                // invalidating-event hooks, never by rescanning.
                .no_compilation, .not_compiled => {
                    self.dbg("provenance-drain: t={d} ei={d} decline: child t={d} not stub-enterable (permanent for this compilation)", .{ edge.parent_id, edge.exit_instr, edge.child_id });
                    continue;
                },
                // The child's page needs a different live episode. Not armable
                // now, not permanently declined — skip it, and re-open only when
                // the episode identity actually changes.
                .no_episode => {
                    episode_deferred = true;
                    self.dbg("provenance-drain: t={d} ei={d} defer: child t={d} needs another episode", .{ edge.parent_id, edge.exit_instr, edge.child_id });
                    continue;
                },
            }
            // A failed publish (OOM in the registry append) is transient.
            if (!self.publishSiblingArm(parent, edge.exit_instr, child)) deferred = true;
        }
        // Settle only when every edge is either armed or permanently declined
        // for its current compiled parent; permanent declines re-open via the
        // invalidating events above (retire/recompile), never by rescanning.
        self.provenance_arms_pending = deferred;
        self.provenance_arms_episode_pending = episode_deferred;
        self.provenance_drain_episode = self.liveEpisodeProto();
    }

    /// Capture complete-ledger verdicts before replay can defer/disarm the
    /// physical registry. The CAP-sized output is fixed storage: no allocation.
    pub fn captureProvenanceVerdicts(
        self: *const TraceState,
        entries: []const irinterp.LedgerEntry,
        initial_cum: usize,
        out: []ProvenanceVerdict,
    ) usize {
        if (self.provenance_edges.items.len == 0) return 0;
        // O(1) necessary precondition. Every edge below must clear
        // `hasArmedSiblingHandoff` — an ARMED handoff — so with an empty arm
        // registry no edge can produce a verdict and the whole per-native-call
        // scan (two `traceById` probes + a latch probe + a ledger walk, per
        // edge) is dead work. This is the steady state of any program whose
        // provenance edges outlive their arms: on scimark-lu essentially every
        // native entry reaches here with nothing armed.
        //
        // Deliberately keyed on the registry being EMPTY rather than on a
        // maintained count of `.sibling_handoff` records: emptiness is read
        // straight off the structure that already exists, so it cannot drift
        // out of sync with it. A maintained counter would be a new invariant
        // to keep exact across all four arm-removal paths, and if it ever
        // under-counted this early-out would silently skip LIVE edges.
        // Conservative in the safe direction: a non-empty registry holding no
        // sibling handoffs merely takes the slow path, as it does today.
        if (self.armed_links.items.len == 0) return 0;
        var n: usize = 0;
        for (self.provenance_edges.items) |edge| {
            const parent = self.traceById(edge.parent_id) orelse continue;
            const child = self.traceById(edge.child_id) orelse continue;
            if (!self.hasArmedSiblingHandoff(parent, edge.exit_instr, child)) continue;
            const action = provenanceEdgeVerdict(entries, initial_cum, edge) orelse continue;
            if (n == out.len)
                @panic("captureProvenanceVerdicts: verdict capacity exceeded");
            out[n] = .{
                .parent_id = edge.parent_id,
                .exit_instr = edge.exit_instr,
                .child_id = edge.child_id,
                .action = action,
            };
            n += 1;
        }
        return n;
    }

    /// The per-edge ledger walk of `captureProvenanceVerdicts`, split out so it
    /// can be pinned directly against hand-built ledgers without standing up
    /// armed physical links. Returns the edge's action, or null when the ledger
    /// holds no evidence either way.
    ///
    /// The straightforward form re-scanned the ledger tail once per matched row,
    /// which is O(rows²) per edge — a measured 2.3% of scimark-fft SELF time.
    /// This walks `k` BACKWARD maintaining the suffix cum-maximum instead, which
    /// is the same verdict by the following equivalence:
    ///
    ///   * the forward loop's final `progressed` is exactly
    ///     `local != 0 or max(cum over entries[k+1..]) > e.cum`;
    ///   * its strike arm could only fire for a row that never progressed — the
    ///     evolving `!progressed` qualifier was vacuously true throughout — so
    ///     the tail scan for a same-cum parent return (child row intervening,
    ///     hence `j >= k + 2`) is only needed in that no-progress case;
    ///   * verdicts accumulate order-independently and one productive row
    ///     decides the whole edge (`.reset` outranks `.strike`), so returning
    ///     at the first productive row is equivalent to scanning them all.
    pub fn provenanceEdgeVerdict(
        entries: []const irinterp.LedgerEntry,
        initial_cum: usize,
        edge: ProvenanceEdge,
    ) ?ProvenanceAction {
        if (entries.len < 2) return null;
        var saw_strike = false;
        var suffix_max: usize = entries[entries.len - 1].cum;
        var k: usize = entries.len - 1;
        while (k > 0) {
            k -= 1;
            // Invariant: `suffix_max` is the maximum cum over `entries[k+1..]`.
            row: {
                const e = entries[k];
                if (e.id != edge.parent_id or e.exit != edge.exit_instr or
                    e.kind != .deopt or e.reason != .normal or e.outcome != .normal or
                    entries[k + 1].id != edge.child_id)
                    break :row;
                const prior_cum: usize = if (k == 0) initial_cum else entries[k - 1].cum;
                const local = e.cum - prior_cum;
                if (local != 0 or suffix_max > e.cum) return .reset;
                var j = k + 2;
                while (j < entries.len) : (j += 1) {
                    if (entries[j].id == edge.parent_id and entries[j].cum == e.cum) {
                        saw_strike = true;
                        break;
                    }
                }
            }
            suffix_max = @max(suffix_max, entries[k].cum);
        }
        return if (saw_strike) .strike else null;
    }

    /// Apply captured verdicts only after replay and deferred global disarms.
    /// Retirement resets the exact physical arm through targeted P-E teardown.
    pub fn applyProvenanceVerdicts(self: *TraceState, verdicts: []const ProvenanceVerdict) void {
        for (verdicts) |verdict| {
            var edge_idx: ?usize = null;
            for (self.provenance_edges.items, 0..) |edge, i| {
                if (edge.parent_id == verdict.parent_id and edge.exit_instr == verdict.exit_instr and
                    edge.child_id == verdict.child_id)
                {
                    edge_idx = i;
                    break;
                }
            }
            const idx = edge_idx orelse continue;
            switch (verdict.action) {
                .reset => self.provenance_edges.items[idx].strikes = 0,
                .strike => {
                    const edge = &self.provenance_edges.items[idx];
                    edge.strikes +|= 1;
                    if (edge.strikes < self.config.max_edge_strikes) continue;
                    var link_idx = self.armed_links.items.len;
                    while (link_idx > 0) {
                        link_idx -= 1;
                        const link = self.armed_links.items[link_idx];
                        if (link.kind == .sibling_handoff and link.parent.id == edge.parent_id and
                            link.slot_index == edge.exit_instr and link.child.id == edge.child_id)
                        {
                            self.disarmLinkAt(link_idx);
                        }
                    }
                    _ = self.provenance_edges.swapRemove(idx);
                },
            }
        }
    }

    pub fn stageSilentSiblingProvenance(
        self: *TraceState,
        edge: PromotedEdge,
        followed: u64,
        productive: bool,
        returned_to_parent: bool,
    ) void {
        if (followed == 0 or edge.arm_kind != .sibling_handoff) return;
        for (self.provenance_edges.items) |prov| {
            if (prov.parent_id != edge.parent.id or prov.exit_instr != edge.exit or
                prov.child_id != edge.child.id) continue;
            if (self.silent_provenance_len == self.silent_provenance.len)
                @panic("stageSilentSiblingProvenance: evidence capacity exceeded");
            self.silent_provenance[self.silent_provenance_len] = .{
                .parent_id = prov.parent_id,
                .exit_instr = prov.exit_instr,
                .child_id = prov.child_id,
                .saw_productive = productive,
                .saw_return_without_progress = returned_to_parent and !productive,
            };
            self.silent_provenance_len += 1;
            return;
        }
    }

    pub fn stageSilentSuffixProvenance(
        self: *TraceState,
        entries: []const irinterp.LedgerEntry,
        initial_cum: usize,
    ) void {
        if (entries.len == 0) return;
        // Every suffix row is later than every silent-prefix firing. Reporting's
        // per-edge scan therefore treats any suffix progress as productive service
        // for every prefix sibling observation still under consideration.
        if (entries[entries.len - 1].cum > initial_cum) {
            for (self.silent_provenance[0..self.silent_provenance_len]) |*evidence|
                evidence.saw_productive = true;
        }
        var suffix: [PROVENANCE_VERDICT_CAP]ProvenanceVerdict = undefined;
        const suffix_len = self.captureProvenanceVerdicts(entries, initial_cum, &suffix);
        for (suffix[0..suffix_len]) |verdict| {
            var found = false;
            for (self.silent_provenance[0..self.silent_provenance_len]) |*evidence| {
                if (evidence.parent_id != verdict.parent_id or evidence.exit_instr != verdict.exit_instr or
                    evidence.child_id != verdict.child_id) continue;
                found = true;
                if (verdict.action == .reset) evidence.saw_productive = true else evidence.saw_return_without_progress = true;
                break;
            }
            if (!found) {
                if (self.silent_provenance_len == self.silent_provenance.len)
                    @panic("stageSilentSuffixProvenance: evidence capacity exceeded");
                self.silent_provenance[self.silent_provenance_len] = .{
                    .parent_id = verdict.parent_id,
                    .exit_instr = verdict.exit_instr,
                    .child_id = verdict.child_id,
                    .saw_productive = verdict.action == .reset,
                    .saw_return_without_progress = verdict.action == .strike,
                };
                self.silent_provenance_len += 1;
            }
        }
    }

    /// A-vii-d.1: apply a `disarmAllLinks` that was deferred because it fired
    /// mid-`replayLedger` walk (see `replay_walk_depth`). Every ledger DRIVER
    /// calls this immediately after the walk returns, BEFORE the pending
    /// bridge-arm drain (a disarm-then-re-arm re-validates all its gates;
    /// arm-then-disarm would silently erase the fresh arm) and before acting
    /// on the directive, so the disarm lands before any native re-entry.
    pub fn applyPendingDisarms(self: *TraceState) void {
        // B-3b.2 transaction order: restored reporting code and cleared metadata
        // must precede every deferred physical-slot disarm.
        while (self.pending_demote.items.len > 0) {
            const pending = self.pending_demote.pop().?;
            for (self.promoted_sets.items, 0..) |set, i| {
                if (set.id == pending.id) {
                    self.demoteSetReason(i, pending.reason);
                    break;
                }
            }
        }
        if (!self.pending_disarm_all) return;
        self.pending_disarm_all = false;
        // Fail-closed: a walk that struck the gate arms nothing this round —
        // drop any pending bridge-arm request rather than disarm-then-re-arm
        // into a complex the gate just condemned. It can re-arm on the next
        // composite observation, gates permitting.
        self.pending_bridge_arm = null;
        self.dbg("disarm-reason: pending walk-deferred gate strike", .{});
        self.disarmAllLinks();
    }

    fn chooseSource(self: *TraceState, candidates: []const RegionId, ctx: RegionContext) ?RegionKey {
        const active = self.activeRegionFor(ctx.call_seq);
        if (active) |a| {
            // A tombstoned (or vanished) def is positive evidence the region is
            // condemned — close its live accumulator immediately rather than let
            // it keep consuming receipts a re-open would refuse.
            const live = if (self.region_defs.get(a.region_id)) |d| d.armable else false;
            if (!live) {
                self.dbg("close-reason: chooseSource active rid={d} tombstoned", .{@intFromEnum(a.region_id)});
                self.closeRegion(a);
            } else {
                for (candidates) |id| if (id == a.region_id) return a;
                // An UNCLASSIFIED exit (empty candidate set) is "no information",
                // not "we left the region" — member traces routinely exit through
                // guards that are not registered structural edges (measured on
                // nsieve: the skip trace's zero-work bridge-cycle receipt, once
                // per traversal, so closing here capped every activation at ONE
                // traversal and turned every window flush into a low-yield gate
                // strike — the A-vii-e "flat wall-clock" in one line). Real
                // departures are owned by the tier-0 observer (non-member pc),
                // dropRegionActivation (frame death), and the tombstone check
                // above; only positive evidence of a transition INTO a different
                // region (non-empty candidates excluding the active one) closes
                // here.
                if (candidates.len == 0) return null;
                self.dbg("close-reason: chooseSource active rid={d} not in {d} candidates", .{ @intFromEnum(a.region_id), candidates.len });
                self.closeRegion(a);
            }
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
            self.dbg("close-reason: applyDestination rid={d} dest={s} candidates={d}", .{ @intFromEnum(source.region_id), @tagName(dest), candidates.len });
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
    /// **Returns whether this receipt was CONSUMED** — i.e. whether the region
    /// window machine has taken ownership of its profitability verdict. This is
    /// the A-vii-c.1 accounting boundary: a caller that also runs per-trace
    /// selection accounting applies the legacy per-trace gate
    /// (`accountLegacyThrash`) iff the region machine did NOT consume. Every
    /// trace-run receipt is therefore accounted by exactly one machine.
    ///
    /// Consumption (revised 2026-08-12 — the gate-fix arc): a receipt is
    /// consumed when it belongs to the LIVE activation, in either of two forms:
    ///   • **Nonzero work, classified or member-unclassified** — credited to the
    ///     accumulator and windows flushed. The unclassified half is new: the
    ///     edge cache is EPHEMERAL, so a member trace's real traversals used to
    ///     be dropped on a cache miss AND handed to the legacy machine as a
    ///     "short segment" strike (measured on nsieve: ~4k real-work receipts/run
    ///     lost this way).
    ///   • **Zero work from a member of a QUALIFIED activation**
    ///     (`useful_window_seen`) — an intra-region transition (a branchy
    ///     complex exits between members on every polarity flip by design), not
    ///     thrash. Before this rule the legacy machine priced every such
    ///     transition as a strike (measured on nsieve: 10,749 `completed=0`
    ///     strikes/run on the scan anchor vs 6,923 clears — the anchor gated
    ///     with exponential backoff, capping the fused complex at ~5% of scan
    ///     iterations; the whole July diagnosis, reintroduced through the
    ///     accounting boundary).
    ///
    /// Non-consumption still covers every shape the region machine cannot gate:
    /// a null key (synthetic scalar site), no live activation context, a
    /// non-member trace, an ambiguous/tombstoned candidate set, and — the
    /// A-vii-c review-blocker shape — zero-work receipts of an activation that
    /// has NOT yet produced a useful window (R2-1 keeps zero-work flushes
    /// silent, so an activation that never qualifies keeps full pre-flip legacy
    /// gating on its barren receipts).
    pub fn accountRegionProfit(self: *TraceState, key: ?ExitKey, work: usize, dest: RegionDestination) bool {
        const exit_key = key orelse return false;
        const ctx = self.region_context orelse return false;
        var consumed = false;
        const candidates = self.classifyExit(exit_key);
        if (candidates.len == 0 and self.region_profit.count() != 0)
            self.dbg("unclassified-exit: t={d} ei={d} work={d}", .{ exit_key.trace_id, exit_key.exit_instr, work });
        const selected = self.chooseSource(candidates, ctx);
        // Codex review (BLOCKER 1): destination processing must see the region
        // this receipt actually came FROM. For classified receipts that is
        // `selected`; for member-unclassified receipts (below) it is the live
        // activation — leaving it null there let a foreign `.known_trace`
        // destination open a SECOND accumulator at this call_seq without
        // closing the source (activeRegionFor then picks the lowest RegionId,
        // cross-crediting overlapping footprints).
        var effective = selected;
        if (selected) |source| {
            if (self.region_profit.getPtr(source)) |accum| {
                if (work != 0) {
                    consumed = true;
                    self.creditRegionWork(source, accum, work);
                } else if (accum.useful_window_seen) {
                    consumed = true;
                    self.noteBarrenConsumed(source, accum);
                }
            }
        } else if (candidates.len == 0) {
            // Unclassified receipt with a live activation: if the receipt's
            // trace anchors inside the activation's membership footprint, this
            // is an intra-region event the ephemeral edge cache merely failed
            // to classify — the region machine owns it (credit any work; barren
            // ones consumed once qualified, exactly as above).
            if (self.activeRegionFor(ctx.call_seq)) |a| {
                if (self.region_profit.getPtr(a)) |accum| {
                    if (self.regionMemberTraceAnchor(a.region_id, exit_key.trace_id)) {
                        effective = a;
                        if (work != 0) {
                            consumed = true;
                            self.creditRegionWork(a, accum, work);
                        } else if (accum.useful_window_seen) {
                            consumed = true;
                            self.noteBarrenConsumed(a, accum);
                        } else {
                            self.dbg("barren-unqualified: t={d} ei={d}", .{ exit_key.trace_id, exit_key.exit_instr });
                        }
                    } else {
                        self.dbg("barren-nonmember: t={d} ei={d}", .{ exit_key.trace_id, exit_key.exit_instr });
                    }
                }
            } else {
                self.dbg("barren-noactive: t={d} ei={d} work={d}", .{ exit_key.trace_id, exit_key.exit_instr, work });
            }
        }
        self.applyDestination(effective, dest, ctx);
        return consumed;
    }

    /// Credit `work` outer traversals to a live accumulator and flush every
    /// complete `min_useful` window through the authoritative gate machine,
    /// latching the activation's qualification bit. Factored out of
    /// `accountRegionProfit` so the classified and member-unclassified credit
    /// paths cannot drift. `flushRegionWindow` never mutates `region_profit`,
    /// so `accum` stays valid across the loop.
    // `inline`: called per credited ledger row from the frozen fast path —
    // perf annotate showed the call frame (push/pop) as a visible slice of its
    // self-time, and the frozen steady-state body is a handful of adds.
    inline fn creditRegionWork(self: *TraceState, key: RegionKey, accum: *RegionAccum, work: usize) void {
        accum.barren_run = 0; // real work ends any barren streak
        accum.outer_traversals +|= @intCast(work);
        const n: u64 = @intCast(self.config.min_useful);
        if (n != 0) while (accum.outer_traversals - accum.window_base >= n) {
            // Freeze-after-qualify: a FROZEN activation's full window is a useful
            // verdict whose only effects in `flushRegionWindow` are two hash-map
            // removes of the owner's `penalty`/`gate` entries. Those can be
            // recreated AFTER qualification (recording aborts, commit failures,
            // unconsumed receipts on the owner anchor), and a useful window is
            // exactly the recovery signal that clears them — so the shortcut is
            // only sound when both maps are EMPTY (codex-flagged MAJOR: skipping
            // unconditionally could strand a demonstrably useful region behind a
            // re-created gate). Empty maps are the steady-state norm; whenever
            // anything is gated anywhere, pay the two removes.
            if (accum.frozen and self.penalty.count() == 0 and self.gate.count() == 0) {
                self.region_profit_flushes +|= 1;
                self.region_profit_flushed_work +|= n;
                accum.useful_streak +|= 1;
                accum.window_base += n;
                continue;
            }
            self.flushRegionWindow(key, n);
            // Codex review (MAJOR 1): the moment an activation first QUALIFIES,
            // clear the legacy penalty/gate on every anchor inside its
            // footprint — from here on the region machine owns those anchors'
            // barren receipts (consumed, never legacy-cleared), so a stale
            // pre-qualification penalty would otherwise stay latent forever
            // and re-gate the anchor on the first low receipt after close.
            if (!accum.useful_window_seen) {
                self.clearMemberAnchorState(key.region_id);
                // The qualification flip changes `qualifiedActiveMember`'s cached
                // verdict without touching the map — invalidate the slot.
                self.act_cache_gen = 0;
                self.act_cache = null;
            }
            accum.useful_window_seen = true;
            accum.window_base += n;
            // Freeze-after-qualify (task #70): a full-window flush from this loop
            // is always a USEFUL verdict (`work == n == min_useful` clears the
            // penalty in `flushRegionWindow`). Enough of them in a row proves the
            // activation is in steady state — freeze it so `replayLedger` stops
            // paying the full pricing pipeline per ledger row. Any strike path
            // (`flushRegionWindow` low-yield) zeroes the streak and unfreezes.
            accum.useful_streak +|= 1;
            if (accum.useful_streak >= self.config.freeze_windows) accum.frozen = true;
        };
    }

    /// Consume one zero-work (barren) receipt of a QUALIFIED activation, and
    /// price a sustained barren-only streak (codex review, BLOCKER 2): the
    /// window machine only sees credited work, and the close-time remainder is
    /// indefinitely postponable, so without this an activation could qualify
    /// once and then thrash forever on receipts nothing gates. A streak of
    /// `max_barren_run` consumed barren receipts with no intervening credit is
    /// positive evidence of decay: it flushes a synthetic 1-work low-yield
    /// verdict through the authoritative gate machine (strike; gate at
    /// `max_penalty`) and restarts the streak. Any real credit resets it
    /// (`creditRegionWork`), and any full window clears the penalty again —
    /// deterministic, a pure function of receipt counts.
    fn noteBarrenConsumed(self: *TraceState, key: RegionKey, accum: *RegionAccum) void {
        accum.barren_run +|= 1;
        if (accum.barren_run >= self.config.max_barren_run) {
            accum.barren_run = 0;
            self.dbg("barren-run strike: rid={d} act={d}", .{ @intFromEnum(key.region_id), key.activation });
            self.flushRegionWindow(key, 1);
        }
    }

    /// Qualification amnesty (codex review, MAJOR 1): remove legacy
    /// penalty/gate state for every anchor whose program point lies inside
    /// `rid`'s membership footprint. Mirrors what a full window flush does for
    /// the owner anchor, extended to the members whose receipts the region
    /// machine now owns. Victim-scan restart per removal (hashmap iterators
    /// don't survive mutation); both maps are small.
    fn clearMemberAnchorState(self: *TraceState, rid: RegionId) void {
        outer: while (true) {
            var pit = self.penalty.keyIterator();
            while (pit.next()) |k| {
                if (self.regionMemberPoint(rid, k.proto.id, k.pc)) {
                    const victim = k.*;
                    _ = self.penalty.remove(victim);
                    self.clearDispatchGate(victim);
                    continue :outer;
                }
            }
            break;
        }
        gates: while (true) {
            var git = self.gate.iterator();
            while (git.next()) |e| {
                // Doc 38: `.low_trip_while` yield gates survive amnesty (see
                // `clearDispatchGate`); skipping without removal keeps the
                // restart-per-mutation loop finite.
                if (e.value_ptr.reason != .low_trip_while and
                    self.regionMemberPoint(rid, e.key_ptr.proto.id, e.key_ptr.pc))
                {
                    _ = self.gate.remove(e.key_ptr.*);
                    continue :gates;
                }
            }
            break;
        }
    }

    /// Does `trace_id` resolve to a cached trace whose anchor program point lies
    /// inside `rid`'s membership footprint? This is the same point-set the tier-0
    /// observer keys survival on (`RegionDef.member_points`), applied to the
    /// TRACE side: a trace anchored inside the region is a region member for
    /// receipt-ownership purposes even when the ephemeral edge cache cannot
    /// classify its exit. Fail-closed on every miss (unknown id, freed def,
    /// tombstoned def, point outside the footprint).
    fn regionMemberTraceAnchor(self: *const TraceState, rid: RegionId, trace_id: u32) bool {
        const t = self.traceById(trace_id) orelse return false;
        return self.regionMemberPoint(rid, t.anchor.proto.id, t.anchor.pc);
    }

    /// Memoized `regionMemberPoint(rid, t.anchor)` for the frozen fast path
    /// (task #70): the answer is cached on the TRACE (`region_memo_*`), keyed by
    /// `(region_defs_gen, rid)`, so the per-row cost in a frozen steady state is
    /// two integer compares instead of a footprint scan. Every `region_defs`
    /// mutation bumps the generation, so a stale answer can never be returned.
    inline fn traceRegionMemberMemo(self: *const TraceState, t: *Trace, rid: RegionId) bool {
        if (t.region_memo_gen == self.region_defs_gen and
            t.region_memo_rid == @intFromEnum(rid))
            return t.region_memo_member;
        const member = self.regionMemberPoint(rid, t.anchor.proto.id, t.anchor.pc);
        t.region_memo_gen = self.region_defs_gen;
        t.region_memo_rid = @intFromEnum(rid);
        t.region_memo_member = member;
        return member;
    }

    /// Point-in-footprint test against a region's `member_points`, fail-closed
    /// (freed or tombstoned defs own nothing).
    fn regionMemberPoint(self: *const TraceState, rid: RegionId, proto_id: u32, pc: u32) bool {
        const def = self.region_defs.get(rid) orelse return false;
        if (!def.armable) return false;
        for (def.member_points) |p| {
            if (p.proto_id == proto_id and p.source_pc == pc) return true;
        }
        return false;
    }

    const MemberAccum = struct { key: RegionKey, accum: *RegionAccum };

    /// The live-QUALIFIED-activation ownership test for events the edge cache
    /// cannot key (the synthetic zero-progress steering charges in `onSideExit`):
    /// non-null iff the current region context has a live activation whose region
    /// has produced at least one useful window AND whose membership footprint
    /// contains `(proto, pc)`. Qualification is the load-bearing half — an
    /// activation that never proves a useful window keeps full pre-flip legacy
    /// gating on its barren events, so the A-vii-c review-blocker shape (member
    /// thrash that no window would ever price) stays gated. Returns the live
    /// accumulator so the caller can count the consumed barren receipt
    /// (`noteBarrenConsumed` — codex BLOCKER 2).
    fn qualifiedActiveMember(self: *TraceState, proto: *const Proto, pc: u32) ?MemberAccum {
        const ctx = self.region_context orelse return null;
        self.refreshActCache(ctx.call_seq);
        const m = self.act_cache orelse return null;
        if (!self.regionMemberPoint(m.key.region_id, proto.id, pc)) return null;
        return m;
    }

    /// Single-slot activation cache refresh (see `act_cache_*`): the map
    /// iteration + hash lookup + qualification check only re-run when the
    /// activation, the `region_profit` map, or the region defs changed. Shared
    /// by `qualifiedActiveMember` (per-receipt) and `replayLedger`'s
    /// freeze-fast-path setup (per-walk) — before the share, the walk setup
    /// re-iterated `region_profit` + re-hashed on EVERY walk (seam round 2).
    /// After a refresh, `act_cache` holds the QUALIFIED (`useful_window_seen`)
    /// active accumulator for `call_seq`, or null — a `frozen` accumulator is
    /// always qualified (freeze-after-qualify), so a valid-cache null also
    /// means "no frozen activation".
    fn refreshActCache(self: *TraceState, call_seq: u64) void {
        if (self.act_cache_gen == self.region_defs_gen and self.act_cache_seq == call_seq) return;
        self.act_cache = blk: {
            const a = self.activeRegionFor(call_seq) orelse break :blk null;
            const accum = self.region_profit.getPtr(a) orelse break :blk null;
            if (!accum.useful_window_seen) break :blk null;
            break :blk .{ .key = a, .accum = accum };
        };
        self.act_cache_gen = self.region_defs_gen;
        self.act_cache_seq = call_seq;
    }

    /// A-vii-e.2: the inline half of the tier-0 departure observer. Returns true
    /// iff this program point provably SURVIVES — i.e. `observeRegionProgramPoint`
    /// would have taken its `ObserverFast` member-hit branch and returned without
    /// closing anything. The caller must fall through to the real observer on
    /// false; a false is never a verdict, only "the inline cache can't answer".
    ///
    /// Soundness rests on the hot cache being keyed by the whole query — the
    /// member-hit branch is a pure function of `(proto_id, pc, depth, call_seq)`
    /// and the `ObserverFast` cache, and the hot entry dies with that cache — so a
    /// matching key over an identical span re-derives the identical verdict. The
    /// only side effect that branch has is refreshing `region_context`, which this
    /// reproduces.
    pub inline fn observeFast(self: *TraceState, proto_id: u32, pc: u32, depth: u32, call_seq: u64) bool {
        const h = &self.observer_hot;
        const words = h.words orelse return false;
        if (h.proto_id != proto_id or h.depth != depth or h.call_seq != call_seq) return false;
        const off = pc -% h.base_pc;
        if (off >= h.span_pcs) return false;
        if ((words[off >> 6] >> @intCast(off & 63)) & 1 == 0) return false;
        self.region_context = .{ .depth = depth, .call_seq = call_seq };
        return true;
    }

    /// Set the current physical activation and close accumulators whose recorded
    /// membership no longer contains this tier-0 departure point. No allocation;
    /// the common empty-map path is one count test.
    pub fn observeRegionProgramPoint(self: *TraceState, proto_id: u32, pc: u32, depth: u32, call_seq: u64) void {
        self.region_context = .{ .depth = depth, .call_seq = call_seq };
        if (self.region_profit.count() == 0) return;
        // A-vii-e.1 fast path: the per-instruction survive verdict for the
        // single-accumulator common case, without touching the hashmap. Exactly
        // the slow loop's predicate below, accelerated:
        //   depth > root                          → survives
        //   depth == root and call_seq != seq     → close
        //   otherwise                             → close iff point ∉ members
        if (self.observer_fast) |f| {
            if (depth > f.root_frame_depth) return;
            if (depth < f.root_frame_depth or call_seq == f.root_call_seq) {
                for (f.spans) |s| {
                    if (s.proto_id != proto_id) continue;
                    if (pc >= s.base_pc and pc < s.limit_pc) {
                        const off = pc - s.base_pc;
                        if ((s.words[off >> 6] >> @intCast(off & 63)) & 1 != 0) {
                            // Member → survives. Warm the inline cache (A-vii-e.2)
                            // with the span that produced this verdict, keyed by the
                            // exact query, so the next instruction at the same
                            // proto/activation never re-enters this function.
                            self.observer_hot = .{
                                .words = s.words.ptr,
                                .proto_id = s.proto_id,
                                .base_pc = s.base_pc,
                                .span_pcs = s.limit_pc - s.base_pc,
                                .depth = depth,
                                .call_seq = call_seq,
                            };
                            return;
                        }
                    }
                }
            }
            self.dbg("observer-close: fast, departure proto={d} pc={d} depth={d} seq={d} (root depth={d} seq={d})", .{ proto_id, pc, depth, call_seq, f.root_frame_depth, f.root_call_seq });
            self.closeRegion(f.key); // count → 0; refresh nulls the cache
            return;
        }
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
            if (victim) |dead| {
                self.dbg("close-reason: dropRegionActivation seq={d} rid={d}", .{ call_seq, @intFromEnum(dead.region_id) });
                self.closeRegion(dead);
            } else break;
        }
        if (self.region_context != null and self.region_context.?.call_seq == call_seq)
            self.region_context = null;
    }

    pub fn resetRegionProfit(self: *TraceState) void {
        self.resetPromotionCandidate();
        self.region_profit.clearRetainingCapacity();
        self.region_context = null;
        self.freeObserverFast();
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
            // Doc 20 qualify (§R1-7/§R2-7/§R4-2): T's OWN completed count in a
            // single receipt (this funnel is per-trace-commit, never a fused
            // child's cumulative sum). Mark only — this funnel runs INSIDE the
            // receipt grammar and may run multiple times per fused walk; the
            // install happens at the caller-owned safe-point drain. Tag
            // inspection ONLY, never `nativeFor` (it compiles lazily —
            // §R3-2); never under coverage (§R1-9: coverage measures the
            // unpatched machine). The `.eligible` compare is the entire
            // steady-state cost for `.bound`/`.suppressed_*` traces.
            if (t.entry_patch == .eligible and !self.config.coverage and
                self.config.native_codegen and t.native == .compiled)
            {
                t.entry_patch = .pending;
                self.entry_patch_dirty += 1;
            }
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
        // Doc 38: "unsupported" is a per-TRACE verdict, but this gate is
        // per-ANCHOR — never fire it while a COMPILED sibling still serves the
        // anchor. The dispatch walk's own "only if nothing productive ran"
        // guard misses one shape: a compiled trace runs productively, exits at
        // its loop-done with no chain target (directive `.next_candidate`),
        // the walk then meets the unsupported sibling and ends — and the
        // anchor gate starves the good trace (fft_bitreverse:55: the
        // float-stable while-body root was gated off because a wandering
        // sibling proveKinds-bailed; 176 native entries in 101M passes). A
        // rare cold scan (this path runs only on unproductive walk ends), and
        // an anchor whose traces are ALL unsupported still gates as before.
        for (self.cache.items) |t| {
            if (t.anchor.proto == anchor.proto and t.anchor.pc == anchor.pc and
                t.native == .compiled) return;
        }
        self.gateAnchor(anchor, .native_unsupported);
    }

    /// Doc 22 §B.3 (Phase B-iii): seed a tier-1a chain successor's inputs
    /// through the episode ctx before `irinterp.execute`. Returns true when the
    /// successor may run on tier-1a for this entry:
    /// - SEED_OK and SEED_HASH_DECLINE → run. A failed hash cell only means the
    ///   seeded fast pointer is unusable; tier-1a re-derives cells from `href`
    ///   operands and side-exits at the same `guard_table`/`guard_hash` — this
    ///   is exactly the dispatcher's old `native_eligible=false` downgrade.
    /// - SEED_CAPACITY_DECLINE → decline, same directive as the VM-side wall
    ///   (`seedTraceInputs` returning null).
    /// - No ctx / no twin installed (hand-built test TraceStates) → decline,
    ///   fail closed — byte-identical to the pre-B-iii skip.
    ///
    /// Seeding re-runs before EVERY execute of a seeded successor (burst
    /// re-entries included): per-entry re-resolution is the dispatcher's
    /// contract ("re-resolved and re-seeded on *every* entry"), and a burst
    /// hop is one more entry of the same region within the same frame. `proto`
    /// is the caller's frame proto, asserted against the ctx's freshness stamp
    /// — every chain seam runs inside an episode `prepareNativeEpisode` just
    /// stamped, so a mismatch is a wiring bug, not a runtime condition.
    fn seedForTier1a(self: *TraceState, t: *const Trace, proto: *const Proto) bool {
        if (t.inputs.len == 0) return true;
        const ctx = self.native_seed_ctx orelse return false;
        const f = ctx.seed_tier1a_fn orelse return false;
        std.debug.assert(ctx.proto == @as(*const anyopaque, @ptrCast(proto)));
        const rc = f(ctx, t);
        self.dbg("chain-seed: trace={d} inputs={d} rc={d}", .{ t.id, t.inputs.len, rc });
        return rc != NativeSeedCtx.SEED_CAPACITY_DECLINE;
    }

    /// Doc 22 §B.4/§B.5: which secondary entry stub an arm/link site wants to
    /// target. Both stubs `jmp body_entry`, which owns the seed prologue — so a
    /// seeded page seeds on EVERY entry kind and `stubEnterable` is
    /// kind-uniform apart from which stub must exist.
    pub const StubEntryKind = enum { ordinary, linked };

    /// Doc 22 §B.4: THE gate every arm/link site consults instead of the B-i..iii
    /// scalar `inputs.len == 0` filters. Answers "may native execution enter this
    /// trace's page through `entry_kind` right now?" — replacing the blanket
    /// "seeded children are unlinkable" rule with "seeded children are linkable
    /// when their seed context is fresh."
    ///
    /// Fail-closed contract (codex-confirmed): operational sites get `false` on
    /// stale/missing context and fall back to their pre-B-iv disposition.
    ///
    /// Freshness for a seeded page = the episode's `NativeSeedCtx` stamp still
    /// names the live frame: same proto on both the ctx and the trace anchor,
    /// and the ctx's activation token matches `region_context.call_seq` (which
    /// `setRegionContext` refreshes unconditionally at every frame transition,
    /// so it IS the live frame's token at any dispatcher/chain seam). Every
    /// seeded-entry-capable seam must have run `prepareNativeEpisode` before
    /// evaluating this predicate — that is what stamps the ctx.
    ///
    /// Never compiles: callers that may need lazy compilation run `nativeFor`
    /// first; a not-yet-compiled page is simply not enterable yet.
    pub fn stubEnterable(
        self: *const TraceState,
        t: *const Trace,
        entry_kind: StubEntryKind,
        proto: *const Proto,
    ) bool {
        return self.stubEnterability(t, entry_kind, proto) == .ok;
    }

    /// WHY a page is not enterable, which the `stubEnterable` bool discards.
    ///
    /// Callers that merely gate an action can use the bool. Callers that must
    /// decide whether to RETRY need the distinction, because `stubEnterable`
    /// conflates two very different falsehoods: "this will never be true for
    /// this compilation" and "this is not true under the episode that happens
    /// to be live right now". Treating the second as the first drops work;
    /// treating the first as the second retries forever. Both mistakes were
    /// live in the tree (`drainProvenanceArms` latched its gate permanently,
    /// `tryArmRegionBridge` re-ran an unbounded pipeline), and both are fixed
    /// by consulting this instead.
    pub const StubEnterability = enum {
        ok,
        /// Structural for this trace's CURRENT native state: `.unsupported`, or
        /// compiled without the requested entry stub. Only a recompile or a
        /// retirement can change it — re-checking under a different episode
        /// cannot.
        no_compilation,
        /// Not compiled YET. Lazy compilation may still produce a page, but
        /// this predicate never compiles one (callers that want that run
        /// `nativeFor` first).
        not_compiled,
        /// A seeded page whose seed context does not name the live frame. Says
        /// nothing about the page itself — re-check under the right episode.
        no_episode,
    };

    /// The proto a seeded page must be anchored in to be enterable right now,
    /// or null when there is no fresh episode at all — no ctx, no region
    /// context, or a ctx whose activation token does not match the live frame's,
    /// in which case NO seeded page is enterable regardless of its proto. Note
    /// the `call_seq` clause is pass-level, not per-edge: when it fails, it
    /// fails for everything.
    fn liveEpisodeProto(self: *const TraceState) ?*const anyopaque {
        const ctx = self.native_seed_ctx orelse return null;
        const rctx = self.region_context orelse return null;
        if (ctx.call_seq != rctx.call_seq) return null;
        return ctx.proto;
    }

    pub fn stubEnterability(
        self: *const TraceState,
        t: *const Trace,
        entry_kind: StubEntryKind,
        proto: *const Proto,
    ) StubEnterability {
        const c = switch (t.native) {
            .compiled => |*cc| cc,
            .unattempted => return .not_compiled,
            .unsupported => return .no_compilation,
        };
        const entry: ?usize = switch (entry_kind) {
            .ordinary => c.ordinary_entry,
            .linked => c.linked_entry,
        };
        if (entry == null) return .no_compilation;
        // Unseeded page: enterable unconditionally (the pre-B-iv world). No
        // episode context needed — hand-built test pages stay armable.
        if (!c.seed_plan.nonEmpty()) return .ok;
        // Seeded page: fail-closed freshness.
        if (t.anchor.proto != proto) return .no_compilation;
        const live = self.liveEpisodeProto() orelse return .no_episode;
        if (live != @as(*const anyopaque, @ptrCast(proto))) return .no_episode;
        return .ok;
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
        // Doc 26 D1 tripwire: the caller's `Vm.unicode_version_pinned`,
        // threaded like `safe_to_arm` because `*Vm` is not visible here. A
        // chain can enter a `requires_unicode_pin` CHILD whose parent needed
        // no pin, bypassing `enterSelectedTrace`'s assert — this closes that
        // coverage gap. Debug-only consumption (a std.debug.assert).
        unicode_pinned: bool,
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
            // Doc 38: a while-loop-done chains to the continuation at the condition
            // branch's JUMP TARGET (the post-loop pc). Re-derived through the
            // fail-closed classifier — a mis-tagged call (exit isn't actually a
            // while-loop-done) returns null rather than walking a bogus pc.
            // Doc 40 Phase 0: fail-closed twin of the dispatcher's peel-aware
            // classification gate. A peeled trace's STEADY-region loop-done at
            // zero local completions owes a replay (its run-once iteration is
            // real but unflushed); chaining would resume the post-loop pc on
            // stale boxes. Belt-and-braces for any future `.while_done` caller.
            .while_done => blk: {
                const local: usize = if (tier == .native_only) result.local_completed else result.completed;
                if (local == 0 and !whileDoneCoherentAtZero(failed, exit_instr)) return null;
                break :blk whileLoopDonePostPc(failed, exit_instr) orelse return null;
            },
            // Numeric-for loop-done materializations chain to a `.link` continuation
            // living at the guard's *exit* PC (a real post-loop bytecode pc). Resolve
            // it through the op-gated accessor so an array-guard lane ordinal is never
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
            // One scratch frame per candidate, released before the next candidate
            // is tried. Scoped to the whole iteration (not to the `else` arm that
            // pushes) because `runLinkedBurst` runs under it and pushes its own
            // frames on top; the release must outlive that nest.
            //
            // Comptime-elided on the native tier, which touches the executor
            // scratch nowhere: neither this walk's `sbuf` nor `runLinkedBurst`'s
            // `ibuf`/`cbuf` exists outside a `tier == .ir` arm. With the release
            // gone the mark is dead and folds away with it — worth the two words
            // of noise here because `driveChain` runs ~1M times on scimark-fft.
            const cand_mark = self.valuesMark();
            defer if (tier == .ir) self.valuesRelease(cand_mark);
            // Doc 24 D8 observation blackout: while a suspend/keyframe window is
            // armed (`!safe_to_arm` — the identical condition the link-arm
            // machinery blacks out on), never chain into an ALLOCATING
            // candidate. A mid-burst suspension after its `guard_gc` passed
            // would capture a heap whose `next_obj_id` tier-0 only reaches
            // after the full burst — the keyframe byte-identity (§T-A.2)
            // demands allocation counts observed only at tier-0 boundaries.
            // Non-allocating candidates chain as before.
            if (!safe_to_arm and sct.alloc_bound > 0) continue;
            // Doc 26 D1 tripwire, chain half: see `enterSelectedTrace`.
            if (sct.requires_unicode_pin) std.debug.assert(unicode_pinned);
            const is_link = sct.instrs.len != 0 and sct.instrs[sct.instrs.len - 1].op == .link;
            // Loop-done chains (ir and native, numeric-for and while) only follow
            // `.link` continuations; an ordinary side trace at the post-loop PC is
            // not a valid hand-off.
            if ((loop_done_values != null or materialization == .while_done) and !is_link) continue;
            if (tier == .native_only and !is_link) continue;
            // A candidate with synthetic inputs needs per-entry seeding. B-iii
            // (doc 22 §B.3): the TIER-1A walk seeds it right here via the episode
            // ctx's seeding twin — hash-decline included (tier-1a re-derives hash
            // cells from `href` operands and side-exits at the same guard); only
            // a capacity decline (or a missing ctx, fail closed) skips it.
            // B-iv.3 (doc 22 §B.5): the NATIVE walk accepts a seeded candidate
            // outright — its page seeds itself at entry (§B.4 prologue) and a
            // stale seed declines through the B-iv.2 hop-0 directives (no
            // strike, no receipt). Ordered AFTER the shape filters so a
            // filtered-out candidate is never spuriously seeded.
            if (sct.inputs.len != 0 and tier != .native_only) {
                if (!self.seedForTier1a(sct, proto)) continue;
            }

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
                self.prepareNativeEntry(); // B-3a global sweep hook: driveChain seed
                sresult = snt.runCapturingLedger(regs, &self.ledger_scratch, self.silentStaging());
                if (self.driveSeedSilentResult(sct, sresult, proto, regs, safe_to_arm, materialization)) |silent|
                    return silent;
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
                // A-vii-d.1 (generalized): a hop-0 ledger OPENED by any armed slot
                // that is NOT the seed's `.link` terminal is replay-owned too — the
                // scalar `sresult_fused` seam below models only the `[C.link, I.x]`
                // shape and would consume the dispatched successor as a fused INNER
                // (wrong anchor, wrong resume). Measured twice: first as
                // `[C.region_bridge, S.…]` (panic on nsieve the moment the bridge
                // armed), then as `[C.deopt(sibling_handoff), S.…]` (panic on the
                // A-viii cycle under doc-20 patched entry, where the chain's
                // exclusion set steers hop-0 to a sibling whose handoff arm fires
                // straight back into the excluded trace). `.loop_done_linked` heads
                // are the same class. Only a `.link_terminal` head matches the
                // scalar seam's model.
                const nonlink_headed = sresult.ledger_len >= 2 and
                    self.ledger_scratch[0].kind != .link_terminal;
                if (sresult.ledger_len > 2 or nonlink_headed) {
                    if (safe_to_arm and materialization == .ordinary_header and
                        self.stubEnterable(sct, .ordinary, proto) and
                        self.isSourceBranchGuardExit(failed, exit_instr, proto))
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
                        self.armLoopDoneLink(failed, exit_instr, safe_to_arm);
                    }
                    // Route by HEAD kind: the seed-ledger drain models only spans
                    // opened by the seed's own `.link` terminal or composite
                    // bridge. Any other head (`.deopt` = sibling-handoff / M1
                    // ordinary-guard dispatch, `.loop_done_linked`) is exactly the
                    // grammar the dispatcher's direct-entry drain already walks —
                    // hand the span to it wholesale.
                    return switch (self.ledger_scratch[0].kind) {
                        .link_terminal, .region_bridge => self.driveSeedLedger(
                            sct,
                            self.ledger_scratch[0..sresult.ledger_len],
                            proto,
                            regs,
                            safe_to_arm,
                            materialization,
                        ),
                        else => self.driveDispatcherLedger(
                            sct,
                            self.ledger_scratch[0..sresult.ledger_len],
                            proto,
                            regs,
                            safe_to_arm,
                        ),
                    };
                }
                // The ≤2 scalar compatibility seam is still a complete native
                // call. Capture its ordinary ledger before any steering and settle
                // before `runLinkedBurst` can re-enter native code.
                var provenance: NativeCallProvenance = .{};
                self.captureNativeCallProvenance(
                    .drive_chain_seed,
                    sresult,
                    self.ledger_scratch[0..sresult.ledger_len],
                    &provenance,
                );
                self.settleNativeCallProvenance(&provenance, safe_to_arm);
                // B-iv.2 (doc 22 §B.2, codex Q2): a hop-0 SCALAR seed decline —
                // `sct`'s own direct entry declined at the seed prologue before
                // any body ran (`final == sct`, exit == maxInt, the ledger holds
                // only the decline row). `regs` are untouched, so the walk state
                // is exactly what it was before this candidate was tried. The
                // agreed dispositions, and NO receipt, strike, side-exit
                // accounting, or chain source — which is why this steers BEFORE
                // the composite-exit arm and the receipt tail below (the
                // capture/settle bracket above is decline-inert: verdict capture
                // matches only `.deopt` rows, and a declined entry stages no
                // pending bridge arm):
                //   capacity → try the next walk candidate (identical to the
                //              pre-B-iv "unenterable candidate" filter);
                //   hash     → end the walk and redispatch at `walk_pc`; the
                //              dispatcher's direct-entry H1 downgrade owns the
                //              tier-1a hash rerun on re-selection.
                // A FUSED span ending in a decline (`final != sct`: the terminal
                // decliner is a linked child) is NOT handled here — it rides
                // `sresult_fused` into `runLinkedBurst`, whose call-A consumes
                // the carried decline coherently.
                if (sresult.final_trace_id == sct.id and
                    (sresult.exit_reason == .seed_hash_decline or
                        sresult.exit_reason == .seed_capacity_decline))
                {
                    if (sresult.exit_reason == .seed_capacity_decline) {
                        self.seed_capacity_declines +|= 1;
                        continue;
                    }
                    self.seed_hash_declines +|= 1;
                    return .{ .completed = 0, .resume_pc = walk_pc };
                }
            } else {
                const sbuf = self.valuesPush(sct.instrs.len) catch continue;
                if (loop_done_values) |vals| {
                    if (!irinterp.flushNumericForLoopDone(failed, regs, vals, exit_instr)) return null;
                    flushed_resume_pc = walk_pc;
                } else if (materialization == .while_done) {
                    // Doc 38: no flush owed — the while condition guard fails at
                    // the trace TOP, before any of the final pass's body ran; the
                    // completed iterations committed at their `.loop` terminals.
                    // But the loop IS done (the condition was observed falsy), so
                    // a zero-progress continuation run must still resume tier-0 at
                    // the post-loop pc, never back at the loop header.
                    flushed_resume_pc = walk_pc;
                }
                sresult = irinterp.executeCtx(.{ .heap = self.exec_heap }, sct, regs, sbuf);
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
                    self.stubEnterable(sct, .ordinary, proto) and
                    self.isSourceBranchGuardExit(failed, exit_instr, proto))
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
                    self.armLoopDoneLink(failed, exit_instr, safe_to_arm);
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
                self.onSideExitReceipt(sct, 0, sresult.exit_instr, 0, .deferred, if (sresult.exit_reason == .prologue_fail) .entry_refusal else .entered);
                return .{ .completed = 0, .resume_pc = target_pc };
            }
            if (sresult.completed > 0) {
                self.onSideExitReceipt(sct, sresult.completed, sresult.exit_instr, sresult.completed, .deferred, .entered);
                return .{ .completed = sresult.completed };
            }
            self.onSideExitReceipt(sct, 0, sresult.exit_instr, 0, .deferred, if (sresult.exit_reason == .prologue_fail) .entry_refusal else .entered);
            // Zero iterations, no flush owed (ordinary path): try the next candidate.
        }
        return null;
    }

    fn driveSeedSilentResult(
        self: *TraceState,
        seed: *Trace,
        result: irinterp.ExecResult,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
        materialization: ExitMaterialization,
    ) ?ChainResult {
        var linked_completed: usize = 0;
        const seed_inner_pc: u32 = if (seed.instrs.len != 0 and seed.instrs[seed.instrs.len - 1].op == .link)
            @intCast(seed.instrs[seed.instrs.len - 1].aux)
        else
            seed.anchor.pc;
        var resume_pc: u32 = seed_inner_pc;
        var hops: usize = 0;
        const directive = self.drainSilentResult(
            result,
            .continuation_call,
            proto,
            &linked_completed,
            &resume_pc,
            &hops,
            8,
            safe_to_arm,
            regs,
        ) orelse return null;
        var provenance: NativeCallProvenance = .{};
        self.captureNativeCallProvenance(
            .drive_chain_seed,
            result,
            self.ledger_scratch[0..result.ledger_len],
            &provenance,
        );
        if (materialization == .ordinary_header) self.prime_side_chain_follows +|= 1;
        self.settleNativeCallProvenance(&provenance, safe_to_arm);
        return switch (directive) {
            .run_continuation => |c| blk: {
                const snt = self.nativeFor(c) orelse
                    @panic("driveSeedSilentResult: run_continuation target has no native code");
                break :blk self.driveBurstCore(c, .{
                    .current_link = c,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                    .start_at_continuation = true,
                }, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            .run_inner_from => |d| blk: {
                const snt = self.nativeFor(d) orelse
                    @panic("driveSeedSilentResult: run_inner_from target has no native code");
                break :blk self.driveBurstCore(d, .{
                    .current_link = d,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                }, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            .return_result => |cr| cr,
            .break_burst => |charge_kind| blk: {
                if (linked_completed > 0)
                    break :blk .{ .completed = linked_completed, .resume_pc = resume_pc };
                self.onSideExit(seed, 0, charge_kind);
                break :blk .{ .completed = 0, .resume_pc = resume_pc };
            },
        };
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
    /// directly with the already-run ramp receipt (see `hasArmedSourceBranchLinkAt`).
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
        break_burst: ChargeKind,
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

    const FrozenFast = struct { key: RegionKey, accum: *RegionAccum };

    const OrdinaryGuardEntry = struct { parent: *Trace, source_local: usize };

    const EntryMaterialization = union(enum) {
        ordinary,
        via_bridge,
        via_handoff,
        /// Suppressed M1 source guard. The successor ramp's terminal contract
        /// resumes at this predecessor's coherent anchor, not at the ramp.
        via_ordinary_guard: OrdinaryGuardEntry,
    };

    const ReplayCursor = struct {
        cont: *Trace,
        link_pc: u32,
        prev_cum: usize,
        next_entry: EntryMaterialization,
        frozen_fast: ?FrozenFast,
        /// false only for a silent-prefix suffix entry, where row 0's owner is the
        /// promoted set's off-cycle successor, not the burst's seed owner.
        check_seed: bool = true,
    };

    const SuffixInit = struct {
        /// Owner of the last promoted (silent) edge — the continuation cursor the
        /// suppressed prefix left behind.
        cont: *Trace,
        link_pc: u32,
        /// Cumulative rbx at the last silent edge (NativeResult.silent_cum).
        prev_cum: usize,
        next_entry: EntryMaterialization,
    };

    /// The single cursor image of one suppressed/replayed physical edge. Both
    /// reporting replay and silent-prefix reconstruction call this helper.
    fn applyEdgeCursorTransition(
        cursor: anytype,
        kind: ArmKind,
        parent: *Trace,
        child: *Trace,
        edge_resume_pc: u32,
        edge_local: usize,
        resume_pc: *u32,
    ) void {
        switch (kind) {
            .link_terminal => {
                cursor.cont = parent;
                cursor.link_pc = edge_resume_pc;
                cursor.next_entry = .ordinary;
            },
            .loop_done_linked => {
                cursor.cont = child;
                cursor.next_entry = .ordinary;
            },
            .region_bridge => cursor.next_entry = .via_bridge,
            .sibling_handoff => cursor.next_entry = .via_handoff,
            .ordinary_guard => cursor.next_entry = .{ .via_ordinary_guard = .{
                .parent = parent,
                .source_local = edge_local,
            } },
        }
        resume_pc.* = edge_resume_pc;
    }

    const SilentCellOwner = struct { set: *PromotedSet, phase: usize };

    /// Resolve a `*SilentExitMetadata` address published by a silent epilogue back to
    /// the promoted edge that owns it.
    ///
    /// Round-6 (this replaced `silentPhases`/`silentEdgeFireCount`): the endpoints of
    /// a silent burst used to be RECONSTRUCTED as `(first_phase + t) % len` from the
    /// call-global transition count. That arithmetic silently assumed every silent
    /// transition was the next phase of one ring in which every trace owns exactly one
    /// phase — and nothing enforces either half. B-3d finished the job: a promoted
    /// SET has no phase order at all (canonical storage order is (parent id, exit)),
    /// may repeat a parent freely, and `promoted_sets` holds up
    /// to `PROMOTED_SET_CAP` concurrently live sets, so both assumptions are
    /// violable by construction. The failure was silent and severe: a wrong terminal
    /// edge yields a wrong tier-0 resume PC (the A-viii "missing prime 307" class) and
    /// a wrong committed count, with no panic to catch it. Native now publishes what
    /// actually happened — per-cell `firings`/`last_ordinal` and `silent_last_cell` —
    /// and this resolver turns those measurements back into edges.
    fn silentCellOwner(self: *TraceState, cell_addr: u64) ?SilentCellOwner {
        if (cell_addr == 0) return null;
        var found: ?SilentCellOwner = null;
        for (self.promoted_sets.items) |*set| {
            for (set.metadata, 0..) |*metadata, phase| {
                if (@intFromPtr(metadata) != cell_addr) continue;
                if (found != null)
                    @panic("driveSilentBurst: silent metadata cell is ambiguous");
                found = .{ .set = set, .phase = phase };
            }
        }
        return found;
    }

    const SilentSiblingEvidence = struct {
        productive: bool,
        returned_to_parent: bool,
    };

    /// The one sibling-handoff verdict this call owes for `cell`'s edge, derived from
    /// measured ordinals rather than phase arithmetic.
    ///
    /// The summary stages exactly ONE verdict per edge, so it must describe the edge's
    /// MOST RECENT firing — reporting walks rows in order and the later observation is
    /// the one left standing. The pre-round-6 form compared against the edge's FIRST
    /// firing (`last_productive_ordinal >= offset + 1`), which called an edge
    /// productive on the strength of progress that happened before its final,
    /// barren firing — under-reporting strikes and letting an unproductive handoff
    /// escape demotion.
    ///
    /// B-3d (doc 17 §B3.16 D3, §B3.17 R3/R4): `returned_to_parent` is MEASURED, not
    /// reconstructed from a ring return distance. Ordinals are call-global and
    /// monotonic, so "control returned to P after e's most recent firing at k" is
    /// exactly: some live cell whose edge's PARENT is P recorded a strictly later
    /// firing (a firing out of P proves control was at P), OR the reporting suffix
    /// contains a row whose owner is P (every suffix row is later than every silent
    /// firing; arrival ownership = `row.id`, exactly as `captureProvenanceVerdicts`
    /// scans it — a failed-prologue row's baked id IS the arriving trace). Strictly
    /// `>` suffices: e's firing at k moves control INTO the child, so the earliest
    /// later firing out of P is k+2 — the one-intervening-child-row requirement the
    /// ring distance encoded is implied by monotonicity. For self-edges (P → P) and
    /// repeated-parent sets this is STRONGER than the ring bound it replaces: the
    /// firing under judgment never counts as its own return evidence, and the old
    /// call-global bound `last_ordinal + distance <= transitions` could be satisfied
    /// by a second live set's firings with no actual return to P (pre-existing false
    /// strike, Rule #0.5 — eliminated by measuring arrivals at P specifically).
    pub fn silentSiblingEvidence(
        self: *TraceState,
        cell: nativegen.SilentSummaryCell,
        followed: u64,
        last_productive_ordinal: u64,
        parent_id: u32,
        suffix_rows: []const irinterp.LedgerEntry,
    ) SilentSiblingEvidence {
        if (cell.last_ordinal == 0)
            @panic("driveSilentBurst: fired edge has no firing ordinal");
        var returned = false;
        for (self.promoted_sets.items) |*c| {
            for (c.edges, c.summary) |other_edge, other_cell| {
                if (other_edge.parent.id == parent_id and
                    other_cell.last_ordinal > cell.last_ordinal)
                {
                    returned = true;
                }
            }
        }
        if (!returned) {
            for (suffix_rows) |row| {
                if (row.id == parent_id) {
                    returned = true;
                    break;
                }
            }
        }
        return .{
            // Progress at or after this relation's most recent firing is service
            // for it; earlier progress belongs to an observation reporting already
            // closed.
            .productive = followed != 0 and last_productive_ordinal >= cell.last_ordinal,
            .returned_to_parent = followed != 0 and returned,
        };
    }

    /// Apply the exact accounting image produced by promoted epilogues, then
    /// either replay an off-cycle reporting suffix or return the compile-time
    /// resume contract of the edge where the silent budget stopped.
    pub fn driveSilentBurst(
        self: *TraceState,
        result: irinterp.ExecResult,
        proto: *const Proto,
        linked_completed: *usize,
        resume_pc: *u32,
        hops: *usize,
        max_hops: usize,
        origin: ReplayOrigin,
        safe_to_arm: bool,
        regs: ?RegWindow,
    ) LedgerReplay {
        if (!self.config.silent_promotion_enabled)
            @panic("driveSilentBurst: silent result while promotion is disabled");
        if (result.silent_active == 0 or result.silent_transitions == 0 or result.silent_cell == 0)
            @panic("driveSilentBurst: incomplete silent result contract");
        // Preserve the same two-phase mutation boundary as replayLedger: a
        // summary-triggered strike may request disarm/demotion, but promotion
        // storage must remain live until this drain has consumed every cell and
        // derived the terminal resume contract. The origin applies queued work
        // immediately after this returns.
        //
        // COMMENT-ASSERT (§B3.18 R5(b)): no promotion or demotion may execute
        // between the native call's return and this drain. Today that holds by
        // construction — the drain is the FIRST act at every origin, and mid-walk
        // demotion is queued — and it is load-bearing: `silent_cell` /
        // `silent_last_cell` resolve against promotion storage as it was when
        // native published them. Any future safe point inserted between return
        // and drain would let those cell addresses go stale.
        const seam_t0: u64 = if (self.config.coverage and self.replay_walk_depth == 0)
            readCycles()
        else
            0;
        self.replay_walk_depth += 1;
        defer {
            self.replay_walk_depth -= 1;
            if (seam_t0 != 0) {
                self.cycles_seam +|= cycleDelta(readCycles(), seam_t0);
                self.seam_walks +|= 1;
            }
        }

        // Both endpoints of the burst are resolved by MEASUREMENT: `silent_cell` is
        // the first promoted edge that fired (first-cell ownership) and fixes the
        // entry phase; `silent_last_cell` is the last one and fixes the resume
        // contract. They may belong to different live sets, and neither survives
        // reconstruction once a set repeats a parent or two sets are live.
        const entry_owner = self.silentCellOwner(result.silent_cell) orelse
            @panic("driveSilentBurst: silent metadata cell has no live promotion");
        const entry_set = entry_owner.set;
        const first_phase = entry_owner.phase;
        const last_owner = self.silentCellOwner(result.silent_last_cell) orelse
            @panic("driveSilentBurst: silent terminal cell has no live promotion");
        const last_set = last_owner.set;
        const last_phase = last_owner.phase;
        for (self.promoted_sets.items) |*c| {
            if (c.edges.len == 0 or c.edges.len != c.summary.len or
                c.edges.len != c.metadata.len)
                @panic("driveSilentBurst: promoted set storage is inconsistent");
        }
        if (result.ledger_len > irinterp.LEDGER_CAP)
            @panic("driveSilentBurst: suffix ledger exceeds cap");
        const last_edge_local = last_set.summary[last_phase].last_local;
        if (last_edge_local > std.math.maxInt(usize))
            @panic("driveSilentBurst: last edge local exceeds usize");
        self.silent_provenance_len = 0;

        // The ordinal space is call-global and monotonic across every live cycle, so
        // "did anything make progress at or after this firing" stays one comparison.
        var last_productive_ordinal: u64 = 0;
        var total_firings: u64 = 0;
        for (self.promoted_sets.items) |*c| {
            for (c.summary) |cell| {
                last_productive_ordinal = @max(last_productive_ordinal, cell.last_productive_ordinal);
                total_firings +|= cell.firings;
            }
        }
        // Every silent transition is owned by exactly one cell. Disagreement means
        // the epilogue ABI and this expansion have diverged — fail closed rather
        // than charge a real transition to the wrong edge.
        if (total_firings != result.silent_transitions)
            std.debug.panic(
                "driveSilentBurst: summary firings {d} disagree with transition count {d}",
                .{ total_firings, result.silent_transitions },
            );
        const active = if (self.region_context) |ctx| self.activeRegionFor(ctx.call_seq) else null;
        if (active == null)
            @panic("driveSilentBurst: silent burst outside an activation");

        var loop_done_count: u64 = 0;
        var suppressed_hops: u64 = 0;
        // COMMENT-ASSERT (§B3.18 R5(a)): this expansion iterates sets and cells in
        // STORAGE order, which carries no information about firing order. That is
        // sound only while every summary mutation below stays additive (saturating
        // sums) or measurement-carried (per-cell ordinals; one most-recent-firing
        // verdict per edge). Do not add order-sensitive derivation here — anything
        // that needs sequence must be measured into the cells by the epilogues.
        for (self.promoted_sets.items) |*c| {
            var region_work: u64 = 0;
            var fired = false;
            for (c.edges, 0..) |edge, phase| {
                const cell = c.summary[phase];
                // An edge that never fired owes nothing: no work, no counters, and
                // (unlike the pre-round-6 form) no `accountLedgerRowsBulk` receipt
                // charging coverage to a trace that did not run in this call.
                if (cell.firings == 0) continue;
                fired = true;
                const fires = cell.firings;
                // A rowless budget/barren return suppresses the final edge's jump to
                // its successor. Its materialization/work still happened, but replay
                // would not charge a fused/follow counter for that terminal row.
                const is_terminal = c == last_set and phase == last_phase;
                const followed = fires - @intFromBool(result.ledger_len == 0 and is_terminal);
                region_work +|= cell.region_work;
                if (cell.selection_work > std.math.maxInt(usize))
                    @panic("driveSilentBurst: selection summary exceeds usize");
                if (edge.arm_kind != .link_terminal) {
                    self.accountLedgerRowsBulk(
                        edge.parent,
                        @intCast(cell.selection_work),
                        cell.qualifying_rows,
                        true,
                    );
                } else if (cell.selection_work != 0 or cell.qualifying_rows != 0) {
                    @panic("driveSilentBurst: link-terminal summary contains selection work");
                }
                switch (edge.arm_kind) {
                    .link_terminal => {
                        self.native_link_exits +|= fires;
                        self.native_link_follow_count +|= followed;
                        self.link_follow_count +|= followed;
                    },
                    .loop_done_linked => {
                        self.native_loopdone_link_fused +|= followed;
                        loop_done_count +|= fires;
                        suppressed_hops +|= fires;
                    },
                    .sibling_handoff => {
                        self.sibling_handoff_fused +|= followed;
                        const evidence = self.silentSiblingEvidence(
                            cell,
                            followed,
                            last_productive_ordinal,
                            edge.parent.id,
                            self.ledger_scratch[0..result.ledger_len],
                        );
                        self.stageSilentSiblingProvenance(
                            edge,
                            followed,
                            evidence.productive,
                            evidence.returned_to_parent,
                        );
                    },
                    .ordinary_guard => self.native_source_link_fused +|= followed,
                    .region_bridge => self.native_region_bridge_fused +|= followed,
                }
            }
            if (!fired) continue;
            // Only a cycle that actually fired must be — and is — provably part of
            // the live activation it credits.
            if (!std.meta.eql(active.?, c.region_key))
                @panic("driveSilentBurst: promoted set activation is not active");
            const c_accum = self.region_profit.getPtr(c.region_key) orelse
                @panic("driveSilentBurst: promoted set accumulator is missing");
            if (!c_accum.frozen)
                @panic("driveSilentBurst: promoted set accumulator is not frozen");
            if (region_work > std.math.maxInt(usize))
                @panic("driveSilentBurst: region summary exceeds usize");
            if (region_work != 0) self.creditRegionWork(c.region_key, c_accum, @intCast(region_work));
        }
        // Every fired edge proved `region_key == active`, so they all share one
        // accumulator; the entry set always fired, so its lookup names it.
        const accum = self.region_profit.getPtr(entry_set.region_key) orelse
            @panic("driveSilentBurst: promoted set accumulator is missing");
        if (loop_done_count > std.math.maxInt(usize) - linked_completed.*)
            linked_completed.* = std.math.maxInt(usize)
        else
            linked_completed.* += @intCast(loop_done_count);
        // Sequential replay charges one hop per loop-done except the first row of
        // an inner-call ledger. Preserve that exception when the first suppressed
        // transition is itself loop-done, then saturate at the caller's bound.
        if (origin == .inner_call and entry_set.edges[first_phase].arm_kind == .loop_done_linked and suppressed_hops > 0)
            suppressed_hops -= 1;
        const hop_room = max_hops -| hops.*;
        hops.* += @intCast(@min(suppressed_hops, hop_room));

        const barren_exhausted = result.cur_zero_run >= result.barren_budget;
        const budget_exhausted = result.silent_transitions >= result.silent_budget;
        if (barren_exhausted) {
            if (self.config.max_barren_run == 0)
                @panic("driveSilentBurst: zero barren budget");
            accum.barren_run = self.config.max_barren_run - 1;
            self.noteBarrenConsumed(entry_set.region_key, accum);
            self.silent_barren_exhaustions +|= 1;
        } else {
            if (result.cur_zero_run > std.math.maxInt(u32))
                @panic("driveSilentBurst: returned zero-run exceeds u32");
            accum.barren_run = @intCast(result.cur_zero_run);
        }

        // B-3d (doc 17 §B3.16 D4): the terminal-resume check is MEASURED, and
        // stronger than the ring-successor assert it replaced. The claimed terminal
        // cell must literally own the final call-global ordinal: the epilogue stamps
        // `last_ordinal = transitions + 1` and then increments the transition count,
        // and silence cannot resume after a reporting row, so for ANY interleaving
        // of set edges the last fired cell's ordinal equals the transition total.
        // (The ring assert validated phase reconstruction; this validates the
        // measurement the resume contract is actually derived from.) Must run
        // BEFORE the mailbox clear below — it reads the summary image.
        if (last_set.summary[last_phase].last_ordinal != result.silent_transitions)
            @panic("driveSilentBurst: terminal cell does not own the final ordinal");

        // Summary cells are a per-call mailbox. Native only adds; the driver
        // clears after consuming the complete image. EVERY live set is cleared,
        // not just the entry one — a second live set that fused into this call
        // would otherwise re-apply its work on its own next drain.
        for (self.promoted_sets.items) |*c|
            @memset(c.summary, std.mem.zeroes(nativegen.SilentSummaryCell));
        self.silent_bursts_drained +|= 1;
        self.silent_transitions_total +|= result.silent_transitions;
        self.silent_hops_total +|= result.silent_transitions;

        const last_edge = last_set.edges[last_phase];
        if (result.silent_cum > std.math.maxInt(usize))
            @panic("driveSilentBurst: silent cumulative count exceeds usize");
        if (result.ledger_len > 0) {
            // Capture while the complete physical arm registry is still intact;
            // replay may queue its teardown. Application remains deferred until
            // the caller merges this with prefix evidence after the walk.
            self.stageSilentSuffixProvenance(
                self.ledger_scratch[0..result.ledger_len],
                @intCast(result.silent_cum),
            );
            self.dbgNoteSuffixLedger(self.ledger_scratch[0..result.ledger_len]);
            self.silent_suffix_drains +|= 1;
            var suffix_init = SuffixInit{
                .cont = last_edge.parent,
                .link_pc = last_edge.resume_pc,
                .prev_cum = @intCast(result.silent_cum),
                .next_entry = .ordinary,
            };
            // Reconstruct exactly the cursor transformation the suppressed final
            // reporting row would have made, including bridge/handoff provenance.
            applyEdgeCursorTransition(
                &suffix_init,
                last_edge.arm_kind,
                last_edge.parent,
                last_edge.child,
                last_edge.resume_pc,
                @intCast(last_edge_local),
                resume_pc,
            );
            return self.replayLedgerSuffix(
                self.ledger_scratch[0..result.ledger_len],
                suffix_init,
                proto,
                linked_completed,
                resume_pc,
                hops,
                max_hops,
                origin,
                safe_to_arm,
                regs,
            );
        }
        if (!budget_exhausted and !barren_exhausted)
            @panic("driveSilentBurst: rowless silent result exhausted no budget");
        if (budget_exhausted) self.silent_budget_exhaustions +|= 1;
        resume_pc.* = last_edge.resume_pc;
        return .{ .return_result = .{
            .completed = @intCast(result.silent_cum),
            .resume_pc = last_edge.resume_pc,
        } };
    }

    /// Universal single-branch drain used immediately after every native call.
    pub fn drainSilentResult(
        self: *TraceState,
        result: irinterp.ExecResult,
        origin: ReplayOrigin,
        proto: *const Proto,
        linked_completed: *usize,
        resume_pc: *u32,
        hops: *usize,
        max_hops: usize,
        safe_to_arm: bool,
        regs: ?RegWindow,
    ) ?LedgerReplay {
        if (result.silent_active == 0) return null;
        return self.driveSilentBurst(
            result,
            proto,
            linked_completed,
            resume_pc,
            hops,
            max_hops,
            origin,
            safe_to_arm,
            regs,
        );
    }

    pub fn captureSilentSuffixProvenance(
        self: *TraceState,
        result: irinterp.ExecResult,
        out: []ProvenanceVerdict,
    ) usize {
        if (result.silent_active == 0) return 0;
        if (result.ledger_len > irinterp.LEDGER_CAP)
            @panic("silent suffix provenance: ledger exceeds cap");
        if (result.silent_cum > std.math.maxInt(usize))
            @panic("silent suffix provenance: cumulative count exceeds usize");
        var n: usize = 0;
        for (self.silent_provenance[0..self.silent_provenance_len]) |prefix| {
            const action: ?ProvenanceAction = if (prefix.saw_productive)
                .reset
            else if (prefix.saw_return_without_progress)
                .strike
            else
                null;
            if (action) |a| {
                if (n == out.len)
                    @panic("captureSilentSuffixProvenance: verdict capacity exceeded");
                out[n] = .{
                    .parent_id = prefix.parent_id,
                    .exit_instr = prefix.exit_instr,
                    .child_id = prefix.child_id,
                    .action = a,
                };
                n += 1;
            }
        }
        self.silent_provenance_len = 0;
        return n;
    }

    pub const NativeCallProvenance = struct {
        verdicts: [PROVENANCE_VERDICT_CAP]ProvenanceVerdict = undefined,
        len: usize = 0,
    };

    pub const NativeCallOrigin = enum {
        dispatcher_root,
        drive_chain_seed,
        inner_call,
        continuation_call,
    };

    /// One provenance capture contract for every native-call origin. For an
    /// ordinary call this MUST run before replay can mutate the arm registry;
    /// for a silent call it runs after `driveSilentBurst` has staged the prefix
    /// and suffix evidence. The matching settle runs exactly once after deferred
    /// disarms and before any replay directive can re-enter native code.
    /// Fills CALLER-OWNED storage rather than returning the aggregate by value.
    /// `verdicts` is capacity-sized, so an aggregate return lowers to a full
    /// memcpy of the array on every native entry — including the overwhelmingly
    /// common case that captures nothing. Measured on scimark-lu at this
    /// revision: `memcpyFast` was 4.04% of the run, 3.94% of it reached through
    /// this function. The out-param is the whole fix; the body is unchanged.
    pub fn captureNativeCallProvenance(
        self: *TraceState,
        origin: NativeCallOrigin,
        result: irinterp.ExecResult,
        entries: []const irinterp.LedgerEntry,
        captured: *NativeCallProvenance,
    ) void {
        _ = origin; // Required at each call site so origin coverage cannot hide.
        captured.len = if (result.silent_active != 0)
            self.captureSilentSuffixProvenance(result, &captured.verdicts)
        else
            self.captureProvenanceVerdicts(entries, 0, &captured.verdicts);
    }

    pub fn settleNativeCallProvenance(
        self: *TraceState,
        captured: *const NativeCallProvenance,
        safe_to_arm: bool,
    ) void {
        self.applyPendingDisarms();
        self.applyProvenanceVerdicts(captured.verdicts[0..captured.len]);
        self.drainPendingBridgeArm(safe_to_arm);
        self.drainProvenanceArms(safe_to_arm);
    }

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
    pub fn replayLedger(
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
        regs: ?RegWindow,
    ) LedgerReplay {
        var frozen_fast: ?FrozenFast = null;
        if (self.region_context) |rctx| {
            if (self.activeRegionFor(rctx.call_seq)) |akey| {
                if (self.region_profit.getPtr(akey)) |accum| {
                    if (accum.frozen) frozen_fast = .{ .key = akey, .accum = accum };
                }
            }
        }
        var cursor = ReplayCursor{
            .cont = seed_owner,
            .link_pc = inner_pc,
            .prev_cum = 0,
            .next_entry = .ordinary,
            .frozen_fast = frozen_fast,
            .check_seed = true,
        };
        return self.replayLedgerFrom(entries, &cursor, seed_owner, proto, linked_completed, resume_pc, hops, max_hops, origin, safe_to_arm, regs);
    }

    pub fn replayLedgerSuffix(
        self: *TraceState,
        entries: []const irinterp.LedgerEntry,
        suffix_init: SuffixInit,
        proto: *const Proto,
        linked_completed: *usize,
        resume_pc: *u32,
        hops: *usize,
        max_hops: usize,
        origin: ReplayOrigin,
        safe_to_arm: bool,
        regs: ?RegWindow,
    ) LedgerReplay {
        const seed_owner = self.traceById(entries[0].id) orelse
            @panic("replayLedgerSuffix: first entry owner id did not resolve");
        var frozen_fast: ?FrozenFast = null;
        if (self.region_context) |rctx| {
            if (self.activeRegionFor(rctx.call_seq)) |akey| {
                if (self.region_profit.getPtr(akey)) |accum| {
                    if (accum.frozen) frozen_fast = .{ .key = akey, .accum = accum };
                }
            }
        }
        var cursor = ReplayCursor{
            .cont = suffix_init.cont,
            .link_pc = suffix_init.link_pc,
            .prev_cum = suffix_init.prev_cum,
            .next_entry = suffix_init.next_entry,
            .frozen_fast = frozen_fast,
            .check_seed = false,
        };
        return self.replayLedgerFrom(entries, &cursor, seed_owner, proto, linked_completed, resume_pc, hops, max_hops, origin, safe_to_arm, regs);
    }

    fn replayLedgerFrom(
        self: *TraceState,
        entries: []const irinterp.LedgerEntry,
        cursor: *ReplayCursor,
        seed_owner: *Trace,
        proto: *const Proto,
        linked_completed: *usize,
        resume_pc: *u32,
        hops: *usize,
        max_hops: usize,
        origin: ReplayOrigin,
        safe_to_arm: bool,
        regs: ?RegWindow,
    ) LedgerReplay {
        // `ledger_len` is always ≥1 (every native exit appends exactly once) and ≤CAP
        // (the append is bounds-guarded; the forced-yield cap keeps a closed cycle
        // under CAP). Release-guard both so `entries[k]` is never OOB even if that
        // invariant were ever violated upstream.
        if (entries.len == 0 or entries.len > irinterp.LEDGER_CAP)
            @panic("replayLedger: ledger length outside [1, LEDGER_CAP]");
        // A-vii-d.1: never inherit a bridge-arm request from a previous ledger.
        self.pending_bridge_arm = null;
        // Seam timing (diagnostic, `--jit-stats` only): bracket the OUTERMOST walk
        // so `cycles_seam` splits the traced bucket into native-vs-steering. A
        // `seam_t0` of 0 doubles as the "not bracketed" sentinel (coverage off,
        // nested walk, or no TSC on this target — all cases where we skip).
        const seam_t0: u64 = if (self.config.coverage and self.replay_walk_depth == 0)
            readCycles()
        else
            0;
        // A-vii-d.1: defer any `disarmAllLinks` for the duration of the walk
        // (see `replay_walk_depth`); the driver applies it right after.
        self.replay_walk_depth += 1;
        defer {
            self.replay_walk_depth -= 1;
            if (seam_t0 != 0) {
                self.cycles_seam +|= cycleDelta(readCycles(), seam_t0);
                self.seam_walks +|= 1;
            }
        }

        // Running cursors as the graph is walked:
        //   `cont`    — the continuation whose anchor is the coherent resume for a
        //               terminal inner loop-done (init: the seed; updated when a fused
        //               `I→C` edge dispatches into the next continuation).
        //   `link_pc` — the inner-root PC named by the most-recent `.link` marker, i.e.
        //               where tier-0 resumes if an inner mid-loop-deopts (init: the
        //               seed's `inner_pc`).
        //   `prev_cum`— `cum` of the previous entry, for per-segment `local` deltas
        //               (`cum[-1] == 0`, the trampoline-zeroed call-start `rbx`).
        // Part S: set by the sibling-handoff production for the row that FOLLOWS a
        // fused handoff — that row's owner was entered at its ordinary (anchor)
        // entry, exactly like a bridged successor, so its terminal contract is the
        // coherent-anchor discipline and NEVER the linked C⇄I grammar's `link_pc`.
        // Measured before this existed: a burst that mixed `.link_terminal` rows
        // with a later handoff ping-pong terminal-resumed at the stale inner-root
        // `link_pc`, so tier-0 fell out of the finished inner loop and advanced the
        // middle induction variable PAST the in-flight iteration — dropping exactly
        // one count per sieve rep (A-viii 108 vs 109; the missing prime is 307, the
        // first zero-trip of the inner loop).

        // Freeze-after-qualify (task #70): resolve the live activation ONCE per
        // burst. If it is FROZEN (a run of useful windows with no strike), member→
        // member ledger rows below are priced through the direct-credit fast path —
        // no classifyExit, no chooseSource, no destination hashing. The `accum`
        // pointer stays valid across the loop because the fast path never mutates
        // `region_profit` (`flushRegionWindow` is documented not to), and the latch
        // is dropped the moment any row takes the slow path (which may open/close
        // activations) or a barren-run strike unfreezes the accumulator.
        // NOTE (seam round 2): serving this from the shared `act_cache` slot
        // (refreshActCache) was tried and MEASURED SLOWER (~+50 cyc/walk on
        // nsieve N=7, +2% wall) than the direct derivation below — the map has
        // 1–2 entries, so the iteration is cheaper than the extra layout/branch
        // cost the shared path added. Keep the direct form.
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
            const entry_materialization: EntryMaterialization = if (k > 0 and entries[k - 1].kind == .region_bridge)
                .via_bridge
            else
                cursor.next_entry;
            // Entry provenance is consumed by exactly one successor row.
            cursor.next_entry = .ordinary;
            const entered_via_bridge = switch (entry_materialization) {
                .via_bridge => true,
                else => false,
            };
            const entered_via_handoff = switch (entry_materialization) {
                .via_handoff => true,
                else => false,
            };
            const ordinary_guard_entry: ?OrdinaryGuardEntry = switch (entry_materialization) {
                .via_ordinary_guard => |entry| entry,
                else => null,
            };
            const owner = self.traceById(e.id) orelse
                @panic("replayLedger: entry owner id did not resolve");
            self.dbgNoteReplayRow(owner, e.exit);
            self.dbg("  row k={d} id={d} kind={s} exit={d} cum={d} outcome={s}", .{
                k, e.id, @tagName(e.kind), e.exit, e.cum, @tagName(e.outcome),
            });
            // First owner must be the seed (call B enters `seed_owner` directly).
            if (cursor.check_seed and k == 0 and owner != seed_owner)
                @panic("replayLedger: first ledger owner is not the seed");
            // `cum` is monotonic non-decreasing (the enclosing counter only grows).
            if (e.cum < cursor.prev_cum)
                @panic("replayLedger: ledger cum decreased");
            // A forced yield can only be the LAST entry of a FULL ledger — an armed
            // chain source that saw `ledger_len >= LEDGER_CAP` jumped to `shared_exit`
            // instead of its successor, so nothing follows it AND the ledger is exactly
            // at CAP (the append is bounds-guarded, so it never exceeds CAP).
            if (e.outcome == .yielded and !(is_last and entries.len == irinterp.LEDGER_CAP))
                @panic("replayLedger: forced-yield entry is not the last of a full ledger");
            const row_local = e.cum - cursor.prev_cum;

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
            // Part S: is THIS row a fused sibling handoff? Resolved here, before the
            // region receipt, because the handoff changes that receipt's destination
            // (below) — and because the `.deopt` arm must agree with it exactly.
            // Armed-edge provenance only, never position or opcode.
            const sibling_succ: ?*Trace = if (!is_last and e.kind == .deopt and
                e.reason == .normal and e.outcome == .normal and e.exit < owner.instrs.len)
            blk: {
                const sib = self.traceById(entries[k + 1].id) orelse break :blk null;
                break :blk if (self.hasArmedSiblingHandoff(owner, e.exit, sib)) sib else null;
            } else null;

            // A suppressed M1 source row and its ramp successor form one replay
            // production. Terminal ramp failures have no independent region row;
            // a ramp sibling handoff does, but reporting deliberately carries the
            // source row's local delta into it by not advancing `prev_cum`.
            if (ordinary_guard_entry) |m1| switch (e.kind) {
                .deopt => {
                    if (!ends_link or e.reason != .normal or e.outcome != .normal or row_local != 0)
                        @panic("replayLedger: silent M1 ramp deopt violates static contract");
                    if (sibling_succ == null) {
                        if (!is_last)
                            @panic("replayLedger: silent M1 terminal ramp deopt is not last");
                        self.onSideExit(owner, 0, .entered);
                        resume_pc.* = m1.parent.anchor.pc;
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = m1.parent.anchor.pc,
                        } };
                    }
                },
                .prologue_fail => {
                    if (!(is_last and ends_link and e.reason == .prologue_fail and
                        e.exit == std.math.maxInt(u32) and e.outcome == .normal and row_local == 0))
                        @panic("replayLedger: silent M1 ramp prologue-fail violates terminal contract");
                    self.onSideExit(owner, 0, .entry_refusal);
                    resume_pc.* = m1.parent.anchor.pc;
                    return .{ .return_result = .{
                        .completed = linked_completed.*,
                        .resume_pc = m1.parent.anchor.pc,
                    } };
                },
                // Doc 22 §B.2 (B-iv): the silent M1 ramp is a seeded page whose
                // entry seeding declined pre-commit. Same routing as the ramp
                // prologue-fail above MINUS all accounting (no `onSideExit`, no
                // strike, no receipt): a decline is an entry-condition mismatch,
                // not a guard failure. Selection resumes at the M1 parent's
                // anchor exactly like the prologue-fail replay; a re-selection
                // of the decliner takes the dispatcher's direct-entry decline
                // handlers (H1 downgrade / next-candidate).
                .seed_hash_decline, .seed_capacity_decline => {
                    const reason_matches = (e.kind == .seed_hash_decline and
                        e.reason == .seed_hash_decline) or
                        (e.kind == .seed_capacity_decline and
                            e.reason == .seed_capacity_decline);
                    if (!(is_last and ends_link and reason_matches and
                        e.exit == std.math.maxInt(u32) and e.outcome == .normal and row_local == 0))
                        @panic("replayLedger: silent M1 ramp seed-decline violates terminal contract");
                    if (e.kind == .seed_hash_decline)
                        self.seed_hash_declines +|= 1
                    else
                        self.seed_capacity_declines +|= 1;
                    resume_pc.* = m1.parent.anchor.pc;
                    return .{ .return_result = .{
                        .completed = linked_completed.*,
                        .resume_pc = m1.parent.anchor.pc,
                    } };
                },
                .link_terminal => {},
                else => @panic("replayLedger: silent M1 successor has an invalid row kind"),
            };
            const local = if (ordinary_guard_entry != null and sibling_succ != null)
                ordinary_guard_entry.?.source_local
            else
                row_local;
            const region_work: usize = switch (e.kind) {
                .loop_done_linked => 1,
                .deopt => local,
                .link_terminal, .prologue_fail, .region_bridge => 0,
                // Doc 22 §B.2: declines happen before the body runs — zero work.
                .seed_hash_decline, .seed_capacity_decline => 0,
            };

            // Destination `.deferred` for a handoff, NEVER `.known_trace`: this edge is
            // deliberately absent from the structural graph (it is same-anchor), so
            // letting `applyDestination` see the successor could close/open activations
            // and reproduce the §A8-v cross-credit pathology.
            const region_dest: RegionDestination = if (sibling_succ != null)
                .deferred
            else if (!is_last)
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
            // Freeze-after-qualify fast path (task #70): a frozen activation's
            // member→member row is credited directly — the same accounting effects
            // `accountRegionProfit`'s member paths would have applied (credit /
            // barren-consume against the live accumulator), minus the per-row
            // classify/choose/destination hash pipeline. Departure shapes (a
            // successor outside the footprint, a terminal-outside destination, a
            // keyless row) fall through to the full pipeline, which owns region
            // lifecycle; after any slow row the burst latch is dropped because
            // `applyDestination` may have mutated `region_profit`.
            var region_consumed = false;
            var fast_done = false;
            if (cursor.frozen_fast) |ff| fast: {
                if (region_key == null) break :fast;
                if (!self.traceRegionMemberMemo(owner, ff.key.region_id)) break :fast;
                switch (region_dest) {
                    .deferred => {},
                    .known_trace => |succ_id| {
                        const succ = self.traceById(succ_id) orelse break :fast;
                        if (!self.traceRegionMemberMemo(succ, ff.key.region_id)) break :fast;
                    },
                    .terminal_outside => break :fast,
                }
                region_consumed = true;
                fast_done = true;
                if (region_work != 0)
                    self.creditRegionWork(ff.key, ff.accum, region_work)
                else
                    self.noteBarrenConsumed(ff.key, ff.accum);
                // A barren-run strike inside `noteBarrenConsumed` unfreezes; stop
                // fast-pathing the rest of the burst the moment that happens.
                if (!ff.accum.frozen) cursor.frozen_fast = null;
            }
            if (!fast_done) {
                region_consumed = self.accountRegionProfit(region_key, region_work, region_dest);
                // A keyless receipt is a documented no-op (`key orelse return
                // false`) — it cannot have touched `region_profit`, so the burst
                // latch survives it. Any other slow row may have open/closed an
                // activation through `applyDestination`; drop the latch.
                if (region_key != null) cursor.frozen_fast = null;
            }

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
                    const edge = self.validateRegionBridgeReceipt(owner, e.exit, succ) catch |err| switch (err) {
                        error.NotComposite => @panic("replayLedger: region_bridge exit is not a composite guard"),
                        error.WrongArmKind => @panic("replayLedger: region_bridge row matched a non-bridge armed link"),
                        error.NoArmedProvenance => @panic("replayLedger: region_bridge has no armed provenance"),
                        error.NoRegionProvenance => @panic("replayLedger: region_bridge armed link has no region provenance"),
                        error.NoExitProvenance => @panic("replayLedger: region_bridge exit has no provenance"),
                        error.RegionMissing => @panic("replayLedger: region_bridge armed region no longer exists"),
                        error.RegionTombstoned => @panic("replayLedger: region_bridge edge is tombstoned"),
                        error.DuplicateEdge => @panic("replayLedger: duplicate region_bridge edge"),
                        error.EdgeMissing => @panic("replayLedger: region_bridge edge is not registered"),
                        error.SuccessorMismatch => @panic("replayLedger: region_bridge successor mismatches registered edge"),
                    };

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
                    accountCandidateCharge(owner, .entered);
                    self.native_region_bridge_fused +|= 1;
                    applyEdgeCursorTransition(cursor, .region_bridge, owner, succ, edge.succ_anchor_pc, local, resume_pc);
                },
                .link_terminal => {
                    // A continuation reached its single-contract `.link` terminal.
                    if (!(e.reason == .normal and ends_link and e.exit == owner.instrs.len - 1))
                        @panic("replayLedger: link_terminal entry is not owner's .link");
                    if (ordinary_guard_entry != null) {
                        if (row_local != 0)
                            @panic("replayLedger: M1 ramp link committed iterations");
                        self.prime_side_chain_follows +|= 1;
                    }
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
                        //
                        // 2c-E site 4 (arming convergence, `.link` edition): mirror
                        // site 3's terminal loop-done arm — a terminal `.link` means
                        // this C→I edge was NOT fused, so arm it now and the next
                        // occurrence dispatches natively. Resolve the inner by the
                        // SAME `findLoopTrace` pick the hop top re-resolution uses, so
                        // the armed target is the sibling selection would choose; every
                        // shape/eligibility gate lives in the fail-closed helper. On a
                        // forced yield the slot is already armed and the identical
                        // re-arm SHORT-CIRCUITS at the `armNativeLink` funnel (B-3d.1
                        // R6, doc 17 §B3.18): no slot mutation, and — decisive since
                        // B-3b — no demotion of a promoted set that owns this exit.
                        if (self.findLoopTrace(proto, owner_inner_pc)) |inner_pick|
                            self.armLinkTerminal(owner, inner_pick, safe_to_arm);
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
                    // B-iv.3 (doc 22 §B.5): seeded successors are newly admitted
                    // (isInnerLoopRoot no longer rejects them), but only under the
                    // rule — the fused span DID dispatch into this successor's
                    // `linked_entry`, so a seeded page must be stub-enterable right
                    // now (it just self-seeded this frame; a hash/capacity decline
                    // leaves enterability intact). Zero-input successors keep the
                    // pre-B-iv shape-only contract (widened with the rule, never
                    // narrowed: real fused rows always have compiled successors,
                    // but the seed-freshness proof only exists for seeded pages).
                    if (succ.inputs.len != 0 and !self.stubEnterable(succ, .linked, proto))
                        @panic("replayLedger: fused seeded successor is not stub-enterable");
                    // 2c-E: a fused `C.link → I` edge IS a continuation→inner follow —
                    // the same event the physical call-A hop top charges via its
                    // follow counters. Charge it here so a `run_continuation` handover
                    // that SKIPS call A (`start_at_continuation`) stays
                    // accounting-exact with the unfused decomposition.
                    self.native_link_follow_count +|= 1;
                    self.link_follow_count +|= 1;
                    // Advance the link cursor; the `.link` marker itself takes no
                    // `onSideExit` (only the bodies that commit iterations do).
                    applyEdgeCursorTransition(cursor, .link_terminal, owner, succ, owner_inner_pc, local, resume_pc);
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
                    self.accountLedgerRow(owner, if (local > 0) local else 1, std.math.maxInt(u32), region_consumed, .entered);
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
                        // B-4 (§B4.3 D2'/D4'): ONE canonical positional selection
                        // per terminal event. The burst's entry path (`cursor.cont`)
                        // is irrelevant to coherence — regs are coherent at
                        // `post_pc` because the final iteration's stores + phi
                        // snapshot committed LINKED, so the ONLY sound question is
                        // "which P-G-eligible, native-runnable continuation is
                        // anchored there". Before B-4 this site (and the arm below)
                        // considered only `cursor.cont`; a burst entering through a
                        // guard-chained composite therefore break_burst'ed on EVERY
                        // inner-loop completion (27,554/run on nsieve-bit 6) even
                        // though an eligible continuation sat in the cache at
                        // `post_pc`. The selector probes the arm-ranked candidate
                        // first (canonical lazy-compile order, D4'), then the
                        // regs-ranked run target over the same list.
                        const sel = self.resolveLoopDoneCont(proto, post_pc, regs);
                        // 2c-E site 3 (arming CONVERGENCE): a TERMINAL loop-done means
                        // this `I→C` edge was NOT fused — the slot is unarmed (or a
                        // forced yield steered around it, in which case the identical
                        // re-arm SHORT-CIRCUITS at the `armNativeLink` funnel — B-3d.1
                        // R6, doc 17 §B3.18: no slot mutation, no demotion of a
                        // promoted set that owns this exit). Arm the CANONICAL target
                        // now so the NEXT occurrence of this exit fuses. Runs BEFORE
                        // the hop budget check — the scalar site (call A) also arms
                        // on the burst's last hop.
                        if (safe_to_arm) if (sel.arm) |arm_target|
                            self.armLoopDoneLinkTo(owner, e.exit, post_pc, arm_target);
                        // The burst may re-run the still-armed continuation. The hop
                        // budget only declines THIS next re-run.
                        if (hops.* >= max_hops) return .{ .break_burst = .entered };
                        // The directive EXECUTES the run target. Selection already
                        // proved P-G eligibility AND native runnability (§B4.7
                        // BLOCKER: an `.unsupported` candidate never reaches here),
                        // and a fingerprint-mismatching target is safe to attempt —
                        // the native prologue fails closed pre-commit with regs
                        // still coherent at `post_pc`. No eligible runnable
                        // continuation at all → fall back to tier-0 at `post_pc`
                        // (`resume_pc` is already set) — the same safe directive
                        // the hop-budget bound above takes.
                        if (sel.run) |run_target|
                            return .{ .run_continuation = run_target };
                        self.dbg("terminal loop-done: no eligible continuation at post_pc={d} -> break_burst", .{
                            post_pc,
                        });
                        if (comptime jitdbg.enabled) {
                            // Diagnostic sub-report: WHY each same-pc candidate was
                            // rejected (anchored-here traces that failed the P-G
                            // predicate or the runnability probe).
                            for (self.cache.items) |t| {
                                if (t.anchor.proto != proto or t.anchor.pc != post_pc) continue;
                                const tail_link = t.instrs.len != 0 and t.instrs[t.instrs.len - 1].op == .link;
                                self.dbg("  candidate id={d}: inputs={d} tail_link={} native={s}", .{
                                    t.id, t.inputs.len, tail_link, @tagName(t.native),
                                });
                            }
                        }
                        return .{ .break_burst = .entered };
                    }
                    // `I→C` fused (2.3c-2e): the next entry is the continuation reached
                    // via the loop-done→ordinary_entry arm. Validate the successor is a
                    // `.link` continuation anchored at this inner's post-loop PC.
                    const succ = self.traceById(entries[k + 1].id) orelse
                        @panic("replayLedger: fused continuation id did not resolve");
                    if (!(succ.instrs.len != 0 and
                        succ.instrs[succ.instrs.len - 1].op == .link and
                        succ.anchor.proto == proto and succ.anchor.pc == post_pc))
                        @panic("replayLedger: fused successor is not the expected continuation");
                    // B-iv.3 (doc 22 §B.5): seeded continuations are newly admitted
                    // (the `inputs.len == 0` shape clause is gone), but only under
                    // the rule — the loop-done arm dispatched into this
                    // continuation's `ordinary_entry`, so a seeded page must be
                    // stub-enterable right now (it just self-seeded this frame).
                    // Zero-input continuations keep the pre-B-iv shape-only
                    // contract (widened with the rule, never narrowed).
                    if (succ.inputs.len != 0 and !self.stubEnterable(succ, .ordinary, proto))
                        @panic("replayLedger: fused seeded continuation is not stub-enterable");
                    // 2c-E: the armed `I.loopdone → C.ordinary_entry` edge actually
                    // fired in native code — the consumer-side proof of the arm.
                    self.native_loopdone_link_fused +|= 1;
                    applyEdgeCursorTransition(cursor, .loop_done_linked, owner, succ, post_pc, local, resume_pc);
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
                    // dispatcher's fused source-branch steering, folded into this
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
                        // Part S: the SIBLING HANDOFF production, checked before M1.
                        // Validated by armed-edge provenance exactly like
                        // `.region_bridge` (never by position, never by opcode): an
                        // armed `.sibling_handoff` link must exist for THIS
                        // (parent, exit) whose child is THIS successor. Everything
                        // the handoff needs is then implied by the arm's own
                        // preconditions (same anchor, zero inputs, non-loop-done,
                        // non-bridge slot), which `armNativeLink` enforced.
                        if (sibling_succ != null) {
                            self.sibling_handoff_fused +|= 1;
                            // Credit the parent's own committed iterations to its RUN
                            // counter — and nothing else. Emphatically NOT
                            // `accountLedgerRow`, whose legacy-thrash half applies the
                            // per-segment profitability VERDICT. Coherence permits any
                            // `local`; the historical zero-progress restriction belonged
                            // only to Part-S discovery/selection. Charging the handoff
                            // itself as an unproductive segment would add a penalty per
                            // fused hop.
                            // Measured: that mis-charge drove `pc=14` to `max_penalty`
                            // within a handful of hops, gated the anchor, and collapsed
                            // nsieve's traced time from 51% to 7.2% (an 18% wall-clock
                            // REGRESSION from a mechanism that fused 96% of bursts).
                            // A fused handoff never reaches the runtime, so — exactly
                            // like a branch taken inside native code — it must be
                            // invisible to profitability. The SIBLING's own rows carry
                            // the work and the verdict.
                            self.accountTraceRun(owner, local);
                            accountCandidateCharge(owner, .entered);
                            // The successor's `cum` continues the same counter, so the
                            // parent's iterations must leave the delta window here or
                            // the sibling's row re-counts them.
                            cursor.prev_cum = e.cum;
                            // Publish the shared anchor as the coherent resume (the
                            // exact move the `.region_bridge` arm makes) and mark the
                            // successor row anchor-entered, so a terminal deopt or
                            // prologue-fail on it resumes THERE — never at a `link_pc`
                            // left behind by earlier linked rows in the same burst.
                            applyEdgeCursorTransition(cursor, .sibling_handoff, owner, sibling_succ.?, owner.anchor.pc, local, resume_pc);
                            continue;
                        }
                        if (e.outcome != .normal)
                            @panic("replayLedger: fused M1 .deopt is a forced yield");
                        if (e.exit >= owner.instrs.len)
                            @panic("replayLedger: fused M1 .deopt exit index out of range");
                        if (!self.isSourceBranchGuardExit(owner, e.exit, proto))
                            @panic("replayLedger: fused M1 .deopt exit is not a source-branch guard");
                        const succ = self.traceById(entries[k + 1].id) orelse
                            @panic("replayLedger: fused M1 successor id did not resolve");
                        // Keyed on the EXACT exit, like `hasArmedSiblingHandoff`
                        // above — an unrolled parent (doc 38 unroll-first) carries
                        // several source-branch guards, each of which may hold its
                        // own armed link to the same successor, so "the (first)
                        // armed slot for the pair" is not unique and comparing it
                        // to `e.exit` falsely rejected legitimate fused hops.
                        if (!self.hasArmedSourceBranchLinkAt(owner, e.exit, succ, proto))
                            @panic("replayLedger: fused M1 transition has no armed source-branch link at the exit guard");
                        std.debug.assert(self.countTracesAt(owner.anchor) >= 2);
                        // The ramp commits ZERO of its OWN iterations, so its `cum`
                        // equals the skip's (`entry_rbx == skip_local`). `local` here is
                        // therefore the skip trace's own committed count, and
                        // `onSideExit(owner, local)` below reproduces the old
                        // `onSideExit(ct, skip_local)` exactly.
                        if (entries[k + 1].cum != e.cum)
                            @panic("replayLedger: fused M1 ramp committed its own iterations (cum advanced)");
                        self.native_source_link_fused +|= 1;
                        self.accountLedgerRow(owner, local, e.exit, region_consumed, .entered);
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
                            // Part S: the ramp's OWN deopt may now be an armed
                            // sibling-handoff source, in which case the burst
                            // legitimately continues past it. Hand row k+1 to the
                            // generic walk (its own production bills it) instead of
                            // treating it as this M1's terminal.
                            if (k + 2 < entries.len) {
                                if (self.traceById(entries[k + 2].id)) |nxt| {
                                    if (self.hasArmedSiblingHandoff(succ, entries[k + 1].exit, nxt))
                                        continue;
                                }
                            }
                            if (k + 2 != entries.len)
                                @panic("replayLedger: fused M1 sub-case (b) ramp deopt is not the last entry");
                            self.onSideExit(succ, 0, .entered);
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
                            self.onSideExit(succ, 0, .entry_refusal);
                            return .{ .return_result = .{
                                .completed = linked_completed.*,
                                .resume_pc = owner.anchor.pc,
                            } };
                        }
                        // Sub-case (d) (doc 22 §B.2, B-iv): the ramp is a seeded
                        // page whose entry seeding declined after the armed jump
                        // — pre-commit, so the cumulative counter is unchanged
                        // (validated above) and regs are coherent at the source
                        // trace's guard exit exactly as in sub-case (c). Same
                        // routing as (c) MINUS the `onSideExit` (no strike, no
                        // receipt, never a chain source): resume deterministic
                        // selection at the source's anchor; re-selecting the
                        // decliner takes the dispatcher's direct decline path.
                        if (entries[k + 1].kind == .seed_hash_decline or
                            entries[k + 1].kind == .seed_capacity_decline)
                        {
                            if (k + 2 != entries.len)
                                @panic("replayLedger: fused M1 sub-case (d) ramp seed-decline is not the last entry");
                            const se = entries[k + 1];
                            const reason_matches = (se.kind == .seed_hash_decline and
                                se.reason == .seed_hash_decline) or
                                (se.kind == .seed_capacity_decline and
                                    se.reason == .seed_capacity_decline);
                            if (!(reason_matches and se.exit == std.math.maxInt(u32) and
                                se.outcome == .normal))
                                @panic("replayLedger: fused M1 sub-case (d) entry violates the seed-decline contract");
                            if (!(succ.instrs.len != 0 and succ.instrs[succ.instrs.len - 1].op == .link))
                                @panic("replayLedger: fused M1 sub-case (d) ramp does not end in .link");
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
                            @panic("replayLedger: fused M1 successor is not .link_terminal (a), .deopt (b), .prologue_fail (c), or seed-decline (d)");
                        self.prime_side_chain_follows +|= 1;
                        cursor.prev_cum = e.cum;
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
                    if (e.outcome == .normal and owner.isBridgeCandidate(e.exit))
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
                    if (entered_via_bridge or entered_via_handoff) {
                        if (!(ends_link or ends_loop))
                            @panic("replayLedger: bridged successor deopt on a non-body owner shape");
                        if (resume_pc.* != owner.anchor.pc)
                            @panic("replayLedger: bridged successor deopt resume mismatches its anchor");
                        self.accountLedgerRow(owner, local, e.exit, region_consumed, .entered);
                        return .{ .return_result = .{
                            .completed = linked_completed.* + local,
                            .resume_pc = resume_pc.*,
                        } };
                    }
                    if (ends_link) {
                        // (a) continuation own guard — terminal.
                        if (local > 0) {
                            self.accountLedgerRow(owner, local, e.exit, region_consumed, .entered);
                            return .{ .return_result = .{
                                .completed = linked_completed.* + local,
                                .resume_pc = resume_pc.*,
                            } };
                        }
                        return .{ .break_burst = .entered };
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
                    self.accountLedgerRow(owner, local, e.exit, region_consumed, .entered);
                    return .{ .return_result = .{
                        .completed = if (linked_completed.* > 0) linked_completed.* else local,
                        .resume_pc = cursor.link_pc,
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
                    if (entered_via_bridge or entered_via_handoff) {
                        if (!(ends_link or ends_loop))
                            @panic("replayLedger: bridged successor prologue-fail on a non-body owner shape");
                        if (resume_pc.* != owner.anchor.pc)
                            @panic("replayLedger: bridged successor prologue-fail resume mismatches its anchor");
                        self.accountLedgerRow(owner, 0, std.math.maxInt(u32), region_consumed, .entry_refusal);
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = resume_pc.*,
                        } };
                    }
                    if (ends_link) {
                        // Seed continuation prologue-fail (local == 0): nothing committed
                        // here → break the burst (matches old scalar `c_local == 0 →
                        // break_burst`).
                        return .{ .break_burst = .entry_refusal };
                    }
                    if (!ends_loop)
                        @panic("replayLedger: prologue_fail owner is neither continuation nor inner root");
                    // Inner prologue-fail (local == 0): matches the old `fdone == false`
                    // mid-loop path — record the zero-progress side exit and resume
                    // tier-0 at the inner header, carrying any earlier chain progress.
                    self.accountLedgerRow(owner, 0, std.math.maxInt(u32), region_consumed, .entry_refusal);
                    return .{ .return_result = .{
                        .completed = if (linked_completed.* > 0) linked_completed.* else 0,
                        .resume_pc = cursor.link_pc,
                    } };
                },
                // Doc 22 §B.2 (B-iv): a fused successor's entry seeding declined
                // pre-commit. Mirrors the `.prologue_fail` arm's provenance
                // routing exactly, MINUS all accounting (`accountLedgerRow`/
                // `onSideExit` suppressed): a decline is an entry-condition
                // mismatch, never a guard failure — no strike, no receipt, no
                // chain source. The contract (codex-reviewed deviation from the
                // original §B.2 sketch) is "resume deterministic selection at
                // the decliner's coherent anchor", NOT "rerun the exact decliner
                // on tier-1a in-drain": the committed prefix is preserved in
                // `linked_completed`, tier-0 resumes at the decliner's anchor,
                // and if selection re-picks the decliner the dispatcher's
                // direct-entry handlers apply the H1 downgrade (hash) or
                // next-candidate (capacity) there.
                .seed_hash_decline, .seed_capacity_decline => {
                    const reason_matches = (e.kind == .seed_hash_decline and
                        e.reason == .seed_hash_decline) or
                        (e.kind == .seed_capacity_decline and
                            e.reason == .seed_capacity_decline);
                    if (!(reason_matches and e.exit == std.math.maxInt(u32) and
                        e.outcome == .normal and local == 0))
                        @panic("replayLedger: seed-decline entry violates its static contract");
                    if (!is_last)
                        @panic("replayLedger: seed-decline is terminal but not last");
                    if (e.kind == .seed_hash_decline)
                        self.seed_hash_declines +|= 1
                    else
                        self.seed_capacity_declines +|= 1;
                    // Bridged/handoff successor decline: the bridge/handoff row
                    // published the successor's validated anchor into
                    // `resume_pc` and regs are still coherent there (the
                    // decline fires before the body commits anything). Same
                    // validation as the bridged prologue-fail; zero-progress,
                    // resume there — never at a stale `link_pc`.
                    if (entered_via_bridge or entered_via_handoff) {
                        if (!(ends_link or ends_loop))
                            @panic("replayLedger: bridged successor seed-decline on a non-body owner shape");
                        if (resume_pc.* != owner.anchor.pc)
                            @panic("replayLedger: bridged successor seed-decline resume mismatches its anchor");
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = resume_pc.*,
                        } };
                    }
                    if (ends_link) {
                        // Seed continuation decline (local == 0): nothing
                        // committed here.
                        //
                        // TERMINAL, deliberately NOT `.break_burst`. A decline is
                        // an entry-condition mismatch, not a guard failure, and
                        // B-iv.2's contract is "no receipt, no strike".
                        // `.break_burst` is the zero-progress GUARD signal: three
                        // of its five consumers end in `onSideExit(seed, 0)`,
                        // which charges the BURST SEED — frequently not this
                        // decliner. In a `C1 → I → C2` sibling-continuation span
                        // the decliner is C2 while `seed` is C1 (or the
                        // dispatcher's entry trace), so the strike landed on an
                        // innocent trace and pushed it toward blacklisting. Every
                        // other seed decline in this function already returns
                        // chargeless; this arm was the odd one out.
                        //
                        // Resuming at the owner's anchor is sound for the same
                        // reason the linked-inner arm below gives: the decline
                        // fires BEFORE the body commits (release-asserted
                        // `local == 0` above), so regs are untouched and coherent
                        // at the entry point, which is the anchor. Where a
                        // `loop_done_linked` row already published `resume_pc`,
                        // the fused-successor validation has proven it equals the
                        // successor's anchor, so this is the same value it
                        // already held — the assert is a grammar-drift tripwire,
                        // not a behaviour change.
                        if (resume_pc.* != owner.anchor.pc and cursor.link_pc == owner.anchor.pc)
                            @panic("replayLedger: continuation seed-decline resume mismatches the decliner's anchor");
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = owner.anchor.pc,
                        } };
                    }
                    if (!ends_loop)
                        @panic("replayLedger: seed-decline owner is neither continuation nor inner root");
                    // Linked inner decline: resume at the decliner's own anchor.
                    // For the linked C⇄I grammar the most-recent `.link` names
                    // exactly that PC — release-assert the two agree so any
                    // future grammar drift fails loudly instead of misresuming.
                    if (cursor.link_pc != owner.anchor.pc)
                        @panic("replayLedger: linked inner seed-decline link_pc mismatches the decliner's anchor");
                    return .{ .return_result = .{
                        .completed = linked_completed.*,
                        .resume_pc = owner.anchor.pc,
                    } };
                },
            }
            cursor.prev_cum = e.cum;
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
        var tail_charge_kind: ChargeKind = .entered;
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
            // Every executor frame this hop pushes (call A's inner, call B's
            // continuation) is released together at the hop boundary, so a burst
            // that runs its full budget uses two frames, not two per hop. The
            // mark is hop-scoped rather than per-push because call A's `ibuf`
            // stays live until the loop-done flush far below it. Comptime-elided
            // on the native tier for the reason given at `driveChain`'s mark:
            // both push sites here are inside `tier == .ir` arms.
            const hop_mark = self.valuesMark();
            defer if (tier == .ir) self.valuesRelease(hop_mark);
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
                // B-iii (doc 22 §B.3): a seeded inner is enterable on tier-1a
                // after per-entry seeding through the episode ctx (capacity
                // decline / missing ctx → end the burst, as an unenterable
                // child). B-iv.3 (doc 22 §B.5): the NATIVE burst accepts a
                // seeded inner — its page seeds itself at entry (§B.4) and a
                // stale seed declines through the B-iv.2 call-A directive. A
                // fused result never reaches the seeding call: fusion is
                // native-only.
                if (inner.inputs.len != 0 and tier != .native_only) {
                    // A seed decline ends the burst CHARGELESS. `break` here fell
                    // into the zero-progress tail's `onSideExit(seed, 0)`, which
                    // strikes the burst SEED for a decline by the INNER. Live on
                    // hop 0 specifically (later hops carry `linked_completed >= 1`
                    // from the roll-up, so the tail's `linked_completed > 0` guard
                    // already returned neutral) — and hop 0 is the common case: a
                    // burst whose inner cannot be seeded declines on its FIRST
                    // hop, every time, so the seed took a strike per attempt.
                    // The native twin of this site returns penalty-neutral, so
                    // this also made tier-1a and native record DIFFERENT penalties
                    // from the same decline event — a real cross-mode divergence
                    // in tiering decisions, against the tail's own stated
                    // "Mode-invariant: ... no mode records a different penalty
                    // here". `resume_pc` already names the coherent resume target.
                    if (!self.seedForTier1a(inner, proto))
                        return .{ .completed = linked_completed, .resume_pc = resume_pc };
                }
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
                    self.prepareNativeEntry(); // B-3a global sweep hook: burst call A
                    iresult = int_native.runLinkedLoopDoneCapturing(regs, &self.ledger_scratch, self.silentStaging());
                    const silent_directive = self.drainSilentResult(
                        iresult,
                        .inner_call,
                        proto,
                        &linked_completed,
                        &resume_pc,
                        &hops,
                        max_hops,
                        safe_to_arm,
                        regs,
                    );
                    const call_a_entries = self.ledger_scratch[0..iresult.ledger_len];
                    var provenance: NativeCallProvenance = .{};
                    self.captureNativeCallProvenance(.inner_call, iresult, call_a_entries, &provenance);
                    if (silent_directive) |call_a_directive| {
                        self.settleNativeCallProvenance(&provenance, safe_to_arm);
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
                            .break_burst => |charge_kind| {
                                tail_charge_kind = charge_kind;
                                break :hop;
                            },
                        }
                    }
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
                            call_a_entries,
                            inner,
                            inner_pc,
                            proto,
                            &linked_completed,
                            &resume_pc,
                            &hops,
                            max_hops,
                            .inner_call,
                            safe_to_arm,
                            regs,
                        );
                        // A-vii-d.1: drain the pending bridge-arm request AFTER the
                        // walk, BEFORE acting on the directive (review blocker 5).
                        self.settleNativeCallProvenance(&provenance, safe_to_arm);
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
                            .break_burst => |charge_kind| {
                                tail_charge_kind = charge_kind;
                                break :hop;
                            },
                        }
                    }
                    // The scalar/short-ledger path has no graph replay, but it is
                    // still one native-call transaction and must consume its
                    // (normally empty) verdict before later steering can re-enter.
                    self.settleNativeCallProvenance(&provenance, safe_to_arm);
                } else {
                    ibuf = self.valuesPush(inner.instrs.len) catch break;
                    iresult = irinterp.executeCtx(.{ .heap = self.exec_heap }, inner, regs, ibuf);
                }
                // B-iv.2 (doc 22 §B.2, codex Q2): a scalar seed decline at call A —
                // the inner's direct entry (or the carried fused hop's linked
                // entry, consumed above) declined at its seed prologue before any
                // body ran. The last committed state is "outer advanced, about to
                // enter the inner at `inner_pc`", and the decline left `regs`
                // untouched — so end the burst coherently at the decliner's
                // anchor, preserving the cumulative `linked_completed`. NO
                // receipt, strike, side-exit accounting, or chain source; in
                // particular this must NOT reach the zero-progress tail's
                // `onSideExit(seed, 0)` (the decline is not the seed's failure).
                // Fused spans DEEPER than the carried scalar (`ledger_len > 1`)
                // never reach here — the call-A drain above hands them to
                // `replayLedger`, whose terminal seed-decline arm owns them.
                // (Tier-1a never takes this: its seeding happens at the hop-top
                // `seedForTier1a`, and its hash guards side-exit in-body.)
                if (iresult.exit_reason == .seed_hash_decline or
                    iresult.exit_reason == .seed_capacity_decline)
                {
                    return .{ .completed = linked_completed, .resume_pc = inner_pc };
                }
                if (iresult.exit_instr == std.math.maxInt(u32)) {
                    self.onSideExitReceipt(
                        inner,
                        0,
                        iresult.exit_instr,
                        0,
                        .deferred,
                        if (iresult.exit_reason == .prologue_fail) .entry_refusal else .entered,
                    );
                    break;
                }
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
                const numeric_done = inner_exit_pc >= 1 and
                    proto.code[guardSourcePc(inner_guard).?].op == .for_loop;
                // Doc 38: the while twin. The post-loop pc for a while-done is the
                // condition branch's jump target — NOT `inner_exit_pc`, which is
                // the loop-body start (inside the loop).
                const while_post: ?u32 = if (numeric_done) null else whileLoopDonePostPc(inner, iresult.exit_instr);
                const loop_done = numeric_done or while_post != null;
                const post_pc: u32 = if (numeric_done) inner_exit_pc else while_post orelse 0;
                if (!loop_done) {
                    if (inner_local > 0) {
                        self.onSideExitReceipt(inner, inner_local, iresult.exit_instr, 0, .deferred, .entered);
                        return .{
                            .completed = if (linked_completed > 0) linked_completed else inner_local,
                            .resume_pc = resume_pc,
                        };
                    }
                    self.onSideExitReceipt(inner, 0, iresult.exit_instr, 0, .deferred, .entered);
                    break;
                }
                // Native committed the loop-done inside `runLinkedLoopDone`; the
                // tier-1a path still owes the final-iteration flush. Doc 38: a
                // while-done owes NO flush on either tier — its condition guard
                // fails at the trace top, before the final pass ran any body.
                if (tier == .ir and numeric_done) {
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
                if (current_link.anchor.pc != post_pc) {
                    const cont = self.findLinkTrace(proto, post_pc) orelse {
                        self.onSideExitReceipt(inner, if (inner_local > 0) inner_local else 1, iresult.exit_instr, 1, .deferred, .entered);
                        return .{ .completed = linked_completed + 1, .resume_pc = post_pc };
                    };
                    if (tier == .native_only) {
                        snt = self.nativeFor(cont) orelse {
                            self.onSideExitReceipt(inner, if (inner_local > 0) inner_local else 1, iresult.exit_instr, 1, .deferred, .entered);
                            return .{ .completed = linked_completed + 1, .resume_pc = post_pc };
                        };
                    }
                    current_link = cont;
                }
                resume_pc = current_link.anchor.pc;

                // Roll-up (doc 15 P3): the inner root running to its loop-done
                // exit completes exactly one enclosing-loop iteration — true even
                // when it reports `completed == 0` (a one-trip inner loop). It is
                // a successful hand-off, not a low-yield entry to penalize.
                self.onSideExitReceipt(inner, if (inner_local > 0) inner_local else 1, iresult.exit_instr, 1, .{ .known_trace = current_link.id }, .entered);
                linked_completed += 1;

                // 2.3b-1: arm `current_link`'s `.link`-terminal slot → `inner`'s
                // `linked_entry`, so the NEXT run of `current_link` `jmp`s straight
                // into `inner` under the shared frame — the continuation→inner hop
                // fuses into one native call, no ~600 ns Zig re-entry. Gated on:
                //  - native tier (tier-1a has no slots);
                //  - `safe_to_arm` (no safepoint-line/suspend recording — an armed
                //    hop erases the 8-hop observation boundary, doc 17 must-fix);
                //  - `stubEnterable(inner, .linked)` (B-iv.3: the page prologue
                //    owns the seeding, so a seeded inner is armable when its
                //    episode ctx is fresh — the bare `jmp` lands on a
                //    self-seeding entry);
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
                if (tier == .native_only and safe_to_arm and
                    self.stubEnterable(inner, .linked, proto) and
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
                    self.armLoopDoneLink(inner, iresult.exit_instr, safe_to_arm);
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
                self.prepareNativeEntry(); // B-3a global sweep hook: burst call B
                var cresult = snt.runCapturingLedger(regs, &self.ledger_scratch, self.silentStaging());
                while (true) {
                    const silent_directive = self.drainSilentResult(
                        cresult,
                        .continuation_call,
                        proto,
                        &linked_completed,
                        &resume_pc,
                        &hops,
                        max_hops,
                        safe_to_arm,
                        regs,
                    );
                    const entries = self.ledger_scratch[0..cresult.ledger_len];
                    // Ordinary capture happens before replay; silent capture happens
                    // after the drain has staged its prefix/suffix evidence.
                    var provenance: NativeCallProvenance = .{};
                    self.captureNativeCallProvenance(.continuation_call, cresult, entries, &provenance);
                    const call_b_directive = silent_directive orelse self.replayLedger(
                        entries,
                        current_link,
                        inner_pc,
                        proto,
                        &linked_completed,
                        &resume_pc,
                        &hops,
                        max_hops,
                        .continuation_call,
                        safe_to_arm,
                        regs,
                    );
                    // A-vii-d.1: drain the pending bridge-arm request AFTER the
                    // walk, BEFORE acting on the directive (review blocker 5).
                    self.settleNativeCallProvenance(&provenance, safe_to_arm);
                    switch (call_b_directive) {
                        // Re-run the carried continuation for the next fused span.
                        // P1a: re-resolve its native compilation (a `C1 → I → C2`
                        // sibling swap makes `c != current_link`); never reuse the old
                        // `snt`. On the same-C nsieve cycle `c == current_link` and
                        // `nativeFor(c) == snt`, so this is byte-identical.
                        .run_continuation => |c| {
                            current_link = c;
                            snt = self.nativeFor(c) orelse break :hop;
                            self.prepareNativeEntry(); // call-B rerun is another entry
                            cresult = snt.runCapturingLedger(regs, &self.ledger_scratch, self.silentStaging());
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
                        .break_burst => |charge_kind| {
                            tail_charge_kind = charge_kind;
                            break :hop;
                        },
                    }
                }
            } else {
                // Tier-1a never fuses (no slots), so `execute` is always the
                // continuation's OWN single-exit result — replay the scalar terminal
                // exactly as before (no ledger to consume).
                // B-iii (doc 22 §B.3): a seeded driver (admitted by the side-walk
                // seeding) is RE-seeded before every re-execution — per-entry
                // re-resolution is the dispatcher's contract, and each hop is one
                // more entry. A capacity decline mid-burst ends the burst, as an
                // unenterable driver.
                // Penalty-neutral, like the native twin's `.return_result` decline
                // and like call A's above. NOT a behaviour fix here, deliberately
                // stated: the `break` this replaces was ALREADY neutral, but only
                // by a non-local accident. Reaching call B on tier-1a requires
                // call A's loop-done roll-up (`start_at_continuation` is set at
                // four sites, all `.native_only`), so `linked_completed >= 1` here
                // and the zero-progress tail's `onSideExit(seed, 0)` was
                // unreachable via its `linked_completed > 0` guard. Returning
                // directly makes the chargelessness a property of THIS site
                // instead of an invariant two hundred lines away that a future
                // `start_at_continuation` on the IR tier would silently break.
                if (current_link.inputs.len != 0 and !self.seedForTier1a(current_link, proto))
                    return .{ .completed = linked_completed, .resume_pc = resume_pc };
                const cbuf = self.valuesPush(current_link.instrs.len) catch break;
                const cresult = irinterp.executeCtx(.{ .heap = self.exec_heap }, current_link, regs, cbuf);
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
                    self.onSideExitReceipt(current_link, cresult.completed, cresult.exit_instr, cresult.completed, .deferred, .entered);
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
        self.onSideExit(seed, 0, tail_charge_kind);
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
    fn noteDispatcherLedgerTerminal(
        self: *TraceState,
        entries: []const irinterp.LedgerEntry,
        first_prev_cum: usize,
        proto: *const Proto,
    ) void {
        self.dbgNoteBurst(entries);
        if (entries.len == 0) return;
        const term = entries[entries.len - 1];
        const prev_cum = if (entries.len >= 2) entries[entries.len - 2].cum else first_prev_cum;
        const term_local = term.cum -| prev_cum;
        if (term.kind != .deopt or term.reason != .normal or term.outcome != .normal) return;
        const owner = self.traceById(term.id) orelse return;
        self.noteSiblingTerminal(owner, term.exit);
        if (term.exit < owner.instrs.len and !isLoopDoneGuardIndex(owner, term.exit))
            self.noteTakenExit(owner, term.exit, term_local, proto);
    }

    pub fn driveDispatcherLedger(
        self: *TraceState,
        seed: *Trace,
        entries: []const irinterp.LedgerEntry,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
    ) ChainResult {
        self.noteDispatcherLedgerTerminal(entries, 0, proto);
        // Part S: charge the burst's terminal ordinary deopt, exactly once per burst.
        //
        // This has to be the DRIVER, not `replayLedger`: a walk can return a directive
        // (`run_inner_from`, `run_continuation`) from an interior row and never visit
        // the last one. Siting the charge at the walk's terminal-`.deopt` arm looked
        // cheaper — `owner` is already resolved there — but it silently missed the
        // dominant exit: on nsieve N=9 it saw only 25,939 of the 330,000 terminals, so
        // `t=4 ei=16` (304k bursts, half the remaining seam) could never qualify.
        //
        // The `traceById` scan here is a handful of pointer compares over the live
        // trace cache. It was never the expense: what made the first cut of Part S a
        // 15% REGRESSION was the per-receipt `AutoHashMap` probe it fed (now a
        // three-scalar watch on the trace itself), not the resolve.
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
        // B-2b: capture registry-recognized edge service over the COMPLETE ledger
        // before replay can request a deferred physical disarm. Apply only after
        // replay returns, per §B.6.
        var provenance: NativeCallProvenance = .{};
        self.captureNativeCallProvenance(.dispatcher_root, .{
            .completed = entries[entries.len - 1].cum,
            .exit_instr = entries[entries.len - 1].exit,
            .ledger_len = entries.len,
        }, entries, &provenance);
        const dispatcher_directive = self.replayLedger(entries, seed, inner_pc, proto, &linked_completed, &resume_pc, &hops, max_hops, .dispatcher_root, safe_to_arm, regs);
        // A-vii-d.1: drain the pending bridge-arm request AFTER the walk,
        // BEFORE acting on the directive (review blocker 5).
        self.settleNativeCallProvenance(&provenance, safe_to_arm);
        self.considerSilentPromotion(entries);
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

    fn finishDispatcherDirective(
        self: *TraceState,
        directive: LedgerReplay,
        linked_completed: usize,
        resume_pc: u32,
        hops: usize,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
    ) ChainResult {
        return switch (directive) {
            .run_inner_from => |d| blk: {
                const snt = self.nativeFor(d) orelse
                    @panic("silent drain: run_inner_from target has no native code");
                break :blk self.driveBurstCore(d, .{
                    .current_link = d,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                }, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            .run_continuation => |c| blk: {
                const snt = self.nativeFor(c) orelse
                    @panic("silent drain: run_continuation target has no native code");
                break :blk self.driveBurstCore(c, .{
                    .current_link = c,
                    .linked_completed = linked_completed,
                    .resume_pc = resume_pc,
                    .hops = hops,
                    .start_at_continuation = true,
                }, null, snt, .native_only, proto, regs, safe_to_arm);
            },
            .return_result => |cr| cr,
            .break_burst => .{ .completed = linked_completed, .resume_pc = resume_pc },
        };
    }

    /// Direct-dispatch origin adapter. The universal drain remains the only
    /// `silent_active` consumer; this wrapper merely preserves the dispatcher's
    /// established post-replay transaction order and directive integration.
    pub fn driveDispatcherSilentResult(
        self: *TraceState,
        seed: *Trace,
        result: irinterp.ExecResult,
        proto: *const Proto,
        regs: RegWindow,
        safe_to_arm: bool,
    ) ?ChainResult {
        var linked_completed: usize = 0;
        var resume_pc: u32 = seed.anchor.pc;
        var hops: usize = 0;
        const max_hops: usize = 8;
        if (result.silent_active != 0 and result.ledger_len != 0) {
            if (result.ledger_len > irinterp.LEDGER_CAP)
                @panic("driveDispatcherSilentResult: suffix ledger exceeds cap");
            if (result.silent_cum > std.math.maxInt(usize))
                @panic("driveDispatcherSilentResult: silent cumulative count exceeds usize");
            self.noteDispatcherLedgerTerminal(
                self.ledger_scratch[0..result.ledger_len],
                @intCast(result.silent_cum),
                proto,
            );
        }
        const directive = self.drainSilentResult(
            result,
            .dispatcher_root,
            proto,
            &linked_completed,
            &resume_pc,
            &hops,
            max_hops,
            safe_to_arm,
            regs,
        ) orelse {
            // Multi-row ordinary calls are captured by `driveDispatcherLedger`
            // immediately below the dispatcher. The scalar/short return never
            // enters that adapter, so settle its (normally empty) transaction
            // here before scalar steering can mutate or re-enter native code.
            // (Round 6: this block previously sat in `driveSeedSilentResult`,
            // where it double-settled the driveChain seed — which already settles
            // its ≤2 scalar seam — and left THIS origin, the one it names, with no
            // settle at all.)
            if (result.ledger_len <= 1) {
                var provenance: NativeCallProvenance = .{};
                self.captureNativeCallProvenance(
                    .dispatcher_root,
                    result,
                    self.ledger_scratch[0..result.ledger_len],
                    &provenance,
                );
                self.settleNativeCallProvenance(&provenance, safe_to_arm);
            }
            return null;
        };
        var provenance: NativeCallProvenance = .{};
        self.captureNativeCallProvenance(
            .dispatcher_root,
            result,
            self.ledger_scratch[0..result.ledger_len],
            &provenance,
        );
        self.settleNativeCallProvenance(&provenance, safe_to_arm);
        return self.finishDispatcherDirective(
            directive,
            linked_completed,
            resume_pc,
            hops,
            proto,
            regs,
            safe_to_arm,
        );
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
    pub fn driveSeedLedger(
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
                if (!seed.isBridgeCandidate(e0.exit))
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
        var provenance: NativeCallProvenance = .{};
        self.captureNativeCallProvenance(.drive_chain_seed, .{
            .completed = entries[entries.len - 1].cum,
            .exit_instr = entries[entries.len - 1].exit,
            .ledger_len = entries.len,
        }, entries, &provenance);
        const seed_directive = self.replayLedger(entries, seed, seed_inner_pc, proto, &linked_completed, &resume_pc, &hops, max_hops, .continuation_call, safe_to_arm, regs);
        // A-vii-d.1: drain the pending bridge-arm request AFTER the walk,
        // BEFORE acting on the directive (review blocker 5).
        self.settleNativeCallProvenance(&provenance, safe_to_arm);
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
            .break_burst => |charge_kind| {
                if (linked_completed > 0)
                    return .{ .completed = linked_completed, .resume_pc = resume_pc };
                self.onSideExit(seed, 0, charge_kind);
                return .{ .completed = 0, .resume_pc = resume_pc };
            },
        }
    }

    /// True when a native trace has a link-terminated continuation waiting at one
    /// of its numeric-for loop-done exits. The dispatcher uses this before native
    /// entry so the original run can commit the final iteration in linked mode;
    /// after a normal native deopt the pre-run snapshot needed for that commit is
    /// already gone.
    pub fn hasNativeLoopDoneLink(self: *const TraceState, failed: *Trace, proto: *const Proto) bool {
        // Memoized under `cache_gen` (see `Trace.ldl_memo_*`): the answer only
        // changes when the trace cache does (`nextTraceExcluding` reads it), and
        // this runs once per native dispatch.
        if (failed.ldl_memo_gen == self.cache_gen) return failed.ldl_memo;
        const answer = self.computeNativeLoopDoneLink(failed, proto);
        failed.ldl_memo = answer;
        failed.ldl_memo_gen = self.cache_gen;
        return answer;
    }

    fn computeNativeLoopDoneLink(self: *const TraceState, failed: *const Trace, proto: *const Proto) bool {
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
        // Doc 38: two loop-done shapes seed a continuation. A numeric-for's
        // continuation anchors at the guard's exit PC (the `for_loop`
        // fall-through). A while loop's anchors at the condition branch's JUMP
        // TARGET (the post-loop pc) — `guardExitPc` there is the loop-body
        // start, inside the loop, never a valid continuation anchor.
        const cont_pc: u32 = if (proto.code[guardSourcePc(ins).?].op == .for_loop)
            exit_pc
        else
            whileLoopDonePostPc(failed, exit_instr) orelse return;
        if (!continuationReachesEnclosingBackEdge(proto, cont_pc, failed.anchor.pc)) {
            self.dbg("cont-arm refuse: no enclosing back-edge from pc={d} (inner anchor {d})", .{ cont_pc, failed.anchor.pc });
            return;
        }
        const key = AnchorKey{ .proto = proto, .pc = cont_pc };
        // Don't fight the normal machinery: a trace already cached here, or a gated
        // anchor (a prior continuation aborted → back off), is left alone.
        // NB: evaluate the map lookups ONCE into locals — `dbg` is comptime-off
        // in normal builds but its ARGUMENTS are still evaluated, and a lookup
        // inside the arg tuple re-hashes on every steady-state completion (a
        // measured ~3.7% of a scimark-lu run before this was hoisted).
        const has = self.hasTrace(key);
        const barred = !has and self.recordingBarred(key);
        if (has or barred) {
            self.dbg("cont-arm refuse: pc={d} has_trace={} barred={}", .{ cont_pc, has, barred });
            return;
        }
        self.dbg("cont-arm: pending at pc={d} (inner anchor {d})", .{ cont_pc, failed.anchor.pc });
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
                // Doc 38: an enclosing WHILE loop's back-edge is a plain backward
                // `jmp`. The scan starts past the inner anchor, so a target at or
                // before it is necessarily backward and enclosing (rule Z-6:
                // while-in-while nests arm continuations like for-in-for ones).
                .jmp => {
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
        // Doc 31 D1 (review B3): final eligibility check at the actual start —
        // the request may have been gated between creation and activation.
        if (self.recordingBarred(key)) return;
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
        const src = self.pending_replay_src;
        self.pending_replay_anchor = null;
        self.pending_replay_src = null;
        // Doc 31 D1 (review B3): final eligibility check at the actual start —
        // the request may have been gated between creation and activation.
        if (self.recordingBarred(key)) return;
        self.rec.reset(self.gpa, key, proto.num_registers) catch return;
        self.rec.kind = .side;
        self.rec.side_src = src;
    }

    /// Drop pending `.full`-pinning arms (continuation *and* prime-side replay).
    /// Used when VM execution leaves the dispatch loop before the `.full` prologue
    /// can consume them (error, suspension, or frame unwind), so the VM cannot stay
    /// pinned in `.full` mode behind a stale pending anchor.
    pub fn clearPendingExitAnchor(self: *TraceState) void {
        self.pending_exit_anchor = null;
        self.pending_replay_anchor = null;
        self.pending_replay_src = null;
    }

    /// Pall's `trace_hotside` (lj_trace.c:798), the exit half of tiering: called
    /// on EVERY taken side exit — productive or not — with the exiting trace and
    /// its failing instruction index. `++count >= hotexit` wants a side trace at
    /// the trace's anchor, carrying `(trace, exit)` provenance so the commit can
    /// DONE-latch the exit (`SNAPCOUNT_DONE`). This replaces the old
    /// zero-progress-only `countGuardFailure` charges: under Pall's model an
    /// exit's hotness is a property of how often it is TAKEN, not of how little
    /// the segment before it achieved — a short-but-productive segment whose
    /// exit fires every entry is exactly a side-trace candidate (nsieve's scan
    /// loop at small sieve sizes: prime-gap segments of 1–5 iterations, every
    /// receipt below `min_useful`, the anchor gated before any hotness accrued
    /// and 88% of the N=3 run stayed tier-0 with a trace available).
    ///
    /// Deterministic: a pure function of the receipt stream and cache state.
    /// Loop-done exits are excluded AT THE CALL SITES — they are productive
    /// completions owned by the continuation machinery (`maybeArmContinuation`),
    /// not alternate paths.
    ///
    /// **Routing (the shape-fidelity rule).** Pall's side trace starts recording
    /// AT the exit, so it captures the alternate path by construction. We cannot
    /// record from an arbitrary mid-body exit, so a hot exit is routed to
    /// whichever of our recorders captures the RIGHT shape:
    ///   * **source-branch guard** (`isSourceBranchGuardExit`) → `wants_prime_side`
    ///     — the doc-16 immediate replay: regs are coherent at the anchor on a
    ///     branch exit, tier-0 re-enters there and records THIS iteration's taken
    ///     branch. This is the faithful record-from-the-exit analog.
    ///   * **any other guard, zero-progress receipt** → `wants_side_trace` —
    ///     consumed at the deopt RESUME (`consumeSideTraceWantAtResume`), which
    ///     records the re-run of the failing iteration: again the right shape by
    ///     construction (this is what caught nsieve's append→overwrite flip).
    ///   * **any other guard, productive receipt** → count only, no want. The
    ///     only recorder we could offer is the next-back-edge one, which records
    ///     the NEXT iteration — on an alternating loop that is ~always the
    ///     already-traced shape, and the resulting duplicate siblings burn the
    ///     anchor's trace capacity and lock out the chain machinery (measured:
    ///     routing branch exits there collapsed nsieve's fusion entirely —
    ///     bridge arms 25 940 → 0, +53% wall).
    pub fn noteTakenExit(self: *TraceState, t: *Trace, exit_instr: u32, completed: usize, proto: *const Proto) void {
        if (exit_instr >= t.exit_counts.len) return; // hand-built / fail-soft commit
        const c = &t.exit_counts[exit_instr];
        if (c.* == Trace.EXIT_COUNT_DONE) return;
        // Count EVERY non-DONE taken exit (Pall: `trace_hotside` increments
        // unconditionally) — capacity must suppress ARMING only, never
        // accounting, else an anchor at cap stops accruing hotness and a later
        // eviction restarts the exit cold (codex review of 84c86bc).
        if (c.* < Trace.EXIT_COUNT_DONE - 1) c.* += 1;
        if (c.* < self.config.hotexit) return;
        // Everything below is arming-only, so it runs behind the cheapest
        // possible gates: `isSourceBranchGuardExit` (provenance decode) and
        // `countTracesAt` (an O(cache) scan) must NOT run per receipt on a
        // saturated exit — the seam profile showed exactly that (2% of nsieve
        // in this function, nearly all in the scan). Route first on the free
        // checks (want occupancy, `completed`), then decode/scan only when a
        // want could actually be set. Capacity refusals mirror the mechanisms
        // each route feeds: the prime side keeps its historical one-ramp bound
        // (`countTracesAt >= 2` — once skip + ramp coexist, arming stops and
        // never re-fires); generic siblings stop at `max_traces_per_anchor`.
        // Route on the POSITIVE branch property (source opcode is a real
        // conditional branch), mirroring `siblingHandoffEligible`'s hardening:
        // `isSourceBranchGuardExit` alone only excludes `for_loop`-sourced
        // guards, so a `for_prep`-sourced zero-trip check (nsieve t=4 ei=18)
        // was misrouted to the prime-side want, hit its 2-trace anchor cap,
        // and never accrued side-trace hotness — 304k walks/run with no way
        // to ever tier up the skip path. A zero-trip guard's alternate path
        // is NEW code (skip the loop body), i.e. generic side-trace
        // territory, not a branch alternation between existing siblings.
        // Doc 31 D1 (review B3): want PRODUCTION is gated, not just
        // consumption — creating a want also unpatches the anchor's entry
        // (`markEntryPatchesAt` below), so with a standing record gate every
        // qualifying hot exit would re-unpatch a healthy trace forever. The
        // exit counter above keeps saturating, so the first exit after the
        // cooldown re-creates the want without losing hotness.
        if (self.recordingBarred(t.anchor)) return;
        const branch = self.isSourceBranchGuardExit(t, exit_instr, proto) and blk: {
            const src_pc = guardSourcePc(t.instrs[exit_instr]) orelse break :blk false;
            if (src_pc >= proto.code.len) break :blk false;
            break :blk switch (proto.code[src_pc].op) {
                .jmp_if_false, .jmp_if_true, .jmp_if_not_nil => true,
                else => false,
            };
        };
        if (branch) {
            if (self.wants_prime_side != null) return;
            if (self.anchorPopulation(t) >= 2) return;
            self.dbg("hotexit: trace id={d} exit={d} count={d} -> want PRIME side at pc={d}", .{ t.id, exit_instr, c.*, t.anchor.pc });
            self.wants_prime_side = t.anchor;
            self.prime_want_src = .{ .trace_id = t.id, .exit_instr = exit_instr };
            // Doc 20 unpatch trigger (same rationale as `wants_side_trace`):
            // prime-side arming also runs through the virgin `onBackEdge` path.
            self.markEntryPatchesAt(t.anchor);
        } else if (completed == 0) {
            if (self.wants_side_trace != null) return;
            if (self.anchorPopulation(t) >= self.config.max_traces_per_anchor) return;
            self.dbg("hotexit: trace id={d} exit={d} count={d} -> want side at pc={d}", .{ t.id, exit_instr, c.*, t.anchor.pc });
            self.wants_side_trace = t.anchor;
            self.side_want_src = .{ .trace_id = t.id, .exit_instr = exit_instr };
            // Doc 20 unpatch trigger: side-arming needs the virgin `onBackEdge`
            // path at this anchor next execution — mark any patch pending.
            self.markEntryPatchesAt(t.anchor);
        }
    }

    /// Count a guard failure at `exit_pc` within a trace anchored at `anchor`.
    /// When the counter crosses `config.hotguard`, sets `wants_side_trace` so
    /// the next back-edge records a side trace for the alternate path.
    /// Called from the dispatch loop after a zero-iteration guard failure.
    pub fn countGuardFailure(self: *TraceState, anchor: AnchorKey, exit_pc: u32) void {
        // Don't bother counting if we already have several traces here —
        // additional side traces beyond the first few have diminishing returns
        // and cause unbounded cache growth on alternating-type loops.
        if (self.countTracesAt(anchor) >= self.config.max_traces_per_anchor) return;

        const key = GuardKey{ .anchor = anchor, .exit_pc = exit_pc };
        const gop = self.guard_failures.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_side_trace == null and
            !self.recordingBarred(anchor)) // doc 31 D1: gated want production
        {
            self.wants_side_trace = anchor;
            self.markEntryPatchesAt(anchor); // doc 20: side-arm needs virgin onBackEdge
        }
    }

    /// Count a fingerprint miss: no cached trace at `anchor` matched the
    /// current register types.  Uses the same side-trace threshold
    /// (`config.hotguard`) as `countGuardFailure`, but the key has
    /// `exit_pc == 0` to distinguish it from real guard failures.
    /// Called from the dispatch loop when all traces are skipped by
    /// fingerprint mismatch.
    pub fn countFingerprintMiss(self: *TraceState, anchor: AnchorKey) void {
        if (self.countTracesAt(anchor) >= self.config.max_traces_per_anchor) return;
        // exit_pc == 0 marks this as a fingerprint miss, not a specific
        // guard failure.  Shares the same counter namespace for the
        // hotguard threshold.
        const key = GuardKey{ .anchor = anchor, .exit_pc = 0 };
        const gop = self.guard_failures.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_side_trace == null and
            !self.recordingBarred(anchor)) // doc 31 D1: gated want production
        {
            self.wants_side_trace = anchor;
            self.markEntryPatchesAt(anchor); // doc 20: side-arm needs virgin onBackEdge
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
    /// Only numeric `for_loop` needs excluding: generic-for (`tfor_loop`) IS
    /// recordable (doc 30 c4, `recTForLoop`), but its loop-done pin is a *type*
    /// guard on the first loop variable (`guard_num`/`guard_string`/`guard_table`
    /// — nil ends the loop, so the non-nil type pin doubles as the loop-done
    /// check), never a `guard_true`/`guard_false`. The op check above therefore
    /// already excludes it — there is no false-negative where a real branch
    /// guard is mistaken for a generic-for loop-done one.
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

    /// Fused-M1 validation keyed on the EXACT exit (doc 38 unroll-first): is
    /// there an armed link `parent[slot] → child` where `slot` is a
    /// source-branch guard? An unrolled parent carries several source-branch
    /// guards (one per unrolled while-condition pass), each of which may hold
    /// its own armed link to the same sibling, so validating by "the first
    /// armed slot for the pair" is ambiguous — the ledger's own exit index is
    /// the key.
    pub fn hasArmedSourceBranchLinkAt(self: *const TraceState, parent: *Trace, slot: u32, child: *Trace, proto: *const Proto) bool {
        if (parent == child) return false;
        if (child.anchor.proto != parent.anchor.proto or child.anchor.pc != parent.anchor.pc) return false;
        if (!self.isSourceBranchGuardExit(parent, slot, proto)) return false;
        for (self.armed_links.items) |l| {
            if (l.parent == parent and l.child == child and l.slot_index == slot) return true;
        }
        return false;
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

    /// Memoized `countTracesAt(t.anchor)` for per-receipt hot paths
    /// (`noteTakenExit`): one gen compare in steady state, full scan only after a
    /// cache mutation (`cache_gen` bump). Results are identical to the scan by
    /// construction.
    fn anchorPopulation(self: *const TraceState, t: *Trace) usize {
        if (t.anchor_pop_gen != self.cache_gen) {
            t.anchor_pop = @intCast(self.countTracesAt(t.anchor));
            t.anchor_pop_gen = self.cache_gen;
        }
        return t.anchor_pop;
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

    pub const SuccAnchor = struct { proto_id: u32, pc: u32 };

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
    pub fn resolveSuccessorAnchor(self: *const TraceState, t: *const Trace, e: ExitProvEntry) ?SuccAnchor {
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
        if (!t.isBridgeCandidate(e.index)) return null;
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
    /// and every retirement (never surgically mutated). Consumed by region discovery and
    /// `validateRegionBridge`.
    ///
    /// **Transactional + fail-closed** (round-12 finding 2, round-14 finding 6): the rebuild
    /// reserves capacity BEFORE clearing (so the happy-path publish loop is infallible), but
    /// on ANY OOM it fails CLOSED to an EMPTY cache — never retains the prior snapshot. The
    /// retain option was removed because it is not safe: a boundary edge (excluded from
    /// `RegionId`) added by the very commit that triggers this rebuild can invalidate a prior
    /// region's owner (`both_count` 1→2), so a retained snapshot is not merely "the new trace
    /// stays unclassified" — it can keep a now-stale region armed. Empty is region-neutral
    /// (arm nothing) and auto-recovers on the next successful rebuild.
    pub fn rebuildEdgeCache(self: *TraceState) void {
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
    pub fn rebuildRegions(self: *TraceState) void {
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
                if (!parent.isBridgeCandidate(e.key.exit_instr)) continue;

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
        // Freeze-after-qualify: every branch above may have mutated defs
        // (new defs, armable recomputes, tombstones) — one bump per rebuild
        // transaction invalidates all per-trace membership memos.
        self.demoteSetsForRegionDefsMutation();
        bumpGen(&self.region_defs_gen);
        freeRegionSetMap(ExitKey, &self.source_exit_regions, gpa);
        freeRegionSetMap(u32, &self.dest_entry_regions, gpa);
        self.source_exit_regions = new_source;
        self.dest_entry_regions = new_dest;
        // A-vii-d.1 (review blocker 3): disarm every `.region_bridge` link
        // whose armed region did not survive this pass live + armable. Runs
        // LAST in the publish phase, against the just-published state.
        self.disarmStaleRegionBridgeLinks(live_armable_ids.items);
        // Gate-fix review (codex MAJOR 2): a rebuild that un-armed or
        // tombstoned a def must not leave its live accumulators consuming
        // receipts until the next keyed receipt happens to notice — nor let a
        // later `armable false→true` recomputation resurrect an accumulator
        // with `useful_window_seen` still latched (arming without a fresh
        // qualifying window). Close them here, against the just-published
        // state; `closeRegion` flushes the remainder and refreshes the
        // observer cache.
        self.closeNonArmableAccumulators();
    }

    /// Close every live accumulator whose region def is missing, tombstoned, or
    /// non-armable after a physical rebuild (see call site above). Victim-scan
    /// restart per removal — `closeRegion` mutates the map.
    fn closeNonArmableAccumulators(self: *TraceState) void {
        while (true) {
            var victim: ?RegionKey = null;
            var it = self.region_profit.keyIterator();
            while (it.next()) |k| {
                const live = if (self.region_defs.get(k.region_id)) |d| d.armable else false;
                if (!live) {
                    victim = k.*;
                    break;
                }
            }
            const v = victim orelse return;
            self.dbg("close-reason: rebuild left rid={d} non-armable", .{@intFromEnum(v.region_id)});
            self.closeRegion(v);
        }
    }

    /// Classify a physical trace exit to the regions it belongs to (doc 17 §A3.3 /
    /// §A8-ii, A-ii.4): a pure query over `source_exit_regions`. Consumed by the
    /// accumulator updates AND by `tryArmRegionBridge`, which branches on the
    /// result to decide arming.
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
    pub const PROMOTED_SET_CAP: usize = 16;
    // At most 16 promoted phases can contribute prefix relations. A 32-row
    // reporting suffix can evidence at most 31 distinct parent→child relations
    // (each needs a following row), so the merged maximum is 47. Allocate 48 by
    // the natural component sum and keep every overflow path release-panicking.
    pub const PROVENANCE_VERDICT_CAP: usize = PROMOTED_SET_CAP + irinterp.LEDGER_CAP;

    pub fn exitPatchFor(compiled: *nativegen.CompiledTrace, exit: u32) ?*nativegen.ExitPatch {
        for (compiled.exit_patches) |*patch| if (patch.exit_instr == exit) return patch;
        return null;
    }

    fn patchKindForArm(kind: ArmKind) ?nativegen.ExitPatchKind {
        return switch (kind) {
            .ordinary_guard, .sibling_handoff => .deopt,
            .link_terminal => .link_terminal,
            .loop_done_linked => .loop_done_linked,
            .region_bridge => .region_bridge,
        };
    }

    const BridgeValidationError = error{
        NotComposite,
        NoArmedProvenance,
        WrongArmKind,
        NoRegionProvenance,
        NoExitProvenance,
        RegionMissing,
        RegionTombstoned,
        DuplicateEdge,
        EdgeMissing,
        SuccessorMismatch,
    };

    /// One authoritative proof for both reporting replay and silent promotion.
    /// Its result is static until either the slot relation or region_defs changes.
    fn validateRegionBridgeReceipt(self: *TraceState, owner: *Trace, exit: u32, succ: *Trace) BridgeValidationError!StructuralEdgeId {
        if (!owner.isBridgeCandidate(exit)) return error.NotComposite;
        var armed_link: ?*NativeLink = null;
        for (self.armed_links.items) |*link| {
            if (link.parent != owner or link.slot_index != exit or link.child != succ) continue;
            if (link.kind != .region_bridge) return error.WrongArmKind;
            if (armed_link != null) return error.NoArmedProvenance;
            armed_link = link;
        }
        const link = armed_link orelse return error.NoArmedProvenance;
        const edge = memo: {
            if (link.bridge_edge) |cached| {
                if (link.bridge_edge_gen == self.region_defs_gen) break :memo cached;
            }
            const region_id = link.region_id orelse return error.NoRegionProvenance;
            const prov = owner.provAt(exit) orelse return error.NoExitProvenance;
            const def = self.region_defs.getPtr(region_id) orelse return error.RegionMissing;
            if (!def.armable) return error.RegionTombstoned;
            var registered: ?StructuralEdgeId = null;
            for (def.members) |member| {
                if (member.anchor_proto_id != owner.anchor.proto.id or
                    member.anchor_pc != owner.anchor.pc or exitOrder(member.exit, prov) != .eq) continue;
                if (registered != null) return error.DuplicateEdge;
                registered = member;
            }
            const resolved = registered orelse return error.EdgeMissing;
            link.bridge_edge = resolved;
            link.bridge_edge_gen = self.region_defs_gen;
            break :memo resolved;
        };
        if (edge.succ_anchor_proto_id != succ.anchor.proto.id or edge.succ_anchor_pc != succ.anchor.pc)
            return error.SuccessorMismatch;
        return edge;
    }

    /// Re-check the activation-local static shapes in release mode. The arm path
    /// proved these once; promotion deliberately does not trust historical proof.
    fn promotedEdgeFromLink(self: *TraceState, link: NativeLink) ?PromotedEdge {
        const kind = patchKindForArm(link.kind) orelse return null;
        const compiled = switch (link.parent.native) {
            .compiled => |*c| c,
            else => return null,
        };
        if (link.slot_index >= link.parent.instrs.len or link.slot_index >= compiled.slots.len)
            return null;
        if (link.slot_index >= compiled.metadata_cells.len) return null;
        const patch = exitPatchFor(compiled, link.slot_index) orelse return null;
        if (patch.kind != kind or patch.metadata_cell != &compiled.metadata_cells[link.slot_index] or
            compiled.metadata_cells[link.slot_index] != 0) return null;

        const child_compiled = switch (link.child.native) {
            .compiled => |*c| c,
            else => return null,
        };
        // B-iv.3 (doc 22 §B.5): promotion re-proves enterability through the
        // shared predicate — a seeded child promotes only while its episode ctx
        // is fresh (the frozen cycle re-seeds on every entry via the §B.4
        // prologue, and the ctx is re-stamped at each frame's
        // `prepareNativeEpisode`). Entry kind mirrors the target switch below.
        if (!self.stubEnterable(link.child, switch (link.kind) {
            .link_terminal => .linked,
            .ordinary_guard, .loop_done_linked, .sibling_handoff, .region_bridge => .ordinary,
        }, link.child.anchor.proto)) return null;
        const target = switch (link.kind) {
            .link_terminal => child_compiled.linked_entry orelse return null,
            .ordinary_guard, .loop_done_linked, .sibling_handoff => child_compiled.ordinary_entry orelse return null,
            .region_bridge => child_compiled.ordinary_entry orelse return null,
        };
        if (compiled.slots[link.slot_index] != target) return null;

        const resume_pc: u32 = switch (link.kind) {
            .sibling_handoff => blk: {
                if (link.parent.anchor.proto != link.child.anchor.proto or
                    link.parent.anchor.pc != link.child.anchor.pc or
                    !exitIsPreEffect(link.parent, link.slot_index)) return null;
                break :blk link.child.anchor.pc;
            },
            .ordinary_guard => blk: {
                if (link.parent.anchor.proto != link.child.anchor.proto or
                    isLoopDoneGuardIndex(link.parent, link.slot_index) or
                    link.parent.isBridgeCandidate(link.slot_index)) return null;
                // M1's child is an ordinary-entry ramp, but any terminal child
                // deopt/prologue-fail is coherent at the SOURCE header.
                break :blk link.parent.anchor.pc;
            },
            .link_terminal => blk: {
                const ins = link.parent.instrs[link.slot_index];
                if (ins.op != .link or ins.aux < 0 or
                    link.parent.anchor.proto != link.child.anchor.proto or
                    @as(u32, @intCast(ins.aux)) != link.child.anchor.pc) return null;
                break :blk link.child.anchor.pc;
            },
            .loop_done_linked => blk: {
                if (link.parent.anchor.proto != link.child.anchor.proto or
                    !isLoopDoneGuardIndex(link.parent, link.slot_index)) return null;
                const post_pc = guardExitPc(link.parent.instrs[link.slot_index]) orelse return null;
                if (post_pc != link.child.anchor.pc) return null;
                break :blk post_pc;
            },
            .region_bridge => (self.validateRegionBridgeReceipt(link.parent, link.slot_index, link.child) catch return null).succ_anchor_pc,
        };
        return .{
            .parent = link.parent,
            .exit = link.slot_index,
            .kind = kind,
            .child = link.child,
            .arm_kind = link.kind,
            .resume_pc = resume_pc,
        };
    }

    const PromotionRejectReason = enum {
        bridge_member,
        region_mismatch,
        open_chain,
        child_mismatch,
        no_patch_point,
        cap,
        region_owned,
    };

    fn rejectPromotion(self: *TraceState, reason: PromotionRejectReason) ?[]PromotedEdge {
        switch (reason) {
            .bridge_member => self.silent_rejects.bridge_member +|= 1,
            .region_mismatch => self.silent_rejects.region_mismatch +|= 1,
            .open_chain => self.silent_rejects.open_chain +|= 1,
            .child_mismatch => self.silent_rejects.child_mismatch +|= 1,
            .no_patch_point => self.silent_rejects.no_patch_point +|= 1,
            .cap => self.silent_rejects.cap +|= 1,
            .region_owned => self.silent_rejects.region_owned +|= 1,
        }
        return null;
    }

    fn rowPatchKind(kind: irinterp.LedgerKind) ?nativegen.ExitPatchKind {
        return switch (kind) {
            .deopt => .deopt,
            .link_terminal => .link_terminal,
            .loop_done_linked => .loop_done_linked,
            .region_bridge => .region_bridge,
            .prologue_fail => null,
            // Doc 22 §B.2: seed declines are entry-condition mismatches, not
            // guard failures — there is no exit branch to patch.
            .seed_hash_decline, .seed_capacity_decline => null,
        };
    }

    /// B-3d (doc 17 §B3.16 D1, §B3.18 R7): the ONE per-edge membership predicate
    /// shared by candidacy (`detectPromotableSet`), promotion re-validation
    /// (`promotionBelongsToRegion`), and the membership-growth trigger at the
    /// `armNativeLink` funnel (`noteMembershipGrowth`). A narrower trigger
    /// predicate would re-create trigger-invisible residue (rows only ever seen in
    /// suffix ledgers, which candidacy deliberately never reads) and reopen the
    /// mixed-suffix scenario R1 closed.
    ///
    /// `require_bridge_stamp`: candidacy and re-validation pass `true` — a
    /// `.region_bridge` edge must have its unique armed link stamped with this
    /// exact region (`tryArmRegionBridge`'s restamp). The growth trigger passes
    /// `false` because it evaluates INSIDE the arm funnel, before the caller's
    /// restamp runs — for a fresh bridge arm the stamp is still null there.
    /// Skipping the stamp check widens the trigger, and wider is the safe
    /// direction: the worst case is one extra demote-and-regrow round, whereas
    /// requiring the stamp would make every fresh bridge arm invisible to growth.
    fn edgeMemberOfRegion(self: *TraceState, edge: PromotedEdge, region_id: RegionId, require_bridge_stamp: bool) bool {
        if (!self.regionMemberPoint(region_id, edge.parent.anchor.proto.id, edge.parent.anchor.pc) or
            !self.regionMemberPoint(region_id, edge.child.anchor.proto.id, edge.child.anchor.pc))
            return false;
        if (edge.arm_kind == .region_bridge and require_bridge_stamp) {
            var matching: ?*const NativeLink = null;
            for (self.armed_links.items) |*link| {
                if (link.parent != edge.parent or link.slot_index != edge.exit or
                    link.child != edge.child or link.kind != .region_bridge) continue;
                if (matching != null) return false;
                matching = link;
            }
            const link = matching orelse return false;
            if (link.region_id == null or link.region_id.? != region_id) return false;
        }
        return true;
    }

    pub fn promotionBelongsToRegion(self: *TraceState, edges: []const PromotedEdge, key: RegionKey) bool {
        const def = self.region_defs.get(key.region_id) orelse return false;
        if (!def.armable) return false;
        const accum = self.region_profit.get(key) orelse return false;
        if (!accum.frozen) return false;
        for (edges) |edge| {
            if (!self.edgeMemberOfRegion(edge, key.region_id, true)) return false;
        }
        return true;
    }

    /// B-3d (doc 17 §B3.16 D1): the candidate is the REGION-TOTAL armed-edge set —
    /// every armed, patch-pointed, un-owned region-member edge at the observation
    /// instant, in canonical (parent id, exit) order. The forced-yield ledger is
    /// evidence when every row is one of the candidate's edges, each row's patch
    /// kind matches its edge, and each non-final row's armed child owns the next
    /// row (per-adjacent-pair child-match — the successor-evidence strength of the
    /// old ring grammar without requiring periodicity; the final `.yielded` row's
    /// jump is suppressed by `emitForcedYieldCheck` and is exempt). Repetition
    /// structure is NOT required: sets subsume rings (a ring is a set whose
    /// automaton happens to be periodic), which is what lets a data-dependent
    /// sibling automaton (the nsieve:14 triangle) promote at all.
    ///
    /// A candidate edge that appears in no evidence ledger still promotes — an
    /// explicit accepted trade (§B3.18 R5(c)): registry proof
    /// (`promotedEdgeFromLink` slot/patch/entry identity) is what makes the jump
    /// target correct; firing evidence then arrives via summary cells. A trace may
    /// have any number of other armed exits: only member edges are patched, and
    /// taking any other exit naturally terminates silence into a reporting suffix.
    /// The candidate is a pure function of deterministic state (armed-link
    /// registry + region membership + ledger), so the promotion instant stays
    /// reproducible across the replay modes.
    pub fn detectPromotableSet(self: *TraceState, entries: []const irinterp.LedgerEntry, key: RegionKey) ?[]PromotedEdge {
        const def = self.region_defs.get(key.region_id) orelse return self.rejectPromotion(.region_mismatch);
        if (!def.armable) return self.rejectPromotion(.region_mismatch);
        if (entries.len == 0) return self.rejectPromotion(.open_chain);

        // Region-total candidate from the armed-link registry.
        var scratch: [PROMOTED_SET_CAP]PromotedEdge = undefined;
        var n: usize = 0;
        for (self.armed_links.items) |link| {
            const edge = self.promotedEdgeFromLink(link) orelse continue;
            if (!self.edgeMemberOfRegion(edge, key.region_id, true)) continue;
            if (self.promoted_exit_owners.contains(.{ .trace_id = edge.parent.id, .exit_instr = edge.exit }))
                continue;
            if (n == PROMOTED_SET_CAP) return self.rejectPromotion(.cap);
            scratch[n] = edge;
            n += 1;
        }
        if (n == 0) return self.rejectPromotion(.open_chain);

        // Canonical order: (parent id, exit). Insertion sort; n <= 16.
        for (1..n) |i| {
            const e = scratch[i];
            var j = i;
            while (j > 0 and (scratch[j - 1].parent.id > e.parent.id or
                (scratch[j - 1].parent.id == e.parent.id and scratch[j - 1].exit > e.exit))) : (j -= 1)
            {
                scratch[j] = scratch[j - 1];
            }
            scratch[j] = e;
        }
        // One record per (parent, slot) is an `armNativeLink` invariant; a
        // duplicate here means the registry broke it. Fail closed.
        for (1..n) |i| {
            if (scratch[i].parent.id == scratch[i - 1].parent.id and
                scratch[i].exit == scratch[i - 1].exit)
                return self.rejectPromotion(.child_mismatch);
        }

        // Evidence: every row ∈ candidate, kind-exact, per-adjacent-pair
        // child-match. Non-final rows are always `.normal`-outcome materialized
        // transitions, and a `.prologue_fail` row can never match a candidate edge
        // (`rowPatchKind` has no patch point for it), so the grammar is total.
        for (entries, 0..) |row, i| {
            const observed_kind = rowPatchKind(row.kind) orelse
                return self.rejectPromotion(.no_patch_point);
            var found: ?PromotedEdge = null;
            for (scratch[0..n]) |edge| {
                if (edge.parent.id == row.id and edge.exit == row.exit) {
                    found = edge;
                    break;
                }
            }
            const edge = found orelse return self.rejectPromotion(.open_chain);
            if (edge.kind != observed_kind) return self.rejectPromotion(.no_patch_point);
            if (i + 1 < entries.len and edge.child.id != entries[i + 1].id)
                return self.rejectPromotion(.child_mismatch);
        }

        const result = self.gpa.alloc(PromotedEdge, n) catch return self.rejectPromotion(.cap);
        @memcpy(result, scratch[0..n]);
        return result;
    }

    fn originalRel32Target(compiled: *const nativegen.CompiledTrace, patch: *const nativegen.ExitPatch) usize {
        const bits: u32 = @as(u32, patch.original[1]) |
            (@as(u32, patch.original[2]) << 8) |
            (@as(u32, patch.original[3]) << 16) |
            (@as(u32, patch.original[4]) << 24);
        const disp: i32 = @bitCast(bits);
        const next = @intFromPtr(compiled.page.code.ptr) + patch.patch_off + 5;
        return @intCast(@as(i128, @intCast(next)) + disp);
    }

    fn patchPromotedEdge(self: *TraceState, edge: PromotedEdge, promote: bool) nativegen.PatchError!void {
        const compiled = switch (edge.parent.native) {
            .compiled => |*c| c,
            else => return error.StalePage,
        };
        const generation = compiled.pageGeneration() orelse return error.NotArenaOwned;
        const patch = exitPatchFor(compiled, edge.exit) orelse return error.OffsetOutOfBounds;
        if (patch.kind != edge.kind) return error.OpcodeMismatch;
        const epilogue = @intFromPtr(compiled.page.code.ptr) + patch.epilogue_off;
        switch (edge.kind) {
            .deopt => try self.mcode_arena.patchRel32(
                &compiled.page,
                generation,
                patch.patch_off,
                if (promote) epilogue else originalRel32Target(compiled, patch),
            ),
            .link_terminal, .loop_done_linked, .region_bridge => try self.mcode_arena.patchWindow(
                &compiled.page,
                generation,
                patch.patch_off,
                patch.original,
                epilogue,
                promote,
            ),
        }
    }

    pub fn promoteSet(self: *TraceState, edges: []PromotedEdge, region_key: RegionKey) !void {
        if (edges.len == 0 or edges.len > PROMOTED_SET_CAP) return error.InvalidPromotionSet;
        if (self.next_promoted_set_id == std.math.maxInt(u32)) return error.PromotionIdExhausted;
        // B-3d (§B3.17 R1): ONE live set per region key, enforced — not assumed.
        // The reachable race this closes: a growth demote queued mid-walk has not
        // applied yet when a promotion-eligible candidate arrives; accepting the
        // second set would put two overlapping promotions on one region and break
        // the PROVENANCE_VERDICT_CAP sizing argument. The reject resets the
        // candidate streak (caller), costing one extra 4-window round —
        // deterministic and accepted (§B3.18 R7 churn note).
        for (self.promoted_sets.items) |s| {
            if (std.meta.eql(s.region_key, region_key)) return error.PromotionRegionOwned;
        }
        if (!self.promotionBelongsToRegion(edges, region_key)) return error.InvalidPromotionRegion;
        for (edges) |edge| {
            const validated = self.promotedEdgeFromLink(.{
                .parent = edge.parent,
                .slot_index = edge.exit,
                .child = edge.child,
                .kind = edge.arm_kind,
            }) orelse return error.InvalidPromotionSet;
            if (validated.kind != edge.kind or validated.resume_pc != edge.resume_pc)
                return error.InvalidPromotionSet;
            if (self.promoted_exit_owners.contains(.{ .trace_id = edge.parent.id, .exit_instr = edge.exit }))
                return error.PromotionExitOwned;
        }

        const owned_edges = try self.gpa.dupe(PromotedEdge, edges);
        errdefer self.gpa.free(owned_edges);
        const summary = try self.gpa.alloc(nativegen.SilentSummaryCell, edges.len);
        errdefer self.gpa.free(summary);
        @memset(summary, std.mem.zeroes(nativegen.SilentSummaryCell));
        const metadata = try self.gpa.alloc(nativegen.SilentExitMetadata, edges.len);
        errdefer self.gpa.free(metadata);

        for (owned_edges, 0..) |edge, i| {
            const compiled = &edge.parent.native.compiled;
            metadata[i] = .{
                .summary = &summary[i],
                .slot = &compiled.slots[edge.exit],
                .min_useful = self.config.min_useful,
                .reporting_target = switch (edge.kind) {
                    .deopt => originalRel32Target(compiled, exitPatchFor(compiled, edge.exit).?),
                    .link_terminal, .loop_done_linked, .region_bridge => @intFromPtr(compiled.page.code.ptr) +
                        exitPatchFor(compiled, edge.exit).?.patch_off + 5,
                },
            };
        }

        try self.promoted_sets.ensureUnusedCapacity(self.gpa, 1);
        try self.promoted_exit_owners.ensureUnusedCapacity(self.gpa, @intCast(edges.len));
        // At most one queued id per live set. Reserve against the registry
        // size (not the pending list's current length, normally zero), so a
        // global sweep during replay can queue every set without allocation.
        try self.pending_demote.ensureTotalCapacity(self.gpa, self.promoted_sets.items.len + 1);

        // Publication: initialized metadata first, then pointer cells, code last.
        for (owned_edges, 0..) |edge, i| {
            edge.parent.native.compiled.metadata_cells[edge.exit] = @intFromPtr(&metadata[i]);
        }
        var patched: usize = 0;
        errdefer {
            while (patched > 0) {
                patched -= 1;
                self.patchPromotedEdge(owned_edges[patched], false) catch
                    @panic("promoteSet: failed to restore reporting code during unwind");
            }
            for (owned_edges) |edge| edge.parent.native.compiled.metadata_cells[edge.exit] = 0;
        }
        for (owned_edges) |edge| {
            try self.patchPromotedEdge(edge, true);
            patched += 1;
        }

        const id = self.next_promoted_set_id;
        self.next_promoted_set_id += 1;
        self.promoted_sets.appendAssumeCapacity(.{
            .edges = owned_edges,
            .summary = summary,
            .metadata = metadata,
            .region_key = region_key,
            .id = id,
        });
        for (owned_edges) |edge| self.promoted_exit_owners.putAssumeCapacityNoClobber(
            .{ .trace_id = edge.parent.id, .exit_instr = edge.exit },
            id,
        );
        self.silent_promotions +|= 1;
        if (comptime jitdbg.enabled) {
            if (self.config.debug_log) {
                jitdbg.log("silent-promote: set={d} region={d} len={d}", .{
                    id, region_key.region_id, owned_edges.len,
                });
                for (owned_edges, 0..) |edge, i| {
                    jitdbg.log("  edge[{d}]: {s}:{d} t={d} ei={d} kind={s} arm={s} -> {s}:{d} t={d} resume={d}", .{
                        i,
                        edge.parent.anchor.proto.name,
                        edge.parent.anchor.pc,
                        edge.parent.id,
                        edge.exit,
                        @tagName(edge.kind),
                        @tagName(edge.arm_kind),
                        edge.child.anchor.proto.name,
                        edge.child.anchor.pc,
                        edge.child.id,
                        edge.resume_pc,
                    });
                }
            }
        }
    }

    fn resetPromotionCandidate(self: *TraceState) void {
        if (self.promotion_candidate.len != 0) self.gpa.free(self.promotion_candidate);
        self.promotion_candidate = &.{};
        self.promotion_candidate_run = 0;
        self.promotion_candidate_region = null;
    }

    fn samePromotionEdges(a: []const PromotedEdge, b: []const PromotedEdge) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.parent.id != y.parent.id or x.exit != y.exit or x.child.id != y.child.id or
                x.kind != y.kind or x.arm_kind != y.arm_kind or x.resume_pc != y.resume_pc)
                return false;
        }
        return true;
    }

    /// Production promotion gate: only a full forced-yield ledger from a frozen
    /// activation is evidence, and the same canonical physical edge sequence must
    /// be detected on consecutive observations.
    fn considerSilentPromotion(self: *TraceState, entries: []const irinterp.LedgerEntry) void {
        if (!self.config.silent_promotion_enabled) return;
        if (entries.len != irinterp.LEDGER_CAP or entries[entries.len - 1].outcome != .yielded) {
            self.resetPromotionCandidate();
            return;
        }
        const ctx = self.region_context orelse {
            self.resetPromotionCandidate();
            return;
        };
        const key = self.activeRegionFor(ctx.call_seq) orelse {
            self.resetPromotionCandidate();
            return;
        };
        const accum = self.region_profit.get(key) orelse {
            self.resetPromotionCandidate();
            return;
        };
        if (!accum.frozen) {
            self.resetPromotionCandidate();
            return;
        }
        const detected = self.detectPromotableSet(entries, key) orelse {
            self.resetPromotionCandidate();
            return;
        };
        self.silent_promotion_candidates +|= 1;
        if (self.promotion_candidate_region != null and
            std.meta.eql(self.promotion_candidate_region.?, key) and
            samePromotionEdges(self.promotion_candidate, detected))
        {
            self.gpa.free(detected);
            self.promotion_candidate_run +|= 1;
        } else {
            self.resetPromotionCandidate();
            self.promotion_candidate = detected;
            self.promotion_candidate_run = 1;
            self.promotion_candidate_region = key;
        }
        const threshold = @max(self.config.promote_after, 1);
        if (self.promotion_candidate_run < threshold) return;
        self.promoteSet(self.promotion_candidate, key) catch |err| {
            switch (err) {
                // §B3.17 R1: the region already owns a live set (e.g. a growth
                // demote is queued but not yet applied). Distinct counter so the
                // churn is visible on the board; the candidate streak resets and
                // regrows from fully-reporting windows after the demote lands.
                error.PromotionRegionOwned => self.silent_rejects.region_owned +|= 1,
                else => self.silent_rejects.no_patch_point +|= 1,
            }
            self.resetPromotionCandidate();
            return;
        };
        self.resetPromotionCandidate();
    }

    const DemotionReason = enum { activation, region_close, slot_mutation, trace_invalidation, teardown, unfreeze, membership_growth };
    const PendingDemotion = struct { id: u32, reason: DemotionReason };

    fn queueDemote(self: *TraceState, id: u32, reason: DemotionReason) void {
        for (self.pending_demote.items) |pending| if (pending.id == id) return;
        self.pending_demote.appendAssumeCapacity(.{ .id = id, .reason = reason });
    }

    fn demoteSet(self: *TraceState, idx: usize) void {
        self.demoteSetReason(idx, .trace_invalidation);
    }

    fn demoteSetReason(self: *TraceState, idx: usize, reason: DemotionReason) void {
        const set = self.promoted_sets.items[idx];
        if (self.replay_walk_depth > 0) {
            self.queueDemote(set.id, reason);
            return;
        }
        // Teardown order is the inverse publication order: code first, cells
        // second, then ownership/storage. A failed restore intentionally leaves
        // every cell and allocation live before terminating the process.
        for (set.edges) |edge| self.patchPromotedEdge(edge, false) catch
            @panic("demoteSet: failed to restore reporting code");
        for (set.edges) |edge| edge.parent.native.compiled.metadata_cells[edge.exit] = 0;
        for (set.edges) |edge| {
            if (!self.promoted_exit_owners.remove(.{ .trace_id = edge.parent.id, .exit_instr = edge.exit }))
                @panic("demoteSet: missing physical-exit ownership");
        }
        self.gpa.free(set.edges);
        self.gpa.free(set.summary);
        self.gpa.free(set.metadata);
        _ = self.promoted_sets.swapRemove(idx);
        self.silent_demotions +|= 1;
        switch (reason) {
            .activation => self.silent_demotion_reasons.activation +|= 1,
            .region_close => self.silent_demotion_reasons.region_close +|= 1,
            .slot_mutation => self.silent_demotion_reasons.slot_mutation +|= 1,
            .trace_invalidation => self.silent_demotion_reasons.trace_invalidation +|= 1,
            .teardown => self.silent_demotion_reasons.teardown +|= 1,
            .unfreeze => self.silent_demotion_reasons.unfreeze +|= 1,
            .membership_growth => self.silent_demotion_reasons.membership_growth +|= 1,
        }
        self.resetPromotionCandidate();
    }

    pub fn demoteSetsTouching(self: *TraceState, parent: *Trace, exit: u32) void {
        const id = self.promoted_exit_owners.get(.{ .trace_id = parent.id, .exit_instr = exit }) orelse return;
        for (self.promoted_sets.items, 0..) |set, i| {
            if (set.id == id) {
                self.demoteSetReason(i, .slot_mutation);
                return;
            }
        }
        @panic("demoteSetsTouching: owner names no live set");
    }

    fn demoteSetsTouchingTrace(self: *TraceState, trace: *Trace) void {
        self.resetPromotionCandidate();
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            var touches = false;
            for (self.promoted_sets.items[i].edges) |edge| {
                if (edge.parent == trace or edge.child == trace) {
                    touches = true;
                    break;
                }
            }
            if (touches) self.demoteSetReason(i, .trace_invalidation);
        }
    }

    pub fn demoteAllSets(self: *TraceState) void {
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            self.demoteSetReason(i, .teardown);
        }
    }

    fn demoteSetsForRegionDefsMutation(self: *TraceState) void {
        self.resetPromotionCandidate();
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            // Region membership is part of every promotion proof, and a bridge
            // additionally freezes its exact structural edge. Any defs mutation
            // invalidates both facts, so no promoted set may survive the gen bump.
            self.demoteSetReason(i, .trace_invalidation);
        }
    }

    const SlotMutationReason = enum { arm, rearm, retire, disarm_all, disarm_one };
    const PreparedSlotMutation = struct { compiled: *nativegen.CompiledTrace, exit: u32 };

    /// Phase 1 of the sole physical slot-write funnel. B-3a validates ownership and
    /// bounds; B-3b will demote a promotion owning this physical exit here.
    fn prepareSlotMutation(self: *TraceState, parent: *Trace, exit: u32, reason: SlotMutationReason) !PreparedSlotMutation {
        switch (reason) {
            .retire, .disarm_all, .disarm_one => self.resetPromotionCandidate(),
            .arm, .rearm => {}, // caller distinguishes identical convergence re-arms
        }
        const compiled = switch (parent.native) {
            .compiled => |*c| c,
            else => return error.NativeTraceUnavailable,
        };
        if (exit >= compiled.slots.len) return error.InvalidNativeSlot;
        self.demoteSetsTouching(parent, exit);
        if (self.promoted_exit_owners.contains(.{ .trace_id = parent.id, .exit_instr = exit }))
            return error.DemotionDeferred;
        return .{ .compiled = compiled, .exit = exit };
    }

    /// Phase 2 is infallible and occurs only after the caller's registry mutation.
    fn commitSlotMutation(_: *TraceState, prepared: PreparedSlotMutation, target: usize) void {
        prepared.compiled.slots[prepared.exit] = target;
    }

    /// INVARIANT: every post-compilation `CompiledTrace.slots[i]` write goes through
    /// `prepareSlotMutation` + `commitSlotMutation`.
    pub fn armNativeLink(self: *TraceState, parent: *Trace, slot_index: u32, child: *Trace, kind: ArmKind) !bool {
        const c = switch (parent.native) {
            .compiled => |*cc| cc,
            else => return false,
        };
        if (slot_index >= c.slots.len) return false;
        // Doc 39 (v1): no fusion into or out of a PEELED trace. The run wrapper's
        // +1 local-completion adjustment (a peeled first back-edge closes two
        // tier-0 iterations) is applied at the unfused seam only — a fused span's
        // per-hop counts come from the raw rbx ledger, which cannot express the
        // split. Refusing the arm keeps every peeled run unfused and the
        // accounting exact on both sides.
        if (parent.peeled or child.peeled) return false;
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
                if (parent.isBridgeCandidate(slot_index)) return false;
            },
            .region_bridge => {
                std.debug.assert(!is_loopdone);
                if (is_loopdone) return false;
            },
            // Part S: same slot shape as `.ordinary_guard` (the stub is literally
            // the same code path) — never a loop-done slot (that one is reserved
            // for `.loop_done_linked`), never a bridge candidate (whose stub takes
            // the A-v bridge body instead of the plain resolve-through-slot path).
            .sibling_handoff => {
                std.debug.assert(!is_loopdone);
                if (is_loopdone) return false;
                if (parent.isBridgeCandidate(slot_index)) return false;
                // Re-proved at arm time, not merely trusted from the watch: this is
                // the predicate that makes the handoff sound (`exitIsPreEffect`), and
                // the validator is the last gate before a physical slot is patched.
                if (!exitIsPreEffect(parent, slot_index)) return false;
                // The defining property: parent and child share an anchor.
                if (child.anchor.proto != parent.anchor.proto or
                    child.anchor.pc != parent.anchor.pc) return false;
                // B-iv.3 (doc 22 §B.5): the page prologue owns the seeding
                // (§B.4), so a seeded child IS stub-enterable when its episode
                // ctx is fresh — consult the shared predicate instead of the
                // pre-B-iv "ordinary_entry cannot seed" blanket rule.
                if (!self.stubEnterable(child, .ordinary, child.anchor.proto)) return false;
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
            .ordinary_guard, .loop_done_linked, .sibling_handoff => child_c.ordinary_entry orelse return false,
            // A-vii is the first increment allowed to call this arm. Missing the
            // required re-guarding entry is therefore a wiring bug, not ordinary
            // ineligibility: fail loudly before publishing an unsafe bare jump.
            .region_bridge => child_c.ordinary_entry orelse
                @panic("armNativeLink(.region_bridge): child has no ordinary_entry"),
        };
        // A re-arm of this exact slot supersedes any prior child it pointed at.
        // Mutate the existing record IN PLACE (no allocation) — the earlier
        // remove-then-append ordering could OOM after dropping the old record,
        // stranding the slot armed-but-untracked (2.3a review BUG-1). Because at
        // most one record exists per (parent, slot_index) — this loop guarantees
        // it — the first match is the only match.
        for (self.armed_links.items) |*l| {
            if (l.parent == parent and l.slot_index == slot_index) {
                // B-3d.1 R6 (doc 17 §B3.18, the convergent round-2 MAJOR): an
                // IDENTICAL re-publication — same child, same kind, same slot
                // target — is a no-op on the physical state and must not reach
                // `prepareSlotMutation`, whose owned-exit demotion would tear a
                // live promoted set down for a re-arm that changes nothing (the
                // forced-yield `is_last` convergence arms re-publish exactly such
                // relations). The target compare is load-bearing: a recompiled
                // child has a NEW `ordinary_entry`, so its re-arm takes the full
                // path below and correctly demotes. `.sibling_handoff` is
                // EXCLUDED: `publishSiblingArm` increments the parent latch after
                // every true return, balanced by `clearSiblingLatch` below —
                // short-circuiting the clear would leak the latch +1 per
                // identical republication (the codex post-landing blocker this
                // branch's comment memorializes).
                if (l.child == child and l.kind == kind and c.slots[slot_index] == target and
                    kind != .sibling_handoff)
                {
                    self.dbg("arm (identical re-arm short-circuit): parent id={d} pc={d} slot={d} kind={s}", .{
                        parent.id, parent.anchor.pc, slot_index, @tagName(kind),
                    });
                    return true;
                }
                // Convergence sites re-publish an identical relation on every
                // terminal observation. Keep that from breaking the consecutive
                // detection streak; a changed relation invalidates the candidate.
                if (l.child != child or l.kind != kind or c.slots[slot_index] != target)
                    self.resetPromotionCandidate();
                const prepared = self.prepareSlotMutation(parent, slot_index, .rearm) catch return false;
                // A re-arm can displace a provenance-published sibling arm with
                // a different kind/child — re-open publication so the drain can
                // re-evaluate the surviving edges at the next safe point. And
                // when the OLD record was a `.sibling_handoff`, its parent-side
                // latch must be released here exactly as on removal (codex
                // post-landing blocker: without this, sibling_arms leaks +1 on
                // every displace→republish cycle and the watch fast-reject
                // stops being exact). `publishSiblingArm` re-increments if the
                // new kind is again a sibling handoff.
                if (l.kind == .sibling_handoff or kind == .sibling_handoff)
                    self.provenance_arms_pending = true;
                if (l.kind == .sibling_handoff)
                    clearSiblingLatch(l.*);
                l.child = child;
                l.kind = kind;
                l.region_id = null; // a `.region_bridge` caller re-stamps after arming
                l.armed_gen = 0;
                l.bridge_edge = null; // drop the replay memo with the old child
                l.bridge_edge_gen = 0;
                self.commitSlotMutation(prepared, target);
                self.dbg("arm (re-arm): parent id={d} pc={d} slot={d} -> child id={d} pc={d} kind={s}", .{
                    parent.id, parent.anchor.pc, slot_index, child.id, child.anchor.pc, @tagName(kind),
                });
                self.noteMembershipGrowth(parent, slot_index, child, kind);
                return true;
            }
        }
        // Fresh slot: append the record BEFORE writing the slot, so a failed append
        // leaves the slot at its prior `shared_exit` value with no dangling record.
        self.resetPromotionCandidate();
        const prepared = self.prepareSlotMutation(parent, slot_index, .arm) catch return false;
        try self.armed_links.append(self.gpa, .{ .parent = parent, .slot_index = slot_index, .child = child, .kind = kind });
        if (self.armed_links.items.len > self.native_link_peak) self.native_link_peak = self.armed_links.items.len;
        self.commitSlotMutation(prepared, target);
        self.dbg("arm: parent id={d} pc={d} slot={d} -> child id={d} pc={d} kind={s}", .{
            parent.id, parent.anchor.pc, slot_index, child.id, child.anchor.pc, @tagName(kind),
        });
        self.noteMembershipGrowth(parent, slot_index, child, kind);
        return true;
    }

    /// B-3d (doc 17 §B3.17 R1, §B3.18 R7): the membership-growth trigger. A
    /// successful fresh arm (or changed-relation re-arm) of an edge that would be
    /// a candidate member of a region owning a live promoted set means that set no
    /// longer covers the region's armed-edge population — its rows would surface
    /// only in suffix ledgers, which candidacy deliberately never reads, so the
    /// residue would be permanent. Demote the set; candidacy then regrows from
    /// fully-reporting windows with the region-total candidate (`promote_after`
    /// consecutive identical sets re-promotes). Evaluated at the single
    /// `armNativeLink` funnel — every production arm path routes through it — and
    /// only AFTER a successful arm. Growth is needed only for UN-owned edges: an
    /// owned slot cannot take the fresh-arm branch, an identical owned re-arm
    /// short-circuits above, and a changed-relation owned re-arm already demoted
    /// via `prepareSlotMutation`. Arming is deterministic, so the demotion instant
    /// is reproducible across the replay modes. Demotion follows `demoteSetReason`
    /// semantics — queued mid-walk, immediate at depth 0 — and the backwards
    /// iteration keeps the depth-0 `swapRemove` sound.
    fn noteMembershipGrowth(self: *TraceState, parent: *Trace, slot_index: u32, child: *Trace, kind: ArmKind) void {
        if (self.promoted_sets.items.len == 0) return;
        if (self.promoted_exit_owners.contains(.{ .trace_id = parent.id, .exit_instr = slot_index }))
            return;
        // Not patch-pointed (or otherwise failing arm-shape validation) means the
        // edge can never be a candidate member, so it cannot outgrow a set. Same
        // per-edge core as candidacy below (§B3.18 R7: one membership predicate);
        // the bridge stamp is not required here because the trigger runs before
        // `tryArmRegionBridge`'s restamp — see `edgeMemberOfRegion`.
        const edge = self.promotedEdgeFromLink(.{
            .parent = parent,
            .slot_index = slot_index,
            .child = child,
            .kind = kind,
        }) orelse return;
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.promoted_sets.items[i];
            if (!self.edgeMemberOfRegion(edge, s.region_key.region_id, false)) continue;
            self.dbg("membership growth: parent id={d} slot={d} kind={s} demotes set={d} region={d}", .{
                parent.id, slot_index, @tagName(kind), s.id, s.region_key.region_id,
            });
            self.demoteSetReason(i, .membership_growth);
        }
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
    /// 2c-E site 4 (arming convergence, `.link` edition — 2026-08-12): fail-closed
    /// arm of a continuation/ramp's `.link` terminal slot → the inner root its
    /// `aux` names. The `.loop_done_linked` twin of this convergence has existed
    /// since 2c-E (site 3, `armLoopDoneLink` above); without the `.link` side, a
    /// `.link` trace reached ONLY through ledger replay never armed — the scalar
    /// call-A arm site reads `current_link` AFTER the driver swap, so it only
    /// ever arms post-loop continuations, never entry ramps. Measured on nsieve
    /// N=7 before this site landed: 6931 of ~7000 native spans per run ended at
    /// the prime ramp's unarmed `.link` (one runtime seam per prime), capping the
    /// fused region complex at ~5% of primes. Every gate mirrors the scalar site
    /// + `replayLedger`'s own fused-successor validation, so an armed slot can
    /// only dispatch a successor the replay grammar would accept.
    fn armLinkTerminal(self: *TraceState, cont: *Trace, inner: *Trace, safe_to_arm: bool) void {
        // Observation blackout (2.3c-0e): never widen an armed cycle while suspend /
        // replay-line recording is active.
        if (!safe_to_arm) return;
        // The parent must end in a `.link` terminal whose aux names the inner root.
        if (cont.instrs.len == 0) return;
        const term = cont.instrs[cont.instrs.len - 1];
        if (term.op != .link) return;
        // The child must be the shape `replayLedger`'s fused `.link_terminal`
        // successor validation release-panics on anything but: an inner loop
        // root in the same proto at exactly the `.link`-named PC (B-iv.3:
        // seeded roots included — enterability checked below).
        if (!isInnerLoopRoot(inner, cont.anchor.proto, @intCast(term.aux))) return;
        // Both ends need native code: the parent for its slot table, the child for
        // the `linked_entry` the arm derives (`armNativeLink` re-checks; missing
        // native on either side must no-op silently, not assert).
        if (self.nativeFor(cont) == null or self.nativeFor(inner) == null) return;
        // B-iv.3 (doc 22 §B.5): mirror the scalar call-A arm site's widened
        // gate — a seeded inner arms only while stub-enterable (fresh ctx).
        if (!self.stubEnterable(inner, .linked, cont.anchor.proto)) return;
        const slot: u32 = @intCast(cont.instrs.len - 1);
        const armed = self.armNativeLink(cont, slot, inner, .link_terminal) catch false;
        if (armed) self.native_link_arms +|= 1;
    }

    fn armLoopDoneLink(self: *TraceState, inner: *Trace, guard_idx: u32, safe_to_arm: bool) void {
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
        // B-4 (§B4.3 D3'): the arm target is CANONICAL — resolved positionally
        // at `post_pc` through the shared selector, never taken from whatever
        // continuation the caller happened to be holding. A caller-supplied
        // candidate could alternate between eligible siblings across paths,
        // and every changed relation is a slot mutation that resets promotion
        // candidacy (§B4.7 MAJOR-2); the selector is a pure function of the
        // cache, so the relation is stable and identical re-arms short-circuit
        // at the `armNativeLink` funnel (B-3d.1 R6).
        const target = self.resolveLoopDoneCont(inner.anchor.proto, post_pc, null).arm orelse return;
        self.armLoopDoneLinkTo(inner, guard_idx, post_pc, target);
    }

    /// The targeted arm worker: `cont` is the canonical selector's choice (or
    /// the terminal drain's already-resolved `sel.arm` — one selection per
    /// event, D4'). P-G eligibility is re-validated fail-closed — cheap, and it
    /// keeps the invariant local rather than trusting the caller.
    fn armLoopDoneLinkTo(self: *TraceState, inner: *Trace, guard_idx: u32, post_pc: u32, cont: *Trace) void {
        // Continuation eligibility (P-G): a `.link` trace anchored exactly at
        // the guard's post-loop PC in the same proto — the shape `replayLedger`'s
        // `.loop_done_linked` successor validation release-panics on, so anything
        // else must stay unarmed. B-iv.3 (doc 22 §B.5): seeded continuations
        // qualify when stub-enterable — checked AFTER `nativeFor` (the predicate
        // never compiles), mirroring the widened replay assert.
        if (!(cont.instrs.len != 0 and cont.instrs[cont.instrs.len - 1].op == .link)) return;
        if (!(cont.anchor.proto == inner.anchor.proto and cont.anchor.pc == post_pc)) return;
        // `ordinary_entry` is optional — a missing entry (e.g. a test stub or an
        // unsupported compile) leaves the slot unarmed, never `.?`-traps.
        _ = self.nativeFor(cont) orelse return;
        if (!self.stubEnterable(cont, .ordinary, inner.anchor.proto)) return;
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
        self.demoteSetsTouchingTrace(t);
        const shared_exit = self.mcode_arena.trampoline_exit orelse 0;
        var i: usize = self.armed_links.items.len;
        while (i > 0) {
            i -= 1;
            const link = self.armed_links.items[i];
            if (link.child != t and link.parent != t) continue;
            self.dbg("retire-reset: link parent id={d} slot={d} child id={d} (retiring id={d})", .{
                link.parent.id, link.slot_index, link.child.id, t.id,
            });
            clearSiblingLatch(link);
            if (link.child == t and link.parent != t) {
                switch (link.parent.native) {
                    .compiled => |*c| if (link.slot_index < c.slots.len) {
                        const prepared = self.prepareSlotMutation(link.parent, link.slot_index, .retire) catch
                            @panic("resetLinksTouching: invalid native slot mutation");
                        self.commitSlotMutation(prepared, shared_exit);
                    },
                    else => {},
                }
            }
            _ = self.armed_links.swapRemove(i);
            // A removed arm may be re-publishable from a surviving provenance
            // edge — let the drain re-evaluate at the next safe point.
            self.provenance_arms_pending = true;
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
            clearSiblingLatch(link);
            switch (link.parent.native) {
                .compiled => |*c| if (link.slot_index < c.slots.len) {
                    const prepared = self.prepareSlotMutation(link.parent, link.slot_index, .disarm_all) catch
                        @panic("disarmAllLinks: invalid native slot mutation");
                    self.commitSlotMutation(prepared, shared_exit);
                },
                else => {},
            }
        }
        self.armed_links.clearRetainingCapacity();
        // See resetLinksTouching: removed arms re-open provenance publication.
        self.provenance_arms_pending = true;
    }

    /// Part S: drop a `.sibling_handoff` link's parent-side latch. EVERY path that
    /// removes an armed link must call this, or `hasArmedSiblingHandoff`'s fast reject
    /// stops being an exact necessary condition (it would keep saying "maybe" for a
    /// parent with no link, costing a registry scan) and the watch could never
    /// re-qualify. Cheap enough to call unconditionally on any link kind.
    fn clearSiblingLatch(link: NativeLink) void {
        if (link.kind != .sibling_handoff) return;
        link.parent.sibling_arms -|= 1;
        link.parent.sibling_watch_exit = std.math.maxInt(u32);
        link.parent.sibling_watch_count = 0;
        // The arm set touching this trace changed — the ineligible memo may have
        // been the armed-slot exclusion, so it must be re-derived.
        link.parent.sibling_reject_exit = std.math.maxInt(u32);
    }

    /// A-vii-d.1 (review blocker 3): disarm ONE armed link by registry index —
    /// reset its parent's physical slot to the shared trampoline exit, count the
    /// disarm, and drop the record. Infallible (publish-phase safe). Uses
    /// `swapRemove`, so callers iterating the registry must walk BACKWARDS.
    pub fn disarmLinkAt(self: *TraceState, idx: usize) void {
        const link = self.armed_links.items[idx];
        self.native_link_disarms +|= 1;
        clearSiblingLatch(link);
        const shared_exit = self.mcode_arena.trampoline_exit orelse 0;
        switch (link.parent.native) {
            .compiled => |*c| if (link.slot_index < c.slots.len) {
                const prepared = self.prepareSlotMutation(link.parent, link.slot_index, .disarm_one) catch
                    @panic("disarmLinkAt: invalid native slot mutation");
                self.commitSlotMutation(prepared, shared_exit);
            },
            else => {},
        }
        _ = self.armed_links.swapRemove(idx);
        // See resetLinksTouching: a removed arm re-opens provenance publication.
        // Deliberately conservative: `.region_bridge` disarms (e.g. via
        // disarmStaleRegionBridgeLinks) also pass through here and re-open
        // publication even though no sibling arm changed — one wasted drain
        // scan per stale-bridge teardown, accepted for a single invariant
        // ("any physical disarm re-opens") instead of per-kind exceptions.
        self.provenance_arms_pending = true;
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
                // B-2a / §B.6: logical relation deletion is immediate at the
                // retirement source; physical link teardown remains P-E's job.
                self.retireProvenanceEdgesTouching(t.id);
                // P-E: reset/drop every armed native link touching `t` before its
                // mcode slot can be freed and reused (see `resetLinksTouching`).
                self.resetLinksTouching(t);
                _ = self.cache.swapRemove(idx);
                bumpGen(&self.cache_gen); // invalidate Trace.anchor_pop_* memos
                // Doc 20 §R7-2: mark the entry patch BEFORE destroy — after it,
                // `EntryPatch.trace` dangles and only `trace_id` (now resolving
                // to null) remains valid. Allocation-free, drained at the next
                // safe point.
                if (t.entry_slot) |slot| self.markEntryPatchPending(slot);
                if (t.id < self.trace_by_id.items.len) self.trace_by_id.items[t.id] = null;
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
    // ---- doc 20: copy-on-patch code images + entry-patch registry ----------

    /// The code array the dispatch fetch must execute for `proto`: its
    /// VM-local patched image when one exists, else canonical. The empty-map
    /// early-out makes an unpatched program's cost one counter load per call.
    pub fn codeFor(self: *const TraceState, proto: *const Proto) []const Instr {
        if (self.code_images.count() == 0) return proto.code;
        return self.code_images.get(proto) orelse proto.code;
    }

    /// Get-or-clone the VM-local image for `proto` (§R1 copy-on-patch). The
    /// clone bumps `image_gen` so live frames re-resolve at their next
    /// back-edge (§R2-1). Install path only — never called per entry.
    fn ensureImage(self: *TraceState, proto: *const Proto) ![]Instr {
        const gop = try self.code_images.getOrPut(self.gpa, proto);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.gpa.dupe(Instr, proto.code) catch |e| {
                self.code_images.removeByPtr(gop.key_ptr);
                return e;
            };
            self.image_gen +%= 1;
        }
        return gop.value_ptr.*;
    }

    /// The image opcode corresponding to a canonical loop-closing instruction.
    /// Numeric `for` uses `.jfor_loop`; compiler-emitted `while` and `repeat`
    /// close with `.jmp` and `.jmp_if_false` respectively, and generic-for
    /// closes with `.tfor_loop` (recordable since doc 30 c4) — all three share
    /// `.jloop`, whose arm re-executes the ORIGINAL opcode's semantics from
    /// `patch.orig` and enters only on a taken back-edge. Other jump variants
    /// are not loop closers emitted by the compiler.
    fn patchedEntryOp(op: OpCode) ?OpCode {
        return switch (op) {
            .for_loop => .jfor_loop,
            .jmp, .jmp_if_false, .tfor_loop => .jloop,
            else => null,
        };
    }

    /// §R3-1 patch-pc resolution, fail closed: the unique supported loop-closing
    /// instruction whose taken back-edge targets `anchor_pc` (target = pc + 1 +
    /// aux, matching the dispatcher's post-fetch `applyJump`). This covers the
    /// actual compiler shapes: numeric `for` (`.for_loop`), `while` (`.jmp`), and
    /// `repeat` (`.jmp_if_false`). Zero or multiple matches → null (ambiguity is a
    /// property of immutable bytecode; the caller routes `.suppressed_permanent`).
    pub fn resolvePatchPc(proto: *const Proto, anchor_pc: u32) ?u32 {
        var found: ?u32 = null;
        for (proto.code, 0..) |ins, i| {
            if (patchedEntryOp(ins.op) == null) continue;
            const target: i64 = @as(i64, @intCast(i + 1)) + ins.aux;
            if (target == anchor_pc and target <= @as(i64, @intCast(i))) {
                if (found != null) return null; // ambiguous → fail closed
                found = @intCast(i);
            }
        }
        return found;
    }

    /// Why `installEntryPatch` declined — routes the §R4-2 state machine at
    /// the drain (`.no_patch_pc` → `.suppressed_permanent`; `.incumbent` →
    /// `.suppressed_incumbent` recording the blocking slot; `.capacity` →
    /// `.suppressed_capacity`; `.oom` → `.eligible`, transient §R5-2).
    pub const InstallResult = union(enum) {
        installed,
        no_patch_pc,
        incumbent: u16,
        capacity,
        oom,
    };

    /// Install a `.jfor_loop` / `.jloop` patch binding `t` at its anchor (§R2-6
    /// publication order: initialize the slot COMPLETELY, then write the
    /// image opcode — that write is the publication). Declines (installing
    /// nothing) when the patch pc is unresolvable/ambiguous, the pc already
    /// holds a live patch (§R3-1 rule 2 — incumbent wins), the slot index
    /// space is exhausted (§R6-2), or allocation fails — a missed
    /// optimization, never an error. Production caller: the Phase-1 install
    /// pass of `drainEntryPatchWork`, which owns the state routing.
    pub fn installEntryPatch(self: *TraceState, t: *Trace) InstallResult {
        std.debug.assert(t.entry_slot == null);
        const patch_pc = resolvePatchPc(t.anchor.proto, t.anchor.pc) orelse return .no_patch_pc;
        const img = self.ensureImage(t.anchor.proto) catch return .oom;
        const orig = t.anchor.proto.code[patch_pc];
        const patched_op = patchedEntryOp(orig.op) orelse unreachable;
        if (img[patch_pc].op == .jfor_loop or img[patch_pc].op == .jloop)
            return .{ .incumbent = img[patch_pc].b }; // live incumbent wins
        // Acquire a slot: reuse a tombstone, else append (fail closed at the
        // u16 index ceiling — `.b` must hold the index).
        const idx: u16 = if (self.entry_patch_free.pop()) |free_idx|
            free_idx
        else blk: {
            // Fail closed when the WOULD-BE index (current len) no longer
            // fits `.b`'s u16 — index 65535 itself is valid (codex MINOR on
            // 7fa7e1a: `>=` wasted the last representable slot).
            if (self.entry_patches.items.len > std.math.maxInt(u16)) return .capacity;
            const p = self.gpa.create(EntryPatch) catch return .oom;
            self.entry_patches.append(self.gpa, p) catch {
                self.gpa.destroy(p);
                return .oom;
            };
            break :blk @intCast(self.entry_patches.items.len - 1);
        };
        // EntryPlan structural half (§R1-4/6): the scratch high-water mark
        // `seedTraceInputs` re-derives per entry, memoized at patch time.
        var seed_count: u32 = t.anchor.proto.num_registers;
        for (t.inputs) |seed| seed_count = @max(seed_count, @as(u32, seed.slot) + 1);
        const p = self.entry_patches.items[idx];
        p.* = .{
            .trace = t,
            .trace_id = t.id,
            .proto = t.anchor.proto,
            .patch_pc = patch_pc,
            .orig = orig,
            .seed_count = seed_count,
        };
        t.entry_slot = idx;
        // Publication: the opcode write, AFTER the slot is fully initialized.
        var patched = p.orig;
        patched.op = patched_op;
        patched.b = idx;
        img[patch_pc] = patched;
        self.image_gen +%= 1; // current frame reloads at its next back-edge
        self.dbg("entry-patch install: pc={d} patch_pc={d} slot={d} trace={d}", .{ t.anchor.pc, patch_pc, idx, t.id });
        return .installed;
    }

    /// Mark a slot for unpatch (§R2-4): clears `live` so no arm dereferences
    /// the (possibly dying) trace pointer, defers the restore/tombstone to
    /// the safe-point drain. Allocation-free — legal mid-grammar, including
    /// from `removeTrace` immediately before `t.destroy` (§R7-2).
    pub fn markEntryPatchPending(self: *TraceState, idx: u16) void {
        const p = self.entry_patches.items[idx];
        if (p.tombstone or p.pending_unpatch) return;
        p.live = false;
        p.pending_unpatch = true;
        self.entry_patch_dirty += 1;
    }

    /// Mark every live slot whose bound trace anchors at `anchor` (doc 20
    /// unpatch-trigger table: anchor gated / `wants_side_trace` at a patched
    /// anchor). Identity goes through `traceById` — a dropped trace's slot was
    /// already marked by the `removeTrace` hook. Linear over the registry,
    /// which stays tiny (one live slot per patched loop); allocation-free.
    pub fn markEntryPatchesAt(self: *TraceState, anchor: AnchorKey) void {
        if (self.entry_patches.items.len == 0) return;
        for (self.entry_patches.items, 0..) |p, i| {
            if (p.tombstone or p.pending_unpatch) continue;
            const t = self.traceById(p.trace_id) orelse continue;
            if (t.anchor.proto == anchor.proto and t.anchor.pc == anchor.pc)
                self.markEntryPatchPending(@intCast(i));
        }
    }

    /// The safe-point drain (doc 20 §Safe-point-drain), called by the
    /// caller-owned epilogue after every `enterSelectedTrace` return, before
    /// acting on the directive. §R3-1 order: ALL pending unpatches first
    /// (a T1-unpatch + T2-install at one pc is then a clean
    /// unpatch-then-repatch; install-first would let T1's restore overwrite
    /// T2), then the revalidate-then-install pass for `.pending` marks in
    /// ascending trace-id order (§R3-1 rule 3 deterministic sibling ties).
    /// Early-outs on the dirty counter, so a quiet turn costs one load.
    pub fn drainEntryPatchWork(self: *TraceState) void {
        if (self.entry_patch_dirty == 0) return;
        self.entry_patch_dirty = 0;
        for (self.entry_patches.items, 0..) |p, i| {
            if (p.tombstone or !p.pending_unpatch) continue;
            self.unpatchSlot(@intCast(i));
        }
        // Install pass: pending marks live on traces, found by cache scan
        // (drains are rare — only a dirty turn pays this). Ascending-id
        // selection keeps sibling ties deterministic without allocating.
        while (true) {
            var best: ?*Trace = null;
            for (self.cache.items) |t| {
                if (t.entry_patch != .pending) continue;
                if (best == null or t.id < best.?.id) best = t;
            }
            self.installPending(best orelse break);
        }
    }

    /// §R4-1 revalidate-then-install for one `.pending` trace. `.pending` is
    /// a claim made mid-receipt; the rest of that same receipt can invalidate
    /// it (region accounting can gate the very anchor just marked, retirement
    /// can drop the trace — a dropped trace never reaches here, the scan is
    /// over the live cache). The drain has already applied this turn's
    /// unpatches and gates, so the checks here are authoritative: still
    /// `.compiled` by tag, anchor not gated, then the install's own
    /// fail-closed checks. Failure routes per the §R4-2 state machine.
    fn installPending(self: *TraceState, t: *Trace) void {
        std.debug.assert(t.entry_patch == .pending);
        if (t.native != .compiled) {
            t.entry_patch = .suppressed_permanent;
            return;
        }
        // A `.link`-closed continuation is never trial-entered through the
        // anchor walk (interp.zig's walk skips them); a patched entry must
        // not become the back door. Permanent — the close op never changes.
        if (t.instrs.len != 0 and t.instrs[t.instrs.len - 1].op == .link) {
            t.entry_patch = .suppressed_permanent;
            return;
        }
        if (self.isGated(t.anchor)) {
            // Transient (§R5-2): cooldown may lift; a condemned trace is
            // never repatched past `isGated` (§T14). Re-qualifies at the next
            // productive receipt after the gate clears.
            t.entry_patch = .eligible;
            return;
        }
        switch (self.installEntryPatch(t)) {
            .installed => t.entry_patch = .bound,
            .no_patch_pc => t.entry_patch = .suppressed_permanent,
            .incumbent => |slot| {
                t.entry_patch = .suppressed_incumbent;
                t.entry_patch_incumbent = slot;
            },
            .capacity => t.entry_patch = .suppressed_capacity,
            .oom => t.entry_patch = .eligible, // transient (§R5-2)
        }
    }

    /// Restore-then-tombstone (§R2-6 unpatch order). In-place restore is
    /// immediately visible to any frame still holding the image slice, and
    /// the restored content is canonical-identical — no generation bump
    /// needed. Resolves the trace through `traceById`, never `p.trace`
    /// (§R7-2: the trace may already be destroyed).
    /// Public for exactly one external caller besides the drain: the
    /// patched dispatch arms' §R6-1 defensive step-1 recovery, which runs OUTSIDE
    /// any receipt grammar and is the sole slot-pointer holder — synchronous
    /// unpatch is safe there.
    pub fn unpatchSlot(self: *TraceState, idx: u16) void {
        const p = self.entry_patches.items[idx];
        if (self.code_images.get(p.proto)) |img| {
            std.debug.assert(img[p.patch_pc].op == patchedEntryOp(p.orig.op).? and img[p.patch_pc].b == idx);
            std.debug.assert(std.meta.eql(p.orig, p.proto.code[p.patch_pc]));
            img[p.patch_pc] = p.orig;
        }
        if (self.traceById(p.trace_id)) |t| {
            t.entry_slot = null;
            // §R4-2 `.bound → .eligible`: the trace survives its unpatch; a
            // later productive receipt may re-qualify (the gate cooldown is
            // the thrash brake against ping-pong).
            if (t.entry_patch == .bound) t.entry_patch = .eligible;
        }
        p.live = false;
        p.pending_unpatch = false;
        p.tombstone = true;
        // §R4-2 wakes, deterministic at this tombstone: `.suppressed_capacity`
        // is a capacity wait — ANY tombstone restores capacity; a
        // `.suppressed_incumbent` wakes only when ITS recorded incumbent slot
        // dies (this one). Wake = back to `.eligible`; the next productive
        // receipt re-qualifies (no install this turn — the wake is not a
        // `.pending` mark).
        for (self.cache.items) |wt| {
            switch (wt.entry_patch) {
                .suppressed_capacity => wt.entry_patch = .eligible,
                .suppressed_incumbent => if (wt.entry_patch_incumbent == idx) {
                    wt.entry_patch = .eligible;
                },
                else => {},
            }
        }
        self.dbg("entry-patch unpatch: patch_pc={d} slot={d} trace={d}", .{ p.patch_pc, idx, p.trace_id });
        // OOM here loses the index for reuse (stays tombstoned forever) —
        // safe: fail-closed capacity, reclaimed at the epoch drain anyway.
        self.entry_patch_free.append(self.gpa, idx) catch {};
    }

    /// Epoch/deinit teardown (§R2-2: the ONLY points images are freed).
    /// Restores nothing — the images are dropped whole, and canonical
    /// `Proto.code` was never touched.
    pub fn dropEntryPatchState(self: *TraceState) void {
        var it = self.code_images.valueIterator();
        while (it.next()) |img| self.gpa.free(img.*);
        self.code_images.clearRetainingCapacity();
        for (self.entry_patches.items) |p| self.gpa.destroy(p);
        self.entry_patches.clearRetainingCapacity();
        self.entry_patch_free.clearRetainingCapacity();
        self.entry_patch_dirty = 0;
        self.image_gen +%= 1; // any live frame re-resolves to canonical
    }

    pub fn clearCache(self: *TraceState) void {
        // Doc 20 §R2-2: drop images + registry BEFORE destroying traces so no
        // slot outlives the epoch (traces are resolved by id, but the order
        // keeps the invariant trivially visible).
        self.dropEntryPatchState();
        self.demoteAllSets();
        self.clearProvenanceEdges();
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.clearRetainingCapacity();
        bumpGen(&self.cache_gen); // invalidate Trace.anchor_pop_* memos
        @memset(self.trace_by_id.items, null); // every indexed trace was just destroyed

        // Anchor-keyed tiering state: reset so the next epoch re-warms cleanly and no
        // stale entry references a freed trace or blocks re-recording. (Mirrors the
        // per-anchor reset `removeTrace` does, applied wholesale.)
        self.counters.clearRetainingCapacity();
        @memset(&self.hotcount, 0);
        self.gate.clearRetainingCapacity();
        self.record_gate.clearRetainingCapacity();
        self.lleave_count.clearRetainingCapacity();
        self.unroll_fail.clearRetainingCapacity();
        self.while_yield.clearRetainingCapacity();
        self.penalty.clearRetainingCapacity();
        self.guard_failures.clearRetainingCapacity();
        self.wants_side_trace = null;
        self.side_want_src = null;
        self.wants_prime_side = null;
        self.prime_want_src = null;
        self.pending_exit_anchor = null;
        self.pending_replay_anchor = null;
        self.pending_replay_src = null;

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
        // Uphold the "every region_defs mutation bumps the gen" contract at the
        // epoch boundary too (codex review of f613c98). Not currently load-
        // bearing — every gen-stamped memo lives on traces/links that were just
        // destroyed/disarmed above — but a future consumer must not find the
        // invariant silently false here.
        self.demoteSetsForRegionDefsMutation();
        bumpGen(&self.region_defs_gen);
        self.region_intern.clear(self.gpa);
        self.clearPhysicalRegionIndices();
        self.resetRegionProfit();
        self.region_profit_flushes = 0;
        self.region_profit_flushed_work = 0;
    }

    /// Part B-2a / §B.6: fresh-epoch teardown drops every logical provenance
    /// relation along with the trace cache. Edges are created by the B-2b
    /// silent-provenance staging (`stageSilentSiblingProvenance` /
    /// `stageSilentSuffixProvenance`) and by side-trace commits.
    pub fn clearProvenanceEdges(self: *TraceState) void {
        self.provenance_edges.clearRetainingCapacity();
    }

    /// Part B-2a / §B.6: retirement of either endpoint immediately deletes
    /// its logical relations. Physical links are handled by `resetLinksTouching`.
    pub fn retireProvenanceEdgesTouching(self: *TraceState, trace_id: u32) void {
        var i = self.provenance_edges.items.len;
        while (i > 0) {
            i -= 1;
            const edge = self.provenance_edges.items[i];
            if (edge.parent_id == trace_id or edge.child_id == trace_id)
                _ = self.provenance_edges.swapRemove(i);
        }
    }

    /// Part B-2a / §B.6: delete relations owned by parent traces at `anchor`.
    /// B-2b wires this event-level wrapper to region low-yield condemnation; it
    /// must not be inferred from ordinary temporary gate state.
    pub fn condemnProvenanceEdgesAt(self: *TraceState, anchor: AnchorKey) void {
        var i = self.provenance_edges.items.len;
        while (i > 0) {
            i -= 1;
            const edge = self.provenance_edges.items[i];
            const parent = self.traceById(edge.parent_id) orelse continue;
            if (parent.anchor.proto == anchor.proto and parent.anchor.pc == anchor.pc)
                _ = self.provenance_edges.swapRemove(i);
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
                if (nativegen.compileInto(self.gpa, &self.mcode_arena, t, self.native_seed_ctx, self.exec_heap)) |ct| {
                    t.native = .{ .compiled = ct };
                    return &t.native.compiled;
                }
                if (comptime jitdbg.enabled) if (self.config.debug_log) {
                    diag: {
                        const kinds = self.gpa.alloc(nativegen.Kind, t.instrs.len) catch break :diag;
                        defer self.gpa.free(kinds);
                        const slots = self.gpa.alloc(i32, t.instrs.len) catch break :diag;
                        defer self.gpa.free(slots);
                        const proved = nativegen.proveKinds(self.gpa, t, kinds, slots);
                        if (proved) {
                            if (nativegen.analyze(self.gpa, t, kinds, slots)) |alloc_value| {
                                var alloc = alloc_value;
                                defer alloc.deinit(self.gpa);
                                self.dbg("native unsupported after analyze: trace={d} anchor={d} spill_count={d}", .{ t.id, t.anchor.pc, alloc.spill_count });
                            } else {
                                self.dbg("native unsupported in analyze: trace={d} anchor={d}", .{ t.id, t.anchor.pc });
                            }
                        } else {
                            self.dbg("native unsupported in proveKinds: trace={d} anchor={d}", .{ t.id, t.anchor.pc });
                        }
                    }
                };
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

    /// Doc 26 D1a: kill an active recording because an error is unwinding
    /// through the dispatch loop. Called from `Vm.execWith`'s errdefer — the
    /// raise is not part of the recorded IR, so a surviving recording would
    /// stitch an enclosing pcall's post-catch continuation onto the partial
    /// iteration and could commit a Franken-path trace at the next anchor
    /// reach. Guarded (no-op when idle) so nested `execWith` unwind levels
    /// stay idempotent: the innermost aborts, outer levels see an inactive
    /// recording.
    pub fn abortRaised(self: *TraceState) void {
        if (self.rec.active) self.abort(.raised);
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

    /// Doc 31 D1: is `anchor` currently held off *recording* by the record
    /// gate? Same cooldown/permanence arithmetic as `isGated`, separate
    /// history — a record-gated anchor's committed traces keep dispatching.
    pub fn isRecordGated(self: *const TraceState, anchor: AnchorKey) bool {
        const g = self.record_gate.get(anchor) orelse return false;
        if (g.strikes >= self.config.max_strikes) return true;
        return self.tick < g.retry_at;
    }

    /// Doc 31 D1: recording eligibility consults BOTH gates — a
    /// dispatch-gated anchor also declines new recordings (preserving the
    /// old duplicate-suppression), and a record-gated anchor backs off
    /// re-recording without touching dispatch.
    pub fn recordingBarred(self: *const TraceState, anchor: AnchorKey) bool {
        return self.isGated(anchor) or self.isRecordGated(anchor);
    }

    /// Shared escalation arithmetic for both gate maps: start (or double) the
    /// cooldown window and bump the strike count. The next eligibility is
    /// `retry_at` = current global `tick` + window; the window then doubles
    /// (capped at `backoff_max`), and after `max_strikes` the anchor is
    /// abandoned for good. Deterministic — keyed only on the monotonic
    /// back-edge tick. Returns null on OOM (gate simply not escalated).
    fn bumpGateEntry(self: *TraceState, map: *std.AutoHashMapUnmanaged(AnchorKey, Gate), anchor: AnchorKey, reason: GateReason) ?*Gate {
        const gop = map.getOrPut(self.gpa, anchor) catch return null;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .retry_at = 0, .window = self.config.backoff_base, .strikes = 0, .reason = reason };
        }
        const g = gop.value_ptr;
        g.reason = reason;
        g.strikes +|= 1;
        g.retry_at = self.tick +| g.window;
        g.window = @min(g.window *| 2, self.config.backoff_max);
        return g;
    }

    /// Install or escalate the DISPATCH gate on `anchor` (doc 31 D1): its
    /// cached traces are not entered until the cooldown elapses. Sources:
    /// legacy thrash, region decay, native-unsupported — never recording
    /// failures (those go to `gateRecordAnchor`).
    pub fn gateAnchor(self: *TraceState, anchor: AnchorKey, reason: GateReason) void {
        const g = self.bumpGateEntry(&self.gate, anchor, reason) orelse return;
        // Doc 20 unpatch trigger: a dispatch-gated anchor must not keep a
        // patched entry — mark pending; the caller-owned safe-point drain
        // restores same-turn and warming re-decides after the cooldown. A
        // RECORD gate deliberately never unpatches (doc 31 §3).
        self.markEntryPatchesAt(anchor);
        self.dbg("gate[dispatch:{s}]: anchor pc={d} strikes={d} window={d} retry_at={d} tick={d}", .{ @tagName(reason), anchor.pc, g.strikes, g.window, g.retry_at, self.tick });
    }

    /// Install or escalate the RECORD gate on `anchor` (doc 31 D1): no new
    /// recording starts here until the cooldown elapses; committed traces
    /// keep dispatching and their entry patches stay live. Sources:
    /// recording aborts and commit failures (LuaJIT `penalty_pc` analog).
    pub fn gateRecordAnchor(self: *TraceState, anchor: AnchorKey, reason: GateReason) void {
        const g = self.bumpGateEntry(&self.record_gate, anchor, reason) orelse return;
        self.dbg("gate[record:{s}]: anchor pc={d} strikes={d} window={d} retry_at={d} tick={d}", .{ @tagName(reason), anchor.pc, g.strikes, g.window, g.retry_at, self.tick });
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
    ///
    /// Doc 31 D1 amendment (measured on the first post-split board): a RECORD-gated
    /// anchor with NO committed trace must also arm the skip — the slow path can
    /// do nothing there (no trace to enter, recording barred), and without the
    /// skip every abort-blacklisted hot loop pays full `onBackEdge` bookkeeping on
    /// every back-edge forever (tbl_ops +40%, euler14-bit +55%, nsieve-bit-fp
    /// +57% jit-vs-t0 drag; pre-split these anchors were dispatch-gated and
    /// skipped). A record-gated anchor WITH a trace must NOT skip: the slow path
    /// is exactly what enters its trace (the review-B3 starvation concern).
    pub fn afterBackEdge(self: *TraceState, proto: *const Proto, pc: u32) void {
        const key: AnchorKey = .{ .proto = proto, .pc = pc };
        if (self.isGated(key) or (self.isRecordGated(key) and !self.hasTrace(key))) {
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

    /// Part S / side-trace precision: consume a pending `wants_side_trace` at a
    /// LEDGER-burst deopt resume instead of waiting for the next back-edge.
    ///
    /// The back-edge consumption in `onBackEdge` is one iteration too late for a
    /// zero-progress deopt: the resume re-runs the FAILING iteration in tier-0, that
    /// iteration's closing back-edge arms the recording, and recording then starts on
    /// the iteration AFTER the failing one — which on an alternating-shape loop is
    /// almost always the other (already-traced) shape. Measured on nsieve N=9: the
    /// zero-trip exit crossed `hotguard`, and every recording it triggered captured
    /// the composite-skip path again — two duplicate traces and the zero-trip shape
    /// still stranded on the runtime turnstile. Arming AT the resume records the
    /// re-run of the failing iteration itself, so the captured path is by
    /// construction the one whose guard kept failing.
    ///
    /// Same guards as the back-edge consumption: gated anchors decline, and the
    /// anchor's failure counters reset so the next crossing needs fresh evidence.
    /// Returns true iff a recording was armed — the caller must then hand the
    /// dispatch loop to `.full` (recording records via the `.full` prologue mirror;
    /// arming from `.fast` and sailing on records NOTHING and commits an empty
    /// trace at the next back-edge, which is exactly what the first cut did).
    /// Arms via `pending_replay_anchor` → `maybeStartReplaySide`, the doc-16
    /// replay-side machinery built for precisely this "record the re-run of the
    /// current iteration from the coherent anchor" shape — not via a raw `arm()`,
    /// which is a back-edge-site primitive.
    pub fn consumeSideTraceWantAtResume(self: *TraceState, proto: *const Proto, resume_pc: u32) bool {
        const wanted = self.wants_side_trace orelse return false;
        if (wanted.proto != proto or wanted.pc != resume_pc) return false;
        const src = self.side_want_src;
        self.wants_side_trace = null;
        self.side_want_src = null;
        const key = AnchorKey{ .proto = proto, .pc = resume_pc };
        if (self.isRecording() or self.pending_replay_anchor != null or self.recordingBarred(key))
            return false;
        self.dbg("side-want-at-resume: arming replay-side recording at pc={d}", .{resume_pc});
        self.pending_replay_anchor = key;
        self.pending_replay_src = src;
        self.clearGuardFailures(key);
        return true;
    }

    /// Close an in-flight recording when dispatch reaches its anchor again through
    /// any control-flow edge. `onBackEdge` handles the common backward edge, but a
    /// nested loop may leave its anchor and later re-enter it through forward flow
    /// after an enclosing back-edge. Waiting for another matching back-edge then
    /// records multiple logical iterations, over-specialising every intervening
    /// branch and heap relation. Called before the dispatch mirror, so the anchor
    /// instruction belongs to the next iteration, not the one being committed.
    pub fn maybeCloseAtAnchor(self: *TraceState, proto: *const Proto, cur_pc: u32, regs: RegWindow) void {
        if (!self.rec.active or self.rec.instrs.items.len == 0) return;
        if (self.rec.anchor.proto == proto and self.rec.anchor.pc == cur_pc) {
            self.closeTrace(regs);
        }
    }

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
                if (!self.recordingBarred(key)) {
                    self.arm(proto, target_pc);
                    // Hotexit provenance rides into the recording so the commit
                    // can DONE-latch the parent exit (`arm` may decline — OOM —
                    // in which case `rec.active` is false and there is nothing
                    // to carry).
                    if (self.rec.active) self.rec.side_src = self.side_want_src;
                    // Clear guard-failure counters for this anchor so we don't
                    // immediately re-trigger on the next outer-loop iteration.
                    self.clearGuardFailures(key);
                }
                self.wants_side_trace = null;
                self.side_want_src = null;
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
        if (!self.recordingBarred(key)) {
            // A gate entry (either map, doc 31 D1) that is no longer barring
            // means its `tick` cooldown has just elapsed → take the one retry
            // now. Arming starts a recording, so the next back-edges are
            // consumed by recording rather than re-arming; we never loop
            // re-arming. A fresh (un-gated) anchor arms on the exact back-edge
            // it first crosses `hotloop`. The probe must consult BOTH maps:
            // recording aborts now live in `record_gate`, and without the
            // second `contains` an aborted root recording — whose warming
            // counter is already past the one-shot `== hotloop` crossing —
            // would never retry (doc 31 §3, review B3).
            const arm_now = if (self.gate.contains(key) or self.record_gate.contains(key))
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
        // Doc 27 §3a defense-in-depth: a dead recording must not leave a multret
        // shadow behind (`reset` is the soundness boundary; this narrows the
        // window further so no code path can observe a shadow past the abort).
        self.rec.multret_top = null;
        // Drop hot-exit provenance with the recording: an abort must never leave
        // `side_src` around to latch a parent exit DONE for a LATER, unrelated
        // commit (Pall retries the exit; `gateAnchor` below is our `penalty_pc`).
        self.rec.side_src = null;
        // Doc 38 unroll-first policy: a ROOT recording that chose to unroll an
        // inner while and then died — for ANY reason (too long, nyi op it only
        // reached because it kept going, guard depth, …) — is one proven
        // unroll failure at this outer anchor. At `unroll_fail_flip` failures
        // `recWhileLink` stops unrolling here and decomposes (LINNER).
        if (self.rec.kind == .root and self.rec.unrolled_while) {
            if (self.unroll_fail.getOrPut(self.gpa, self.rec.anchor)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* +|= 1;
                self.dbg("unroll-fail (record abort): anchor pc={d} count={d}", .{ self.rec.anchor.pc, gop.value_ptr.* });
            } else |_| {}
        }
        // Doc 38 LLEAVE fast retry: which pass a while/repeat-root recording
        // lands on (cond-true → the body root we want, cond-false → LLEAVE) is
        // a race against the loop's trip pattern, not evidence of
        // untraceability. Count the abort but skip the gate strike while under
        // budget, so the anchor retries at its next hot event; a loop that
        // exhausts the budget has proven a low/zero remaining-trip pattern and
        // strikes normally from then on (and unlocks `recWhileLink`'s
        // innerloopleft unroll). On OOM fall through to the normal strike —
        // fail-closed, never a hotter path.
        if (reason == .loop_leave) {
            if (self.lleave_count.getOrPut(self.gpa, self.rec.anchor)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* +|= 1;
                if (gop.value_ptr.* < self.config.lleave_fast_retries) {
                    // No gate entry is created, so `onBackEdge`'s retry probe
                    // (`gate.contains or record_gate.contains`) won't fire —
                    // and the warming counter is already past its one-shot
                    // `== hotloop` crossing (the review-B3 starvation shape).
                    // Rewind the counter so the next back-edge re-crosses and
                    // re-arms: the retry lands on the same instance's next
                    // trip, which is exactly the cond-true pass we want.
                    self.counters.put(self.gpa, self.rec.anchor, self.config.hotloop -| 1) catch {};
                    self.dbg("lleave fast-retry: anchor pc={d} count={d}", .{ self.rec.anchor.pc, gop.value_ptr.* });
                    return;
                }
            } else |_| {}
        }
        self.gateRecordAnchor(self.rec.anchor, .record_abort);
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

    /// Doc 39: ops admissible inside a type-stabilizing peel (the register-only
    /// rule, enforced over BOTH passes). A WHITELIST, fail-closed: any op not
    /// listed — stores (`astore`/`astore_append`/`hstore`/`gstore`), allocating
    /// producers (the `.alloc` class), match-scratch writers
    /// (`smatch`/`sfindp`/`sgmatch`/`scap_*`), the gmatch cursor
    /// (`sgm_setpos`), grid ops, `guard_gc`, and anything added later —
    /// declines the peel at pass 1 or aborts it at pass 2. Heap READS are
    /// admitted: effect-free, guarded, and their run-once values persist under
    /// the E1 executor contract.
    fn peelAdmissibleOp(op: IrOp) bool {
        return switch (op) {
            .konst,
            .slot_load,
            .phi,
            .preheader,
            .add,
            .sub,
            .mul,
            .div,
            .idiv,
            .mod,
            .pow,
            .band,
            .bor,
            .bxor,
            .shl,
            .shr,
            .sar,
            .eq,
            .ne,
            .lt,
            .le,
            .neg,
            .not,
            .bnot,
            .int_of_float,
            .guard_int,
            .guard_float,
            .guard_number,
            .guard_true,
            .guard_false,
            .guard_func,
            .guard_builtin,
            .fsqrt,
            .fsin,
            .fcos,
            .ffloor,
            .fceil,
            .aref,
            .aload,
            .href,
            .hload,
            .alen,
            .guard_table,
            .guard_lane,
            .guard_bounds,
            .guard_present,
            .guard_hash,
            .slen,
            .guard_string,
            .scp,
            => true,
            else => false,
        };
    }

    /// Doc 39 Phase 0/1 entry decision, called at the FIRST anchor-return of a
    /// recording (from `closeTrace`, before `commit` — never an error out of
    /// commit, which would gate `.commit_failure`). Returns true when
    /// `closeTrace` should return WITHOUT committing: either the peel was
    /// entered (marker emitted, recording continues into iteration 2), or a
    /// mid-entry OOM aborted the recording.
    ///
    /// Eligibility (doc 40 Phase 2 lifts the doc-39 `.root`-only gate): any
    /// recording kind closing as `.loop` at its own plain-while anchor — the
    /// reset-to-int glue records exclusively through the side / continuation
    /// channels (LLEAVE aborts a root on its anchor loop's own exit edge), so
    /// a `.root`-only peel fires on neither fft DOA shape. Side recordings
    /// that link elsewhere stay out (`link_target` below). The rest of the
    /// gate is unchanged: anchor frame closed (no inlining / multret shadow
    /// open), register-only iteration 1 (no pending stores, no allocations,
    /// whitelist-pure IR).
    ///
    /// The instability sweep (doc 40 Phase 3, bidirectional) covers the
    /// anchor window `[0, anchor_num_registers)` only, per-slot: a `.def`
    /// slot whose proven entry kind contradicts the numeric kind its carried
    /// value actually delivers at this anchor return. int-entry/float-carry
    /// is doc 39's RV-3-bailing forward shape; float-entry/int-carry is the
    /// F1-reverse reset-to-int shape (fft_bitreverse's `k = n`). The carried
    /// side reads the LIVE anchor-return register, not the ref's IR `ty` —
    /// an unguarded `slot_load` carries `.ty = .unknown` (exactly the `k = n`
    /// store), while recording is concrete execution, so the live value IS
    /// what the back-edge φ would deliver.
    fn maybeEnterPeel(self: *TraceState, regs: RegWindow) bool {
        if (!self.config.peel) return false;
        const rec = &self.rec;
        if (rec.link_target != null) return false;
        if (rec.inline_depth != 0) return false;
        if (rec.multret_top != null) return false;
        if (rec.pending_stores.items.len != 0) return false;
        if (rec.guard_gc_ref != null or rec.alloc_count != 0) return false;
        if (!isPlainWhileAnchor(rec.anchor.proto, rec.anchor.pc)) return false;
        // Instability sweep before the (linear) purity scan: the sweep is the
        // rarer pass condition, so most closes stop here. Bidirectional
        // (doc 40 Phase 3), per-slot — one recording may widen one slot and
        // narrow another; any single mismatch makes the close unstable.
        var unstable = false;
        for (rec.reg_map[0..rec.anchor_num_registers], 0..) |s, slot| {
            if (s.state != .def or s.entry_kind == .none) continue;
            const v = regs.get(@intCast(slot));
            unstable = switch (s.entry_kind) {
                .int => v.isFloat(),
                .float => v.isInt(),
                .none => unreachable,
            };
            if (unstable) break;
        }
        if (!unstable) return false;
        for (rec.instrs.items) |ins| {
            if (!peelAdmissibleOp(ins.op)) return false;
        }
        // Enter. Snapshot allocation first — a failure here declines cleanly
        // with the stream untouched (ordinary close proceeds).
        const slots = self.gpa.alloc(PeelSlot, rec.anchor_num_registers) catch return false;
        for (slots, rec.reg_map[0..rec.anchor_num_registers]) |*ps, s| {
            ps.* = .{ .ref = s.ref, .state = s.state };
        }
        _ = self.emit(.{ .op = .preheader }) catch {
            // The stream may hold a half-appended marker (instrs vs exit_prov
            // skew) — the recording cannot continue OR commit. Abort; `reset`
            // restores the invariant, exactly as any mid-recording emit OOM.
            self.gpa.free(slots);
            self.abort(.alloc);
            return true;
        };
        rec.peel = .{ .mark_len = rec.instrs.items.len, .slots = slots };
        self.dbg("peel: enter anchor pc={d} marker ir={d}", .{ rec.anchor.pc, rec.instrs.items.len - 1 });
        return true;
    }

    /// Doc 39 Phase 1 close, at the SECOND anchor-return of a peeled recording:
    /// verify the body pass stayed register-only (a forbidden effect means
    /// iteration 2 took a path iteration 1 didn't — abort, ordinary strikes)
    /// and type-stable, then patch every internal φ's back-edge `b` from the
    /// slot's body-final ref (or `a` — a constant carry — when the body only
    /// read it). Returns false when the recording must abort
    /// `.type_instability` instead of committing.
    fn finishPeel(self: *TraceState, p: *PeelState) bool {
        const rec = &self.rec;
        if (rec.link_target != null) return false; // a peeled root never link-closes
        if (rec.pending_stores.items.len != 0) return false;
        if (rec.guard_gc_ref != null or rec.alloc_count != 0) return false;
        for (rec.instrs.items[p.mark_len..]) |ins| {
            if (!peelAdmissibleOp(ins.op)) return false;
        }
        for (p.slots, 0..) |*ps, slot| {
            const pr = ps.phi_ref orelse continue;
            const phi_ins = &rec.instrs.items[@intCast(pr)];
            const cur = rec.reg_map[slot].ref;
            // Body redefined the slot → carry the body-final def; body only
            // read it → constant carry (`b = a`; the init is a run-once value
            // whose executor slot persists, so re-carrying it is exact).
            const b: Ref = if (cur != pr) cur else phi_ins.a;
            // Stability recheck against the φ's carried type (stamped from the
            // iteration-1 def at creation): a mismatch is a genuine
            // per-iteration flip-flop — uncompilable before the peel, stays so.
            if (rec.instrs.items[@intCast(b)].ty != phi_ins.ty) return false;
            phi_ins.b = b;
        }
        self.dbg("peel: close anchor pc={d} body ir={d}..{d}", .{
            rec.anchor.pc, p.mark_len, rec.instrs.items.len,
        });
        return true;
    }

    /// Doc 40 Phase 1 — commit preflight: would this `.loop` close be
    /// self-defeating? A trace whose entry fingerprint pins a carried slot to
    /// one numeric kind while its back-edge φ would store the other can never
    /// take its own back-edge: every entry runs exactly one iteration, exits
    /// on the entry guard, and the accounting machinery mistakes it for
    /// healthy forever (`completed > 0` clears the anchor penalty each entry;
    /// no want channel fires — the doc 40 "failure loop"). Such a close is
    /// refused BEFORE `commit` mutates anything (codex finding 4), keeping the
    /// anchor's accounting live and the producing channel retrying under the
    /// record gate.
    ///
    /// Scope (codex finding 6): proven int↔float contradictions only —
    /// `guard_number` matches both numeric kinds and non-numeric carried slots
    /// have legitimate specialized load/store relationships. The ENTRY side
    /// mirrors the fingerprint-extraction criteria exactly (a guard over a
    /// `slot_load` of an anchor-window slot — `matchesFingerprint` is what
    /// makes the contradiction fatal at re-entry); the STORE side reads the
    /// live anchor-return registers. Commit's φ-emission slot filter is
    /// mirrored too: a slot that gets no φ is never written at the back-edge,
    /// so its entry guard cannot be contradicted.
    fn loopCloseSelfDefeating(self: *const TraceState, regs: RegWindow) bool {
        // The live-value read below indexes the ANCHOR frame; at inline depth
        // the window belongs to a callee. Depth-0 covers every channel the
        // reset-to-int shape records through (glue side / continuation).
        if (self.rec.inline_depth != 0) return false;
        const instrs = self.rec.instrs.items;
        for (instrs, 0..) |ins, i| {
            const want_int = switch (ins.op) {
                .guard_int => true,
                .guard_float => false,
                else => continue,
            };
            const ref: usize = @intCast(ins.a);
            if (ref >= i or instrs[ref].op != .slot_load) continue;
            const slot: usize = @intCast(instrs[ref].aux);
            if (slot >= self.rec.anchor_num_registers) continue;
            const s = self.rec.reg_map[slot];
            if (s.state != .def) continue; // read-only slot: no φ, no back-edge write
            if (self.rec.alloc_count == 0 and
                slot >= self.rec.locals_watermark and !self.readSlot(@intCast(slot))) continue;
            // STORE side: the LIVE value at this anchor return. Recording is
            // concrete execution, so this is exactly what the φ delivers on
            // the recorded path. (The IR `ty` is useless here: an unguarded
            // `slot_load` store — the fft `k = n` reset — is `.unknown`.)
            const v = regs.get(@intCast(slot));
            if (want_int and v.isFloat()) return true;
            if (!want_int and v.isInt()) return true;
        }
        return false;
    }

    /// Finalise a cleanly-closed recording into a cached `Trace`. A build failure
    /// is treated like an abort (discard + gate-with-backoff) so we never thrash.
    ///
    /// Doc 39: this is also the peel's decision point, shared by BOTH
    /// anchor-arrival paths (`onBackEdge` + `maybeCloseAtAnchor`), which both
    /// funnel here. The `mark_len` equality check makes the marker-emitting
    /// return and its immediate re-arrival at the anchor ONE logical return
    /// regardless of which path fires first (a back-edge arrival calls
    /// `onBackEdge` then `maybeCloseAtAnchor` before anything records; a
    /// forward-flow arrival calls only `maybeCloseAtAnchor`).
    fn closeTrace(self: *TraceState, regs: RegWindow) void {
        if (self.rec.peel) |*p| {
            if (self.rec.instrs.items.len == p.mark_len) return; // same arrival
            if (!self.finishPeel(p)) {
                self.abort(.type_instability);
                return;
            }
        } else if (self.maybeEnterPeel(regs)) {
            return; // peel entered (keep recording iteration 2) or aborted
        }
        // Doc 40 Phase 1: refuse a self-defeating `.loop` close (entry
        // fingerprint contradicts a carried φ's numeric kind) for EVERY
        // recording kind — root, side, continuation — the glue channels are
        // precisely where the reset-to-int shape records (codex finding 1).
        // Peeled closes are legitimately entry≠steady by design; `.link`
        // closes carry no back-edge.
        if (self.rec.peel == null and self.rec.link_target == null and
            self.loopCloseSelfDefeating(regs))
        {
            self.dbg("commit refuse: anchor pc={d} self-defeating loop (entry kind vs phi store kind)", .{self.rec.anchor.pc});
            self.abort(.type_instability);
            return;
        }
        self.commit() catch |err| {
            self.dbg("commit failed: anchor pc={d} error={s} ir_len={d}", .{
                self.rec.anchor.pc,
                @errorName(err),
                self.rec.instrs.items.len,
            });
            self.gateRecordAnchor(self.rec.anchor, .commit_failure);
        };
        self.rec.active = false;
        // A successful `commit` consumed `side_src` (DONE latch); a failed one
        // must drop it too, so a stale key can never latch a later commit.
        self.rec.side_src = null;
    }

    /// B-2b commit publication: preserve the logical hotexit provenance only
    /// after the child is registered. A same-anchor relation OOM deliberately
    /// leaves the parent counter live (no DONE-without-edge); cross-anchor side
    /// traces retain the historical DONE latch but never create an arm relation.
    pub fn finishSideTraceProvenance(self: *TraceState, child: *Trace) void {
        const src = self.rec.side_src orelse return;
        defer self.rec.side_src = null;
        if (self.traceById(child.id) != child) return;
        const parent = self.traceById(src.trace_id) orelse return;
        var may_latch_done = true;
        if (parent.anchor.proto == child.anchor.proto and parent.anchor.pc == child.anchor.pc and
            src.exit_instr < parent.instrs.len)
        {
            self.provenance_edges.append(self.gpa, .{
                .parent_id = parent.id,
                .exit_instr = src.exit_instr,
                .child_id = child.id,
            }) catch {
                may_latch_done = false;
            };
            if (may_latch_done) {
                self.provenance_arms_pending = true;
                self.dbg("provenance-edge: t={d} ei={d} -> t={d}", .{ parent.id, src.exit_instr, child.id });
            }
        }
        if (may_latch_done and src.exit_instr < parent.exit_counts.len)
            parent.exit_counts[src.exit_instr] = Trace.EXIT_COUNT_DONE;
    }

    /// Copy the in-progress recording into an owned, cached `Trace`. The exit
    /// snapshot is every register the trace *defined* (its loop-carried writes).
    /// When `config.optimize`, the trace optimizer (`tropt.zig`) rewrites the IR
    /// first; an optimizer OOM falls back to caching the *unoptimized* trace
    /// (correct, just slower) rather than failing the commit.
    fn commit(self: *TraceState) !void {
        // Doc 24 D3: stamp the allocation bound `A` into the entry `guard_gc`'s
        // `aux` (emitted with a placeholder by `emitAlloc`). Stamped on the
        // RECORDED stream, before `tropt.optimize` — the optimizer may CSE an
        // `.alloc` op away (tostr repeats), which only makes the stamped bound a
        // conservative upper bound: a stricter guard is always sound.
        if (self.rec.guard_gc_ref) |gr| {
            std.debug.assert(self.rec.alloc_count > 0);
            self.rec.instrs.items[@intCast(gr)].aux = @intCast(self.rec.alloc_count);
        }
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
        for (self.rec.pending_stores.items) |ps| {
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
            // Doc 24 D3 full-write-set flush rule (codex #6): an ALLOCATING
            // trace flushes EVERY anchor-frame slot the body writes — including
            // dead expression temporaries the watermark filter would drop. The
            // collector roots every physical register below `stack_top`, not the
            // live set; a dead temp holding a per-iteration heap ref (a `tostr_*`
            // result) left at its *pre-burst* value would diverge the sweep's
            // root set from tier-0-only's (which holds the LAST iteration's
            // value there) → divergent de-intern sets → divergent ids. Flushing
            // the full written span makes post-burst regs equal tier-0's after
            // the same iterations exactly. Non-allocating traces keep the
            // watermark filter (arc-A shapes byte-identical: their traceable
            // loops cannot produce per-iteration heap temps).
            if (self.rec.alloc_count == 0 and
                slot >= self.rec.locals_watermark and !self.readSlot(@intCast(slot))) continue;
            // Doc 39: a peeled trace stamps each slot-bound φ's otherwise-
            // unused `a` with the slot's steady-state INTERNAL φ ref — the
            // durable slot↔φ association native analyze needs to connect the
            // entry load (run-once, entry-kinded) with the carried home
            // (internal-φ-kinded) without dataflow guessing (codex round-2
            // finding 4). `a = 0` = no internal φ: a write-before-read or
            // never-touched-in-body slot, the existing write-only class.
            const steady_phi: Ref = if (self.rec.peel) |p| blk: {
                if (slot < p.slots.len) {
                    if (p.slots[slot].phi_ref) |pr| break :blk pr;
                }
                break :blk 0;
            } else 0;
            try self.rec.instrs.append(self.gpa, .{
                .op = .phi,
                .a = steady_phi,
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
        // Doc 39 Phase 1b: peeled traces bypass `tropt` (the link-trace
        // precedent) — the optimizer's liveness roots have no concept of a
        // recorder-emitted `preheader` marker (it synthesizes its own during
        // compaction from a global invariance analysis) and would drop the
        // peel's run-once/steady split; CSE and guard dedup likewise span the
        // whole stream marker-blind. A marker-aware tropt is future work.
        const fields: tropt.Optimized = if (self.config.optimize and self.rec.link_target == null and self.rec.peel == null)
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
        // commit error, perturbing tiering, and `exit_prov` is region metadata (read
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
        // would perturb tiering, and `rec_path` is region metadata. On ANY
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
        // Doc 26 D1: does the committed IR carry a case-mapping op? (`.alloc`
        // ops are never DCE'd, so post-optimizer presence ≡ recorded.) The
        // commit itself is the first checkpoint of the pin invariant: the
        // recorder only reaches these ops by mirroring a successful tier-0
        // upper/lower, which pinned the session's Unicode version.
        var requires_unicode_pin = false;
        for (fields.instrs) |ins| {
            if (ins.op == .supper or ins.op == .slower) requires_unicode_pin = true;
        }
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
            .alloc_bound = self.rec.alloc_count,
            .requires_unicode_pin = requires_unicode_pin,
            .unrolled_while = self.rec.unrolled_while,
            .peeled = self.rec.peel != null,
        };
        // §T.9: memoize the pure `isCompositeBridgeCandidate` oracle over this trace's
        // instruction indices. Must run AFTER `t.*` is populated — the oracle reads the
        // finished trace (`instrs`, `anchor`, `provAt`). FAIL-SOFT: on OOM leave the memo
        // unbuilt, and `isBridgeCandidate` transparently falls back to the oracle, so a
        // failure costs speed and never correctness.
        buildBridgeCandMemo(self.gpa, t);
        errdefer if (t.bridge_cand.len != 0) self.gpa.free(t.bridge_cand);
        // Hotexit substrate (Pall's `snap->count`): one taken-exit counter per
        // committed instruction. FAIL-SOFT on OOM (empty ⇒ `noteTakenExit`
        // no-ops for this trace — hotness lost, correctness untouched).
        if (self.gpa.alloc(u8, fields.instrs.len)) |counts| {
            @memset(counts, 0);
            t.exit_counts = counts;
        } else |_| {}
        errdefer if (t.exit_counts.len != 0) self.gpa.free(t.exit_counts);
        try self.cache.append(self.gpa, t);
        bumpGen(&self.cache_gen); // invalidate Trace.anchor_pop_* memos
        // Register in the O(1) id index (fail-soft: on grow-OOM the id stays
        // unindexed and `traceById` falls back to the cache scan).
        if (t.id >= self.trace_by_id.items.len) {
            const old_len = self.trace_by_id.items.len;
            if (self.trace_by_id.resize(self.gpa, t.id + 1)) {
                @memset(self.trace_by_id.items[old_len..], null);
                self.trace_by_id.items[t.id] = t;
            } else |_| {}
        } else {
            self.trace_by_id.items[t.id] = t;
        }
        // Pall's `snap->count = SNAPCOUNT_DONE` at side-trace link (lj_trace.c:535):
        // this commit was triggered by a hot exit (`side_src` provenance followed
        // the want through consume → pending → recorder), so latch the parent's
        // exit — it now has its side trace and must never count again. The parent
        // may have been evicted mid-recording (`traceById` miss) — then there is
        // nothing to latch.
        self.finishSideTraceProvenance(t);
        // Coverage (gated): a trace now exists at this anchor, so subsequent
        // interpreted back-edges here are "fallback despite a trace."
        if (self.config.coverage) self.markAnchorTraced(t.anchor);
        // A-ii.2: refresh the structural-edge cache — the new trace may add edges
        // FROM itself AND make pre-existing traces' exits newly resolvable. Fail-soft
        // (never fails the commit); any OOM fails CLOSED to an empty cache (round-14
        // finding 6 — this new trace can add a boundary edge that invalidates a prior
        // region's owner, so retaining the prior snapshot could keep a stale arm).
        self.rebuildEdgeCache();
        // A-ii.4: rediscover regions over the refreshed graph. Fail-soft;
        // any OOM fails CLOSED to empty physical indices (arm nothing).
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
                // `alen` reads its sole table operand `a` (a prior node).
                .alen => std.debug.assert(ins.a < i),
                // `fsin`/`fcos`/`ffloor`/`fceil` read their sole numeric operand `a` (a prior node).
                .fsin, .fcos, .ffloor, .fceil => std.debug.assert(ins.a < i),
                // Doc 24 D4: `tostr_*` read their guarded numeric operand,
                // `slen`/`guard_string` their string operand — all prior nodes.
                // Doc 26: `supper`/`slower` read their string operand like `srev`.
                .tostr_int, .tostr_num, .slen, .guard_string, .srev, .schar1, .supper, .slower => std.debug.assert(ins.a < i),
                .srep2 => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < i);
                },
                // ssub's third operand rides `aux` as a Ref (doc 24 codex #4);
                // `scp` shares the three-operand encoding (doc 26 D3), as do
                // doc 30's `sfindp`/`smatch` (subject, init, pattern-in-aux).
                .ssub, .scp, .sfindp, .smatch => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < i);
                    std.debug.assert(ins.aux >= 0 and ins.aux < i);
                },
                // Doc 30 `sgmatch`: `a` = state ref; `aux` = konst-pool id
                // (an immediate, bounds-checked against the pool).
                .sgmatch => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len);
                },
                // Doc 30 projections: `a` = the match op ref; `b` = slot
                // immediate within the scratch geometry (never a ref).
                .scap_int, .scap_str => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(@as(usize, ins.b) < gc.MatchScratch.n_slots);
                },
                // Doc 30 str2num: unary on a proven-string ref.
                .str2num_i, .str2num_f => std.debug.assert(ins.a < i),
                // Doc 30 sgm_setpos: state ref + new-pos ref, both prior.
                .sgm_setpos => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < i);
                },
                // Doc 30 guard_sid: string ref + konst-pool id immediate.
                .guard_sid => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len);
                },
                // `guard_gc` (doc 24 D3): operand-free; `aux` is the allocation
                // bound `A` — a positive count stamped by `commit()`.
                .guard_gc => std.debug.assert(ins.aux > 0),
                // `guard_builtin` reads the callee ref `a`; `fsqrt` reads its float
                // operand `a` — both prior nodes.
                .guard_builtin, .fsqrt => std.debug.assert(ins.a < i),
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
                .aload, .guard_table, .guard_lane, .guard_present, .guard_fits, .guard_append, .hload, .guard_hash => {
                    std.debug.assert(ins.a < i);
                },
                // `guard_bounds` carries producer-dispatched semantics (doc 18 D3):
                // tier-1a selects the bounds rule from the producer op, so the
                // producer must be one of exactly two memory ops — `aref` (scalar
                // array key) or `garow` (grid row). Both are canonical-to-self in
                // `tropt` (never folded/CSE'd) and `a` is remapped through
                // compaction, so this holds post-optimization too; pin it so
                // malformed IR fails closed here rather than mis-dispatching.
                .guard_bounds => {
                    std.debug.assert(ins.a < i);
                    const producer = instrs[ins.a].op;
                    std.debug.assert(producer == .aref or producer == .garow);
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
                    // Doc 39: a slot-bound φ's `a` is either 0 (unused — no
                    // steady-state internal φ; the historical value) or the
                    // slot's INTERNAL φ (the durable slot↔φ association a
                    // peeled trace commits). Unambiguous: instruction 0 can
                    // never be a φ (its `a < i` requires i > 0).
                    if (ins.aux != PHI_INTERNAL and ins.a != 0) {
                        const assoc = instrs[@intCast(ins.a)];
                        std.debug.assert(assoc.op == .phi and assoc.aux == PHI_INTERNAL);
                    }
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
        // Doc 27: the multret shadow is visible to exactly one instruction — the
        // designated consumer immediately after its producer, mirroring tier-0's
        // `reg_top_pending` scope. Stash and clear before dispatch; only the
        // consumer arms (`recCall`/`recBuiltin`/`recReturn`) receive the stash,
        // and only producer arms re-set the field (on success).
        const multret = self.rec.multret_top;
        self.rec.multret_top = null;
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
            // Doc 38: while-inner nested-loop linking. A backward `jmp` whose
            // target already has a `.loop` root trace links to it (continuation/
            // side) or aborts LINNER (root), instead of unrolling the while body.
            // Forward jumps and jumps to unknown targets stay no-ops.
            .jmp => try self.recWhileLink(instr, regs, proto, pc),
            .jmp_if_false, .jmp_if_true => try self.recBranch(instr, regs, proto, pc),
            .for_loop => try self.recForLoop(instr, regs, pc),
            // Doc 30 c4: the generic-for back-edge — mirrors the CONTINUE
            // direction (first loop var non-nil → publish it as ctrl).
            .tfor_loop => try self.recTForLoop(instr, regs),
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
            // (`native`) call stays a trace barrier unless it carries a
            // `RecordedBuiltin` tag; anything we can't inline (vararg, `__call`,
            // too deep) aborts cleanly and tier-0 owns the loop. Dynamic multret
            // windows resolve against the one-instruction `multret` shadow
            // (doc 27) instead of aborting.
            .call => try self.recCall(instr, regs, proto, multret),
            .ret => if (self.rec.inline_depth == 0)
                // A `.ret` in the anchor frame closes the traced function itself —
                // the loop's back-edge always closes the trace first, so this is
                // only reached on an odd shape; abort rather than map results into a
                // caller we never inlined.
                self.abort(.cross_frame)
            else
                try self.recReturn(instr, multret),
            // `.halt` ends the top-level chunk; never a return from an inlined
            // callee. Always a barrier.
            .halt => self.abort(.cross_frame),

            // Table read `t[k]`: an INTEGER key takes the lane-aware packed-array
            // path (Phase B; in-bounds dense narrow-lane slot only); a constant
            // STRING key takes the hash-field path (doc 11, `obj.field`); anything
            // else aborts cleanly. The key type is observed at record time.
            // `#R[b]` (doc 23 D3 / doc 24 D4): a table records through the
            // guarded `alen` producer; a konst string folds to its `cp_len`
            // (code points — the `#s` semantic, deliberately distinct from
            // `rawlen`'s bytes). A NON-konst string records through the pure
            // `slen` producer: when its producing op already proves stringness
            // (`tostr_*` — proven by construction), `slen` rides bare; an
            // *observed* string (a loaded slot / hash load) pins first with
            // `guard_string`.
            .len => {
                const v = regs.get(instr.b);
                if (v.isHeap() and v.heapType() == .table) {
                    try self.recAlenShape(instr.a, instr.b, .b, regs);
                } else if (v.isHeap() and v.heapType() == .string) {
                    const rstr = try self.refOf(instr.b);
                    if (self.konstValueOf(rstr)) |kv| {
                        if (!kv.isHeap() or kv.heapType() != .string) return self.abort(.nyi_opcode);
                        const s = string_mod.String.fromHeader(kv.asHeap());
                        self.setReg(instr.a, try self.konst(Value.int(@intCast(s.cp_len))));
                    } else {
                        const proven = self.isProvenStringRef(rstr);
                        // Emitted raw; tropt's guard dedup (GuardKey) drops an
                        // exact duplicate — same discipline as `guard_table`.
                        if (!proven)
                            self.stampProv(try self.emit(.{ .op = .guard_string, .a = rstr }), .operand_type, .b, .neutral);
                        const r = try self.emit(.{ .op = .slen, .a = rstr, .ty = .int });
                        self.setReg(instr.a, r);
                    }
                } else return self.abort(.nyi_opcode);
            },

            // NUMBER covers the integral-float key (`v[j]` with `j` from float
            // division) — `recArrayGet` narrows it via `keyRefNarrowed` or aborts
            // `.bad_type` for a fractional float, same net abort as before.
            .get_index => if (regs.get(instr.c).isNumber())
                try self.recArrayGet(instr, regs)
            else if (isStringKey(regs.get(instr.c)))
                try self.recHashGet(instr, regs)
            else
                self.abort(.bad_type),

            // Table write `t[k]=v`: INTEGER key → packed-array write (Phase B,
            // in-bounds in-lane, C1 deopt-replay rule); constant STRING key →
            // hash-field write (doc 11, present-key overwrite only); else abort.
            .set_index => if (regs.get(instr.b).isNumber())
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
    pub fn emit(self: *TraceState, ins: IrInstr) !Ref {
        var ins_mut = ins;
        switch (ins_mut.op) {
            // `int_of_float` and `alen` are value-producing but also side-exit, so
            // they stamp their PC for exit-PC chaining like the type guards (their
            // `aux` is unused for anything else — the result kind is `.int`, the
            // operand is `a`).
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float, .alen => {
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

    /// Emit an `.alloc`-kind op (doc 24 D4): ensures the body's single
    /// `guard_gc` entry guard exists — emitted lazily immediately before the
    /// FIRST `.alloc` op, which places it before *every* `.alloc` op. That is
    /// the only ordering the D3 soundness argument needs: any effects that
    /// precede it in the body (inline `astore`s) are already required to be
    /// header-replay-idempotent by the C1 discipline (every later guard can
    /// fail below them today), and a failing `guard_gc` means ZERO allocations
    /// were performed this iteration, so the D2 corollary's clean-replay
    /// premise holds at its exit. The guard's `aux` (the bound `A`) is a
    /// placeholder until `commit()` stamps the final `alloc_count`.
    fn emitAlloc(self: *TraceState, ins: IrInstr) !Ref {
        if (self.rec.guard_gc_ref == null) {
            self.rec.guard_gc_ref = try self.emit(.{ .op = .guard_gc });
        }
        self.rec.alloc_count += 1;
        return self.emit(ins);
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
    pub fn refOf(self: *TraceState, slot: u16) !Ref {
        // Translate the frame-relative `slot` into a `reg_map` index by the current
        // frame's absolute offset (0 for the anchor frame; cross-frame tracing
        // raises it inside an inlined callee). A `slot_load` is only ever emitted
        // for an anchor-frame slot: S1 pre-seeds every callee slot `.def` at the
        // inlining `.call`, so a callee index is never `.undef` here — the
        // executor's `slot_load aux` therefore always lands in `[0,
        // anchor_num_registers)`.
        const abs: usize = self.rec.base_off + slot;
        const s = &self.rec.reg_map[abs];
        if (s.state != .undef) {
            // Doc 39: inside a peel's body pass, the first read of an
            // anchor-window slot iteration 1 DEFINED lazily creates the
            // internal φ carrying its steady state — `a` = the iteration-1
            // ref (a run-once value), `b` patched at close — and rebinds the
            // slot so every later consumer naturally uses the φ (φ-before-use
            // falls out of laziness; no operand rewrite pass exists). Slots
            // still `.input` at the marker (invariant reads) and slots the
            // body already wrote (`rebound`, incl. write-before-read — no
            // cross-iteration dataflow of their own) are referenced directly.
            if (self.rec.peel) |*p| {
                if (abs < self.rec.anchor_num_registers) {
                    const ps = &p.slots[abs];
                    if (!ps.rebound and ps.state == .def) {
                        const phi_ref = try self.emit(.{
                            .op = .phi,
                            .a = ps.ref,
                            .b = 0, // patched by finishPeel
                            .aux = PHI_INTERNAL,
                            .ty = self.rec.instrs.items[@intCast(ps.ref)].ty,
                        });
                        ps.rebound = true;
                        ps.phi_ref = phi_ref;
                        s.* = .{ .ref = phi_ref, .state = .def, .entry_kind = s.entry_kind };
                        return phi_ref;
                    }
                }
            }
            return s.ref;
        }
        const aux: i32 = @intCast(abs);
        const ref = try self.emit(.{ .op = .slot_load, .aux = aux, .ty = .unknown });
        try self.rec.entry_slots.append(self.gpa, @intCast(abs));
        // A fresh `slot_load` resets `entry_kind` to `.none` by construction:
        // the slot was `.undef`, so no proof can have covered it yet.
        s.* = .{ .ref = ref, .state = .input };
        return ref;
    }

    /// Doc 39 Phase 0 (central capture, codex round-2 finding 11): a numeric
    /// type proof just covered `ref`. If `ref` is an anchor-window `slot_load`,
    /// stamp the slot's `entry_kind` — keyed off the *instruction* (a
    /// `slot_load` carries its absolute slot in `aux`), so the stamp works
    /// regardless of which proof route got here first, after the slot has been
    /// redefined, and even when `guarded_refs` dedup suppresses the guard's
    /// emission (the proof exists either way). First proof wins: the entry
    /// value has exactly one runtime kind per recording, so later proofs agree.
    fn noteEntryKind(self: *TraceState, ref: Ref, kind: EntryKind) void {
        const ins = self.rec.instrs.items[@intCast(ref)];
        if (ins.op != .slot_load) return;
        const abs: usize = @intCast(ins.aux);
        // Synthetic input slots (upvalue/global/hash-cell snapshots) reuse the
        // `slot_load` op with `aux >= anchor_num_registers`; that aux is an
        // executor window index, NEVER a `reg_map` index — don't alias the
        // inlined-callee scratch the `reg_map` tail reserves.
        if (abs >= self.rec.anchor_num_registers) return;
        const s = &self.rec.reg_map[abs];
        if (s.entry_kind == .none) s.entry_kind = kind;
    }

    /// Doc 39: the lane-implied variant of `noteEntryKind` for the `guard_fits`
    /// proof route (emitted directly, not via `guard`). Fit implies type for the
    /// narrow lanes: the int store-shape lanes (`Lane.isInt`) prove the value
    /// int, `.f64` proves float; `.boolean`/`.value`/`.grid` prove no numeric
    /// kind and stamp nothing.
    fn noteEntryKindFromLane(self: *TraceState, ref: Ref, lane: arr.Lane) void {
        if (lane.isInt()) {
            self.noteEntryKind(ref, .int);
        } else if (lane == .f64) {
            self.noteEntryKind(ref, .float);
        }
    }

    /// Record that tier-0 register `slot` (in the current frame) now holds the
    /// value produced by `ref` (a loop-carried write — surfaces in the exit
    /// snapshot). Offset by `base_off` like `refOf`.
    fn setReg(self: *TraceState, slot: u16, ref: Ref) void {
        self.defineSlotAbs(self.rec.base_off + slot, ref);
    }

    /// The single whole-`RegSlot` define: every write that replaces a slot's
    /// binding (`setReg`, inlined-callee seeding, return mapping) funnels here
    /// so that (a) `entry_kind` SURVIVES the write (doc 39 — `k = k/2` must not
    /// erase the evidence that `k` entered int; codex round-2 finding 2), and
    /// (b) an in-flight peel marks the slot `rebound` (a body write before any
    /// read means "no internal φ" — the write-before-read class).
    fn defineSlotAbs(self: *TraceState, abs: usize, ref: Ref) void {
        if (self.rec.peel) |*p| {
            if (abs < self.rec.anchor_num_registers) p.slots[abs].rebound = true;
        }
        const s = &self.rec.reg_map[abs];
        s.* = .{ .ref = ref, .state = .def, .entry_kind = s.entry_kind };
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
        // Doc 39: stamp the slot's proven entry kind BEFORE the dedup return —
        // the proof exists even when the guard emission is suppressed.
        switch (op) {
            .guard_int => self.noteEntryKind(ref, .int),
            .guard_float => self.noteEntryKind(ref, .float),
            else => {},
        }
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

    /// Record-time view of an array get/set KEY: the integer index tier-0's
    /// `table.normalizeKey` resolves the key to, or null when the access is hash
    /// territory (fractional float / non-number) and the caller must abort
    /// `.bad_type`. The SAME `value.floatAsExactInt` predicate underpins
    /// `normalizeKey`, tier-1a's `int_of_float`, and the native `cvttsd2si`
    /// round-trip, so all four agree bit-for-bit.
    fn keyIndexOf(vkey: Value) ?i64 {
        if (vkey.isInt()) return vkey.asInt();
        if (vkey.isFloat()) return value.floatAsExactInt(vkey.asFloat());
        return null;
    }

    /// Emit the int-typed key ref for an array get/set whose record-time key
    /// `keyIndexOf` already accepted. An int key type-guards as before
    /// (`guard_int`, dedup'd). An integral-FLOAT key — e.g. fft_bitreverse's
    /// `j`, made float by `k = k/2` float division — NARROWS: `guard_float` on
    /// the operand, then `int_of_float`, the same guarded float→int op the
    /// float-loop-limit specialization uses (all three tiers lower it; native
    /// requires exactly this dominating `guard_float`, nativegen.zig ~1522).
    /// This is the recorder mirror of tier-0's `normalizeKey` (LuaJIT:
    /// `lj_opt_narrow` index narrowing): a later NON-integral float at the same
    /// site side-exits `int_of_float` → tier-0 resumes with its exact hash-part
    /// semantics, so the fractional case is never on-trace, just not fast.
    fn keyRefNarrowed(self: *TraceState, key_reg: u16, operand: OperandDesig, vkey: Value) !Ref {
        const rkey = try self.refOf(key_reg);
        if (vkey.isInt()) {
            try self.guardInt(rkey, .key_type, operand);
            return rkey;
        }
        std.debug.assert(vkey.isFloat()); // caller gated on keyIndexOf != null
        try self.guard(rkey, .guard_float, .key_type, operand);
        const iof = try self.emit(.{ .op = .int_of_float, .a = rkey, .ty = .int });
        self.stampProv(iof, .key_int, operand, .neutral);
        return iof;
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
        // Native exact mixed int/float comparison cannot round the int through f64
        // (`compareIntFloat` deliberately does not). When the observed float is
        // integral, narrow only that operand and compare two ints. A later
        // fractional float exits at `int_of_float` before any sunk store executes,
        // and tier-0 replays with the full exact mixed-number semantics.
        if (vb.isInt() and vc.isFloat() and value.floatAsExactInt(vc.asFloat()) != null) {
            rc = try self.emit(.{ .op = .int_of_float, .a = rc, .ty = .int });
            self.stampProv(rc, .operand_int, .c, .neutral);
        } else if (vb.isFloat() and vc.isInt() and value.floatAsExactInt(vb.asFloat()) != null) {
            rb = try self.emit(.{ .op = .int_of_float, .a = rb, .ty = .int });
            self.stampProv(rb, .operand_int, .b, .neutral);
        }
        if (swap) {
            const t = rb;
            rb = rc;
            rc = t;
        }
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    // --- index-recording shapes (doc 23 D3) --------------------------------
    //
    // The `get_index`/`set_index` opcode arms and the call-shaped `rawget`/
    // `rawset` builtins record the SAME guarded access — on a metatable-free
    // table (which every shape re-proves with `guard_table` after aborting
    // `.has_metatable` at record time) raw and non-raw access are one
    // operation. So the cores are shape functions over an explicit slot frame:
    // which guest register plays table/key/value/dest, plus how each guard's
    // operand is designated in exit provenance (`.b`/`.c` for the opcodes,
    // `.a1`/`.a2`/`.a3` — call args — for the builtins).

    /// Slot frame for the read shapes: `dst` receives the loaded value.
    const GetFrame = struct {
        dst: u16,
        tab: u16,
        key: u16,
        tab_od: OperandDesig,
        key_od: OperandDesig,
    };

    /// Slot frame for the write shapes: `val` is the stored value's register.
    const SetFrame = struct {
        tab: u16,
        key: u16,
        val: u16,
        tab_od: OperandDesig,
        key_od: OperandDesig,
        val_od: OperandDesig,
    };

    /// Record `t[k]` (`get_index`, `dst=a b=table c=key`) as an array read.
    ///
    /// **Narrow lanes** (i8–i64/f64/u8/boolean): emits `guard_table` + `guard_lane`
    /// on the table ref, `guard_int` on the key, then `aref` + `guard_bounds` +
    /// `guard_present` + `aload`. The result is a scalar value.
    ///
    /// **`.value` lane** (the type-erased lane holding full 16-byte Values): emits the
    /// same prefix but omits `guard_present` (`.value` lane has no presence bitmap —
    /// nil is in-band) and appends a type guard on the *loaded value*. Two element
    /// shapes are recordable:
    ///   * a **table** with no metatable — the array-of-structs pattern
    ///     (`bodies[i].x`), pinned by `guard_table` on the load. The result is a heap
    ///     table ref subsequent `recHashGet`/`recHashSet` calls chain from.
    ///   * an **int or float** — the mixed/erased numeric array (doc 32), pinned by
    ///     `guard_int`/`guard_float`. Arises whenever an int-lane array takes a float
    ///     store (or vice versa): `widenFor` has no cross-family rung, so the array
    ///     erases to `.value` permanently.
    ///
    /// Aborts (leaving tier-0 untouched) when:
    ///   * non-table container or non-int key → `.bad_type`;
    ///   * out-of-bounds or hole at record time → `.bad_type`;
    ///   * `.value`-lane with a bool, string, or function element → `.nyi_opcode`
    ///     (no strict type guard pins those — doc 32 §3);
    ///   * element table has a metatable → `.has_metatable`.
    fn recArrayGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        return self.arrayGetShape(regs, .{ .dst = instr.a, .tab = instr.b, .key = instr.c, .tab_od = .b, .key_od = .c });
    }

    fn arrayGetShape(self: *TraceState, regs: RegWindow, f: GetFrame) !void {
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        const idx = keyIndexOf(vkey) orelse return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent slot could fire `__index` (chunk 2a). Even a
        // present slot today could become a hole on a later iteration, so the only
        // sound conservative choice is to bail the whole trace to tier-0.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        if (!arr.ArrayPart.inArray(idx, tbl.array.asize)) return self.abort(.bad_type);
        const loaded = tbl.getInt(idx);
        if (loaded.isNil()) return self.abort(.bad_type); // hole — not a profitable trace

        if (lane == .value) {
            // The `.value` lane stores full 16-byte Values (tag+payload, nil in-band).
            // Two element shapes are recordable, distinguished only by the *trailing*
            // type guard on the loaded ref — the address/bounds prefix is identical:
            //
            //   * a **table** with no metatable — the array-of-structs pattern
            //     (`bodies[i].x`), guarded by `guard_table` on the load;
            //   * an **int or float** — the mixed/erased numeric array (doc 32),
            //     guarded by `guard_int`/`guard_float` on the load.
            //
            // Everything else (bool, string, function) stays nyi: neither has a
            // *strict* type guard that pins the element so a later iteration changing
            // it side-exits — `guard_true` would wave a truthy heap value through, and
            // a string element would additionally need `guard_string` plumbing. This
            // is the same int/float restriction `hashGetShape` applies to hash fields,
            // for the same reason.
            const elem_is_table = loaded.isHeap() and loaded.heapType() == .table;
            const elem_is_num = loaded.isInt() or loaded.isFloat();
            if (!elem_is_table and !elem_is_num) return self.abort(.nyi_opcode);
            if (elem_is_table) {
                const elem_tbl = table_mod.Table.fromHeader(loaded.asHeap());
                if (elem_tbl.metatable != null) return self.abort(.has_metatable);
            }

            const lane_ord: i32 = @intFromEnum(lane); // 0 for .value
            const rtab = try self.refOf(f.tab);
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
            self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
            const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
            if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, idx)) return;
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
            // No guard_present: the `.value` lane has no presence bitmap — nil is
            // encoded in-band (tag == .nil). A nil element fails the trailing type
            // guard below (nil is neither a heap_ref nor a number) and side-exits to
            // tier-0. Correct for both element shapes.
            const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
            // Fused native producer-exit (A-i.3): the native `.value` `aload` tag-checks
            // the loaded element against the tag its recorded `ty` implies and side-exits
            // there, with no `guard_*` node — so the exit identity rides the `aload`
            // itself. The recorder still emits the guard below for the tier-1a oracle;
            // native discharges it statically (proven kind) and emits nothing.
            self.stampProv(rload, .element_type, .loaded, .neutral);
            // Pin the element's type so a later iteration changing it side-exits.
            if (elem_is_table) {
                self.stampProv(try self.emit(.{ .op = .guard_table, .a = rload }), .element_type, .loaded, .neutral);
            } else {
                try self.guardNum(rload, loaded, .element_type, .loaded);
            }
            self.setReg(f.dst, rload);
            return;
        }

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
        const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
        if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, idx)) return;
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_present, .a = ref }), .present, .none, .neutral);
        const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
        self.setReg(f.dst, rload);
    }

    /// Resolve an array load against the recorder's deferred-store buffer using
    /// LuaJIT's `aa_ahref` rule: forward only on a statically must-alias key, skip
    /// only on a statically no-alias key, and abort on ambiguity. In particular we
    /// never guard the record-time equality of two loop-varying keys — that pins an
    /// incidental per-iteration relation and makes a valid trace a turnstile.
    /// Walking newest-to-oldest preserves last-writer-wins.
    fn forwardPendingArrayLoad(self: *TraceState, dst: u16, rtab: Ref, rkey: Ref, idx: i64) !bool {
        _ = idx; // observed values never decide aliasing
        var n = self.rec.pending_stores.items.len;
        while (n > 0) {
            n -= 1;
            const ps = self.rec.pending_stores.items[n];
            switch (ps.op) {
                .astore => {},
                // A present hash overwrite cannot change an array slot.
                .hstore => continue,
                // Doc 30: a pending `sgm_setpos` DOES write an array cell
                // (the gmatch state's slot 3) — fail closed on any store op
                // this classifier wasn't written for.
                else => {
                    self.abort(.bad_type);
                    return true;
                },
            }
            const addr = self.rec.instrs.items[ps.aref];
            std.debug.assert(addr.op == .aref);
            if (addr.a != rtab) {
                self.abort(.bad_type);
                return true;
            }
            switch (self.classifyArrayKeyAlias(rkey, addr.b)) {
                .must => {
                    self.setReg(dst, ps.value);
                    return true;
                },
                .no => continue,
                .may => {
                    self.abort(.bad_type);
                    return true;
                },
            }
        }
        return false;
    }

    /// Resolve a hash load against the deferred-store buffer (doc 08 §2026-08-20,
    /// LuaJIT's `aa_href`). Every key that reaches the hash recorders is an
    /// interned-string `.konst` (dispatch routes numeric keys to the array path),
    /// so key identity is exactly konst-ref equality — interning + `konst()`'s
    /// `(tag, bits)` dedup make equal content ⇔ the same ref. Walks newest→oldest
    /// (last-writer-wins; `commit()` flushes oldest→newest — the pair keeps
    /// repeated same-cell stores exact). Returns `true` when the load was resolved
    /// (value forwarded or recording aborted); `false` → caller emits the heap read.
    fn forwardPendingHashLoad(self: *TraceState, dst: u16, rtab: Ref, rkey: Ref) bool {
        var n = self.rec.pending_stores.items.len;
        while (n > 0) {
            n -= 1;
            const ps = self.rec.pending_stores.items[n];
            switch (ps.op) {
                // An in-bounds array store (the only array op ever buffered —
                // `astore_append` is emitted inline) can neither grow the array nor
                // migrate a hash cell, and every recordable hash key is a string:
                // NO alias, keep scanning.
                .astore => continue,
                .hstore => {},
                // Fail closed on any store op this classifier wasn't written for.
                else => {
                    self.abort(.bad_type);
                    return true;
                },
            }
            const addr = self.rec.instrs.items[ps.aref];
            std.debug.assert(addr.op == .href);
            // Distinct interned-string keys are distinct cells regardless of which
            // table each ref holds → NO.
            if (addr.b != rkey) continue;
            // Same key + same table SSA ref → MUST: forward the newest pending
            // value. Its type is already pinned by the store-side `guardNum`, and
            // at record time tier-0 has executed the store, so the observed loaded
            // value IS the stored value.
            if (addr.a == rtab) {
                self.setReg(dst, ps.value);
                return true;
            }
            // Same key, unproven table identity (two SSA refs may hold the same
            // table at runtime) → MAY: abort fail-closed. Never guard a runtime
            // identity relation between loop-varying refs.
            self.abort(.bad_type);
            return true;
        }
        return false;
    }

    fn classifyArrayKeyAlias(self: *const TraceState, lhs: Ref, rhs: Ref) AliasClass {
        if (lhs == rhs) return .must;
        const lc = self.intKonstRef(lhs);
        const rc = self.intKonstRef(rhs);
        if (lc != null and rc != null) return if (lc.? == rc.?) .must else .no;
        const la = self.affineIntKey(lhs, 0) orelse return .may;
        const ra = self.affineIntKey(rhs, 0) orelse return .may;
        if (la.base != ra.base) return .may;
        return if (la.offset == ra.offset) .must else .no;
    }

    fn intKonstRef(self: *const TraceState, ref: Ref) ?i64 {
        if (ref >= self.rec.instrs.items.len) return null;
        const ins = self.rec.instrs.items[ref];
        if (ins.op != .konst or ins.aux < 0) return null;
        const ci: usize = @intCast(ins.aux);
        if (ci >= self.rec.consts.items.len) return null;
        const v = self.rec.consts.items[ci];
        return if (v.isInt()) v.asInt() else null;
    }

    /// Canonicalise integer `base + constant` chains. Distinct offsets from the
    /// same SSA base cannot alias; unrelated bases remain MAY. The recursion is
    /// bounded defensively even though SSA operands point backward.
    fn affineIntKey(self: *const TraceState, ref: Ref, depth: u8) ?AffineIntKey {
        if (depth == 16 or ref >= self.rec.instrs.items.len) return null;
        const ins = self.rec.instrs.items[ref];
        if (ins.op != .add or ins.ty != .int) return .{ .base = ref, .offset = 0 };
        if (self.intKonstRef(ins.a)) |c| {
            var key = self.affineIntKey(ins.b, depth + 1) orelse return null;
            key.offset +%= c;
            return key;
        }
        if (self.intKonstRef(ins.b)) |c| {
            var key = self.affineIntKey(ins.a, depth + 1) orelse return null;
            key.offset +%= c;
            return key;
        }
        return .{ .base = ref, .offset = 0 };
    }

    /// Record `t[k]=v` (`set_index`, `a=table b=key c=value`) as a lane-aware
    /// packed-array write. Emits, in order: `guard_table` + `guard_lane` on the
    /// table ref, `guard_int` on the key, then `aref` + `guard_bounds` + `astore`
    /// — the FIRST mid-iteration heap mutation in the system. Aborts (leaving
    /// tier-0 untouched) unless the store is a *present, in-bounds, in-lane*
    /// slot whose value is deopt-replay-safe:
    ///   * non-table container or non-integral key → `.bad_type` (hash-part /
    ///     metatable territory, out of scope; an integral-FLOAT key narrows via
    ///     `keyRefNarrowed`, mirroring tier-0's `normalizeKey`);
    ///   * `.value`-lane array with a non-numeric value → `.nyi_opcode`. An int or
    ///     float IS recordable there (doc 32): every value fits the type-erased lane,
    ///     so no widen can be forced, and `guardNum` on the stored value replaces the
    ///     vacuous `guard_fits` as the type pin. A heap value stays out — it would be
    ///     the one shape needing a real write barrier under a future
    ///     generational/incremental collector. A `.value`-lane *append* is also still
    ///     out of scope: the append branch admits only bool/int lanes, so a `.value`
    ///     append falls through to the bounds check and aborts `.bad_type`;
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
        return self.arraySetShape(regs, .{ .tab = instr.a, .key = instr.b, .val = instr.c, .tab_od = .a, .key_od = .b, .val_od = .c });
    }

    fn arraySetShape(self: *TraceState, regs: RegWindow, f: SetFrame) !void {
        // NB (Gap C): unlike the single-store original, a store arriving while other
        // stores are already deferred is NOT blanket-aborted here. An in-bounds RMW
        // store appends to `pending_stores` (the in-bounds path below); an *append*
        // store (which changes `len`) must still abort — handled in the append branch.
        // The pending-store checks live at those two sites, not at the top,
        // because we cannot tell append-vs-in-bounds until we know `idx`/`len` below.
        // See `docs/design/08-multi-store-sinking.md`.
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
        const vval = regs.get(f.val);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        const idx = keyIndexOf(vkey) orelse return self.abort(.bad_type);
        if (vval.isNil()) return self.abort(.bad_type); // hole-punch — out of scope
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent-key store could fire `__newindex` (chunk 2a);
        // the append path below stores to exactly such an absent key (`len+1`).
        // Abort the whole trace to tier-0, which does full `__newindex` dispatch.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        // `.value`-lane store (doc 32): the type-erased lane holds full 16-byte
        // Values, so *any* value fits and no widen can ever be forced. Admitted for
        // **int/float** values only — the same restriction `hashSetShape` applies,
        // and for the same reason: those are the values with a strict type guard
        // (`guard_int`/`guard_float`) that keeps the cell scalar on-trace. A heap
        // value would additionally be the one shape needing a real write barrier
        // under any future generational/incremental collector.
        if (lane == .value and !(vval.isInt() or vval.isFloat())) return self.abort(.nyi_opcode);

        // Grow (append) store: `t[asize] = v` extends the dense run by one (doc 18
        // D2.3: under identity mapping the contiguous successor key IS `asize`).
        // This is
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
            idx == @as(i64, @intCast(tbl.array.asize)) and
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
            const rval = try self.refOf(f.val);
            const lane_ord: i32 = @intFromEnum(lane);
            const rtab = try self.refOf(f.tab);
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
            self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
            const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            // guard_append: hash-empty + `idx==asize` + `asize<cap`. The grow analogue
            // of guard_bounds — side-exits to tier-0 (which reallocs/migrates) when
            // any precondition fails, so the on-trace append never allocates.
            self.stampProv(try self.emit(.{ .op = .guard_append, .a = ref }), .append_precond, .none, .neutral);
            // guard_fits: the value still fits the narrow lane (the oracle re-checks a
            // free-variable store; native bool already proves `.bool`). Same as astore.
            self.noteEntryKindFromLane(rval, lane); // doc 39: fit implies type
            self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord }), .value_fits, f.val_od, .neutral);
            _ = try self.emit(.{ .op = .astore_append, .a = ref, .b = rval, .aux = lane_ord });
            return;
        }

        if (!arr.ArrayPart.inArray(idx, tbl.array.asize)) return self.abort(.bad_type);
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
        // exactly once. The virtual store buffer grows only within `maxrecord`, and
        // flushes in recorded order. A later array load either forwards from it or
        // proves non-aliasing with fail-closed guards; append remains unsupported
        // because it changes shape. A pure-write store (no prior `aload`) is
        // deopt-idempotent and emits inline as before.
        const defer_store = self.traceHasHeapLoad();
        const rval = try self.refOf(f.val);

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
        const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
        // Pin the stored value's type. Which guard does that depends on the lane, and
        // exactly one of the two is emitted:
        //
        // **Narrow lane → `guard_fits`.** The value must still fit the recorded lane:
        // a later iteration storing an out-of-lane value (an out-of-range/non-int int
        // into an int lane, a non-bool into the bool lane, a non-float into f64) would
        // force tier-0 to WIDEN the lane (alloc + relayout), which the native store
        // can't do mid-run and which would trip the tier-1a oracle's in-place
        // `setInLane` encode (`assert(fits(val))`) — so `guard_fits` side-exits
        // instead and lets tier-0 re-run + widen. The `astore` value can be a free
        // variable (a loop-carried slot), not just a constant, so the recorder cannot
        // assume it stays in-lane. For the bool lane native lowers this to nothing —
        // the value is already proven `.bool` at analysis time — but the oracle, which
        // runs the raw trace, still needs the runtime check. Fit implies type here
        // (`laneFits(.i32, v)` requires `v.isInt()`), so this doubles as the type pin.
        //
        // **`.value` lane → `guardNum` (doc 32).** `laneFits(.value, _)` is
        // unconditionally true, so `guard_fits` would degenerate to a no-op that pins
        // NOTHING — tropt would fold it as always-pass, and the oracle's `fits` assert
        // passes for any value. Recording observed an int/float once; that does not
        // make the producing ref numeric on a later iteration. Without an explicit
        // pin, tier-1a would store a drifted bool/heap into the cell while native had
        // assumed a numeric kind — an oracle divergence. This is the same guard, for
        // the same reason, that `hashSetShape` emits on a hash-cell store: neither
        // site has a lane to constrain the value. It also carries the *forwarded*
        // read: `forwardPendingArrayLoad` returns before any load guard is emitted, so
        // a forwarded `.value` load inherits its type pin entirely from here.
        if (lane == .value) {
            try self.guardNum(rval, vval, .value_type, f.val_od);
        } else {
            self.noteEntryKindFromLane(rval, lane); // doc 39: fit implies type
            self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord }), .value_fits, f.val_od, .neutral);
        }
        // No `guard_present`: on a narrow lane `astore` *creates* presence (the slot
        // is in-bounds by `guard_bounds`; storing a non-nil value sets the presence
        // bit), and the `.value` lane has no presence bitmap at all — nil is in-band,
        // and the store writes a non-nil value by the `isNil` abort above. The store
        // is effectful and not register-defining, so nothing is `setReg`'d.
        if (defer_store) {
            // Read-modify-write: stash the store; `commit()` flushes it (and any
            // siblings) below every guard, just before `.loop`, in this recorded
            // order. The guards above (table/lane/int/bounds/fits) stay inline and
            // continue to dominate the sunk store.
            try self.rec.pending_stores.append(self.gpa, .{
                .aref = ref,
                .value = rval,
                .lane_ord = lane_ord,
            });
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
        if (self.rec.pending_stores.items.len > 0) return self.abort(.bad_type);
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
    ///   * a pending (sunk) store that MAY-aliases this load → `.bad_type` (doc 08
    ///     §2026-08-20): the deferred-store buffer is consulted first via
    ///     `forwardPendingHashLoad` — a MUST-alias forwards the pending value, a
    ///     proven NO falls through to the heap read, and only the ambiguous
    ///     same-key/different-table-ref case aborts fail-closed.
    fn recHashGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        return self.hashGetShape(regs, .{ .dst = instr.a, .tab = instr.b, .key = instr.c, .tab_od = .b, .key_od = .c });
    }

    fn hashGetShape(self: *TraceState, regs: RegWindow, f: GetFrame) !void {
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
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
        const rkey = try self.refOf(f.key);
        if (self.rec.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

        const rtab = try self.refOf(f.tab);
        // Resolve against the deferred-store buffer BEFORE emitting the load chain
        // (doc 08 §2026-08-20): a MUST-alias forwards the pending value (the store
        // side already emitted `guard_table`/`href`/`guard_hash`/`guardNum` on this
        // same table ref + key konst, so no chain is re-emitted here), NO keeps
        // scanning / falls through to the heap read, MAY aborts fail-closed.
        if (self.forwardPendingHashLoad(f.dst, rtab, rkey)) return;
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        // Seed the loop-invariant cell pointer for native (H1); `href.aux` carries
        // the synthetic slab slot, or `-1` to mark "not seeded → native declines".
        // The tier-1a oracle ignores `aux`, so a `null` seed leaves H0 untouched.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count);
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
        // Fused native producer-exit (A-i.3): native `href` side-exits at the address
        // node on cell-resolution failure (`nativegen.zig`), no `guard_*` — same guest
        // hash access as `guard_hash`, so it shares `(hash_struct, b)`.
        self.stampProv(ref, .hash_struct, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, f.tab_od, .neutral);
        const rload = try self.emit(.{ .op = .hload, .a = ref, .ty = obsTypeOf(fv) });
        // Fused native producer-exit (A-i.3): native `hload` side-exits at the load on
        // a field-type change, no `guard_*` node — same site as the consumer guardNum.
        self.stampProv(rload, .field_type, .loaded, .neutral);
        self.setReg(f.dst, rload);
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
    ///   * recorder allocation failure → `.alloc` (ordinary recording abort).
    fn recHashSet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        return self.hashSetShape(regs, .{ .tab = instr.a, .key = instr.b, .val = instr.c, .tab_od = .a, .key_od = .b, .val_od = .c });
    }

    fn hashSetShape(self: *TraceState, regs: RegWindow, f: SetFrame) !void {
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
        const vval = regs.get(f.val);
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
        const rkey = try self.refOf(f.key);
        if (self.rec.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

        // C1 / store-sinking, identical to `recArraySet`: a write following any heap
        // read is a read-modify-write that must be deferred below every guard so a
        // side-exit leaves it un-executed and deopt-replay applies it exactly once.
        const defer_store = self.traceHasHeapLoad();
        const rval = try self.refOf(f.val);
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
        try self.guardNum(rval, vval, .value_type, f.val_od);
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        // Seed the cell pointer for native (H1) — see `recHashGet`. An RMW's read and
        // write `href`s dedup onto the same slot via `seedHashCell`.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count);
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
        // Fused native producer-exit (A-i.3): native `href` cell-resolution failure.
        self.stampProv(ref, .hash_struct, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, f.tab_od, .neutral);
        // `hstore` is effectful (overwrites the present cell in place) and defines no
        // register. A present-key overwrite never grows the map, so `guard_hash`
        // (population) stays sufficient. The store value's type is pinned by the
        // `guardNum` above (native declines a heap value at H1).
        if (defer_store) {
            try self.rec.pending_stores.append(self.gpa, .{
                .aref = ref,
                .value = rval,
                .lane_ord = 0,
                .op = .hstore,
            });
        } else {
            _ = try self.emit(.{ .op = .hstore, .a = ref, .b = rval });
        }
    }

    /// `eq`/`ne`. First cut: numeric operands only (the common loop-condition
    /// case); other types abort.
    fn recEq(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        // Konst×konst folds to a bool konst with zero runtime work — `Value.eql`
        // at record time is exact for every type (interned strings compare by
        // identity). This is what makes the `type(x) == "number"` idiom (doc 23)
        // collapse entirely: both sides are konsts (the `type` fold and the proto
        // constant), so the comparison — and via the branch guard on a constant,
        // the whole test — vanishes from the trace body.
        if (self.konstValueOf(rb)) |kb| if (self.konstValueOf(rc)) |kc| {
            const equal = kb.eql(kc);
            self.setReg(instr.a, try self.konst(Value.boolean(if (op == .eq) equal else !equal)));
            return;
        };
        const vb = regs.get(instr.b);
        const vc = regs.get(instr.c);
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        try self.guardNum(rb, vb, .operand_type, .b);
        try self.guardNum(rc, vc, .operand_type, .c);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// `jmp_if_false`/`jmp_if_true`: pin the *observed* truthiness of the tested
    /// register. Which path the trace records is whatever tier-0 took; the guard
    /// is what keeps the straight-line trace valid.
    fn recBranch(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
        const truthy_early = regs.get(instr.a).isTruthy();
        // Doc 38 LLEAVE (LuaJIT `rec_loop_interp`): a ROOT trace anchored at a
        // loop header "must loop back to form a root trace". If this branch is
        // the anchor loop's OWN exit edge and tier-0 took the exit direction,
        // abort instead of recording the enclosing code — the retry (after the
        // record-gate cooldown) lands on a pass that stays in the loop and
        // records the loop-BODY root the continuation machinery links against.
        // Anchor-tied structurally, so exits of OTHER loops (sequential
        // whiles, an inlined callee's loops — excluded by depth 0) never
        // match; side/continuation recordings legitimately cross loop exits.
        if (self.rec.kind == .root and self.rec.inline_depth == 0 and
            self.rec.anchor.proto == proto)
        {
            const jumped = (instr.op == .jmp_if_true) == truthy_early;
            const target_i: i64 = @as(i64, pc) + instr.aux; // `pc` = post-increment cursor, as in applyJump
            if (target_i >= 0 and target_i < @as(i64, @intCast(proto.code.len))) {
                const target: u32 = @intCast(target_i);
                if (target > pc) {
                    // `while` shape: forward branch over the body whose last
                    // instruction is the backward `jmp` to our anchor (the
                    // condition start). Taking the branch leaves the loop.
                    //
                    // ROOT recordings abort unconditionally (LuaJIT LLEAVE):
                    // the retry lands on a cond-true pass and records the
                    // body root first. The cond-false GLUE sibling
                    // (`guard_false → outer body → loop`, the figure-eight —
                    // measured 78.5 cyc/it vs 137 for root+link on a
                    // bounded-variance nest) is deliberately reachable only
                    // through the SIDE-trace route: `.side` recordings skip
                    // this check by kind, and the side want at a while-done
                    // exit only accrues once the anchor's OBSERVED trips/entry
                    // prove low (`whileDoneHotnessEligible`) — evidence a root
                    // recording cannot have yet (no committed trace → no
                    // receipts). That ordering keeps high-trip whiles
                    // (nsieve-bit-fp) on the pure body-root + link family the
                    // glue formation measurably degrades.
                    if (jumped and target >= 1 and proto.code[target - 1].op == .jmp and
                        @as(i64, target) + proto.code[target - 1].aux == @as(i64, self.rec.anchor.pc))
                    {
                        return self.abort(.loop_leave);
                    }
                } else if (instr.op == .jmp_if_false and target == self.rec.anchor.pc and !jumped) {
                    // `repeat`/`until` shape: backward `jmp_if_false` to our
                    // anchor (the body start). Falling through leaves the loop.
                    return self.abort(.loop_leave);
                }
            }
        }
        const ra = try self.refOf(instr.a);
        const truthy = truthy_early;
        // Fold statically-decided branches (doc 30 c5): a konst's truthiness is
        // fixed forever, and a proven-string producer result (`scap_str`,
        // `tostr_*`, the snew class) is ALWAYS truthy — only nil/false are
        // falsy in Lua, and a reachable string ref is never either. The guard
        // would be a tautology on the recorded direction, so emit nothing:
        // every tier wins (tier-1a skips a per-iteration re-check; native's
        // proveKinds rightly refuses to model heap truthiness, so an emitted
        // guard would bail the whole trace — the `if match(s, "^key")`
        // anchored-test shape). No region/polarity identity is lost either: a
        // branch that cannot diverge has no other CFG edge for a side trace.
        if (self.konstValueOf(ra)) |kv| {
            if (kv.isTruthy() == truthy) return;
            // A konst contradicting the observation is impossible (the konst IS
            // the observed value); fall through and emit the guard fail-closed.
        } else if (truthy and self.isProvenStringRef(ra)) {
            return;
        }
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
    /// Generic-for back-edge (doc 30 c4): `tfor_loop base, target` — tier-0
    /// continues iff the first loop variable (`base+3`) is non-nil, publishing
    /// it as the next control (`base+2`). The recorder mirrors the CONTINUE
    /// direction only: the observed v1 is pinned non-nil by its type guard
    /// (number → `guardNum`, string → `guard_string`, table → `guard_table`;
    /// a konst or proven string producer — e.g. the composite gmatch step's
    /// `scap_str` — is nil-free statically and needs no pin), and the ctrl
    /// slot inherits v1's ref (a pure ref move, like `.move`). An observed
    /// nil (the loop's end) aborts: leaving the loop is not loop-body code —
    /// the numeric `for_loop`'s exit-direction rule. At run time a
    /// nil-producing iteration side-exits at the pin (or earlier, at the
    /// composite step's negative status) and tier-0 replays the call,
    /// produces the nil, and ends the loop itself. A BOOLEAN v1 aborts
    /// fail-closed: `false` is non-nil (the loop continues) but no guard op
    /// expresses "non-nil" without also pinning truthiness. No
    /// `locals_watermark` here: generic-for keeps the maxInt sentinel (the
    /// loop variables live below the call window and stay in the snapshot).
    fn recTForLoop(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        // Same cross-proto pc hazard as `recForLoop`: never process a
        // back-edge inside an inlined callee.
        if (self.rec.inline_depth > 0) return self.abort(.cross_frame);
        const a = instr.a;
        const v1 = regs.get(a + 3);
        if (v1.isNil()) return self.abort(.bad_type); // end direction
        // Pin the OLD ctrl (`a+2`) by observed type. The test block's
        // `move base+5 ← base+2` already materialized an UNGUARDED slot_load
        // of it (the arg-window copy the iterator may ignore), and an
        // unguarded slot_load has no provable kind — proveKinds would refuse
        // the whole trace for native. Unlike the v1 pin below this guard has
        // no loop semantics (any ctrl continues the loop); it exists purely so
        // the shuttle has a kind, so the policy differs at the edges:
        //   * nil → abort. Only reachable when recording starts at a loop
        //     instance's FIRST iteration (ctrl still the initial nil); the
        //     back-edge hotcount discipline starts recordings via the back
        //     edge (iteration ≥ 2), so this is a rare race, and a retry lands
        //     on a pinnable iteration — better than committing a trace that
        //     can never leave tier-1a.
        //   * bool / exotic heap → record UNPINNED. No guard op can pin them
        //     (no non-nil guard exists), the trace stays sound (native
        //     declines it; tier-1a executes it), and aborting forever would
        //     be strictly worse than tier-1a.
        const vc = regs.get(a + 2);
        if (vc.isNil()) return self.abort(.bad_type);
        const rc = try self.refOf(a + 2);
        if (self.konstValueOf(rc) == null and !self.isProvenStringRef(rc)) {
            if (vc.isNumber()) {
                try self.guardNum(rc, vc, .operand_type, .a);
            } else if (vc.isHeap()) {
                switch (vc.heapType()) {
                    .string => self.stampProv(try self.emit(.{ .op = .guard_string, .a = rc }), .operand_type, .a, .neutral),
                    .table => {
                        const ctbl = table_mod.Table.fromHeader(vc.asHeap());
                        if (ctbl.metatable == null)
                            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rc }), .operand_type, .a, .neutral);
                        // metatable-bearing ctrl: leave unpinned (tier-1a).
                    },
                    else => {}, // exotic heap ctrl: leave unpinned (tier-1a).
                }
            }
            // bool ctrl: leave unpinned (tier-1a).
        }
        const r1 = try self.refOf(a + 3);
        if (self.konstValueOf(r1) == null and !self.isProvenStringRef(r1)) {
            if (v1.isNumber()) {
                try self.guardNum(r1, v1, .operand_type, .a);
            } else if (v1.isHeap()) switch (v1.heapType()) {
                .string => self.stampProv(try self.emit(.{ .op = .guard_string, .a = r1 }), .operand_type, .a, .neutral),
                .table => {
                    const tbl = table_mod.Table.fromHeader(v1.asHeap());
                    if (tbl.metatable != null) return self.abort(.has_metatable);
                    self.stampProv(try self.emit(.{ .op = .guard_table, .a = r1 }), .operand_type, .a, .neutral);
                },
                else => return self.abort(.bad_type),
            } else return self.abort(.bad_type);
        }
        self.setReg(a + 2, r1); // publish ctrl = v1
    }

    fn recForLoop(self: *TraceState, instr: Instr, regs: RegWindow, pc: u32) !void {
        const a = instr.a;

        // If *this* `for_loop` is the one whose back-edge defines the trace
        // anchor (its target == anchor.pc, computed exactly as the interpreter's
        // `applyJump`), then the trace re-enters / resumes at this numeric-`for`'s
        // body start. Its four control regs occupy `a..a+3` (idx, limit, step,
        // var), so every slot `>= a+4` is a compiler temporary — dead at the body
        // start on every resume path and after the loop. Record the watermark so
        // `commit()` can drop those slots from the exit snapshot. A `for_loop` the
        // trace merely passes through (different target) is ignored.
        //
        // Guard with `inline_depth == 0`: at depth > 0 the `target` pc is in the
        // callee's proto, so `target == anchor.pc` is a cross-proto coincidence —
        // the watermark would corrupt the anchor frame's phi writeback. The callee's
        // locals are already excluded by `slot >= anchor_num_registers` in commit.
        const target: u32 = @intCast(@as(i64, pc) + instr.aux);
        if (self.rec.inline_depth == 0 and target == self.rec.anchor.pc)
            self.rec.locals_watermark = @as(u32, a) + 4;
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

        // Polarity-aware continuation test (the zero-trip / loop-exit direction was
        // previously unrecordable — the recorder unconditionally asserted `guard_true`,
        // which contradicts the observed execution whenever tier-0 falls OUT of the
        // loop here, e.g. a `.side` recording of a skip-shaped iteration whose inner
        // loop zero-trips). Compute the observed decision with the SAME value-level
        // ops tier-0 uses (`arith.add`/`lt`/`le` on the runtime values), so the
        // recorded direction is byte-identical to the path tier-0 actually took —
        // a pure function of deterministic register values, identical in every
        // record/exec mode.
        const vnext = arith.add(vidx, vstep) catch return self.abort(.bad_type);
        const o_ascending = !(arith.lt(vstep, Value.int(0)) catch return self.abort(.bad_type));
        const within = if (o_ascending)
            arith.le(vnext, vlimit) catch return self.abort(.bad_type)
        else
            arith.le(vlimit, vnext) catch return self.abort(.bad_type);

        if (within) {
            // Loop-taken direction (the historical shape): assert the continue test,
            // publish the stepped index and the loop variable (R[a+3]). The
            // `guard_true` sourced at a `for_loop` is the loop-done guard — its
            // failure is the committed post-loop exit (isNumericForLoopDoneGuard).
            const done_g = try self.emit(.{ .op = .guard_true, .a = cmp });
            self.stampProv(done_g, .loop_done, .none, .neutral); // loop-continuation test
            self.setReg(a, rnext);
            self.setReg(a + 3, rnext);
        } else {
            // Loop-exit direction (zero-trip skip / final fall-out): assert the
            // continue test FAILED and keep recording straight-line past the loop.
            // tier-0 writes the stepped index back to R[a] but does NOT publish the
            // visible var R[a+3] on this path — mirror that exactly. A `guard_false`
            // here is an ORDINARY guard everywhere (loop-done machinery keys on
            // `guard_true`: isLoopDoneGuardIndex / isNumericForLoopDoneGuard /
            // irinterp all short-circuit on the op), so its failure deopts under the
            // H-1b re-execute convention — resume at the anchor with entry values,
            // tier-0 re-runs the iteration and takes the loop normally.
            const skip_g = try self.emit(.{ .op = .guard_false, .a = cmp });
            self.stampProv(skip_g, .loop_done, .none, .neutral); // loop-exit test
            self.setReg(a, rnext);
        }
    }

    /// `for_prep` (numeric-for entry): the nested-loop **trace-link** site (doc 15,
    /// Phase 2 — the mahina analogue of LuaJIT's `rec_loop_jit` / `LJ_TRLINK_ROOT`).
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
        const a = instr.a;

        // Read + type-check the numeric-for control values up front (both directions
        // need them; tier-0 `for_prep` type-checks all three and raises TypeError on
        // a non-number, so a non-number is not a numeric `for` we model — abort).
        const vinit = regs.get(a);
        const vlimit = regs.get(a + 1);
        const vstep = regs.get(a + 2);
        if (!vinit.isNumber() or !vlimit.isNumber() or !vstep.isNumber()) return self.abort(.bad_type);

        // ZERO-TRIP RECORD-THROUGH. Decide which direction tier-0 is about to take,
        // with the SAME value-level ops it uses: `for_prep` computes `R[a] = init −
        // step`, jumps to the `for_loop`, which computes `(init − step) + step` and
        // compares against the limit (direction by step sign). Note `(init−step)+step`
        // is NOT always `init` for floats — compute it exactly, never shortcut.
        // The decision is a pure function of deterministic register values, so it is
        // identical in every record/exec mode.
        //
        // If the loop runs AND we are at depth 0, fall through to the `.link`
        // hand-off below. If it ZERO-TRIPS, the link is meaningless (the inner root
        // assumes ≥1 iteration) and force-closing with `.link` recorded the WRONG
        // shape — the duplicate-continuation bug that made the skip direction
        // unrecordable. Instead, record the `for_prep` as the plain arithmetic it is
        // (`R[a] = init − step`, operands type-guarded) and keep recording: tier-0
        // jumps to the `for_loop`, whose recorder mirror (`recForLoop`) now records
        // the observed loop-EXIT direction (`guard_false` on the continue test) and
        // continues straight-line past the loop. This is sound for every recording
        // kind — no link is taken, it is just straight-line code — so a `.root` may
        // record through a zero-tripping inner `for_prep` too.
        //
        // At `inline_depth > 0` the same record-through path handles BOTH zero-trip
        // AND running loops: the link path cannot work at depth > 0 (`driveChain`
        // resolves `link_target` in the anchor proto, not the callee's), so we record
        // the `for_prep` arithmetic and let `recForLoop` unroll the inner loop. The
        // trace specializes to the iteration count observed during recording; a
        // mismatch on replay deopts via `guard_true`/`guard_false` failure.
        {
            const pre = arith.sub(vinit, vstep) catch return self.abort(.bad_type);
            const vnext = arith.add(pre, vstep) catch return self.abort(.bad_type);
            const o_ascending = !(arith.lt(vstep, Value.int(0)) catch return self.abort(.bad_type));
            const within = if (o_ascending)
                arith.le(vnext, vlimit) catch return self.abort(.bad_type)
            else
                arith.le(vlimit, vnext) catch return self.abort(.bad_type);
            if (!within or self.rec.inline_depth > 0) {
                const rinit0 = try self.refOf(a);
                const rlimit0 = try self.refOf(a + 1);
                const rstep0 = try self.refOf(a + 2);
                try self.guardNum(rinit0, vinit, .operand_type, .a);
                try self.guardNum(rlimit0, vlimit, .operand_type, .a1);
                try self.guardNum(rstep0, vstep, .operand_type, .a2);
                const rsub = try self.emit(.{ .op = .sub, .a = rinit0, .b = rstep0, .ty = arithResultType(.sub, vinit, vstep) });
                self.setReg(a, rsub);
                return;
            }
        }

        // Only a *side* or *continuation* links (LuaJIT's model). A `.root` recording
        // that reaches an inner `for_prep` aborts LINNER — byte-identical to the
        // pre-Phase-2 behaviour — so it never anchors a link trace at a real
        // back-edge target.
        if (self.rec.kind == .root) return self.abort(.nyi_opcode);

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
        // than commit a bogus link); already checked at the top of this fn.
        const rinit = try self.refOf(a);
        const rlimit = try self.refOf(a + 1);
        const rstep = try self.refOf(a + 2);
        try self.guardNum(rinit, vinit, .operand_type, .a);
        try self.guardNum(rlimit, vlimit, .operand_type, .a1);
        try self.guardNum(rstep, vstep, .operand_type, .a2);

        // First-iteration bounds test, mirroring `recForLoop`'s compare (incl. the
        // float-limit → int specialization so a mixed int/float compare stays lowerable
        // and byte-identical to tier-0's `idx <= limit`). tier-0 computes `(init−step)
        // +step` and compares THAT — which is NOT always `init` for floats (e.g.
        // `init=1.0, step=1e16` → tier-0's first index is `0.0`, not `1.0`), so the
        // recorded IR must do the same `sub` then `add` and both compare and publish
        // the result. (An earlier revision compared/published `init` directly on the
        // "(init−step)+step = init" shortcut — codex-flagged BLOCKER: a float link
        // handed the inner root a first index tier-0 never produced. Ints wrap back
        // exactly, so this only ever differed for floats.) On failure the inner loop
        // runs zero times → side-exit to tier-0 instead of entering the inner root.
        const all_int = vinit.isInt() and vstep.isInt();
        const vpre = arith.sub(vinit, vstep) catch return self.abort(.bad_type);
        const rpre = try self.emit(.{ .op = .sub, .a = rinit, .b = rstep, .ty = arithResultType(.sub, vinit, vstep) });
        const rfirst = try self.emit(.{ .op = .add, .a = rpre, .b = rstep, .ty = arithResultType(.add, vpre, vstep) });
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null) blk: {
            const iof = try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int });
            self.stampProv(iof, .limit_int, .a1, .neutral);
            break :blk iof;
        } else rlimit;
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            try self.emit(.{ .op = .le, .a = rfirst, .b = rlimit_cmp, .ty = .boolean })
        else
            try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rfirst, .ty = .boolean });
        self.stampProv(try self.emit(.{ .op = .guard_true, .a = cmp }), .loop_done, .none, .neutral);

        // Publish the inner root's entry state: the control index `R[a]` and the
        // visible loop var `R[a+3]` both hold tier-0's first index `(init−step)+step`.
        // (limit `R[a+1]` / step `R[a+2]` are untouched by the loop and flow through
        // the exit snapshot.)
        self.setReg(a, rfirst);
        self.setReg(a + 3, rfirst);

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

    /// Doc 38 — while-inner nested-loop linking. Extends the doc 15 linking
    /// machinery to `while` loops, whose bytecode structure is
    /// `<cmp>; jmp_if_false <past_end>; <body>; jmp <back_to_cmp>`.
    ///
    /// When a continuation/side recording encounters a backward `jmp` whose
    /// target already has a `.loop` root trace (the inner while-loop root),
    /// this function closes the recording with a `.link` terminal to that root
    /// — exactly the numeric-for pattern from `recForPrepLink`, but simpler:
    /// no pre-decrement arithmetic and no explicit bounds guard (the inner
    /// root's own condition-prefix guard handles zero-trip).
    ///
    /// Root recordings abort LINNER (matching `recForPrepLink` and LuaJIT's
    /// `rec_loop_jit` root gate): the inner loop must spawn its own root
    /// first.
    ///
    /// Forward jumps, self-anchor jumps, OOB jumps, and jumps at inline
    /// depth > 0 are silently ignored (the `.jmp` stays a no-op and the
    /// recording unrolls the while body as before).
    fn recWhileLink(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
        // Compute the jump target in signed arithmetic, matching `applyJump`.
        // `pc` is the post-increment cursor (the instruction AFTER this `jmp`),
        // so `pc + aux` gives the jump destination.
        const target_i: i64 = @as(i64, pc) + instr.aux;
        if (target_i < 0 or target_i >= @as(i64, @intCast(proto.code.len))) return; // OOB → no-op
        const target: u32 = @intCast(target_i);

        // Only backward jumps are while-loop re-entries. Forward jumps (break,
        // goto, if-skip) are straight-line in the trace.
        if (target >= pc) return;

        // If this jump targets our own anchor, `maybeCloseAtAnchor` (called
        // before the mirror) or `onBackEdge` already closed the trace. This is
        // a safety net — in practice we shouldn't reach here for our own anchor.
        // Compare the full (proto, pc) pair, not just pc, to be future-proof.
        if (self.rec.anchor.proto == proto and target == self.rec.anchor.pc) return;

        // Links at inline depth > 0 can't work: `driveChain` resolves
        // `link_target` in the anchor proto, not the callee's. Same constraint
        // as `recForPrepLink`.
        if (self.rec.inline_depth > 0) return;

        // Root recordings abort LINNER — REGARDLESS of whether the inner while
        // has a root yet (LuaJIT `rec_loop_interp`: entering an inner loop in a
        // root aborts so the inner loop traces FIRST; making it conditional on
        // an existing inner root made the outcome a recording race). The
        // continuation machinery then owns the nest: the inner root's loop-done
        // exits arm a continuation at the post-loop pc (`maybeArmContinuation`,
        // doc 38), which records the outer body and links back here. Unrolling
        // instead would commit a trip-count-pinned trace that thrashes on trip
        // variance AND clogs the anchor's trace population.
        //
        // Escape hatch (LuaJIT `innerloopleft`): an inner anchor that
        // repeatedly failed to loop back (`loop_leave` aborts exhausting the
        // fast-retry budget — reason-specific, exactly like LuaJIT keys its
        // check on LLEAVE/LINNER penalties) has a low/zero remaining-trip
        // pattern; a root may then unroll it, which is strictly better than
        // both sides backing off forever. Deterministic — a pure abort count.
        if (self.rec.kind == .root) {
            // innerloopleft: an inner that PROVED it cannot root (LLEAVE budget
            // exhausted) can only ever be unrolled — no evidence overrides this.
            if (self.lleave_count.get(.{ .proto = proto, .pc = target })) |n| {
                if (n >= self.config.lleave_fast_retries) {
                    self.rec.unrolled_while = true;
                    return; // unroll
                }
            }
            // Unroll-first (doc 38 revision — LuaJIT's innerloopleft mirrored):
            // mahina's decomposed inner-root+link pays a runtime re-entry per
            // inner completion (exits are not patched branches), so unrolling
            // into the outer root wins whenever sibling coverage can absorb the
            // trip variance (measured: ~17 vs ~95 native cyc/it on a bounded-
            // variance nest). Only an outer anchor with PROVEN unroll failure
            // (`unroll_fail` >= flip: unrolling recordings aborted, or
            // committed unrolled roots thrash-gated) decomposes via LINNER.
            const fails = self.unroll_fail.get(self.rec.anchor) orelse 0;
            if (fails < self.config.unroll_fail_flip) {
                self.rec.unrolled_while = true;
                return; // unroll
            }
            return self.abort(.nyi_opcode); // LINNER → inner root + link
        }

        // Side/continuation recordings: no inner root yet → no-op (the historical
        // straight-line unroll). The inner while warms up via `onBackEdge` and
        // spawns its own root; a later continuation then links here.
        if (self.findLoopTrace(proto, target) == null) return;

        // Close with a `.link` terminal to the inner while root. The φ writeback
        // in `commit()` ensures all modified slots are flushed; unmodified slots
        // remain coherent in the physical register file.
        self.rec.link_target = target;
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
    /// metamethod, a vararg callee, and exceeding `MAX_INLINE_DEPTH` or the
    /// `reg_map` reservation all abort. Dynamic multret windows (doc 27) no
    /// longer abort per se: an `all_results` ARGUMENT window resolves its fixed
    /// count against the recorder's multret shadow (`multret`, set by the
    /// immediately-preceding recorded producer — fails closed on `null`), and an
    /// `all_results` RESULT window stores the sentinel in `ret_count` verbatim,
    /// resolved by `recReturn` once the callee's `ret` fixes `produced`.
    fn recCall(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, multret: ?u32) !void {
        const callee = regs.get(instr.a);
        if (!callee.isHeap()) return self.abort(.cross_frame);
        switch (callee.heapType()) {
            // A host call crosses the embedding boundary — heap effects we can't
            // model on the trace — UNLESS the native carries a `RecordedBuiltin`
            // tag, i.e. the recorder knows how to record its calls (doc 23:
            // fold-to-konst, reuse of the index shapes, or a leaf op/callout).
            // Anything untagged stays the host barrier.
            .native => {
                const nat = function.Native.fromHeader(callee.asHeap());
                if (nat.recorded) |rb| return self.recBuiltin(rb, instr, regs, multret);
                return self.abort(.host_barrier);
            },
            .function => {},
            // `__call` on a table/userdata, or anything else callable only via a
            // metamethod, is not a plain Lua-closure call. Not inlined.
            else => return self.abort(.cross_frame),
        }
        // Doc 27 D3: a dynamic argument window resolves against the multret
        // shadow — `top - (a + 1)`, the same arithmetic tier-0 runs against
        // `reg_top` (`interp.zig` `.call`), in recorder frame-space (producer and
        // consumer always share a frame, so `base` never enters). All arithmetic
        // in u32 and fail-closed below the `all_results` sentinel (§3a). A
        // dynamic RESULT window needs nothing here: `ret_count = instr.c` stores
        // the sentinel verbatim and `recReturn` resolves it (D4).
        const nargs: u32 = if (instr.b == bytecode.all_results) blk: {
            const top = multret orelse return self.abort(.cross_frame);
            const first_arg = @as(u32, instr.a) + 1;
            if (top < first_arg) return self.abort(.cross_frame);
            const n = top - first_arg;
            if (n >= bytecode.all_results) return self.abort(.cross_frame);
            break :blk n;
        } else instr.b;

        const cl = function.Closure.fromHeader(callee.asHeap());
        const cp = cl.proto;
        // Loaded (`load`/`require`) callees inline like static ones (doc 19): their
        // proto constants are rooted VM-lifetime via `loaded_chunks` in both root
        // walks, so a trace konst over them is always redundant — the H-2
        // sole-root hazard that used to force an abort here is unreachable.
        // A vararg callee's extra-args frame cursor isn't modelled on the trace.
        if (cp.is_vararg) return self.abort(.cross_frame);
        if (self.rec.inline_depth >= MAX_INLINE_DEPTH) return self.abort(.too_deep);

        // Callee window starts `caller_proto.num_registers` above the current
        // frame's base — exactly tier-0's `callee_base = base + caller.num_registers`,
        // in the recorder's anchor-relative `base_off` space. `proto` here is the
        // *caller* proto (the frame the `.call` executes in).
        const callee_base_off: u32 = self.rec.base_off + proto.num_registers;
        if (@as(usize, callee_base_off) + cp.num_registers > self.rec.reg_map.len)
            return self.abort(.frame_bounds);

        // (1) guard_func: pin the runtime callee to this proto's stable id. `aux`
        // carries `Proto.id` (a `u32`, NOT a pointer — pointers change across a
        // keyframe restore and would break replay). Fails closed in the executor.
        const callee_ref = try self.refOf(instr.a);
        self.stampProv(try self.emit(.{ .op = .guard_func, .a = callee_ref, .aux = @bitCast(cp.id) }), .callee_identity, .a, .neutral);

        // (2) S1: seed every callee slot `.def`. Param slots (`i < num_params` and
        // an arg was actually passed) take the caller arg's SSA ref; everything else
        // is `nil`, matching tier-0's nil-fill of an unset register. After this no
        // callee slot is `.undef`, so `refOf` never emits a `slot_load` on a callee
        // index (which would be an out-of-window trace input). `nargs` was resolved
        // above (fixed, or doc 27's shadow resolution of `all_results`).
        var i: u16 = 0;
        while (i < cp.num_registers) : (i += 1) {
            const seed: Ref = if (i < cp.num_params and i < nargs)
                try self.refOf(@intCast(@as(usize, instr.a) + 1 + i))
            else
                try self.konst(Value.nil());
            // Whole-RegSlot write → `defineSlotAbs` (doc 39: preserves
            // `entry_kind`; a callee index is >= anchor_num_registers so the
            // peel-rebound branch never fires here, but the funnel keeps every
            // define on one audited path).
            self.defineSlotAbs(callee_base_off + i, seed);
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

    /// Dispatch a `.call` whose callee is a `RecordedBuiltin`-tagged native to
    /// its per-builtin recorder arm (doc 23 D1 — mahina's `recff_idmap`). The
    /// common preamble here rejects dynamic windows once; each arm owns its own
    /// arity (`instr.b`), result-count (`instr.c`), and observed-shape abort
    /// matrix. Arms whose recorder has not landed yet abort `.host_barrier`,
    /// byte-identical to the untagged path — a registry row only gains its
    /// `.recorded` tag together with its arm, so those prongs are unreachable
    /// until then and exist to keep the switch exhaustive as the enum grows.
    fn recBuiltin(self: *TraceState, rb: function.RecordedBuiltin, instr: Instr, regs: RegWindow, multret: ?u32) !void {
        // Doc 27: dynamic multret windows resolve here instead of aborting.
        //
        // Consumer half (D2, `b == all_results`): the actual argument count is
        // `top - (a + 1)` against the multret shadow — the identical arithmetic
        // tier-0 runs against `reg_top`, in recorder frame-space. Fails closed on
        // a `null` shadow (vararg spreads, recordings starting at a consumer) and
        // on any count not representable below the sentinel (§3a, u32 math).
        //
        // Producer half (D1, `c == all_results`): only structurally single-result
        // builtins qualify — tier-0's `all` path calls `nat.func` and
        // `stampSingleResult` (exactly one value) for every recorded builtin
        // WITHOUT a `.multi` projection. `codepoint`/`select` have one (can
        // produce ≠1 values) and stay barriers. The arm itself records under an
        // effective `c = 1` (the exact mirror of `stampSingleResult`'s one-value
        // write); the shadow publishes after the arm succeeds.
        //
        // Both flags are captured BEFORE the effective-instr rewrite (§3b): the
        // middle call of `f(g(h()))` is consumer AND producer at once, and the
        // rewrite destroys both sentinels.
        const was_dynamic_c = instr.c == bytecode.all_results;
        var eff = instr;
        if (instr.b == bytecode.all_results) {
            const top = multret orelse return self.abort(.cross_frame);
            const first_arg = @as(u32, instr.a) + 1;
            if (top < first_arg) return self.abort(.cross_frame);
            const nargs = top - first_arg;
            if (nargs >= bytecode.all_results) return self.abort(.cross_frame);
            eff.b = @intCast(nargs);
        }
        if (was_dynamic_c) {
            switch (rb) {
                // Doc 30 §5: find/match/gmatch_iter join the D1 EXCLUDED list
                // in v1 — the producer shadow would need the census count.
                .codepoint, .select, .find, .match, .gmatch_iter => return self.abort(.cross_frame),
                else => {},
            }
            eff.c = 1;
        }
        switch (rb) {
            .sqrt => try self.recPureSqrt(eff, regs),
            .type => try self.recBType(eff, regs),
            .tostring => try self.recBTostring(eff, regs),
            .tonumber => try self.recBTonumber(eff, regs),
            .select => try self.recBSelect(eff),
            .rawequal => try self.recBRawequal(eff, regs),
            .rawlen => try self.recBRawlen(eff, regs),
            .rawget => try self.recBRawget(eff, regs),
            .rawset => try self.recBRawset(eff, regs),
            .sin => try self.recFloatUnary(eff, regs, .sin, .fsin),
            .cos => try self.recFloatUnary(eff, regs, .cos, .fcos),
            .mtype => try self.recBMType(eff, regs),
            .len => try self.recBSLen(eff, regs),
            .sub => try self.recBSSub(eff, regs),
            .reverse => try self.recBSRev(eff, regs),
            .char => try self.recBSChar1(eff, regs),
            .rep => try self.recBSRep2(eff, regs),
            .upper => try self.recBSCase(eff, regs, .upper, .supper),
            .lower => try self.recBSCase(eff, regs, .lower, .slower),
            .codepoint => try self.recBSCodepoint(eff, regs),
            .find => try self.recBSFind(eff, regs),
            .match => try self.recBSMatch(eff, regs),
            .gmatch_iter => try self.recBSGmatchIter(eff, regs),
            .floor => try self.recFloorCeil(eff, regs, .floor, .ffloor),
            .ceil => try self.recFloorCeil(eff, regs, .ceil, .fceil),
        }
        // D1 publish — only a LIVE recording may leave a shadow (an aborting arm
        // set `rec.active = false`; §3a truthfulness: set only by a successfully
        // recorded producer).
        if (was_dynamic_c and self.rec.active)
            self.rec.multret_top = @as(u32, eff.a) + 1;
    }

    /// `math.type(v)` — konst fold under the same pins as `type()` (doc 24
    /// ride-along): a numeric argument's `guardNum` pin decides
    /// "integer"/"float" (the pin is exactly the query!), a pinned
    /// table/native/closure folds `nil` (Value.nil needs no interning), and
    /// the pin-less observations (string/nil/bool non-konst) abort as in
    /// `recBType`. Never allocates: string results via `foldInternedStr`.
    fn recBMType(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .mtype);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const argv = regs.get(arg_slot);
        const arg_ref = try self.refOf(arg_slot);
        if (self.konstValueOf(arg_ref) == null) {
            if (argv.isNumber()) {
                try self.guardNum(arg_ref, argv, .operand_type, .a1);
            } else if (argv.isHeap()) switch (argv.heapType()) {
                .table => {
                    const tbl = table_mod.Table.fromHeader(argv.asHeap());
                    if (tbl.metatable != null) return self.abort(.has_metatable);
                    self.stampProv(try self.emit(.{ .op = .guard_table, .a = arg_ref }), .operand_type, .a1, .neutral);
                },
                .native => {
                    const nat = function.Native.fromHeader(argv.asHeap());
                    const tag = nat.recorded orelse return self.abort(.bad_type);
                    try self.guardBuiltinCallee(arg_slot, tag);
                },
                .function => {
                    const cl = function.Closure.fromHeader(argv.asHeap());
                    if (!self.rec.guarded_refs.contains(arg_ref)) {
                        try self.rec.guarded_refs.put(self.gpa, arg_ref, {});
                        self.stampProv(try self.emit(.{ .op = .guard_func, .a = arg_ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a1, .neutral);
                    }
                },
                else => return self.abort(.bad_type),
            } else return self.abort(.bad_type);
        }
        if (!self.isRecording()) return;
        if (argv.isInt()) {
            const r = (try self.foldInternedStr("integer")) orelse return self.abort(.bad_type);
            self.setReg(instr.a, r);
        } else if (argv.isFloat()) {
            const r = (try self.foldInternedStr("float")) orelse return self.abort(.bad_type);
            self.setReg(instr.a, r);
        } else {
            self.setReg(instr.a, try self.konst(Value.nil()));
        }
    }

    // --- doc 23 D2: fold-to-konst builtin arms -----------------------------
    //
    // Shared discipline: the recorder runs BEFORE tier-0 executes the call, so a
    // fold may never allocate a guest heap object — interned-string results go
    // through `foldInternedStr` (read-only lookup, abort on miss; in steady state
    // the hot-count threshold guarantees prior tier-0 iterations interned them).
    // Guards follow the house rules: numeric pins via the *registered* `guardNum`
    // (`guarded_refs` holds only numeric guards), heap-shape pins (`guard_table`,
    // `guard_func`) emitted raw and deduped by CSE, builtin identity via
    // `guardBuiltinCallee` (disjoint use of the registered set — a native-valued
    // ref never carries a numeric guard).

    /// The `Value` behind `ref` iff `ref` is a trace konst (else null). The
    /// fold arms use this to recognize compile-time-constant arguments, whose
    /// identity needs no runtime guard (konst refs are literals by construction).
    pub fn konstValueOf(self: *const TraceState, ref: Ref) ?Value {
        const ins = self.rec.instrs.items[@intCast(ref)];
        if (ins.op != .konst) return null;
        return self.rec.consts.items[@intCast(ins.aux)];
    }

    /// Fold an interned-string result: konst ref for `bytes`'s already-interned
    /// string, or null when it is not interned yet or no heap channel exists
    /// (bare test harness) — callers abort `.bad_type` and recording retries
    /// later, by which time tier-0 has interned the value. NEVER interns.
    fn foldInternedStr(self: *TraceState, bytes: []const u8) !?Ref {
        const heap = self.rec_heap orelse return null;
        const s = heap.internedLookup(bytes) orelse return null;
        return try self.konst(Value.heap(&s.header));
    }

    /// `type(v)` — the result is a constant type-name string once the argument's
    /// runtime type is pinned (doc 23 D2 table). Number/table/recorded-native/
    /// closure observations pin with existing guards; string/nil/bool have no
    /// guard vocabulary and abort (tier-0 owns them until a consumer justifies
    /// new guards). The pins are deliberately *stronger* than `type()` needs
    /// (`guardNum` pins int-vs-float; `guard_table` also demands no metatable;
    /// `guard_func` pins the exact proto) — a drifting argument deopts and
    /// re-records, which is conservative, never wrong.
    fn recBType(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .type);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const argv = regs.get(arg_slot);
        const arg_ref = try self.refOf(arg_slot);
        if (self.konstValueOf(arg_ref) == null) {
            if (argv.isNumber()) {
                try self.guardNum(arg_ref, argv, .operand_type, .a1);
            } else if (argv.isHeap()) switch (argv.heapType()) {
                .table => {
                    const tbl = table_mod.Table.fromHeader(argv.asHeap());
                    if (tbl.metatable != null) return self.abort(.has_metatable);
                    self.stampProv(try self.emit(.{ .op = .guard_table, .a = arg_ref }), .operand_type, .a1, .neutral);
                },
                .native => {
                    const nat = function.Native.fromHeader(argv.asHeap());
                    const tag = nat.recorded orelse return self.abort(.bad_type);
                    try self.guardBuiltinCallee(arg_slot, tag);
                },
                .function => {
                    const cl = function.Closure.fromHeader(argv.asHeap());
                    if (!self.rec.guarded_refs.contains(arg_ref)) {
                        try self.rec.guarded_refs.put(self.gpa, arg_ref, {});
                        self.stampProv(try self.emit(.{ .op = .guard_func, .a = arg_ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a1, .neutral);
                    }
                },
                else => return self.abort(.bad_type),
            } else return self.abort(.bad_type);
        }
        const kref = (try self.foldInternedStr(argv.typeName())) orelse return self.abort(.bad_type);
        self.setReg(instr.a, kref);
    }

    /// `tostring(v)` — two recorded shapes:
    ///
    /// **Konst fold (arc A / doc 23).** Only non-heap konsts fold:
    /// numbers/bools/nil can never carry a metatable (`Vm.metatableOf` returns
    /// null for every non-heap value), so the `__tostring` metacall tier-0's
    /// `bToString` probes first is statically impossible and the scalar
    /// rendering is the whole story. A konst *string* does NOT fold: strings
    /// share the mutable built-in string metatable, so a runtime `__tostring`
    /// could appear with no guard to catch it. The rendering goes through
    /// `io.writeValue` — the exact renderer `bToString` uses — into a bounded
    /// stack buffer, then a read-only lookup.
    ///
    /// **Allocating producer (arc B / doc 24).** A non-konst observed
    /// int/float pins with `guardNum` (int-vs-float — the pin selects the op)
    /// and records `tostr_int`/`tostr_num` through `emitAlloc` (which arms the
    /// body's `guard_gc` budget guard). The `__tostring` impossibility argument
    /// is the same (the guard proves non-heap). Everything else (observed
    /// strings/bools/nil/heap) stays a tier-0 barrier.
    fn recBTostring(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const arg_ref = try self.refOf(arg_slot);
        if (self.konstValueOf(arg_ref)) |kv| {
            if (kv.isHeap()) return self.abort(.bad_type);
            try self.guardBuiltinCallee(instr.a, .tostring);
            var buf: [128]u8 = undefined;
            var w = io.Writer.fixed(&buf);
            io.writeValue(&w, kv) catch unreachable; // scalars render in <32 bytes
            const kref = (try self.foldInternedStr(w.buffered())) orelse return self.abort(.bad_type);
            self.setReg(instr.a, kref);
            return;
        }
        const argv = regs.get(arg_slot);
        if (!argv.isNumber()) return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .tostring);
        try self.guardNum(arg_ref, argv, .operand_type, .a1);
        const op: IrOp = if (argv.isInt()) .tostr_int else .tostr_num;
        const r = try self.emitAlloc(.{ .op = op, .a = arg_ref, .ty = .heap });
        self.setReg(instr.a, r);
    }

    /// Is `r`'s producer an op whose result is a PROVEN string (needs no
    /// `guard_string`)? The tostr/snew producers stamp `ty = .heap` with
    /// string-typed results by construction.
    fn isProvenStringRef(self: *const TraceState, r: Ref) bool {
        return switch (self.rec.instrs.items[@intCast(r)].op) {
            .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower => true,
            // Doc 30: an interned capture span is a string by construction.
            .scap_str => true,
            else => false,
        };
    }

    /// Resolve a builtin STRING argument (doc 24 c3): a konst interned string
    /// or a proven producer passes ref-through; an observed string gets a
    /// `guard_string` pin; anything else aborts (tier-0 owns coercions and
    /// error raising). Returns the operand ref.
    /// Null = the recording was aborted (`abort` flags it; the caller must
    /// return without emitting) — the house `!?Ref` convention: `abort()`
    /// itself is not an error, allocator failures still propagate as errors.
    fn stringArgRef(self: *TraceState, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?Ref {
        const r = try self.refOf(arg_slot);
        if (self.konstValueOf(r)) |kv| {
            if (!kv.isHeap() or kv.heapType() != .string) {
                self.abort(.bad_type);
                return null;
            }
            return r;
        }
        if (self.isProvenStringRef(r)) return r;
        const v = regs.get(arg_slot);
        if (!v.isHeap() or v.heapType() != .string) {
            self.abort(.bad_type);
            return null;
        }
        // tropt's GuardKey dedup drops an exact duplicate pin.
        self.stampProv(try self.emit(.{ .op = .guard_string, .a = r }), .operand_type, operand, .neutral);
        return r;
    }

    /// Resolve a builtin INT argument: konst int passes through; an observed
    /// int gets a `guard_int` pin; float/other aborts (tier-0 owns the
    /// integral-float coercion these builtins perform — recording it would
    /// need an `int_of_float` shape no string bench exercises).
    /// Null = aborted (see `stringArgRef`).
    fn intArgRef(self: *TraceState, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?Ref {
        const r = try self.refOf(arg_slot);
        if (self.konstValueOf(r)) |kv| {
            if (!kv.isInt()) {
                self.abort(.bad_type);
                return null;
            }
            return r;
        }
        if (!regs.get(arg_slot).isInt()) {
            self.abort(.bad_type);
            return null;
        }
        try self.guard(r, .guard_int, .operand_type, operand);
        return r;
    }

    /// `string.len(s)` — non-allocating: the `#s` shape under `guard_builtin`.
    /// Konst string folds to a `cp_len` konst (code points — NOT `rawlen`'s
    /// byte length); otherwise `slen` on the proven/guarded ref.
    fn recBSLen(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .len);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const r = try self.refOf(arg_slot);
        if (self.konstValueOf(r)) |kv| {
            if (!kv.isHeap() or kv.heapType() != .string) return self.abort(.bad_type);
            const str = string_mod.String.fromHeader(kv.asHeap());
            self.setReg(instr.a, try self.konst(Value.int(@intCast(str.cp_len))));
            return;
        }
        const sref = (try self.stringArgRef(arg_slot, regs, .a1)) orelse return;
        self.setReg(instr.a, try self.emit(.{ .op = .slen, .a = sref, .ty = .int }));
    }

    /// `string.sub(s, i[, j])` → `ssub` (snew class). The 2-arg shape records
    /// its default `j = -1` as a konst — same value tier-0 defaults to — so
    /// both shapes share one op. The third operand rides `aux` as a ref
    /// (codex #4); clamping semantics mean the op itself never errors.
    fn recBSSub(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 2 and instr.b != 3) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .sub);
        const base: usize = instr.a;
        const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
        const iref = (try self.intArgRef(@intCast(base + 2), regs, .a2)) orelse return;
        const jref: Ref = if (instr.b == 3)
            (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
        else
            try self.konst(Value.int(-1));
        const r = try self.emitAlloc(.{ .op = .ssub, .a = sref, .b = iref, .aux = @intCast(jref), .ty = .heap });
        self.setReg(instr.a, r);
    }

    /// `string.reverse(s)` → `srev` (snew class).
    fn recBSRev(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .reverse);
        const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .srev, .a = sref, .ty = .heap }));
    }

    /// 1-argument `string.char(c)` → `schar1`. The variadic shape aborts
    /// (`IrInstr` carries no operand vector — codex #4). Range failure is a
    /// side-exit at run time, not a record-time concern.
    fn recBSChar1(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .char);
        const cref = (try self.intArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .schar1, .a = cref, .ty = .heap }));
    }

    /// 2-argument `string.rep(s, n)` → `srep2`. A separator argument aborts
    /// (pinned arity, codex #4) — tier-0 owns the 3-arg shape.
    fn recBSRep2(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 2) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .rep);
        const base: usize = instr.a;
        const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
        const nref = (try self.intArgRef(@intCast(base + 2), regs, .a2)) orelse return;
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .srep2, .a = sref, .b = nref, .ty = .heap }));
    }

    /// `string.upper(s)` / `string.lower(s)` → `supper`/`slower` (doc 26 D2,
    /// snew class — one arm, two ops). The recording is only reachable because
    /// tier-0 is executing the very call being mirrored, which commits the
    /// session's Unicode-version pin (or raises — D1a then kills this
    /// recording), so the on-trace op is heap-only. No konst fold: a fold
    /// would intern a derived string into the konst pool at record time; the
    /// konst ref passes through and the op's repeat is an intern hit.
    fn recBSCase(self: *TraceState, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, rb);
        const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
        self.setReg(instr.a, try self.emitAlloc(.{ .op = op, .a = sref, .ty = .heap }));
    }

    /// Single-result `string.codepoint(s [, i [, j]])` → `scp` (doc 26 D3).
    /// Pure, non-allocating (plain `emit`, NOT `emitAlloc` — bound A must not
    /// inflate). Arity pins: 1–3 arguments, exactly one wanted result (the
    /// `nwanted >= 2` multi path stays a barrier — `recBuiltin`'s preamble
    /// already rejected `all_results`, this rejects fixed multi shapes).
    /// Defaults record the SAME refs tier-0 derives: 1-arg → both konst 1;
    /// 2-arg → `aux` IS the i ref (j defaults to the runtime i). Indices are
    /// int-only (tier-0's integral-float coercion stays tier-0-owned — the
    /// ssub precedent). An empty range side-exits at run time.
    fn recBSCodepoint(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b < 1 or instr.b > 3) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .codepoint);
        const base: usize = instr.a;
        const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
        const iref: Ref = if (instr.b >= 2)
            (try self.intArgRef(@intCast(base + 2), regs, .a2)) orelse return
        else
            try self.konst(Value.int(1));
        const jref: Ref = if (instr.b == 3)
            (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
        else
            iref; // j defaults to the RUNTIME i — the same ref, not a konst
        self.setReg(instr.a, try self.emit(.{ .op = .scp, .a = sref, .b = iref, .aux = @intCast(jref), .ty = .int }));
    }

    // --- doc 30: the pattern-engine arms -----------------------------------

    const PatternPin = struct { ref: Ref, str: *const string_mod.String };

    /// P1: pin the pattern argument. A konst interned string passes ref-
    /// through (bytes from the pool value); an observed runtime string gets
    /// the interned-identity pin — `guard_string` for the dominating type
    /// proof (unless the producer already proves it) plus `guard_sid` against
    /// the pattern's konst-pool entry (§2a: equal bytes ⇔ same object within
    /// a heap, so identity pins content — a cached-in-a-local pattern records
    /// as well as a literal). Anything else aborts; tier-0 owns coercions.
    /// Null = aborted (the `stringArgRef` convention).
    fn patternArgPin(self: *TraceState, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?PatternPin {
        const r = try self.refOf(arg_slot);
        if (self.konstValueOf(r)) |kv| {
            if (!kv.isHeap() or kv.heapType() != .string) {
                self.abort(.bad_type);
                return null;
            }
            return .{ .ref = r, .str = string_mod.String.fromHeader(kv.asHeap()) };
        }
        const v = regs.get(arg_slot);
        if (!v.isHeap() or v.heapType() != .string) {
            self.abort(.bad_type);
            return null;
        }
        if (!self.isProvenStringRef(r))
            self.stampProv(try self.emit(.{ .op = .guard_string, .a = r }), .operand_type, operand, .neutral);
        // Rooting: `konst` interns the pattern Value into the trace pool
        // (an explicit GC root); the guard carries the POOL ID, never a
        // pointer — tier-1a resolves via `t.consts`, native bakes at compile
        // time (§2a).
        const pk = try self.konst(v);
        const pool_id = self.rec.instrs.items[@intCast(pk)].aux;
        self.stampProv(try self.emit(.{ .op = .guard_sid, .a = r, .aux = pool_id }), .operand_type, operand, .neutral);
        return .{ .ref = r, .str = string_mod.String.fromHeader(v.asHeap()) };
    }

    /// Project a completed match's result window out of the scratch (doc 30
    /// §3): `first_slot` is the caller's first result register offset within
    /// the window this helper owns (find offsets captures by 2). Emits one
    /// `scap_str` per STRING capture in capture order REGARDLESS of the
    /// wanted count (B02 — tier-0 materializes every capture before the
    /// result window truncates, so the id stream must too); position
    /// captures are non-allocating and emitted only when register-wanted.
    /// Nil-pads wanted results beyond the produced span (M04).
    fn projectCaptures(self: *TraceState, m: Ref, base: usize, first: usize, census: pattern_mod.Census, nwanted: usize) !void {
        var k: usize = 0;
        while (k < census.ncap) : (k += 1) {
            const slot = gc.MatchScratch.slot_cap0 + k;
            const wanted = (first + k) < nwanted;
            if (census.kinds[k] == .span) {
                const r = try self.emitAlloc(.{ .op = .scap_str, .a = m, .b = @intCast(slot), .ty = .heap });
                if (wanted) self.setReg(@intCast(base + first + k), r);
            } else if (wanted) {
                self.setReg(@intCast(base + first + k), try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(slot), .ty = .int }));
            }
        }
        var w: usize = first + census.ncap;
        while (w < nwanted) : (w += 1)
            self.setReg(@intCast(base + w), try self.konst(Value.nil()));
    }

    /// `string.find(s, pat [, init [, plain]])` (doc 30 §5). Plain flag must
    /// be konst (its truthiness picks the shape at record time). Plain or
    /// no-specials → `sfindp` with the end index as recorder arithmetic
    /// (`start + cpLen(pat) − 1`, konst-folded from the pinned pattern — the
    /// empty pattern's `(st, st−1)` falls out with `cpLen == 0`); else
    /// `smatch` + scratch projections. v1 records the MATCHED direction only
    /// (P2): the arm runs the same core tier-0 is about to and aborts on
    /// no-match/raise.
    fn recBSFind(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b < 2 or instr.b > 4) return self.abort(.cross_frame);
        if (instr.c < 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .find);
        const base: usize = instr.a;
        const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
        const sobj: *const string_mod.String = string_mod.String.fromHeader(regs.get(@intCast(base + 1)).asHeap());
        var plain = false;
        if (instr.b == 4) {
            const pref = try self.refOf(@intCast(base + 4));
            const pkv = self.konstValueOf(pref) orelse return self.abort(.bad_type);
            plain = pkv.isTruthy();
        }
        const init_ref: Ref = if (instr.b >= 3)
            (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
        else
            try self.konst(Value.int(1));
        const init_v: i64 = if (instr.b >= 3) regs.get(@intCast(base + 3)).asInt() else 1;
        const pat = (try self.patternArgPin(@intCast(base + 2), regs, .a2)) orelse return;
        const pat_bytes = pat.str.bytes();

        if (plain or !pattern_mod.hasSpecials(pat_bytes)) {
            // P2 via the same heap-free core the shim runs.
            if (string_stdlib.sfindPlainCore(sobj, init_v, pat_bytes) < 1) return self.abort(.bad_type);
            const r_start = try self.emit(.{ .op = .sfindp, .a = sref, .b = init_ref, .aux = @intCast(pat.ref), .ty = .int });
            self.setReg(instr.a, r_start);
            if (instr.c >= 2) {
                const cp_minus1: i64 = @as(i64, @intCast(pat.str.cpLen())) - 1;
                const kref = try self.konst(Value.int(cp_minus1));
                self.setReg(@intCast(base + 1), try self.emit(.{ .op = .add, .a = r_start, .b = kref, .ty = .int }));
            }
            var w: usize = 2;
            while (w < instr.c) : (w += 1) // M04: plain find has no captures
                self.setReg(@intCast(base + w), try self.konst(Value.nil()));
            return;
        }
        const census = pattern_mod.census(pat_bytes) orelse return self.abort(.bad_type);
        const st = string_stdlib.resolveInit(init_v, sobj) orelse return self.abort(.bad_type);
        var ms = pattern_mod.MatchState.init(sobj.bytes(), pat_bytes);
        _ = (pattern_mod.locateMatch(&ms, st, true) catch null) orelse return self.abort(.bad_type);
        const m = try self.emit(.{ .op = .smatch, .a = sref, .b = init_ref, .aux = @intCast(pat.ref), .ty = .int });
        self.setReg(instr.a, try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(gc.MatchScratch.slot_start), .ty = .int }));
        if (instr.c >= 2)
            self.setReg(@intCast(base + 1), try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(gc.MatchScratch.slot_end), .ty = .int }));
        try self.projectCaptures(m, base, 2, census, instr.c);
    }

    /// `string.match(s, pat [, init])` (doc 30 §5): always the `smatch` shape.
    /// `ncap == 0` → the whole match interned from `slot_whole`; else the
    /// capture window per B02/M04. Matched direction only (P2).
    fn recBSMatch(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b < 2 or instr.b > 3) return self.abort(.cross_frame);
        if (instr.c < 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .match);
        const base: usize = instr.a;
        const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
        const sobj: *const string_mod.String = string_mod.String.fromHeader(regs.get(@intCast(base + 1)).asHeap());
        const init_ref: Ref = if (instr.b >= 3)
            (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
        else
            try self.konst(Value.int(1));
        const init_v: i64 = if (instr.b >= 3) regs.get(@intCast(base + 3)).asInt() else 1;
        const pat = (try self.patternArgPin(@intCast(base + 2), regs, .a2)) orelse return;
        const pat_bytes = pat.str.bytes();
        const census = pattern_mod.census(pat_bytes) orelse return self.abort(.bad_type);
        const st = string_stdlib.resolveInit(init_v, sobj) orelse return self.abort(.bad_type);
        var ms = pattern_mod.MatchState.init(sobj.bytes(), pat_bytes);
        _ = (pattern_mod.locateMatch(&ms, st, true) catch null) orelse return self.abort(.bad_type);
        const m = try self.emit(.{ .op = .smatch, .a = sref, .b = init_ref, .aux = @intCast(pat.ref), .ty = .int });
        if (census.ncap == 0) {
            self.setReg(instr.a, try self.emitAlloc(.{ .op = .scap_str, .a = m, .b = @intCast(gc.MatchScratch.slot_whole), .ty = .heap }));
            var w: usize = 1;
            while (w < instr.c) : (w += 1)
                self.setReg(@intCast(base + w), try self.konst(Value.nil()));
        } else {
            try self.projectCaptures(m, base, 0, census, instr.c);
        }
    }

    /// `@gmatch_iter(state)` → the composite `sgmatch` step (doc 30 §6). The
    /// state is guarded a table; the pattern lives in `state[2]` where no SSA
    /// ref exists, so the pin is NOT `guard_sid` — the expected pattern's
    /// konst-pool id rides `sgmatch.aux` and the SHIM compares identity per
    /// execution. The census only fixes the projection list, a syntactic
    /// property of the pattern alone; subject/pos are read by the shim at run
    /// time (a non-string subject / broken B03 layout → negative status →
    /// side-exit). The cursor advance is a DEFERRED `sgm_setpos` through the
    /// docs-07/08 pending-store discipline: any exit in the iteration replays
    /// tier-0 against the UN-advanced pos and reproduces the same token.
    /// v1 records the matched direction only; exhaustion aborts (the for-in
    /// end is one side-exit per gmatch() call at run time).
    fn recBSGmatchIter(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b < 1 or instr.b > 2) return self.abort(.cross_frame);
        if (instr.c < 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .gmatch_iter);
        const base: usize = instr.a;
        const state_slot: u16 = @intCast(base + 1);
        const stv = regs.get(state_slot);
        if (!stv.isHeap() or stv.heapType() != .table) return self.abort(.bad_type);
        const st_tbl = table_mod.Table.fromHeader(stv.asHeap());
        if (st_tbl.metatable != null) return self.abort(.has_metatable);
        const state_ref = try self.refOf(state_slot);
        // Fail-closed corner (§6): a SECOND composite step against the same
        // state ref in one iteration would read a stale pos under the
        // deferred store. The for-in shape (one aux call per iteration) never
        // trips this.
        for (self.rec.pending_stores.items) |ps| {
            if (ps.op == .sgm_setpos and ps.aref == state_ref) return self.abort(.bad_type);
        }
        // Record-time state reads: census inputs only — every runtime
        // assumption is shim-verified per execution or guarded.
        const subj_v = st_tbl.getInt(1);
        if (!subj_v.isHeap() or subj_v.heapType() != .string) return self.abort(.bad_type);
        const sobj = string_mod.String.fromHeader(subj_v.asHeap());
        const pat_v = st_tbl.getInt(2);
        if (!pat_v.isHeap() or pat_v.heapType() != .string) return self.abort(.bad_type);
        const pat_bytes = string_mod.String.fromHeader(pat_v.asHeap()).bytes();
        const pos = st_tbl.inLaneValueIntCell(3) orelse return self.abort(.bad_type); // B03
        if (pos < 0) return self.abort(.bad_type);
        const census = pattern_mod.census(pat_bytes) orelse return self.abort(.bad_type);
        // P2, gmatch flavor: continue from the stored pos, no anchor
        // consumption — exactly `gmatchAuxCore`'s locate.
        var ms = pattern_mod.MatchState.init(sobj.bytes(), pat_bytes);
        _ = (pattern_mod.locateMatch(&ms, @intCast(pos), false) catch null) orelse return self.abort(.bad_type);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = state_ref }), .operand_type, .a1, .neutral);
        const pk = try self.konst(pat_v);
        const pool_id = self.rec.instrs.items[@intCast(pk)].aux;
        const m = try self.emit(.{ .op = .sgmatch, .a = state_ref, .aux = pool_id, .ty = .int });
        if (census.ncap == 0) {
            self.setReg(instr.a, try self.emitAlloc(.{ .op = .scap_str, .a = m, .b = @intCast(gc.MatchScratch.slot_whole), .ty = .heap }));
            var w: usize = 1;
            while (w < instr.c) : (w += 1)
                self.setReg(@intCast(base + w), try self.konst(Value.nil()));
        } else {
            try self.projectCaptures(m, base, 0, census, instr.c);
        }
        const np = try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(gc.MatchScratch.slot_next_pos), .ty = .int });
        try self.rec.pending_stores.append(self.gpa, .{ .op = .sgm_setpos, .aref = state_ref, .value = np, .lane_ord = 0 });
    }

    /// `tonumber(v[, base])` — konst arguments fold at record time through
    /// `arith.toNumber`, the ONE conversion core shared with tier-0's
    /// `bToNumber` (so the fold and the builtin can never disagree); the result
    /// is an int/float/nil konst, never an interned string. A non-konst
    /// observed-*number* 1-arg call is the identity: pin with `guardNum` and
    /// pass the ref through. Everything else (non-konst strings — a guarded
    /// runtime parse — and dynamic bases) aborts; tier-0 owns it.
    fn recBTonumber(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.c != 1) return self.abort(.cross_frame);
        if (instr.b < 1 or instr.b > 2) return self.abort(.cross_frame);
        const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
        const kv = self.konstValueOf(arg_ref);
        if (instr.b == 2) {
            const base_ref = try self.refOf(@intCast(@as(usize, instr.a) + 2));
            const kb = self.konstValueOf(base_ref) orelse return self.abort(.bad_type);
            const ka = kv orelse return self.abort(.bad_type);
            try self.guardBuiltinCallee(instr.a, .tonumber);
            self.setReg(instr.a, try self.konst(arith.toNumber(ka, kb)));
            return;
        }
        if (kv) |ka| {
            try self.guardBuiltinCallee(instr.a, .tonumber);
            self.setReg(instr.a, try self.konst(arith.toNumber(ka, null)));
            return;
        }
        const argv = regs.get(@intCast(@as(usize, instr.a) + 1));
        if (argv.isNumber()) {
            try self.guardBuiltinCallee(instr.a, .tonumber);
            try self.guardNum(arg_ref, argv, .operand_type, .a1);
            self.setReg(instr.a, arg_ref);
            return;
        }
        // Doc 30: the observed-STRING 1-arg call — a guarded runtime parse
        // through the ONE `arith.toNumber` core (`str2numRuntime` calls the
        // same function, so the recorder's observation, tier-0, and the
        // trace can never disagree). The observed outcome bakes the op's
        // kind (P2); a later kind flip or non-number side-exits at run time.
        // The nil direction stays tier-0 in v1.
        if (argv.isHeap() and argv.heapType() == .string) {
            try self.guardBuiltinCallee(instr.a, .tonumber);
            const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
            const outcome = arith.toNumber(argv, null);
            if (outcome.isInt()) {
                self.setReg(instr.a, try self.emit(.{ .op = .str2num_i, .a = sref, .ty = .int }));
            } else if (outcome.isFloat()) {
                self.setReg(instr.a, try self.emit(.{ .op = .str2num_f, .a = sref, .ty = .float }));
            } else {
                return self.abort(.bad_type);
            }
            return;
        }
        return self.abort(.bad_type);
    }

    /// `select('#', a…)` — only the konst-`'#'` selector records: the arg count
    /// is compile-time fixed (`instr.b − 1`; `instr.b` excludes the callee), so
    /// the result is a constant with no runtime guard beyond the callee
    /// identity — konst args need no re-proving. The numeric form (a slot
    /// shuffle, multi-result) is a non-goal; vararg callers can't trace anyway
    /// (`is_vararg` aborts in `recCall`).
    fn recBSelect(self: *TraceState, instr: Instr) !void {
        if (instr.c != 1) return self.abort(.cross_frame);
        if (instr.b < 1) return self.abort(.cross_frame);
        const sel_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
        const sel = self.konstValueOf(sel_ref) orelse return self.abort(.bad_type);
        if (!sel.isHeap() or sel.heapType() != .string) return self.abort(.bad_type);
        const bytes = string_mod.String.fromHeader(sel.asHeap()).bytes();
        if (bytes.len != 1 or bytes[0] != '#') return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .select);
        self.setReg(instr.a, try self.konst(Value.int(@as(i64, instr.b) - 1)));
    }

    /// `rawequal(a, b)` — the NaN-safe fold subset (doc 23 D2, codex catch #6:
    /// `Value.eql` is false for NaN==NaN, so same-ref must NOT blindly fold
    /// true). Konst×konst folds exactly; a same-ref pair folds true only once
    /// the ref is *pinned non-float* — observed table → raw `guard_table`,
    /// observed int → registered `guardNum` (pins int) — because a float (or
    /// unguarded) same-ref could be NaN on a later entry. Everything else
    /// aborts; a general value-compare op has no consumer yet.
    fn recBRawequal(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 2) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        const ra = try self.refOf(@intCast(@as(usize, instr.a) + 1));
        const rb2 = try self.refOf(@intCast(@as(usize, instr.a) + 2));
        const ka = self.konstValueOf(ra);
        const kb = self.konstValueOf(rb2);
        if (ka != null and kb != null) {
            try self.guardBuiltinCallee(instr.a, .rawequal);
            self.setReg(instr.a, try self.konst(Value.boolean(ka.?.eql(kb.?))));
            return;
        }
        if (ra != rb2) return self.abort(.bad_type);
        const argv = regs.get(@intCast(@as(usize, instr.a) + 1));
        if (argv.isInt()) {
            try self.guardBuiltinCallee(instr.a, .rawequal);
            try self.guardNum(ra, argv, .operand_type, .a1);
        } else if (argv.isHeap() and argv.heapType() == .table) {
            const tbl = table_mod.Table.fromHeader(argv.asHeap());
            if (tbl.metatable != null) return self.abort(.has_metatable);
            try self.guardBuiltinCallee(instr.a, .rawequal);
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = ra }), .operand_type, .a1, .neutral);
        } else {
            return self.abort(.bad_type); // float same-ref: NaN ~= NaN
        }
        self.setReg(instr.a, try self.konst(Value.boolean(true)));
    }

    /// `rawlen(v)` — arc A folds the konst-string case to its **byte** length
    /// (`bRawLen` returns `String.len`; `#s` is `cp_len`, a different quantity
    /// — codex catch #7, the two must never share an emission), and records an
    /// observed table through the same guarded `alen` shape as `#t` (`bRawLen`
    /// on a table is `Table.length()`, the identical border — and `rawget`-
    /// style raw-vs-plain is moot since the shape aborts on any metatable).
    fn recBRawlen(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const argv = regs.get(arg_slot);
        if (argv.isHeap() and argv.heapType() == .table) {
            try self.guardBuiltinCallee(instr.a, .rawlen);
            return self.recAlenShape(instr.a, arg_slot, .a1, regs);
        }
        const arg_ref = try self.refOf(arg_slot);
        const kv = self.konstValueOf(arg_ref) orelse return self.abort(.bad_type);
        if (!kv.isHeap() or kv.heapType() != .string) return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .rawlen);
        const len = string_mod.String.fromHeader(kv.asHeap()).len;
        self.setReg(instr.a, try self.konst(Value.int(@intCast(len))));
    }

    /// `rawget(t, k)` — records through the extracted index shapes (doc 23 D3).
    /// On a metatable-free table raw and non-raw access are the same operation,
    /// and the shapes abort `.has_metatable` at record time with `guard_table`
    /// re-proving absence at runtime — so the reuse is sound rather than
    /// assumed. Numeric key → array-get shape; string key → hash-get shape
    /// (konst-key-only, enforced inside). Grid-lane tables abort `.bad_type`:
    /// tier-0's raw access deflates grids, and a trace must not bake a
    /// deflation (`guard_lane` deopts if a table becomes a grid between
    /// entries). Provenance designates the call args (`.a1` table, `.a2` key).
    fn recBRawget(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 2) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        const tab_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const key_slot: u16 = @intCast(@as(usize, instr.a) + 2);
        const vtab = regs.get(tab_slot);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (table_mod.Table.fromHeader(vtab.asHeap()).array.lane == .grid) return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .rawget);
        const vkey = regs.get(key_slot);
        if (vkey.isNumber())
            try self.arrayGetShape(regs, .{ .dst = instr.a, .tab = tab_slot, .key = key_slot, .tab_od = .a1, .key_od = .a2 })
        else if (isStringKey(vkey))
            try self.hashGetShape(regs, .{ .dst = instr.a, .tab = tab_slot, .key = key_slot, .tab_od = .a1, .key_od = .a2 })
        else
            return self.abort(.bad_type);
    }

    /// `rawset(t, k, v)` — the write mirror of `recBRawget`, through the same
    /// extracted shapes with the store-sinking discipline unchanged (a sunk
    /// store commits below every guard exactly as for `set_index`). A nil/NaN
    /// key falls out naturally: nil is neither number nor string key (abort),
    /// NaN fails `keyIndexOf` inside the array shape — tier-0 owns the error.
    /// The statement-tolerant arm (doc 23 D1): `c ∈ {0,1}` — a statement call
    /// (`rawset(t, k, v)` discarding the result, the common form, compiled
    /// with `c == 0`) records the store alone; a value call (`c == 1`) also
    /// defines the dest register with the table ref (tier-0 `bRawSet` returns
    /// `args[0]`).
    fn recBRawset(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 3) return self.abort(.cross_frame);
        if (instr.c > 1) return self.abort(.cross_frame);
        const tab_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const key_slot: u16 = @intCast(@as(usize, instr.a) + 2);
        const val_slot: u16 = @intCast(@as(usize, instr.a) + 3);
        const vtab = regs.get(tab_slot);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (table_mod.Table.fromHeader(vtab.asHeap()).array.lane == .grid) return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .rawset);
        const vkey = regs.get(key_slot);
        if (vkey.isNumber())
            try self.arraySetShape(regs, .{ .tab = tab_slot, .key = key_slot, .val = val_slot, .tab_od = .a1, .key_od = .a2, .val_od = .a3 })
        else if (isStringKey(vkey))
            try self.hashSetShape(regs, .{ .tab = tab_slot, .key = key_slot, .val = val_slot, .tab_od = .a1, .key_od = .a2, .val_od = .a3 })
        else
            return self.abort(.bad_type);
        if (!self.isRecording()) return; // the shape aborted
        if (instr.c == 1) self.setReg(instr.a, try self.refOf(tab_slot));
    }

    /// Record `#t` / `rawlen(t)` as the guarded `alen` producer (doc 23 D3):
    /// `guard_table(t)` then `alen(t)`, whose own runtime check side-exits
    /// unless the exact fast case holds (hash empty ∧ bitmap lane ∧ (asize ≤ 1 ∨
    /// present(asize−1))). The record-time observation must already satisfy the
    /// fast case — an already-failing shape would be an instant turnstile — and
    /// `.value`/`.boolean`/grid lanes abort (their presence is in-band, so the
    /// fast case can't certify the border without reading elements).
    ///
    /// Sunk-store interaction (arc-A codex #4, REFINED in doc 24 D7): pending
    /// RMW stores flush at commit, below every guard, so on-trace `alen` reads
    /// the pre-store table state mid-iteration. That is sound WITHOUT an abort
    /// because sunk stores cannot change the guarded fast-case answer:
    ///   - only in-bounds stores sink (appends are never deferred — they change
    ///     `len` and abort/`astore_append` inline), so `asize` is invariant;
    ///   - stores never clear presence (nil hole-punch aborts), so
    ///     `present(asize-1)` can only go false→true; the trace's alen check
    ///     reading the stale FALSE side-exits — and since `alen` is a
    ///     side-exiting op, the sunk stores are un-executed at that exit and
    ///     tier-0's replay applies them exactly once (the doc-08 argument);
    ///   - when the check passes on the pre-store state, the result depends
    ///     only on `asize` — identical pre- and post-store;
    ///   - a sunk `hstore` implies a non-empty hash on ITS table; if that is
    ///     this table, the record-time `hash.count()` check below aborts, and
    ///     a different table cannot alias this one's header fields.
    /// So: no pending-store abort. Gate: the rawset-then-`#t` differential in
    /// trace_record_test.zig plus scalar's end-to-end run (doc 24 D7).
    fn recAlenShape(self: *TraceState, dst: u16, tab_slot: u16, tab_od: OperandDesig, regs: RegWindow) !void {
        const vtab = regs.get(tab_slot);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        if (tbl.hash.count() != 0) return self.abort(.bad_type);
        if (!tbl.array.lane.scalarPresenceLane()) return self.abort(.bad_type);
        const asize = tbl.array.asize;
        if (asize > 1 and !tbl.array.isPresent(asize - 1)) return self.abort(.bad_type);
        const rtab = try self.refOf(tab_slot);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, tab_od, .neutral);
        const r = try self.emit(.{ .op = .alen, .a = rtab, .ty = .int });
        self.stampProv(r, .border, tab_od, .neutral);
        self.setReg(dst, r);
    }

    /// Emit `guard_builtin(callee, rb)` unless this callee ref already carries
    /// one — re-proving, in both tiers, that the seeded callee is still this
    /// exact builtin. The callee ref is the seeded loop-invariant input (so the
    /// guard checks the same value `seedTraceInputs` re-resolves). Deduped
    /// against `guarded_refs` — one SSA value, one identity check (a native
    /// callee never carries a numeric type guard, so reusing the set is sound).
    /// `aux` carries the `RecordedBuiltin` ordinal, not a PC.
    fn guardBuiltinCallee(self: *TraceState, callee_slot: u16, rb: function.RecordedBuiltin) !void {
        const callee_ref = try self.refOf(callee_slot);
        if (!self.rec.guarded_refs.contains(callee_ref)) {
            try self.rec.guarded_refs.put(self.gpa, callee_ref, {});
            self.stampProv(try self.emit(.{ .op = .guard_builtin, .a = callee_ref, .aux = @intFromEnum(rb) }), .callee_pure, .a, .neutral);
        }
    }

    /// Inline a `math.sqrt(x)` call (callee flagged `RecordedBuiltin.sqrt`, doc 12) as a
    /// leaf `fsqrt` producer instead of aborting `.host_barrier`. Emits, in order:
    /// `guard_builtin(callee)` (re-prove the seeded callee is still this exact builtin —
    /// deduped like a type guard, LICM-hoistable since the callee is a once-seeded
    /// loop invariant), a type guard pinning the numeric operand, then
    /// `fsqrt(arg)` whose result lands directly in the call's destination register.
    /// NO frame push / NO `recReturn`: `fsqrt` is a leaf producer — the single value
    /// the call site wants is `instr.a` itself, with no callee window to model.
    fn recPureSqrt(self: *TraceState, instr: Instr, regs: RegWindow) !void {
        return self.recFloatUnary(instr, regs, .sqrt, .fsqrt);
    }

    /// The shared float-leaf shape (doc 23 D4): `f(x)` with one fixed numeric
    /// arg and one result inlines as `guard_builtin(callee)` + a type guard on
    /// the arg + a leaf float-producer op (`fsqrt`/`fsin`/`fcos`) whose result
    /// lands in the call's destination. One fixed arg, one fixed result — any
    /// other arity has no leaf shape, abort, tier-0 owns the call.
    ///
    /// Numeric args only: the observed type (int or float) is pinned by
    /// `guard_int`/`guard_float`, and an int operand is promoted by the SAME
    /// operand-level discipline the float binary ops already use — tier-1a
    /// `@floatFromInt`, native `cvtsi2sd` in `floatOperandToXmm`, both
    /// round-to-nearest and bit-identical (partialsums' `sin(k)`/`sqrt(k)`
    /// with an integer loop var is exactly this shape; doc 23 D4 note).
    /// Anything non-numeric aborts `.bad_type`.
    fn recFloatUnary(self: *TraceState, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        const arg = regs.get(@intCast(@as(usize, instr.a) + 1));
        if (!arg.isFloat() and !arg.isInt()) return self.abort(.bad_type);

        try self.guardBuiltinCallee(instr.a, rb);
        const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
        const g: IrOp = if (arg.isFloat()) .guard_float else .guard_int;
        try self.guard(arg_ref, g, .operand_type, .a1);
        const r = try self.emit(.{ .op = op, .a = arg_ref, .ty = .float });
        self.setReg(instr.a, r);
    }

    /// Record `math.floor(x)` / `math.ceil(x)`. Unlike `recFloatUnary`
    /// (sin/cos/sqrt → float result), these produce an INTEGER result (Lua 5.4
    /// semantics: `math.floor(2.7) == 2`, an int, not `2.0`).
    ///
    /// Integer path: `floor(int) == int` (identity). Emit `guard_int(arg)` and
    /// reuse the same ref — no `ffloor`/`fceil` emitted.
    /// Float path: emit `guard_float(arg)` + `ffloor`/`fceil` with `.ty = .int`.
    /// The IR op side-exits on NaN / inf / out-of-`[-2^63, 2^63)`.
    fn recFloorCeil(self: *TraceState, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
        if (instr.b != 1) return self.abort(.cross_frame); // single-arg only
        if (instr.c != 1) return self.abort(.cross_frame); // single-result only
        const arg = regs.get(@intCast(@as(usize, instr.a) + 1));
        if (!arg.isFloat() and !arg.isInt()) return self.abort(.bad_type);

        try self.guardBuiltinCallee(instr.a, rb);
        const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));

        if (arg.isInt()) {
            // Integer → identity: floor/ceil of an int is itself.
            try self.guard(arg_ref, .guard_int, .operand_type, .a1);
            self.setReg(instr.a, arg_ref);
        } else {
            // Float → ffloor/fceil producing an integer.
            try self.guard(arg_ref, .guard_float, .operand_type, .a1);
            const r = try self.emit(.{ .op = op, .a = arg_ref, .ty = .int });
            self.setReg(instr.a, r);
        }
    }

    /// Cross-frame tracing — close an inlined callee (LuaJIT's `lj_record_ret`).
    /// Only reached at `inline_depth > 0` (the anchor-frame `.ret` aborts). Maps the
    /// callee's result slots back into the caller's `ret_dest..` window, nil-padding
    /// to the call site's fixed `ret_count`, then pops the recorder frame and
    /// restores `base_off`. The result writes use *absolute* `reg_map` indices (the
    /// caller region is disjoint from and below the callee source region, so a
    /// single forward pass can read source then write dest without a buffer).
    fn recReturn(self: *TraceState, instr: Instr, multret: ?u32) !void {
        const d = self.rec.inline_depth - 1;
        const fr = self.rec.frames[d];
        // Doc 27 D5: `ret a, all_results` (`return prefix..., g(...)`) resolves
        // its produced count from the multret shadow in CALLEE frame-space —
        // `top - a` counts the fixed prefix slots plus everything the trailing
        // producer left, exactly tier-0's `reg_top`-based resolution. Fails
        // closed on a `null` shadow and on the sentinel bound (§3a, u32 math).
        const produced: u32 = if (instr.b == bytecode.all_results) blk: {
            const top = multret orelse return self.abort(.cross_frame);
            if (top < instr.a) return self.abort(.cross_frame);
            const n = top - instr.a;
            if (n >= bytecode.all_results) return self.abort(.cross_frame);
            break :blk n;
        } else instr.b;
        // Doc 27 D4: a caller that wanted a dynamic window (`call … c =
        // all_results`) takes exactly `produced` values — no nil-fill, tier-0's
        // `wants_all` arm — and re-exports the shadow for ITS caller's next
        // instruction, in caller frame-space (after `base_off` is restored).
        const wants_all = fr.ret_count == bytecode.all_results;
        const want: u32 = if (wants_all) produced else fr.ret_count;
        // The dynamic shapes can write above the caller's fixed window (tier-0
        // does the same into slab scratch); bound them against the reg_map
        // reservation like `recCall` bounds callee windows.
        if (@as(usize, fr.base_off) + fr.ret_dest + want > self.rec.reg_map.len)
            return self.abort(.frame_bounds);
        var k: u32 = 0;
        while (k < want) : (k += 1) {
            // `base_off` is still the callee window here, so `refOf` reads the
            // callee's result slots `instr.a + k`.
            const ref: Ref = if (k < produced)
                try self.refOf(@intCast(@as(usize, instr.a) + k))
            else
                try self.konst(Value.nil());
            // Whole-RegSlot write → `defineSlotAbs` (doc 39): return values can
            // land back in the ANCHOR window (`fr.base_off == 0`), where the
            // write must both preserve `entry_kind` and mark a peel rebound.
            self.defineSlotAbs(@as(usize, fr.base_off) + fr.ret_dest + k, ref);
        }
        self.rec.base_off = fr.base_off;
        self.rec.inline_depth = d;
        if (wants_all) self.rec.multret_top = @as(u32, fr.ret_dest) + produced;
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
    ///
    /// Inlined-callee upvalues: reads inside inlined callees (inline_depth > 0) create a
    /// `callee_upvalue` seed that resolves through the callee's closure at entry.
    /// The callee's closure is in a slab slot that was itself seeded earlier (as an
    /// anchor-frame `upvalue`/`global` or regular `slot_load` input), so seed
    /// ordering is correct by construction. Global reads at inline_depth > 0 still
    /// abort — globals use proto-specific constant pool indices.
    fn recInputGet(self: *TraceState, comptime kind: InputKind, dest: u16, source: u16, resolved: Value) !void {
        // Inlined-callee upvalues resolve through the callee's
        // closure. Global reads at depth > 0 still abort: the seed uses the
        // anchor's proto.constants, but the global's constant-pool index refers to
        // the callee's proto — a different key set.
        if (self.rec.inline_depth != 0) {
            if (kind == .global) return self.abort(.cross_frame);
            // kind == .upvalue at inline_depth > 0 → callee_upvalue seed.
            return self.recCalleeUpval(dest, source, resolved);
        }

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
        if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);

        // Defensive: the synthetic slot counter is a `u16` seeded at
        // `anchor_num_registers`. A function with a near-`u16`-max register window
        // could push it to the wrap boundary; an `@intCast`-wrapped slot would fold
        // back *into* the live anchor window as a plausible in-window `slot_load`
        // that `assertWellFormed` (bound `anchor_num_registers + n_inputs`) cannot
        // catch — and `seedTraceInputs` would then clobber a live caller register.
        // Abort rather than wrap. (MAX_TRACE_INPUTS already bounds the count; this
        // bounds the *index*.)
        if (self.rec.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

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

    /// Record a `get_upval` inside an inlined callee. The callee's closure
    /// must be reachable as a `slot_load` in the anchor slab (i.e. the callee was
    /// loaded from an upvalue/global/local of the anchor frame). If the callee was
    /// computed on-trace (not a `slot_load`), we abort — on-trace closure creation
    /// is future work (doc 24).
    ///
    /// The seed resolves at entry by reading the callee closure from its slab slot
    /// and then resolving `closure.upvalues[source]` through `upvalGet`. The
    /// callee's own seed was appended earlier (when the anchor-frame `get_upval`
    /// that loaded the callee ran), so seed ordering is correct by construction.
    fn recCalleeUpval(self: *TraceState, dest: u16, source: u16, resolved: Value) !void {
        // Find the callee's closure ref. The callee was at register `ret_dest` in
        // frame `inline_depth - 1` (ret_dest = instr.a of the .call that opened
        // this inline frame — Lua convention: reg A holds the callee).
        const d = self.rec.inline_depth - 1;
        const callee_anchor_reg: usize = @as(usize, self.rec.frames[d].base_off) + self.rec.frames[d].ret_dest;
        if (callee_anchor_reg >= self.rec.reg_map.len) return self.abort(.cross_frame);
        const callee_entry = self.rec.reg_map[callee_anchor_reg];
        if (callee_entry.state == .undef) return self.abort(.cross_frame);
        const callee_ref = callee_entry.ref;

        // The callee ref must be a `slot_load` — that means the callee's closure
        // is in a known slab slot at entry time. A computed callee (aload, hload,
        // etc.) can't be re-resolved at entry, so we abort.
        const callee_ir = self.rec.instrs.items[callee_ref];
        if (callee_ir.op != .slot_load) return self.abort(.cross_frame);
        const callee_slot: u16 = @intCast(callee_ir.aux);

        // Dedup: (callee_upvalue << 32) | (callee_slot << 16) | source.
        // Two different inlined callees might both read upvalue index 0, so the
        // key must incorporate which callee.
        const key = (@as(u64, @intFromEnum(InputKind.callee_upvalue)) << 32) |
            (@as(u64, callee_slot) << 16) | source;
        if (self.rec.input_dedup.get(key)) |ref| {
            self.setReg(dest, ref);
            return;
        }

        if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);
        if (self.rec.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

        const slot = self.rec.next_input_slot;
        self.rec.next_input_slot += 1;
        const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
        try self.rec.entry_slots.append(self.gpa, slot);
        try self.rec.input_seeds.append(self.gpa, .{
            .kind = .callee_upvalue,
            .source = source,
            .slot = slot,
            .callee_slot = callee_slot,
        });
        try self.rec.input_dedup.put(self.gpa, key, ref);

        // Pin a function callee's identity (same as the anchor-frame path).
        if (resolved.isHeap() and resolved.heapType() == .function) {
            const cl = function.Closure.fromHeader(resolved.asHeap());
            self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
        }
        self.setReg(dest, ref);
    }
};

/// Doc 39: `pc` anchors a *plain while* loop — at least one plain backward
/// `jmp` targets it, and no conditional backward jump (a repeat-until
/// back-edge) or loop-op back-edge (`for_loop`/`tfor_loop`/`jfor_loop`)
/// does. Pure bytecode geometry as a standalone predicate. Unmemoized: it
/// runs at most once per anchor-return of an otherwise-eligible root
/// recording, never on the dispatch hot path.
fn isPlainWhileAnchor(proto: *const Proto, pc: u32) bool {
    var has_plain = false;
    for (proto.code, 0..) |ins, j| {
        const is_jump = switch (ins.op) {
            .jmp, .jmp_if_false, .jmp_if_true, .for_loop, .tfor_loop, .jfor_loop => true,
            else => false,
        };
        if (!is_jump) continue;
        const t = @as(i64, @intCast(j)) + 1 + ins.aux;
        if (t != pc or j <= pc) continue;
        if (ins.op == .jmp) {
            has_plain = true;
        } else {
            return false;
        }
    }
    return has_plain;
}

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

/// Doc 39 Phase 0: the numeric kind a type proof established for a slot's
/// ENTRY value (the `slot_load`), or `.none` when no int/float proof covered
/// it. Stamped centrally by `noteEntryKind` on every proof route (`guardNum`,
/// `guardInt`/`keyRefNarrowed`, bitop guards, lane-implied `guard_fits`) and
/// preserved across every whole-`RegSlot` write (`defineSlotAbs`), so the
/// peel-eligibility sweep can compare "entered int" against "carries float".
const EntryKind = enum { none, int, float };

/// The SSA ref currently held by a tier-0 register, with how it got there.
/// `entry_kind` records the proven numeric kind of the slot's entry value
/// (doc 39) — a property of the recording's entry snapshot, so it survives
/// redefinition (`.def`) of the slot.
const RegSlot = struct { ref: Ref = 0, state: SlotState = .undef, entry_kind: EntryKind = .none };

/// Doc 39: one anchor-window slot's snapshot at the peel marker (the first
/// anchor-return of a type-unstable plain-while root).
const PeelSlot = struct {
    /// The slot's iteration-1 final ref at the marker.
    ref: Ref = 0,
    /// The slot's state at the marker: `.def` = iteration 1 defined it (a body
    /// read lazily creates an internal φ); `.input`/`.undef` = invariant or
    /// untouched (referenced directly, no φ).
    state: SlotState = .undef,
    /// The body pass wrote this slot, or its internal φ was already created —
    /// either way, later body reads use `reg_map` directly (no new φ). A body
    /// WRITE before any read deliberately leaves `phi_ref` null: the slot has
    /// no cross-iteration dataflow of its own (redefined from other φ'd inputs
    /// every iteration) and falls to the existing write-only slot class.
    rebound: bool = false,
    /// The internal φ (aux == PHI_INTERNAL) carrying this slot's steady state,
    /// created lazily at the first body read. Its `b` is patched at close.
    phi_ref: ?Ref = null,
};

/// Doc 39: in-flight type-stabilizing peel. Entered at the first anchor-return
/// of an eligible unstable recording (`maybeEnterPeel`); cleared by `reset`.
const PeelState = struct {
    /// `instrs.len` immediately after the `preheader` marker was emitted. A
    /// close-path call arriving with the stream still at this length is the
    /// SAME logical anchor-return that entered the peel (`onBackEdge` and
    /// `maybeCloseAtAnchor` both fire on one arrival — the shared-generation
    /// rule, codex round-2 finding 1) and must not close; the next arrival
    /// (stream grown by the body pass) is the real second return.
    mark_len: usize,
    /// Per-slot marker snapshot, length `anchor_num_registers` (gpa-owned;
    /// freed by `Recorder.reset`/`deinit`).
    slots: []PeelSlot,
};

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
/// A deferred read-modify-write store (`op` = `.astore` for an in-bounds array
/// slot, `.hstore` for a present hash cell), sunk below every guard at trace
/// close. `aref`/`value` are IR refs already emitted inline (the address node —
/// `aref`/`href` — and the value to store); `lane_ord` is the packed-array
/// `Lane` ordinal (the `astore`'s `aux`; 0 and unused for `.hstore`). See
/// `Recorder.pending_stores`.
const PendingStore = struct {
    aref: Ref,
    value: Ref,
    lane_ord: i32,
    op: IrOp = .astore,
};

const AliasClass = enum { must, no, may };
const AffineIntKey = struct { base: Ref, offset: i64 };

/// Per-inlined-frame register reservation in the recorder's grown `reg_map`. The
/// map is sized `anchor.num_registers + MAX_INLINE_DEPTH × MAX_CALLEE_REGS`; a
/// callee whose `num_registers` exceeds this reservation (or that would overflow
/// the map at depth) aborts cleanly rather than reading the slab out of bounds.
/// 256 covers every realistic leaf body the compiler emits.
const MAX_CALLEE_REGS = 256;

/// Maximum number of synthetic entry inputs (upvalue/global/hash-cell
/// snapshots) a single trace may carry. Each is one slab slot the dispatch loop
/// re-seeds + widens the executor window by; a trace wanting more aborts
/// cleanly (`.input_cap`), and the widened window is still capacity-checked
/// dynamically at every entry (`seedTraceInputs` declines on overflow), so this
/// constant is pure policy — a backstop against a pathological loop growing the
/// entry snapshot without bound — not a layout invariant.
///
/// Measured 2026-08-28 (input-cap sweep, CURRENT_TASK LATEST-94): the machinery
/// is free at every width tried. Synthetic N-upvalue-callee loops at N =
/// 2..64, steady-state AND entry-heavy shapes, show a flat jit cost curve
/// (~45× over tier-0 throughout), and the direct control — the same N callees
/// as anchor-frame locals (zero inputs) vs upvalues (N inputs) — is identical
/// within noise at N = 8/16/32/64. The old value (8) was set on the guess "a
/// handful of callees covers every realistic loop"; str_manip's main path
/// already needs 7, and one more cached builtin in any user loop would have
/// silently killed its trace. 64 keeps the backstop role (maxrecord bounds the
/// IR anyway — each input costs ≥2 ops) without realistically binding.
///
/// `pub` for the diagnostic dumps only (`writeTrace`, `dumpNative` in main.zig
/// render `inputs=N/{this}`); nothing outside this file may make policy off it.
pub const MAX_TRACE_INPUTS = 64;

/// One saved caller context for an inlined `.call`, popped at the matching
/// `.ret`. `base_off` is the caller frame's absolute slot offset (relative to the
/// anchor frame's base); `ret_dest`/`ret_count` mirror the call's `instr.a`/
/// `instr.c` (where results land in the caller, and how many it wants).
pub const InlineFrame = struct {
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
pub fn pathFromFrames(frames: []const InlineFrame, depth: u8) [MAX_INLINE_DEPTH]CallEdge {
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
    /// Doc 39: in-flight type-stabilizing peel, or null (the common case — no
    /// peel entered). Set by `maybeEnterPeel` at the first anchor-return of an
    /// int-entry/float-body plain-while root; consulted by the close paths
    /// (same-arrival suppression + second-return close), `refOf` (lazy internal
    /// φ) and `defineSlotAbs` (rebound tracking); consumed by `finishPeel` +
    /// `commit`. Cleared (slice freed) by `reset`/`deinit`.
    peel: ?PeelState = null,
    /// Doc 38 unroll-first policy: this ROOT recording followed at least one
    /// inner-while back-edge inline (unrolled it) instead of aborting LINNER.
    /// Read at abort (an unrolling root that dies bumps the outer anchor's
    /// `unroll_fail` evidence) and carried onto the committed `Trace` so
    /// runtime thrash of an unrolled root counts as the same evidence.
    unrolled_while: bool = false,
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
    /// Hotexit provenance: the parent `(trace id, exit index)` whose hot exit
    /// triggered this recording (`noteTakenExit` → want → arm). Non-null only
    /// for hotexit-sourced recordings; on successful commit the parent's exit
    /// counter is latched `EXIT_COUNT_DONE` (Pall's `SNAPCOUNT_DONE` at
    /// lj_trace.c:535). Cleared by `reset` and consumed by `commit`; an abort
    /// simply drops it (Pall retries the exit — `snap->count` stays hot — and
    /// the abort's own `gateAnchor` backoff is our `penalty_pc` analog).
    side_src: ?ExitKey = null,
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
    /// Deferred (sunk) stores: in-bounds `astore`s that follow an `aload` and
    /// present-cell `hstore`s that follow an `hload` (read-modify-writes). Rather
    /// than abort the trace (the old C1 rule), `recArraySet`/`recHashSet` record
    /// each store's address + guards inline but stash the store node itself here;
    /// `commit()` flushes them — *front-to-back, in the
    /// recorded (tier-0 bytecode) order* — *after* every guard (incl. the `for_loop`
    /// continuation guard), just before the `.loop` terminator. Sinking them below
    /// all side-exits makes deopt-replay idempotent: any guard failure leaves *all*
    /// of them un-executed, so tier-0 re-runs the iteration along the original source
    /// path and applies exactly that path's stores once each. Flushing in recorded
    /// order keeps last-writer-wins identical between the trace and tier-0 even if two
    /// stores alias. See `docs/design/08-multi-store-sinking.md` (Gap C); doc 07 is
    /// the single-store original (Gap B).
    ///
    /// A later array or hash read consults this virtual store buffer
    /// newest-to-oldest (`forwardPendingArrayLoad`/`forwardPendingHashLoad`):
    /// must-alias loads forward the pending value, proven-non-alias loads read the
    /// heap behind guards, and ambiguous table identity aborts fail-closed. Appends
    /// still abort because they mutate array shape. The list is naturally bounded
    /// by `maxrecord`; native register pressure spills or rejects the completed trace.
    pending_stores: std.ArrayListUnmanaged(PendingStore) = .empty,

    // --- deterministic on-trace allocation (doc 24 D3/D4) -------------------
    /// Count of `.alloc`-kind ops emitted so far — the allocation bound `A`.
    /// `commit()` stamps it into the entry `guard_gc`'s `aux` and the committed
    /// `Trace.alloc_bound`. Each `.alloc` op's helper performs at most one
    /// `Heap.link` (the D5 audit rule), so `A` bounds the burst's worst-case
    /// id consumption per iteration.
    alloc_count: u32 = 0,
    /// Emission ref of the single entry `guard_gc`, emitted by `emitAlloc`
    /// immediately before the FIRST `.alloc` op (which places it before every
    /// `.alloc` op — the only ordering the D3 argument needs: effects that
    /// precede it are already header-replay-idempotent under the C1 discipline,
    /// and a failing `guard_gc` means zero allocations were performed this
    /// iteration, so the D2 clean-replay premise holds). Null for a
    /// non-allocating recording (no `guard_gc` at all — arc-A traces unchanged).
    guard_gc_ref: ?Ref = null,

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
    /// Doc 27: frame-relative one-past-the-end of the values the immediately-
    /// preceding recorded instruction produced under `c == all_results` — the
    /// recorder's shadow of tier-0's `reg_top`/`reg_top_pending` handshake.
    /// Set only by a successfully recorded producer; valid for exactly one
    /// instruction (`recordOne` stashes and clears it before dispatch, mirroring
    /// tier-0's `reg_top_pending` scope); expressed in the frame-space of the
    /// instruction that will consume it. `null` = no pending producer — every
    /// `all_results` consumer fails closed on it. `u32`, not `u16`: a valid
    /// one-past top can be 65,536 (the slab size), and a resolved count must be
    /// checked below the `all_results` sentinel before it becomes a fixed arity
    /// (doc 27 §3a). Cleared on `reset` (the soundness boundary — a `maxrecord`
    /// abort fires before the `recordOne` stash, so a stale shadow could
    /// otherwise leak into the NEXT recording) and on `abort` (defense-in-depth).
    multret_top: ?u32 = null,

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
        if (self.peel) |p| gpa.free(p.slots);
        self.pending_stores.deinit(gpa);
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
        self.pending_stores.clearRetainingCapacity();
        self.alloc_count = 0;
        self.guard_gc_ref = null;
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
        self.side_src = null;
        self.anchor_num_registers = num_registers;
        self.base_off = 0;
        self.inline_depth = 0;
        self.multret_top = null; // doc 27 §3a: never inherit a stale shadow
        if (self.peel) |p| gpa.free(p.slots);
        self.peel = null;
        self.unrolled_while = false;
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
        // guard_sid: operand + the expected string's konst id.
        .guard_sid => try w.print("%{d}  sid=k{d}", .{ ins.a, ins.aux }),
        // `guard_builtin` reads the callee `%a` and tags the builtin in `aux`.
        .guard_builtin => try w.print("%{d}  [{s}]", .{ ins.a, @tagName(@as(function.RecordedBuiltin, @enumFromInt(ins.aux))) }),
        .loop, .preheader => {},
        // `.link` (doc 15): terminal hand-off; `aux` is the inner root's anchor pc.
        .link => try w.print("-> {d}", .{ins.aux}),
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

/// Disassemble a whole trace: header + entry slots + numbered IR (the slot-bound
/// `phi` rows are the loop-carried writebacks that `exit_stores` used to list).
pub fn writeTrace(w: *io.Writer, t: *const Trace) io.Writer.Error!void {
    try w.print("trace {s}:{d}  entry=[", .{ t.anchor.proto.name, t.anchor.pc });
    for (t.entry_slots, 0..) |s, i| {
        if (i != 0) try w.writeAll(" ");
        try w.print("r{d}", .{s});
    }
    // Synthetic entry inputs (upvalue/global/hash-cell snapshots) against the
    // MAX_TRACE_INPUTS policy cap — so a dump answers "how close is this trace
    // to the input budget?" at a glance instead of leaving it to be guessed
    // from abort rows (which once misdiagnosed str_manip as cap-blocked when
    // its main trace used 7 of 8, back when the then-`.too_deep` tag — now
    // split into `.input_cap`/`.frame_bounds`/`.too_deep` — hid which limit
    // fired; CURRENT_TASK LATEST-94).
    try w.print("]  inputs={d}/{d}\n", .{ t.inputs.len, MAX_TRACE_INPUTS });
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

/// Cycles-per-iteration for the stats report; 0 when there were no iterations.
fn cyclesPerIter(cycles: u64, iters: u64) f64 {
    if (iters == 0) return 0;
    return @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(iters));
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
            "mahina: jit coverage — iters: traced {d:.1}% / fallback {d:.1}%",
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

    try w.writeAll("mahina: JIT stats\n");
    try w.writeAll("  event counters:\n");
    try w.print("    trace entries:        {d} (native bodies: {d})\n", .{ ts.entries, ts.native_entries });
    try w.print("    link arms:            native={d} source={d} loopdone={d} bridge={d}\n", .{ ts.native_link_arms, ts.native_source_link_arms, ts.native_loopdone_link_arms, ts.native_region_bridge_arms });
    try w.print("    bridge arm attempts:  {d} (pipeline runs; vs {d} arms)\n", .{ ts.native_region_bridge_arm_attempts, ts.native_region_bridge_arms });
    try w.print("    link fused:           source={d} loopdone={d} bridge={d}\n", .{ ts.native_source_link_fused, ts.native_loopdone_link_fused, ts.native_region_bridge_fused });
    try w.print("    link disarms:         {d} (peak simultaneous arms: {d})\n", .{ ts.native_link_disarms, ts.native_link_peak });
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
        // The seam is a sub-interval of the traced bracket (`cycles_seam` doc);
        // clamp so TSC skew can never report negative native time.
        const c_seam = if (ts.cycles_seam < c_traced) ts.cycles_seam else c_traced;
        const c_native = c_traced - c_seam;
        const c_tier0 = c_cov +| c_unc;
        try w.writeAll("  coverage by time (TSC cycles — the honest split):\n");
        try w.print("    traced (ran as trace):  {d:>12}  ({d:.1}% of run)\n", .{ c_traced, pctOf(c_traced, run) });
        try w.print("      native execution:     {d:>12}  ({d:.1}% of run)\n", .{ c_native, pctOf(c_native, run) });
        if (ts.seam_walks > 0) {
            try w.print("      steering seam:        {d:>12}  ({d:.1}% of run)   replayLedger: {d} walks, ~{d} cyc/walk\n", .{
                c_seam, pctOf(c_seam, run), ts.seam_walks, ts.cycles_seam / ts.seam_walks,
            });
        } else {
            try w.print("      steering seam:        {d:>12}  ({d:.1}% of run)   replayLedger: 0 walks\n", .{ c_seam, pctOf(c_seam, run) });
        }
        try w.print("    tier-0 (Vm.exec bodies):{d:>12}  ({d:.1}% of run)\n", .{ c_tier0, pctOf(c_tier0, run) });
        try w.print("      tier-0, has-trace:    {d:>12}  ({d:.1}% of run)   <- fallback despite a trace\n", .{ c_cov, pctOf(c_cov, run) });
        try w.print("      tier-0, no-trace:     {d:>12}  ({d:.1}% of run)\n", .{ c_unc, pctOf(c_unc, run) });
        try w.print("    other (non-loop):       {d:>12}  ({d:.1}% of run)\n", .{ c_other, pctOf(c_other, run) });
        try w.print("    run total:              {d:>12}\n", .{run});
        // Per-iteration / per-entry costs — the numbers that expose transition
        // amortization (few iters per native entry = the seam dominates) and let
        // the native c/it be compared against another VM's whole-run c/it without
        // hand arithmetic.
        if (traced > 0 or covered_interp +| uncovered > 0) {
            try w.writeAll("    cycles/iter:           ");
            if (traced > 0) {
                try w.print(" traced ~{d:.1} (native ~{d:.1} + seam ~{d:.1})", .{
                    cyclesPerIter(c_traced, traced), cyclesPerIter(c_native, traced), cyclesPerIter(c_seam, traced),
                });
            }
            const t0_iters = covered_interp +| uncovered;
            if (t0_iters > 0)
                try w.print("   tier-0 ~{d:.1}", .{cyclesPerIter(c_tier0, t0_iters)});
            try w.writeAll("\n");
            if (traced > 0 and ts.entries > 0)
                try w.print("    iters/native-entry:     ~{d}\n", .{traced / ts.entries});
        }
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
        try w.print("    {s:<18}  {s:>11}  {s:>11}  {s:>6}   {s:>6}  {s:>8}  {s:>8}  {s:>8}\n", .{ "anchor", "traced-it", "interp-it", "trc%it", "run%", "trc%time", "trc-c/it", "t0-c/it" });
        for (rows[0..n]) |r| {
            var name_pc_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&name_pc_buf, "{s}:{d}", .{ r.name, r.pc }) catch "?";
            const anchor_cycles = r.traced_cycles +| r.interp_cycles;
            if (has_time) {
                try w.print("    {s:<18}  {d:>11}  {d:>11}  {d:>5.1}%   {d:>5.1}%  {d:>7.1}%  {d:>8.1}  {d:>8.1}\n", .{
                    label,                                    r.traced,
                    r.interp,                                 pctOf(r.traced, r.traced +| r.interp),
                    pctOf(anchor_cycles, run),                pctOf(r.traced_cycles, anchor_cycles),
                    cyclesPerIter(r.traced_cycles, r.traced), cyclesPerIter(r.interp_cycles, r.interp),
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
// Tests
// ---------------------------------------------------------------------------
//
// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only
// analyses a file that is reachable by import, so this block is what makes them
// run under `zig build test`.

test {
    _ = @import("trace_ir_test.zig");
    _ = @import("trace_record_test.zig");
    _ = @import("trace_chain_test.zig");
    _ = @import("trace_provenance_test.zig");
    _ = @import("trace_promotion_test.zig");
    _ = @import("trace_replay_test.zig");
    _ = @import("trace_fingerprint_test.zig");
    _ = @import("trace_gate_test.zig");
    _ = @import("trace_region_test.zig");
    _ = @import("trace_entrypatch_test.zig");
}
