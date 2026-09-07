//! Immutable, owned code payload of a committed trace.
//!
//! `TraceCode` is embedded by value in the lifecycle-owned `TraceRecord`.  Execution,
//! serialization, classification, and native lowering consume this dependency-light
//! representation and therefore do not depend on cache/native lifecycle state.

const std = @import("std");
const value = @import("value.zig");
const trace_ir = @import("trace_ir.zig");
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

    pub fn deinit(self: *TraceCode, gpa: std.mem.Allocator) void {
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        if (self.exit_prov.len != 0) gpa.free(self.exit_prov);
        if (self.rec_path.len != 0) gpa.free(self.rec_path);
        if (self.bridge_cand.len != 0) gpa.free(self.bridge_cand);
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

    pub fn loopDoneSnapshotSupported(self: *const TraceCode, exit_instr: usize) bool {
        var i = exit_instr + 1;
        while (i < self.instrs.len) : (i += 1) switch (self.instrs[i].op) {
            .sgm_setpos => return false,
            .phi, .loop, .link => return true,
            else => {},
        };
        return true;
    }

    pub fn isNumericForLoopDoneGuard(self: *const TraceCode, instr_idx: usize) bool {
        if (instr_idx >= self.instrs.len) return false;
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
            .astore, .astore_append, .hstore, .gstore, .sgm_setpos => return false,
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
