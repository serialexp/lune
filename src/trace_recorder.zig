//! Independent recording scratch and lifecycle. Publication is coordinator-owned.
const std = @import("std");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const string_mod = @import("string.zig");
const pattern_mod = @import("stdlib/pattern.zig");
const string_stdlib = @import("stdlib/string.zig");
const table_mod = @import("table.zig");
const arith = @import("arith.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;

const AnchorKey = @import("trace_types.zig").AnchorKey;
const ChargeKind = @import("trace_ir.zig").ChargeKind;
const IrOp = @import("trace_ir.zig").IrOp;
const IrInstr = @import("trace_ir.zig").IrInstr;
const trace_ir = @import("trace_ir.zig");
const Ref = @import("trace_ir.zig").Ref;
const ObsType = @import("trace_ir.zig").ObsType;
const PHI_INTERNAL = @import("trace_ir.zig").PHI_INTERNAL;
const guardExitPc = @import("trace_ir.zig").guardExitPc;
const guardSourcePc = @import("trace_ir.zig").guardSourcePc;
const isSideExitGuardOp = @import("trace_ir.zig").isSideExitGuardOp;
const GuardRole = @import("trace_types.zig").GuardRole;
const OperandDesig = @import("trace_types.zig").OperandDesig;
const Polarity = @import("trace_types.zig").Polarity;
const trace_code = @import("trace_code.zig");
const InputKind = trace_code.InputKind;
const UPVALUE_CELL_ANCHOR = trace_code.UPVALUE_CELL_ANCHOR;
const MAX_INLINE_DEPTH = @import("trace_types.zig").MAX_INLINE_DEPTH;
const CallEdge = @import("trace_types.zig").CallEdge;
const SlotStore = @import("trace_ir.zig").SlotStore;
const trace_snapshot = @import("trace_snapshot.zig");
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
    /// Store-forwarding ambiguity: a pending-store load-forwarding pass
    /// (`forwardPendingArrayLoad` / `forwardPendingHashLoad`) could not
    /// prove non-aliasing between a pending store and a load — either the
    /// pending store's op is unclassified, the table SSA refs are distinct
    /// (same key, different table — `may`-alias), or the key alias class
    /// was `.may`. Fail-closed: tier-0 owns the iteration.
    store_fwd_ambiguity,
    /// Deopt-replay unsoundness: a store (array, grid, or hash) follows a
    /// prior heap read in the same trace, making the iteration
    /// non-idempotent under coarse side-exit replay — a side-exit after
    /// the store re-runs the whole iteration against the mutated heap and
    /// double-applies (C1 rule, doc 08 §store-sinking). For arrays the
    /// sinking machinery handles this; for appends and grids the recorder
    /// aborts instead.
    store_after_load,
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
    /// Doc 43 §3.1 (P0a): an inlined callee (or anchor-frame) `get_upval` read
    /// an upvalue whose cell is **open over a register the trace can write** —
    /// the cell's `loc.open` slab index falls at or above the anchor frame's
    /// absolute base, i.e. inside the anchor window or an inlined-callee window,
    /// every one of which the trace's φ writeback / body writes mutate. The
    /// per-entry input snapshot (`InputKind.upvalue` / `.callee_upvalue`) is a
    /// COPY, so an on-trace write to that slot leaves the snapshot stale for the
    /// rest of the episode and tier-1a reads the entry value forever (confirmed
    /// miscompile, repro `a01_callee_upval_open.lua`). Fail closed: a closed
    /// cell (or one open over a frame *below* the anchor base — an outer scope
    /// the trace never writes, the common `local cfg` idiom) is unaffected and
    /// keeps recording.
    aliased_input,
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
    /// Doc 43 P5: a `set_upval` targeted a closed cell whose value this same
    /// recording already baked into the per-entry SNAPSHOT (a
    /// `.upvalue`/`.callee_upvalue` seed) — recording is linear, so the read
    /// is already frozen and would go stale the moment the store lands. The
    /// abort MEMOIZES the anchor (`TraceState.upvalue_mutable_memo`): the
    /// gated retry arms with `route_upvalue_reads`, routing scalar closed-cell
    /// reads through per-iteration `uload`s from the start, and the store then
    /// records (the LuaJIT-flavoured penalty/retry answer to doc 43 §8's read-
    /// routing question — read-only loops keep their free snapshot hoist).
    upvalue_mutable,
    /// Doc 44 D12b: a `.cont` (continuation-anchor) recording met a loop
    /// back-edge — at the tier-0 back-edge funnel (`onBackEdge`), or at the
    /// recorder's own link sites (`recForPrepLink` running-loop path,
    /// `recWhileLink` backward jmp). v1 keeps cont shapes
    /// straight-line-to-terminal: loops have their own anchor machinery, so
    /// a continuation that runs into one yields the loop to it, fail-closed.
    cont_backedge,
    /// Doc 45 D2: a NON-precise recording met `new_table` (later: any general
    /// store requiring per-bytecode precision). The candidate is discarded
    /// without a gate strike; the hub memoizes the anchor
    /// (`TraceState.precise_anchor_memo`) and re-arms its deterministic
    /// hotness counter to threshold-saturating-minus-one (the `loop_leave`
    /// fast-retry precedent), so the retry arms at the next back-edge /
    /// call / return event in PRECISE mode (`RecordingSession.precise`) with
    /// the full entry slot_load map from the first instruction. Deterministic
    /// re-recording, never retroactive promotion: no loads or snapshots are
    /// inserted into an already-running candidate.
    needs_precise,
    /// Doc 45 D2: the recording's precise-deopt snapshot demand exceeded a
    /// deterministic admission budget (`trace_snapshot.Budget`: 256 interned
    /// slot vectors / 2000 records / 65536 slots per candidate, checked
    /// BEFORE allocation). Deliberate admission refusal — a full-map body
    /// that churns one slot per bytecode can exhaust vectors long before
    /// `maxrecord`. Ordinary strike semantics: the shape is honestly
    /// uncompilable under the budget, no partial candidate publishes.
    snapshot_limit,
    /// Doc 56 G6-Q1(d), LuaJIT `LJ_TRERR_LUNROLL` (`rec_loop_interp`): a
    /// side or continuation recording went round a loop it could not link
    /// to (no root at its header, a peeled root, an entry-contract mismatch)
    /// more than `Options.loopunroll` times. Without the bound it would grow
    /// to `maxrecord` with one particular trip count baked in. Ordinary
    /// strike semantics; the loop warms its own root meanwhile, and a later
    /// recording links to it.
    loop_unroll,
    /// Doc 61 §7.1 (Phase Q): a collection is about to sweep a heap constant
    /// in the recording's pool (`rec.consts`). The pool is not a root, so the
    /// recording is cancelled (`RecordingSession.cancel`, never `abort`'s
    /// peel rewind) before the sweep frees it. Ordinary strike semantics.
    const_swept,
};
const ExitProvenance = @import("trace_types.zig").ExitProvenance;
const ProgramPoint = @import("trace_types.zig").ProgramPoint;
const ExitKey = @import("trace_types.zig").ExitKey;
const InputSeed = @import("trace_code.zig").InputSeed;
const GuardProvenance = @import("trace_types.zig").GuardProvenance;

/// Doc 58 §4.6: a `while` loop's header is the instruction right after its
/// `loop` marker, so the anchor is plain-`while`-shaped exactly when
/// `code[anchor − 1]` is a marker of kind `while`. Keeps the peel's scope as
/// it was: only `while` loops peel — `repeat` markers and `for` back-edges
/// answer false.
pub fn isPlainWhileAnchor(proto: *const Proto, pc: u32) bool {
    return bytecode.isWhileHeader(proto, pc);
}

/// Result type of a recorded arithmetic op given its observed operands. Mirrors
/// `arith.zig`: `/` and `^` are always float; otherwise int iff both operands are
/// int (matching tier-0's int/float promotion).
pub fn arithResultType(op: IrOp, vb: Value, vc: Value) ObsType {
    if (op == .div or op == .pow) return .float;
    return if (vb.isInt() and vc.isInt()) .int else .float;
}

pub fn obsTypeOf(v: Value) ObsType {
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

/// Doc 47 increment A: check whether all entry guards match the current regs.
/// This mirrors `TraceCode.matchesFingerprint` but operates on the borrowed
/// `entry_guards` slice without needing a full `TraceCode`.
/// `regs` is a `RegWindow` or a `ForEntryView`.
pub fn entryGuardsMatch(guards: []const trace_code.EntryGuard, regs: anytype) bool {
    for (guards) |g| {
        if (g.slot >= regs.len()) return false;
        if (!g.ty.accepts(regs.get(g.slot))) return false;
    }
    return true;
}

/// The registers a loop body's root sees at entry, read at a numeric-`for`
/// hand-off tier-0 has not executed yet (`for_loop`, or `for_prep` plus its
/// first `for_loop`): `regs`, except that the index `R[a]` and the visible
/// variable `R[a+3]` both hold `next`, the value that `for_loop` publishes.
/// `R[a+3]` is write-only there, so its current contents are dead and not
/// program state: doc 61's collector scrubs such a slot to nil, and any
/// other tier may leave it stale.
pub const ForEntryView = struct {
    regs: RegWindow,
    a: usize,
    next: Value,

    pub fn get(self: ForEntryView, slot: usize) Value {
        return if (slot == self.a or slot == self.a + 3) self.next else self.regs.get(slot);
    }

    pub fn len(self: ForEntryView) usize {
        return self.regs.len();
    }
};

/// Doc 47 increment A: check whether every mismatching entry guard is a `.float`
/// guard on a slot currently holding int. Only such mismatches can be resolved
/// by peeling one inner iteration (arithmetic promotes int→float). Any other
/// kind of mismatch (float→int, table mismatch, etc.) is not fixable by peeling.
pub fn entryGuardsMismatchPromotable(guards: []const trace_code.EntryGuard, regs: anytype) bool {
    var has_mismatch = false;
    for (guards) |g| {
        if (g.slot >= regs.len()) return false;
        const v = regs.get(g.slot);
        if (!g.ty.accepts(v)) {
            // Only int→float is fixable by peeling; a primitive pin (doc 57)
            // or any other mismatch is not.
            if (g.ty != .float or !v.isInt()) return false;
            has_mismatch = true;
        }
    }
    return has_mismatch;
}

/// State of a tier-0 register within the recording: `undef` (never touched →
/// next read emits a `slot_load`), `input` (holds a `slot_load` ref — read but
/// not written, loop-invariant), or `def` (holds a computed ref — a loop-carried
/// write that surfaces in the exit snapshot).
pub const SlotState = enum { undef, input, def };

/// Doc 39 Phase 0: the numeric kind a type proof established for a slot's
/// ENTRY value (the `slot_load`), or `.none` when no int/float proof covered
/// it. Stamped centrally by `noteEntryKind` on every proof route (`guardNum`,
/// `guardInt`/`keyRefNarrowed`, bitop guards, lane-implied `guard_fits`) and
/// preserved across every whole-`RegSlot` write (`defineSlotAbs`), so the
/// peel-eligibility sweep can compare "entered int" against "carries float".
pub const EntryKind = enum { none, int, float };

/// The SSA ref currently held by a tier-0 register, with how it got there.
/// `entry_kind` records the proven numeric kind of the slot's entry value
/// (doc 39) — a property of the recording's entry snapshot, so it survives
/// redefinition (`.def`) of the slot.
pub const RegSlot = struct { ref: Ref = 0, state: SlotState = .undef, entry_kind: EntryKind = .none };

/// Doc 39: one anchor-window slot's snapshot at the peel marker (the first
/// anchor-return of a type-unstable plain-while root).
pub const PeelSlot = struct {
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

/// Doc 47 increment A: deferred link close state for continuation-scoped peeling.
/// When a `.continuation`/`.side` recording reaches an inner `for_prep` and the
/// inner root's entry guards mismatch the current register types, the recording
/// continues through the inner body to promote accumulator types before closing
/// `.link`. The two-phase state machine tracks progress:
/// - `.await_initial_entry`: waiting for the first `for_loop` visit (tier-0
///    jumped from `for_prep` to `for_loop`; this is the initial bounds check,
///    not a post-body back-edge). Transition to `.peeling` on continue.
/// - `.peeling`: one body iteration is being recorded. The next `for_loop`
///    continue-direction visit closes `.link` if compatible, else aborts.
/// Why a pending link peel was dropped (`clearPendingLinkClose`'s argument).
pub const LinkPeelEnd = enum {
    /// Types matched after one body iteration: `.link` closes.
    linked,
    /// The inner loop ran no iteration.
    zero_trip,
    /// The body ran once and the loop ended.
    one_trip,
    /// Types still mismatched after one iteration: the recording aborts.
    type_mismatch,
    /// The body aborted: rewind and close `.link` without the peel.
    rewound,
    /// `cancel` (a collection swept one of the recording's constants).
    cancelled,
    /// `reset` armed a new recording over a stale peel.
    reset,
    /// The session was torn down.
    deinit,
};

pub const PendingLinkClose = struct {
    inner_anchor_pc: u32,
    for_loop_pc: u32,
    /// Copy of the inner root's numeric entry guards, owned by the session
    /// and freed through `clearPendingLinkClose`. It is not borrowed from
    /// the inner root's `Trace.code.entry_guards`: a collection between the
    /// peel's instructions can retire that trace (doc 61 §7.1 item 4).
    contract: []const trace_code.EntryGuard,
    phase: Phase,

    // --- Rewind state: saved at peel entry so that a mid-body abort can
    //     truncate back and emit the immediate `.link` close instead. ---
    ir_rewind_len: u32,
    entry_slots_rewind_len: u32,
    for_prep_slot: u16,
    vinit: value.Value,
    vlimit: value.Value,
    vstep: value.Value,
    for_prep_pc: u32,
    saved_proto_id: u32,
    saved_global_seed: bool,
    saved_global_store: bool,
    /// Snapshot of `reg_map[0..anchor_num_registers]` at peel entry.
    /// Allocated with gpa at peel start; freed on rewind or normal close.
    saved_reg_map: []RegSlot,
    /// Doc 56 §4.2: exit-snapshot rewind state. The `for_prep` bytecode's
    /// boundary snapshot is committed BEFORE these are taken, so the
    /// re-emitted close guards (same bytecode, same ordinal) still find it.
    saved_snap_mark: trace_snapshot.Builder.Mark,
    saved_ord: u16,
    saved_ord_overflow: bool,
    saved_snap_exhausted: bool,
    saved_by_ord_len: u32,

    pub const Phase = enum {
        await_initial_entry,
        peeling,
    };
};

/// Doc 39: in-flight type-stabilizing peel. Entered at the first anchor-return
/// of an eligible unstable recording (`maybeEnterPeel`); cleared by `reset`.
pub const PeelState = struct {
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
/// plus the meaningful payload bits. Moved to `trace_ir.zig` (doc 51 Fix B —
/// the optimizer keys its konst canonicalization on the same identity, and
/// tropt must not depend on this module); re-exported so recorder-side call
/// sites and tests keep their spelling.
pub const KonstKey = trace_ir.KonstKey;
pub const konstKey = trace_ir.konstKey;

/// A heap object's identity for the recorder's dedup maps and observed-truth
/// fields, taken when the entry is recorded and never by dereferencing a
/// header later. The address alone is not enough: a collection between
/// recorded instructions can free an object and hand its address to a new one
/// (doc 61 §7.1 item 4). The new object gets a fresh `GcHeader.id`, so the pair
/// differs. The id alone is not enough either: raw test-created objects all
/// carry id 0, and they differ only by address.
pub const ObjIdentity = struct { id: u32, addr: usize };

pub fn objIdentity(h: *const object.GcHeader) ObjIdentity {
    return .{ .id = h.id, .addr = @intFromPtr(h) };
}

/// `konst_map`'s key: the pool identity plus, for a heap constant, its
/// `GcHeader.id` (same reasoning as `ObjIdentity`). The optimizer keeps the
/// plain `konstKey`: tropt runs with no collection inside it.
pub const RecKonstKey = struct { key: KonstKey, id: u32 };

pub fn recKonstKey(v: Value) RecKonstKey {
    return .{ .key = konstKey(v), .id = if (v.isHeap()) v.asHeap().id else 0 };
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
pub const PendingStore = struct {
    aref: Ref,
    value: Ref,
    lane_ord: i32,
    op: IrOp = .astore,
    /// Record-time identity of the stored-to table (doc 51 Fix A): the
    /// observed truth that decides which DIRECTION the alias-disambiguation
    /// guard specializes to. An `ObjIdentity`, captured at store time: the
    /// address alone could be reused by a new table after a collection
    /// between the store and a later load. The id alone would make raw test
    /// tables (all id 0) compare equal. The identity never enters the trace
    /// IR; it only picks between two guard emissions, and that choice is
    /// deterministic because object identity is replay-stable. Null for
    /// non-table stores (`ustore`/`sgm_setpos`), which never reach the
    /// identity arms.
    tab_obj: ?ObjIdentity = null,
    /// Record-time integer index of an `astore` (doc 51 Fix A) — the
    /// observed truth for the loop-varying (`.may`) key arm. Unused for
    /// other store ops.
    key_idx: i64 = 0,
    /// Doc 56 §4.2: the BOUNDARY ORDINAL of the bytecode that deferred this
    /// store (`RecordingSession.cur_ord`), stamped onto the sunk IR store at
    /// `finalize`. Deliberately no default: every deferral site must say
    /// which bytecode the store belongs to, or a resume-coherent exit would
    /// apply it at the wrong program point.
    ord: u16,

    fn storedTo(self: PendingStore, tab: *const object.GcHeader) bool {
        const id = self.tab_obj orelse return false;
        return std.meta.eql(id, objIdentity(tab));
    }
};

pub const AliasClass = enum { must, no, may };
pub const AffineIntKey = struct { base: Ref, offset: i64 };

/// Per-inlined-frame register reservation in the recorder's grown `reg_map`. The
/// map is sized `anchor.num_registers + MAX_INLINE_DEPTH × MAX_CALLEE_REGS`; a
/// callee whose `num_registers` exceeds this reservation (or that would overflow
/// the map at depth) aborts cleanly rather than reading the slab out of bounds.
/// 256 covers every realistic leaf body the compiler emits.
pub const MAX_CALLEE_REGS = 256;

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
/// - `.head`      — a FUNCTION-HEAD root (doc 44): armed by `maybeStartHead`
///                  at a hot callee's pc 0 (anchor pc = `FUNC_HEAD_PC`
///                  sentinel). Root-like in every root-only policy (LINNER,
///                  peel refusal, no `.link` close); closes ONLY via the
///                  one-shot `.terminal` — at a depth-0 `ret`
///                  (return_interp) or a depth-0 direct self-call
///                  (self_call_interp) — never via `.loop`.
/// - `.cont`      — a CONTINUATION-ANCHOR root (doc 44 D12b): armed by
///                  `maybeStartCont` at a hot post-call resume pc (anchor
///                  pc = `CONT_PC_BIT | resume_pc`). Inherits `.head`'s
///                  one-shot close grammar verbatim (depth-0 `ret` →
///                  return_interp; depth-0 direct self-call of the anchor
///                  proto → self_call_interp) and every root-only policy —
///                  stricter on loops: ANY back-edge met while recording
///                  aborts `.cont_backedge` (straight-line-to-terminal v1;
///                  distinct from the legacy `.continuation` loop-exit kind,
///                  which may `.link`).
pub const TraceKind = enum { root, side, continuation, head, cont };

/// Doc 44 D12b: the ONE-SHOT recording family — head + cont share the
/// terminal close grammar and every root-only policy. A behavior class,
/// never an identity equivalence (per-anchor state stays exact-key).
pub inline fn isOneShotKind(kind: TraceKind) bool {
    return kind == .head or kind == .cont;
}

pub const RecordingSession = struct {
    pub const Options = struct {
        maxrecord: usize = 4096,
        peel: bool = true,
        /// Doc 57 P3: `Config.instunroll` (extra source iterations a
        /// pin-defeated close may record before aborting).
        instunroll: u8 = 4,
        /// Doc 56 G6-Q1(d): LuaJIT's `loopunroll` (15) — loop iterations a
        /// side or continuation recording may unroll before `.loop_unroll`.
        loopunroll: u8 = 15,
        optimize: bool = true,
        /// Doc 45 D2: deterministic snapshot admission budgets for PRECISE
        /// recordings. Defaults are the contract values; tests inject smaller
        /// ones to exercise exact-boundary and one-over refusal.
        snapshot_budget: trace_snapshot.Budget = .{},
    };
    /// `upval_open`: for a `get_upval` whose resolved cell is OPEN, its `loc.open`
    /// absolute slab index; null for `get_global`, a closed cell, or any other
    /// op. Supplied per-instruction by the dispatch loop (doc 43 §3.1, P0a) so
    /// `recInputGet` can reject a snapshot that aliases the trace-writable window.
    /// `globals_header`: the VM globals table's `GcHeader` address (doc 43 §3.2,
    /// P0b), so `hashSetShape`/`arraySetShape` can recognise a recorded store into
    /// `_G` and fail closed when the trace also snapshots a `get_global`. Stable
    /// per VM; supplied per-instruction alongside `heap`.
    /// `upval_cell` (doc 43 P5): for a `get_upval`/`set_upval`, the resolved
    /// `*Upvalue` cell (`st.closure.upvalues[instr.b]` — correct at any inline
    /// depth, since tier-0 is really executing the callee); null for other ops.
    /// The recorder keys alias classes and the snapshot-read set on its address
    /// and inspects `loc` for the open/closed split.
    pub const InstructionContext = struct {
        heap: ?*const gc.Heap = null,
        inner_root: bool = false,
        /// Doc 47 increment A: the inner root's entry_guards, resolved once per
        /// `for_prep` instruction by `TraceState.recordInstr`. The slice is
        /// borrowed from the live `Trace.code.entry_guards` (stable while the
        /// trace is cached — no eviction runs during recording). Used by
        /// `recForPrepLink` to decide whether a peel is needed and by
        /// `recForLoop` to verify post-peel compatibility.
        inner_root_guards: []const trace_code.EntryGuard = &.{},
        /// Doc 56 Phase 3: whether that root is PEELED. `recForLoop`'s
        /// enclosing-root `.link` close refuses a peeled root: its entry
        /// guards are its run-once iteration's types (doc 56 review finding 5).
        inner_root_peeled: bool = false,
        unroll_while: bool = false,
        upval_open: ?usize = null,
        globals_header: ?*const object.GcHeader = null,
        upval_cell: ?*function.Upvalue = null,
    };
    pub const AbortNotice = struct { reason: AbortReason, anchor: AnchorKey, kind: TraceKind, unrolled_while: bool, pc: u32, op: OpCode, ir_len: u32, force_ordinary: bool };
    pub const PeelNotice = union(enum) { enter: struct { anchor_pc: u32, marker: usize }, close: struct { anchor_pc: u32, begin: usize, end: usize } };
    pub fn takePeelNotice(self: *RecordingSession) ?PeelNotice {
        const notice = self.peel_notice;
        self.peel_notice = null;
        return notice;
    }
    gpa: std.mem.Allocator = undefined,
    options: Options = .{},
    context: InstructionContext = .{},
    close_requested: bool = false,
    abort_notice: ?AbortNotice = null,
    peel_notice: ?PeelNotice = null,
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
    /// Doc 57 P3 (LuaJIT `instunroll`): extra source iterations this
    /// recording has added to its loop body because a close found a
    /// value-pinned carried slot holding another value. Bounded by
    /// `options.instunroll`; becomes `TraceCode.instunrolled`.
    unroll_used: u8 = 0,
    /// Doc 57 P3: `instrs.len` at the latest unroll decision. A second close
    /// call at the same arrival (`onBackEdge` then `maybeCloseAtAnchor`, the
    /// doc 39 shared-arrival rule) sees the stream unchanged and is ignored.
    unroll_mark_len: usize = 0,
    /// Doc 56 G6-Q1(d) (LuaJIT `loopunroll`): loop iterations this side or
    /// continuation recording has unrolled — `noteLoopIteration`.
    loop_iterations: u8 = 0,
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
    /// The value is the guard INSTRUCTION's index: a peel rewind
    /// (`rewindPeelAndCloseLink`) truncates IR by length, and the guard always
    /// sits at a higher index than the ref it covers — purging on the ref's own
    /// index left refs below the rewind point marked "guarded" with their guard
    /// truncated away, so the re-close silently skipped a required guard and
    /// the committed trace carried an unguarded slot_load (proveKinds then
    /// rejected the whole trace; spectral-norm's loop-done cont was the case).
    guarded_refs: std.AutoHashMapUnmanaged(Ref, u32) = .empty,
    /// Doc 48: record-time table identity per emitted `guard_lane`
    /// (recorder-index keyed; finalization remaps through tropt's compaction
    /// map). Eviction metadata only — an OOM here silently skips the pin,
    /// which can only ever SUPPRESS a widen-eviction, never corrupt output.
    /// Truncated on peel rewind exactly like `guarded_refs` (`guard_ref >=
    /// ir_rewind_len` ⇒ the guard instruction itself was truncated).
    lane_pins: std.ArrayListUnmanaged(trace_code.LanePin) = .empty,
    /// Interns constants: a recurring literal reuses its `konst` instruction's
    /// ref (and pool slot) instead of emitting a fresh one, so identical
    /// subexpressions get identical operand refs and the optimizer's CSE can
    /// merge them. See `TraceState.konst`.
    konst_map: std.AutoHashMapUnmanaged(RecKonstKey, Ref) = .empty,
    /// Current SSA ref + state for each tier-0 register, sized to the recording
    /// frame's `num_registers`.
    reg_map: []RegSlot = &.{},
    /// Nested-loop trace linking (doc 15, Phase 2): when set, this recording is a
    /// *continuation* that re-reached an inner numeric-`for`'s `for_prep` whose loop
    /// header already has a root trace. The value is the inner root's anchor pc (a
    /// bytecode pc in this same proto). `commit()` then closes the trace with a
    /// `.link{aux=link_target}` terminator *instead of* `.loop`, and caches it
    /// unoptimized (link traces skip `tropt`). `null` for every ordinary
    /// root/continuation trace (closes with `.loop`). Reset to `null` by `reset`.
    link_target: ?u32 = null,
    /// Doc 56 Phase 3: the `.link` terminal's `LinkKind` tag (commit writes it
    /// into `link.a`). `.enclosing_iteration` only when the close crossed the
    /// back-edge of a loop containing the anchor (`linkKindAt`). Meaningless
    /// while `link_target == null`; reset alongside it.
    link_kind: trace_ir.LinkKind = .inner_root,
    /// Transport for the `.link` terminal's exit provenance (doc 17, A-i.4 / edge 2):
    /// the `.link` op is synthesized at COMMIT (not at `recForPrepLink`, and link
    /// traces bypass `tropt.optimize`), so `recForPrepLink` stashes the terminal's
    /// `.link_terminal` provenance here and `commit` consumes it when it appends the
    /// `.link`. Release invariant: `link_target != null ⇔ pending_link_provenance !=
    /// null`. Reset to `null` by `reset` (every abort/re-arm) alongside `link_target`.
    pending_link_provenance: ?ExitProvenance = null,
    /// Doc 47 increment A: deferred link close for continuation-scoped peeling.
    /// When a `.continuation`/`.side` recording reaches an inner `for_prep` whose
    /// inner root's entry guards don't match the current register types (e.g. the
    /// inner root wants float on `sum` but the continuation has int), the
    /// recording takes the record-through path instead of immediately closing
    /// `.link`. The recording continues through `for_prep`, the initial `for_loop`
    /// entry, and one inner body iteration — which naturally promotes `sum` from
    /// int to float. At the post-body `for_loop` (phase `.peeling`), compatibility
    /// is rechecked; if the entry guards now match, `.link` is closed with the
    /// promoted state. Set by `recForPrepLink`; consumed by `recForLoop`.
    /// Cleared in `reset()` and `abort()`; asserted null in `finalize()`.
    pending_link_close: ?PendingLinkClose = null,
    /// Link peels set up, and how each one ended, over the session's whole
    /// life (`reset` keeps them). Diagnostics and tests.
    link_peel_setups: u64 = 0,
    link_peel_ends: std.EnumArray(LinkPeelEnd, u64) = .initFill(0),
    /// Doc 44 P0: a `.head` recording's one-shot close. Set by the depth-0
    /// `ret` arm (`.return_interp`) or `recCall`'s depth-0 self-call arm
    /// (`.self_call_interp`) — always BEFORE tier-0 executes that
    /// instruction, so `resume_pc` (the instruction's own pc) is where
    /// tier-0 resumes after a successful terminal exit and executes it
    /// exactly once. `finalize` appends `.terminal{a=kind, aux=resume_pc}`
    /// instead of `.loop`/`.link`, keeps EVERY defined depth-0 register in
    /// the writeback φ rows (a ret/call may read temporaries the dead-φ
    /// filter would drop), and caches the trace unoptimized (the link-trace
    /// precedent). Reset to `null` by `reset`.
    terminal_close: ?struct { kind: trace_ir.TerminalKind, resume_pc: u32 } = null,
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
    /// Doc 43 §3.1 (P0a): the anchor frame's ABSOLUTE slab base index at record
    /// time, captured when the recording is armed (`arm` ← the back-edge's
    /// `st.base`). The trace's writable region is `[anchor_abs_base, …)` — the
    /// anchor window plus every inlined-callee window above it. An open upvalue
    /// cell whose `loc.open` falls in that region aliases a register the trace
    /// writes, so its per-entry snapshot would go stale (`aliased_input` abort).
    /// The absolute base differs per episode (a loop entered at varying call
    /// depth), but the aliasing *relationship* it decides is lexically invariant,
    /// so a record-time verdict generalises. Record-time only; never serialised.
    anchor_abs_base: usize = 0,
    /// Doc 43 §3.2 (P0b): the `_G` snapshot-vs-store coherence flags. A
    /// `get_global` snapshots the globals cell once per entry; a recorded
    /// `hstore`/`astore` into the globals table (reached via a `_G` handle)
    /// mutates that same cell every iteration, staling the snapshot (confirmed
    /// tier-1a AND native miscompile, repro `a02_global_hstore.lua`). Recording
    /// is linear, so either order is caught by remembering both: a global seed
    /// aborts if a globals store was already recorded, and vice-versa. Coarse by
    /// design (any store to the globals table vs any global seed) — a key-level
    /// refinement (only abort on a colliding name) is a documented follow-up
    /// (doc 43 open Q4). Reset per recording.
    recorded_global_seed: bool = false,
    recorded_global_store: bool = false,
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
    /// Dedup for `callee_global` seeds (doc 43 P4): interned name identity →
    /// the seeding `slot_load` ref. Interned strings are VM-deduped, so two
    /// callee protos naming one global share the identity (and the seed).
    callee_global_dedup: std.AutoHashMapUnmanaged(ObjIdentity, Ref) = .empty,
    /// Next synthetic input slab slot to hand out. Initialised to
    /// `anchor_num_registers` in `reset` (inputs live *above* the anchor window);
    /// bumped once per unique input. The slot is only ever a `slot_load` `aux` and
    /// an executor `RegWindow` index — never a `reg_map` index — so it does not
    /// collide with the inlined-callee scratch the `reg_map` tail reserves.
    next_input_slot: u16 = 0,

    // --- closed-cell upvalue stores (doc 43 P5) -----------------------------
    /// Alias classes keyed on the OBSERVED `*Upvalue` cell's identity at record
    /// time (`objIdentity`): aliasing is a property of the physical cell, not
    /// of the `(callee_slot, upvalue_index)` access path — different slots,
    /// closures and indices can reach one shared cell. Value = the class's
    /// `uref` token; two paths resolving to the same cell share it
    /// (MUST-alias), distinct observed cells are distinct classes (NO-alias),
    /// and the entry seeder re-proves the whole relation (verifier seeds).
    upvalue_cell_classes: std.AutoHashMapUnmanaged(ObjIdentity, Ref) = .empty,
    /// Per-class access-path dedup: `(callee_slot_or_anchor_sentinel << 16 |
    /// upvalue_index)` → seen. A path already seeded (as writer or verifier)
    /// appends no further seed.
    upvalue_path_dedup: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Cells whose value was baked into the per-entry SNAPSHOT (a
    /// `.upvalue`/`.callee_upvalue` seed) this recording. A later `set_upval`
    /// to such a cell would leave the baked read stale for the rest of the
    /// episode — abort `.upvalue_mutable`, which memoizes the anchor so the
    /// retry routes its scalar reads through `uload` from the start.
    snapshot_read_cells: std.AutoHashMapUnmanaged(ObjIdentity, void) = .empty,
    /// Doc 43 P5 read routing (the abort-once-and-memo retry): set at arm time
    /// from the anchor's `upvalue_mutable_memo`. When true, SCALAR-observed
    /// closed-cell upvalue reads route through per-iteration `uload`s instead
    /// of the per-entry snapshot, so a later `set_upval` in the same recording
    /// can join the class. Function/table-valued reads always stay snapshots
    /// (they cannot be stored — v1 is scalar-only — and the callee-loading
    /// machinery depends on their `slot_load` shape).
    route_upvalue_reads: bool = false,
    /// Doc 45 D2 deterministic re-recording: set at arm time from the
    /// anchor's `precise_anchor_memo`. When false, the first bytecode that
    /// needs per-instruction deopt precision (`new_table` today) cancels the
    /// candidate with `.needs_precise` — non-penalizing, memoizes the anchor,
    /// re-arms the hotness counter — so the retry records this whole episode
    /// in precise mode from the first instruction. Per-anchor policy, never
    /// a retroactive mid-candidate promotion.
    precise: bool = false,
    /// The owning VM's `Config.debug_log`, stamped by every `start`: the
    /// runtime gate for the recorder's jitdbg probes (`dbg`). Without it a
    /// `-Djit-debug` build prints recorder probes for EVERY VM, and the test
    /// runner then shows that stray stderr on a passing gate.
    debug_log: bool = false,
    /// A1' (doc 45 / task 27): this recording is an ORDINARY PROBE at a
    /// precise-occupied one-shot anchor — the `precise_anchor_memo` seed is
    /// suppressed (arm() leaves `precise` false) and `.needs_precise` aborts
    /// take a normal gate strike instead of the cancel-and-retry path (the
    /// abort consumer reads this off the AbortNotice). The probe commits
    /// only when recording lands on a construction-free path (e.g. the
    /// recursive-descent side of a body whose leaf side allocates), giving
    /// the anchor a native-runnable ordinary sibling next to its precise
    /// incumbent.
    force_ordinary: bool = false,
    /// Doc 45 D2 capture state (precise recordings only). `snap_builder` is
    /// the allocator-injected reusable accumulator (reset between recordings,
    /// no per-iteration allocation); `snap_scratch` is the bounded full-window
    /// vector buffer `recordInstr` rebuilds at each guest-bytecode boundary;
    /// `cur_snap` is the one-based index of the CURRENT bytecode's snapshot,
    /// stamped by `emit` onto every body op (0 during the entry prologue =
    /// entry-replay semantics for pre-body failures).
    snap_builder: trace_snapshot.Builder = undefined,
    snap_builder_init: bool = false,
    snap_scratch: []trace_snapshot.SnapshotSlot = &.{},
    cur_snap: trace_ir.SnapIdx = 0,
    /// Doc 45 D2: whether the precise entry prologue (full slot_load map +
    /// eager guard_gc) has been emitted yet this recording. Deferred to the
    /// first body `recordInstr`; cleared in `reset`.
    precise_prologue_done: bool = false,
    /// Doc 56 §4.2 (ORDINARY recordings): the current guest bytecode's
    /// boundary ordinal — one-based, bumped once per `recordInstr`; 0 before
    /// the first body bytecode (arm-time ops). `emit` stamps it on every op
    /// and every deferral stamps it on its `PendingStore`, so guards and sunk
    /// stores share one program-order coordinate that survives `tropt`.
    /// Precise recordings leave it 0 (they carry full per-bytecode snapshots).
    cur_ord: u16 = 0,
    /// The ordinal space saturated (> 65535 bytecodes): later bytecodes get
    /// no ordinal and `finalize` drops every exit snapshot (fail closed —
    /// the exits stay anchor-coherent, never attachable).
    exit_ord_overflow: bool = false,
    /// The current bytecode opened an eligible boundary (resume pc
    /// `exit_resume_pc`) whose snapshot is not committed yet. It is built
    /// and committed at the bytecode's first side-exit guard, so bytecodes
    /// that cannot exit cost no snapshot at all (LuaJIT likewise snapshots
    /// only where a guard needs one).
    exit_snap_pending: bool = false,
    exit_resume_pc: u32 = 0,
    /// Lazy capture's undo state, one entry per anchor-window slot: when
    /// `exit_undo_stamp[slot] == exit_seq`, the CURRENT bytecode rebound the
    /// slot while its snapshot was pending and `exit_undo_prev[slot]` is the
    /// binding it had at the boundary (saved on the first write only). The
    /// commit reads `reg_map` through it, so the snapshot is exactly the
    /// boundary state even when the bytecode writes a slot before its first
    /// guard. `exit_seq` bumps per boundary and never rewinds (a peel rewind
    /// cannot resurrect stale stamps); the stamps are cleared per recording.
    exit_undo_prev: []RegSlot = &.{},
    exit_undo_stamp: []u32 = &.{},
    exit_seq: u32 = 0,
    /// Bit `s` set ⇔ anchor-window slot `s` is `.def` in `reg_map` (slots
    /// only ever become `.def` during a recording, except a peel rewind,
    /// which recomputes it). ANDed with the resume pc's liveness row, it
    /// makes a commit O(words + captured slots) instead of O(registers) —
    /// a 60k-register proto would otherwise scan its whole window per
    /// guarded bytecode (Rule #20).
    exit_def_bits: []u64 = &.{},
    /// The snapshot budget refused a commit: every LATER boundary of this
    /// recording skips capture entirely (its exits stay non-attachable), so
    /// a budget-exhausted recording stops paying O(registers) per guarded
    /// bytecode for vectors the builder would refuse anyway.
    exit_snap_exhausted: bool = false,
    /// ordinal → one-based exit snapshot index into `snap_builder` (0 = the
    /// bytecode has no snapshot: it emitted no side-exit guard, ran inside an
    /// inlined frame, or hit the snapshot budget). Index 0 is the "no
    /// ordinal" entry and is always 0.
    exit_snap_by_ord: std.ArrayListUnmanaged(trace_ir.SnapIdx) = .empty,

    /// A jitdbg probe line, behind both gates: compiled in only with
    /// `-Djit-debug`, printed only when this VM set `Config.debug_log`.
    pub inline fn dbg(self: *const RecordingSession, comptime fmt: []const u8, args: anytype) void {
        if (comptime jitdbg.enabled) {
            if (self.debug_log) jitdbg.log(fmt, args);
        }
    }

    pub fn abort(self: *RecordingSession, reason: AbortReason) void {
        if (!self.active) return;
        if (reason == .bad_type or reason == .store_fwd_ambiguity or reason == .store_after_load)
            self.dbg("ABORT {s}: pc={d} op={d} ir_len={d} ret={x}", .{ @tagName(reason), self.cur_pc, @intFromEnum(self.cur_op), self.instrs.items.len, @returnAddress() });
        // Doc 47 increment A fallback: if a peel is in flight and the body
        // recording aborts (aliased_input, nyi_opcode, etc.), don't kill the
        // recording — rewind the IR to the pre-peel state and close `.link`
        // immediately (the path that would have run without the peel attempt).
        if (self.pending_link_close != null) {
            self.rewindPeelAndCloseLink();
            return;
        }
        self.abort_notice = .{ .reason = reason, .anchor = self.anchor, .kind = self.kind, .unrolled_while = self.unrolled_while, .pc = self.cur_pc, .op = self.cur_op, .ir_len = @intCast(self.instrs.items.len), .force_ordinary = self.force_ordinary };
        self.abort_reason = reason;
        self.active = false;
        self.multret_top = null;
        self.side_src = null;
        self.close_requested = false;
    }
    /// Doc 47 increment A fallback: the link peel attempted to record through
    /// the inner body but hit an abort (aliased_input on get_upval, nyi_opcode
    /// on a call, etc.). Instead of killing the whole continuation recording,
    /// rewind the IR to the pre-peel state and emit the immediate `.link`
    /// close that would have fired without the peel attempt. This preserves
    /// loopdone link fusion for patterns like spectral-norm where the peel
    /// can't complete (body contains upvalue loads / calls that abort).
    fn rewindPeelAndCloseLink(self: *RecordingSession) void {
        const plc = self.pending_link_close orelse return;
        const a = plc.for_prep_slot;

        // --- Rewind IR and register state to the pre-peel snapshot ---
        self.instrs.items.len = plc.ir_rewind_len;
        self.exit_prov.items.len = plc.ir_rewind_len;
        self.entry_slots.items.len = plc.entry_slots_rewind_len;
        // Restore the full reg_map to its pre-peel state. Body recording
        // may have modified arbitrary slots (slot_load, setReg from arith,
        // etc.); those refs now point into the truncated range and would
        // produce garbage in the exit snapshot if left.
        @memcpy(self.reg_map[0..plc.saved_reg_map.len], plc.saved_reg_map);
        // Restore side-effect flags that body recording may have set.
        self.recorded_global_seed = plc.saved_global_seed;
        self.recorded_global_store = plc.saved_global_store;
        // Doc 56 §4.2: drop the truncated bytecodes' exit snapshots and
        // ordinals. The re-emitted close below belongs to the `for_prep`
        // bytecode again (same ordinal), whose snapshot was committed before
        // the mark was taken.
        if (self.snap_builder_init) self.snap_builder.truncate(plc.saved_snap_mark);
        self.exit_snap_by_ord.items.len = plc.saved_by_ord_len;
        self.cur_ord = plc.saved_ord;
        self.exit_ord_overflow = plc.saved_ord_overflow;
        // The restored `reg_map` may have un-defined slots the peel defined.
        if (self.exit_def_bits.len != 0 and self.cur_ord != 0) self.recomputeExitDefBits();
        self.exit_snap_exhausted = plc.saved_snap_exhausted;
        self.exit_snap_pending = false;
        // Purge any guarded_refs whose GUARD instruction was truncated. The
        // map value is the guard's own index — never the guarded ref's, which
        // is always lower: a ref below the rewind point whose guard sat above
        // it must lose its "guarded" mark, or the re-close below would
        // silently skip a required guard (an unguarded slot_load then made
        // proveKinds reject the committed trace — spectral's loop-done cont).
        // Restart the scan after each removal (iterator invalidation); the
        // set is small and rewinds are rare, so O(n·removals) is fine — and
        // unlike the old fixed 64-slot scratch, nothing stale can survive.
        outer: while (true) {
            var it = self.guarded_refs.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* >= plc.ir_rewind_len) {
                    _ = self.guarded_refs.remove(entry.key_ptr.*);
                    continue :outer;
                }
            }
            break;
        }
        // Doc 48: drop lane pins whose guard_lane was truncated (same
        // staleness class; the pin indexes the guard instruction itself).
        var np: usize = 0;
        for (self.lane_pins.items) |pin| {
            if (pin.guard_ref < plc.ir_rewind_len) {
                self.lane_pins.items[np] = pin;
                np += 1;
            }
        }
        self.lane_pins.items.len = np;
        self.clearPendingLinkClose(.rewound);

        // --- Re-emit the immediate `.link` close (same logic as the
        //     non-peel path in recForPrepLink lines 3062-3124). ---
        const vinit = plc.vinit;
        const vlimit = plc.vlimit;
        const vstep = plc.vstep;
        const rinit = self.refOf(a) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        const rlimit = self.refOf(a + 1) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        const rstep = self.refOf(a + 2) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        self.guardNum(rinit, vinit, .operand_type, .a) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        self.guardNum(rlimit, vlimit, .operand_type, .a1) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        self.guardNum(rstep, vstep, .operand_type, .a2) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        const all_int = vinit.isInt() and vstep.isInt();
        const vpre = arith.sub(vinit, vstep) catch {
            self.realAbort(.bad_type);
            return;
        };
        const rpre = self.emit(.{ .op = .sub, .a = rinit, .b = rstep, .ty = arithResultType(.sub, vinit, vstep) }) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        const rfirst = self.emit(.{ .op = .add, .a = rpre, .b = rstep, .ty = arithResultType(.add, vpre, vstep) }) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null) blk: {
            const iof = self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int }) catch {
                self.realAbort(.nyi_opcode);
                return;
            };
            self.stampProv(iof, .limit_int, .a1, .neutral);
            break :blk iof;
        } else rlimit;
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            self.emit(.{ .op = .le, .a = rfirst, .b = rlimit_cmp, .ty = .boolean }) catch {
                self.realAbort(.nyi_opcode);
                return;
            }
        else
            self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rfirst, .ty = .boolean }) catch {
                self.realAbort(.nyi_opcode);
                return;
            };
        const guard_ref = self.emit(.{ .op = .guard_true, .a = cmp }) catch {
            self.realAbort(.nyi_opcode);
            return;
        };
        self.stampProv(guard_ref, .loop_done, .none, .neutral);
        self.setReg(a, rfirst);
        self.setReg(a + 3, rfirst);
        self.link_target = plc.inner_anchor_pc;
        self.pending_link_provenance = .{ .link_terminal = .{
            .path = pathFromFrames(&self.frames, self.inline_depth),
            .inline_depth = self.inline_depth,
            .source_proto_id = plc.saved_proto_id,
            .source_pc = plc.for_prep_pc -| 1,
        } };
        self.close_requested = true;
    }

    /// The single release point for `pending_link_close` and the two
    /// buffers it owns (the rewind `saved_reg_map` and the `contract` copy).
    /// Every path that drops a pending peel comes through here.
    fn clearPendingLinkClose(self: *RecordingSession, end: LinkPeelEnd) void {
        const plc = self.pending_link_close orelse return;
        self.gpa.free(plc.saved_reg_map);
        self.gpa.free(plc.contract);
        self.pending_link_close = null;
        self.link_peel_ends.getPtr(end).* +|= 1;
        self.dbg("link-peel end: {s} inner pc={d}", .{ @tagName(end), plc.inner_anchor_pc });
    }

    /// Kill the recording unconditionally, with no peel-rewind fallback.
    /// `abort` can turn an in-flight peel into a `.link` close that keeps the
    /// pool. A collection about to sweep one of the recording's constants
    /// (doc 61 §7.1 item 2) must not let that happen.
    pub fn cancel(self: *RecordingSession, reason: AbortReason) void {
        if (!self.active) return;
        self.clearPendingLinkClose(.cancelled);
        self.realAbort(reason);
    }

    /// The real abort — unconditionally kills the recording. Called when
    /// `rewindPeelAndCloseLink` itself fails (OOM on emit, etc.).
    fn realAbort(self: *RecordingSession, reason: AbortReason) void {
        self.abort_notice = .{ .reason = reason, .anchor = self.anchor, .kind = self.kind, .unrolled_while = self.unrolled_while, .pc = self.cur_pc, .op = self.cur_op, .ir_len = @intCast(self.instrs.items.len), .force_ordinary = self.force_ordinary };
        self.abort_reason = reason;
        self.active = false;
        self.multret_top = null;
        self.side_src = null;
        self.close_requested = false;
    }

    pub fn takeAbortNotice(self: *RecordingSession) ?AbortNotice {
        const notice = self.abort_notice;
        self.abort_notice = null;
        return notice;
    }
    pub fn close(self: *RecordingSession, regs: RegWindow) bool {
        if (!self.active) return false;
        self.close_requested = false;
        // Doc 44: a terminal (one-shot head) close has no back-edge — no peel
        // machinery, no loop-close fingerprint check. `finalize` appends the
        // `.terminal` and the full writeback rows.
        if (self.terminal_close != null) return true;
        // Doc 57 P3: the second close call of the arrival that just decided
        // to unroll (nothing was recorded in between).
        if (self.unroll_used != 0 and self.link_target == null and
            self.instrs.items.len == self.unroll_mark_len) return false;
        if (self.peel) |*p| {
            if (self.instrs.items.len == p.mark_len) return false; // same arrival
            if (!self.finishPeel(p)) {
                self.abort(.type_instability);
                return false;
            }
        } else if (self.unroll_used == 0 and self.maybeEnterPeel(regs)) {
            // (Never once unrolled: the peel's prefix would swallow the
            // unrolled iterations, and each mode owns the back-edge.)
            return false; // peel entered (keep recording iteration 2) or aborted
        }
        // Doc 40 Phase 1: refuse a self-defeating `.loop` close (entry
        // fingerprint contradicts a carried φ's numeric kind) for EVERY
        // recording kind — root, side, continuation — the glue channels are
        // precisely where the reset-to-int shape records (codex finding 1).
        // Peeled closes are legitimately entry≠steady by design; `.link`
        // closes carry no back-edge.
        if (self.peel == null and self.link_target == null) {
            switch (self.loopCloseDefeat(regs)) {
                .none => {},
                // Doc 57 P3 (LuaJIT `lj_opt_loop` TYPEINS/GFAIL → keep
                // recording): only value pins are contradicted, so another
                // iteration may bring every carried value back to its pin.
                .pins => {
                    if (self.enterUnroll()) return false;
                    self.abort(.type_instability);
                    return false;
                },
                // An int/float contradiction: another iteration cannot fix it
                // (a float stays a float); that is doc 39's peel territory.
                .numeric => {
                    self.abort(.type_instability);
                    return false;
                },
            }
        }
        return true;
    }

    /// Doc 57 P3: keep recording one more source iteration as more loop body
    /// instead of aborting a pin-defeated close. Returns false (the caller
    /// aborts, as before P3) when the budget is spent or the recording has a
    /// shape whose back-edge another mechanism owns.
    fn enterUnroll(self: *RecordingSession) bool {
        if (self.unroll_used >= self.options.instunroll) return false;
        // Doc 45 D3 precedent (the peel is refused too): a precise recording
        // keeps its one-iteration snapshot contract.
        if (self.precise) return false;
        if (self.inline_depth != 0) return false;
        if (self.pending_link_close != null) return false;
        // A numeric `for` arrives through its own `for_loop`, whose continue
        // test `recForLoop` just stamped `.loop_done`. It now sits mid-trip:
        // re-mark it so no loop-done classifier takes it (`isLoopTestCopy`).
        // (A `while` copy is marked where it is emitted, in `recBranch`.)
        if (self.cur_op == .for_loop) self.markForLoopTestCopy(self.cur_pc -| 1);
        self.unroll_used += 1;
        self.unroll_mark_len = self.instrs.items.len;
        self.dbg("unroll: anchor pc={d} iteration={d} ir={d}", .{ self.anchor.pc, @as(u32, self.unroll_used) + 1, self.instrs.items.len });
        return true;
    }

    /// Doc 57 P3: re-mark the anchor-frame `.loop_done` guard that the
    /// `for_loop` at `for_pc` emitted on this arrival as a mid-trip copy.
    /// Scans back from the stream end (the guard is among the last few
    /// instructions) and stops at the first match.
    fn markForLoopTestCopy(self: *RecordingSession, for_pc: u32) void {
        var i = self.instrs.items.len;
        while (i > 0) {
            i -= 1;
            if (self.instrs.items[i].op != .guard_true) continue;
            if (self.exit_prov.items[i]) |*prov| switch (prov.*) {
                .guard => |*gp| {
                    if (gp.role != .loop_done or gp.inline_depth != 0) continue;
                    if (gp.source_proto_id != self.anchor.proto.id or gp.source_pc != for_pc) continue;
                    gp.role = .loop_test_copy;
                    return;
                },
                .link_terminal => {},
            };
        }
    }
    pub fn finalize(self: *RecordingSession) !@import("trace_candidate.zig").RecordingCandidate {
        if (!self.active) return error.InactiveRecording;
        // Doc 47 increment A: a pending link peel must be consumed (closed into
        // link_target) or cancelled (abort/reset) before finalization. Reaching
        // finalize with the peel still live means the recording was committed
        // without completing the peel — a state machine error.
        std.debug.assert(self.pending_link_close == null);
        defer {
            self.active = false;
            self.side_src = null;
            self.multret_top = null;
        }
        return @import("trace_finalize.zig").finalize(self.gpa, self, .{ .optimize = self.options.optimize });
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
    pub fn recordInstr(self: *RecordingSession, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) void {
        if (!self.active) return;
        if (self.instrs.items.len >= self.options.maxrecord) return self.abort(.too_long);
        self.cur_pc = pc;
        self.cur_op = instr.op;
        self.cur_proto_id = proto.id; // leaf proto for GuardProvenance (A-i.3)
        // A-ii.3: capture the recorded program-point for region membership. Fail-soft
        // — an OOM here marks membership unavailable and continues; it must NEVER
        // abort the trace (that would change trace selection → non-byte-identical).
        if (self.rec_path_ok) {
            self.rec_path.append(self.gpa, .{ .proto_id = proto.id, .source_pc = pc -| 1 }) catch {
                self.rec_path_ok = false;
            };
        }
        // Doc 45 D2: a PRECISE recording emits its full entry slot_load map +
        // eager `guard_gc` prologue at its FIRST body instruction (deferred
        // from `arm`, whose eager emit would defeat `maybeCloseAtAnchor`'s
        // empty-body guard), then opens every guest bytecode with a full-window
        // snapshot built BEFORE the bytecode's IR — it holds the state after
        // the last COMPLETED instruction, so a failing body op resumes at this
        // pc with those values. Budget overflow is deterministic admission
        // refusal (`.snapshot_limit`), never a partial candidate.
        if (self.precise) {
            if (!self.precise_prologue_done) {
                self.beginPreciseInner() catch return self.abort(.alloc);
                self.precise_prologue_done = true;
            }
            self.snapBoundary(pc) catch |e| switch (e) {
                error.SnapshotLimit => return self.abort(.snapshot_limit),
                error.OutOfMemory => return self.abort(.alloc),
            };
        } else {
            self.exitBoundary(proto, pc) catch return self.abort(.alloc);
        }
        self.recordOne(instr, regs, proto, pc, resolved) catch self.abort(.alloc);
    }

    /// Size the reusable snapshot builder + scratch for this recording (Z-4:
    /// reset between recordings, no per-iteration allocation). The budget is
    /// re-read per recording so tests can inject a smaller one. Shared by the
    /// precise prologue (doc 45) and the ordinary exit-snapshot capture
    /// (doc 56) — a recording is one or the other, never both.
    fn prepareSnapBuilder(self: *RecordingSession) std.mem.Allocator.Error!void {
        if (!self.snap_builder_init) {
            self.snap_builder = trace_snapshot.Builder.init(self.gpa, self.options.snapshot_budget);
            self.snap_builder_init = true;
        } else {
            self.snap_builder.budget = self.options.snapshot_budget;
            self.snap_builder.reset();
        }
        const n: usize = self.anchor_num_registers;
        if (self.snap_scratch.len != n) {
            const replacement = try self.gpa.alloc(trace_snapshot.SnapshotSlot, n);
            if (self.snap_scratch.len != 0) self.gpa.free(self.snap_scratch);
            self.snap_scratch = replacement;
        }
    }

    /// Doc 56 §4.2: open an ORDINARY recording's guest-bytecode boundary —
    /// bump the ordinal and, when the boundary is eligible, mark its
    /// snapshot pending. O(1): nothing is copied here. The snapshot is built
    /// only if the bytecode reaches a side-exit guard (`commitExitSnap`),
    /// from `reg_map` read through the undo log that `noteSlotWrite` fills
    /// if the bytecode rebinds a slot first. A boundary is eligible only in
    /// the anchor proto's own frame (exits inside an inlined frame are
    /// deferred until frame reconstruction exists, doc 56 "Defer") and with
    /// a liveness table (unknown liveness must never pin every slot).
    fn exitBoundary(self: *RecordingSession, proto: *const Proto, pc: u32) std.mem.Allocator.Error!void {
        self.exit_snap_pending = false;
        if (self.exit_ord_overflow) return;
        if (self.cur_ord == std.math.maxInt(u16)) {
            self.exit_ord_overflow = true;
            return;
        }
        if (self.cur_ord == 0) {
            try self.prepareSnapBuilder();
            try self.prepareExitCapture();
            try self.exit_snap_by_ord.append(self.gpa, 0); // ordinal 0: "none"
        }
        self.cur_ord += 1;
        try self.exit_snap_by_ord.append(self.gpa, 0);
        if (self.inline_depth != 0 or self.exit_snap_exhausted) return;
        // `pc` is post-increment; 0 names no bytecode (synthetic recorder
        // drives in unit tests), so there is no resume point to snapshot —
        // the bytecode's exits simply stay non-attachable.
        if (pc == 0) return;
        if (proto != self.anchor.proto or self.base_off != 0) return;
        // The liveness row must cover the whole anchor window (it always
        // does in production: the window IS `proto.num_registers`).
        if (self.anchor_num_registers != proto.num_registers) return;
        if (!proto.reg_live.available() or pc - 1 >= proto.code.len) return;
        self.exit_resume_pc = pc - 1; // resume at the CURRENT bytecode
        self.exit_seq +%= 1;
        if (self.exit_seq == 0) {
            // Wrapped (after 2^32 boundaries): restart the stamp space.
            @memset(self.exit_undo_stamp, 0);
            self.exit_seq = 1;
        }
        self.exit_snap_pending = true;
    }

    /// Size and clear the lazy capture's per-slot stamps for this recording
    /// (Z-4: reused across recordings; O(registers) once per recording).
    fn prepareExitCapture(self: *RecordingSession) std.mem.Allocator.Error!void {
        const n: usize = self.anchor_num_registers;
        if (self.exit_undo_stamp.len != n) {
            const stamps = try self.gpa.alloc(u32, n);
            errdefer self.gpa.free(stamps);
            const prevs = try self.gpa.alloc(RegSlot, n);
            errdefer self.gpa.free(prevs);
            const defs = try self.gpa.alloc(u64, (n + 63) / 64);
            if (self.exit_undo_stamp.len != 0) self.gpa.free(self.exit_undo_stamp);
            if (self.exit_undo_prev.len != 0) self.gpa.free(self.exit_undo_prev);
            if (self.exit_def_bits.len != 0) self.gpa.free(self.exit_def_bits);
            self.exit_undo_stamp = stamps;
            self.exit_undo_prev = prevs;
            self.exit_def_bits = defs;
        }
        @memset(self.exit_undo_stamp, 0);
        self.exit_seq = 0;
        self.recomputeExitDefBits();
    }

    /// Rebuild `exit_def_bits` from `reg_map` (once per recording, and after
    /// a peel rewind restores `reg_map`). O(registers).
    fn recomputeExitDefBits(self: *RecordingSession) void {
        @memset(self.exit_def_bits, 0);
        for (self.reg_map[0..self.exit_undo_stamp.len], 0..) |s, slot| {
            if (s.state == .def) self.exit_def_bits[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
        }
    }

    /// Doc 56 §4.2: the current bytecode is about to rebind anchor-window
    /// slot `abs`. While its boundary snapshot is pending, save the slot's
    /// boundary binding (first write per slot only) so the lazy commit still
    /// sees the state before this bytecode. O(1), no allocation.
    fn noteSlotWrite(self: *RecordingSession, abs: usize) void {
        // The capture state is (re)built at this recording's first boundary
        // (`prepareExitCapture` recomputes the def bits from `reg_map`), so
        // before it — and for inlined-callee slots — there is nothing to do.
        if (self.cur_ord == 0 or abs >= self.exit_undo_stamp.len) return;
        self.exit_def_bits[abs / 64] |= @as(u64, 1) << @intCast(abs % 64);
        if (!self.exit_snap_pending) return;
        if (self.exit_undo_stamp[abs] == self.exit_seq) return;
        self.exit_undo_stamp[abs] = self.exit_seq;
        self.exit_undo_prev[abs] = self.reg_map[abs];
    }

    /// Doc 56 §4.2: build and commit the current bytecode's boundary
    /// snapshot (idempotent; no-op when nothing is pending): the `.def`
    /// anchor-window slots at the boundary that tier-0 may still READ from
    /// the resume pc (`Proto.reg_live`, the `snap_usedef` analogue).
    /// `.undef`/`.input` slots are still coherent in the slab; dead `.def`
    /// slots are left stale on purpose — a snapshot ref is a `tropt`
    /// liveness root, so capturing a dead local would cost DCE in every
    /// trace. O(registers) per committed snapshot, as LuaJIT's
    /// `snapshot_slots`. The snapshot budget is fail-soft: over it, this and
    /// later exits simply have no snapshot and stay non-attachable — never
    /// an abort (doc 56 §4.2 "Budgets").
    fn commitExitSnap(self: *RecordingSession) std.mem.Allocator.Error!void {
        if (!self.exit_snap_pending) return;
        self.exit_snap_pending = false;
        const rpc = self.exit_resume_pc;
        const n = self.anchor_num_registers;
        // Doc 61 §5 (site 3): only a maskable proto may leave dead slots
        // stale, since only its frames are masked by the collector. Any
        // other proto records every `.def` slot.
        const proto = self.anchor.proto;
        const live_row: ?[]const u64 = if (proto.maskable) proto.reg_live.row(rpc) else null;
        // Candidates: slots `.def` NOW and live at the resume pc, ascending.
        // A slot this bytecode rebound reads its saved BOUNDARY binding; one
        // that was not `.def` at the boundary is skipped (writes only ever
        // make a slot `.def`, so every boundary-`.def` slot is `.def` now).
        var len: u16 = 0;
        for (self.exit_def_bits, 0..) |d, wi| {
            var m = d & if (live_row) |row| row[wi] else ~@as(u64, 0);
            while (m != 0) : (m &= m - 1) {
                const slot: usize = wi * 64 + @ctz(m);
                const s = if (self.exit_undo_stamp[slot] == self.exit_seq) self.exit_undo_prev[slot] else self.reg_map[slot];
                if (s.state != .def) continue;
                self.snap_scratch[len] = .{ .slot = @intCast(slot), .ref = s.ref };
                len += 1;
            }
        }
        const idx = self.snap_builder.addSparse(rpc, n, self.snap_scratch[0..len]) catch |e| switch (e) {
            error.SnapshotLimit => {
                self.exit_snap_exhausted = true;
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        self.exit_snap_by_ord.items[self.cur_ord] = idx;
    }

    /// Doc 45 D2: emit a PRECISE recording's entry prologue — force the full
    /// entry `slot_load` map (every anchor-window register, ascending) so
    /// unwritten slots keep a ref to their ORIGINAL entry values in every later
    /// snapshot; then emit the eager `guard_gc` (doc 45 D4: after the entry-load
    /// block, before ALL effects — `aux` stays 0 for a nonallocating body;
    /// finalize stamps the real bound). Run lazily at the FIRST body
    /// `recordInstr` (not at `arm` — an eager emit would make
    /// `maybeCloseAtAnchor` close an empty-body trace). Everything emitted here
    /// carries `snap == 0`: prologue/seed failures remain pre-body ENTRY
    /// failures, not mid-body deopts.
    fn beginPreciseInner(self: *RecordingSession) !void {
        try self.prepareSnapBuilder();
        var slot: u16 = 0;
        while (slot < self.anchor_num_registers) : (slot += 1) _ = try self.refOf(slot);
        self.guard_gc_ref = try self.emit(.{ .op = .guard_gc });
    }

    /// Build the current guest bytecode's full-window snapshot (doc 45 D2):
    /// every anchor-window register exactly once, ascending; unwritten slots
    /// reference their entry `slot_load` (forced by `beginPrecise`). `pc` is
    /// the post-increment dispatch pc — the snapshot resumes at the CURRENT
    /// instruction (`pc - 1`), never at a branch target.
    fn snapBoundary(self: *RecordingSession, pc: u32) trace_snapshot.Error!void {
        // Precise mode refuses inlining, so recording is always in the anchor
        // frame and `reg_map[0..anchor_num_registers]` IS the activation.
        std.debug.assert(self.base_off == 0);
        const n: u16 = @intCast(self.anchor_num_registers);
        for (self.snap_scratch[0..n], 0..) |*out, slot| {
            const s = self.reg_map[slot];
            std.debug.assert(s.state != .undef); // beginPrecise loaded every slot
            out.* = .{ .slot = @intCast(slot), .ref = s.ref };
        }
        self.cur_snap = try self.snap_builder.add(pc - 1, n, self.snap_scratch[0..n]);
    }

    pub fn recordOne(self: *RecordingSession, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) error{OutOfMemory}!void {
        // Doc 27: the multret shadow is visible to exactly one instruction — the
        // designated consumer immediately after its producer, mirroring tier-0's
        // `reg_top_pending` scope. Stash and clear before dispatch; only the
        // consumer arms (`recCall`/`recBuiltin`/`recReturn`) receive the stash,
        // and only producer arms re-set the field (on success).
        const multret = self.multret_top;
        self.multret_top = null;
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
            .not => try self.recNot(instr, regs),
            .bnot => try self.recBnot(instr, regs),

            // comparisons (gt/ge normalise to lt/le with swapped operands).
            .eq => try self.recEq(.eq, instr, regs),
            .ne => try self.recEq(.ne, instr, regs),
            .lt => try self.recCompare(.lt, false, instr, regs),
            .le => try self.recCompare(.le, false, instr, regs),
            .gt => try self.recCompare(.lt, true, instr, regs),
            .ge => try self.recCompare(.le, true, instr, regs),

            // control flow.
            // Doc 58: a `jmp` records nothing. Every jump is now straight-line
            // control flow in the trace — the two backward ones are loop
            // closers, and the loop's iteration is owned by its marker below
            // (LuaJIT's `BC_JMP`, which only shrinks `maxslot`).
            .jmp => {},
            // Doc 58: the loop marker is where a nested `while`/`repeat` is
            // entered, so it carries the linking decision the backward `jmp`
            // used to (LuaJIT `rec_loop_jit` on `JLOOP` / `rec_loop_interp` on
            // `LOOP`): link to the inner root at its header, unroll it, or
            // abort LINNER. Otherwise it records nothing.
            .loop => try self.recLoopLink(instr, regs, proto, pc),
            .jmp_if_false, .jmp_if_true => try self.recBranch(instr, regs, proto, pc),
            .for_loop => try self.recForLoop(instr, regs, pc),
            // Doc 30 c4: the generic-for back-edge — mirrors the CONTINUE
            // direction (first loop var non-nil → publish it as ctrl).
            .tfor_loop => try self.recTForLoop(instr, regs, pc),
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
            .ret => if (self.inline_depth == 0)
                // Depth-0 return. A one-shot recording (`.head`/`.cont`,
                // doc 44) CLOSES here — the one-shot terminal, set before
                // tier-0 executes the ret — unless the ret window is dynamic
                // (`b == all_results` reads `multret_top`, which trace
                // execution never sets: refused, codex round-1 change 4). A
                // loop root still aborts (LLEAVE): it must not leave the loop.
                (if (isOneShotKind(self.kind))
                    (if (instr.b == bytecode.all_results)
                        self.abort(.nyi_opcode)
                    else
                        self.closeHeadTerminal(.return_interp))
                else
                    self.abort(.cross_frame))
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
            else blk: {
                self.dbg("bad_type get_index dispatch: isInt={} isFloat={} isNil={} isHeap={} pc={d}", .{ regs.get(instr.c).isInt(), regs.get(instr.c).isFloat(), regs.get(instr.c).isNil(), regs.get(instr.c).isHeap(), self.cur_pc });
                break :blk self.abort(.bad_type);
            },

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
            // function — pin its identity with `guard_func`. `set_global` stays an
            // abort (not in this switch): a write in the traced region would make
            // the snapshot stale, so such loops keep running on tier-0.
            // `set_upval` records since doc 43 P5 (closed cells, scalar values)
            // — see `recSetUpval`; the snapshot-staleness concern is enforced by
            // `snapshot_read_cells` + the `.upvalue_mutable` memo/retry.
            .get_upval => try self.recInputGet(.upvalue, instr.a, instr.b, resolved, proto),
            .get_global => try self.recInputGet(.global, instr.a, instr.b, resolved, proto),
            // Doc 43 P5: a write through a CLOSED upvalue cell records as
            // `uref`/`ustore` (scalar values only in v1); everything else —
            // open cells, heap values, snapshot-staled reads — aborts, and the
            // `.upvalue_mutable` abort memoizes the anchor so the retry routes
            // its reads through `uload` and the store can record.
            .set_upval => try self.recSetUpval(instr, regs),

            // Doc 45 D2: table construction needs per-bytecode precise deopt
            // to record (the constructed table is visible mid-episode, so
            // entry replay would double-construct). A non-precise candidate
            // cancels with `.needs_precise` — memoized + counter re-armed, so
            // the retry arms in precise mode from the first instruction.
            // Doc 45 D3 (increment 5): the precise retry records `tnew` —
            // routed through `emitAlloc` so the body's `guard_gc` bound
            // covers its object ID, and snapshot-stamped like every precise
            // body op so an OOM exits `.precise_error` at exactly this
            // bytecode (finalize rejects a snap-less `tnew`,
            // `requiresPreciseSnapshot`). The produced ref IS the fresh
            // table of the current iteration; no operands, never reused.
            .new_table => {
                if (!self.precise) return self.abort(.needs_precise);
                self.setReg(instr.a, try self.emitAlloc(.{ .op = .tnew, .ty = .heap }));
            },

            // closures, concat, for_prep, len, …: each pulls in heap-effect
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
    pub fn emit(self: *RecordingSession, ins: IrInstr) !Ref {
        var ins_mut = ins;
        switch (ins_mut.op) {
            // `int_of_float` and `alen` are value-producing but also side-exit, so
            // they stamp their PC for exit-PC chaining like the type guards (their
            // `aux` is unused for anything else — the result kind is `.int`, the
            // operand is `a`).
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float, .alen => {
                ins_mut.aux = @intCast(self.cur_pc);
            },
            // Doc 57: the primitive pins are type guards too.
            .guard_is_nil, .guard_is_false, .guard_is_true => {
                ins_mut.aux = @intCast(self.cur_pc);
            },
            else => {},
        }
        // Doc 45 D2: on a precise recording every BODY op carries the current
        // bytecode-boundary snapshot (a superset of "all potentially failing
        // ops" — dead metadata on ops that cannot exit). The entry prologue
        // runs before any boundary exists (`cur_snap == 0`), which is exactly
        // the entry-replay marker those pre-body failures need.
        if (self.precise) ins_mut.snap = self.cur_snap;
        // Doc 56 §4.2: every op carries its bytecode's boundary ordinal
        // (dead metadata on ops that cannot exit); the bytecode's first
        // side-exit guard commits the boundary snapshot it will resume from.
        ins_mut.ord = self.cur_ord;
        if (self.exit_snap_pending and trace_ir.isSideExitGuardOp(ins_mut.op)) try self.commitExitSnap();
        const ref: Ref = @intCast(self.instrs.items.len);
        try self.instrs.append(self.gpa, ins_mut);
        // Grow the exit-provenance table in lockstep (A-i.1): one `null` per append,
        // so `exit_prov.items[ref]` is always addressable. Guard / fused-producer
        // sites overwrite their slot via `stampProv` (A-i.3); everything else stays
        // `null`. If this append OOMs, `emit` returns the error → the recording
        // aborts → `reset` clears both lists back to equal length, so a transient
        // length skew never outlives the failed recording.
        try self.exit_prov.append(self.gpa, null);
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
    pub fn emitAlloc(self: *RecordingSession, ins: IrInstr) !Ref {
        if (self.guard_gc_ref == null) {
            self.guard_gc_ref = try self.emit(.{ .op = .guard_gc });
        }
        self.alloc_count += 1;
        return self.emit(ins);
    }

    /// Intern a constant into the trace's pool and emit a `konst` for it. A
    /// value seen before reuses its existing `konst` ref (and pool slot) — a
    /// `konst` is pure and operand-free, so sharing its ref is sound. This is
    /// what lets identical subexpressions (e.g. the two `i + 7` in
    /// `(i + 7) * (i + 7)`) end up with identical operand refs, so the
    /// optimizer's CSE can collapse them (see docs / TODO.md).
    pub fn konst(self: *RecordingSession, v: Value) !Ref {
        const key = recKonstKey(v);
        if (self.konst_map.get(key)) |existing| return existing;
        const idx: i32 = @intCast(self.consts.items.len);
        try self.consts.append(self.gpa, v);
        const ref = try self.emit(.{ .op = .konst, .aux = idx, .ty = obsTypeOf(v) });
        try self.konst_map.put(self.gpa, key, ref);
        return ref;
    }

    /// The SSA ref currently held by tier-0 register `slot`. The first read of a
    /// register emits a `slot_load` (a trace input) and records it in the entry
    /// snapshot.
    pub fn refOf(self: *RecordingSession, slot: u16) !Ref {
        // Translate the frame-relative `slot` into a `reg_map` index by the current
        // frame's absolute offset (0 for the anchor frame; cross-frame tracing
        // raises it inside an inlined callee). A `slot_load` is only ever emitted
        // for an anchor-frame slot: S1 pre-seeds every callee slot `.def` at the
        // inlining `.call`, so a callee index is never `.undef` here — the
        // executor's `slot_load aux` therefore always lands in `[0,
        // anchor_num_registers)`.
        return self.refOfAbs(self.base_off + slot);
    }

    /// The anchor-absolute-index body of `refOf` (doc 53): the open-upvalue
    /// slot canonicalization reads an ANCHOR-window slot from a depth>0
    /// context, which `refOf`'s frame-relative signature (it adds `base_off`)
    /// cannot express. Same lazy `slot_load` + peel-φ machinery either way.
    pub fn refOfAbs(self: *RecordingSession, abs: usize) !Ref {
        const s = &self.reg_map[abs];
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
            if (self.peel) |*p| {
                if (abs < self.anchor_num_registers) {
                    const ps = &p.slots[abs];
                    if (!ps.rebound and ps.state == .def) {
                        const phi_ref = try self.emit(.{
                            .op = .phi,
                            .a = ps.ref,
                            .b = 0, // patched by finishPeel
                            .aux = PHI_INTERNAL,
                            .ty = self.instrs.items[@intCast(ps.ref)].ty,
                        });
                        ps.rebound = true;
                        ps.phi_ref = phi_ref;
                        self.noteSlotWrite(abs); // doc 56 §4.2: boundary binding
                        s.* = .{ .ref = phi_ref, .state = .def, .entry_kind = s.entry_kind };
                        return phi_ref;
                    }
                }
            }
            return s.ref;
        }
        const aux: i32 = @intCast(abs);
        const ref = try self.emit(.{ .op = .slot_load, .aux = aux, .ty = .unknown });
        try self.entry_slots.append(self.gpa, @intCast(abs));
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
    pub fn noteEntryKind(self: *RecordingSession, ref: Ref, kind: EntryKind) void {
        const ins = self.instrs.items[@intCast(ref)];
        if (ins.op != .slot_load) return;
        const abs: usize = @intCast(ins.aux);
        // Synthetic input slots (upvalue/global/hash-cell snapshots) reuse the
        // `slot_load` op with `aux >= anchor_num_registers`; that aux is an
        // executor window index, NEVER a `reg_map` index — don't alias the
        // inlined-callee scratch the `reg_map` tail reserves.
        if (abs >= self.anchor_num_registers) return;
        const s = &self.reg_map[abs];
        if (s.entry_kind == .none) s.entry_kind = kind;
    }

    /// Doc 39: the lane-implied variant of `noteEntryKind` for the `guard_fits`
    /// proof route (emitted directly, not via `guard`). Fit implies type for the
    /// narrow lanes: the int store-shape lanes (`Lane.isInt`) prove the value
    /// int, `.f64` proves float; `.boolean`/`.value`/`.grid` prove no numeric
    /// kind and stamp nothing.
    pub fn noteEntryKindFromLane(self: *RecordingSession, ref: Ref, lane: arr.Lane) void {
        if (lane.isInt()) {
            self.noteEntryKind(ref, .int);
        } else if (lane == .f64) {
            self.noteEntryKind(ref, .float);
        }
    }

    /// Record that tier-0 register `slot` (in the current frame) now holds the
    /// value produced by `ref` (a loop-carried write — surfaces in the exit
    /// snapshot). Offset by `base_off` like `refOf`.
    pub fn setReg(self: *RecordingSession, slot: u16, ref: Ref) void {
        self.defineSlotAbs(self.base_off + slot, ref);
    }

    /// The single whole-`RegSlot` define: every write that replaces a slot's
    /// binding (`setReg`, inlined-callee seeding, return mapping) funnels here
    /// so that (a) `entry_kind` SURVIVES the write (doc 39 — `k = k/2` must not
    /// erase the evidence that `k` entered int; codex round-2 finding 2), and
    /// (b) an in-flight peel marks the slot `rebound` (a body write before any
    /// read means "no internal φ" — the write-before-read class).
    pub fn defineSlotAbs(self: *RecordingSession, abs: usize, ref: Ref) void {
        if (self.peel) |*p| {
            if (abs < self.anchor_num_registers) p.slots[abs].rebound = true;
        }
        self.noteSlotWrite(abs); // doc 56 §4.2: keep the boundary binding
        const s = &self.reg_map[abs];
        s.* = .{ .ref = ref, .state = .def, .entry_kind = s.entry_kind };
    }

    /// Whether tier-0 register `slot` was *read* during this recording (i.e. it is
    /// in the entry snapshot). Used by `commit()` as a safety net so the dead-
    /// temporary filter never drops a slot the trace actually consumed.
    pub fn readSlot(self: *const RecordingSession, slot: u16) bool {
        return std.mem.indexOfScalar(u16, self.entry_slots.items, slot) != null;
    }

    /// Stamp the exit provenance (doc 17, A-i.3) of the guard / fused-producer just
    /// emitted at emission index `ref` — the lockstep `exit_prov` slot already exists
    /// (appended by `emit`). The leaf is the currently-recording opcode:
    /// `source_proto_id = cur_proto_id`, `source_pc = cur_pc − 1` (`cur_pc` is the
    /// post-increment resume PC), with the live inline-path prefix. Behaviour-neutral:
    /// nothing reads `exit_prov` until Part A (A-ii).
    pub fn stampProv(self: *RecordingSession, ref: Ref, role: GuardRole, operand: OperandDesig, polarity: Polarity) void {
        self.exit_prov.items[ref] = .{
            .guard = .{
                .path = pathFromFrames(&self.frames, self.inline_depth),
                .inline_depth = self.inline_depth,
                .source_proto_id = self.cur_proto_id,
                // `cur_pc` is the post-increment resume PC (= source-opcode PC + 1), so the
                // owning guest opcode is `cur_pc − 1` (same convention as `guardSourcePc`).
                // In production `cur_pc ≥ 1` always; saturating subtraction is identical for
                // every real input and only maps the synthetic `pc = 0` test sentinel to 0
                // (which `guardSourcePc` likewise treats as "no loop-body guard PC").
                .source_pc = self.cur_pc -| 1,
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
    pub fn guard(self: *RecordingSession, ref: Ref, op: IrOp, role: GuardRole, operand: OperandDesig) !void {
        // Doc 39: stamp the slot's proven entry kind BEFORE the dedup return —
        // the proof exists even when the guard emission is suppressed.
        switch (op) {
            .guard_int => self.noteEntryKind(ref, .int),
            .guard_float => self.noteEntryKind(ref, .float),
            else => {},
        }
        if (self.guarded_refs.contains(ref)) {
            self.dbg("guard-dedup: ref={d} op={s} ir_len={d}", .{ ref, @tagName(op), self.instrs.items.len });
            return;
        }
        const gref = try self.emit(.{ .op = op, .a = ref });
        try self.guarded_refs.put(self.gpa, ref, @intCast(gref));
        self.stampProv(gref, role, operand, .neutral);
    }

    /// Doc 57 §4.2: value-specialize an untyped nil/bool input (LuaJIT's typed
    /// SLOAD of `IRT_NIL`/`IRT_FALSE`/`IRT_TRUE`). Returns the konst ref that
    /// stands for `ref` from here on, or null when no pin applies:
    ///   * `v` is not nil/bool → null (numbers/heap keep their own paths);
    ///   * `ref` is already a konst → `ref`;
    ///   * `ref` is a `slot_load` or a `phi` (the untyped sources) → emit the
    ///     strict `guard_is_*` (deduped through `guarded_refs`, which
    ///     `peelRewind` already purges correctly — no second map) and return
    ///     the interned konst of `v`;
    ///   * any other producer → null: compares, `not`, bool-lane `aload`, bool
    ///     `hload`/`uload` are typed producers that stay dynamic `.bool`, and
    ///     value-lane loads keep today's behaviour.
    /// The register is NOT rebound: the slot stays `.input` (no φ, no
    /// writeback); later consumers of the same ref pin again and hit the dedup.
    /// Provenance is `(.operand_type, operand)` even at a branch: a pin failing
    /// there is not always the other CFG edge (`true` → a table stays truthy).
    pub fn pinPrim(self: *RecordingSession, ref: Ref, v: Value, operand: OperandDesig) !?Ref {
        const op = trace_ir.primPinOp(v) orelse return null;
        if (self.konstValueOf(ref) != null) return ref;
        switch (self.instrs.items[@intCast(ref)].op) {
            .slot_load, .phi => {},
            else => return null,
        }
        try self.guard(ref, op, .operand_type, operand);
        return try self.konst(v);
    }

    /// Doc 57: is `ref` statically a boolean on every run of the trace? A bool
    /// konst, or a producer whose result type is fixed: the compares and `not`
    /// (always a bool), a bool-LANE `aload` (checked by lane, not by the
    /// observed `ty`, which a value-lane load also stamps), and a bool
    /// `hload`/`uload` field (their fused tag check exits on drift — the
    /// `recHashSet` P1 discipline). `slot_load`/`phi` are never typed: a peel
    /// φ copies its init's `ty`, which proves nothing about the update.
    fn boolTyped(self: *const RecordingSession, ref: Ref) bool {
        if (self.konstValueOf(ref)) |kv| return kv.isBool();
        const ins = self.instrs.items[@intCast(ref)];
        return switch (ins.op) {
            .eq, .ne, .lt, .le, .not => true,
            .aload => ins.aux == @intFromEnum(arr.Lane.boolean),
            .hload, .uload => ins.ty == .boolean,
            else => false,
        };
    }

    pub fn guardInt(self: *RecordingSession, ref: Ref, role: GuardRole, operand: OperandDesig) !void {
        try self.guard(ref, .guard_int, role, operand);
    }

    /// Doc 48: emit the `container_lane` `guard_lane` AND pin the observed
    /// table's deterministic identity (`GcHeader.id`) for widen-eviction.
    /// The pin is eviction metadata only — append failure (OOM) skips it,
    /// which at worst suppresses a future eviction of this trace.
    pub fn emitLaneGuardPinned(self: *RecordingSession, rtab: Ref, lane_ord: i32, od: OperandDesig, header: *const object.GcHeader) !void {
        const gref = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
        self.stampProv(gref, .container_lane, od, .neutral);
        // Only slot_load-rooted guards get pins: `laneWidenedPast` resolves
        // the live table via guard_lane.a → slot_load.aux, so a pin on any
        // other root (e.g. an hloaded per-iteration table, doc 43 P3) could
        // never be consulted — don't capture it (codex round-2).
        if (self.instrs.items[rtab].op != .slot_load) return;
        self.lane_pins.append(self.gpa, .{ .guard_ref = @intCast(gref), .table_id = header.id }) catch {};
    }

    pub fn guardNum(self: *RecordingSession, ref: Ref, v: Value, role: GuardRole, operand: OperandDesig) !void {
        try self.guard(ref, if (v.isInt()) IrOp.guard_int else IrOp.guard_float, role, operand);
    }

    /// Record-time view of an array get/set KEY: the integer index tier-0's
    /// `table.normalizeKey` resolves the key to, or null when the access is hash
    /// territory (fractional float / non-number) and the caller must abort
    /// `.bad_type`. The SAME `value.floatAsExactInt` predicate underpins
    /// `normalizeKey`, tier-1a's `int_of_float`, and the native `cvttsd2si`
    /// round-trip, so all four agree bit-for-bit.
    pub fn keyIndexOf(vkey: Value) ?i64 {
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
    pub fn keyRefNarrowed(self: *RecordingSession, key_reg: u16, operand: OperandDesig, vkey: Value) !Ref {
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

    pub fn recArith(self: *RecordingSession, op: IrOp, instr: Instr, regs: RegWindow) !void {
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

    pub fn recBitwise(self: *RecordingSession, op: IrOp, instr: Instr, regs: RegWindow) !void {
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

    pub fn recNeg(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        if (!vb.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardNum(rb, vb, .operand_type, .b);
        const r = try self.emit(.{ .op = .neg, .a = rb, .ty = if (vb.isInt()) .int else .float });
        self.setReg(instr.a, r);
    }

    /// `not` works on any value via Lua truthiness, so it needs no type guard —
    /// the IR `not` is defined over truthiness, like tier-0. Doc 57: a nil/bool
    /// input is value-specialized first, and a konst operand folds to the konst
    /// result (LuaJIT BC_NOT: "type specialization already forces const
    /// result"). Only a dynamic operand (a compare result, a bool-lane load, a
    /// heap value) still emits the IR `not`.
    pub fn recNot(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        const rb_raw = try self.refOf(instr.b);
        const rb = (try self.pinPrim(rb_raw, regs.get(instr.b), .b)) orelse rb_raw;
        if (self.konstValueOf(rb)) |kv| {
            self.setReg(instr.a, try self.konst(Value.boolean(!kv.isTruthy())));
            return;
        }
        const r = try self.emit(.{ .op = .not, .a = rb, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    pub fn recBnot(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        const vb = regs.get(instr.b);
        if (!vb.isInt()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardInt(rb, .operand_type, .b);
        const r = try self.emit(.{ .op = .bnot, .a = rb, .ty = .int });
        self.setReg(instr.a, r);
    }

    pub fn recCompare(self: *RecordingSession, op: IrOp, swap: bool, instr: Instr, regs: RegWindow) !void {
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
    pub const GetFrame = struct {
        dst: u16,
        tab: u16,
        key: u16,
        tab_od: OperandDesig,
        key_od: OperandDesig,
    };

    /// Slot frame for the write shapes: `val` is the stored value's register.
    pub const SetFrame = struct {
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
    pub fn recArrayGet(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        return self.arrayGetShape(regs, .{ .dst = instr.a, .tab = instr.b, .key = instr.c, .tab_od = .b, .key_od = .c });
    }

    pub fn arrayGetShape(self: *RecordingSession, regs: RegWindow, f: GetFrame) !void {
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        const idx = keyIndexOf(vkey) orelse {
            self.dbg("bad_type arrayGet key: isInt={} isFloat={} pc={d}", .{ vkey.isInt(), vkey.isFloat(), self.cur_pc });
            return self.abort(.bad_type);
        };
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent slot could fire `__index` (chunk 2a). Even a
        // present slot today could become a hole on a later iteration, so the only
        // sound conservative choice is to bail the whole trace to tier-0.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        const loaded = tbl.getInt(idx);
        if (loaded.isNil()) return self.recordAbsentGet(regs, f);
        if (!arr.ArrayPart.inArray(idx, tbl.array.asize)) {
            self.dbg("bad_type arrayGet: idx={d} asize={d} lane={d} pc={d}", .{ idx, tbl.array.asize, @intFromEnum(lane), self.cur_pc });
            return self.abort(.bad_type);
        }

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
            try self.emitLaneGuardPinned(rtab, lane_ord, f.tab_od, vtab.asHeap());
            const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
            if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, idx, vtab.asHeap())) return;
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
        try self.emitLaneGuardPinned(rtab, lane_ord, f.tab_od, vtab.asHeap());
        const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
        if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, idx, vtab.asHeap())) return;
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_present, .a = ref }), .present, .none, .neutral);
        const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
        self.setReg(f.dst, rload);
    }

    /// Resolve an array load against the recorder's deferred-store buffer using
    /// LuaJIT's `aa_ahref` rule extended with RECORD-TIME TRUTH (doc 51 Fix A):
    /// forward on a must-alias, skip on a proven no-alias, and — where static
    /// analysis is ambiguous — specialize to the direction actually OBSERVED
    /// during recording, guarded. A guard contrary to the observed state is a
    /// dead-on-arrival trace (it fails on the very iteration that recorded it —
    /// the F1 turnstile of doc 51), so the observed values decide the guard's
    /// direction, never its necessity. Table identity alone is NOT cell
    /// identity: the decision combines the observed table relation with the
    /// static key class (the doc 51 matrix). The one deliberate abort:
    /// loop-varying (`.may`) keys observed EQUAL — forwarding behind a key-
    /// equality guard would pin an unproven per-iteration collision (the
    /// turnstile the pre-existing policy warns against); proving such a
    /// relation is `classifyArrayKeyAlias`'s job, not a record sample's.
    /// Walking newest-to-oldest preserves last-writer-wins.
    pub fn forwardPendingArrayLoad(self: *RecordingSession, dst: u16, rtab: Ref, rkey: Ref, idx: i64, load_tab: *const object.GcHeader) !bool {
        var n = self.pending_stores.items.len;
        while (n > 0) {
            n -= 1;
            const ps = self.pending_stores.items[n];
            switch (ps.op) {
                .astore => {},
                // A present hash overwrite cannot change an array slot; a
                // closed-cell upvalue store (doc 43 P5) writes an `Upvalue`'s
                // owned `Value`, which is never a table slot.
                .hstore, .ustore => continue,
                // Doc 30: a pending `sgm_setpos` DOES write an array cell
                // (the gmatch state's slot 3) — fail closed on any store op
                // this classifier wasn't written for.
                else => {
                    self.abort(.store_fwd_ambiguity);
                    return true;
                },
            }
            const addr = self.instrs.items[ps.aref];
            std.debug.assert(addr.op == .aref);
            const same_ref = addr.a == rtab;
            const tables_observed_equal = same_ref or ps.storedTo(load_tab);
            if (!tables_observed_equal) {
                // Observed-distinct tables: the honest specialization is
                // "they differ" — guard it and ignore the keys entirely. If
                // the refs collide on a later iteration, side-exit (sound in
                // C1: no pending store has executed).
                const cmp = try self.emit(.{ .op = .ne, .a = rtab, .b = addr.a, .ty = .boolean });
                self.stampProv(try self.emit(.{ .op = .guard_true, .a = cmp }), .alias_disambig, .none, .neutral);
                continue;
            }
            switch (self.classifyArrayKeyAlias(rkey, addr.b)) {
                .must => {
                    // Statically the same cell. Same SSA ref needs no guard;
                    // different refs to the observed-same table pin the
                    // identity (`ne` observed FALSE → guard_false).
                    if (!same_ref) {
                        const cmp = try self.emit(.{ .op = .ne, .a = rtab, .b = addr.a, .ty = .boolean });
                        self.stampProv(try self.emit(.{ .op = .guard_false, .a = cmp }), .alias_disambig, .none, .neutral);
                    }
                    self.setReg(dst, ps.value);
                    return true;
                },
                // Statically-distinct keys can't share a cell regardless of
                // which table each ref holds — no guard needed.
                .no => continue,
                .may => {
                    if (idx != ps.key_idx) {
                        // Loop-varying keys observed DIFFERENT: guard the key
                        // inequality ONLY — adding a table-equality guard
                        // would over-specialize (if the tables differ at
                        // runtime the store can't touch our cell anyway, and
                        // a spurious key-collision exit is C1-sound).
                        const cmp = try self.emit(.{ .op = .ne, .a = rkey, .b = addr.b, .ty = .boolean });
                        self.stampProv(try self.emit(.{ .op = .guard_true, .a = cmp }), .alias_disambig, .none, .neutral);
                        continue;
                    }
                    // Loop-varying keys observed EQUAL: an unproven
                    // collision — abort rather than pin it (see doc comment).
                    self.abort(.store_fwd_ambiguity);
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
    /// repeated same-cell stores exact). Same-key/different-table-ref cases
    /// specialize to the RECORD-TIME table object identity (doc 51 Fix A): observed
    /// equal → the store aliases this cell, forward its value behind an
    /// identity guard; observed distinct → guard the inequality (honest) and
    /// keep scanning. Returns `true` when the load was resolved (value
    /// forwarded or recording aborted); `false` → caller emits the heap read.
    pub fn forwardPendingHashLoad(self: *RecordingSession, dst: u16, rtab: Ref, rkey: Ref, load_tab: *const object.GcHeader) !bool {
        var n = self.pending_stores.items.len;
        while (n > 0) {
            n -= 1;
            const ps = self.pending_stores.items[n];
            switch (ps.op) {
                // An in-bounds array store (the only array op ever buffered —
                // `astore_append` is emitted inline) can neither grow the array nor
                // migrate a hash cell, and every recordable hash key is a string:
                // NO alias, keep scanning. A closed-cell upvalue store (doc 43
                // P5) likewise can never alias a table's hash cell.
                .astore, .ustore => continue,
                .hstore => {},
                // Fail closed on any store op this classifier wasn't written for.
                else => {
                    self.abort(.store_fwd_ambiguity);
                    return true;
                },
            }
            const addr = self.instrs.items[ps.aref];
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
            // Same key, different table SSA refs — the record-time identity
            // decides the specialization direction (doc 51 Fix A; guarding
            // contrary to the observed state minted DOA turnstile traces).
            if (ps.storedTo(load_tab)) {
                // Observed the SAME table: the sunk store aliases this cell.
                // Pin the identity (`ne` observed FALSE → guard_false) and
                // forward the newest pending value — at record time tier-0
                // has executed the store, so the observed loaded value IS
                // the stored value; at native time the flush below all
                // guards makes the same value visible.
                const cmp = try self.emit(.{ .op = .ne, .a = rtab, .b = addr.a, .ty = .boolean });
                self.stampProv(try self.emit(.{ .op = .guard_false, .a = cmp }), .alias_disambig, .none, .neutral);
                self.setReg(dst, ps.value);
                return true;
            }
            // Observed DISTINCT tables: guard the inequality (honest) and
            // keep scanning — the store can't touch our cell.
            const cmp = try self.emit(.{ .op = .ne, .a = rtab, .b = addr.a, .ty = .boolean });
            self.stampProv(try self.emit(.{ .op = .guard_true, .a = cmp }), .alias_disambig, .none, .neutral);
            continue;
        }
        return false;
    }

    pub fn classifyArrayKeyAlias(self: *const RecordingSession, lhs: Ref, rhs: Ref) AliasClass {
        if (lhs == rhs) return .must;
        const lc = self.intKonstRef(lhs);
        const rc = self.intKonstRef(rhs);
        if (lc != null and rc != null) return if (lc.? == rc.?) .must else .no;
        const la = self.affineIntKey(lhs, 0) orelse return .may;
        const ra = self.affineIntKey(rhs, 0) orelse return .may;
        if (la.base != ra.base) return .may;
        return if (la.offset == ra.offset) .must else .no;
    }

    pub fn intKonstRef(self: *const RecordingSession, ref: Ref) ?i64 {
        if (ref >= self.instrs.items.len) return null;
        const ins = self.instrs.items[ref];
        if (ins.op != .konst or ins.aux < 0) return null;
        const ci: usize = @intCast(ins.aux);
        if (ci >= self.consts.items.len) return null;
        const v = self.consts.items[ci];
        return if (v.isInt()) v.asInt() else null;
    }

    /// Canonicalise integer `base + constant` chains. Distinct offsets from the
    /// same SSA base cannot alias; unrelated bases remain MAY. The recursion is
    /// bounded defensively even though SSA operands point backward.
    pub fn affineIntKey(self: *const RecordingSession, ref: Ref, depth: u8) ?AffineIntKey {
        if (depth == 16 or ref >= self.instrs.items.len) return null;
        const ins = self.instrs.items[ref];
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
    pub fn recArraySet(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        return self.arraySetShape(regs, .{ .tab = instr.a, .key = instr.b, .val = instr.c, .tab_od = .a, .key_od = .b, .val_od = .c });
    }

    pub fn arraySetShape(self: *RecordingSession, regs: RegWindow, f: SetFrame) !void {
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
        if (self.globalsStoreBars(vtab)) return self.abort(.aliased_input); // doc 43 P0b
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
        // back to tier-0 while the in-capacity common case runs native. Phase A
        // covered the boolean lane (one in-band byte/slot) and the fixed-width int
        // lanes (i8…i64: width store + presence bit); doc 47 extends it to `.f64`
        // (movsd store + presence bit — the XMM path the in-bounds F64_LANE
        // `astore` already emits), unblocking float array-fill loops
        // (`x[i]=rand()`-style setup, and sparse's grow-then-reuse `vy` whose
        // append aborts permanently record-blacklisted the loop-done continuation
        // anchor during scimark's calibration call). Only `.value` still aborts
        // below (write-barrier territory, doc 32). The emitted IR sequence is
        // lane-generic; `guard_fits` (below) supplies the int lane's runtime range
        // check (for f64 it degenerates to the float type pin), and the value's
        // static kind comes from its producing ref — same as the in-bounds store.
        if ((lane == .boolean or lane.isInt() or lane == .f64) and
            idx == @as(i64, @intCast(tbl.array.asize)) and
            tbl.hash.count() == 0 and
            tbl.array.fits(vval))
        {
            // Same C1 deopt-replay rule as `astore`, but scoped to the reads an
            // append can actually invalidate (doc 43 P4): a prior ARRAY read
            // (`aload`/`gload`/`alen`) could have steered this store's value or
            // occurrence, and re-running the iteration on a side-exit (against
            // the now-longer array) would diverge — barred. A pure HASH read
            // (`hload`) cannot witness an append — `guard_append` re-proves
            // this table's hash EMPTY while `guard_hash` requires the hload's
            // cell POPULATED, so aliasing side-exits before the append runs —
            // and is admitted (the method-fill idiom: `self.image` hloads
            // feeding `image[pos] = p`). Pending SUNK stores may therefore now
            // coexist with an inline append (hload→hstore traces have no
            // aload): sound because the flush stays below every guard — a
            // failed guard leaves them unapplied and tier-0's re-run applies
            // each exactly once, while the re-run's append lands as an
            // idempotent in-bounds overwrite (its key/value derive only from
            // state the append didn't touch); hash and array parts are
            // disjoint, and same-table hstore+append contradict at the guards
            // (`docs/design/08-multi-store-sinking.md` §soundness).
            if (self.traceHasArrayRead()) return self.abort(.store_after_load);
            // Doc 57: a bool input is value-specialized (the store writes the
            // konst; its `guard_fits` then folds in tropt).
            const rval_raw = try self.refOf(f.val);
            const rval = (try self.pinPrim(rval_raw, vval, f.val_od)) orelse rval_raw;
            const lane_ord: i32 = @intFromEnum(lane);
            const rtab = try self.refOf(f.tab);
            // P0d: `t[#t+1] = v` (length-dependent append) is non-idempotent under
            // coarse deopt-replay — bar it fail-closed. See `traceHasAlenOf`.
            if (self.traceHasAlenOf(rtab)) return self.abort(.aliased_input);
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
            try self.emitLaneGuardPinned(rtab, lane_ord, f.tab_od, vtab.asHeap());
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
        // Doc 57: a bool input is value-specialized (see the append path).
        const rval_raw = try self.refOf(f.val);
        const rval = (try self.pinPrim(rval_raw, vval, f.val_od)) orelse rval_raw;

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        try self.emitLaneGuardPinned(rtab, lane_ord, f.tab_od, vtab.asHeap());
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
            // Doc 45 D3: precise candidates keep `pending_stores` EMPTY — a
            // sunk store would float past the per-bytecode snapshot ordering.
            // Store-at-position for these shapes lands with the effect-order
            // increment; until then refuse, fail-closed.
            if (self.precise) return self.abort(.nyi_opcode);
            // Read-modify-write: stash the store; `commit()` flushes it (and any
            // siblings) below every guard, just before `.loop`, in this recorded
            // order. The guards above (table/lane/int/bounds/fits) stay inline and
            // continue to dominate the sunk store.
            try self.pending_stores.append(self.gpa, .{
                .aref = ref,
                .value = rval,
                .lane_ord = lane_ord,
                .tab_obj = objIdentity(vtab.asHeap()),
                .key_idx = idx,
                .ord = self.cur_ord,
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
    pub fn recGridGet(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        // Like recArrayGet: a grid load after a sunk store would read stale on-trace.
        if (self.pending_stores.items.len > 0) return self.abort(.store_after_load);
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
    pub fn recGridSet(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
        if (self.traceHasHeapLoad()) return self.abort(.store_after_load);

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
    pub fn traceHasHeapLoad(self: *const RecordingSession) bool {
        for (self.instrs.items) |ins| {
            // `uload` (doc 43 P5) is a heap read for the C1 store-sink
            // decision: a store following it is a read-modify-write whose
            // write must defer below every guard.
            if (ins.op == .aload or ins.op == .hload or ins.op == .gload or ins.op == .uload or ins.op == .guard_absent) return true;
        }
        return false;
    }

    /// Has this trace already read any ARRAY-part state (`aload`/`gload`) or a
    /// table length (`alen`)? The narrower cousin of `traceHasHeapLoad` for the
    /// APPEND branch's C1 idempotence bar (doc 43 P4): an append mutates only
    /// array-part state (a slot + `asize`), and `guard_append` re-proves the
    /// table's hash EMPTY every iteration — while an `hload`'s dominating
    /// `guard_hash` requires a POPULATED cell in its table. If the two tables
    /// were ever the same, the guards contradict at runtime and the iteration
    /// side-exits BEFORE the append executes, so a pure hash-field read can
    /// never witness an append and is safe to precede one (the method-call
    /// idiom: `self.nx`/`self.image` hloads feeding an `image[pos] = p` fill).
    /// Array reads and `alen`s of ANY ref stay barred — a different SSA root
    /// may alias the appended table (fail-closed, no alias analysis).
    pub fn traceHasArrayRead(self: *const RecordingSession) bool {
        for (self.instrs.items) |ins| {
            if (ins.op == .aload or ins.op == .gload or ins.op == .alen or ins.op == .guard_absent) return true;
        }
        return false;
    }

    /// Has this trace already read `#t` (an `.alen`) of the SAME table `rtab`?
    /// The push idiom `t[#t+1] = v` reads the table's own length to form the
    /// append index, then appends — growing that very length. Under coarse C1
    /// deopt-replay a loop-done side-exit re-runs the final body iteration, and
    /// the re-run observes the now-longer `#t`, so the append double-applies at
    /// `asize+1` (doc 43 P0d: a16/a20 diverged, t0=N vs trace=N+1). A loop-var-
    /// indexed append (`t[i]=v`, nsieve) never reads `#t` and is idempotent, so
    /// it stays traced. Fail-closed: any `alen(rtab)` in the trace bars the
    /// append. Correct native tracing of the push idiom is a perf follow-up
    /// (needs a loop-done snapshot that pins the pre-append length).
    fn traceHasAlenOf(self: *const RecordingSession, rtab: Ref) bool {
        for (self.instrs.items) |ins| {
            if (ins.op == .alen and ins.a == rtab) return true;
        }
        return false;
    }

    /// Is `v` a heap **string** — i.e. an `obj.field`-shaped (hash-part) table key?
    /// The compiler lowers every `obj.field` to `get_index`/`set_index` with an
    /// interned-string key, so this is the gate that routes such accesses to the
    /// hash-field path (doc 11) instead of the integer-array path.
    pub fn isStringKey(v: Value) bool {
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
    pub fn seedHashCell(self: *RecordingSession, rtab: Ref, rkey: Ref, count: u32, hrefk_aux: i32) !?u16 {
        const tab_instr = self.instrs.items[@intCast(rtab)];
        // The table must live in a re-readable anchor slot (a `slot_load`, which both
        // an ordinary register read and a U0-seeded upvalue/global resolve to). A
        // table computed on-trace has no entry slab slot to re-resolve from.
        if (tab_instr.op != .slot_load) return null;
        const table_reg: u16 = @intCast(tab_instr.aux);
        const key_const: u32 = @intCast(self.instrs.items[@intCast(rkey)].aux);

        const dkey = (@as(u64, table_reg) << 32) | key_const;
        if (self.hash_cell_dedup.get(dkey)) |slot| return slot;

        // Budget/index guards mirror `recInputGet`, but a miss declines native rather
        // than aborting the (still-valid-at-tier-1a) trace.
        if (self.input_seeds.items.len >= MAX_TRACE_INPUTS) return null;
        if (self.next_input_slot == std.math.maxInt(u16)) return null;

        const slot = self.next_input_slot;
        self.next_input_slot += 1;
        try self.input_seeds.append(self.gpa, .{
            .kind = .hash_cell,
            .source = key_const,
            .slot = slot,
            .table_reg = table_reg,
            .expected_count = count,
            // Doc 49 P5: the hrefk fallback hint for when emission discovers
            // the root is carried-heap and deactivates this seed. Same
            // observed table + key within one recording (dedup key), so the
            // first stamp is the only stamp.
            .hrefk_aux = hrefk_aux,
        });
        try self.hash_cell_dedup.put(self.gpa, dkey, slot);
        return slot;
    }

    /// The hrefk `(slot, mask)` encoding for a HEAP (string) constant key
    /// present LIVE in the observed table, else `-1`. Scalar-key hrefk is
    /// deferred (doc 49) — the native key guard compares the node key's
    /// `GcHeader.id`, which only heap keys have. Shared by `hrefAuxFor` (the
    /// dynamic-root aux) and `seedHashCell` (the doc 49 P5 fallback hint
    /// stamped into the seed), so both record the identical encoding.
    fn hrefkAuxOf(tbl: *const table_mod.Table, vkey: Value) i32 {
        if (vkey.isHeap()) {
            if (tbl.hashSlotOf(vkey)) |sm| {
                if (trace_ir.HrefAux.encode(sm.slot, sm.mask)) |aux| return aux;
            }
        }
        return -1;
    }

    /// The `href.aux` for a hash-field access (doc 49): seed slab slot when the
    /// root is invariant, else the hrefk `(slot, mask)` encoding, else `-1`
    /// (the per-iteration `resolveHashCell` callout).
    fn hrefAuxFor(seed_slot: ?u16, tbl: *const table_mod.Table, vkey: Value) i32 {
        if (seed_slot) |s| return @as(i32, s);
        return hrefkAuxOf(tbl, vkey);
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
    /// General absent lookup. Keep the nil constant behind a runtime proof;
    /// never specialize an observed absence into an unconditional result.
    fn recordAbsentGet(self: *RecordingSession, regs: RegWindow, f: GetFrame) !void {
        const key = regs.get(f.key);
        const rtab = try self.refOf(f.tab);
        const rkey = if (key.isNumber())
            try self.keyRefNarrowed(f.key, f.key_od, key)
        else
            try self.refOf(f.key);
        if (!key.isNumber() and self.konstValueOf(rkey) == null) return self.abort(.bad_type);
        // Pending mutations are not yet in the executor heap. The existing
        // forwarding paths either resolve them or refuse ambiguous aliases.
        if (key.isNumber()) {
            if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, keyIndexOf(key).?, regs.get(f.tab).asHeap())) return;
        } else if (try self.forwardPendingHashLoad(f.dst, rtab, rkey, regs.get(f.tab).asHeap())) return;
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_absent, .a = rtab, .b = rkey }), .present, .loaded, .neutral);
        self.setReg(f.dst, try self.konst(Value.nil()));
    }

    pub fn recHashGet(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        return self.hashGetShape(regs, .{ .dst = instr.a, .tab = instr.b, .key = instr.c, .tab_od = .b, .key_od = .c });
    }

    pub fn hashGetShape(self: *RecordingSession, regs: RegWindow, f: GetFrame) !void {
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const cell = tbl.fieldPtr(vkey) orelse return self.recordAbsentGet(regs, f);
        // Field-type restriction (the hash analogue of the narrow-array-lane rule).
        // A present cell holds a non-`nil` tagged `Value` of any type. We trace
        // **int/float/bool/function** fields. The historic objection to bool —
        // "there is no strict bool guard; `guard_true` waves a truthy heap value
        // through" — is answered LuaJIT-style (doc 43 P1): the **load's own tag
        // check** is the strict guard. `hload ty=.boolean` tag-checks the cell in
        // BOTH tiers (tier-1a `type_ok`, native `cmp byte [cell], TAG_BOOL`) and
        // side-exits at the load, before any consumer, so a field drifting
        // bool→heap never flows on-trace. (The old "the scalar exec-log encoder
        // can't take it" half of the objection was already dead — doc 32: the log
        // silently drops unencodables, is viz-only, mutually exclusive with
        // native, and `effectser.toEffectResult` encodes bools anyway.)
        // A FUNCTION field (doc 43 P2 — `local m = self.method` / `obj:method()`
        // dispatch) records as `hload ty=.heap` + an immediate `guard_func`
        // pinning the closure's `Proto.id` (doc 02: a stable id, never a pointer
        // — survives keyframe restore). Proto-id identity — not closure identity
        // — is sound because an inlined callee's upvalue read requires a
        // `slot_load` callee ref (`recCalleeUpval`) and an `hload` ref is not
        // one: it aborts `.cross_frame` fail-closed. HARD INVARIANT (doc 43 §5):
        // any future path letting an hload-loaded callee reach upvalue access
        // must first tighten `guard_func` to closure `GcHeader.id`.
        // A TABLE field (doc 43 P3 — `local image = self.image` inside a loop
        // body, the array3d shape) records as `hload ty=.heap` + an immediate
        // `guard_table` — the exact mirror of the `.value`-lane array-of-structs
        // element pin (`arrayGetShape`). The loaded ref then roots downstream
        // array/hash accesses as a DYNAMIC (per-iteration) table: native lowers
        // its guard_table/guard_lane/guard_hash in-body and resolves href via
        // the `resolveHashCell` callout (no entry seed — `seedHashCell` already
        // declines a non-slot_load root). Metatable-free is checked at record
        // time here AND at run time by guard_table, like the element precedent.
        // String/native-builtin fields still abort.
        const fv = cell.*;
        const is_fn_field = fv.isHeap() and fv.heapType() == .function;
        const is_tbl_field = fv.isHeap() and fv.heapType() == .table;
        if (!(fv.isInt() or fv.isFloat() or fv.isBool() or is_fn_field or is_tbl_field)) return self.abort(.nyi_opcode);
        if (is_tbl_field) {
            const ftbl = table_mod.Table.fromHeader(fv.asHeap());
            if (ftbl.metatable != null) return self.abort(.has_metatable);
        }
        // The key must be a recorded `konst` (the bytecode literal interned via
        // `load_const`), so its ref is provably the constant — no runtime key-
        // identity guard is needed and the cell is pinnable. A computed key reaches
        // here as a `slot_load`/arith ref and aborts (v1 scope).
        const rkey = try self.refOf(f.key);
        if (self.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

        const rtab = try self.refOf(f.tab);
        // Resolve against the deferred-store buffer BEFORE emitting the load chain
        // (doc 08 §2026-08-20): a MUST-alias forwards the pending value (the store
        // side already emitted `guard_table`/`href`/`guard_hash`/`guardNum` on this
        // same table ref + key konst, so no chain is re-emitted here), NO keeps
        // scanning / falls through to the heap read, MAY aborts fail-closed.
        if (try self.forwardPendingHashLoad(f.dst, rtab, rkey, vtab.asHeap())) return;
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        // Seed the loop-invariant cell pointer for native (H1); `href.aux` carries
        // the synthetic slab slot, the hrefk `(slot, mask)` encoding for a
        // dynamic root (doc 49), or `-1` (per-iteration callout).
        // The tier-1a oracle ignores `aux`, so H0 is untouched either way.
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count, hrefkAuxOf(tbl, vkey));
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = hrefAuxFor(seed_slot, tbl, vkey) });
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
        // A BOOL field takes no `guardNum` (there is no numeric guard to give it):
        // its strict type pin IS the `hload ty=.boolean` fused tag exit above —
        // both tiers side-exit at the load itself on a tag flip, so the ref is
        // bool-proven for every consumer (`guard_true`/`guard_false`, or a P1
        // bool `hstore` requiring a `.ty == .boolean` producer).
        // A FUNCTION field (P2) instead pins IDENTITY: `guard_func(rload,
        // aux=Proto.id)` right at the load. The `hload ty=.heap` tag exit proves
        // "some heap value"; guard_func proves "a closure of exactly this proto".
        // `recCall` re-emits the same guard on this ref at the call site and
        // tropt's aux-keyed guard CSE (`guardKeyAux`) folds the duplicate.
        if (is_fn_field) {
            const cl = function.Closure.fromHeader(fv.asHeap());
            self.stampProv(try self.emit(.{ .op = .guard_func, .a = rload, .aux = @bitCast(cl.proto.id) }), .callee_identity, .loaded, .neutral);
        } else if (is_tbl_field) {
            // P3: pin "table, metatable-free" at run time — the mirror of the
            // `.value`-lane element pin. Downstream accesses chain off `rload`.
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rload }), .field_type, .loaded, .neutral);
        } else if (!fv.isBool()) {
            try self.guardNum(rload, fv, .field_type, .loaded);
        }
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
    pub fn recHashSet(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        return self.hashSetShape(regs, .{ .tab = instr.a, .key = instr.b, .val = instr.c, .tab_od = .a, .key_od = .b, .val_od = .c });
    }

    /// Doc 43 §3.2 (P0b): record that a store targets `vtab`; if that is the
    /// globals table, enforce the `_G` snapshot-vs-store coherence. Returns true
    /// when the caller must abort `.aliased_input` (a `get_global` snapshot is
    /// already live). On a non-conflicting globals store it latches the flag so a
    /// *later* `get_global` seed aborts. Non-globals stores are ignored.
    fn globalsStoreBars(self: *RecordingSession, vtab: Value) bool {
        const gh = self.context.globals_header orelse return false;
        if (!vtab.isHeap() or vtab.asHeap() != gh) return false;
        if (self.recorded_global_seed) return true;
        self.recorded_global_store = true;
        return false;
    }

    pub fn hashSetShape(self: *RecordingSession, regs: RegWindow, f: SetFrame) !void {
        const vtab = regs.get(f.tab);
        const vkey = regs.get(f.key);
        const vval = regs.get(f.val);
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (self.globalsStoreBars(vtab)) return self.abort(.aliased_input);
        if (vval.isNil()) return self.abort(.bad_type); // delete — out of scope
        // Value restriction, the store mirror of `hashGetShape`'s read rule:
        // int/float (runtime-pinned by the `guardNum` below) and bool (statically
        // pinned — see the rval check after `refOf`). Covers the int/float field
        // arithmetic OOP code does (`obj.x = obj.x + dt*vx`) and flag writes
        // (`obj.done = true`, `p.alive = q.alive`); reference fields
        // (`obj.next = node`) stay tier-0 pending P2/P3.
        if (!(vval.isInt() or vval.isFloat() or vval.isBool())) return self.abort(.nyi_opcode);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        _ = tbl.fieldPtr(vkey) orelse return self.abort(.bad_type); // absent = insert
        const rkey = try self.refOf(f.key);
        if (self.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

        // C1 / store-sinking, identical to `recArraySet`: a write following any heap
        // read is a read-modify-write that must be deferred below every guard so a
        // side-exit leaves it un-executed and deopt-replay applies it exactly once.
        const defer_store = self.traceHasHeapLoad();
        var rval = try self.refOf(f.val);
        // Pin the **store value's** type. A hash cell holds a full tagged `Value`
        // with no lane to constrain it, so this pin is the analogue of the array
        // path's `guard_fits`: it is the sole guarantee the field stays this type
        // on-trace. Without it, a value whose runtime type drifts (int→heap) would
        // be written into the cell, and a later `hload` would read the wrong type.
        //  * int/float: the standard deduped `guardNum`, emitted inline (it stays
        //    in the body even when the store sinks) so a drifted store value
        //    side-exits *before* the write lands. Sound via `guarded_refs`
        //    (holds only numeric guards, so a prior guard on this ref is
        //    necessarily a matching `guard_int`/`guard_float`).
        //  * bool (doc 43 P1): there is no runtime bool guard — instead the value
        //    ref must be STATICALLY bool-proven: a konst bool, or a producer whose
        //    `.ty == .boolean` (an `hload` bool field, whose fused tag exit
        //    already side-exits upstream on drift). Doc 57: an untyped input
        //    (`slot_load`/`phi`) is value-specialized first — its strict pin
        //    is the runtime guard, and the store writes the konst. Anything
        //    still unproven aborts — that is exactly the drifting-store-value
        //    hole `guardNum` plugs for scalars, and fail-closed is the P0
        //    discipline.
        if (vval.isBool()) {
            if (try self.pinPrim(rval, vval, f.val_od)) |k| rval = k;
            if (!self.boolTyped(rval)) return self.abort(.nyi_opcode);
        } else {
            try self.guardNum(rval, vval, .value_type, f.val_od);
        }
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        // Seed the cell pointer for native (H1) — see `recHashGet`. An RMW's read and
        // write `href`s dedup onto the same slot via `seedHashCell`. A dynamic
        // root gets the hrefk `(slot, mask)` aux instead (doc 49).
        const count: u32 = @intCast(tbl.hash.count());
        const seed_slot = try self.seedHashCell(rtab, rkey, count, hrefkAuxOf(tbl, vkey));
        const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = hrefAuxFor(seed_slot, tbl, vkey) });
        // Fused native producer-exit (A-i.3): native `href` cell-resolution failure.
        self.stampProv(ref, .hash_struct, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, f.tab_od, .neutral);
        // `hstore` is effectful (overwrites the present cell in place) and defines no
        // register. A present-key overwrite never grows the map, so `guard_hash`
        // (population) stays sufficient. The store value's type is pinned by the
        // `guardNum` above (native declines a heap value at H1).
        if (defer_store) {
            // Doc 45 D3: no sunk stores on a precise candidate (see astore).
            if (self.precise) return self.abort(.nyi_opcode);
            try self.pending_stores.append(self.gpa, .{
                .aref = ref,
                .value = rval,
                .lane_ord = 0,
                .op = .hstore,
                .tab_obj = objIdentity(vtab.asHeap()),
                .ord = self.cur_ord,
            });
        } else {
            _ = try self.emit(.{ .op = .hstore, .a = ref, .b = rval });
        }
    }

    /// `eq`/`ne`. First cut: numeric operands only (the common loop-condition
    /// case); other types abort.
    pub fn recEq(self: *RecordingSession, op: IrOp, instr: Instr, regs: RegWindow) !void {
        // Doc 57: value-specialize nil/bool inputs first, so a pinned input
        // takes the konst paths below (LuaJIT `lj_record_objcmp` on typed
        // primitives).
        const rb_raw = try self.refOf(instr.b);
        const rc_raw = try self.refOf(instr.c);
        const rb = (try self.pinPrim(rb_raw, regs.get(instr.b), .b)) orelse rb_raw;
        const rc = (try self.pinPrim(rc_raw, regs.get(instr.c), .c)) orelse rc_raw;
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
        if (!vb.isNumber() or !vc.isNumber()) {
            // Doc 57: two booleans whose types are both proven (a konst, or a
            // typed producer — a compare, `not`, a bool-lane load, a bool
            // field) compare by value on every tier; native lowers it as the
            // int compare of the 0/1 payloads. (Untyped inputs were pinned to
            // konsts above, so any other bool ref here is a typed producer.)
            if (vb.isBool() and vc.isBool() and self.boolTyped(rb) and self.boolTyped(rc)) {
                const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
                self.setReg(instr.a, r);
                return;
            }
            // Cross-type fold — the `x == nil` idiom. Lua equality across
            // distinct type classes is unconditionally false (`__eq` only fires
            // table×table / userdata×userdata, never number×anything-else), and
            // int↔float — the one cross-type pair that CAN compare equal — is
            // one class here. So when BOTH sides' classes are pinned and they
            // differ, the answer is fixed: pin a non-konst number side with
            // guardNum (an iteration where it drifts off-number side-exits
            // before the fold lies) and fold to a bool konst. Pinned means: a
            // konst (the bytecode literal, or a doc 57 pin), a number (pinned by
            // the guardNum emitted here), or a proven-bool producer. Anything
            // else (an unproven heap/nil value) still aborts.
            const b_pinned = self.konstValueOf(rb) != null or vb.isNumber() or self.boolTyped(rb);
            const c_pinned = self.konstValueOf(rc) != null or vc.isNumber() or self.boolTyped(rc);
            const same_class = (vb.isNumber() and vc.isNumber()) or vb.tag == vc.tag;
            if (b_pinned and c_pinned and !same_class) {
                if (vb.isNumber() and self.konstValueOf(rb) == null) try self.guardNum(rb, vb, .operand_type, .b);
                if (vc.isNumber() and self.konstValueOf(rc) == null) try self.guardNum(rc, vc, .operand_type, .c);
                self.setReg(instr.a, try self.konst(Value.boolean(op == .ne)));
                return;
            }
            return self.abort(.bad_type);
        }
        try self.guardNum(rb, vb, .operand_type, .b);
        try self.guardNum(rc, vc, .operand_type, .c);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// `jmp_if_false`/`jmp_if_true`: pin the *observed* truthiness of the tested
    /// register. Which path the trace records is whatever tier-0 took; the guard
    /// is what keeps the straight-line trace valid.
    pub fn recBranch(self: *RecordingSession, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
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
        if (self.kind == .root and self.inline_depth == 0 and
            self.anchor.proto == proto)
        {
            const jumped = (instr.op == .jmp_if_true) == truthy_early;
            const target_i: i64 = @as(i64, pc) + instr.aux; // `pc` = post-increment cursor, as in applyJump
            if (target_i >= 0 and target_i < @as(i64, @intCast(proto.code.len))) {
                const target: u32 = @intCast(target_i);
                // Doc 58 §4.3: the own-loop test is structural and LOCAL now —
                // the branch sits right next to this loop's `loop` marker,
                // whose header is our anchor. No CFG walk, and no dependence on
                // where the condition sits.
                //
                // ROOT recordings abort unconditionally (LuaJIT LLEAVE): the
                // retry lands on a condition-true pass and records the body
                // root first.
                if (target > pc) {
                    // `while`: the branch is at `b`, `code[b + 1]` is the
                    // marker, and taking the branch leaves the loop.
                    if (jumped and pc < proto.code.len and
                        bytecode.loopHeaderOf(proto.code[pc], pc) == self.anchor.pc)
                    {
                        return self.abort(.loop_leave);
                    }
                } else if (instr.op == .jmp_if_false and !jumped and
                    bytecode.loopHeaderOf(proto.code[target], target) == self.anchor.pc)
                {
                    // `repeat`: the backward `jmp_if_false` targets our marker,
                    // and falling through leaves the loop.
                    return self.abort(.loop_leave);
                }
            }
        }
        // Doc 57: a nil/bool input is value-specialized first (its strict pin
        // is the only guard left), so the konst fold below removes the branch
        // — LuaJIT's "type specialization suffices" for BC_IST/BC_ISF.
        const ra_raw = try self.refOf(instr.a);
        const ra = (try self.pinPrim(ra_raw, regs.get(instr.a), .a)) orelse ra_raw;
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
        // Doc 58: a `while`'s own condition guard keeps role `.branch_cond` —
        // the role describes the guard's SHAPE, and `resumeOf` needs it for the
        // branch fix-up that sends the exit to the post-loop pc. Which guards
        // are a loop's own test is answered structurally instead, by
        // `TraceCode.isOwnLoopTest`, so it needs no role and matches every
        // unrolled copy (doc 57 P3's `.loop_test_copy` for `while` is gone with
        // the top-of-trace classifier that needed it).
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
    /// expresses "non-nil" without also pinning truthiness.
    /// Doc 56 G6-Q1(d), LuaJIT `rec_loop_interp`'s side-trace arm ("side
    /// trace enters an inner loop": `--J->loopunroll < 0` → `LJ_TRERR_LUNROLL`).
    /// Called where a side or continuation recording goes round a loop
    /// without closing or linking — a taken `for_loop`/`tfor_loop` back-edge,
    /// or a passed `loop` marker, at any inline depth. Its own anchor's
    /// back-edge never gets here (that one closes the trace). Like LuaJIT the
    /// budget is recording-wide and kind-blind: a root reaches it only where it
    /// may unroll at all — the `innerloopleft` escape (`recLoopLink`) and loops
    /// inside inlined callees; elsewhere roots abort LINNER first, and
    /// one-shots abort `cont_backedge`.
    fn noteLoopIteration(self: *RecordingSession) void {
        if (self.close_requested or !self.active) return;
        if (self.loop_iterations >= self.options.loopunroll) return self.abort(.loop_unroll);
        self.loop_iterations += 1;
    }

    pub fn recTForLoop(self: *RecordingSession, instr: Instr, regs: RegWindow, pc: u32) !void {
        // Same cross-proto pc hazard as `recForLoop`: never process a
        // back-edge inside an inlined callee.
        if (self.inline_depth > 0) return self.abort(.cross_frame);
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
        // Going round a generic `for` that is not our own anchor's unrolls it
        // (G6-Q1(d)); depth is 0 here (inlined back-edges abort above).
        const target: u32 = @intCast(@as(i64, pc) + instr.aux);
        if (target != self.anchor.pc) self.noteLoopIteration();
    }

    pub fn recForLoop(self: *RecordingSession, instr: Instr, regs: RegWindow, pc: u32) !void {
        const a = instr.a;
        // The back-edge target, computed exactly as the interpreter's
        // `applyJump`.
        const target: u32 = @intCast(@as(i64, pc) + instr.aux);
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

        // Doc 56 Phase 3: a `.continuation` recording that loops back into a
        // numeric `for` whose body start already has a root links to it, the
        // `for` twin of `recLoopLink` (LuaJIT `rec_loop_jit`, whose side
        // traces end `LJ_TRLINK_ROOT` at any loop that has a trace). Before
        // this the recording unrolled the enclosing loop's next iteration.
        // Doc 56 G6-Q1(a): `.side` recordings too — LuaJIT's rule is any trace
        // with a parent; leaving them out let nsieve's `.side` trace unroll
        // the outer loop with one prime gap baked in (§4.8.4).
        // The continue test and the stepped index/loop var were published
        // above, so the registers are the root's entry state, exactly as at
        // the doc 47 peel close below. Only into a non-peeled root whose
        // entry guards the live registers already satisfy; otherwise keep
        // recording as before. Skipped while a doc 47 peel is pending (that
        // close owns this back-edge).
        const entry: ForEntryView = .{ .regs = regs, .a = a, .next = vnext };
        if (within and self.pending_link_close == null and (self.kind == .continuation or self.kind == .side) and
            self.inline_depth == 0 and !self.precise and target != self.anchor.pc and
            self.context.inner_root and !self.context.inner_root_peeled and
            entryGuardsMatch(self.context.inner_root_guards, entry))
        {
            self.link_target = target;
            self.link_kind = self.linkKindAt(self.anchor.proto, target);
            self.pending_link_provenance = .{ .link_terminal = .{
                .path = pathFromFrames(&self.frames, self.inline_depth),
                .inline_depth = self.inline_depth,
                .source_proto_id = self.cur_proto_id,
                .source_pc = self.cur_pc -| 1, // the for_loop opcode
            } };
            self.close_requested = true;
            return;
        }

        // No link: going round this loop unrolls it (bounded, G6-Q1(d)). Not
        // our own anchor's back-edge (that closes), and not under a doc 47
        // peel (the peel bounds itself and owns this back-edge).
        if (within and self.pending_link_close == null and
            !(self.inline_depth == 0 and target == self.anchor.pc))
            self.noteLoopIteration();

        // Doc 47 increment A: consume a pending link close from a continuation
        // that recorded through an inner `for_prep` to promote accumulator types.
        if (self.pending_link_close) |*plc| {
            if (self.inline_depth == 0 and target == plc.inner_anchor_pc) {
                switch (plc.phase) {
                    .await_initial_entry => {
                        // First `for_loop` visit: tier-0 jumped here from
                        // `for_prep`. The bounds check just ran above. If the
                        // loop continues (`within`), transition to `.peeling` —
                        // the body will run next, promoting types. If the loop
                        // exits, this is a one-trip-loop: clear the peel and
                        // continue recording past the loop normally.
                        if (within) {
                            plc.phase = .peeling;
                        } else {
                            self.clearPendingLinkClose(.zero_trip);
                            // Continue recording — the guard_false exit direction
                            // was already recorded above.
                        }
                    },
                    .peeling => {
                        // Post-body `for_loop`: one inner iteration completed.
                        if (within) {
                            // Check compatibility against the inner root's entry
                            // guards using the CURRENT register state (types have
                            // been promoted by the inner body), as this
                            // `for_loop` leaves it.
                            if (entryGuardsMatch(plc.contract, entry)) {
                                // Types now match. Close `.link` with the
                                // promoted state. The for_loop's `guard_true`
                                // (continue test) was already emitted above, and
                                // the stepped index/loop-var are published.
                                self.link_target = plc.inner_anchor_pc;
                                self.pending_link_provenance = .{
                                    .link_terminal = .{
                                        .path = pathFromFrames(&self.frames, self.inline_depth),
                                        .inline_depth = self.inline_depth,
                                        .source_proto_id = self.cur_proto_id,
                                        .source_pc = self.cur_pc -| 1, // the for_loop opcode
                                    },
                                };
                                self.close_requested = true;
                                self.clearPendingLinkClose(.linked);
                            } else {
                                // Still mismatched after one iteration — abort.
                                // The peel can't help; fall back to today's
                                // behavior (no link, eventual gate). Free the
                                // rewind state and clear BEFORE abort so the
                                // abort-rewind catch doesn't fire (the peel
                                // completed; rewind would be wrong).
                                self.clearPendingLinkClose(.type_mismatch);
                                return self.abort(.type_instability);
                            }
                        } else {
                            // One-trip inner loop: the body ran once but no
                            // iteration 2 exists. Clear the peel and continue
                            // recording past the loop — may produce a useful
                            // one-trip-specialized continuation trace.
                            self.clearPendingLinkClose(.one_trip);
                        }
                    },
                }
            }
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
    /// **P2 (the critical hand-off invariant, doc 15).** The link hand-off must
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
    pub fn recForPrepLink(self: *RecordingSession, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
        // Doc 47 increment A: a pending link peel forbids nested inner for-loops
        // (a nested for_prep inside the peeled body is too complex for v1).
        if (self.pending_link_close != null) return self.abort(.nyi_opcode);
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
            if (!within or self.inline_depth > 0) {
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
        // back-edge target. A `.head` root (doc 44) is root-like here: its body's
        // loops record their own root traces.
        if (self.kind == .root or self.kind == .head) return self.abort(.nyi_opcode);
        // Doc 44 D12b: a `.cont` recording never links and never enters a
        // running loop — straight-line-to-terminal v1, fail-closed.
        if (self.kind == .cont) return self.abort(.cont_backedge);

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
        if (!self.context.inner_root) return self.abort(.nyi_opcode);

        // Doc 47 increment A: check whether the current register state matches the
        // inner root's entry guards. If it does, use the existing immediate `.link`
        // close. If not — and the mismatch is int→float promotable — take the
        // record-through path and peel one inner iteration to promote types.
        // The inner root's entry state is the P2 hand-off above: `R[a]` and
        // `R[a+3]` both hold `(init − step) + step`.
        const inner_guards = self.context.inner_root_guards;
        if (!self.precise and self.pending_link_close == null and inner_guards.len > 0) {
            const vfirst = arith.add(arith.sub(vinit, vstep) catch return self.abort(.bad_type), vstep) catch return self.abort(.bad_type);
            const entry: ForEntryView = .{ .regs = regs, .a = a, .next = vfirst };
            const compatible = entryGuardsMatch(inner_guards, entry);
            if (!compatible and entryGuardsMismatchPromotable(inner_guards, entry)) {
                // Promotable int→float mismatch: record `for_prep` as arithmetic
                // (like zero-trip / inline_depth>0) and peel one inner iteration.
                // Save rewind state BEFORE emitting any IR so that a mid-body
                // abort can truncate back and close `.link` immediately.
                const n_regs = self.anchor_num_registers;
                // Doc 56 §4.2: commit this bytecode's boundary snapshot now —
                // the scratch is overwritten by the peel's bytecodes, and a
                // rewind re-emits this bytecode's guards, which resume here.
                try self.commitExitSnap();
                // OOM propagates: `record` aborts the recording (`.alloc`).
                // Returning quietly instead would skip recording this
                // `for_prep` entirely while the recording stays active (codex
                // Phase Q review) — no peel state exists yet to unwind.
                const contract = try self.gpa.dupe(trace_code.EntryGuard, inner_guards);
                errdefer self.gpa.free(contract);
                const saved_regs = try self.gpa.dupe(RegSlot, self.reg_map[0..n_regs]);
                errdefer self.gpa.free(saved_regs);
                const rewind_ir = @as(u32, @intCast(self.instrs.items.len));
                const rewind_es = @as(u32, @intCast(self.entry_slots.items.len));
                const rinit0 = try self.refOf(a);
                const rlimit0 = try self.refOf(a + 1);
                const rstep0 = try self.refOf(a + 2);
                try self.guardNum(rinit0, vinit, .operand_type, .a);
                try self.guardNum(rlimit0, vlimit, .operand_type, .a1);
                try self.guardNum(rstep0, vstep, .operand_type, .a2);
                const rsub = try self.emit(.{ .op = .sub, .a = rinit0, .b = rstep0, .ty = arithResultType(.sub, vinit, vstep) });
                self.setReg(a, rsub);
                self.pending_link_close = .{
                    .inner_anchor_pc = inner_anchor,
                    .for_loop_pc = fl_pc,
                    .contract = contract,
                    .phase = .await_initial_entry,
                    .ir_rewind_len = rewind_ir,
                    .entry_slots_rewind_len = rewind_es,
                    .for_prep_slot = a,
                    .vinit = vinit,
                    .vlimit = vlimit,
                    .vstep = vstep,
                    .for_prep_pc = pc,
                    .saved_proto_id = self.cur_proto_id,
                    .saved_global_seed = self.recorded_global_seed,
                    .saved_global_store = self.recorded_global_store,
                    .saved_reg_map = saved_regs,
                    .saved_snap_mark = if (self.snap_builder_init) self.snap_builder.mark() else .{ .records = 0, .slots = 0, .vectors = 0 },
                    .saved_ord = self.cur_ord,
                    .saved_ord_overflow = self.exit_ord_overflow,
                    .saved_snap_exhausted = self.exit_snap_exhausted,
                    .saved_by_ord_len = @intCast(self.exit_snap_by_ord.items.len),
                };
                self.link_peel_setups +|= 1;
                return;
            }
        }

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

        // Doc 45 D6 (P2): a PRECISE candidate never closes `.link` — no link
        // OUT of a precise page (the chain machinery has no precise-exit
        // consumer, and a `.link` tail would make this page selectable by
        // `findLinkTrace`'s structural predicate). Ordinary admission
        // refusal; constructing outers with inner loops stay tier-0 until
        // their own phase (P3+) lands a precise link contract.
        if (self.precise) return self.abort(.nyi_opcode);
        // Close with the `.link` terminator (commit reads `link_target`). closeTrace
        // commits + clears `active`; a build failure gates the anchor, like any abort.
        // A-i.4: stamp the `.link` terminal's provenance (edge 2). `for_prep` is the
        // owning guest opcode, so `source_pc = pc − 1` (= `cur_pc − 1`, this recorded
        // op), and `inline_depth == 0` here (the guard at the top of this fn aborts any
        // inlined `for_prep`), so the path prefix is empty. Set together with
        // `link_target` so the commit-time ⇔ invariant holds by construction.
        self.link_target = inner_anchor;
        self.pending_link_provenance = .{ .link_terminal = .{
            .path = pathFromFrames(&self.frames, self.inline_depth),
            .inline_depth = self.inline_depth,
            .source_proto_id = self.cur_proto_id,
            .source_pc = self.cur_pc -| 1,
        } };
        self.close_requested = true;
    }

    /// Doc 56 Phase 3: tag a `.link` close made into the loop whose header (body
    /// start) is `target`. The loop contains this recording's anchor exactly
    /// when the anchor lies inside the loop's static extent (loops nest
    /// properly), and then one run to the `.link` finishes one iteration of it.
    ///
    /// Doc 58 (review r2 finding 6): the extent comes from
    /// `bytecode.loopExtentFor`, not from "header .. back-edge pc" — for the
    /// two marker kinds the back-edge sits at the TOP of the loop, and a
    /// `while`'s condition sits BELOW its header, so a pc-ordering test on the
    /// header alone would misclassify both. No extent (ambiguous or malformed)
    /// fails closed to `.inner_root`, the conservative answer: it credits no
    /// enclosing iteration.
    ///
    /// Only called at inline depth 0, so `target` is an anchor-proto pc like
    /// `anchor.pc` (a `.continuation` anchor is a raw pc).
    fn linkKindAt(self: *const RecordingSession, proto: *const Proto, target: u32) trace_ir.LinkKind {
        std.debug.assert(self.inline_depth == 0);
        const a = self.anchor.pc;
        const ext = bytecode.loopExtentFor(proto, target) orelse return .inner_root;
        return if (ext.start <= a and a <= ext.end) .enclosing_iteration else .inner_root;
    }

    /// Doc 58 — nested `while`/`repeat` loop linking, at the loop's `loop`
    /// marker (LuaJIT `rec_loop_jit` on `JLOOP`, `rec_loop_interp` on `LOOP`).
    /// This is doc 38's `recWhileLink` re-keyed: the decision now happens where
    /// the inner loop is ENTERED — its marker, whose header is the body start —
    /// instead of at the backward `jmp` that closed it, which is no longer a
    /// back-edge and records nothing.
    ///
    /// When a continuation/side recording reaches an inner loop's marker and a
    /// `.loop` root trace exists at its header, the recording closes with a
    /// `.link` terminal to that root — the numeric-for pattern from
    /// `recForPrepLink`, but simpler: no pre-decrement arithmetic and no
    /// explicit bounds guard. The inner loop's condition has already been
    /// recorded as an ordinary guard before the marker is reached, so a
    /// zero-trip arrival never gets here at all (the guard's other direction
    /// leaves the loop, and the recording simply continues past it — LuaJIT's
    /// "a side trace continues across a loop that is left or not entered").
    ///
    /// Root recordings abort LINNER (matching `recForPrepLink` and LuaJIT's
    /// `rec_loop_jit` root gate): the inner loop must spawn its own root first.
    ///
    /// Our own anchor's marker, OOB markers, and markers at inline depth > 0
    /// are silently ignored (the marker stays a no-op).
    pub fn recLoopLink(self: *RecordingSession, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
        std.debug.assert(instr.op == .loop);
        // `pc` is the post-increment cursor — the instruction after the marker,
        // which IS the loop header (`bytecode.loopHeaderOf`).
        if (pc >= proto.code.len) return; // marker at end-of-code → no-op
        const target: u32 = pc;

        // Our own loop: reaching the marker again means the iteration closed,
        // which `maybeCloseAtAnchor` (called before the mirror) and `onBackEdge`
        // own — the same path `for_loop` takes. Compare the full (proto, pc)
        // pair, not just pc, to be future-proof.
        // Depth 0 only: the same (proto, pc) inside an inlined recursive call is
        // a different loop instance, unrolled like any other.
        if (self.inline_depth == 0 and self.anchor.proto == proto and target == self.anchor.pc) return;

        // Links at inline depth > 0 can't work: `driveChain` resolves
        // `link_target` in the anchor proto, not the callee's. Same constraint
        // as `recForPrepLink`. Going round the callee's loop unrolls it, so it
        // counts against `loopunroll` (G6-Q1(d)) for every kind.
        if (self.inline_depth > 0) return self.noteLoopIteration();

        // Root recordings abort LINNER — REGARDLESS of whether the inner while
        // has a root yet (LuaJIT `rec_loop_interp`: entering an inner loop in a
        // root aborts so the inner loop traces FIRST; making it conditional on
        // an existing inner root made the outcome a recording race). The
        // continuation machinery then owns the nest: doc 38's `while` leg of
        // `maybeArmContinuation` is GONE (doc 58 B2 — a `while`/`repeat`
        // condition is now an ordinary exit, and only `for_loop` arms a
        // continuation), so for those two shapes the nest re-forms through doc
        // 56's exit-side route at the post-loop pc, which records the outer body
        // and links back here. A numeric `for` still arms. Unrolling
        // instead would commit a trip-count-pinned trace that thrashes on trip
        // variance AND clogs the anchor's trace population.
        //
        // Escape hatch (LuaJIT `innerloopleft`): an inner anchor that
        // repeatedly failed to loop back (`loop_leave` aborts exhausting the
        // fast-retry budget — reason-specific, exactly like LuaJIT keys its
        // check on LLEAVE/LINNER penalties) has a low/zero remaining-trip
        // pattern; a root may then unroll it, which is strictly better than
        // both sides backing off forever. Deterministic — a pure abort count.
        if (self.kind == .root or self.kind == .head) {
            // innerloopleft: an inner that PROVED it cannot root (LLEAVE budget
            // exhausted) can only ever be unrolled — no evidence overrides this.
            // (doc 44: `.head` is root-like — same policy, same escape hatch.)
            if (self.context.unroll_while) {
                self.unrolled_while = true;
                // LuaJIT bounds this unrolling too (`--J->loopunroll < 0` in
                // the root arm of `rec_loop_interp`). An abort here carries
                // `unrolled_while`, so it feeds the outer anchor's
                // `unroll_fail` evidence like any dying unrolled root.
                return self.noteLoopIteration();
            }
            return self.abort(.nyi_opcode); // LINNER → inner root + link
        }
        // Doc 44 D12b: a `.cont` recording never links and never unrolls a
        // while — any backward jmp aborts (straight-line-to-terminal v1).
        if (self.kind == .cont) return self.abort(.cont_backedge);

        // Side/continuation recordings: no inner root yet → unroll this
        // iteration (bounded by `loopunroll`, G6-Q1(d)). The inner while warms
        // up via `onBackEdge` and spawns its own root; a later continuation
        // then links here.
        if (!self.context.inner_root) return self.noteLoopIteration();

        // Doc 45 D6 (P2): no `.link` close on a PRECISE candidate (see
        // `recForPrepLink` — same refusal, same rationale).
        if (self.precise) return self.abort(.nyi_opcode);
        // The root's entry contract, exactly as `recForLoop`'s link close
        // checks it (doc 58 B2 review should-fix 4): never into a PEELED root
        // (its entry guards are its run-once iteration's types, doc 56 review
        // finding 5), and only when the live registers already satisfy its
        // entry guards. A link the root's prologue would refuse is a hop that
        // fails before the body; the body-start link point makes that easy to
        // reach (a reset int arriving at a root specialised for a later float
        // trip). Otherwise keep recording into the loop, as with no root.
        if (self.context.inner_root_peeled or
            !entryGuardsMatch(self.context.inner_root_guards, regs)) return self.noteLoopIteration();
        // Close with a `.link` terminal to the inner while root. The φ writeback
        // in `commit()` ensures all modified slots are flushed; unmodified slots
        // remain coherent in the physical register file.
        self.link_target = target;
        self.link_kind = self.linkKindAt(proto, target);
        self.pending_link_provenance = .{ .link_terminal = .{
            .path = pathFromFrames(&self.frames, self.inline_depth),
            .inline_depth = self.inline_depth,
            .source_proto_id = self.cur_proto_id,
            .source_pc = self.cur_pc -| 1,
        } };
        self.close_requested = true;
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
    pub fn recCall(self: *RecordingSession, instr: Instr, regs: RegWindow, proto: *const Proto, multret: ?u32) !void {
        // Doc 47 increment A: a pending link peel forbids inlined calls (v1
        // conservative — sparse's inner body has no calls; a future version
        // may allow balanced loop-free inlined calls).
        if (self.pending_link_close != null) return self.abort(.nyi_opcode);
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
        // Doc 44 P0: a depth-0 DIRECT self-call in a `.head` recording closes
        // the trace — the staged up-recursion analogue. Closed BEFORE any
        // guard is emitted: on the terminal exit tier-0 re-executes the call
        // generically, so no callee pin is needed (a different callee at this
        // pc at run time simply gets called normally — correct either way).
        // A dynamic argument window is refused: the re-executed call would
        // read `reg_top` state that trace execution never maintains (the
        // multret shadow is a RECORD-time resolution only).
        // (Doc 44 D12b: `.cont` inherits the same close — a depth-0 direct
        // call of the anchor proto, i.e. the caller recursing, terminates
        // the continuation one-shot exactly like the head's.)
        if (isOneShotKind(self.kind) and self.inline_depth == 0 and cp == self.anchor.proto) {
            if (instr.b == bytecode.all_results) return self.abort(.nyi_opcode);
            return self.closeHeadTerminal(.self_call_interp);
        }
        // Doc 45 D1/D3: precise mode records NO inlined frames — snapshots
        // describe the anchor activation only, and no call may be inlined once
        // precision is required (a checked admission boundary, not a fallback).
        // The depth-zero terminal self-call above is real frame motion, not an
        // inline, and stays supported.
        if (self.precise) return self.abort(.nyi_opcode);
        // A vararg callee's extra-args frame cursor isn't modelled on the trace.
        if (cp.is_vararg) return self.abort(.cross_frame);
        if (self.inline_depth >= MAX_INLINE_DEPTH) return self.abort(.too_deep);

        // Callee window starts `caller_proto.num_registers` above the current
        // frame's base — exactly tier-0's `callee_base = base + caller.num_registers`,
        // in the recorder's anchor-relative `base_off` space. `proto` here is the
        // *caller* proto (the frame the `.call` executes in).
        const callee_base_off: u32 = self.base_off + proto.num_registers;
        if (@as(usize, callee_base_off) + cp.num_registers > self.reg_map.len)
            return self.abort(.frame_bounds);
        // Doc 61 P1: a dynamic argument span past the caller window makes
        // tier-0 lay the callee above the span instead, and the native inline
        // push hard-codes `base + nreg`. Leave that rare shape to tier-0.
        if (@as(u32, instr.a) + 1 + nargs > proto.num_registers)
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
        self.frames[self.inline_depth] = .{
            .base_off = self.base_off,
            .ret_dest = instr.a,
            .ret_count = instr.c,
            .caller_proto_id = proto.id,
            .call_pc = self.cur_pc - 1,
        };
        self.inline_depth += 1;
        self.base_off = callee_base_off;
    }

    /// Dispatch a `.call` whose callee is a `RecordedBuiltin`-tagged native to
    /// its per-builtin recorder arm (doc 23 D1 — mahina's `recff_idmap`). The
    /// common preamble here rejects dynamic windows once; each arm owns its own
    /// arity (`instr.b`), result-count (`instr.c`), and observed-shape abort
    /// matrix. Arms whose recorder has not landed yet abort `.host_barrier`,
    /// byte-identical to the untagged path — a registry row only gains its
    /// `.recorded` tag together with its arm, so those prongs are unreachable
    /// until then and exist to keep the switch exhaustive as the enum grows.
    pub fn recBuiltin(self: *RecordingSession, rb: function.RecordedBuiltin, instr: Instr, regs: RegWindow, multret: ?u32) !void {
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
                // Doc 43 P4: assert returns ALL its arguments (variable-result
                // like select), so a dynamic result window is excluded too.
                .codepoint, .select, .find, .match, .gmatch_iter, .assert => return self.abort(.cross_frame),
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
            .assert => try self.recBAssert(eff, regs),
        }
        // Doc 45 D2: a snapshot boundary cannot carry dynamic multret state —
        // precise mode refuses the shadow's producer outright, fail-closed.
        if (was_dynamic_c and self.active and self.precise)
            return self.abort(.nyi_opcode);
        // D1 publish — only a LIVE recording may leave a shadow (an aborting arm
        // set `rec.active = false`; §3a truthfulness: set only by a successfully
        // recorded producer).
        if (was_dynamic_c and self.active)
            self.multret_top = @as(u32, eff.a) + 1;
    }

    /// `math.type(v)` — konst fold under the same pins as `type()` (doc 24
    /// ride-along): a numeric argument's `guardNum` pin decides
    /// "integer"/"float" (the pin is exactly the query!), a pinned
    /// table/native/closure folds `nil` (Value.nil needs no interning), and
    /// a nil/bool input is value-specialized (doc 57) and folds `nil` too, and
    /// the pin-less observations (a non-konst string) abort as in `recBType`.
    /// Never allocates: string results via `foldInternedStr`.
    pub fn recBMType(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .mtype);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const argv = regs.get(arg_slot);
        const arg_ref = try self.refOf(arg_slot);
        if (self.konstValueOf(arg_ref) == null) {
            if (argv.isNumber()) {
                try self.guardNum(arg_ref, argv, .operand_type, .a1);
            } else if ((try self.pinPrim(arg_ref, argv, .a1)) != null or self.boolTyped(arg_ref)) {
                // Doc 57: a nil/bool input is value-specialized, and a typed
                // bool producer is always a bool — either way the result is
                // fixed.
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
                    if (!self.guarded_refs.contains(arg_ref)) {
                        const gref = try self.emit(.{ .op = .guard_func, .a = arg_ref, .aux = @bitCast(cl.proto.id) });
                        try self.guarded_refs.put(self.gpa, arg_ref, @intCast(gref));
                        self.stampProv(gref, .callee_identity, .a1, .neutral);
                    }
                },
                else => return self.abort(.bad_type),
            } else return self.abort(.bad_type);
        }
        if (!self.active) return;
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
    pub fn konstValueOf(self: *const RecordingSession, ref: Ref) ?Value {
        const ins = self.instrs.items[@intCast(ref)];
        if (ins.op != .konst) return null;
        return self.consts.items[@intCast(ins.aux)];
    }

    /// Fold an interned-string result: konst ref for `bytes`'s already-interned
    /// string, or null when it is not interned yet or no heap channel exists
    /// (bare test harness) — callers abort `.bad_type` and recording retries
    /// later, by which time tier-0 has interned the value. NEVER interns.
    pub fn foldInternedStr(self: *RecordingSession, bytes: []const u8) !?Ref {
        const heap = self.context.heap orelse return null;
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
    pub fn recBType(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .type);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const argv = regs.get(arg_slot);
        const arg_ref = try self.refOf(arg_slot);
        if (self.konstValueOf(arg_ref) == null) {
            if (argv.isNumber()) {
                try self.guardNum(arg_ref, argv, .operand_type, .a1);
            } else if ((try self.pinPrim(arg_ref, argv, .a1)) != null or self.boolTyped(arg_ref)) {
                // Doc 57: a nil/bool input is value-specialized, and a typed
                // bool producer is always a bool — either way the result is
                // fixed.
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
                    if (!self.guarded_refs.contains(arg_ref)) {
                        const gref = try self.emit(.{ .op = .guard_func, .a = arg_ref, .aux = @bitCast(cl.proto.id) });
                        try self.guarded_refs.put(self.gpa, arg_ref, @intCast(gref));
                        self.stampProv(gref, .callee_identity, .a1, .neutral);
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
    pub fn recBTostring(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        // Doc 57: a nil/bool input is value-specialized, so it takes the konst
        // fold below ("true"/"false"/"nil").
        const arg_raw = try self.refOf(arg_slot);
        const arg_ref = (try self.pinPrim(arg_raw, regs.get(arg_slot), .a1)) orelse arg_raw;
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
    pub fn isProvenStringRef(self: *const RecordingSession, r: Ref) bool {
        return switch (self.instrs.items[@intCast(r)].op) {
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
    pub fn stringArgRef(self: *RecordingSession, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?Ref {
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
    pub fn intArgRef(self: *RecordingSession, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?Ref {
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
    pub fn recBSLen(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBSSub(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBSRev(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .reverse);
        const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .srev, .a = sref, .ty = .heap }));
    }

    /// 1-argument `string.char(c)` → `schar1`. The variadic shape aborts
    /// (`IrInstr` carries no operand vector — codex #4). Range failure is a
    /// side-exit at run time, not a record-time concern.
    pub fn recBSChar1(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        if (instr.b != 1) return self.abort(.cross_frame);
        if (instr.c != 1) return self.abort(.cross_frame);
        try self.guardBuiltinCallee(instr.a, .char);
        const cref = (try self.intArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .schar1, .a = cref, .ty = .heap }));
    }

    /// 2-argument `string.rep(s, n)` → `srep2`. A separator argument aborts
    /// (pinned arity, codex #4) — tier-0 owns the 3-arg shape.
    pub fn recBSRep2(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBSCase(self: *RecordingSession, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
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
    pub fn recBSCodepoint(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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

    pub const PatternPin = struct { ref: Ref, str: *const string_mod.String };

    /// P1: pin the pattern argument. A konst interned string passes ref-
    /// through (bytes from the pool value); an observed runtime string gets
    /// the interned-identity pin — `guard_string` for the dominating type
    /// proof (unless the producer already proves it) plus `guard_sid` against
    /// the pattern's konst-pool entry (§2a: equal bytes ⇔ same object within
    /// a heap, so identity pins content — a cached-in-a-local pattern records
    /// as well as a literal). Anything else aborts; tier-0 owns coercions.
    /// Null = aborted (the `stringArgRef` convention).
    pub fn patternArgPin(self: *RecordingSession, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?PatternPin {
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
        const pool_id = self.instrs.items[@intCast(pk)].aux;
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
    pub fn projectCaptures(self: *RecordingSession, m: Ref, base: usize, first: usize, census: pattern_mod.Census, nwanted: usize) !void {
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
    pub fn recBSFind(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBSMatch(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBSGmatchIter(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
        for (self.pending_stores.items) |ps| {
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
        const pool_id = self.instrs.items[@intCast(pk)].aux;
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
        // Doc 45 D3: no sunk stores on a precise candidate (see astore).
        if (self.precise) return self.abort(.nyi_opcode);
        try self.pending_stores.append(self.gpa, .{ .op = .sgm_setpos, .aref = state_ref, .value = np, .lane_ord = 0, .ord = self.cur_ord });
    }

    /// `tonumber(v[, base])` — konst arguments fold at record time through
    /// `arith.toNumber`, the ONE conversion core shared with tier-0's
    /// `bToNumber` (so the fold and the builtin can never disagree); the result
    /// is an int/float/nil konst, never an interned string. A non-konst
    /// observed-*number* 1-arg call is the identity: pin with `guardNum` and
    /// pass the ref through. Everything else (non-konst strings — a guarded
    /// runtime parse — and dynamic bases) aborts; tier-0 owns it.
    pub fn recBTonumber(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBSelect(self: *RecordingSession, instr: Instr) !void {
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

    /// `assert(v[, message, ...])` — doc 43 P4. mahina cannot do LuaJIT's
    /// zero-IR version (our refs don't carry nil/false-excluding types), but
    /// one deduped truthiness pin is close. The observed `v` was truthy — a
    /// falsy one raises, and the raise is a trace barrier, so that observation
    /// aborts fail-closed here. The pin per observed shape mirrors the branch
    /// recorder's folds: a truthy konst and a proven-string ref are tautologies
    /// (emit nothing); an observed NUMBER pins its type via `guardNum` — every
    /// int/float is truthy (0 and 0.0 included), so the tag pin IS the
    /// truthiness pin, and native models it where a `guard_true` on a float
    /// kind would bail; an observed bool emits `guard_true` (both tiers lower
    /// it). Other heap shapes abort in v1 (a type pin there is not a
    /// worthwhile tautology yet). Results: assert returns ALL its arguments —
    /// a fixed `c` copies `min(nargs, c)` argument REFS to the destination
    /// window and nil-pads the remainder; the statement form (`c == 0`, the
    /// array3d shape) copies nothing; `c == all_results` was excluded upstream
    /// (the `select` list). The message argument is evaluated but never
    /// guarded — it is observed only on the error path, a side-exit by
    /// construction.
    pub fn recBAssert(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        if (instr.b < 1) return self.abort(.cross_frame); // `assert()` raises — barrier
        const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
        const ra = try self.refOf(arg_slot);
        const argv = regs.get(arg_slot);
        if (!argv.isTruthy()) return self.abort(.cross_frame); // THIS call raises — barrier
        try self.guardBuiltinCallee(instr.a, .assert);
        if (self.konstValueOf(ra)) |_| {
            // konst: truthiness fixed forever; observed truthy → tautology.
        } else if (self.isProvenStringRef(ra)) {
            // a reachable string ref is never nil/false → tautology.
        } else if (argv.isInt() or argv.isFloat()) {
            try self.guardNum(ra, argv, .operand_type, .a1);
        } else if (argv.isBool()) {
            self.stampProv(try self.emit(.{ .op = .guard_true, .a = ra }), .operand_type, .a1, .neutral);
        } else {
            return self.abort(.bad_type);
        }
        // Copy argument refs forward (dest slot a+k reads arg slot a+1+k,
        // strictly above every slot already written — no clobber), then pad.
        const nres: u32 = instr.c;
        const ncopy: u32 = @min(@as(u32, instr.b), nres);
        var k: u32 = 0;
        while (k < ncopy) : (k += 1) {
            const rsrc = try self.refOf(@intCast(@as(usize, instr.a) + 1 + k));
            self.setReg(@intCast(@as(usize, instr.a) + k), rsrc);
        }
        while (k < nres) : (k += 1) {
            self.setReg(@intCast(@as(usize, instr.a) + k), try self.konst(Value.nil()));
        }
    }

    /// `rawequal(a, b)` — the NaN-safe fold subset (doc 23 D2, codex catch #6:
    /// `Value.eql` is false for NaN==NaN, so same-ref must NOT blindly fold
    /// true). Konst×konst folds exactly; a same-ref pair folds true only once
    /// the ref is *pinned non-float* — observed table → raw `guard_table`,
    /// observed int → registered `guardNum` (pins int) — because a float (or
    /// unguarded) same-ref could be NaN on a later entry. Everything else
    /// aborts; a general value-compare op has no consumer yet.
    pub fn recBRawequal(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBRawlen(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBRawget(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recBRawset(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
        if (!self.active) return; // the shape aborted
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
    pub fn recAlenShape(self: *RecordingSession, dst: u16, tab_slot: u16, tab_od: OperandDesig, regs: RegWindow) !void {
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
    pub fn guardBuiltinCallee(self: *RecordingSession, callee_slot: u16, rb: function.RecordedBuiltin) !void {
        const callee_ref = try self.refOf(callee_slot);
        if (!self.guarded_refs.contains(callee_ref)) {
            const gref = try self.emit(.{ .op = .guard_builtin, .a = callee_ref, .aux = @intFromEnum(rb) });
            try self.guarded_refs.put(self.gpa, callee_ref, @intCast(gref));
            self.stampProv(gref, .callee_pure, .a, .neutral);
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
    pub fn recPureSqrt(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
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
    pub fn recFloatUnary(self: *RecordingSession, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
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
    pub fn recFloorCeil(self: *RecordingSession, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
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
    /// Doc 44 P0: request the one-shot close of a `.head` (or, D12b, `.cont`)
    /// recording.
    /// `cur_pc` is post-increment, so the terminating instruction's own pc —
    /// where tier-0 resumes on a successful terminal exit and executes it
    /// exactly once — is `cur_pc - 1`.
    fn closeHeadTerminal(self: *RecordingSession, kind: trace_ir.TerminalKind) void {
        std.debug.assert(isOneShotKind(self.kind) and self.inline_depth == 0);
        self.terminal_close = .{ .kind = kind, .resume_pc = self.cur_pc - 1 };
        self.close_requested = true;
    }

    pub fn recReturn(self: *RecordingSession, instr: Instr, multret: ?u32) !void {
        const d = self.inline_depth - 1;
        const fr = self.frames[d];
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
        if (@as(usize, fr.base_off) + fr.ret_dest + want > self.reg_map.len)
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
        self.base_off = fr.base_off;
        self.inline_depth = d;
        if (wants_all) self.multret_top = @as(u32, fr.ret_dest) + produced;
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
    pub fn recInputGet(self: *RecordingSession, comptime kind: InputKind, dest: u16, source: u16, resolved: Value, proto: *const Proto) !void {
        // Doc 43 §3.1 (P0a): fail closed on an OPEN upvalue cell that aliases the
        // trace-writable window. The per-entry snapshot is a copy; an on-trace
        // write to the backing register leaves it stale (confirmed tier-1a
        // miscompile). `context.upval_open` carries the cell's `loc.open` slab
        // index (null for globals / closed cells); the trace writes every slot
        // at or above the anchor base, so an index there is an alias. A cell open
        // over a frame BELOW the anchor (an outer scope the trace never writes —
        // the `local cfg; hot loop reads cfg` idiom) is index < base → safe, and
        // keeps recording. Covers both the anchor-frame and inlined-callee reads
        // (both route through here before the depth split below).
        // Doc 43 P5 read routing (any depth — recUpvalLoad splits the access
        // path itself): a read of a cell that already has an alias class (a
        // store was recorded — the read MUST see the pending value) or of a
        // scalar closed cell under the anchor's `upvalue_mutable` memo goes
        // through the per-iteration `uload` path instead of the per-entry
        // snapshot. Function/table-valued reads always stay snapshots.
        if (kind == .upvalue) {
            if (self.context.upval_cell) |cell| {
                const scalar = resolved.isInt() or resolved.isFloat() or resolved.isBool();
                if (self.upvalue_cell_classes.contains(objIdentity(&cell.header)) or
                    (self.route_upvalue_reads and scalar and !cell.isOpen()))
                    return self.recUpvalLoad(dest, source, cell, resolved);
            }
        }
        if (kind == .upvalue) {
            if (self.context.upval_open) |open_idx| {
                // Doc 53: an open cell over the trace-writable window cannot be
                // a snapshot (the P0a staleness argument stands) — but when it
                // aliases the ANCHOR frame's own window, the cell IS a tracked
                // slot and the read canonicalizes to that slot's SSA value.
                if (open_idx >= self.anchor_abs_base)
                    return self.recUpvalSlotAlias(dest, source, open_idx);
            }
        }
        // Doc 43 §3.2 (P0b): a global snapshot cannot coexist with a recorded
        // store into the globals table (the store stales the snapshot). If such
        // a store already landed this recording, fail closed; otherwise remember
        // the seed so a later globals store aborts symmetrically.
        if (kind == .global) {
            if (self.recorded_global_store) return self.abort(.aliased_input);
            self.recorded_global_seed = true;
        }
        // Inlined-callee reads resolve through the callee's closure: an upvalue
        // via `closure.upvalues[source]` (callee_upvalue), a global via the
        // CALLEE proto's constant pool — `globals.get(callee.proto.constants
        // [source])` (callee_global, doc 43 P4; the anchor proto's pool is a
        // different key set, which is why the plain `global` recipe can't be
        // reused at depth).
        if (self.inline_depth != 0) {
            // The reading frame's proto is the CALLEE's here (tier-0 executes
            // the callee), so its constant pool holds the global's key value.
            if (kind == .global) return self.recCalleeGlobal(dest, proto.constants[source], resolved);
            // kind == .upvalue at inline_depth > 0 → callee_upvalue seed.
            return self.recCalleeUpval(dest, source, resolved);
        }

        const key = (@as(u64, @intFromEnum(kind)) << 32) | source;
        if (self.input_dedup.get(key)) |ref| {
            // A repeat read of the same upvalue/global reuses the one snapshot.
            self.setReg(dest, ref);
            return;
        }
        // Cap the number of synthetic inputs a single trace may carry. The hard
        // limit is the executor window the dispatch loop must widen (checked against
        // `regCapacity` at entry); this cap bounds it cheaply and keeps a
        // pathological loop from growing the entry snapshot without bound.
        if (self.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);

        // Defensive: the synthetic slot counter is a `u16` seeded at
        // `anchor_num_registers`. A function with a near-`u16`-max register window
        // could push it to the wrap boundary; an `@intCast`-wrapped slot would fold
        // back *into* the live anchor window as a plausible in-window `slot_load`
        // that `assertWellFormed` (bound `anchor_num_registers + n_inputs`) cannot
        // catch — and `seedTraceInputs` would then clobber a live caller register.
        // Abort rather than wrap. (MAX_TRACE_INPUTS already bounds the count; this
        // bounds the *index*.)
        if (self.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

        const slot = self.next_input_slot;
        self.next_input_slot += 1;
        const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
        try self.entry_slots.append(self.gpa, slot);
        try self.input_seeds.append(self.gpa, .{ .kind = kind, .source = source, .slot = slot });
        try self.input_dedup.put(self.gpa, key, ref);
        // Doc 43 P5: remember which CELL this snapshot baked, so a later
        // `set_upval` to it aborts `.upvalue_mutable` (and memoizes the anchor)
        // instead of silently staling the read.
        if (kind == .upvalue) {
            if (self.context.upval_cell) |cell|
                try self.snapshot_read_cells.put(self.gpa, objIdentity(&cell.header), {});
        }
        // Pin a *function* callee's identity so a different proto — or a value that
        // is no longer a function — side-exits. A non-function heap invariant (e.g.
        // an upvalue table) needs no identity guard: its *type* is pinned by the
        // ordinary operand guard wherever the trace consumes it. An observed
        // SCALAR (int/float) is type-pinned right here (doc 43 P4 — LuaJIT's
        // typed-SLOAD discipline): a pure pass-through read (a value copied to a
        // φ without any computation) has no consuming guard, and native cannot
        // re-box a kind-unproven value at the φ commit. `guard()` dedups, so a
        // consumer's later guardNum on the same ref emits nothing.
        if (resolved.isHeap() and resolved.heapType() == .function) {
            const cl = function.Closure.fromHeader(resolved.asHeap());
            // Operand is the destination register `dest` (H-1c: `(callee_identity, dest)`),
            // which `recInputGet` receives as `instr.a` of the get_upval/get_global.
            self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
        } else if (resolved.isInt() or resolved.isFloat()) {
            try self.guardNum(ref, resolved, .operand_type, .a);
        }
        self.setReg(dest, ref);
    }

    /// Doc 53: canonicalize a `get_upval` whose OPEN cell aliases the ANCHOR
    /// frame's own window to the aliased slot's SSA value (the mahina flavor of
    /// LuaJIT `rec_upvalue`'s SSA redirect). Within one recording the cell and
    /// the slot are the same storage, so the lazy `refOfAbs` machinery is exact
    /// by construction — reads see prior anchor-frame stores in order, no
    /// snapshot, no IR guard. Cross-entry soundness comes from a
    /// VALIDATION-ONLY `.upvalue_slot_alias` seed: `guard_func` pins only proto
    /// id, so a same-proto closure from another live activation (whose cell
    /// aliases a DIFFERENT frame) must be caught at entry — the seed re-proves
    /// `closure_in(callee_slot).upvalues[source].loc.open == base + rel` and
    /// declines the candidate otherwise. Mid-episode the relation cannot
    /// change: the anchor never returns mid-trace, and a scope-exit close of
    /// an anchor-window cell would need an on-trace closure creation, which
    /// aborts.
    ///
    /// Fail-closed aborts (all keep the pre-doc-53 `.aliased_input` verdict):
    /// a cell over an INLINED frame's window (`rel >= anchor_num_registers` —
    /// unreachable today without on-trace closures, doc 24), and depth 0
    /// (lexically impossible: a function cannot capture its own locals as
    /// upvalues). An unresolvable callee path (computed callee) keeps
    /// `recCalleeUpval`'s `.cross_frame`.
    fn recUpvalSlotAlias(self: *RecordingSession, dest: u16, source: u16, open_idx: usize) !void {
        const rel_usize = open_idx - self.anchor_abs_base;
        if (rel_usize >= self.anchor_num_registers) return self.abort(.aliased_input);
        if (self.inline_depth == 0) return self.abort(.aliased_input);
        const rel: u16 = @intCast(rel_usize);
        const path_slot = self.upvalAccessPathSlot() orelse return self.abort(.cross_frame);
        // path_slot is a real slab slot here — the depth-0 sentinel case was
        // excluded above.
        std.debug.assert(path_slot != UPVALUE_CELL_ANCHOR);

        // Dedup the SEED only — the read itself must always re-resolve through
        // `refOfAbs` so a repeat read after an anchor-frame store to the slot
        // sees the current def (the cell IS the slot), never a cached first ref.
        const key = (@as(u64, @intFromEnum(InputKind.upvalue_slot_alias)) << 32) |
            (@as(u64, path_slot) << 16) | source;
        if (!self.input_dedup.contains(key)) {
            if (self.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);
            try self.input_seeds.append(self.gpa, .{
                .kind = .upvalue_slot_alias,
                .source = source,
                .slot = rel,
                .callee_slot = path_slot,
            });
            // The stored ref is never read back (see above); the map is used as
            // a set keyed on (kind, path, source).
            try self.input_dedup.put(self.gpa, key, 0);
        } else if (std.debug.runtime_safety) {
            // The dedup key excludes `rel`, so a repeat hit MUST re-derive the
            // same aliased slot. Today that's guaranteed by the access-path
            // invariant (same `slot_load` callee ⇒ same closure ⇒ same open
            // cell); assert it so any future widening of callee resolution or
            // on-trace closure support fails loudly here instead of silently
            // entry-validating the wrong slot (codex doc 53 review, item 1).
            for (self.input_seeds.items) |s| {
                if (s.kind == .upvalue_slot_alias and
                    s.callee_slot == path_slot and s.source == source)
                {
                    std.debug.assert(s.slot == rel);
                    break;
                }
            }
        }
        const ref = try self.refOfAbs(rel);
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
    pub fn recCalleeUpval(self: *RecordingSession, dest: u16, source: u16, resolved: Value) !void {
        // Find the callee's closure ref. The callee was at register `ret_dest` in
        // frame `inline_depth - 1` (ret_dest = instr.a of the .call that opened
        // this inline frame — Lua convention: reg A holds the callee).
        const d = self.inline_depth - 1;
        const callee_anchor_reg: usize = @as(usize, self.frames[d].base_off) + self.frames[d].ret_dest;
        if (callee_anchor_reg >= self.reg_map.len) return self.abort(.cross_frame);
        const callee_entry = self.reg_map[callee_anchor_reg];
        if (callee_entry.state == .undef) return self.abort(.cross_frame);
        const callee_ref = callee_entry.ref;

        // The callee ref must be a `slot_load` — that means the callee's closure
        // is in a known slab slot at entry time. A computed callee (aload, hload,
        // etc.) can't be re-resolved at entry, so we abort.
        const callee_ir = self.instrs.items[callee_ref];
        if (callee_ir.op != .slot_load) return self.abort(.cross_frame);
        const callee_slot: u16 = @intCast(callee_ir.aux);

        // Dedup: (callee_upvalue << 32) | (callee_slot << 16) | source.
        // Two different inlined callees might both read upvalue index 0, so the
        // key must incorporate which callee.
        const key = (@as(u64, @intFromEnum(InputKind.callee_upvalue)) << 32) |
            (@as(u64, callee_slot) << 16) | source;
        if (self.input_dedup.get(key)) |ref| {
            self.setReg(dest, ref);
            return;
        }

        if (self.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);
        if (self.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

        const slot = self.next_input_slot;
        self.next_input_slot += 1;
        const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
        try self.entry_slots.append(self.gpa, slot);
        try self.input_seeds.append(self.gpa, .{
            .kind = .callee_upvalue,
            .source = source,
            .slot = slot,
            .callee_slot = callee_slot,
        });
        try self.input_dedup.put(self.gpa, key, ref);
        // Doc 43 P5: the snapshot-vs-store staleness bar, exactly as in
        // `recInputGet`'s depth-0 arm — the context cell is the CALLEE's here
        // (tier-0 executes the callee, so `st.closure` is its closure).
        if (self.context.upval_cell) |cell|
            try self.snapshot_read_cells.put(self.gpa, objIdentity(&cell.header), {});

        // Pin a function callee's identity, or an observed scalar's type (the
        // typed-SLOAD discipline — see recInputGet; pass-through reads feeding
        // φs have no consuming guard, and the array3d iterator's y/z are
        // exactly this shape).
        if (resolved.isHeap() and resolved.heapType() == .function) {
            const cl = function.Closure.fromHeader(resolved.asHeap());
            self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
        } else if (resolved.isInt() or resolved.isFloat()) {
            try self.guardNum(ref, resolved, .operand_type, .a);
        }
        self.setReg(dest, ref);
    }

    /// Record a `get_global` inside an inlined callee (doc 43 P4 — unblocks
    /// `assert(...)` and every other global read in an inlined body). The
    /// bytecode's constant-pool index refers to the CALLEE's proto — a key set
    /// the entry seeder cannot reach — so the seed carries the key VALUE
    /// itself: the interned name string is copied into the TRACE's const pool
    /// (`ct.consts`, the `hash_cell` precedent) and `source` is its index;
    /// entry resolution is proto-free (`globals.get(ct.consts[source])`).
    /// Works for computed callees (an hload'd method) as well as slab-slot
    /// ones — the name is fixed at record time, and callee identity is pinned
    /// independently (`recCall`'s guard_func / the arm's guard_builtin). The
    /// P0b store-bar discipline already ran in `recInputGet` (kind was
    /// `.global` there). Dedup keys on the interned name's address (interned
    /// strings are VM-deduped, so two protos naming one global share it).
    pub fn recCalleeGlobal(self: *RecordingSession, dest: u16, key: Value, resolved: Value) !void {
        if (!key.isHeap() or key.heapType() != .string) return self.abort(.bad_type);
        const dkey = objIdentity(key.asHeap());
        if (self.callee_global_dedup.get(dkey)) |ref| {
            self.setReg(dest, ref);
            return;
        }

        if (self.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);
        if (self.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

        // Intern the key into the trace const pool WITHOUT emitting a `konst`
        // IR instruction (nothing on the trace reads the name; a dangling heap
        // konst would only complicate native proving).
        const const_idx: u32 = @intCast(self.consts.items.len);
        try self.consts.append(self.gpa, key);

        const slot = self.next_input_slot;
        self.next_input_slot += 1;
        const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
        try self.entry_slots.append(self.gpa, slot);
        try self.input_seeds.append(self.gpa, .{
            .kind = .callee_global,
            .source = const_idx,
            .slot = slot,
        });
        try self.callee_global_dedup.put(self.gpa, dkey, ref);

        // Pin a function value's identity, or an observed scalar's type (the
        // typed-SLOAD discipline — see recInputGet).
        if (resolved.isHeap() and resolved.heapType() == .function) {
            const cl = function.Closure.fromHeader(resolved.asHeap());
            self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
        } else if (resolved.isInt() or resolved.isFloat()) {
            try self.guardNum(ref, resolved, .operand_type, .a);
        }
        self.setReg(dest, ref);
    }

    // --- closed-cell upvalue access (doc 43 P5) -----------------------------

    /// Resolve the CURRENT frame's closure access path for an upvalue op:
    /// depth 0 → the anchor closure (`UPVALUE_CELL_ANCHOR` sentinel); depth > 0
    /// → the inlined callee's slab slot, requiring the callee ref to be a
    /// `slot_load` — the P2×P5 invariant inherited verbatim from
    /// `recCalleeUpval`: `guard_func` pins only `Proto.id`, so a COMPUTED
    /// (hload'd) callee's cells cannot be re-resolved at entry and two
    /// same-proto closures would silently swap cells. Null → caller aborts
    /// `.cross_frame`.
    fn upvalAccessPathSlot(self: *const RecordingSession) ?u16 {
        if (self.inline_depth == 0) return UPVALUE_CELL_ANCHOR;
        const d = self.inline_depth - 1;
        const callee_anchor_reg: usize = @as(usize, self.frames[d].base_off) + self.frames[d].ret_dest;
        if (callee_anchor_reg >= self.reg_map.len) return null;
        const callee_entry = self.reg_map[callee_anchor_reg];
        if (callee_entry.state == .undef) return null;
        const callee_ir = self.instrs.items[callee_entry.ref];
        if (callee_ir.op != .slot_load) return null;
        return @intCast(callee_ir.aux);
    }

    /// Get-or-create the alias class for an observed closed cell, seen through
    /// access path `(path_slot, source)`. One `uref` (and one synthetic slab
    /// slot) per distinct `*Upvalue`; a NEW path onto an EXISTING class appends
    /// a VERIFIER seed (entry re-proves the record-time MUST-alias relation),
    /// and an already-seen path appends nothing. Returns null after aborting
    /// (budget exhaustion, or the defensive same-path/different-cell case).
    fn ensureUpvalClass(self: *RecordingSession, cell: *function.Upvalue, path_slot: u16, source: u16) !?Ref {
        const addr = objIdentity(&cell.header);
        const existing = self.upvalue_cell_classes.get(addr);
        const pkey = (@as(u64, path_slot) << 16) | source;
        if (self.upvalue_path_dedup.contains(pkey)) {
            // A path is (slab slot, upvalue index); the closure in that slot is
            // fixed for the whole recording (slot_load = the entry value, and a
            // body overwrite re-maps the register to a non-slot_load ref that
            // fails the gate above), so a seen path re-resolving to a DIFFERENT
            // cell is a recorder invariant break — fail closed.
            if (existing) |uref| return uref;
            self.abort(.bad_type);
            return null;
        }
        if (self.input_seeds.items.len >= MAX_TRACE_INPUTS) {
            self.abort(.input_cap);
            return null;
        }
        if (existing) |uref| {
            // New verifier path for an existing class: same slab slot, no write.
            const slot: u16 = @intCast(self.instrs.items[@intCast(uref)].aux);
            try self.input_seeds.append(self.gpa, .{
                .kind = .upvalue_cell,
                .source = source,
                .slot = slot,
                .callee_slot = path_slot,
                .verify = true,
            });
            try self.upvalue_path_dedup.put(self.gpa, pkey, {});
            return uref;
        }
        if (self.next_input_slot == std.math.maxInt(u16)) {
            self.abort(.input_cap);
            return null;
        }
        const slot = self.next_input_slot;
        self.next_input_slot += 1;
        const uref = try self.emit(.{ .op = .uref, .aux = @intCast(slot), .ty = .unknown });
        try self.entry_slots.append(self.gpa, slot);
        try self.input_seeds.append(self.gpa, .{
            .kind = .upvalue_cell,
            .source = source,
            .slot = slot,
            .callee_slot = path_slot,
            .verify = false,
        });
        try self.upvalue_cell_classes.put(self.gpa, addr, uref);
        try self.upvalue_path_dedup.put(self.gpa, pkey, {});
        return uref;
    }

    /// Resolve a closed-cell read against the deferred-store buffer. Class
    /// identity IS cell identity (one `uref` per observed `*Upvalue`), so the
    /// alias lattice is exact: same token → MUST (forward the newest pending
    /// value), different token → NO (distinct observed cells), and there is no
    /// MAY case. Table-part stores can never alias a cell's owned `Value`.
    /// Walks newest→oldest (last-writer-wins); fail-closed on unknown store ops.
    fn forwardPendingUload(self: *RecordingSession, dst: u16, uref: Ref) bool {
        var n = self.pending_stores.items.len;
        while (n > 0) {
            n -= 1;
            const ps = self.pending_stores.items[n];
            switch (ps.op) {
                .astore, .hstore => continue,
                .ustore => {},
                else => {
                    self.abort(.bad_type);
                    return true;
                },
            }
            if (ps.aref != uref) continue;
            self.setReg(dst, ps.value);
            return true;
        }
        return false;
    }

    /// Record a closed-cell upvalue READ through the per-iteration `uload`
    /// path (instead of the per-entry snapshot). Reached when the cell's alias
    /// class already exists (a read after a recorded store MUST see the
    /// pending value), or when the anchor's `upvalue_mutable` memo routed all
    /// scalar reads here so a later `set_upval` can record. Mirrors
    /// `hashGetShape`'s load discipline: `uload ty=obs` is the fused tag pin
    /// (a bool's ONLY pin); int/float additionally get the consumer `guardNum`.
    fn recUpvalLoad(self: *RecordingSession, dest: u16, source: u16, cell: *function.Upvalue, resolved: Value) !void {
        if (cell.isOpen()) return self.abort(.nyi_opcode); // v1: closed cells only
        if (!(resolved.isInt() or resolved.isFloat() or resolved.isBool())) return self.abort(.bad_type);
        const path_slot = self.upvalAccessPathSlot() orelse return self.abort(.cross_frame);
        const uref = (try self.ensureUpvalClass(cell, path_slot, source)) orelse return;
        if (self.forwardPendingUload(dest, uref)) return;
        const rload = try self.emit(.{ .op = .uload, .a = uref, .ty = obsTypeOf(resolved) });
        self.stampProv(rload, .field_type, .loaded, .neutral);
        self.setReg(dest, rload);
        // The consumer type pin, exactly the hload discipline: int/float get a
        // deduped guardNum; a bool's strict pin IS the uload tag exit.
        if (!resolved.isBool()) try self.guardNum(rload, resolved, .field_type, .loaded);
    }

    /// Record `set_upval` — a write through a CLOSED upvalue cell (doc 43 P5,
    /// scalar values only in v1). The store follows the C1 sink discipline of
    /// `hashSetShape` (deferred below every guard when the trace has a prior
    /// heap load, so any side-exit leaves it un-executed and deopt-replay
    /// applies it exactly once), and the value-type pin is `hashSetShape`'s
    /// verbatim (guardNum for scalars, static proof for bools). Aborts:
    ///   * no resolved cell (defensive) / OPEN cell (the LuaJIT SSA-redirect
    ///     case, deferred) → `.nyi_opcode`;
    ///   * non-scalar or nil value → `.bad_type` (heap-valued stores need the
    ///     native write-barrier ABI, deferred with its own doc 43 bullet);
    ///   * the cell was already SNAPSHOT-read this recording →
    ///     `.upvalue_mutable`, memoizing the anchor so the retry routes reads
    ///     through `uload` (see the AbortReason doc);
    ///   * computed callee at depth > 0 → `.cross_frame` (the P2×P5 gate).
    pub fn recSetUpval(self: *RecordingSession, instr: Instr, regs: RegWindow) !void {
        const cell = self.context.upval_cell orelse return self.abort(.nyi_opcode);
        const vval = regs.get(instr.a);
        if (!(vval.isInt() or vval.isFloat() or vval.isBool())) return self.abort(.bad_type);
        if (cell.isOpen()) return self.abort(.nyi_opcode);
        if (self.snapshot_read_cells.contains(objIdentity(&cell.header))) return self.abort(.upvalue_mutable);
        const path_slot = self.upvalAccessPathSlot() orelse return self.abort(.cross_frame);
        var rval = try self.refOf(instr.a);
        if (vval.isBool()) {
            // Doc 57: pin an untyped input, then require a proven bool (the
            // same rule as `recHashSet`).
            if (try self.pinPrim(rval, vval, .a)) |k| rval = k;
            if (!self.boolTyped(rval)) return self.abort(.nyi_opcode);
        } else {
            try self.guardNum(rval, vval, .value_type, .a);
        }
        const uref = (try self.ensureUpvalClass(cell, path_slot, instr.b)) orelse return;
        if (self.traceHasHeapLoad()) {
            // Doc 45 D3: no sunk stores on a precise candidate (see astore).
            if (self.precise) return self.abort(.nyi_opcode);
            try self.pending_stores.append(self.gpa, .{
                .aref = uref,
                .value = rval,
                .lane_ord = 0,
                .op = .ustore,
                .ord = self.cur_ord,
            });
        } else {
            _ = try self.emit(.{ .op = .ustore, .a = uref, .b = rval });
        }
    }

    /// Doc 39: `pc` anchors a *plain while* loop — at least one plain backward
    /// `jmp` targets it, and no conditional backward jump (a repeat-until
    /// back-edge) or loop-op back-edge (`for_loop`/`tfor_loop`/`jfor_loop`)
    /// does. Pure bytecode geometry as a standalone predicate. Unmemoized: it
    /// runs at most once per anchor-return of an otherwise-eligible root
    /// recording, never on the dispatch hot path.
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
            .guard_is_nil,
            .guard_is_false,
            .guard_is_true,
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
    fn maybeEnterPeel(self: *RecordingSession, regs: RegWindow) bool {
        if (!self.options.peel) return false;
        // Doc 45 D3: no peeling on a precise candidate (snapshots assume one
        // guest-ordered stream; allocations-in-peels are an explicit deferral).
        // The eager `guard_gc_ref` below would decline it anyway — this makes
        // the policy visible rather than incidental.
        if (self.precise) return false;
        const rec = self;
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
        self.peel_notice = .{ .enter = .{ .anchor_pc = self.anchor.pc, .marker = rec.instrs.items.len - 1 } };
        return true;
    }

    /// Doc 39 Phase 1 close, at the SECOND anchor-return of a peeled recording:
    /// verify the body pass stayed register-only (a forbidden effect means
    /// iteration 2 took a path iteration 1 didn't — abort, ordinary strikes)
    /// and type-stable, then patch every internal φ's back-edge `b` from the
    /// slot's body-final ref (or `a` — a constant carry — when the body only
    /// read it). Returns false when the recording must abort
    /// `.type_instability` instead of committing.
    fn finishPeel(self: *RecordingSession, p: *PeelState) bool {
        const rec = self;
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
        self.peel_notice = .{ .close = .{ .anchor_pc = self.anchor.pc, .begin = p.mark_len, .end = rec.instrs.items.len } };
        return true;
    }

    /// Doc 57 P3: which kind of contradiction `loopCloseDefeat` found —
    /// `.numeric` if any int/float one (never fixable by another iteration,
    /// so it wins), else `.pins` if only value pins are contradicted (the
    /// close may unroll), else `.none`.
    const CloseDefeat = enum { none, pins, numeric };

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
    /// Scope (codex finding 6): proven int↔float contradictions —
    /// `guard_number` matches both numeric kinds and non-numeric carried slots
    /// have legitimate specialized load/store relationships — plus doc 57's
    /// value pins, where any carried value other than the pin contradicts
    /// (the pin is also an entry-fingerprint guard). The ENTRY side
    /// mirrors the fingerprint-extraction criteria exactly (a guard over a
    /// `slot_load` of an anchor-window slot — `matchesFingerprint` is what
    /// makes the contradiction fatal at re-entry); the STORE side reads the
    /// live anchor-return registers. Commit's φ-emission slot filter is
    /// mirrored too: a slot that gets no φ is never written at the back-edge,
    /// so its entry guard cannot be contradicted.
    fn loopCloseDefeat(self: *const RecordingSession, regs: RegWindow) CloseDefeat {
        // The live-value read below indexes the ANCHOR frame; at inline depth
        // the window belongs to a callee. Depth-0 covers every channel the
        // reset-to-int shape records through (glue side / continuation).
        if (self.inline_depth != 0) return .none;
        const finalizer = @import("trace_finalize.zig");
        var live_buf: [finalizer.PHI_LIVE_WORDS]u64 = undefined;
        const live = finalizer.phiLiveRow(self, &live_buf);
        var found: CloseDefeat = .none;
        const instrs = self.instrs.items;
        for (instrs, 0..) |ins, i| {
            switch (ins.op) {
                .guard_int, .guard_float, .guard_is_nil, .guard_is_false, .guard_is_true => {},
                else => continue,
            }
            const ref: usize = @intCast(ins.a);
            if (ref >= i or instrs[ref].op != .slot_load) continue;
            const slot: usize = @intCast(instrs[ref].aux);
            if (slot >= self.anchor_num_registers) continue;
            const s = self.reg_map[slot];
            if (s.state != .def) continue; // read-only slot: no φ, no back-edge write
            if (!finalizer.phiWritebackKept(self, @intCast(slot), live)) continue;
            // STORE side: the LIVE value at this anchor return. Recording is
            // concrete execution, so this is exactly what the φ delivers on
            // the recorded path. (The IR `ty` is useless here: an unguarded
            // `slot_load` store — the fft `k = n` reset — is `.unknown`.)
            const v = regs.get(@intCast(slot));
            switch (ins.op) {
                .guard_int => if (v.isFloat()) return .numeric,
                .guard_float => if (v.isInt()) return .numeric,
                // Doc 57 §4.3 (LuaJIT GFAIL/TYPEINS): a value-specialized input
                // must carry exactly its pin around the back-edge, or iteration
                // 2 fails the pin every time — the flipped bool (`b = not b`).
                // Whatever produced the carried value, only strict equality
                // with the pin is stable. P3 unrolls on this kind alone.
                .guard_is_nil, .guard_is_false, .guard_is_true => if (!trace_ir.primPinPasses(ins.op, v)) {
                    found = .pins;
                },
                else => unreachable,
            }
        }
        return found;
    }

    pub fn deinit(self: *RecordingSession, gpa: std.mem.Allocator) void {
        // A pending peel exists only after `reset`, which set `self.gpa`.
        self.clearPendingLinkClose(.deinit);
        if (self.peel) |p| gpa.free(p.slots);
        self.pending_stores.deinit(gpa);
        self.input_seeds.deinit(gpa);
        self.input_dedup.deinit(gpa);
        self.hash_cell_dedup.deinit(gpa);
        self.callee_global_dedup.deinit(gpa);
        self.upvalue_cell_classes.deinit(gpa);
        self.upvalue_path_dedup.deinit(gpa);
        self.snapshot_read_cells.deinit(gpa);
        self.instrs.deinit(gpa);
        self.consts.deinit(gpa);
        self.entry_slots.deinit(gpa);
        self.exit_prov.deinit(gpa);
        self.rec_path.deinit(gpa);
        self.guarded_refs.deinit(gpa);
        self.lane_pins.deinit(gpa);
        self.konst_map.deinit(gpa);
        if (self.reg_map.len != 0) gpa.free(self.reg_map);
        if (self.snap_scratch.len != 0) gpa.free(self.snap_scratch);
        if (self.snap_builder_init) self.snap_builder.deinit();
        self.exit_snap_by_ord.deinit(gpa);
        if (self.exit_undo_prev.len != 0) gpa.free(self.exit_undo_prev);
        if (self.exit_undo_stamp.len != 0) gpa.free(self.exit_undo_stamp);
        if (self.exit_def_bits.len != 0) gpa.free(self.exit_def_bits);
    }

    /// The production entry: `reset` for a VM whose `Config.debug_log` is
    /// `debug_log` (the `dbg` gate). Every `TraceState` arming path goes
    /// through here, so no recording runs with a stale gate; hand-driven
    /// recorder tests call `reset` and stay silent (the field's default).
    pub fn start(self: *RecordingSession, gpa: std.mem.Allocator, anchor: AnchorKey, num_registers: u16, debug_log: bool) !void {
        self.debug_log = debug_log;
        return self.reset(gpa, anchor, num_registers);
    }

    /// Clear the buffer and arm a fresh recording for `anchor` over a frame with
    /// `num_registers` registers. Reuses retained capacity; only (re)allocates
    /// `reg_map` when the register count changes.
    pub fn reset(self: *RecordingSession, gpa: std.mem.Allocator, anchor: AnchorKey, num_registers: u16) !void {
        self.gpa = gpa;
        self.context = .{};
        self.peel_notice = null;
        self.abort_notice = null;
        self.close_requested = false;
        self.active = false;
        self.side_src = null;
        self.multret_top = null; // doc 27 §3a: never inherit a stale shadow
        self.link_target = null;
        self.link_kind = .inner_root;
        self.terminal_close = null;
        self.pending_link_provenance = null;
        self.clearPendingLinkClose(.reset);
        self.inline_depth = 0;
        if (self.peel) |p| gpa.free(p.slots);
        self.peel = null;
        self.unroll_used = 0;
        self.unroll_mark_len = 0;
        self.loop_iterations = 0;
        self.instrs.clearRetainingCapacity();
        self.consts.clearRetainingCapacity();
        self.entry_slots.clearRetainingCapacity();
        self.exit_prov.clearRetainingCapacity();
        self.rec_path.clearRetainingCapacity();
        self.rec_path_ok = true;
        self.guarded_refs.clearRetainingCapacity();
        self.lane_pins.clearRetainingCapacity();
        self.konst_map.clearRetainingCapacity();
        self.input_seeds.clearRetainingCapacity();
        self.input_dedup.clearRetainingCapacity();
        self.hash_cell_dedup.clearRetainingCapacity();
        self.callee_global_dedup.clearRetainingCapacity();
        self.upvalue_cell_classes.clearRetainingCapacity();
        self.upvalue_path_dedup.clearRetainingCapacity();
        self.snapshot_read_cells.clearRetainingCapacity();
        self.route_upvalue_reads = false; // doc 43 P5: arm() seeds the anchor memo after reset
        self.precise = false; // doc 45 D2: arm() seeds the anchor memo after reset
        self.force_ordinary = false; // A1' (task 27): arm() sets it from the pending's policy
        self.cur_snap = 0; // doc 45 D2: no boundary exists until the first precise bytecode
        self.precise_prologue_done = false; // doc 45 D2: prologue emitted at first body instr
        self.cur_ord = 0; // doc 56 §4.2: first body bytecode opens ordinal 1
        self.exit_ord_overflow = false;
        self.exit_snap_exhausted = false;
        self.exit_snap_pending = false;
        self.exit_snap_by_ord.clearRetainingCapacity();
        self.pending_stores.clearRetainingCapacity();
        self.alloc_count = 0;
        self.guard_gc_ref = null;
        self.anchor_abs_base = 0; // doc 43 P0a: arm() seeds the real base after reset
        self.recorded_global_seed = false; // doc 43 P0b
        self.recorded_global_store = false;

        // Size the register map for the anchor frame **plus** reserved windows for
        // inlined callee frames (cross-frame tracing). The executor only ever
        // touches `[0, anchor_num_registers)`; the tail is scratch the recorder
        // uses to hold callee SSA temporaries while inlining.
        const wanted: usize = @as(usize, num_registers) + MAX_INLINE_DEPTH * MAX_CALLEE_REGS;
        if (self.reg_map.len != wanted) {
            const replacement = try gpa.alloc(RegSlot, wanted);
            if (self.reg_map.len != 0) gpa.free(self.reg_map);
            self.reg_map = replacement;
        }
        @memset(self.reg_map, .{});
        self.anchor = anchor;
        self.abort_reason = null;
        self.kind = .root;
        self.anchor_num_registers = num_registers;
        self.base_off = 0;
        self.unrolled_while = false;
        self.next_input_slot = num_registers;
        self.active = true;
    }
};

test "recorder failed resize stays inactive and retains valid storage" {
    const testing = std.testing;
    var rec: RecordingSession = .{};
    defer rec.deinit(testing.allocator);
    const anchor: AnchorKey = .{ .proto = undefined, .pc = 0 };
    try rec.reset(testing.allocator, anchor, 2);
    const old_map = rec.reg_map;
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    try testing.expectError(error.OutOfMemory, rec.reset(failing.allocator(), anchor, 3));
    try testing.expect(!rec.active);
    try testing.expectEqual(old_map.ptr, rec.reg_map.ptr);
    try rec.reset(testing.allocator, anchor, 3);
    try testing.expect(rec.active);
}

test "doc 56 §4.2: lazy exit capture snapshots the BOUNDARY binding of a slot rebound before the first guard" {
    const testing = std.testing;
    const gpa = testing.allocator;
    // Three bytecodes, every register live everywhere (a hand-built table).
    const bits = [_]u64{ 0b11, 0b11, 0b11 };
    const proto = Proto{
        .code = &.{ Instr.op0(.halt), Instr.op0(.halt), Instr.op0(.halt) },
        .name = "lazy",
        .num_registers = 2,
        .reg_live = .{ .words = 1, .bits = &bits },
    };
    var rec: RecordingSession = .{};
    defer rec.deinit(gpa);
    try rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, 2);

    // Bytecode 1 (pc 0): binds r0 = A. No guard, so no snapshot.
    try rec.exitBoundary(&proto, 1);
    const a = try rec.emit(.{ .op = .slot_load, .aux = 0 });
    rec.defineSlotAbs(0, a);
    // Bytecode 2 (pc 1): rebinds r0 = B, THEN guards. The exit resumes at
    // pc 1, where tier-0 still expects r0 = A.
    try rec.exitBoundary(&proto, 2);
    const b = try rec.emit(.{ .op = .slot_load, .aux = 1 });
    rec.defineSlotAbs(0, b);
    rec.defineSlotAbs(0, a); // a second write must not overwrite the saved binding
    rec.defineSlotAbs(0, b);
    _ = try rec.emit(.{ .op = .guard_int, .a = b });
    _ = try rec.emit(.{ .op = .guard_int, .a = b }); // same bytecode: one snapshot
    // Bytecode 3 (pc 2): no writes; guards see r0 = B.
    try rec.exitBoundary(&proto, 3);
    _ = try rec.emit(.{ .op = .guard_int, .a = b });

    try testing.expectEqual(@as(usize, 4), rec.exit_snap_by_ord.items.len);
    try testing.expectEqual(@as(trace_ir.SnapIdx, 0), rec.exit_snap_by_ord.items[1]);
    try testing.expectEqual(@as(trace_ir.SnapIdx, 1), rec.exit_snap_by_ord.items[2]);
    try testing.expectEqual(@as(trace_ir.SnapIdx, 2), rec.exit_snap_by_ord.items[3]);
    const recs = rec.snap_builder.records.items;
    try testing.expectEqual(@as(usize, 2), recs.len);
    const slots = rec.snap_builder.slots.items;
    try testing.expectEqual(@as(u32, 1), recs[0].resume_pc);
    try testing.expectEqual(@as(u32, 1), recs[0].slots_len);
    try testing.expectEqual(a, slots[recs[0].slots_begin].ref);
    try testing.expectEqual(@as(u32, 2), recs[1].resume_pc);
    try testing.expectEqual(b, slots[recs[1].slots_begin].ref);
    // Every op carries its bytecode's ordinal.
    try testing.expectEqual(@as(u16, 1), rec.instrs.items[@intCast(a)].ord);
    try testing.expectEqual(@as(u16, 2), rec.instrs.items[@intCast(b)].ord);
}

test "doc 56 §4.2: a dead slot stays out of the snapshot; no liveness table means no snapshots" {
    const testing = std.testing;
    const gpa = testing.allocator;
    // r1 is dead at pc 1 (bit clear), r0 live.
    const bits = [_]u64{ 0b11, 0b01 };
    const proto = Proto{
        .code = &.{ Instr.op0(.halt), Instr.op0(.halt) },
        .name = "dead",
        .num_registers = 2,
        .reg_live = .{ .words = 1, .bits = &bits },
        .maskable = true,
    };
    var rec: RecordingSession = .{};
    defer rec.deinit(gpa);
    try rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, 2);
    try rec.exitBoundary(&proto, 1);
    const x = try rec.emit(.{ .op = .slot_load, .aux = 0 });
    rec.defineSlotAbs(0, x);
    rec.defineSlotAbs(1, x);
    try rec.exitBoundary(&proto, 2);
    _ = try rec.emit(.{ .op = .guard_int, .a = x });
    const recs = rec.snap_builder.records.items;
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqual(@as(u32, 1), recs[0].slots_len);
    try testing.expectEqual(@as(u16, 0), rec.snap_builder.slots.items[recs[0].slots_begin].slot);

    // Doc 61 §5 (site 3): the same table on a proto that is not maskable.
    // The collector roots its frames whole, so the snapshot must keep the
    // dead `.def` slot r1 too.
    var unmasked = proto;
    unmasked.maskable = false;
    try rec.reset(gpa, .{ .proto = &unmasked, .pc = 0 }, 2);
    try rec.exitBoundary(&unmasked, 1);
    const w = try rec.emit(.{ .op = .slot_load, .aux = 0 });
    rec.defineSlotAbs(0, w);
    rec.defineSlotAbs(1, w);
    try rec.exitBoundary(&unmasked, 2);
    _ = try rec.emit(.{ .op = .guard_int, .a = w });
    const all = rec.snap_builder.records.items;
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqual(@as(u32, 2), all[0].slots_len);
    try testing.expectEqual(@as(u16, 1), rec.snap_builder.slots.items[all[0].slots_begin + 1].slot);

    // A budget-refused commit latches: later guarded bytecodes skip capture.
    try rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, 2);
    rec.options.snapshot_budget = .{ .max_records = 1 };
    try rec.exitBoundary(&proto, 1);
    const z = try rec.emit(.{ .op = .slot_load, .aux = 0 });
    rec.defineSlotAbs(0, z);
    _ = try rec.emit(.{ .op = .guard_int, .a = z }); // record 1: fits
    try rec.exitBoundary(&proto, 2);
    _ = try rec.emit(.{ .op = .guard_int, .a = z }); // refused → latch
    try testing.expect(rec.exit_snap_exhausted);
    try rec.exitBoundary(&proto, 2);
    try testing.expect(!rec.exit_snap_pending);
    try testing.expectEqual(@as(usize, 1), rec.snap_builder.records.items.len);

    // The same shape on a proto without a table: ordinals, but no snapshot.
    rec.options.snapshot_budget = .{};
    const bare = Proto{ .code = proto.code, .name = "bare", .num_registers = 2 };
    try rec.reset(gpa, .{ .proto = &bare, .pc = 0 }, 2);
    try rec.exitBoundary(&bare, 1);
    const y = try rec.emit(.{ .op = .slot_load, .aux = 0 });
    rec.defineSlotAbs(0, y);
    _ = try rec.emit(.{ .op = .guard_int, .a = y });
    try testing.expectEqual(@as(usize, 0), rec.snap_builder.records.items.len);
    try testing.expectEqual(@as(u16, 1), rec.cur_ord);
}

test "doc 57 P3: enterUnroll spends its budget and refuses precise or inlined recordings" {
    const testing = std.testing;
    var s: RecordingSession = .{};
    defer s.deinit(testing.allocator);
    const proto = Proto{ .code = &.{}, .id = 1, .name = "unroll", .num_registers = 1 };
    const key: AnchorKey = .{ .proto = &proto, .pc = 0 };

    try s.reset(testing.allocator, key, 1);
    s.options.instunroll = 2;
    s.cur_op = .jmp; // a `while` arrival: nothing to re-mark
    try testing.expect(s.enterUnroll());
    try testing.expectEqual(@as(u8, 1), s.unroll_used);
    _ = try s.emit(.{ .op = .konst }); // the next iteration records something
    try testing.expect(s.enterUnroll());
    try testing.expectEqual(s.instrs.items.len, s.unroll_mark_len);
    try testing.expect(!s.enterUnroll()); // budget spent
    try testing.expectEqual(@as(u8, 2), s.unroll_used);

    // `reset` starts every recording with a fresh budget.
    try s.reset(testing.allocator, key, 1);
    try testing.expectEqual(@as(u8, 0), s.unroll_used);
    try testing.expectEqual(@as(usize, 0), s.unroll_mark_len);

    // Budget 0 = the pre-P3 abort.
    s.options.instunroll = 0;
    try testing.expect(!s.enterUnroll());

    // A precise recording keeps its one-iteration snapshot contract.
    try s.reset(testing.allocator, key, 1);
    s.options.instunroll = 4;
    s.precise = true;
    try testing.expect(!s.enterUnroll());

    // A close inside an inlined frame never unrolls.
    try s.reset(testing.allocator, key, 1);
    s.inline_depth = 1;
    try testing.expect(!s.enterUnroll());
    s.inline_depth = 0;
    try testing.expect(s.enterUnroll());
}

test "session abort snapshot is consumed exactly once" {
    const testing = std.testing;
    var session: RecordingSession = .{};
    defer session.deinit(testing.allocator);
    try session.reset(testing.allocator, .{ .proto = undefined, .pc = 19 }, 0);
    session.abort(.type_instability);
    session.anchor.pc = 27;
    const notice = session.takeAbortNotice().?;
    try testing.expectEqual(@as(u32, 19), notice.anchor.pc);
    try testing.expectEqual(AbortReason.type_instability, notice.reason);
    try testing.expect(session.takeAbortNotice() == null);
    try testing.expect(!session.active);
    try testing.expectError(error.InactiveRecording, session.finalize());
}

test "session candidate survives reset and session teardown" {
    const testing = std.testing;
    var session: RecordingSession = .{};
    const proto = Proto{ .code = &.{}, .id = 1, .name = "session", .num_registers = 0 };
    try session.reset(testing.allocator, .{ .proto = &proto, .pc = 0 }, 0);
    session.options.optimize = false;
    var candidate = try session.finalize();
    defer candidate.deinit(testing.allocator);
    try testing.expectError(error.InactiveRecording, session.finalize());
    try session.reset(testing.allocator, .{ .proto = &proto, .pc = 0 }, 1);
    session.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), candidate.getCode().?.instrs.len);
}

test "session failed finalization rejects recording until reset" {
    const testing = std.testing;
    var session: RecordingSession = .{};
    defer session.deinit(testing.allocator);
    const proto = Proto{ .code = &.{}, .id = 1, .name = "oom", .num_registers = 0 };
    try session.reset(testing.allocator, .{ .proto = &proto, .pc = 0 }, 0);
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    session.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, session.finalize());
    const count = session.instrs.items.len;
    session.recordInstr(undefined, undefined, undefined, 0, undefined);
    try testing.expect(!session.close(undefined));
    try testing.expectEqual(count, session.instrs.items.len);
    try testing.expectError(error.InactiveRecording, session.finalize());
    session.context.inner_root = true;
    session.context.unroll_while = true;
    try session.reset(testing.allocator, .{ .proto = &proto, .pc = 0 }, 0);
    try testing.expect(!session.context.inner_root and !session.context.unroll_while);
}

test "doc 58 B2 review: a continuation links into a while root only under its entry contract" {
    // `recLoopLink` must check the inner root's entry contract exactly as
    // `recForLoop`'s link close does: never into a peeled root, and only when
    // the live registers satisfy its entry guards. (It used to discard the
    // registers and link unconditionally — a hop the root's prologue then
    // refuses on every run.)
    const testing = std.testing;
    const bc = @import("bytecode.zig");
    const marker: Instr = .{ .op = .loop, .b = @intFromEnum(bc.LoopKind.while_loop), .aux = 2 };
    // `C: load_bool; jmp_if_false → E; loop; body (header 3); jmp → C; E: ret`.
    const code = [_]Instr{
        Instr.opA(.load_bool, 0),    Instr.opAx(.jmp_if_false, 0, 3), marker,
        Instr.opAx(.load_int, 1, 0), Instr.opAx(.jmp, 0, -5),          Instr.op0(.ret),
    };
    const proto = Proto{ .code = &code, .id = 1, .name = "while", .num_registers = 2 };
    const header: u32 = 3;
    // The root wants slot 1 float (it recorded a later, floated trip).
    const guards = [_]trace_code.EntryGuard{.{ .slot = 1, .ty = .float }};

    var tags = [_]u8{ 0, 0 };
    var payloads = [_]u64{ 0, 0 };
    const regs = RegWindow.of(&tags, &payloads);

    const Case = struct { slot1: Value, peeled: bool, links: bool };
    const cases = [_]Case{
        .{ .slot1 = Value.int(8), .peeled = false, .links = false }, // reset int
        .{ .slot1 = Value.float(0.5), .peeled = false, .links = true }, // compatible
        .{ .slot1 = Value.float(0.5), .peeled = true, .links = false }, // peeled root
    };
    for (cases) |cs| {
        var session: RecordingSession = .{};
        defer session.deinit(testing.allocator);
        // A continuation anchored past the loop (the post-loop pc).
        try session.reset(testing.allocator, .{ .proto = &proto, .pc = 5 }, 2);
        session.kind = .continuation;
        session.context.inner_root = true;
        session.context.inner_root_guards = &guards;
        session.context.inner_root_peeled = cs.peeled;
        regs.set(1, cs.slot1);
        try session.recLoopLink(marker, regs, &proto, header);
        try testing.expectEqual(cs.links, session.close_requested);
        try testing.expectEqual(if (cs.links) @as(?u32, header) else null, session.link_target);
    }
}

/// `for r0 = 1, 10 do <load_int r4> end` after a prologue, then `ret`:
/// `for_prep` at 3, header 4, `for_loop` at 5, post-loop pc 6.
const g6_for_code = [_]Instr{
    Instr.opAx(.load_int, 0, 1), Instr.opAx(.load_int, 1, 10), Instr.opAx(.load_int, 2, 1),
    Instr.opAx(.for_prep, 0, 1), Instr.opAx(.load_int, 4, 0),  Instr.opAx(.for_loop, 0, -2),
    Instr.op0(.ret),
};
const g6_for_loop = g6_for_code[5];
const g6_for_header: u32 = 4;

fn g6ForRegs(tags: *[5]u8, payloads: *[5]u64) RegWindow {
    const regs = RegWindow.of(tags, payloads);
    regs.set(0, Value.int(1)); // idx: 1 + 1 <= 10, the loop goes round
    regs.set(1, Value.int(10));
    regs.set(2, Value.int(1));
    return regs;
}

test "doc 56 G6-Q1(a): a side recording links into a for root at its back-edge, like a continuation" {
    const testing = std.testing;
    const proto = Proto{ .code = &g6_for_code, .id = 1, .name = "for", .num_registers = 5 };
    var tags = [_]u8{ 0, 0, 0, 0, 0 };
    var payloads = [_]u64{ 0, 0, 0, 0, 0 };
    const regs = g6ForRegs(&tags, &payloads);
    const Case = struct { kind: TraceKind, links: bool };
    for ([_]Case{ .{ .kind = .side, .links = true }, .{ .kind = .continuation, .links = true } }) |cs| {
        var session: RecordingSession = .{};
        defer session.deinit(testing.allocator);
        try session.reset(testing.allocator, .{ .proto = &proto, .pc = 6 }, 5);
        session.kind = cs.kind;
        session.context.inner_root = true;
        // `pc` is the post-increment cursor, as in `recordInstr`.
        try session.recForLoop(g6_for_loop, regs, 6);
        try testing.expectEqual(cs.links, session.close_requested);
        try testing.expectEqual(@as(?u32, g6_for_header), session.link_target);
        try testing.expectEqual(@as(u8, 0), session.loop_iterations); // a link unrolls nothing
    }
}

test "doc 56 G6-Q1(d): a recording unrolls at most loopunroll iterations of loops it cannot link, inlined ones and root escapes included" {
    const testing = std.testing;
    const bc = @import("bytecode.zig");
    const for_proto = Proto{ .code = &g6_for_code, .id = 1, .name = "for", .num_registers = 5 };
    const marker: Instr = .{ .op = .loop, .b = @intFromEnum(bc.LoopKind.while_loop), .aux = 2 };
    const while_code = [_]Instr{
        Instr.opA(.load_bool, 0),    Instr.opAx(.jmp_if_false, 0, 3), marker,
        Instr.opAx(.load_int, 1, 0), Instr.opAx(.jmp, 0, -5),          Instr.op0(.ret),
    };
    const while_proto = Proto{ .code = &while_code, .id = 2, .name = "while", .num_registers = 5 };
    var tags = [_]u8{ 0, 0, 0, 0, 0 };
    var payloads = [_]u64{ 0, 0, 0, 0, 0 };
    const regs = g6ForRegs(&tags, &payloads);

    // `inlined`: the marker sits in an inlined callee (no link is possible
    // there) — counted for every kind, roots included (codex re-review
    // should-fix 1: it used to be skipped, and a side recording unrolled an
    // inlined `while` until `too_long`). The callee is the anchor's own proto at
    // the anchor pc — a recursive instance, so the depth-0 own-anchor exemption
    // must not apply. `unroll_root`: a root on the `innerloopleft` escape
    // (`unroll_while`), LuaJIT's root-arm `LUNROLL`.
    const Shape = enum { for_loop, marker, inlined, unroll_root };
    const Case = struct { kind: TraceKind, shape: Shape };
    const cases = [_]Case{
        .{ .kind = .side, .shape = .for_loop },         .{ .kind = .continuation, .shape = .for_loop },
        .{ .kind = .side, .shape = .marker },           .{ .kind = .continuation, .shape = .marker },
        .{ .kind = .side, .shape = .inlined },          .{ .kind = .continuation, .shape = .inlined },
        .{ .kind = .root, .shape = .inlined },          .{ .kind = .root, .shape = .unroll_root },
        .{ .kind = .head, .shape = .unroll_root },
    };
    for (cases) |cs| {
        var session: RecordingSession = .{};
        defer session.deinit(testing.allocator);
        const proto = if (cs.shape == .for_loop) &for_proto else &while_proto;
        const anchor_pc: u32 = if (cs.shape == .inlined) 3 else @intCast(proto.code.len - 1);
        try session.reset(testing.allocator, .{ .proto = proto, .pc = anchor_pc }, 5);
        session.kind = cs.kind;
        session.options.loopunroll = 3;
        if (cs.shape == .inlined) session.inline_depth = 1;
        if (cs.shape == .unroll_root) session.context.unroll_while = true;
        // No root at the loop: every crossing unrolls one iteration.
        for (0..3) |_| {
            switch (cs.shape) {
                .for_loop => try session.recForLoop(g6_for_loop, regs, 6),
                .marker, .inlined, .unroll_root => try session.recLoopLink(marker, regs, &while_proto, 3),
            }
            try testing.expect(session.active);
        }
        try testing.expectEqual(@as(u8, 3), session.loop_iterations);
        switch (cs.shape) {
            .for_loop => try session.recForLoop(g6_for_loop, regs, 6),
            .marker, .inlined, .unroll_root => try session.recLoopLink(marker, regs, &while_proto, 3),
        }
        try testing.expect(!session.active);
        try testing.expectEqual(@as(?AbortReason, .loop_unroll), session.abort_reason);
        if (cs.shape == .unroll_root) try testing.expect(session.unrolled_while);
    }

    // A root without the escape still aborts LINNER at the marker, uncounted.
    var linner: RecordingSession = .{};
    defer linner.deinit(testing.allocator);
    try linner.reset(testing.allocator, .{ .proto = &while_proto, .pc = 5 }, 5);
    linner.kind = .root;
    try linner.recLoopLink(marker, regs, &while_proto, 3);
    try testing.expectEqual(@as(?AbortReason, .nyi_opcode), linner.abort_reason);
    try testing.expectEqual(@as(u8, 0), linner.loop_iterations);

    // A recording's own anchor back-edge closes the trace; it is never an
    // unrolled iteration. (A `.side` recording anchored at the loop header.)
    var own: RecordingSession = .{};
    defer own.deinit(testing.allocator);
    try own.reset(testing.allocator, .{ .proto = &for_proto, .pc = g6_for_header }, 5);
    own.kind = .side;
    own.options.loopunroll = 0;
    try own.recForLoop(g6_for_loop, regs, 6);
    try testing.expect(own.active);
    try testing.expectEqual(@as(u8, 0), own.loop_iterations);
}
