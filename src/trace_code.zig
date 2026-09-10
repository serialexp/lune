//! Immutable, owned code payload of a committed trace.
//!
//! `TraceCode` is embedded by value in the lifecycle-owned `TraceRecord`.  Execution,
//! serialization, classification, and native lowering consume this dependency-light
//! representation and therefore do not depend on cache/native lifecycle state.

const std = @import("std");
const value = @import("value.zig");
const trace_ir = @import("trace_ir.zig");
const trace_snapshot = @import("trace_snapshot.zig");
const trace_types = @import("trace_types.zig");
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
pub const InputKind = enum(u8) { upvalue, global, hash_cell, callee_upvalue, callee_global, upvalue_cell };

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
pub const NativeSeedCtx = struct {
    /// `seed_fn` result grammar (u64 for C-ABI simplicity; doc 22 §B.2).
    pub const SEED_OK: u64 = 1;
    /// A hash_cell seed failed validation (metatable appeared, key vanished,
    /// `hash.count()` drifted): the entry must not run natively this episode.
    pub const SEED_HASH_DECLINE: u64 = 2;
    /// The seed slots don't fit the register slab (`base + count > capacity`):
    /// nothing was written; the candidate itself is unusable at this depth.
    pub const SEED_CAPACITY_DECLINE: u64 = 3;

    /// `self_call_push_fn` result grammar (doc 44 D11) — deliberately disjoint
    /// from the seed values above so a wiring mistake (wrong fn baked) can
    /// never read as the other grammar's success.
    /// The helper pushed a real VM frame for the self-call and refreshed this
    /// ctx for the new activation: the page shifts its lane pointers and
    /// re-enters its own body.
    pub const PUSH_OK: u64 = 16;
    /// Any refusal (rebound callee, depth/capacity wall, live region
    /// receipts, invariant re-verification failure): NOTHING was mutated;
    /// the page runs its plain terminal exit and tier-0 re-executes the
    /// call generically, raising any error itself.
    pub const PUSH_DECLINE: u64 = 17;

    /// `self_ret_pop_fn` result grammar (doc 44 D12c) — disjoint from both
    /// grammars above for the same wiring-mistake reason.
    /// The helper popped the episode's own top frame (opRet-verbatim result
    /// copy + real frame pop) and refreshed this ctx for the popped-into
    /// caller activation; the page appends a `.ret_pop` row and exits.
    pub const POP_OK: u64 = 18;
    /// Any refusal (net-zero floor, open upvalue over the popped window,
    /// `all_results` wiring, boundary frame, invariant re-verification
    /// failure): NOTHING was mutated; the page runs its plain terminal exit
    /// and tier-0 re-executes the `ret` generically.
    pub const POP_DECLINE: u64 = 19;

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
    /// Doc 44 D11: the C-ABI self-call frame-push helper (interp.zig
    /// `nativeSelfCallPush`), called from a head page's
    /// `.terminal(self_call_interp)` push epilogue with the terminal's resume
    /// pc (the `.call` bytecode index) baked as an imm64. Replicates `opCall`'s
    /// Lua-closure arm verbatim (window layout + caller cursor freeze +
    /// `pushFrameVararg`), refreshes THIS ctx for the pushed activation, and
    /// returns PUSH_OK / PUSH_DECLINE. Installed once at VM init next to
    /// `seed_fn`; optional so hand-built test ctxs keep compiling and
    /// compilation falls back to the plain terminal when absent (fail closed).
    self_call_push_fn: ?*const fn (ctx: *const NativeSeedCtx, t: *const TraceCode, terminal_aux: u64) callconv(.c) u64 = null,
    /// Doc 44 D12c: the C-ABI return-side frame-pop helper (interp.zig
    /// `nativeSelfRetPop`), called from a `.terminal(return_interp)` pop
    /// epilogue with the terminal's `.ret` bytecode index AND the episode's
    /// net pushed-frame count (`pushed_frames - popped_frames`, computed by
    /// the emitted code from the `NativeResult` counters) — the round-6
    /// change-7 explicit floor: the helper refuses at net 0, so an episode
    /// only ever pops frames IT pushed and the entry frame's own return
    /// stays tier-0. Replicates `opRet`'s non-boundary arm verbatim (result
    /// copy under the live `stack_top`, region-activation drop, frame pop,
    /// `stack_top` shrink), refreshes THIS ctx for the caller activation,
    /// and returns POP_OK / POP_DECLINE. Installed once at VM init;
    /// optional so hand-built test ctxs keep compiling and compilation
    /// falls back to the plain terminal when absent (fail closed).
    self_ret_pop_fn: ?*const fn (ctx: *const NativeSeedCtx, t: *const TraceCode, terminal_aux: u64, net_pushed: u64) callconv(.c) u64 = null,
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
    /// Owned SSA instruction array. Frozen after publication.
    instrs: []IrInstr,
    /// Owned constants, including heap values rooted by the runtime while live.
    consts: []Value,
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
    /// Owned LSB-first pure-classifier memo, built once before publication.
    /// OOM leaves it unbuilt and isBridgeCandidate uses the identical oracle.
    bridge_cand: []const u8 = &.{},
    bridge_cand_built: bool = false,
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

    pub fn deinit(self: *TraceCode, gpa: std.mem.Allocator) void {
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        if (self.exit_prov.len != 0) gpa.free(self.exit_prov);
        if (self.rec_path.len != 0) gpa.free(self.rec_path);
        if (self.bridge_cand.len != 0) gpa.free(self.bridge_cand);
        if (self.snapshots.len != 0) gpa.free(self.snapshots);
        if (self.snapshot_slots.len != 0) gpa.free(self.snapshot_slots);
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

    pub fn matchesFingerprint(self: *const TraceCode, regs: RegWindow) bool {
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

    pub fn isNumericForLoopDoneGuard(self: *const TraceCode, instr_idx: usize) bool {
        if (instr_idx >= self.instrs.len) return false;
        // Doc 44 D1/D12b: a one-shot trace (head or cont) has no loop-done
        // exits — a zero-iteration `for` recorded through the body would
        // otherwise classify here (its guard_true really does source from a
        // `for_loop` op) and route into the loop-done slot/snapshot
        // machinery. Kind check, fail-closed.
        if (anchorKind(self.anchor.pc) != .loop) return false;
        const guard = self.instrs[instr_idx];
        if (guard.op != .guard_true) return false;
        const exit_pc = trace_ir.guardExitPc(guard) orelse return false;
        if (exit_pc == 0 or exit_pc > self.anchor.proto.code.len) return false;
        if (self.anchor.proto.code[trace_ir.guardSourcePc(guard).?].op != .for_loop) return false;
        if (self.provAt(@intCast(instr_idx))) |prov| switch (prov) {
            .guard => |gp| if (gp.inline_depth > 0) return false,
            .link_terminal => return false,
        };
        return true;
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
        const source_pc = trace_ir.guardSourcePc(guard) orelse return false;
        if (exit_pc >= self.anchor.pc or source_pc >= self.anchor.proto.code.len) return false;
        const gp = switch (self.provAt(@intCast(instr_idx)) orelse return false) {
            .guard => |g| g,
            .link_terminal => return false,
        };
        if (gp.role != .branch_cond or gp.source_proto_id != self.anchor.proto.id or gp.source_pc != source_pc) return false;
        switch (self.anchor.proto.code[source_pc].op) {
            .jmp_if_true, .jmp_if_false => {},
            else => return false,
        }
        // Doc 43 P0c (fail-closed): an ARMED composite bridge hands off directly to
        // the successor (`nativegen` edge-4 stub: snapshot φ slots, then `jmpMem`
        // to `exit_target` — NO tier-0 replay) and its snapshot
        // (`emitCompositeBridgeSnapshot`) flushes ONLY slot-bound φs. A SUNK heap
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
        while (si < self.instrs.len) : (si += 1) switch (self.instrs[si].op) {
            .astore, .astore_append, .hstore, .gstore, .sgm_setpos, .ustore => return false,
            else => {},
        };
        for (self.instrs) |ins| if (ins.op == .phi and ins.aux != trace_ir.PHI_INTERNAL and ins.b < instr_idx) return true;
        return false;
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

test {
    _ = @import("trace_code_test.zig");
}
