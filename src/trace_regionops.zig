//! Region-ops: the region data-model machinery over `TraceState` — window
//! flush + per-trace profitability accounting, region open/close/invalidate,
//! region-bridge validation and arming drains, provenance verdict capture and
//! application, region profit accounting, the observer fast-path cache, and
//! the wholesale `edge_cache`/region rebuilds — carved out of `trace.zig`
//! (file-split pass).
//!
//! Every function here is a `TraceState` method body moved verbatim: free
//! functions taking `self: *TraceState`, re-exported inside `TraceState` as
//! forwarding decls (`pub const openRegion = trace_regionops.openRegion;`)
//! so every `self.openRegion(...)` spelling keeps working. Pure code
//! motion — behaviour identical by construction. The region *data model*
//! (RegionDef, RegionKey, ...) stays in the leaf `trace_region.zig`; this
//! file is the *operations* over it.

const std = @import("std");
const trace_mod = @import("trace.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const io = @import("io.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const function = @import("function.zig");
const Value = value.Value;
const Proto = bytecode.Proto;

const TraceState = trace_mod.TraceState;
const Trace = trace_mod.Trace;
const AnchorKey = trace_mod.AnchorKey;
const ExitKey = trace_mod.ExitKey;
const ProgramPoint = trace_mod.ProgramPoint;
const StructuralEdgeId = trace_mod.StructuralEdgeId;
const RegionId = trace_mod.RegionId;
const RegionKey = trace_mod.RegionKey;
const RegionDef = trace_mod.RegionDef;
const RegionBridgeDef = trace_mod.RegionBridgeDef;
const RegionContext = trace_mod.RegionContext;
const RegionDestination = trace_mod.RegionDestination;
const RegionAccum = trace_mod.RegionAccum;
const ChargeKind = trace_mod.ChargeKind;
const IrOp = trace_mod.IrOp;
const IrInstr = trace_mod.IrInstr;
const Ref = trace_mod.Ref;
const guardExitPc = trace_mod.guardExitPc;
const guardSourcePc = trace_mod.guardSourcePc;
const isSideExitGuardOp = trace_mod.isSideExitGuardOp;
const ProvenanceEdge = trace_mod.ProvenanceEdge;
const ProvenanceAction = trace_mod.ProvenanceAction;
const ProvenanceVerdict = trace_mod.ProvenanceVerdict;
const ExitProvenance = trace_mod.ExitProvenance;
const GateReason = trace_mod.GateReason;
const freeRegionBridges = trace_mod.freeRegionBridges;
const isAnyLoopDoneGuardIndex = trace_mod.isAnyLoopDoneGuardIndex;
const isLoopDoneGuardIndex = trace_mod.isLoopDoneGuardIndex;
const readCycles = trace_mod.readCycles;
const cycleDelta = trace_mod.cycleDelta;
const cloneRegionBridges = trace_mod.cloneRegionBridges;
const RegionSetBuilder = trace_mod.RegionSetBuilder;
const programPointLess = trace_mod.programPointLess;
const programPointsEqual = trace_mod.programPointsEqual;
const PROVENANCE_VERDICT_CAP = trace_mod.TraceState.PROVENANCE_VERDICT_CAP;
const PromotedEdge = trace_mod.PromotedEdge;
const ObserverSpan = trace_mod.ObserverSpan;
const RegionClassifier = trace_mod.RegionClassifier;
const freeRegionSetMap = trace_mod.freeRegionSetMap;
const appendUniqueSlot = trace_mod.appendUniqueSlot;
const DemotionReason = trace_mod.TraceState.DemotionReason;
const forLoopEndFor = trace_mod.TraceState.forLoopEndFor;
// pub'd in trace.zig for trace_link.zig (file-split pass):
const bumpGen = TraceState.bumpGen;
const exitIsPreEffect = TraceState.exitIsPreEffect;

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
pub inline fn accountLegacyThrash(self: *TraceState, t: *Trace, completed: usize, exit_instr: u32, charge_kind: ChargeKind) void {
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
pub inline fn accountLedgerRow(self: *TraceState, t: *Trace, completed: usize, exit_instr: u32, region_consumed: bool, charge_kind: ChargeKind) void {
    self.accountTraceRun(t, completed);
    if (!region_consumed) {
        self.accountLegacyThrash(t, completed, exit_instr, charge_kind);
    } else {
        accountCandidateCharge(t, charge_kind);
    }
}

pub inline fn accountCandidateCharge(t: *Trace, charge_kind: ChargeKind) void {
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
pub fn accountLedgerRowsBulk(
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

pub fn sameAnchor(a: AnchorKey, b: AnchorKey) bool {
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

pub fn demotePromotionsForRegion(self: *TraceState, key: RegionKey) void {
    self.demotePromotionsForRegionReason(key, .region_close);
}

/// Backwards over `promoted_sets` because `demoteSetReason` swapRemoves at
/// depth 0 (mid-walk it queues instead) — forward iteration would skip entries.
pub fn demotePromotionsForRegionReason(self: *TraceState, key: RegionKey, reason: DemotionReason) void {
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

pub fn freeObserverFast(self: *TraceState) void {
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
pub fn refreshObserverFast(self: *TraceState) void {
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

// pub for trace_link.zig (file-split pass)
pub fn activeRegionFor(self: *const TraceState, activation: u64) ?RegionKey {
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

pub const RegionBridgeDecision = struct {
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

pub fn traceInRegion(self: *const TraceState, trace_id: u32, id: RegionId) bool {
    for (self.dest_entry_regions.get(trace_id) orelse &.{}) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

/// Arm-only child lookup for an already-discovered bridge edge. Selection is
/// identical to `findTrace`: highest hit_count, stable first-on-tie, with the
/// additional physical-membership proof that excludes same-anchor siblings.
pub fn resolveRegionBridgeChild(
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

pub fn slotInSortedSet(slots: []const u16, wanted: u16) bool {
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
pub fn tryArmRegionBridge(self: *TraceState, failed: *Trace, exit_instr: u32) void {
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
pub fn maybeArmCompositeExit(self: *TraceState, t: *Trace, exit_instr: u32, safe_to_arm: bool) void {
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

pub fn chooseSource(self: *TraceState, candidates: []const RegionId, ctx: RegionContext) ?RegionKey {
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

pub fn applyDestination(self: *TraceState, selected: ?RegionKey, dest: RegionDestination, ctx: RegionContext) void {
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
pub inline fn creditRegionWork(self: *TraceState, key: RegionKey, accum: *RegionAccum, work: usize) void {
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
pub fn noteBarrenConsumed(self: *TraceState, key: RegionKey, accum: *RegionAccum) void {
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
pub fn clearMemberAnchorState(self: *TraceState, rid: RegionId) void {
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
pub fn regionMemberTraceAnchor(self: *const TraceState, rid: RegionId, trace_id: u32) bool {
    const t = self.traceById(trace_id) orelse return false;
    return self.regionMemberPoint(rid, t.anchor.proto.id, t.anchor.pc);
}

/// Memoized `regionMemberPoint(rid, t.anchor)` for the frozen fast path
/// (task #70): the answer is cached on the TRACE (`region_memo_*`), keyed by
/// `(region_defs_gen, rid)`, so the per-row cost in a frozen steady state is
/// two integer compares instead of a footprint scan. Every `region_defs`
/// mutation bumps the generation, so a stale answer can never be returned.
pub inline fn traceRegionMemberMemo(self: *const TraceState, t: *Trace, rid: RegionId) bool {
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
// pub for trace_link.zig (file-split pass)
pub fn regionMemberPoint(self: *const TraceState, rid: RegionId, proto_id: u32, pc: u32) bool {
    const def = self.region_defs.get(rid) orelse return false;
    if (!def.armable) return false;
    for (def.member_points) |p| {
        if (p.proto_id == proto_id and p.source_pc == pc) return true;
    }
    return false;
}

pub const MemberAccum = struct { key: RegionKey, accum: *RegionAccum };

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
pub fn qualifiedActiveMember(self: *TraceState, proto: *const Proto, pc: u32) ?MemberAccum {
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
pub fn refreshActCache(self: *TraceState, call_seq: u64) void {
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

pub fn rebuildEdgeCacheFallible(self: *TraceState) !void {
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

// pub for trace_link.zig (file-split pass)
pub fn clearPhysicalRegionIndices(self: *TraceState) void {
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

pub fn rebuildRegionsFallible(self: *TraceState) !void {
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
pub fn closeNonArmableAccumulators(self: *TraceState) void {
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
