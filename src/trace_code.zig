//! Immutable, owned code payload of a committed trace.
//!
//! `TraceCode` is embedded by value in the lifecycle-owned `TraceRecord`.  Execution,
//! serialization, classification, and native lowering consume this dependency-light
//! representation and therefore do not depend on cache/native lifecycle state.

const std = @import("std");
const value = @import("value.zig");
const bytecode = @import("bytecode.zig");
const trace_ir = @import("trace_ir.zig");
const trace_snapshot = @import("trace_snapshot.zig");
const trace_types = @import("trace_types.zig");
const exit_attach = @import("trace_exit_attach.zig");
const RegWindow = @import("regwindow.zig").RegWindow;

const Value = value.Value;
const IrInstr = trace_ir.IrInstr;
const AnchorKey = trace_types.AnchorKey;
const ExitProvenance = trace_types.ExitProvenance;
const ExitProvEntry = trace_types.ExitProvEntry;
const ProgramPoint = trace_types.ProgramPoint;

/// The kind of type a trace's entry guard enforces on a register.
pub const EntryGuardType = enum(u8) {
    int,
    float,
    number, // accepts both int and float (guard_number)
    table,
    // Doc 57: value-specialized primitive pins (`guard_is_*`) — the value
    // itself, not only its type.
    nil,
    false_,
    true_,

    /// Does an entry value `v` satisfy this guard? The one definition every
    /// fingerprint check (the dispatcher's `matchesFingerprint` and the
    /// recorder's `entryGuardsMatch`/`entryGuardsMismatchPromotable`) uses.
    pub fn accepts(self: EntryGuardType, v: Value) bool {
        return switch (self) {
            .int => v.isInt(),
            .float => v.isFloat(),
            .number => v.isNumber(),
            .table => v.isHeap() and v.heapType() == .table,
            .nil => v.isNil(),
            .false_ => v.isBool() and !v.asBool(),
            .true_ => v.isBool() and v.asBool(),
        };
    }
};

/// A register and the type it must have for this trace to be entered.
/// Pairs are computed from the trace's IR at commit time and stored as a
/// runtime-only fingerprint — not serialized.
pub const EntryGuard = struct { slot: u16, ty: EntryGuardType };

/// Doc 48: record-time table identity behind one `guard_lane` (see
/// `TraceCode.lane_pins`). `guard_ref` indexes the COMMITTED instruction
/// array (finalization remaps recorder indices through tropt's `old_to_new`
/// and drops pins whose guard was eliminated); `table_id` is the observed
/// table's deterministic `GcHeader.id` — never an address, so replay-stable
/// and immune to allocator reuse.
pub const LanePin = struct { guard_ref: u32, table_id: u32 };

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
/// `upvalue_cell` (doc 43 P5): one ACCESS PATH of a closed-upvalue alias class.
/// The seed resolves the cell `closure.upvalues[source]` through either the
/// anchor closure (`callee_slot == UPVALUE_CELL_ANCHOR`) or the closure in slab
/// slot `callee_slot`, requires it CLOSED, and produces `&cell.loc.closed` (a
/// `*Value`) into slab slot `slot` tagged `.int` (the `hash_cell` raw-pointer
/// discipline). The FIRST path of a class writes the slot; every further path
/// (`verify == true`) re-resolves and DECLINES the entry unless it agrees —
/// that is how the record-time MUST-alias relation (same observed `*Upvalue`)
/// is re-proven at entry. ANY failure (missing/open cell, non-function callee,
/// verifier mismatch) declines the whole candidate to tier-0 — `uref` has no
/// operands to re-derive from, so no tier-1a downgrade exists.
pub const InputKind = enum(u8) { upvalue, global, hash_cell, callee_upvalue, callee_global, upvalue_cell, upvalue_slot_alias };

/// `upvalue_cell` sentinel for `callee_slot`: resolve through the ANCHOR
/// closure (a depth-0 `get_upval`/`set_upval` path). Never a real slab slot —
/// the recorder aborts before `next_input_slot` reaches `maxInt(u16)` and real
/// callee slots are bounded by the slab capacity check at entry.
pub const UPVALUE_CELL_ANCHOR: u16 = std.math.maxInt(u16);

/// Doc 44: the `AnchorKey.pc` of a FUNCTION-HEAD anchor (a hot-call trace,
/// LuaJIT's `BC_FUNCF` analogue). A sentinel, deliberately NOT pc 0: a
/// `while` at the top of a function body can anchor a loop at pc 0, and the
/// two anchors must never share counters/gates/cache rows. The sentinel is
/// anchor IDENTITY only — recording and every bytecode consumer use the real
/// entry pc via `headEntryPc` — so any site that reads/executes bytecode at
/// `anchor.pc` must check `isHeadAnchorPc` first (bridging, loop
/// classification, and chain resume-pc derivation exclude head anchors
/// outright, fail-closed; doc 44 D1).
pub const FUNC_HEAD_PC: u32 = std.math.maxInt(u32);

/// Doc 44 D12b: the `AnchorKey.pc` tag bit of a CONTINUATION anchor (a hot
/// post-call resume pc; the return-side one-shot root). Anchor pc =
/// `CONT_PC_BIT | resume_pc`. Sound ONLY under the compiler contract that
/// every proto's code length stays `< 1 << 31` (`compiler.zig` hard-fails
/// past it), which both keeps bit 31 free on executable pcs and excludes
/// `resume_pc == 0x7fffffff` (whose encoding would alias `FUNC_HEAD_PC`).
/// All encode/decode goes through `contAnchorPc` / `anchorKind` / `entryPc`
/// — never raw bit tests at use sites.
pub const CONT_PC_BIT: u32 = 1 << 31;

/// Doc 44 D12b: the three anchor identity classes an `AnchorKey.pc` can
/// carry. `head` and `cont` are the ONE-SHOT family (terminal-closing roots
/// with a patched entry and no back-edge walk); `loop` is everything
/// classic. One-shot is a behavior class, never an identity equivalence —
/// per-anchor state (counters, gates, walks, wants, row validation) is
/// always keyed on the EXACT `AnchorKey`.
pub const AnchorPcKind = enum { loop, head, cont };

/// Decode an `AnchorKey.pc`'s identity class. Head first: the sentinel
/// (`maxInt`) has bit 31 set, so the cont test must never see it.
pub inline fn anchorKind(pc: u32) AnchorPcKind {
    if (pc == FUNC_HEAD_PC) return .head;
    if (pc & CONT_PC_BIT != 0) return .cont;
    return .loop;
}

/// The real bytecode pc an anchor's recording/entry starts at: pc 0 for a
/// head, the masked resume pc for a cont, the pc itself for a loop.
pub inline fn entryPc(pc: u32) u32 {
    return switch (anchorKind(pc)) {
        .head => 0,
        .cont => pc & ~CONT_PC_BIT,
        .loop => pc,
    };
}

/// Encode a continuation anchor's `AnchorKey.pc` from its resume pc.
pub inline fn contAnchorPc(resume_pc: u32) u32 {
    std.debug.assert(resume_pc & CONT_PC_BIT == 0); // compiler length contract
    return CONT_PC_BIT | resume_pc;
}

/// True iff `pc` is the function-head sentinel (not an executable pc).
pub inline fn isHeadAnchorPc(pc: u32) bool {
    return pc == FUNC_HEAD_PC;
}

/// The real bytecode pc a head anchor's recording/entry starts at.
/// (Superseded by `entryPc` for kind-generic sites; retained where the
/// caller has already proven `.head`.)
pub inline fn headEntryPc(pc: u32) u32 {
    return if (pc == FUNC_HEAD_PC) 0 else pc;
}

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
/// native eligibility. For `upvalue_slot_alias` (doc 53): VALIDATION-ONLY — no
/// slab write. The recorder canonicalized an inlined callee's OPEN-upvalue read
/// to the aliased anchor slot's SSA value; the seed re-proves at entry that the
/// callee closure in `callee_slot` still has `upvalues[source]` open over
/// exactly `base + slot` (`slot` is the aliased ANCHOR-window slot here, not a
/// synthetic one — `guard_func` pins only proto id, so a same-proto closure
/// from another live activation would alias a different frame; this seed is
/// mahina's per-entry flavor of LuaJIT `rec_upvalue`'s `REF_BASE` relation
/// guard). ANY failure declines the whole candidate to tier-0 (the
/// `upvalue_cell` grammar — the canonicalized slot read has nothing to
/// re-derive from, so no tier-1a downgrade exists).
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
    /// `hash_cell` only (doc 49 P5): the `HrefAux`-encoded `(slot, mask)` observed
    /// for this key in the recorded table, or `-1` when unavailable (non-heap key,
    /// encode overflow). When emission discovers the seeded href's root is dynamic
    /// (carried-heap — the seed is deactivated and its slab slot never read), this
    /// hint lets the href lower to hrefk inline guards instead of the
    /// per-iteration `resolveHashCell` callout (`effectiveHrefAux`). Pure
    /// compile-time data: never consulted by any seeding twin.
    hrefk_aux: i32 = -1,
    /// `callee_upvalue` only (inlined-callee upvalues): anchor-slab slot where the inlined callee's
    /// closure lives at entry time. The callee was already seeded (as an `upvalue`
    /// or regular `slot_load` input) before this seed, so `regGet(base +
    /// callee_slot)` is valid by the time this seed runs. (`callee_global` — doc 43
    /// P4, a global read inside an inlined callee — needs no callee at all: its
    /// `source` indexes the TRACE's own const pool (`ct.consts`, the `hash_cell`
    /// precedent), where the recorder copied the interned name string, so entry
    /// resolution is simply `globals.get(ct.consts[source])` — proto-free, which is
    /// what makes a depth>0 global seedable when the anchor proto's constant pool
    /// doesn't contain the key.)
    callee_slot: u16 = 0,
    /// `upvalue_cell` only: this seed is a VERIFIER path of an alias class —
    /// re-resolve the cell and decline the entry unless it equals the pointer
    /// the class's writer seed (same `slot`, earlier in the array) produced.
    verify: bool = false,
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
/// Doc 54 P2: capacity of the per-episode touched-slot drain list
/// (`NativeSeedCtx.touched`). Bounded so the episode-end drain is
/// O(distinct slots touched), never a global armed-link registry scan
/// (Rule #20). A row-free hit whose first-of-episode publish would
/// overflow the list DECLINES into its site's miss path instead — an
/// ordinary final row + dispatcher bounce; the next episode drains fresh.
pub const TOUCHED_CAP: usize = 64;

pub const NativeSeedCtx = struct {
    /// `seed_fn` result grammar (u64 for C-ABI simplicity; doc 22 §B.2).
    pub const SEED_OK: u64 = 1;
    /// A hash_cell seed failed validation (metatable appeared, key vanished,
    /// `hash.count()` drifted): the entry must not run natively this episode.
    pub const SEED_HASH_DECLINE: u64 = 2;
    /// The seed slots don't fit the register slab (`base + count > capacity`):
    /// nothing was written; the candidate itself is unusable at this depth.
    pub const SEED_CAPACITY_DECLINE: u64 = 3;

    // (Values 16/17 were the doc 44 D11 `self_call_push_fn` PUSH_OK/
    // PUSH_DECLINE grammar — doc 54 P2 replaced the last helper-driven push
    // path (cont pages) with the inline emitted sequence — and values 18/19
    // were the doc 44 D12c `self_ret_pop_fn` POP_OK/POP_DECLINE grammar,
    // replaced at doc 54 P1. All four stay reserved — never reuse them for
    // a new grammar.)

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
    /// Dynamic resume cursor published by a successful native return pop. The
    /// emitted epilogue reloads it after the C call to select a `.ret_cont` slot.
    ret_resume_pc: u32 = 0,
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
    seed_fn: *const fn (ctx: *const NativeSeedCtx, t: *const TraceCode, plan_bits: u64) callconv(.c) u64,
    /// The tier-1a seeding twin (interp.zig `nativeSeedTier1aFn`; doc 22 §B.3),
    /// called from `driveChain`'s chain seams (`seedForTier1a`) before each
    /// `irinterp.execute` of a seeded successor. Unlike the C-ABI plan twin it
    /// resolves the FULL input set — tier-1a's `slot_load`s read every synthetic
    /// slot; seed plans are a native-page concept (carried-heap rewrites) that
    /// never deactivates tier-1a's needs — and it is a plain Zig fn pointer (the
    /// callers are chain seams, not JIT-emitted code, so nothing is baked).
    /// Same tri-state result grammar. Optional so hand-built test ctxs that only
    /// exercise the C-ABI prologue keep compiling; consumers fail closed.
    seed_tier1a_fn: ?*const fn (ctx: *const NativeSeedCtx, t: *const TraceCode) u64 = null,
    // (Doc 44 D11's `self_call_push_fn` C-ABI push helper lived here until
    // doc 54 P2 rebuilt the last helper-driven path — continuation-page
    // pushes — on the inline emitted sequence and deleted the helper.)
    /// Doc 54 P1: the jit-debug-only structural-invariant assert callout
    /// (interp.zig `nativeFrameMotionAssert`). The inline pop drops the old
    /// helper's frame-identity re-verification because its premises are
    /// episode-local invariants; this callout is where each dropped check
    /// keeps a debug assert that can bite (the doc's sabotage protocol).
    /// Installed by `Vm.initBare` ONLY in `-Djit-debug` builds — `null`
    /// (normal builds, hand-built test ctxs) emits no callout, so release
    /// pages carry zero cost. Panics on violation; returns nothing.
    frame_motion_assert_fn: ?*const fn (ctx: *const NativeSeedCtx, nreg: u64) callconv(.c) void = null,
    /// Doc 54 P0: the per-episode descent gate byte — 1 iff the episode may
    /// perform inline native frame motion. Published by
    /// `Vm.prepareNativeEpisode` from `receiptsInert() and !reg_top_pending
    /// and final_cut == null`; all three conjuncts are episode-invariant
    /// (verified codex round 1: `reg_top_pending` is written only by tier-0
    /// multret paths, `final_cut` only after a top-level return, and nothing
    /// mutates region policy between an episode's pushes), so the byte
    /// written at episode start describes every push in the episode. The
    /// inline push sequence checks it with one `cmp byte` — the whole
    /// runtime residue of the helper's per-push preflight.
    descent_ok: u8 = 0,
    /// Doc 54 P0: the `Vm`/`CallFrame` field-offset descriptor the inline
    /// frame-motion sequences encode against (see `FrameMotionAbi`).
    /// Installed once by `Vm.initBare` next to the helper fns; `null` (a
    /// hand-built test ctx) means compilation emits no inline push — the
    /// same fail-closed fallback as an absent helper fn.
    frame_abi: ?FrameMotionAbi = null,
    /// Doc 54 P2: the episode generation stamp the row-free hit counters
    /// compare against (`LinkHitCounter.gen`). Incremented by
    /// `Vm.prepareNativeEpisode` — the per-episode funnel every
    /// frame-motion entry passes through — so every episode makes all
    /// counter records cold by construction and a drain can never read a
    /// previous episode's counts. (Recorded deviation from doc 54 P2's
    /// `runWithLinkedLoopDone` init sketch: the run wrapper has no ctx
    /// handle — `CompiledTrace` deliberately does not carry the ctx — and
    /// unprepared episodes (pure loop chains) cannot reach a frame-motion
    /// slot, so the prepare funnel is the equivalent init point.)
    episode_gen: u64 = 0,
    /// Doc 54 P2: the bounded touched-slot drain list — raw addresses of
    /// the `LinkHitCounter` records this episode's row-free hits published
    /// (first hit per slot per episode publishes; `TOUCHED_CAP` bounds the
    /// walk). `touched_len` is reset by `prepareNativeEpisode`; the array
    /// contents above the length are dead. Same recorded deviation as
    /// `episode_gen` (the doc sketched a `NativeResult`-tail array, which
    /// would cost a per-episode marshal of the full array or signature
    /// churn on every run wrapper; the ctx is per-VM, heap-stable, and
    /// already the episode-scoped mutable surface the emitted code bakes).
    touched_len: usize = 0,
    touched: [TOUCHED_CAP]usize = @splat(0),
};

/// Doc 54 P0: every `Vm`/`CallFrame`-layout byte offset the inline native
/// frame-motion sequences (push now; pop at P1) encode as displacement
/// immediates. The JIT lowering layer (`nativegen*.zig`) deliberately cannot
/// import `interp.zig` (interp imports trace, never the reverse), so it
/// cannot `@offsetOf` these types itself; instead `Vm.initBare` computes them
/// — comptime-derived, so a layout change recomputes them or fails interp's
/// pinned-width asserts, never silently miscompiles (the `nativegen_layout`
/// discipline, Z-1/Z-2) — and publishes them through the seed ctx. All
/// offsets are from the episode's `*Vm` (loaded from `NativeSeedCtx.vm` at
/// run time — `Vm` is a movable by-value struct, so no Vm-interior address
/// may be baked) except the `frame_*` fields, which are relative to a
/// `*CallFrame`.
pub const FrameMotionAbi = struct {
    /// `Vm.depth` (u32).
    vm_depth_off: i32,
    /// `Vm.stack_top` (usize).
    vm_stack_top_off: i32,
    /// `Vm.frames` (the inline `[max_call_depth]CallFrame` array base).
    vm_frames_off: i32,
    /// `Vm.next_call_seq` (u64; maxInt = exhausted, the emitted wall).
    vm_next_call_seq_off: i32,
    /// `Vm.trace.region_policy.region_context.depth` (u32).
    vm_region_depth_off: i32,
    /// `Vm.trace.region_policy.region_context.call_seq` (u64).
    vm_region_call_seq_off: i32,
    /// `Vm.trace.region_policy.region_context_valid` (bool, 1 byte).
    vm_region_valid_off: i32,
    /// `Vm.trace.tick` (u64) — `tickCallEntry` is `tick +%= 1`.
    vm_tick_off: i32,
    /// `Vm.trace.self_call_pushes` (u64) — the formation/`--jit-stats` witness.
    vm_self_call_pushes_off: i32,
    /// `Vm.trace.self_ret_pops` (u64) — the pop's formation witness (doc 54 P1).
    vm_self_ret_pops_off: i32,
    /// `Vm.open_upvalue_ceiling` (usize) — the inline pop's one-cmp
    /// open-upvalue check (`ceiling <= popped base` ⇒ no open cell at or
    /// above the popped window). Doc 54 P1.
    vm_open_upvalue_ceiling_off: i32,
    /// `@sizeOf(CallFrame)` — the `frames[]` stride.
    frame_size: i32,
    frame_closure_off: i32,
    frame_call_seq_off: i32,
    frame_base_off: i32,
    frame_pc_off: i32,
    frame_ret_dest_off: i32,
    frame_ret_count_off: i32,
    frame_varargs_base_off: i32,
    frame_varargs_count_off: i32,
    /// `CallFrame.code_cache_gen` (u64; write `maxInt` = invalidate the
    /// doc-20 fetch-image cache, replicating the push struct-literal's
    /// default).
    frame_code_cache_gen_off: i32,
    /// `CallFrame.in_flight` (bool; the push writes 0, replicating the
    /// struct-literal default — doc 61 §4.2). Doc 68's `ctl` byte follows it,
    /// so the push clears both with one word store here.
    frame_in_flight_off: i32,
    /// `interp.max_call_depth` — the depth wall immediate.
    max_call_depth: u32,
};

/// The static facts of one instruction as an exit (`TraceCode.exit_facts`).
/// Every field is its oracle's answer for the committed code.
pub const ExitFacts = packed struct(u64) {
    /// `trace_exit_attach.classify` says `.attachable`.
    attachable: bool = false,
    /// `TraceCode.isNumericForLoopDoneGuard`.
    numeric_for_done: bool = false,
    /// `TraceCode.isOwnLoopTest`.
    own_loop_test: bool = false,
    _pad: u29 = 0,
    /// The resume pc `P` (`trace_exit_attach.resumeOf`) when `attachable`;
    /// 0 otherwise.
    resume_pc: u32 = 0,
};

pub const TraceCode = struct {
    /// Borrowed proto identity; its program image must outlive this artifact.
    anchor: AnchorKey,
    /// Recording unrolled an inner while back-edge; immutable tiering evidence.
    unrolled_while: bool = false,
    /// The preheader represents a real run-once guest iteration, not LICM.
    /// The first completed back-edge accounts for TWO guest iterations. A
    /// zero-progress exit must leave carried boxes at the original entry state.
    peeled: bool = false,
    /// Doc 57 P3: extra source iterations an instability unroll added to the
    /// loop body (0 = one iteration per trip). Each copy of the loop's own
    /// test left mid-trip carries `GuardRole.loop_test_copy`
    /// (`isLoopTestCopy`).
    instunrolled: u8 = 0,
    /// Owned SSA instruction array. Frozen after publication.
    instrs: []IrInstr,
    /// Owned constants. Heap values here are NOT rooted (doc 61 §7.1): a
    /// collection that is about to sweep one retires the trace first
    /// (`heap_consts`, `Vm.invalidateDeadTraceConsts`).
    consts: []Value,
    /// Doc 61 §7.1 item 3: the indices into `consts` that hold heap values,
    /// built from the full final pool at finalize. The collector scans these
    /// between mark and sweep. Owned; freed in `deinit`.
    heap_consts: []u32 = &.{},
    entry_slots: []u16,
    /// Immutable entry contract; runtime-only means nonserialized, not mutable.
    inputs: []InputSeed = &.{},
    entry_guards: []EntryGuard,
    /// Conservative recorder allocation bound; blackout entry checks consume it.
    alloc_bound: u32 = 0,
    /// Requires the VM's monotone Unicode-version pin before entry/link arming.
    requires_unicode_pin: bool = false,
    /// Owned, sorted committed-index provenance. Missing allocation is fail-soft:
    /// mark incomplete so region discovery cannot infer safety from missing edges.
    exit_prov: []ExitProvEntry = &.{},
    exit_prov_complete: bool = true,
    /// Owned ordered recording path. Incomplete differs from legitimately empty;
    /// regions containing incomplete members must fail closed.
    rec_path: []ProgramPoint = &.{},
    rec_path_complete: bool = true,
    /// Owned ordinal → guest bytecode map: `instrs[i].ord` names the bytecode
    /// whose recording emitted it, `src_by_ord[ord]` is that bytecode's
    /// `{proto_id, source_pc}` (index 0 = no ordinal). Diagnostic only — read by
    /// the trace serializer for the visualiser's source mapping, never by
    /// tiering or codegen. Empty when the recording had no ordinals (precise),
    /// overflowed them, or hit an OOM.
    src_by_ord: []ProgramPoint = &.{},
    /// Owned LSB-first pure-classifier memo, built once before publication.
    /// OOM leaves it unbuilt and isBridgeCandidate uses the identical oracle.
    bridge_cand: []const u8 = &.{},
    bridge_cand_built: bool = false,
    /// Owned LSB-first memo of `isAnchorFrameGuard`'s complement: bit `i` set
    /// when instruction `i` was recorded off the anchor's frame (provenance
    /// at inline depth > 0, or a link terminal). Built first at commit, by
    /// one merge over the sorted `exit_prov`, because every later classifier
    /// asks it per guard (`buildFrameMemo`). Same fail-soft contract as
    /// `bridge_cand`.
    off_frame: []const u8 = &.{},
    off_frame_built: bool = false,
    /// Doc 45 D2: owned precise-deopt snapshot records + their flat slot-vector
    /// store (see `trace_snapshot.zig`). Empty on every `entry_replay` trace;
    /// a `precise` trace's finalization populates both or fails the candidate
    /// (correctness metadata, never fail-soft). Freed in `deinit`, which every
    /// candidate error path already funnels through.
    snapshots: []trace_snapshot.Snapshot = &.{},
    snapshot_slots: []trace_snapshot.SnapshotSlot = &.{},
    /// Doc 45 D2: how a guard failure restores guest state — whole-episode
    /// entry replay (the historical contract) or per-bytecode precise deopt
    /// via `snapshots`. Arm/dispatch validation must check this, not infer it.
    deopt_mode: trace_snapshot.DeoptMode = .entry_replay,
    /// Doc 63 §5.1: the host call sites of a precise trace, indexed by the
    /// host ops' `a`. Empty on every other trace. Read-only at run time.
    /// Owned; freed in `deinit`.
    host_sites: []trace_ir.HostCallSite = &.{},
    /// Doc 56 §4.2: the SPARSE exit snapshots of an ordinary (`entry_replay`)
    /// trace — per guard-bearing bytecode, the `.def` anchor-window slots
    /// mapped to committed IR refs, resuming at that bytecode. Kept apart
    /// from the precise `snapshots` above on purpose: `IrInstr.snap != 0`
    /// means a PRECISE exit everywhere, and ordinary traces keep `snap == 0`.
    /// A guard finds its snapshot through its `ord`: `exit_snap_by_ord[ord]`
    /// (one-based; 0 = none; entry 0 is always 0). Fail-soft metadata: empty
    /// (every exit non-attachable) on precise, peeled and deserialized traces,
    /// on ordinal overflow, and when validation or allocation failed. Owned;
    /// freed in `deinit`.
    exit_snapshots: []trace_snapshot.Snapshot = &.{},
    exit_snapshot_slots: []trace_snapshot.SnapshotSlot = &.{},
    exit_snap_by_ord: []trace_ir.SnapIdx = &.{},
    /// The static facts of every instruction as an exit (`ExitFacts`, one
    /// entry per instruction), computed once at commit by `buildExitFacts` —
    /// pure functions of this immutable code that the dispatcher's ledger
    /// replay otherwise re-derived on every row. Same fail-soft contract as
    /// `bridge_cand`: an OOM leaves it unbuilt and every reader asks the
    /// identical oracle. Built but empty when the trace has no instructions.
    /// Owned; freed in `deinit`.
    exit_facts: []const ExitFacts = &.{},
    exit_facts_built: bool = false,
    /// Doc 48: eviction metadata ONLY — the record-time table identity behind
    /// each `guard_lane` on a slot_load-covered root, so widen-eviction
    /// (`laneWidenedPast`) fires only against the very table whose monotonic
    /// lane history the recorder observed, never against a different table
    /// that happens to occupy the register at a polymorphic anchor. Identity
    /// is the deterministic `GcHeader.id` serial (never an address). A pin is
    /// a HEURISTIC: the guarded trace is lane- not identity-specialized, so
    /// evicting when the pinned table widens can still discard a trace some
    /// other same-lane table would pass — accepted re-record risk. Missing
    /// pins (OOM, non-slot_load roots) only ever suppress eviction.
    lane_pins: []LanePin = &.{},

    pub fn deinit(self: *TraceCode, gpa: std.mem.Allocator) void {
        gpa.free(self.instrs);
        gpa.free(self.consts);
        if (self.heap_consts.len != 0) gpa.free(self.heap_consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        if (self.exit_prov.len != 0) gpa.free(self.exit_prov);
        if (self.rec_path.len != 0) gpa.free(self.rec_path);
        if (self.src_by_ord.len != 0) gpa.free(self.src_by_ord);
        if (self.bridge_cand.len != 0) gpa.free(self.bridge_cand);
        if (self.off_frame.len != 0) gpa.free(self.off_frame);
        if (self.snapshots.len != 0) gpa.free(self.snapshots);
        if (self.snapshot_slots.len != 0) gpa.free(self.snapshot_slots);
        if (self.host_sites.len != 0) gpa.free(self.host_sites);
        if (self.exit_snapshots.len != 0) gpa.free(self.exit_snapshots);
        if (self.exit_snapshot_slots.len != 0) gpa.free(self.exit_snapshot_slots);
        if (self.exit_snap_by_ord.len != 0) gpa.free(self.exit_snap_by_ord);
        if (self.exit_facts.len != 0) gpa.free(self.exit_facts);
        if (self.lane_pins.len != 0) gpa.free(self.lane_pins);
        self.* = undefined;
    }

    pub fn provAt(self: *const TraceCode, idx: u32) ?ExitProvenance {
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

    /// The source pc of guard `idx` in the ANCHOR proto (`guardSourcePc`), or
    /// null when the guard has none or is not the anchor frame's own. An
    /// inlined callee's guard carries a pc in the CALLEE's proto (`emit`
    /// stamps the recorder's `cur_pc`), so reading `anchor.proto.code` there
    /// decodes an unrelated instruction, and a coincidental branch or
    /// `for_loop` at that pc misroutes the exit (doc 66 P2: array3d's
    /// iterator `jmp_if_false` at callee pc 5 met main's own `jmp_if_false`
    /// at pc 5 and raised a prime-side want every row). Every reader of the
    /// anchor proto at a guard's pc goes through here. A guard with no
    /// provenance row (a hand-built trace) is taken as depth 0; a link
    /// terminal never names an anchor source opcode.
    pub fn anchorSourcePc(self: *const TraceCode, idx: usize) ?u32 {
        if (idx >= self.instrs.len) return null;
        const src_pc = trace_ir.guardSourcePc(self.instrs[idx]) orelse return null;
        if (src_pc >= self.anchor.proto.code.len) return null;
        if (!self.isAnchorFrameGuard(idx)) return null;
        return src_pc;
    }

    /// Was instruction `idx` recorded in the anchor's own frame (inline depth
    /// 0), so that its pc indexes the anchor proto? Reads the `off_frame`
    /// memo: the commit-time classifiers (`buildBridgeCandMemo`,
    /// `buildExitFacts`) ask it for every guard, and a `provAt` search per
    /// ask measured +1% instructions on the small `while_shortcircuit_probe`.
    pub fn isAnchorFrameGuard(self: *const TraceCode, idx: usize) bool {
        if (!self.off_frame_built) return self.computeAnchorFrameGuard(idx);
        if (idx >= self.instrs.len) return false;
        return (self.off_frame[idx >> 3] >> @intCast(idx & 7)) & 1 == 0;
    }

    /// Build the `off_frame` memo: one pass over the sorted provenance table.
    /// Called at commit before any other classifier memo.
    pub fn buildFrameMemo(self: *TraceCode, gpa: std.mem.Allocator) void {
        std.debug.assert(!self.off_frame_built and self.off_frame.len == 0);
        if (self.instrs.len == 0) {
            self.off_frame_built = true;
            return;
        }
        const bytes = gpa.alloc(u8, (self.instrs.len + 7) / 8) catch return;
        @memset(bytes, 0);
        for (self.exit_prov) |e| {
            if (e.index >= self.instrs.len) continue;
            const off = switch (e.prov) {
                .guard => |gp| gp.inline_depth != 0,
                .link_terminal => true,
            };
            if (off) bytes[e.index >> 3] |= @as(u8, 1) << @intCast(e.index & 7);
        }
        self.off_frame = bytes;
        self.off_frame_built = true;
    }

    /// The oracle behind `isAnchorFrameGuard` (`noinline`: see
    /// `computeNumericForLoopDoneGuard`).
    noinline fn computeAnchorFrameGuard(self: *const TraceCode, idx: usize) bool {
        if (idx >= self.instrs.len) return false;
        const prov = self.provAt(@intCast(idx)) orelse return true;
        return switch (prov) {
            .guard => |gp| gp.inline_depth == 0,
            .link_terminal => false,
        };
    }

    /// The anchor-proto source instruction of guard `idx` (`anchorSourcePc`).
    pub fn anchorSourceInstr(self: *const TraceCode, idx: usize) ?bytecode.Instr {
        return self.anchor.proto.code[self.anchorSourcePc(idx) orelse return null];
    }

    /// The conditional branch guard `idx` was recorded from, when its source
    /// opcode (`anchorSourcePc`) is one.
    pub fn anchorCondBranch(self: *const TraceCode, idx: usize) ?bytecode.CondBranch {
        const pc = self.anchorSourcePc(idx) orelse return null;
        return bytecode.condBranchOf(self.anchor.proto.code[pc], pc);
    }

    /// Doc 57 P3: is guard `idx` a copy of the loop's own test that an
    /// instability unroll left mid-trip (`GuardRole.loop_test_copy`)? Such a
    /// guard is an ordinary coarse exit: every loop-done classifier and every
    /// source-branch consumer must refuse it. Fail-closed: in an unrolled
    /// trace a guard with no provenance counts as a copy, because treating a
    /// real loop-done as ordinary only costs a tier-0 replay, while the
    /// reverse loses an iteration.
    pub fn isLoopTestCopy(self: *const TraceCode, idx: usize) bool {
        if (self.instunrolled == 0) return false;
        if (idx >= self.instrs.len) return true;
        const prov = self.provAt(@intCast(idx)) orelse return true;
        return switch (prov) {
            .guard => |gp| gp.role == .loop_test_copy,
            .link_terminal => false,
        };
    }

    /// Doc 57 P3: source (tier-0 back-edge) iterations covered by `trips`
    /// completed trips. For coverage accounting only — `completed` itself
    /// stays a trip count everywhere else.
    pub fn sourceIters(self: *const TraceCode, trips: usize) u64 {
        return @as(u64, trips) *| (@as(u64, self.instunrolled) + 1);
    }

    pub fn matchesFingerprint(self: *const TraceCode, regs: RegWindow) bool {
        for (self.entry_guards) |g| {
            if (!g.ty.accepts(regs.get(g.slot))) return false;
        }
        return true;
    }

    /// Doc 56 §4.2: the one-based exit snapshot of side-exit instruction
    /// `instr_idx`, found through its boundary ordinal, or null when it has
    /// none (not a side-exit op, no ordinal, or its snapshot was dropped).
    /// Finalize validated every entry (`exitSnapshotsValid`); the range
    /// checks here only keep a hand-built trace from indexing out of bounds.
    pub fn exitSnapIdx(self: *const TraceCode, instr_idx: usize) ?trace_ir.SnapIdx {
        if (instr_idx >= self.instrs.len) return null;
        const ins = self.instrs[instr_idx];
        if (ins.ord == 0 or ins.ord >= self.exit_snap_by_ord.len) return null;
        if (!trace_ir.isSideExitGuardOp(ins.op)) return null;
        const si = self.exit_snap_by_ord[ins.ord];
        if (si == 0 or si > self.exit_snapshots.len) return null;
        return si;
    }

    /// Compute `exit_facts` once, at commit, from the final code: each
    /// fact's oracle below, the attachability and resume pc through
    /// `trace_exit_attach.fillFacts`. FAIL-SOFT: on OOM the table stays
    /// unbuilt, never partial, and every reader asks its oracle.
    pub fn buildExitFacts(self: *TraceCode, gpa: std.mem.Allocator) void {
        std.debug.assert(!self.exit_facts_built and self.exit_facts.len == 0);
        if (self.instrs.len == 0) {
            self.exit_facts_built = true;
            return;
        }
        const facts = gpa.alloc(ExitFacts, self.instrs.len) catch return;
        for (facts, 0..) |*f, i| f.* = .{
            .numeric_for_done = self.computeNumericForLoopDoneGuard(i),
            .own_loop_test = self.computeOwnLoopTest(i),
        };
        if (!exit_attach.fillFacts(gpa, self, facts)) {
            gpa.free(facts);
            return;
        }
        self.exit_facts = facts;
        self.exit_facts_built = true;
    }

    /// Doc 56 §4.3: whether exit `instr_idx` may take the resume-coherent
    /// path (materialize at its resume pc, then continue there). Reads the
    /// commit-time memo; see `trace_exit_attach` for the rules.
    pub fn exitAttachable(self: *const TraceCode, instr_idx: usize) bool {
        if (!self.exit_facts_built) return exit_attach.classify(self, instr_idx) == .attachable;
        if (instr_idx >= self.exit_facts.len) return false;
        return self.exit_facts[instr_idx].attachable;
    }

    /// Doc 56 Phase 3: whether the commit-time memo marks any exit
    /// attachable. An unbuilt memo (OOM) answers false: the trace then gets
    /// no exit-side state, which costs coverage, never correctness.
    pub fn anyExitAttachable(self: *const TraceCode) bool {
        if (!self.exit_facts_built) return false;
        for (self.exit_facts) |f| if (f.attachable) return true;
        return false;
    }

    /// Doc 56 Phase 3: whether this trace ends in a `.link` that finishes
    /// an iteration of a loop containing its anchor (`LinkKind`). The burst
    /// counts each such run to the `.link` as one completed iteration.
    pub fn linkClosesIteration(self: *const TraceCode) bool {
        const n = self.instrs.len;
        if (n == 0 or self.instrs[n - 1].op != .link) return false;
        return @as(trace_ir.LinkKind, @enumFromInt(self.instrs[n - 1].a)) == .enclosing_iteration;
    }

    /// Doc 56 §4.3: the resume pc `P` of an attachable exit (the branch
    /// fix-up applied), or null when the exit is not attachable.
    pub fn exitResumePc(self: *const TraceCode, instr_idx: usize) ?u32 {
        if (!self.exit_facts_built) return exit_attach.resumePc(self, instr_idx);
        if (instr_idx >= self.exit_facts.len) return null;
        const f = self.exit_facts[instr_idx];
        return if (f.attachable) f.resume_pc else null;
    }

    /// Doc 43 P5 (the sgm_setpos precedent, generalized): the eligibility gate
    /// for the loop-done linked-exit flush is a CLOSED WHITELIST, not a
    /// denylist. The region between the loop-done guard and the φ block holds
    /// exactly the sunk stores `finalize` appended; both materializers
    /// (`irinterp.flushNumericForLoopDone`, nativegen's
    /// `emitLinkedLoopDoneSnapshot`) enumerate the same store inventory, so any
    /// op neither of them models — `sgm_setpos` today, or a future store kind
    /// added without its two flush arms — declines the flush here and the
    /// linked exit falls back to tier-0 replaying the final iteration
    /// (correct, merely slower). A denylist would silently LOSE the new store.
    pub fn loopDoneSnapshotSupported(self: *const TraceCode, exit_instr: usize) bool {
        var i = exit_instr + 1;
        while (i < self.instrs.len) : (i += 1) switch (self.instrs[i].op) {
            .astore, .hstore, .gstore, .ustore => {},
            .phi, .loop, .link => return true,
            else => return false,
        };
        return true;
    }

    /// The single gate both tiers consult before taking the linked loop-done
    /// flush at numeric-for loop-done guard `exit_instr`: the closed store
    /// inventory above, and doc 61 §5 (site 5). The flush skips the visible
    /// control variable `R[a+3]`, whose slab copy then holds the value of an
    /// earlier iteration. That is sound only when nothing reads it from the
    /// fall-through pc on, and when the collector's mask covers that
    /// staleness (`maskable`). Otherwise decline: the guard takes the
    /// ordinary deopt and tier-0 replays the final iteration, which writes
    /// `R[a+3]` itself.
    pub fn loopDoneFlushSupported(self: *const TraceCode, exit_instr: usize) bool {
        if (!self.loopDoneSnapshotSupported(exit_instr)) return false;
        const proto = self.anchor.proto;
        if (!proto.maskable) return false;
        const exit_pc = trace_ir.guardExitPc(self.instrs[exit_instr]) orelse return false;
        const slot = (self.anchorSourceInstr(exit_instr) orelse return false).a + 3;
        if (slot >= proto.num_registers) return false; // not a real for-loop window
        // Falling off the end of the code reads nothing.
        if (exit_pc >= proto.code.len) return true;
        return !proto.reg_live.liveIn(exit_pc, slot);
    }

    /// Does the native page emit the linked loop-done branch at guard
    /// `instr_idx`? Emission consults exactly this, and so does every reader
    /// that must know whether a linked-mode run committed the final
    /// iteration there (the chain's call A): where it is false the guard is
    /// mode-0-always and its exit is an ordinary deopt at the loop header.
    /// A peeled trace never takes the linked path (doc 39).
    pub fn linkedLoopDoneEmitted(self: *const TraceCode, instr_idx: usize) bool {
        return self.isNumericForLoopDoneGuard(instr_idx) and !self.peeled and
            self.loopDoneFlushSupported(instr_idx);
    }

    /// Is guard `instr_idx` a numeric-`for` loop-done guard: a `guard_true`
    /// at inline depth 0, not a mid-trip copy, whose exit pc follows a
    /// `for_loop` of a loop-anchored trace? Reads the commit-time memo.
    pub fn isNumericForLoopDoneGuard(self: *const TraceCode, instr_idx: usize) bool {
        if (!self.exit_facts_built) return self.computeNumericForLoopDoneGuard(instr_idx);
        return instr_idx < self.exit_facts.len and self.exit_facts[instr_idx].numeric_for_done;
    }

    /// The oracle behind `isNumericForLoopDoneGuard`. `noinline` for every
    /// memo oracle here: they run only before the commit-time memo exists,
    /// and inlined they bloat their reader past LLVM's inlining threshold,
    /// so the reader stops being a one-load read at its callers (measured:
    /// `ExitIterator.next`'s 264 asks on `while_shortcircuit_probe` became
    /// calls, +0.5% instructions).
    noinline fn computeNumericForLoopDoneGuard(self: *const TraceCode, instr_idx: usize) bool {
        if (instr_idx >= self.instrs.len) return false;
        // Doc 44 D1/D12b: a one-shot trace (head or cont) has no loop-done
        // exits — a zero-iteration `for` recorded through the body would
        // otherwise classify here (its guard_true really does source from a
        // `for_loop` op) and route into the loop-done slot/snapshot
        // machinery. Kind check, fail-closed.
        if (anchorKind(self.anchor.pc) != .loop) return false;
        if (self.instrs[instr_idx].op != .guard_true) return false;
        // Depth 0 only (`anchorSourcePc`): a callee's `for_loop` is not ours.
        const src = self.anchorSourceInstr(instr_idx) orelse return false;
        if (src.op != .for_loop) return false;
        // Doc 57 P3: a non-final iteration's `for_loop` test sits mid-trip.
        return !self.isLoopTestCopy(instr_idx);
    }

    /// Doc 58 §4.3: is guard `idx` the test of the loop this trace is anchored
    /// at — the guard whose other direction LEAVES the loop? Purely structural,
    /// from the guard's source instruction and `bytecode.loopHeaderOf`, so it
    /// needs no role and matches every unrolled copy of the test (a copy has the
    /// same source instruction). One classifier for all three loop shapes:
    ///  - a `for_loop`/`tfor_loop` whose header is the anchor;
    ///  - a link of the test of the `while` whose header is the anchor that
    ///    leaves the loop (`bytecode.whileTestMarkerOf`): the last one,
    ///    right above the marker, or an earlier `and` link;
    ///  - a link of the test of the `repeat` whose header is the anchor
    ///    that leaves the loop (`bytecode.repeatTestMarkerOf`): the closer
    ///    onto the marker, or an `or` link jumping to the exit.
    ///
    /// A loop's own test is not a branch alternation: it must not raise
    /// `wants_prime_side` (which would unpatch the entry and chain same-anchor
    /// siblings on every loop completion). Its hotness feeds exit-side only
    /// (review r3 finding 1; the dispatcher counts it — B2 review blocker 2 —
    /// and `noteTakenExit` stops it before every legacy route). Reads the
    /// commit-time memo.
    pub fn isOwnLoopTest(self: *const TraceCode, idx: usize) bool {
        if (!self.exit_facts_built) return self.computeOwnLoopTest(idx);
        return idx < self.exit_facts.len and self.exit_facts[idx].own_loop_test;
    }

    /// The oracle behind `isOwnLoopTest` (`noinline`: see
    /// `computeNumericForLoopDoneGuard`).
    noinline fn computeOwnLoopTest(self: *const TraceCode, idx: usize) bool {
        if (idx >= self.instrs.len) return false;
        if (anchorKind(self.anchor.pc) != .loop) return false;
        const g = self.instrs[idx];
        if (g.op != .guard_true and g.op != .guard_false) return false;
        // Depth 0 only (`anchorSourcePc`): an inlined callee's loop test is
        // not this loop's.
        const src_pc = self.anchorSourcePc(idx) orelse return false;
        const proto = self.anchor.proto;
        const src = proto.code[src_pc];
        // `for_loop` / `tfor_loop`: the back-edge itself is the test.
        if (bytecode.loopHeaderOf(src, src_pc) == self.anchor.pc) return true;
        // `while`: a link of the test that leaves the loop.
        if (bytecode.whileTestMarkerOf(proto.code, src_pc)) |m| {
            if (m + 1 == self.anchor.pc) return true;
        }
        // `repeat`: likewise.
        const m = bytecode.repeatTestMarkerOf(proto.code, src_pc) orelse return false;
        return m + 1 == self.anchor.pc;
    }

    /// Doc 39: is exit `idx` in a PEELED trace's steady region — past the
    /// `.preheader` marker that ends the run-once guest iteration? False on an
    /// unpeeled trace (its `.preheader`, if any, is an LICM boundary, not a
    /// guest iteration). A linear scan: asked only on the rare zero-completion
    /// exit of a peeled trace, which replays the whole iteration in tier-0
    /// anyway.
    pub fn isSteadyRegionExit(self: *const TraceCode, idx: usize) bool {
        if (!self.peeled or idx >= self.instrs.len) return false;
        for (self.instrs[0..idx]) |ins| {
            if (ins.op == .preheader) return true;
        }
        return false;
    }

    pub fn classifyBridgeCandidate(self: *const TraceCode, instr_idx: usize) bool {
        if (instr_idx >= self.instrs.len or self.peeled) return false;
        // Doc 44 D1/D12b: a ONE-SHOT trace (head or cont) is never a bridge
        // member — its branch guards (e.g. fib's base-case `jmp_if` guard)
        // carry `.branch_cond` provenance and slot-bound φs below them, so
        // the structural checks alone would admit it (`exit_pc >= anchor.pc`
        // is vacuous against the sentinel / tagged pc). Explicit kind check,
        // fail-closed.
        if (anchorKind(self.anchor.pc) != .loop) return false;
        const guard = self.instrs[instr_idx];
        if (guard.op != .guard_true and guard.op != .guard_false) return false;
        if (self.isNumericForLoopDoneGuard(instr_idx)) return false;
        const exit_pc = trace_ir.guardExitPc(guard) orelse return false;
        const source_pc = self.anchorSourcePc(instr_idx) orelse return false;
        if (exit_pc >= self.anchor.pc) return false;
        const gp = switch (self.provAt(@intCast(instr_idx)) orelse return false) {
            .guard => |g| g,
            .link_terminal => return false,
        };
        if (gp.role != .branch_cond or gp.source_proto_id != self.anchor.proto.id or gp.source_pc != source_pc) return false;
        const cb = self.anchorCondBranch(instr_idx) orelse return false;
        if (!cb.cond.isCondition()) return false;
        // Doc 43 P0c (fail-closed): an ARMED composite bridge hands off directly to
        // the successor (`nativegen` edge-4 stub: snapshot φ slots, then `jmpMem`
        // to `exit_target` — NO tier-0 replay) and its snapshot
        // (`emitCompositeBridgeSnapshot`) flushes ONLY the carried homes and the
        // slot-bound φs of E. A SUNK heap
        // store (RMW `astore`/`hstore`/`gstore`, or the deferred gmatch
        // `sgm_setpos`) is deopt-deferred to the trace tail — below every body
        // guard — on the promise that any side-exit re-runs the iteration in tier-0
        // and re-does the store. A bridge exit breaks that promise: it neither
        // flushes the sunk store nor replays, so the store is LOST. Such stores are
        // always appended AFTER the body guards (`trace_finalize`), i.e. at an IR
        // index below this branch guard, so refuse candidacy whenever any store op
        // sits below `instr_idx`. Today branch-candidate traces and store-bearing
        // traces are disjoint (the sieve's bridge trace has zero store ops), so
        // this is coverage-neutral now and pins the invariant as the arc adds new
        // sunk-store shapes (P1–P3 `hstore`). Ordinary deopt (tier-0 replay) stays
        // correct for these guards.
        var si = instr_idx + 1;
        while (si < self.instrs.len) : (si += 1) {
            if (trace_ir.isStateEffectOp(self.instrs[si].op)) return false;
        }
        // The pc the bridge lands on first: the branch edge the recording did
        // NOT take, where `CompositeWalk` starts.
        const walk = CompositeWalk.init(self.anchor.proto.code, source_pc, gp.polarity) orelse return false;
        const landing = walk.current() orelse return false;
        return self.bridgeMatchesExitSnapshot(instr_idx, landing);
    }

    /// Doc 58 B2 review, blocker 1: an armed composite bridge hands off with
    /// NO tier-0 replay, so the state it commits must BE the guest state at
    /// the exit — what LuaJIT restores from the exit's snapshot. The emitted
    /// set E (`bridgeEmissions`) infers that state from φs: "a φ whose update
    /// ref precedes the guard wrote its slot before the guard". The IR index
    /// of a VALUE is not the program point of a slot WRITE: `konst` is
    /// interned at first use and CSE reuses earlier refs, so a slot written
    /// AFTER the guard (a `while` condition temp re-set by an unrolled copy's
    /// `loadk true`) can own a φ whose update precedes it, and a slot written
    /// before the guard and again after it leaves E without the earlier
    /// write. Either way the bridge committed a state the guest never had
    /// (`bench/while_shortcircuit_probe.lua`: one extra `while` trip).
    ///
    /// The exit snapshot (doc 56 §4.2) is the recorder's exact slot state at
    /// the guard's bytecode (the branch writes nothing, so it is also the
    /// state on the edge out of it). E is admitted only when it agrees with
    /// that state on every slot live at `landing`, the pc the bridge lands on:
    /// a live E member must be in the snapshot with the SAME ref, and a live
    /// snapshot write must be in E (or re-store the slot's own current value,
    /// which the bridge's carried-home flush, `emitCarriedHomesFlush`, writes
    /// before E). Every slot outside E is coherent at the hand-off: carried
    /// homes are flushed, invariant slots never changed. Liveness is taken at
    /// `landing`, not at the guard: the branch's own condition temp is read by
    /// the branch and dead past it (nsieve's `if flags[i]`). Anything the
    /// bridge successor reads is live at `landing` — the overlay walks only
    /// `jmp`s, which read nothing, and at most one `for_loop`, whose written
    /// slots the continue proof covers. No snapshot (precise, budget
    /// exhausted, dropped by validation) ⇒ no candidacy: fail closed.
    fn bridgeMatchesExitSnapshot(self: *const TraceCode, instr_idx: usize, landing: u32) bool {
        const si = self.exitSnapIdx(instr_idx) orelse return false;
        const s = self.exit_snapshots[si - 1];
        const proto = self.anchor.proto;
        // Not maskable (no liveness, or a call layout the collector cannot
        // mask, doc 61 §5): every slot counts as observable, which only makes
        // the agreement check stricter.
        const live_row: []const u64 = if (proto.maskable) proto.reg_live.row(landing) else &.{};
        const snap = self.exit_snapshot_slots[s.slots_begin..][0..s.slots_len];
        var any = false;
        var emitted = self.bridgeEmissions(instr_idx);
        while (emitted.next()) |p| {
            any = true;
            const slot: usize = @intCast(p.aux);
            if (!liveIn(live_row, slot)) continue;
            const ref = snapshotRefOf(snap, slot) orelse return false;
            if (ref != p.b) return false;
        }
        for (snap) |ss| {
            if (!liveIn(live_row, ss.slot)) continue;
            if (self.bridgeEmitsSlot(instr_idx, ss.slot)) continue;
            const d = self.instrs[ss.ref];
            if (d.op == .slot_load and d.aux == @as(i32, ss.slot)) continue;
            return false;
        }
        return any;
    }

    fn liveIn(row: []const u64, slot: usize) bool {
        if (slot / 64 >= row.len) return true; // outside the row (or no row): observable
        return (row[slot / 64] >> @intCast(slot % 64)) & 1 != 0;
    }

    fn snapshotRefOf(snap: []const trace_snapshot.SnapshotSlot, slot: usize) ?trace_ir.Ref {
        for (snap) |ss| if (ss.slot == slot) return ss.ref;
        return null;
    }

    pub fn isBridgeCandidate(self: *const TraceCode, idx: usize) bool {
        if (!self.bridge_cand_built) return self.classifyBridgeCandidate(idx);
        if (idx >= self.instrs.len) return false;
        return (self.bridge_cand[idx >> 3] >> @intCast(idx & 7)) & 1 != 0;
    }

    /// The single source of truth for A-v's emitted bridge set E: slot-bound phis
    /// whose update dominates the composite exit (doc 17 §A2.1). Lowering, arm
    /// validation, and region-topology discovery all consume this allocation-free
    /// immutable-IR query.
    pub fn bridgeEmissions(self: *const TraceCode, exit_instr: usize) BridgeEmissionIterator {
        return .{ .instrs = self.instrs, .exit_instr = exit_instr };
    }

    pub fn bridgeEmitsSlot(self: *const TraceCode, exit_instr: usize, slot: u16) bool {
        var emitted = self.bridgeEmissions(exit_instr);
        while (emitted.next()) |p|
            if (p.aux == @as(i32, @intCast(slot))) return true;
        return false;
    }
};

pub const BridgeEmissionIterator = struct {
    instrs: []const IrInstr,
    exit_instr: usize,
    index: usize = 0,

    pub fn next(self: *BridgeEmissionIterator) ?IrInstr {
        while (self.index < self.instrs.len) {
            const p = self.instrs[self.index];
            self.index += 1;
            if (p.op == .phi and p.aux != trace_ir.PHI_INTERNAL and p.b < self.exit_instr)
                return p;
        }
        return null;
    }
};

/// Doc 17 A-vii-d.1: the static-CFG path a failing branch guard's deopt
/// takes, which a composite bridge follows to its successor. It starts on the
/// edge of the source `jmp_if_*` the recording did NOT take (post-fetch jump
/// convention: offsets apply to `source_pc + 1`), then crosses only `jmp`,
/// `loop` markers and at most ONE numeric `for_loop`, along its continue
/// edge, for at most `MAX_STEPS` pcs. `resolveCompositeBridgeSuccessor` stops
/// it at the first pc with a bound trace. `trace_finalize.phiLiveRow` walks
/// it to the end, because the recording cannot know where traces will bind.
pub const CompositeWalk = struct {
    code: []const bytecode.Instr,
    pc_i: i64,
    steps: u8 = 0,
    /// The `for_loop` the walk crossed, whose written slots `{a, a+3}` the
    /// bridge takes from E (`compositeContinueProof`).
    crossed_for_loop: ?u32 = null,

    pub const MAX_STEPS = 16;

    /// The walk for a guard sourced at `source_pc` whose recorded branch
    /// direction is `polarity`; null when the source is not a conditional
    /// jump or the guard carries no direction.
    pub fn init(code: []const bytecode.Instr, source_pc: u32, polarity: trace_types.Polarity) ?CompositeWalk {
        if (polarity == .neutral or source_pc >= code.len) return null;
        const cb = bytecode.condBranchOf(code[source_pc], source_pc) orelse return null;
        if (!cb.cond.isCondition()) return null;
        const fallthrough: i64 = @as(i64, source_pc) + 1;
        return .{ .code = code, .pc_i = if (polarity == .fallthrough) cb.target else fallthrough };
    }

    /// The pc the walk stands on, or null once it has left the code or run
    /// out of steps.
    pub fn current(self: *const CompositeWalk) ?u32 {
        if (self.steps >= MAX_STEPS or self.pc_i < 0 or self.pc_i >= self.code.len) return null;
        return @intCast(self.pc_i);
    }

    /// Step past `current()`. False when that op ends the walk: anything but
    /// `jmp`, `loop` (a marker always falls through; its `aux` is the loop's
    /// exit offset, doc 58) or a first `for_loop`.
    pub fn step(self: *CompositeWalk) bool {
        const pc = self.current() orelse return false;
        const ins = self.code[pc];
        switch (ins.op) {
            .jmp => self.pc_i += 1 + ins.aux,
            .loop => self.pc_i += 1,
            .for_loop => {
                if (self.crossed_for_loop != null) return false;
                self.crossed_for_loop = pc;
                self.pc_i += 1 + ins.aux;
            },
            else => return false,
        }
        self.steps += 1;
        return true;
    }
};

test {
    _ = @import("trace_code_test.zig");
    _ = exit_attach;
}
