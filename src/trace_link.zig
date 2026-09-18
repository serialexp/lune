//! Native-link arming, exit-branch patching, promotion/demotion, entry
//! patches, and cache lifecycle — carved out of `trace.zig` (file-split pass).
//!
//! Every function here is a `TraceState` method body moved verbatim: free
//! functions taking `self: *TraceState`, re-exported inside `TraceState` as
//! forwarding decls (`pub const armNativeLink = trace_link.armNativeLink;`)
//! so every `self.armNativeLink(...)` spelling keeps working. Pure code
//! motion — behaviour identical by construction.

const std = @import("std");
const native_physical = @import("trace_native_registry.zig");
const trace_mod = @import("trace.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const trace_exec = @import("trace_exec.zig");
const jitdbg = @import("jitdbg.zig");
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;

const TraceState = trace_mod.TraceState;
const Trace = trace_mod.Trace;
const NativeLink = trace_mod.NativeLink;
const PromotedEdge = trace_mod.PromotedEdge;
const ArmKind = trace_mod.ArmKind;
const EntryPatch = trace_mod.EntryPatch;
const EntryPatchState = trace_mod.EntryPatchState;
const Gate = trace_mod.Gate;
const GateReason = trace_mod.GateReason;
const AnchorKey = trace_mod.AnchorKey;
const ExitKey = trace_mod.ExitKey;
const ProgramPoint = trace_mod.ProgramPoint;
const StructuralEdgeId = trace_mod.StructuralEdgeId;
const RegionId = trace_mod.RegionId;
const RegionKey = trace_mod.RegionKey;
const RegionDef = trace_mod.RegionDef;
const RegionBridgeDef = trace_mod.RegionBridgeDef;
const ExitProvenance = trace_mod.ExitProvenance;
const ExitProvEntry = trace_mod.ExitProvEntry;
const GuardKey = trace_mod.GuardKey;
const ChargeKind = trace_mod.ChargeKind;
const IrOp = trace_mod.IrOp;
const IrInstr = trace_mod.IrInstr;
const Ref = trace_mod.Ref;
const PHI_INTERNAL = trace_mod.PHI_INTERNAL;
const guardExitPc = trace_mod.guardExitPc;
const guardSourcePc = trace_mod.guardSourcePc;
const isSideExitGuardOp = trace_mod.isSideExitGuardOp;
const isLoopDoneGuardIndex = trace_mod.isLoopDoneGuardIndex;
const isWhileLoopDoneGuardIndex = trace_mod.isWhileLoopDoneGuardIndex;
const isAnyLoopDoneGuardIndex = trace_mod.isAnyLoopDoneGuardIndex;
const whileLoopDonePostPc = trace_mod.whileLoopDonePostPc;
const ProvenanceEdge = trace_mod.ProvenanceEdge;
const ProvenanceAction = trace_mod.ProvenanceAction;
const ProvenanceVerdict = trace_mod.ProvenanceVerdict;
const hotIndex = trace_mod.hotIndex;

const exitOrder = trace_mod.exitOrder;
// pub'd in trace.zig for trace_link.zig (file-split pass):
const isInnerLoopRoot = TraceState.isInnerLoopRoot;
const exitIsPreEffect = TraceState.exitIsPreEffect;
const bumpGen = TraceState.bumpGen;
const freeRegionBridges = trace_mod.freeRegionBridges;

/// True when a native trace has a link-terminated continuation waiting at one
/// of its numeric-for loop-done exits. The dispatcher uses this before native
/// entry so the original run can commit the final iteration in linked mode;
/// after a normal native deopt the pre-run snapshot needed for that commit is
/// already gone.
pub fn hasNativeLoopDoneLink(self: *const TraceState, failed: *Trace, proto: *const Proto) bool {
    // Doc 44 D9 (review round 3) / D12b: a one-shot trace (head or cont) has
    // no loop-done exits by construction — its guards deopt to its entry pc,
    // never to a post-loop pc. The body scan below matches `guard_true` exit
    // pcs against `proto.code` shapes and could collide with a coincident
    // link-terminated trace; refuse the kind explicitly (the D1
    // discipline), BEFORE the memo, so both entry paths structurally
    // select ordinary mode for one-shot anchors.
    if (trace_mod.anchorKind(failed.code.anchor.pc) != .loop) return false;
    // Memoized under `cache_gen` (see `Trace.ldl_memo_*`): the answer only
    // changes when the trace cache does (`nextTraceExcluding` reads it), and
    // this runs once per native dispatch.
    if (failed.ldl_memo_gen == self.registry.cache_gen) return failed.ldl_memo;
    const answer = self.computeNativeLoopDoneLink(failed, proto);
    failed.ldl_memo = answer;
    failed.ldl_memo_gen = self.registry.cache_gen;
    return answer;
}

pub fn computeNativeLoopDoneLink(self: *const TraceState, failed: *const Trace, proto: *const Proto) bool {
    for (failed.code.instrs) |ins| {
        if (ins.op != .guard_true) continue;
        const exit_pc = guardExitPc(ins) orelse continue;
        if (exit_pc == 0 or exit_pc == failed.code.anchor.pc or exit_pc > proto.code.len) continue;
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
            if (sct.code.instrs.len != 0 and sct.code.instrs[sct.code.instrs.len - 1].op == .link) return true;
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
    const ins = failed.code.instrs[exit_instr];
    // Only a loop-continuation `guard_true` failing marks "loop ran to
    // completion"; a body type-guard (`guard_int`/…) failing is a different,
    // mid-iteration exit and must not seed a continuation.
    if (ins.op != .guard_true) return;
    const exit_pc = guardExitPc(ins) orelse return;
    if (exit_pc == 0 or exit_pc == failed.code.anchor.pc) return;
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
    if (!continuationReachesEnclosingBackEdge(proto, cont_pc, failed.code.anchor.pc)) {
        self.dbg("cont-arm refuse: no enclosing back-edge from pc={d} (inner anchor {d})", .{ cont_pc, failed.code.anchor.pc });
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
    self.dbg("cont-arm: pending at pc={d} (inner anchor {d})", .{ cont_pc, failed.code.anchor.pc });
    self.pending_exit_anchor = key;
}

pub fn continuationReachesEnclosingBackEdge(proto: *const Proto, start_pc: u32, inner_anchor: u32) bool {
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
    // Doc 43 P0a: seed the anchor's absolute slab base (same as armWithPolicy).
    // Missing this left `anchor_abs_base = 0`, making the open-upvalue aliasing
    // guard fire on ALL open upvalues regardless of frame depth.
    // Doc 43 P0a: seed the anchor's absolute slab base (same as armWithPolicy).
    // Missing this left `anchor_abs_base = 0`, making the open-upvalue aliasing
    // guard fire on ALL open upvalues regardless of frame depth.
    self.rec.anchor_abs_base = self.pending_anchor_base;
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
    // Doc 43 P0a: seed the anchor's absolute slab base (same as armWithPolicy).
    self.rec.anchor_abs_base = self.pending_anchor_base;
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
    if (self.recordingBarred(t.code.anchor)) return;
    // Doc 44 D8 (P1a) / D12b: ONE-SHOT route (head + cont), before the
    // branch/generic routes. A one-shot guard fail is coherent at the entry
    // pc — the alternate path is a same-anchor SIBLING, so raise the
    // sibling want (an EXACT AnchorKey; the consumer matches it exactly)
    // and, decisively, do NOT `markEntryPatchesAt`: the patched pc is the
    // SOLE entry for every sibling (no virgin back-edge walk to re-arm
    // through). Consumed on the CURRENT activation by `enterPatchedTrace`
    // after the whole sibling walk declines.
    if (trace_mod.anchorKind(t.code.anchor.pc) != .loop) {
        if (self.wants_head_sibling != null) return;
        if (self.anchorPopulation(t) >= self.config.max_traces_per_anchor) return;
        self.dbg("hotexit: trace id={d} exit={d} count={d} -> want HEAD sibling", .{ t.id, exit_instr, c.* });
        self.wants_head_sibling = t.code.anchor;
        self.head_want_src = .{ .trace_id = t.id, .exit_instr = exit_instr };
        return;
    }
    const branch = self.isSourceBranchGuardExit(t, exit_instr, proto) and blk: {
        const src_pc = guardSourcePc(t.code.instrs[exit_instr]) orelse break :blk false;
        if (src_pc >= proto.code.len) break :blk false;
        break :blk switch (proto.code[src_pc].op) {
            .jmp_if_false, .jmp_if_true, .jmp_if_not_nil => true,
            else => false,
        };
    };
    if (branch) {
        if (self.wants_prime_side != null) return;
        if (self.anchorPopulation(t) >= 2) return;
        self.dbg("hotexit: trace id={d} exit={d} count={d} -> want PRIME side at pc={d}", .{ t.id, exit_instr, c.*, t.code.anchor.pc });
        self.wants_prime_side = t.code.anchor;
        self.prime_want_src = .{ .trace_id = t.id, .exit_instr = exit_instr };
        // Doc 20 unpatch trigger (same rationale as `wants_side_trace`):
        // prime-side arming also runs through the virgin `onBackEdge` path.
        self.markEntryPatchesAt(t.code.anchor);
    } else if (completed == 0) {
        if (self.wants_side_trace != null) return;
        if (self.anchorPopulation(t) >= self.config.max_traces_per_anchor) return;
        self.dbg("hotexit: trace id={d} exit={d} count={d} -> want side at pc={d}", .{ t.id, exit_instr, c.*, t.code.anchor.pc });
        self.wants_side_trace = t.code.anchor;
        self.side_want_src = .{ .trace_id = t.id, .exit_instr = exit_instr };
        // Doc 20 unpatch trigger: side-arming needs the virgin `onBackEdge`
        // path at this anchor next execution — mark any patch pending.
        self.markEntryPatchesAt(t.code.anchor);
    }
}

/// Doc 44 D8 (P1a): a head trace at `anchor` completed terminally. If a
/// head-sibling want is standing for this anchor, retire it: clear the want
/// and DONE-latch the raising `(trace, exit)` counter — without the latch a
/// saturated incumbent exit re-raises the want on its next zero exit and the
/// anchor records duplicate shapes until the population cap (review round 2
/// blocker 3). Deterministic: pure function of the want state.
pub fn noteHeadSiblingCompletion(self: *TraceState, anchor: AnchorKey, completed_id: u32) void {
    const wanted = self.wants_head_sibling orelse return;
    if (wanted.proto != anchor.proto or wanted.pc != anchor.pc) return;
    if (self.head_want_src) |src| {
        // The want's SOURCE completing proves only its own path still runs —
        // the failing path stays uncovered, so the want stands. Any OTHER
        // sibling completing on this anchor was reached because the walk fell
        // past the source's zero exit: that path is now covered.
        if (src.trace_id == completed_id) return;
        if (self.traceById(src.trace_id)) |parent| {
            if (src.exit_instr < parent.exit_counts.len)
                parent.exit_counts[src.exit_instr] = trace_mod.Trace.EXIT_COUNT_DONE;
        }
    }
    self.wants_head_sibling = null;
    self.head_want_src = null;
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
/// `failed.code.instrs[exit_instr]` is a *source-level branch guard* exit — a
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
    const ins = failed.code.instrs[exit_instr];
    if (ins.op != .guard_true and ins.op != .guard_false) return false;
    const exit_pc = guardExitPc(ins) orelse return false;
    if (exit_pc == 0 or exit_pc == failed.code.anchor.pc) return false;
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
    if (child.code.anchor.proto != parent.code.anchor.proto or child.code.anchor.pc != parent.code.anchor.pc) return false;
    if (!self.isSourceBranchGuardExit(parent, slot, proto)) return false;
    for (self.registry.native_physical.armedLinks()) |l| {
        if (l.parent == parent and l.child == child and l.slot_index == slot) return true;
    }
    return false;
}

/// How many cached traces are at this anchor? `pub` so the dispatcher's M1 fused
/// consumer (interp.zig) can assert the skip+prime-side pair coexist (≥ 2).
pub fn countTracesAt(self: *const TraceState, anchor: AnchorKey) usize {
    var n: usize = 0;
    for (self.registry.cache.items) |t| {
        if (t.code.anchor.proto == anchor.proto and t.code.anchor.pc == anchor.pc) n += 1;
    }
    return n;
}

/// Memoized `countTracesAt(t.code.anchor)` for per-receipt hot paths
/// (`noteTakenExit`): one gen compare in steady state, full scan only after a
/// cache mutation (`cache_gen` bump). Results are identical to the scan by
/// construction.
pub fn anchorPopulation(self: *const TraceState, t: *Trace) usize {
    if (t.anchor_pop_gen != self.registry.cache_gen) {
        t.anchor_pop = @intCast(self.countTracesAt(t.code.anchor));
        t.anchor_pop_gen = self.registry.cache_gen;
    }
    return t.anchor_pop;
}

/// True iff some cached trace at `(proto, pc)` has inner-loop-root shape. Used by
/// `.link_terminal` successor resolution (A-ii.2) to confirm the named inner root
/// is bound — the `isInnerLoopRoot` shape (`inputs.len == 0` + `.loop` terminal)
/// that `findLoopTrace` omits.
pub fn hasInnerRootAt(self: *const TraceState, proto: *const Proto, pc: u32) bool {
    for (self.registry.cache.items) |t| {
        if (isInnerLoopRoot(t, proto, pc)) return true;
    }
    return false;
}

/// A-vii-d.1: the closing `for_loop` pc of the numeric loop whose body starts
/// at anchor `pc` — i.e. the unique `for_loop` op whose back-edge target is
/// `pc`. Null when none or ambiguous (fail-closed: the anchor then cannot be
/// elected as a closed region's enclosing owner). Static bytecode only; the
/// body span of the loop is `[pc, result]`.
pub fn forLoopEndFor(proto: *const Proto, pc: u32) ?u32 {
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
///     `wp != t.code.anchor.pc`, and a trace is bound at `(t.proto, wp)`.
/// The successor proto is `t.code.anchor.proto` — the same-proto assumption
/// `driveChain` makes (it threads one `proto` into `nextTraceExcluding`); a
/// cross-proto inlined-callee resume is a known deferred refinement (§A8-ii).
/// Returns `null` (no structural edge) for any exit whose successor is not a
/// compatibly-bound trace, or a non-PC-carrying guard.
pub fn resolveSuccessorAnchor(self: *const TraceState, t: *const Trace, e: ExitProvEntry) ?SuccAnchor {
    // Doc 44 D1/D12b: a one-shot trace (head or cont) contributes no edges to
    // the structural successor graph — it is never armed, promoted, or
    // region-owned, and the guard arm below would otherwise compare real exit
    // pcs against the sentinel/tagged pc (`wp != anchor.pc` is vacuously
    // true). Explicit kind check, fail-closed.
    if (trace_mod.anchorKind(t.code.anchor.pc) != .loop) return null;
    const proto = t.code.anchor.proto;
    switch (e.prov) {
        .link_terminal => {
            const li = t.code.instrs[e.index];
            if (li.op != .link) return null; // defensive: a .link_terminal must sit on a .link
            if (li.aux < 0) return null;
            const succ_pc: u32 = @intCast(li.aux);
            if (!self.hasInnerRootAt(proto, succ_pc)) return null;
            return .{ .proto_id = proto.id, .pc = succ_pc };
        },
        .guard => {
            if (guardExitPc(t.code.instrs[e.index])) |wp| {
                if (wp != 0 and wp != t.code.anchor.pc and
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
pub fn resolveCompositeBridgeSuccessor(self: *const TraceState, t: *const Trace, e: ExitProvEntry) ?SuccAnchor {
    const g = switch (e.prov) {
        .guard => |gp| gp,
        .link_terminal => return null,
    };
    // Non-inlined, same-proto, polarity-carrying branch provenance only
    // (d.1 review blocker: never widen an inlined exit using the parent
    // proto's bytecode).
    if (g.inline_depth != 0) return null;
    if (g.role != .branch_cond or g.polarity == .neutral) return null;
    const proto = t.code.anchor.proto;
    if (g.source_proto_id != proto.id) return null;
    if (!t.code.isBridgeCandidate(e.index)) return null;
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
        if (pc == t.code.anchor.pc) return null;
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
///     with the SAME update ref `R`, and `t.code.instrs[R]` is the `add` that
///     steps the index (`recForLoop` publishes the one `rnext` to both);
///   - a committed `.loop_done` guard (non-inlined, same proto, source pc
///     == `flp`) whose guarded `le` compare CONSUMES `R` — i.e. the loop
///     continue condition over exactly the value the bridge will commit
///     passed before the composite guard could fire.
/// Limit/step are not written by `for_loop`, so they may legitimately remain
/// edge-invariant; this proof is what gives `invariant = S \ E` its
/// soundness for the crossed-op slots (doc 17 A-vii-d.1 item 2).
pub fn compositeContinueProof(t: *const Trace, composite_ei: u32, flp: u32) bool {
    const proto = t.code.anchor.proto;
    if (flp >= proto.code.len or proto.code[flp].op != .for_loop) return false;
    const base: u16 = proto.code[flp].a;

    // Fetch the dominance-scoped phi update refs for idx and var.
    var idx_ref: ?u16 = null;
    var var_ref: ?u16 = null;
    var emitted = t.code.bridgeEmissions(composite_ei);
    while (emitted.next()) |p| {
        if (p.aux == @as(i32, @intCast(base))) idx_ref = p.b;
        if (p.aux == @as(i32, @intCast(base)) + 3) var_ref = p.b;
    }
    const r = idx_ref orelse return false;
    if (var_ref != r) return false;
    if (r >= t.code.instrs.len or t.code.instrs[r].op != .add) return false;

    // Find a dominating loop-continue guard for THIS for_loop whose compare
    // consumes exactly `r`.
    for (t.code.exit_prov) |ep| {
        if (ep.index >= composite_ei) break; // sorted ascending
        const gp = switch (ep.prov) {
            .guard => |gg| gg,
            .link_terminal => continue,
        };
        if (gp.role != .loop_done or gp.inline_depth != 0) continue;
        if (gp.source_proto_id != proto.id or gp.source_pc != flp) continue;
        const gi = t.code.instrs[ep.index];
        if (gi.op != .guard_true) continue;
        const cmp_ref = gi.a;
        if (cmp_ref >= t.code.instrs.len) continue;
        const cmp = t.code.instrs[cmp_ref];
        if (cmp.op != .le) continue;
        if (cmp.a == r or cmp.b == r) return true;
    }
    return false;
}

pub const PROMOTED_SET_CAP: usize = 16;
// At most 16 promoted phases can contribute prefix relations. A 32-row
// reporting suffix can evidence at most 31 distinct parent→child relations
// (each needs a following row), so the merged maximum is 47. Allocate 48 by
// the natural component sum and keep every overflow path release-panicking.
pub const PROVENANCE_VERDICT_CAP: usize = PROMOTED_SET_CAP + trace_exec.LEDGER_CAP;

pub const exitPatchFor = native_physical.exitPatchFor;

pub fn patchKindForArm(kind: ArmKind) ?nativegen.ExitPatchKind {
    return switch (kind) {
        .ordinary_guard, .sibling_handoff => .deopt,
        .link_terminal => .link_terminal,
        .loop_done_linked => .loop_done_linked,
        .region_bridge => .region_bridge,
        .ret_cont, .call_head => null,
    };
}

pub const BridgeValidationError = error{
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
pub fn validateRegionBridgeReceipt(self: *TraceState, owner: *Trace, exit: u32, succ: *Trace) BridgeValidationError!StructuralEdgeId {
    if (!owner.code.isBridgeCandidate(exit)) return error.NotComposite;
    var armed_link: ?*const NativeLink = null;
    for (self.registry.native_physical.armedLinks()) |*link| {
        if (link.parent != owner or link.slot_index != exit or link.child != succ) continue;
        if (link.kind != .region_bridge) return error.WrongArmKind;
        if (armed_link != null) return error.NoArmedProvenance;
        armed_link = link;
    }
    const link = armed_link orelse return error.NoArmedProvenance;
    const edge = memo: {
        if (link.bridge_edge) |cached| {
            if (link.bridge_edge_gen == self.region_policy.region_defs_gen) break :memo cached;
        }
        const region_id = link.region_id orelse return error.NoRegionProvenance;
        const prov = owner.code.provAt(exit) orelse return error.NoExitProvenance;
        const def = self.region_policy.region_defs.getPtr(region_id) orelse return error.RegionMissing;
        if (!def.armable) return error.RegionTombstoned;
        var registered: ?StructuralEdgeId = null;
        for (def.members) |member| {
            if (member.anchor_proto_id != owner.code.anchor.proto.id or
                member.anchor_pc != owner.code.anchor.pc or exitOrder(member.exit, prov) != .eq) continue;
            if (registered != null) return error.DuplicateEdge;
            registered = member;
        }
        const resolved = registered orelse return error.EdgeMissing;
        if (!self.registry.native_physical.memoizeBridgeEdge(owner, exit, succ, .{
            .id = region_id,
            .generation = link.armed_gen,
        }, resolved, self.region_policy.region_defs_gen)) return error.NoArmedProvenance;
        break :memo resolved;
    };
    if (edge.succ_anchor_proto_id != succ.code.anchor.proto.id or edge.succ_anchor_pc != succ.code.anchor.pc)
        return error.SuccessorMismatch;
    return edge;
}

/// Re-check the activation-local static shapes in release mode. The arm path
/// proved these once; promotion deliberately does not trust historical proof.
pub fn promotedEdgeFromLink(self: *TraceState, link: NativeLink) ?PromotedEdge {
    const kind = patchKindForArm(link.kind) orelse return null;
    const compiled = switch (link.parent.native) {
        .compiled => |*c| c,
        else => return null,
    };
    if (link.slot_index >= link.parent.code.instrs.len or link.slot_index >= compiled.slots.len)
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
        .ordinary_guard, .loop_done_linked, .sibling_handoff, .region_bridge, .ret_cont, .call_head => .ordinary,
    }, link.child.code.anchor.proto)) return null;
    const target = switch (link.kind) {
        .link_terminal => child_compiled.linked_entry orelse return null,
        .ordinary_guard, .loop_done_linked, .sibling_handoff, .ret_cont, .call_head => child_compiled.ordinary_entry orelse return null,
        .region_bridge => child_compiled.ordinary_entry orelse return null,
    };
    if (compiled.slots[link.slot_index] != target) return null;

    const resume_pc: u32 = switch (link.kind) {
        .ret_cont, .call_head => return null, // frame-motion links never promote
        .sibling_handoff => blk: {
            if (link.parent.code.anchor.proto != link.child.code.anchor.proto or
                link.parent.code.anchor.pc != link.child.code.anchor.pc or
                !exitIsPreEffect(link.parent, link.slot_index)) return null;
            break :blk link.child.code.anchor.pc;
        },
        .ordinary_guard => blk: {
            if (link.parent.code.anchor.proto != link.child.code.anchor.proto or
                isLoopDoneGuardIndex(link.parent, link.slot_index) or
                link.parent.code.isBridgeCandidate(link.slot_index)) return null;
            // M1's child is an ordinary-entry ramp, but any terminal child
            // deopt/prologue-fail is coherent at the SOURCE header.
            break :blk link.parent.code.anchor.pc;
        },
        .link_terminal => blk: {
            const ins = link.parent.code.instrs[link.slot_index];
            if (ins.op != .link or ins.aux < 0 or
                link.parent.code.anchor.proto != link.child.code.anchor.proto or
                @as(u32, @intCast(ins.aux)) != link.child.code.anchor.pc) return null;
            break :blk link.child.code.anchor.pc;
        },
        .loop_done_linked => blk: {
            if (link.parent.code.anchor.proto != link.child.code.anchor.proto or
                !isLoopDoneGuardIndex(link.parent, link.slot_index)) return null;
            const post_pc = guardExitPc(link.parent.code.instrs[link.slot_index]) orelse return null;
            if (post_pc != link.child.code.anchor.pc) return null;
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

pub const PromotionRejectReason = enum {
    bridge_member,
    region_mismatch,
    open_chain,
    child_mismatch,
    no_patch_point,
    cap,
    region_owned,
};

pub fn rejectPromotion(self: *TraceState, reason: PromotionRejectReason) ?[]PromotedEdge {
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

pub fn rowPatchKind(kind: trace_exec.LedgerKind) ?nativegen.ExitPatchKind {
    return switch (kind) {
        .deopt => .deopt,
        .link_terminal => .link_terminal,
        .loop_done_linked => .loop_done_linked,
        .region_bridge => .region_bridge,
        .prologue_fail => null,
        // Doc 22 §B.2: seed declines are entry-condition mismatches, not
        // guard failures — there is no exit branch to patch.
        .seed_hash_decline, .seed_capacity_decline => null,
        // Doc 44 P0: a head trace's terminal is a completion through
        // shared_exit (slot_addr = null) — there is no exit branch to patch.
        .head_terminal => null,
        // Frame-motion transitions use dedicated trailing slot cells.
        .ret_pop, .call_push => null,
        // Doc 45 D6: precise exits carry no patch window — a precise trace
        // is never a chain source, so there is no exit branch to patch.
        .precise_deopt, .precise_error => null,
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
pub fn edgeMemberOfRegion(self: *TraceState, edge: PromotedEdge, region_id: RegionId, require_bridge_stamp: bool) bool {
    if (!self.regionMemberPoint(region_id, edge.parent.code.anchor.proto.id, edge.parent.code.anchor.pc) or
        !self.regionMemberPoint(region_id, edge.child.code.anchor.proto.id, edge.child.code.anchor.pc))
        return false;
    if (edge.arm_kind == .region_bridge and require_bridge_stamp) {
        var matching: ?*const NativeLink = null;
        for (self.registry.native_physical.armedLinks()) |*link| {
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
    const def = self.region_policy.region_defs.get(key.region_id) orelse return false;
    if (!def.armable) return false;
    const accum = self.region_policy.region_profit.get(key) orelse return false;
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
pub fn detectPromotableSet(self: *TraceState, entries: []const trace_exec.LedgerEntry, key: RegionKey) ?[]PromotedEdge {
    return detectPromotableSetMembers(self, entries, key, entries.len);
}

/// Doc 52: the detector core with an explicit membership bound. The full-cap
/// grammar checks EVERY row for candidate membership (`member_rows ==
/// entries.len`); the recurrence grammar exempts the final natural-terminal
/// row (`member_rows == entries.len - 1`) — it is a NON-member unpatched
/// exit, the burst's future reporting suffix. Child adjacency is always
/// checked over the FULL ledger: for every member row `i` with a successor
/// row, the matched edge's armed child must own `entries[i + 1]` — so the
/// last member row's successor proof is the terminal row's owner, never
/// dropped by slicing the ledger before detection.
pub fn detectPromotableSetMembers(
    self: *TraceState,
    entries: []const trace_exec.LedgerEntry,
    key: RegionKey,
    member_rows: usize,
) ?[]PromotedEdge {
    std.debug.assert(member_rows <= entries.len);
    const def = self.region_policy.region_defs.get(key.region_id) orelse return self.rejectPromotion(.region_mismatch);
    if (!def.armable) return self.rejectPromotion(.region_mismatch);
    if (entries.len == 0 or member_rows == 0) return self.rejectPromotion(.open_chain);

    // Region-total candidate from the armed-link registry.
    var scratch: [PROMOTED_SET_CAP]PromotedEdge = undefined;
    var n: usize = 0;
    for (self.registry.native_physical.armedLinks()) |link| {
        const edge = self.promotedEdgeFromLink(link) orelse continue;
        if (!self.edgeMemberOfRegion(edge, key.region_id, true)) continue;
        if (self.registry.native_physical.exitIsPromoted(edge.parent.id, edge.exit))
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

    // Evidence: every MEMBER row ∈ candidate, kind-exact, per-adjacent-pair
    // child-match against the full ledger. Non-final rows are always
    // `.normal`-outcome materialized transitions, and a `.prologue_fail` row
    // can never match a candidate edge (`rowPatchKind` has no patch point for
    // it), so the grammar is total.
    for (entries[0..member_rows], 0..) |row, i| {
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

pub const originalRel32Target = native_physical.originalRel32Target;

pub fn patchPromotedEdge(self: *TraceState, edge: PromotedEdge, promote: bool) nativegen.PatchError!void {
    defer self.syncNativeInvalidation();
    return self.registry.native_physical.patchPromotedEdge(&self.registry.mcode_arena, edge, promote);
}

pub fn promoteSet(self: *TraceState, edges: []const PromotedEdge, region_key: RegionKey) !void {
    // Physical precedence (bounds, id space, region/exit ownership) is the
    // owner's `checkPromotable` — run it first so its errors keep priority
    // over policy validation, exactly as before the checks were shared.
    try self.registry.native_physical.checkPromotable(edges, region_key);
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
    }

    try self.registry.native_physical.promoteSet(&self.registry.mcode_arena, edges, region_key, self.config.min_useful);
    if (comptime jitdbg.enabled) {
        if (self.config.debug_log) {
            jitdbg.log("silent-promote: set={d} region={d} len={d}", .{
                self.registry.native_physical.next_promoted_set_id - 1, region_key.region_id, edges.len,
            });
            for (edges, 0..) |edge, i| {
                jitdbg.log("  edge[{d}]: {s}:{d} t={d} ei={d} kind={s} arm={s} -> {s}:{d} t={d} resume={d}", .{
                    i,
                    edge.parent.code.anchor.proto.name,
                    edge.parent.code.anchor.pc,
                    edge.parent.id,
                    edge.exit,
                    @tagName(edge.kind),
                    @tagName(edge.arm_kind),
                    edge.child.code.anchor.proto.name,
                    edge.child.code.anchor.pc,
                    edge.child.id,
                    edge.resume_pc,
                });
            }
        }
    }
}

pub fn resetPromotionCandidate(self: *TraceState) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.resetPromotionCandidate();
}

/// Production promotion gate: only a full forced-yield ledger from a frozen
/// activation is evidence, and the same canonical physical edge sequence must
/// be detected on consecutive observations.
pub fn considerSilentPromotion(self: *TraceState, entries: []const trace_exec.LedgerEntry) void {
    if (!self.config.silent_promotion_enabled) return;
    if (entries.len != trace_exec.LEDGER_CAP or entries[entries.len - 1].outcome != .yielded) {
        self.resetPromotionCandidate();
        // Doc 52: short natural-terminal ledgers carry the recurrence
        // evidence class; every other non-full-cap shape resets the streaks
        // inside the same funnel.
        tryRecurrencePromotion(self, entries);
        return;
    }
    // Doc 52: a full-cap ledger for any region is decisive evidence the
    // observed shape is NOT a short recurring burst — reset every def's
    // recurrence streak at the TOP of this branch, before dormant admission
    // can mutate eligibility (the simplest deterministic ordering).
    resetRecurrenceStreaks(self);
    // Demand-driven admission runs on the same evidence class as candidacy (a
    // full forced-yield ledger) but BEFORE the activation-context resolution:
    // a dormant region is out of the receipt maps, so no activation can be
    // open for it yet — the ledger itself is its only voice.
    tryDormantAdmission(self, entries);
    const ctx = self.region_policy.region_context orelse {
        self.resetPromotionCandidate();
        return;
    };
    const key = self.activeRegionFor(ctx.call_seq) orelse {
        self.resetPromotionCandidate();
        return;
    };
    const accum = self.region_policy.region_profit.get(key) orelse {
        self.resetPromotionCandidate();
        return;
    };
    if (!accum.frozen) {
        self.resetPromotionCandidate();
        return;
    }
    // Parked-proof reuse (codex C′): a clean `.region_close` parked this
    // region's last proven physical set. Re-promotion still goes through the
    // FULL fail-closed `promoteSet` validation (physical exit ownership, link
    // identity, membership, enterability) against this activation's frozen
    // accumulator — only the observational re-detection and the
    // `promote_after` streak are skipped: the set already proved it chains in
    // a prior activation of this same region, and the full-cap yielded
    // ledger above re-establishes present drain pressure. A proof that fails
    // validation is discarded (take semantics) and the normal detection path
    // resumes below.
    if (self.registry.native_physical.takeParkedProof(key.region_id)) |parked| {
        defer self.gpa.free(parked);
        if (self.promoteSet(parked, key)) |_| {
            self.silent_parked_reuses +|= 1;
            self.dbg("silent-promote: parked reuse rid={d} len={d}", .{ @intFromEnum(key.region_id), parked.len });
            if (self.region_policy.region_defs.getPtr(key.region_id)) |d| d.no_candidate_runs = 0;
            self.resetPromotionCandidate();
            return;
        } else |_| {
            self.dbg("silent-promote: parked proof stale rid={d}", .{@intFromEnum(key.region_id)});
        }
    }
    const detected = self.detectPromotableSet(entries, key) orelse {
        // Failed-opportunity settlement (doc 47 Increment B follow-up): a
        // full-cap yielded ledger for an ACTIVE frozen fallback region that
        // yields no promotable candidate means the region was admitted on
        // evidence its physical topology no longer supports. Bounded count,
        // reset by a successful promotion; at the threshold, invalidate — the
        // per-receipt accounting tax has no remaining payoff path.
        if (self.region_policy.region_defs.getPtr(key.region_id)) |d| {
            if (d.fallback_owner and !d.dormant and !d.tombstoned) {
                d.no_candidate_runs +|= 1;
                if (d.no_candidate_runs >= self.config.region_no_candidate_tombstone) {
                    self.dbg("region: no-candidate tombstone rid={d}", .{@intFromEnum(key.region_id)});
                    self.invalidateRegion(key.region_id);
                }
            }
        }
        self.resetPromotionCandidate();
        return;
    };
    self.silent_promotion_candidates +|= 1;
    const streak = self.registry.native_physical.observePromotionCandidate(detected, key);
    const threshold = @max(self.config.promote_after, 1);
    if (streak < threshold) return;
    self.promoteSet(self.registry.native_physical.promotionCandidate(), key) catch |err| {
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
    // A successful promotion clears the region's failed-opportunity debt
    // (settlement counts only CONSECUTIVE dry runs). It does NOT touch the
    // net-work ledger: "a promotion occurred" is not "the promotion repaid
    // the receipt tax" — repayment is measured in suppressed transitions
    // credited at burst drain (grid_matmul promotes 200+ times while staying
    // net-negative).
    if (self.region_policy.region_defs.getPtr(key.region_id)) |d| {
        d.no_candidate_runs = 0;
    }
    self.resetPromotionCandidate();
}

/// Demand-driven admission of dormant fallback regions (doc 47 Increment B
/// follow-up). A fallback-elected region mints DORMANT: excluded from the
/// source/dest receipt maps, so `receiptsInert()` keeps short-circuiting and
/// the per-receipt classify/credit tax is never paid for it. This probe runs
/// once per full-cap forced-yield ledger — the exact evidence that LEDGER_CAP
/// drain pressure exists AND (via the same set proof as candidacy) that the
/// region owns a promotable armed set which could absorb it. One qualifying
/// ledger admits (the existing `promote_after` streak then supplies
/// confirmation before anything is patched); repeated failures saturate
/// `admission_failures` and end probing — terminal dormancy, bounding the
/// probe cost on shapes that never qualify (spectral-norm: 2 minted regions,
/// zero promotable ledgers, +16% wall pre-admission-gating).
fn tryDormantAdmission(self: *TraceState, entries: []const trace_exec.LedgerEntry) void {
    if (self.region_policy.region_defs.count() == 0) return;
    // Order-independence (codex): probe EVERY eligible dormant region before
    // publishing anything — hashmap iteration order must never decide which
    // region admits or which regions get charged a failure. Every
    // non-matching eligible region gains a failure; the winner is the
    // MINIMUM matching RegionId (deterministic; two disjoint regions cannot
    // both cover every row of one ledger unless memberships overlap).
    var winner: ?RegionId = null;
    var it = self.region_policy.region_defs.iterator();
    while (it.next()) |e| {
        const d = e.value_ptr;
        if (!d.fallback_owner or !d.dormant or !d.armable or d.tombstoned) continue;
        if (d.admission_failures >= self.config.region_admission_probe_cap) continue;
        // Probe with the candidacy proof. Reject diagnostics are production
        // candidacy telemetry — probes must not pollute them (success or
        // failure), so save/restore around every probe.
        const saved_rejects = self.silent_rejects;
        const probe_key: RegionKey = .{ .region_id = e.key_ptr.*, .activation = 0 };
        if (self.detectPromotableSet(entries, probe_key)) |edges| {
            self.gpa.free(edges);
            self.silent_rejects = saved_rejects;
            if (winner == null or @intFromEnum(e.key_ptr.*) < @intFromEnum(winner.?))
                winner = e.key_ptr.*;
        } else {
            self.silent_rejects = saved_rejects;
            d.admission_failures +|= 1;
        }
    }
    const rid = winner orelse return;
    const d = self.region_policy.region_defs.getPtr(rid).?;
    d.dormant = false;
    self.dbg("region: dormant admission rid={d} failures={d}", .{ @intFromEnum(rid), d.admission_failures });
    // The receipt maps are wholesale-built; rebuild so the admitted region
    // enters them. Safe here: the replay walk has returned (this runs from
    // the post-walk drain tail) and admission only ADDS armability — the
    // stale-bridge sweep sees an unchanged live-armable set.
    self.rebuildRegions();
}

// ---------------------------------------------------------------------------
// Doc 52: recurrence evidence for short natural-terminal bursts.
// ---------------------------------------------------------------------------

comptime {
    // The RegionDef signature arrays deliberately avoid a trace_exec import;
    // this is the pinned equivalence.
    std.debug.assert(trace_mod.RECURRENCE_SIG_CAP == trace_exec.LEDGER_CAP);
}

/// Doc 52: reset every def's recurrence streak. Called for every observed
/// non-qualifying dispatcher ledger — including the full-cap branch — and
/// deliberately unfiltered: resetting a non-eligible def's streak is a no-op
/// semantically and keeps the funnel one loop with no eligibility drift.
pub fn resetRecurrenceStreaks(self: *TraceState) void {
    var it = self.region_policy.region_defs.iterator();
    while (it.next()) |e| e.value_ptr.recurrence_streak = 0;
}

fn recurrenceEligible(d: *const RegionDef) bool {
    return d.fallback_owner and d.dormant and d.armable and !d.tombstoned;
}

fn recurrenceSigMatches(d: *const RegionDef, entries: []const trace_exec.LedgerEntry) bool {
    if (d.recurrence_len == 0 or d.recurrence_len != entries.len) return false;
    for (entries, 0..) |row, i| {
        if (d.recurrence_ids[i] != row.id or d.recurrence_exits[i] != row.exit or
            d.recurrence_kinds[i] != @intFromEnum(row.kind)) return false;
    }
    return true;
}

fn recurrenceSigStore(d: *RegionDef, entries: []const trace_exec.LedgerEntry) void {
    std.debug.assert(entries.len < trace_mod.RECURRENCE_SIG_CAP);
    d.recurrence_len = @intCast(entries.len);
    for (entries, 0..) |row, i| {
        d.recurrence_ids[i] = row.id;
        d.recurrence_exits[i] = row.exit;
        d.recurrence_kinds[i] = @intFromEnum(row.kind);
    }
}

/// Doc 52: the recurrence funnel — runs once per observed dispatcher ledger
/// that failed the full-cap gate. The steady state is signature-only
/// (fieldwise compares against a handful of defs, allocation-free); the
/// expensive region-total detector runs only at owner resolution of a new
/// signature, budget-bounded by `recurrence_probe_charges` per def.
///
/// A ledger qualifies as a recurrent pure burst iff `len ∈ [2, LEDGER_CAP)`
/// and its final row is a natural terminal in the STRICT class
/// `kind == .deopt ∧ reason == .normal ∧ outcome == .normal` (the same
/// predicate `noteDispatcherLedgerTerminal` keys on — `.normal` outcome
/// alone is overloaded: prologue fails and seed declines are also
/// `.normal`-outcome terminals). Membership then covers the NON-final rows
/// (`detectPromotableSetMembers` with `member_rows = len - 1`); the terminal
/// row additionally must not itself resolve to a candidate armed edge (an
/// armed chain source with ledger room dispatches onward — a terminal that
/// IS a live candidate means registry and execution disagree; never promote
/// on it).
///
/// P0 scope: evidence only. At the threshold the streak saturates and holds
/// ("held at threshold"); the resident promotion itself is doc 52 P1.
fn tryRecurrencePromotion(self: *TraceState, entries: []const trace_exec.LedgerEntry) void {
    if (self.region_policy.region_defs.count() == 0) return;
    const qualifies = entries.len >= 2 and entries.len < trace_exec.LEDGER_CAP and blk: {
        const term = entries[entries.len - 1];
        break :blk term.kind == .deopt and term.reason == .normal and term.outcome == .normal;
    };
    if (!qualifies) {
        resetRecurrenceStreaks(self);
        return;
    }
    // Cheap match: scan ALL eligible defs and take the MINIMUM RegionId whose
    // stored signature equals this ledger — never first-hit, which would make
    // the owner depend on hashmap iteration order (two defs can hold the same
    // signature: overlapping memberships, stale losers).
    var matched: ?RegionId = null;
    var it = self.region_policy.region_defs.iterator();
    while (it.next()) |e| {
        if (!recurrenceEligible(e.value_ptr)) continue;
        if (!recurrenceSigMatches(e.value_ptr, entries)) continue;
        if (matched == null or @intFromEnum(e.key_ptr.*) < @intFromEnum(matched.?))
            matched = e.key_ptr.*;
    }
    if (matched) |rid| {
        var it2 = self.region_policy.region_defs.iterator();
        while (it2.next()) |e| {
            if (e.key_ptr.* == rid) {
                e.value_ptr.recurrence_streak +|= 1; // saturating: held at threshold
            } else e.value_ptr.recurrence_streak = 0;
        }
        const d = self.region_policy.region_defs.getPtr(rid).?;
        self.dbg("recurrence: qualify rid={d} len={d} streak={d}/{d}", .{
            @intFromEnum(rid), entries.len, d.recurrence_streak, self.config.recurrence_promote_after,
        });
        if (d.recurrence_streak < @max(self.config.recurrence_promote_after, 1)) return;
        // Gates BEFORE any expensive work (doc 52, codex round 2 blocker 3).
        if (d.recurrence_probe_charges >= self.config.recurrence_probe_cap) {
            self.dbg("recurrence: probe-cap rid={d}", .{@intFromEnum(rid)});
            return;
        }
        // P1 gate slot: `resident_set_count != 0` blocks here (one-resident-
        // set invariant) once resident sets exist. P0 promotes nothing: the
        // saturating streak holds and P1 adds the threshold probe + resident
        // authorization at exactly this point.
        self.dbg("recurrence: threshold rid={d} held (promotion lands in doc 52 P1)", .{@intFromEnum(rid)});
        return;
    }
    // Owner resolution — the only other expensive path, budget-bounded.
    // Every probed def is charged, win or lose (alternating valid shapes
    // must saturate, not scan the armed registry forever). The winner is the
    // minimum matching RegionId; non-winning successful probes free their
    // candidate allocation. Reject diagnostics are production candidacy
    // telemetry — save/restore around every probe, as dormant admission does.
    var winner: ?RegionId = null;
    var it3 = self.region_policy.region_defs.iterator();
    while (it3.next()) |e| {
        const d = e.value_ptr;
        if (!recurrenceEligible(d)) continue;
        if (d.recurrence_probe_charges >= self.config.recurrence_probe_cap) continue;
        d.recurrence_probe_charges +|= 1;
        const saved_rejects = self.silent_rejects;
        const probe_key: RegionKey = .{ .region_id = e.key_ptr.*, .activation = 0 };
        if (detectPromotableSetMembers(self, entries, probe_key, entries.len - 1)) |edges| {
            defer self.gpa.free(edges);
            self.silent_rejects = saved_rejects;
            // Grammar 3: the terminal row must not be a live candidate edge.
            const term = entries[entries.len - 1];
            var terminal_is_candidate = false;
            for (edges) |edge| {
                if (edge.parent.id == term.id and edge.exit == term.exit) {
                    terminal_is_candidate = true;
                    break;
                }
            }
            if (terminal_is_candidate) continue;
            if (winner == null or @intFromEnum(e.key_ptr.*) < @intFromEnum(winner.?))
                winner = e.key_ptr.*;
        } else {
            self.silent_rejects = saved_rejects;
        }
    }
    const rid = winner orelse {
        // A qualifying ledger that NO def owns still breaks every
        // in-progress streak: the streak is defined over CONSECUTIVE
        // identical observed ledgers, and this observation wasn't identical
        // to any streak-holder's shape.
        resetRecurrenceStreaks(self);
        return;
    };
    var it4 = self.region_policy.region_defs.iterator();
    while (it4.next()) |e| e.value_ptr.recurrence_streak = 0;
    const d = self.region_policy.region_defs.getPtr(rid).?;
    recurrenceSigStore(d, entries);
    d.recurrence_streak = 1;
    self.dbg("recurrence: owner-resolve rid={d} len={d} charges={d}", .{
        @intFromEnum(rid), entries.len, d.recurrence_probe_charges,
    });
}

pub const DemotionReason = native_physical.DemotionReason;
pub const PendingDemotion = native_physical.PendingDemotion;

pub fn queueDemote(self: *TraceState, id: u32, reason: DemotionReason) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.queueDemote(id, reason);
}

pub fn demoteSet(self: *TraceState, idx: usize) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.demoteSet(&self.registry.mcode_arena, idx);
}

pub fn demoteSetReason(self: *TraceState, idx: usize, reason: DemotionReason) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.demoteSetReason(&self.registry.mcode_arena, idx, reason);
}

pub fn demoteSetsTouching(self: *TraceState, parent: *Trace, exit: u32) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.demoteSetsTouching(&self.registry.mcode_arena, parent, exit);
}

pub fn demoteSetsTouchingTrace(self: *TraceState, trace: *Trace) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.demoteSetsTouchingTrace(&self.registry.mcode_arena, trace);
}

pub fn demoteAllSets(self: *TraceState) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.demoteAllSets(&self.registry.mcode_arena);
}

pub fn demoteSetsForRegionDefsMutation(self: *TraceState) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.demoteSetsForRegionDefsMutation(&self.registry.mcode_arena);
}

pub const SlotMutationReason = native_physical.SlotMutationReason;
pub const PreparedSlotMutation = native_physical.PreparedSlotMutation;

/// Phase 1 of the sole physical slot-write funnel. B-3a validates ownership and
/// bounds; B-3b will demote a promotion owning this physical exit here.
pub fn prepareSlotMutation(self: *TraceState, parent: *Trace, exit: u32, reason: SlotMutationReason) !PreparedSlotMutation {
    defer self.syncNativeInvalidation();
    return self.registry.native_physical.prepareSlotMutation(&self.registry.mcode_arena, parent, exit, reason);
}

/// Phase 2 is infallible and occurs only after the caller's registry mutation.
pub fn commitSlotMutation(self: *TraceState, prepared: PreparedSlotMutation, target: usize) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.commitSlotMutation(prepared, target);
}

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
/// INVARIANT: every post-compilation `CompiledTrace.slots[i]` write goes through
/// `prepareSlotMutation` + `commitSlotMutation`.
pub const RegionArmProof = native_physical.RegionArmProof;

pub const ArmRequest = native_physical.ArmRequest;

pub fn armNativeLink(self: *TraceState, parent: *Trace, slot_index: u32, child: *Trace, kind: ArmKind) !bool {
    return arm(self, .{ .parent = parent, .slot_index = slot_index, .child = child, .kind = kind });
}

/// Publish the complete relation before its executable slot. Region policy must
/// supply its proof here, never amend an already-published registry row.
pub fn arm(self: *TraceState, request: ArmRequest) !bool {
    const parent = request.parent;
    const slot_index = request.slot_index;
    const child = request.child;
    const kind = request.kind;
    if (request.region != null and kind != .region_bridge) return false;
    const c = switch (parent.native) {
        .compiled => |*cc| cc,
        else => return false,
    };
    // Logical keys and physical cells differ for frame links. Ordinary kinds
    // name an IR instruction; ret_cont names a bytecode resume PC; call_head
    // names the continuation's terminal IR instruction. Physical translation
    // and bounds are registry-owned.
    switch (kind) {
        .ret_cont => if (slot_index >= parent.code.anchor.proto.code.len) return false,
        .call_head => if (slot_index >= parent.code.instrs.len or parent.code.instrs[slot_index].op != .terminal) return false,
        // Legacy fixtures may omit synthetic IR while still providing physical
        // slots. Production traces have one physical slot per IR instruction.
        else => if (slot_index >= parent.code.instrs.len and slot_index >= c.slots.len) return false,
    }
    // Doc 39 (v1): no fusion into or out of a PEELED trace. The run wrapper's
    // +1 local-completion adjustment (a peeled first back-edge closes two
    // tier-0 iterations) is applied at the unfused seam only — a fused span's
    // per-hop counts come from the raw rbx ledger, which cannot express the
    // split. Refusing the arm keeps every peeled run unfused and the
    // accounting exact on both sides.
    if (parent.code.peeled or child.code.peeled) return false;
    // Doc 45 D6 (P2): no native link INTO or OUT OF a PRECISE page — a
    // precise guard exit must reach the dispatcher's `.precise_resume`
    // consumer, never jump to another trace, and nothing may fuse into a
    // page whose exits carry snapshot contracts the burst machinery cannot
    // honor. Structurally unreachable today (precise never compiles to
    // native, and `.compiled` is required above), but the doc mandates the
    // predicate at the arm boundary explicitly.
    if (parent.code.deopt_mode == .precise or child.code.deopt_mode == .precise) return false;
    // P-C option (b) invariant (2.3c-0a): a numeric-for loop-done guard's slot is
    // exclusively its linked-materialized exit. Enforce that the arm's declared kind
    // matches the slot's guard shape — a mismatch is a wiring bug (assert in debug),
    // and fail closed (leave the slot unarmed) in release. The emission half (0f)
    // already routes a loop-done ordinary deopt around `slot[ei]`; this closes the
    // arming half so no ordinary/link arm can ever write a loop-done slot (and no
    // loop-done arm can land on a non-loop-done slot).
    const is_loopdone = isLoopDoneGuardIndex(parent, slot_index);
    // Doc 44 D10 (round 4, durable invariant) / D12b: one-shot-anchored slots
    // (head + cont) carry ONLY `.sibling_handoff` arms. Enforced here at the
    // single arm funnel — not just at the request sites — so the guarantee
    // survives future arm paths. (D12c's `.ret_cont`/`.call_head` kinds will
    // widen this switch as first-class branches.)
    const head_parent = trace_mod.anchorKind(parent.code.anchor.pc) != .loop;
    switch (kind) {
        .loop_done_linked => {
            std.debug.assert(is_loopdone);
            if (!is_loopdone) return false;
            if (head_parent) return false;
        },
        .link_terminal => {
            std.debug.assert(!is_loopdone);
            if (is_loopdone) return false;
            if (head_parent) return false;
        },
        .ordinary_guard => {
            std.debug.assert(!is_loopdone);
            if (is_loopdone) return false;
            if (head_parent) return false;
            // A-v bridge candidates must remain at shared_exit. In particular,
            // the older M1 ordinary-source arm must not accidentally publish a
            // composite back-edge into the new armed body.
            if (parent.code.isBridgeCandidate(slot_index)) return false;
        },
        .region_bridge => {
            std.debug.assert(!is_loopdone);
            if (is_loopdone) return false;
            if (head_parent) return false;
        },
        // Part S: same slot shape as `.ordinary_guard` (the stub is literally
        // the same code path) — never a loop-done slot (that one is reserved
        // for `.loop_done_linked`), never a bridge candidate (whose stub takes
        // the A-v bridge body instead of the plain resolve-through-slot path).
        .ret_cont => {
            if (!head_parent or trace_mod.anchorKind(child.code.anchor.pc) != .cont) return false;
            if (parent.code.anchor.proto != child.code.anchor.proto) return false;
            if (trace_mod.contAnchorPc(slot_index) != child.code.anchor.pc) return false;
            if (!self.stubEnterable(child, .ordinary, child.code.anchor.proto)) return false;
        },
        .call_head => {
            if (trace_mod.anchorKind(parent.code.anchor.pc) != .cont or
                trace_mod.anchorKind(child.code.anchor.pc) != .head) return false;
            if (parent.code.anchor.proto != child.code.anchor.proto) return false;
            if (!self.stubEnterable(child, .ordinary, child.code.anchor.proto)) return false;
        },
        .sibling_handoff => {
            std.debug.assert(!is_loopdone);
            if (is_loopdone) return false;
            if (parent.code.isBridgeCandidate(slot_index)) return false;
            // Doc 44 D10: a head arm's fused ledger grammar has no
            // `seed_hash_decline` terminal — the burst consumer cannot replay
            // a hash-seeded child's tier-1a rerun mid-episode. Exclude the
            // case at ARM time instead of teaching the consumer about it.
            if (head_parent) {
                const child_cc = switch (child.native) {
                    .compiled => |*cc| cc,
                    else => return false,
                };
                if (child_cc.has_hash_seed) return false;
            }
            // Re-proved at arm time, not merely trusted from the watch: this is
            // the predicate that makes the handoff sound (`exitIsPreEffect`), and
            // the validator is the last gate before a physical slot is patched.
            if (!exitIsPreEffect(parent, slot_index)) return false;
            // The defining property: parent and child share an anchor.
            if (child.code.anchor.proto != parent.code.anchor.proto or
                child.code.anchor.pc != parent.code.anchor.pc) return false;
            // B-iv.3 (doc 22 §B.5): the page prologue owns the seeding
            // (§B.4), so a seeded child IS stub-enterable when its episode
            // ctx is fresh — consult the shared predicate instead of the
            // pre-B-iv "ordinary_entry cannot seed" blanket rule.
            if (!self.stubEnterable(child, .ordinary, child.code.anchor.proto)) return false;
        },
    }
    defer self.syncNativeInvalidation();
    self.registry.native_physical.debug_log = self.config.debug_log;
    const outcome = try self.registry.native_physical.publishValidatedLink(&self.registry.mcode_arena, request);
    if (outcome == .changed) self.noteMembershipGrowth(parent, slot_index, child, kind);
    return outcome != .declined;
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
pub fn noteMembershipGrowth(self: *TraceState, parent: *Trace, slot_index: u32, child: *Trace, kind: ArmKind) void {
    if (self.registry.native_physical.promotedSets().len == 0 and
        self.registry.native_physical.parked_proofs.items.len == 0) return;
    if (self.registry.native_physical.exitIsPromoted(parent.id, slot_index))
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
    var i = self.registry.native_physical.promotedSets().len;
    while (i > 0) {
        i -= 1;
        const s = self.registry.native_physical.promotedSets()[i];
        if (!self.edgeMemberOfRegion(edge, s.region_key.region_id, false)) continue;
        self.dbg("membership growth: parent id={d} slot={d} kind={s} demotes set={d} region={d}", .{
            parent.id, slot_index, @tagName(kind), s.id, s.region_key.region_id,
        });
        self.demoteSetReason(i, .membership_growth);
    }
    // Parked proofs hold to the SAME region-total invariant (§B3.17 R1,
    // codex round-4 blocker): a proof is a claim that its set covered the
    // region's whole armed-edge population, and a new armable member edge of
    // that region falsifies the claim — reuse would promote a set whose
    // uncovered rows surface only in suffix ledgers, permanently. An edge
    // already IN the proof changes nothing physically and may stay (identical
    // convergence re-arms short-circuit before this trigger anyway; the
    // covered check is belt-and-braces).
    var j = self.registry.native_physical.parked_proofs.items.len;
    while (j > 0) {
        j -= 1;
        const p = self.registry.native_physical.parked_proofs.items[j];
        if (!self.edgeMemberOfRegion(edge, p.region_id, false)) continue;
        var covered = false;
        for (p.edges) |pe| {
            if (pe.parent.id == edge.parent.id and pe.exit == edge.exit and
                pe.child.id == edge.child.id and pe.kind == edge.kind and
                pe.arm_kind == edge.arm_kind and pe.resume_pc == edge.resume_pc)
            {
                covered = true;
                break;
            }
        }
        if (covered) continue;
        self.dbg("membership growth: drops parked proof region={d}", .{@intFromEnum(p.region_id)});
        self.registry.native_physical.dropParkedProof(p.region_id);
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
pub fn armLinkTerminal(self: *TraceState, cont: *Trace, inner: *Trace, safe_to_arm: bool) void {
    // Observation blackout (2.3c-0e): never widen an armed cycle while suspend /
    // replay-line recording is active.
    if (!safe_to_arm) return;
    // The parent must end in a `.link` terminal whose aux names the inner root.
    if (cont.code.instrs.len == 0) return;
    const term = cont.code.instrs[cont.code.instrs.len - 1];
    if (term.op != .link) return;
    // The child must be the shape `replayLedger`'s fused `.link_terminal`
    // successor validation release-panics on anything but: an inner loop
    // root in the same proto at exactly the `.link`-named PC (B-iv.3:
    // seeded roots included — enterability checked below).
    if (!isInnerLoopRoot(inner, cont.code.anchor.proto, @intCast(term.aux))) return;
    // Both ends need native code: the parent for its slot table, the child for
    // the `linked_entry` the arm derives (`armNativeLink` re-checks; missing
    // native on either side must no-op silently, not assert).
    if (self.nativeFor(cont) == null or self.nativeFor(inner) == null) return;
    // B-iv.3 (doc 22 §B.5): mirror the scalar call-A arm site's widened
    // gate — a seeded inner arms only while stub-enterable (fresh ctx).
    if (!self.stubEnterable(inner, .linked, cont.code.anchor.proto)) return;
    const slot: u32 = @intCast(cont.code.instrs.len - 1);
    const armed = self.armNativeLink(cont, slot, inner, .link_terminal) catch false;
    if (armed) self.native_link_arms +|= 1;
}

pub fn armLoopDoneLink(self: *TraceState, inner: *Trace, guard_idx: u32, safe_to_arm: bool) void {
    // Observation blackout (2.3c-0e): never widen an armed cycle while suspend /
    // replay-line recording is active.
    if (!safe_to_arm) return;
    // The exit must be a real in-bounds loop-done guard on `inner`. Checked
    // explicitly HERE, not delegated to `armNativeLink`'s kind invariant: that
    // invariant's debug half is an assert (a wiring-bug tripwire), whereas a
    // mid-loop or prologue-fail exit index is a legitimately reachable input at
    // the call sites and must no-op silently.
    if (guard_idx == std.math.maxInt(u32) or guard_idx >= inner.code.instrs.len) return;
    if (!isLoopDoneGuardIndex(inner, guard_idx)) return;
    const post_pc = guardExitPc(inner.code.instrs[guard_idx]) orelse return;
    // B-4 (§B4.3 D3'): the arm target is CANONICAL — resolved positionally
    // at `post_pc` through the shared selector, never taken from whatever
    // continuation the caller happened to be holding. A caller-supplied
    // candidate could alternate between eligible siblings across paths,
    // and every changed relation is a slot mutation that resets promotion
    // candidacy (§B4.7 MAJOR-2); the selector is a pure function of the
    // cache, so the relation is stable and identical re-arms short-circuit
    // at the `armNativeLink` funnel (B-3d.1 R6).
    const target = self.resolveLoopDoneCont(inner.code.anchor.proto, post_pc, null).arm orelse return;
    self.armLoopDoneLinkTo(inner, guard_idx, post_pc, target);
}

/// The targeted arm worker: `cont` is the canonical selector's choice (or
/// the terminal drain's already-resolved `sel.arm` — one selection per
/// event, D4'). P-G eligibility is re-validated fail-closed — cheap, and it
/// keeps the invariant local rather than trusting the caller.
pub fn armLoopDoneLinkTo(self: *TraceState, inner: *Trace, guard_idx: u32, post_pc: u32, cont: *Trace) void {
    // Continuation eligibility (P-G): a `.link` trace anchored exactly at
    // the guard's post-loop PC in the same proto — the shape `replayLedger`'s
    // `.loop_done_linked` successor validation release-panics on, so anything
    // else must stay unarmed. B-iv.3 (doc 22 §B.5): seeded continuations
    // qualify when stub-enterable — checked AFTER `nativeFor` (the predicate
    // never compiles), mirroring the widened replay assert.
    if (!(cont.code.instrs.len != 0 and cont.code.instrs[cont.code.instrs.len - 1].op == .link)) return;
    if (!(cont.code.anchor.proto == inner.code.anchor.proto and cont.code.anchor.pc == post_pc)) return;
    // `ordinary_entry` is optional — a missing entry (e.g. a test stub or an
    // unsupported compile) leaves the slot unarmed, never `.?`-traps.
    _ = self.nativeFor(cont) orelse return;
    if (!self.stubEnterable(cont, .ordinary, inner.code.anchor.proto)) return;
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
    defer self.syncNativeInvalidation();
    self.registry.native_physical.debug_log = self.config.debug_log;
    self.registry.native_physical.resetLinksTouching(&self.registry.mcode_arena, t);
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
    defer self.syncNativeInvalidation();
    self.registry.native_physical.debug_log = self.config.debug_log;
    self.registry.native_physical.disarmAllLinks(&self.registry.mcode_arena);
}

/// Part S: drop a `.sibling_handoff` link's parent-side latch. EVERY path that
/// removes an armed link must call this, or `hasArmedSiblingHandoff`'s fast reject
/// stops being an exact necessary condition (it would keep saying "maybe" for a
/// parent with no link, costing a registry scan) and the watch could never
/// re-qualify. Cheap enough to call unconditionally on any link kind.
pub const clearSiblingLatch = native_physical.clearSiblingLatch;

/// A-vii-d.1 (review blocker 3): disarm ONE armed link by registry index —
/// reset its parent's physical slot to the shared trampoline exit, count the
/// disarm, and drop the record. Infallible (publish-phase safe). Uses
/// `swapRemove`, so callers iterating the registry must walk BACKWARDS.
pub fn disarmLinkAt(self: *TraceState, idx: usize) void {
    defer self.syncNativeInvalidation();
    self.registry.native_physical.disarmLinkAt(&self.registry.mcode_arena, idx);
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
pub fn disarmStaleRegionBridgeLinks(self: *TraceState, live_armable: []const RegionId) void {
    var i = self.registry.native_physical.armedLinks().len;
    while (i > 0) {
        i -= 1;
        const link = self.registry.native_physical.armedLinks()[i];
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

/// Remove a trace from the cache and free it. Used by widen-eviction to
/// retire a permanently-dead trace so its per-anchor slot frees up for the
/// stabilised wider-lane trace. Cache entries are `*Trace`, so removing one
/// never invalidates pointers to the others — but the caller must NOT be
/// mid-iteration over the cache through this trace (see the dispatch loop,
/// which defers eviction until after its same-anchor walk completes).
pub fn removeTrace(self: *TraceState, t: *Trace) void {
    for (self.registry.cache.items) |c| {
        if (c == t) {
            const anchor = t.code.anchor;
            if (comptime jitdbg.enabled) if (self.config.debug_log) {
                // Same lane summary as the commit probe: correlating WHICH
                // sibling was removed is the point of this line (doc 48
                // alternating-lane churn diagnosis; codex round-2).
                var lanes: [4]i32 = .{ -1, -1, -1, -1 };
                var nl: usize = 0;
                for (t.code.instrs) |ins| {
                    if (ins.op == .guard_lane and nl < lanes.len) {
                        lanes[nl] = ins.aux;
                        nl += 1;
                    }
                }
                self.dbg("trace-retire: t={d} anchor pc={d} proto={s} lanes={any}", .{ t.id, anchor.pc, anchor.proto.name, lanes[0..nl] });
            };
            // B-2a / §B.6: logical relation deletion is immediate at the
            // retirement source; physical link teardown remains P-E's job.
            self.retireProvenanceEdgesTouching(t.id);
            self.registry.native_physical.debug_log = self.config.debug_log;
            _ = self.registry.retire(t);
            self.syncNativeInvalidation();
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
/// Physical epoch safety is owned by `TraceRegistry.clear`: it demotes and
/// disarms before freeing records even when the caller has not pre-disarmed.
// ---- doc 20: copy-on-patch code images + entry-patch registry ----------

/// The code array the dispatch fetch must execute for `proto`: its
/// VM-local patched image when one exists, else canonical. The empty-map
/// early-out makes an unpatched program's cost one counter load per call.
pub inline fn codeFor(self: *const TraceState, proto: *const Proto) []const Instr {
    return self.registry.entry_registry.codeFor(proto);
}

/// Get-or-clone the VM-local image for `proto` (§R1 copy-on-patch). The
/// clone bumps `image_gen` so live frames re-resolve at their next
/// back-edge (§R2-1). Install path only — never called per entry.
pub fn ensureImage(self: *TraceState, proto: *const Proto) ![]Instr {
    return self.registry.entry_registry.ensureImage(proto);
}

/// The image opcode corresponding to a canonical loop-closing instruction.
/// Numeric `for` uses `.jfor_loop`; compiler-emitted `while` and `repeat`
/// close with `.jmp` and `.jmp_if_false` respectively, and generic-for
/// closes with `.tfor_loop` (recordable since doc 30 c4) — all three share
/// `.jloop`, whose arm re-executes the ORIGINAL opcode's semantics from
/// `patch.orig` and enters only on a taken back-edge. Other jump variants
/// are not loop closers emitted by the compiler.
pub fn patchedEntryOp(op: OpCode) ?OpCode {
    return trace_mod.trace_entry_registry.EntryRegistry.patchedEntryOp(op);
}

/// §R3-1 patch-pc resolution, fail closed: the unique supported loop-closing
/// instruction whose taken back-edge targets `anchor_pc` (target = pc + 1 +
/// aux, matching the dispatcher's post-fetch `applyJump`). This covers the
/// actual compiler shapes: numeric `for` (`.for_loop`), `while` (`.jmp`), and
/// `repeat` (`.jmp_if_false`). Zero or multiple matches → null (ambiguity is a
/// property of immutable bytecode; the caller routes `.suppressed_permanent`).
pub fn resolvePatchPc(proto: *const Proto, anchor_pc: u32) ?u32 {
    return trace_mod.trace_entry_registry.EntryRegistry.resolvePatchPc(proto, anchor_pc);
}

/// Why `installEntryPatch` declined — routes the §R4-2 state machine at
/// the drain (`.no_patch_pc` → `.suppressed_permanent`; `.incumbent` →
/// `.suppressed_incumbent` recording the blocking slot; `.capacity` →
/// `.suppressed_capacity`; `.oom` → `.eligible`, transient §R5-2).
pub const InstallResult = trace_mod.trace_entry_registry.InstallResult;

/// Install a `.jfor_loop` / `.jloop` patch binding `t` at its anchor (§R2-6
/// publication order: initialize the slot COMPLETELY, then write the
/// image opcode — that write is the publication). Declines (installing
/// nothing) when the patch pc is unresolvable/ambiguous, the pc already
/// holds a live patch (§R3-1 rule 2 — incumbent wins), the slot index
/// space is exhausted (§R6-2), or allocation fails — a missed
/// optimization, never an error. Production caller: the Phase-1 install
/// pass of `drainEntryPatchWork`, which owns the state routing.
pub fn installEntryPatch(self: *TraceState, t: *Trace) InstallResult {
    const result = self.registry.entry_registry.installEntryPatch(t);
    if (result == .installed) {
        const idx = t.entry_slot.?;
        const p = self.registry.entry_registry.entry_patches.items[idx];
        self.dbg("entry-patch install: pc={d} patch_pc={d} slot={d} trace={d}", .{ t.code.anchor.pc, p.patch_pc, idx, t.id });
    }
    return result;
}

/// Mark a slot for unpatch (§R2-4): clears `live` so no arm dereferences
/// the (possibly dying) trace pointer, defers the restore/tombstone to
/// the safe-point drain. Allocation-free — legal mid-grammar, including
/// from `removeTrace` immediately before `t.destroy` (§R7-2).
pub fn markEntryPatchPending(self: *TraceState, idx: u16) void {
    self.registry.entry_registry.markEntryPatchPending(idx);
}

/// Mark every live slot whose bound trace anchors at `anchor` (doc 20
/// unpatch-trigger table: anchor gated / `wants_side_trace` at a patched
/// anchor). Identity goes through `traceById` — a dropped trace's slot was
/// already marked by the `removeTrace` hook. Linear over the registry,
/// which stays tiny (one live slot per patched loop); allocation-free.
pub fn markEntryPatchesAt(self: *TraceState, anchor: AnchorKey) void {
    if (self.registry.entry_registry.entry_patches.items.len == 0) return;
    for (self.registry.entry_registry.entry_patches.items, 0..) |p, i| {
        if (p.tombstone or p.pending_unpatch) continue;
        const t = self.traceById(p.trace_id) orelse continue;
        if (t.code.anchor.proto == anchor.proto and t.code.anchor.pc == anchor.pc)
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
    if (!self.registry.entry_registry.takeDirty()) return;
    for (self.registry.entry_registry.entry_patches.items, 0..) |p, i| {
        if (p.tombstone or !p.pending_unpatch) continue;
        self.unpatchSlot(@intCast(i));
    }
    // Install pass: pending marks live on traces, found by cache scan
    // (drains are rare — only a dirty turn pays this). Ascending-id
    // selection keeps sibling ties deterministic without allocating.
    while (true) {
        var best: ?*Trace = null;
        for (self.registry.cache.items) |t| {
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
pub fn installPending(self: *TraceState, t: *Trace) void {
    std.debug.assert(t.entry_patch == .pending);
    // Doc 44 P0/D12b: one-shot traces (head + cont) install without a native
    // page — the patched pc is their ONLY entry (there is no back-edge walk
    // to fall back on), so gating installs on `.compiled` would make them
    // unreachable on every tier-1a leg. The loop-patch rationale (a patch
    // merely SHORTCUTS the walk, so only pay for it when native is ready)
    // does not transfer.
    if (t.native != .compiled and trace_mod.anchorKind(t.code.anchor.pc) == .loop) {
        t.entry_patch = .suppressed_permanent;
        return;
    }
    // A `.link`-closed continuation is never trial-entered through the
    // anchor walk (interp.zig's walk skips them); a patched entry must
    // not become the back door. Permanent — the close op never changes.
    if (t.code.instrs.len != 0 and t.code.instrs[t.code.instrs.len - 1].op == .link) {
        t.entry_patch = .suppressed_permanent;
        return;
    }
    if (self.isGated(t.code.anchor)) {
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
    self.registry.entry_registry.unpatchSlot(idx, self.registry.cache.items);
    const p = self.registry.entry_registry.entry_patches.items[idx];
    self.dbg("entry-patch unpatch: patch_pc={d} slot={d} trace={d}", .{ p.patch_pc, idx, p.trace_id });
}

/// Epoch/deinit teardown (§R2-2: the ONLY points images are freed).
/// Restores nothing — the images are dropped whole, and canonical
/// `Proto.code` was never touched.
pub fn dropEntryPatchState(self: *TraceState) void {
    self.registry.entry_registry.dropEntryPatchState();
}

pub fn clearCache(self: *TraceState) void {
    self.clearProvenanceEdges();
    self.registry.native_physical.debug_log = self.config.debug_log;
    self.registry.clear();
    self.syncNativeInvalidation();

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
    self.wants_head_sibling = null;
    self.head_want_src = null;
    self.wants_prime_side = null;
    self.prime_want_src = null;
    self.pending_exit_anchor = null;
    self.pending_replay_anchor = null;
    self.pending_replay_src = null;
    // B1' (task 27): frame-link arm requests are trace-id-keyed; ids are
    // monotonic across epochs (so a stale key can only resolve to null), but
    // a cleared cache must not carry cross-epoch arm policy either way.
    self.pending_ret_cont_arm = null;
    self.pending_call_head_arm = null;

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
    self.region_policy.clearEdges();

    // Physical demotion precedes the policy-owned epoch mutation.
    self.demoteSetsForRegionDefsMutation();
    self.region_policy.clearEpochTopology(self.gpa);
    self.resetRegionProfit();
    self.region_policy.resetDiagnostics();
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
        if (parent.code.anchor.proto == anchor.proto and parent.code.anchor.pc == anchor.pc)
            _ = self.provenance_edges.swapRemove(i);
    }
}

/// Remove all guard-failure entries for `anchor`. Called after a side
/// trace is armed so the counter resets and doesn't re-trigger infinitely.
pub fn clearGuardFailures(self: *TraceState, anchor: AnchorKey) void {
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
            if (nativegen.compileInto(self.gpa, &self.registry.mcode_arena, &t.code, t.id, self.registry.native_seed_ctx, self.exec_heap)) |ct| {
                t.native = .{ .compiled = ct };
                return &t.native.compiled;
            }
            if (comptime jitdbg.enabled) if (self.config.debug_log) {
                diag: {
                    const kinds = self.gpa.alloc(nativegen.Kind, t.code.instrs.len) catch break :diag;
                    defer self.gpa.free(kinds);
                    const slots = self.gpa.alloc(i32, t.code.instrs.len) catch break :diag;
                    defer self.gpa.free(slots);
                    const proved = nativegen.proveKinds(self.gpa, &t.code, kinds, slots);
                    if (proved) {
                        if (nativegen.analyze(self.gpa, &t.code, kinds, slots)) |alloc_value| {
                            var alloc = alloc_value;
                            defer alloc.deinit(self.gpa);
                            self.dbg("native unsupported after analyze: trace={d} anchor={d} spill_count={d}", .{ t.id, t.code.anchor.pc, alloc.spill_count });
                        } else {
                            self.dbg("native unsupported in analyze: trace={d} anchor={d}", .{ t.id, t.code.anchor.pc });
                        }
                    } else {
                        self.dbg("native unsupported in proveKinds: trace={d} anchor={d}", .{ t.id, t.code.anchor.pc });
                        // `dbg_last_idx` is the instruction the failing pass was
                        // examining when it bailed — written per iteration by the
                        // synchronous call above, so it is this trace's offender.
                        const fi = @import("nativegen_prove.zig").dbg_last_idx;
                        if (fi < t.code.instrs.len) {
                            const ins = t.code.instrs[fi];
                            self.dbg("proveKinds fail-at: trace={d} %{d} op={s} aux={d} ty={s}", .{ t.id, fi, @tagName(ins.op), ins.aux, @tagName(ins.ty) });
                        }
                    }
                }
            };
            t.native = .unsupported;
            return null;
        },
    }
}
