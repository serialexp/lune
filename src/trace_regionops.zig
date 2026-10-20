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
const trace_exec = @import("trace_exec.zig");
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
const isOwnLoopTestIndex = trace_mod.isOwnLoopTestIndex;
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
    const key = t.code.anchor;
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
        // Doc 44 D9 (S2): skip the two hash probes when the maps are empty —
        // the steady state of every healthy workload (removing a missing key
        // is a no-op, so this is behavior-identical, just without the wyhash).
        if (self.penalty.count() != 0) _ = self.penalty.remove(key);
        if (self.gate.count() != 0) self.clearDispatchGate(key);
        return;
    }
    // A zero-COMPLETION receipt that ended at the loop's OWN test is a loop
    // that ran to completion committing nothing — evidence of NEITHER
    // productivity NOR thrash. It must not strike (task #62's
    // completions-are-not-thrash, extended to the legacy machine) and must not
    // clear (it did no work to earn one). Without this, the strike/clear pair
    // alternates forever on a healthy anchor (measured on fft_bitreverse's
    // ~50% zero-trip instances). Two policies, kept apart on purpose (doc 58
    // §4.5, B2 review):
    if (exit_instr != std.math.maxInt(u32) and exit_instr < t.code.instrs.len) {
        // (1) A numeric `for`'s FINAL test — unchanged since task #62. Its
        // completion is served by the loop-done machinery (the linked
        // materialization / continuation), so it never strikes. A doc 57
        // mid-trip copy is not a final test and still strikes, as before.
        if (isLoopDoneGuardIndex(t, exit_instr)) return;
        // (2) A `while`/`repeat` loop's own test, unrolled copies included (a
        // copy failing is the same loop ending one trip earlier, resuming at
        // the same post-loop pc). Doc 58 made this an ordinary exit that only
        // doc 56's exit-side route serves, so it is exempt exactly while that
        // route serves or is warming up to serve it. When it cannot — native
        // exit-side off, the exit gave up, or it can never go wanted — the
        // zero-completion entries are the pure enter/exit turnstile the
        // deleted `.low_trip_while` yield gate stood in front of, and they
        // strike like any zero-progress exit.
        if (isMarkerLoopTest(t, exit_instr) and exitSideServes(self, t, exit_instr)) return;
    }
    if (exitSideWaiting(self, t, exit_instr)) return;
    const gop = self.penalty.getOrPut(self.gpa, key) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* +|= 1;
    // Option A: give a real side-exit counter enough deterministic headroom to
    // reach `hotexit`, but retain the finite legacy gate. Without direct
    // native exit-branch stitching, permanently exempting zero-progress guard
    // exits creates an enter/exit runtime turnstile on variable loop shapes.
    const side_headroom = exit_instr != std.math.maxInt(u32) and
        exit_instr < t.code.instrs.len and
        isSideExitGuardOp(t.code.instrs[exit_instr].op) and
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
        if (t.code.unrolled_while) {
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

/// Doc 56 §4.8.3 R4: is a zero-progress receipt at `exit_instr` part of an
/// attachable exit's bounded wait for a native side trace? True while the
/// exit is `.wanted` (at most `tryside` more firings), or `.none` with its
/// hot count still below `hotexit`. Such a receipt must not strike the
/// anchor: gating it would stop the very firings that make the exit hot
/// or record its child. The `hotexit` bound matters (review 3): an exit
/// that can never go wanted (`maxside` reached, or a live ordinary arm,
/// R1) stays `.none` for good and strikes again once it is hot. Applies
/// only with native exit-side on, so the switch-off path is unchanged.
fn exitSideWaiting(self: *const TraceState, t: *const Trace, exit_instr: u32) bool {
    if (!self.exitSideNative()) return false;
    if (exit_instr >= t.exit_side.len or !t.code.exitAttachable(exit_instr)) return false;
    return switch (t.exit_side[exit_instr]) {
        .wanted => true,
        .none => exit_instr < t.exit_counts.len and t.exit_counts[exit_instr] < self.config.hotexit,
        .attached, .gave_up => false,
    };
}

/// Doc 58 §4.5: does exit-side serve attachable exit `exit_instr` — bound to
/// a child, or still on its bounded way there (`exitSideWaiting`)? False with
/// native exit-side off, once the exit gave up, and for an exit that can
/// never go wanted.
fn exitSideServes(self: *const TraceState, t: *const Trace, exit_instr: u32) bool {
    if (exitSideWaiting(self, t, exit_instr)) return true;
    if (!self.exitSideNative() or exit_instr >= t.exit_side.len) return false;
    return t.exit_side[exit_instr] == .attached;
}

/// Doc 58: is `exit_instr` the own test of a `while`/`repeat` loop — a marker
/// loop, whose header has its `loop` marker right above it? (`isOwnLoopTest`
/// answers for `for` loops too; those keep their own policy.)
fn isMarkerLoopTest(t: *const Trace, exit_instr: u32) bool {
    if (!isOwnLoopTestIndex(t, exit_instr)) return false;
    const code = t.code.anchor.proto.code;
    const h = t.code.anchor.pc;
    return h > 0 and h < code.len and code[h - 1].op == .loop;
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
        if (completed > 0) self.noteTraceIters(t.code.anchor, t.code.sourceIters(completed));
        // Iteration totals remain exact. Per-trace TSC attribution cannot be:
        // the promoted set executed as one uninterrupted native span, so
        // there is no per-member timestamp boundary to reconstruct here.
        // Charge the drain-time span once per summarized member as diagnostic
        // attribution only, matching doc 17's explicit redefinition.
        const now = readCycles();
        self.noteTracedCycles(t.code.anchor, cycleDelta(now, self.last_hop_tsc));
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
    applyWindowDecision(self, key, work, self.region_policy.flushWindow(key, work, self.config.min_useful));
}

fn applyWindowDecision(self: *TraceState, key: RegionKey, work: u64, decision: @import("trace_region_policy.zig").RegionPolicy.WindowDecision) void {
    const owner = switch (decision) {
        .none => return,
        .recover => |owner| {
            _ = self.penalty.remove(owner);
            self.clearDispatchGate(owner);
            return;
        },
        .strike => |owner| owner,
    };
    const unfroze = self.demotePromotionsForRegionReason(key, .unfreeze);
    // Instability eviction (doc 47 Increment B follow-up): a strike that
    // destroys a LIVE promotion is the churn event — "we paid to patch, then
    // immediately unpatched". Charged per event on the fallback region's def
    // (never the shared per-anchor penalty map, whose remove-on-recover
    // semantics an oscillating region defeats: scimark-lu recovered often
    // enough that 435k strikes never saturated max_penalty while cycling 175k
    // promote/demote pairs). Clean `.region_close` survivals decrement in
    // `closeRegion`. At the threshold the region is invalidated one-shot.
    if (unfroze > 0) {
        if (self.region_policy.region_defs.getPtr(key.region_id)) |d| {
            if (d.fallback_owner and !d.tombstoned) {
                d.instability +|= 1;
                if (d.instability >= self.config.region_instability_tombstone) {
                    self.dbg("region: instability tombstone rid={d} owner pc={d} work={d}", .{ @intFromEnum(key.region_id), owner.pc, work });
                    _ = self.penalty.remove(owner);
                    self.invalidateRegion(key.region_id);
                    return;
                }
            }
        }
    }
    const gop = self.penalty.getOrPut(self.gpa, owner) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* +|= 1;
    if (gop.value_ptr.* >= self.config.max_penalty) {
        // Doc 47 Increment B: a FALLBACK-elected owner (closed-SCC tier) that
        // strikes out is tombstoned — one-shot `invalidateRegion`, returning
        // that region to its pre-Increment-B unarmable status quo — instead of
        // the primary-tier gate below. The gate branch re-fires on EVERY strike
        // once penalty saturates, and each firing tears down every armed link
        // registry-wide (`disarmAllLinks`); on a phase-variant closed cycle
        // (fft's butterfly: work=1 early stages, work=512 late) that repeated
        // global teardown cost ~2× wall-clock. Re-entry via invalidateRegion →
        // closeRegion → applyWindowDecision is bounded: the def is tombstoned
        // by then, so the lookup below takes the remove-and-return path.
        if (self.region_policy.region_defs.get(key.region_id)) |def| {
            if (def.fallback_owner) {
                self.dbg("region: fallback owner strike-out — tombstone rid={d} owner pc={d} work={d}", .{ @intFromEnum(key.region_id), owner.pc, work });
                _ = self.penalty.remove(owner);
                if (!def.tombstoned) self.invalidateRegion(key.region_id);
                return;
            }
        }
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
    // Doc 63 §5.9.2: unreachable while suspended. A callback's frames lie
    // deeper than every open accumulator's root and carry fresh `call_seq`s,
    // so neither the observer nor an activation drop can pick one; every
    // other caller starts from a trace run, a commit or the ledger.
    std.debug.assert(!self.suspended());
    const close = self.region_policy.beginClose(key, self.config.min_useful) orelse return;
    self.dbg("region: close rid={d} activation={d} work={d}", .{ @intFromEnum(key.region_id), key.activation, close.work });
    applyWindowDecision(self, key, close.work, close.window);
    const survived = self.demotePromotionsForRegion(key);
    // Instability recovery: a promotion that lived until the activation's own
    // lifecycle close (rather than being struck down by `.unfreeze`) is
    // positive evidence — decrement, never full-reset, so sustained churn
    // still saturates through occasional clean closes. This is scimark-sparse's
    // healthy signature: 150k region-close demotions, ~2800 transitions per
    // burst, 1 strike per run.
    if (survived > 0) {
        if (self.region_policy.region_defs.getPtr(key.region_id)) |d| {
            if (d.fallback_owner) d.instability -|= 1;
        }
    }
    self.resetPromotionCandidate();
    self.region_policy.finishClose(self.gpa, key);
}

pub fn demotePromotionsForRegion(self: *TraceState, key: RegionKey) usize {
    return self.demotePromotionsForRegionReason(key, .region_close);
}

/// Backwards over `promoted_sets` because `demoteSetReason` swapRemoves at
/// depth 0 (mid-walk it queues instead) — forward iteration would skip entries.
/// Returns the number of sets demoted (or queued mid-walk — they WILL demote).
///
/// Parked proofs (codex C′): ONLY the clean `.region_close` demotion of a
/// fallback-owned, live-armable region parks the set's edges for reuse by the
/// region's next activation. Every other reason (`.unfreeze`, growth, slot,
/// trace, teardown) is negative evidence and parks nothing. The copy is taken
/// BEFORE `demoteSetReason` so a mid-walk queued demotion still parks the
/// exact set that was live.
pub fn demotePromotionsForRegionReason(self: *TraceState, key: RegionKey, reason: DemotionReason) usize {
    var demoted: usize = 0;
    var i = self.registry.native_physical.promotedSets().len;
    while (i > 0) {
        i -= 1;
        const set = self.registry.native_physical.promotedSets()[i];
        if (std.meta.eql(set.region_key, key)) {
            if (reason == .region_close) {
                if (self.region_policy.region_defs.get(key.region_id)) |d| {
                    if (d.fallback_owner and d.armable and !d.tombstoned and !d.dormant)
                        self.registry.native_physical.parkPromotionProof(key.region_id, set.edges);
                }
            }
            self.demoteSetReason(i, reason);
            demoted += 1;
        }
    }
    return demoted;
}

/// B-3a hook at every native-call origin. B-3b performs the conservative global
/// activation sweep here, demoting every live promotion whose RegionKey differs
/// from the current active key before any patched code can run.
pub inline fn prepareNativeEntry(self: *TraceState) void {
    // This is on every native entry; preserve the empty-registry common case
    // as one length branch before resolving activation state. Doc 52 P1:
    // resident sets are exempt from the sweep (they are activation-blind by
    // construction), so with only resident sets live there is nothing to
    // sweep and activation resolution is skipped entirely — the count cache
    // keeps this the same one-branch fast path.
    if (self.registry.native_physical.activation_set_count == 0) return;
    const active = if (self.region_policy.regionContext()) |ctx| self.activeRegionFor(ctx.call_seq) else null;
    var i = self.registry.native_physical.promotedSets().len;
    while (i > 0) {
        i -= 1;
        const set = &self.registry.native_physical.promotedSets()[i];
        if (set.isResident()) continue;
        if (active == null or !std.meta.eql(set.region_key, active.?))
            self.demoteSetReason(i, .activation);
    }
}

/// One authoritative staging image for every native-call origin. The barren
/// bound is absolute: `cur_zero_run` begins at the active activation's current
/// streak and native compares it directly with `max_barren_run`.
pub inline fn silentStaging(self: *TraceState) nativegen.SilentStaging {
    // Nothing is promoted ⇒ no patch targets a silent epilogue ⇒ no native code
    // can read any of these fields. Resolving the activation here would put an
    // `activeRegionFor` walk + a `region_profit` hashmap lookup on EVERY native
    // call, which measured +10% on pi_leibniz (a workload that promotes nothing
    // at all: 0 bursts, 0 promotions) — the same per-call-cost failure mode as
    // the A-vii-e.1 observer scan. Stage zeros behind one predictable branch;
    // the real staging cost is paid only while patched code exists, where it is
    // amortized across thousands of silent transitions.
    if (self.registry.native_physical.promotedSets().len == 0) return .{};
    // Doc 52 P1: with no activation-scoped set live there is no activation
    // barren streak to stage — return the zero-run image WITHOUT the
    // `activeRegionFor` walk + `region_profit` probe (the +10%-on-pi_leibniz
    // per-call-cost failure mode above). Resident edges never modify the run
    // (barren-exempt at the epilogue), so the staged image is inert for them;
    // the budgets must still be staged — the epilogue tail compares are
    // unconditional for every promoted edge.
    var zero_run: u64 = 0;
    if (self.registry.native_physical.activation_set_count != 0) {
        if (self.region_policy.regionContext()) |ctx| {
            if (self.activeRegionFor(ctx.call_seq)) |key| {
                if (self.region_policy.region_profit.get(key)) |accum| zero_run = accum.barren_run;
            }
        }
    }
    return .{
        .silent_budget = self.config.silent_budget,
        .barren_budget = self.config.max_barren_run,
        .cur_zero_run = zero_run,
    };
}

pub fn freeObserverFast(self: *TraceState) void {
    self.region_policy.freeObserverFast(self.gpa);
}
pub fn refreshObserverFast(self: *TraceState) void {
    self.region_policy.refreshObserverFast(self.gpa);
}
pub fn activeRegionFor(self: *const TraceState, activation: u64) ?RegionKey {
    return self.region_policy.activeRegionFor(activation);
}

pub fn openRegion(self: *TraceState, id: RegionId, ctx: RegionContext) ?RegionKey {
    // Doc 63 §5.9.2: regions open only from trace receipts, and no trace
    // runs while suspended.
    std.debug.assert(!self.suspended());
    while (self.region_policy.openCollision(id, ctx)) |old| self.closeRegion(old);
    return self.region_policy.openRegion(self.gpa, id, ctx);
}

pub fn invalidateRegion(self: *TraceState, id: RegionId) void {
    // Doc 63 §5.9.2: every caller is a trace run, an arm, a commit or a
    // window strike, none of which happen while suspended.
    std.debug.assert(!self.suspended());
    self.resetPromotionCandidate();
    if (self.region_policy.invalidateRegion(id)) self.demoteSetsForRegionDefsMutation();
    while (self.region_policy.nextInvalidated(id)) |key| self.closeRegion(key);
    self.disarmAllLinks();
    // Doc 47 Increment B follow-up: the tombstone alone leaves the region's
    // stale entries in the source/dest receipt maps, so `receiptsInert()`
    // stays false and every receipt program-wide keeps paying the region
    // pipeline for a region that can never pay off again. Request a maps
    // rebuild at the next post-walk drain tail (deferred — this can run
    // mid-replay, where a wholesale map swap is not safe).
    self.pending_region_rebuild = true;
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
    for (self.region_policy.dest_entry_regions.get(trace_id) orelse &.{}) |candidate| {
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
    var it = self.registry.tracesAt(bridge.successor);
    while (it.next()) |t| {
        // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
        // selection. Suppression deadlocks: a skipped trace can never be
        // entered, so the counter can never reset. The refusal is already
        // free (no anchor penalty), so the cost of a futile prologue
        // attempt is one native call + ledger row per dispatch — bounded
        // by the caller's own iteration count, not by the counter.
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
    const def = self.region_policy.region_defs.getPtr(id) orelse return .invalidated;
    if (!def.armable) return .invalidated;
    const edge = self.region_policy.edge_cache.get(.{
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
        if (!parent.code.bridgeEmitsSlot(exit_instr, slot) and
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
    if (child.code.inputs.len != 0 and
        self.stubEnterability(child, .ordinary, child.code.anchor.proto) != .ok)
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
    const def = self.region_policy.region_defs.get(id) orelse return;
    if (!def.armable or def.classifier.kind != .cross_trace_cycle) {
        self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (armable={} kind={s})", .{ failed.id, exit_instr, @intFromEnum(id), def.armable, @tagName(def.classifier.kind) });
        return;
    }
    // Profitability: the ACTIVE accumulator for the current activation must
    // belong to this region and have committed a full min_useful window.
    const ctx = self.region_policy.regionContext() orelse {
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
    const accum = self.region_policy.region_profit.get(active) orelse return;
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
            failed.bridge_decline_gen = self.region_policy.region_defs_gen;
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
    if (self.stubEnterability(child, .ordinary, child.code.anchor.proto) != .ok) {
        failed.bridge_decline_exit = exit_instr;
        failed.bridge_decline_gen = self.region_policy.region_defs_gen;
        failed.bridge_decline_seq = ctx.call_seq;
        self.dbg("bridge-arm: decline t={d} ei={d} rid={d} (child id={d} page not enterable — memoized for this activation)", .{ failed.id, exit_instr, @intFromEnum(id), child.id });
        return;
    }
    const armed = @import("trace_link.zig").arm(self, .{
        .parent = failed,
        .slot_index = exit_instr,
        .child = child,
        .kind = .region_bridge,
        .region = .{ .id = id, .generation = self.region_policy.region_defs_gen },
    }) catch false;
    if (armed) self.native_region_bridge_arms +|= 1;
}

/// A-vii-d.1: the shared receipt-sited arm entry. Every place a native
/// composite-candidate deopt is OBSERVED with `safe_to_arm` in hand funnels
/// through here — the dispatcher-entered `driveChain` head, the chain-run
/// exits, and the post-replay pending drain. Cheap and fail-closed: every
/// gate declines silently.
pub fn maybeArmCompositeExit(self: *TraceState, t: *Trace, exit_instr: u32, safe_to_arm: bool) void {
    if (!safe_to_arm) return;
    if (exit_instr == std.math.maxInt(u32) or exit_instr >= t.code.instrs.len) return;
    if (!t.code.isBridgeCandidate(exit_instr)) return;
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
    for (self.registry.native_physical.armedLinks()) |l| {
        if (l.parent == t and l.slot_index == exit_instr and l.kind == .region_bridge and
            l.armed_gen == self.region_policy.region_defs_gen) return;
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
    if (t.bridge_decline_exit == exit_instr and t.bridge_decline_gen == self.region_policy.region_defs_gen) {
        if (self.region_policy.regionContext()) |rctx| {
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
pub inline fn drainPendingBridgeArm(self: *TraceState, safe_to_arm: bool) void {
    // Task #28: the gate is inline (a single null check at every ledger-driver
    // safe point); the consumer stays out of line so a cost-model change can
    // never drag the arm pipeline into the hot dispatcher path.
    if (self.pending_bridge_arm == null) return;
    drainPendingBridgeArmSlow(self, safe_to_arm);
}

noinline fn drainPendingBridgeArmSlow(self: *TraceState, safe_to_arm: bool) void {
    const key = self.pending_bridge_arm orelse return;
    self.pending_bridge_arm = null;
    const t = self.traceById(key.trace_id) orelse return;
    self.maybeArmCompositeExit(t, key.exit_instr, safe_to_arm);
}

/// B-2b: republish disposable physical sibling arms from persistent hotexit
/// provenance. Called only at dispatcher/runtime safe points. Observation
/// windows retain the logical edges and retry when arming becomes safe again.
pub inline fn drainProvenanceArms(self: *TraceState, safe_to_arm: bool) void {
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
    // Task #28: the gate above is FORCED inline (at ~3M dispatcher safe
    // points per binary-trees run, even an out-of-line call to an
    // immediately-returning gate cost ~46M cycles once code growth pushed
    // this function out of LLVM's inline budget); the scan below is FORCED
    // out of line so the same cost model can never inline the cold
    // edge-walk machinery back into the dispatcher hot path.
    drainProvenanceArmsScan(self);
}

noinline fn drainProvenanceArmsScan(self: *TraceState) void {
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
        // Doc 45 / task #28: a precise endpoint is PERMANENT for the edge —
        // `deopt_mode` is immutable on a committed trace and `armNativeLink`
        // categorically refuses links into or out of precise traces, so the
        // publish below could never succeed. Charging that to the transient
        // `deferred` flag (a precise parent is native-declined, so it trips
        // the "parent not compiled" arm forever) would re-scan the full edge
        // list at every dispatcher safe point — the same failure family as
        // the peeled exclusion below. Delete the edge. BEFORE the
        // `parent.native` inspection, and with no compile-on-demand: precise
        // traces are excluded from the chain selectors and burst grammar, so
        // nothing needs the child page this edge would have compiled.
        if (parent.code.deopt_mode == .precise or child.code.deopt_mode == .precise) {
            self.dbg("provenance-drain: t={d} ei={d} decline: precise endpoint (edge deleted)", .{ edge.parent_id, edge.exit_instr });
            _ = self.provenance_edges.swapRemove(i);
            continue;
        }
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
        if (edge.exit_instr >= parent.code.instrs.len or edge.exit_instr >= compiled.slots.len) {
            self.dbg("provenance-drain: t={d} ei={d} decline: slot bounds (slots={d})", .{ edge.parent_id, edge.exit_instr, compiled.slots.len });
            continue;
        }
        if (!exitIsPreEffect(parent, edge.exit_instr)) {
            self.dbg("provenance-drain: t={d} ei={d} decline: not pre-effect", .{ edge.parent_id, edge.exit_instr });
            continue;
        }
        if (parent.code.anchor.proto != child.code.anchor.proto or parent.code.anchor.pc != child.code.anchor.pc) continue;
        // B-iv.3 (doc 22 §B.5): seeded children are drainable — the arm
        // funnel's validator (`armNativeLink`) gates enterability via
        // `stubEnterable`, so no separate input filter here.
        if (parent.code.isBridgeCandidate(edge.exit_instr)) {
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
        if (parent.code.peeled or child.code.peeled) {
            self.dbg("provenance-drain: t={d} ei={d} decline: peeled fusion exclusion (edge deleted)", .{ edge.parent_id, edge.exit_instr });
            _ = self.provenance_edges.swapRemove(i);
            continue;
        }
        var already_armed = false;
        for (self.registry.native_physical.armedLinks()) |link| {
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
        switch (self.stubEnterability(child, .ordinary, child.code.anchor.proto)) {
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
    entries: []const trace_exec.LedgerEntry,
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
    if (self.registry.native_physical.armedLinks().len == 0) return 0;
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
    entries: []const trace_exec.LedgerEntry,
    initial_cum: usize,
    edge: ProvenanceEdge,
) ?ProvenanceAction {
    if (entries.len < 2) return null;
    var saw_strike = false;
    var suffix_max: usize = entries[entries.len - 1].cum;
    var suffix_commits: bool = entries[entries.len - 1].kind.commitsGuestWork();
    var k: usize = entries.len - 1;
    while (k > 0) {
        k -= 1;
        // Invariant: `suffix_max` is the maximum cum over `entries[k+1..]`,
        // and `suffix_commits` is whether any row in `entries[k+1..]` is a
        // committing kind — progress `cum` cannot see (a one-trip loop's
        // `loop_done_linked`, a continuation's `link_terminal`).
        row: {
            const e = entries[k];
            if (e.id != edge.parent_id or e.exit != edge.exit_instr or
                e.kind != .deopt or e.reason != .normal or e.outcome != .normal or
                entries[k + 1].id != edge.child_id)
                break :row;
            const prior_cum: usize = if (k == 0) initial_cum else entries[k - 1].cum;
            const local = e.cum - prior_cum;
            if (local != 0 or suffix_max > e.cum or suffix_commits) return .reset;
            var j = k + 2;
            while (j < entries.len) : (j += 1) {
                if (entries[j].id == edge.parent_id and entries[j].cum == e.cum) {
                    saw_strike = true;
                    break;
                }
            }
        }
        suffix_max = @max(suffix_max, entries[k].cum);
        suffix_commits = suffix_commits or entries[k].kind.commitsGuestWork();
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
                self.dbg("provenance-retire: t={d} ei={d} -> t={d} strikes={d}", .{
                    edge.parent_id, edge.exit_instr, edge.child_id, edge.strikes,
                });
                var link_idx = self.registry.native_physical.armedLinks().len;
                while (link_idx > 0) {
                    link_idx -= 1;
                    const link = self.registry.native_physical.armedLinks()[link_idx];
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
    entries: []const trace_exec.LedgerEntry,
    initial_cum: usize,
) void {
    if (entries.len == 0) return;
    // Every suffix row is later than every silent-prefix firing. Reporting's
    // per-edge scan therefore treats any suffix progress as productive service
    // for every prefix sibling observation still under consideration.
    // Progress is `cum` OR a committing row (doc 55 §1).
    const suffix_commits = for (entries) |e| {
        if (e.kind.commitsGuestWork()) break true;
    } else false;
    if (entries[entries.len - 1].cum > initial_cum or suffix_commits) {
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
    defer self.syncNativeInvalidation();
    self.registry.native_physical.debug_log = self.config.debug_log;
    if (self.registry.native_physical.drainBarrier(&self.registry.mcode_arena)) {
        self.pending_bridge_arm = null;
        self.dbg("disarm-reason: pending walk-deferred gate strike", .{});
    }
}

pub fn chooseSource(self: *TraceState, candidates: []const RegionId, ctx: RegionContext) ?RegionKey {
    var cursor: @import("trace_region_policy.zig").RegionPolicy.SelectionCursor = .{};
    while (true) switch (self.region_policy.chooseSource(self.gpa, candidates, ctx, &cursor)) {
        .done => |key| return key,
        .close => |key| self.closeRegion(key),
        .invalidate => |id| self.invalidateRegion(id),
    };
}

pub fn applyDestination(self: *TraceState, selected: ?RegionKey, dest: RegionDestination, ctx: RegionContext) void {
    const candidates: []const RegionId = switch (dest) {
        // Doc 55 §2: arrival, not the member proof — a landing in a sibling
        // linked to a member keeps the activation open.
        .known_trace => |id| self.region_policy.arrival_entry_regions.get(id) orelse &.{},
        else => &.{},
    };
    var source = selected;
    var cursor: @import("trace_region_policy.zig").RegionPolicy.SelectionCursor = .{};
    while (true) switch (self.region_policy.applyDestination(self.gpa, &source, candidates, dest == .deferred, ctx, &cursor)) {
        .done => |maybe_key| {
            // Payoff-receipt eviction (doc 47 Increment B follow-up): charge
            // a receipt that OPENED a destination region here (a kept source
            // was already charged at the `decision.effective` site in
            // `accountRegionProfit` — don't double-charge it).
            if (maybe_key) |key| {
                if (selected == null or !std.meta.eql(selected.?, key))
                    chargePayoffReceipt(self, key.region_id);
            }
            return;
        },
        .close => |key| self.closeRegion(key),
        .invalidate => |id| self.invalidateRegion(id),
    };
}

/// Drain the deferred maps rebuild requested by `invalidateRegion`. Runs at
/// the dispatcher drain tail — the same post-replay-walk safe point as
/// dormant admission — never mid-walk.
pub fn drainPendingRegionRebuild(self: *TraceState) void {
    if (!self.pending_region_rebuild) return;
    self.pending_region_rebuild = false;
    self.rebuildRegions();
}

/// Deterministic pick of the open activation with the smallest region id —
/// the region charged for a receipt the pipeline processed without resolving
/// any effective activation (the open activation that keeps `receiptsInert()`
/// false may belong to an OUTER frame's call_seq, invisible to this receipt's
/// context, yet its existence is exactly why the receipt paid the walk).
pub fn minOpenRegion(self: *TraceState) ?RegionId {
    var best: ?RegionId = null;
    var it = self.region_policy.region_profit.keyIterator();
    while (it.next()) |key| {
        if (best == null or @intFromEnum(key.region_id) < @intFromEnum(best.?))
            best = key.region_id;
    }
    return best;
}

/// Charge one receipt of region-accounting tax against a fallback region's
/// deterministic net-work ledger, and invalidate the region once its
/// cumulative debit passes the minimum sample without the credit side
/// (suppressed silent transitions, rolled up in `driveSilentBurst`) repaying
/// it at `region_profit_weight`. Promotions never reset the ledger —
/// "promotion occurred" is not "promotion repaid the cost". After eviction
/// the maps rebuild without the region and `receiptsInert()` short-circuits
/// the whole receipt path again.
pub fn chargePayoffReceipt(self: *TraceState, rid: RegionId) void {
    const d = self.region_policy.region_defs.getPtr(rid) orelse return;
    if (!d.fallback_owner or d.dormant or d.tombstoned) return;
    d.receipts_debit +|= 1;
    if (d.receipts_debit % 4096 == 0)
        self.dbg("region: net ledger rid={d} debit={d} credit={d}", .{ @intFromEnum(rid), d.receipts_debit, d.transitions_credit });
    if (d.receipts_debit < self.config.region_payoff_receipts) return;
    if (d.transitions_credit *| self.config.region_profit_weight >= d.receipts_debit) return;
    self.dbg("region: net-loss tombstone rid={d} debit={d} credit={d}", .{ @intFromEnum(rid), d.receipts_debit, d.transitions_credit });
    self.invalidateRegion(rid);
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
    const ctx = self.region_policy.regionContext() orelse return false;
    if (self.region_policy.receiptsInert()) return false;
    const candidates = self.classifyExit(exit_key);
    const selected = self.chooseSource(candidates, ctx);
    var member: ?RegionKey = null;
    if (selected == null and candidates.len == 0) {
        if (self.activeRegionFor(ctx.call_seq)) |active| {
            if (self.regionMemberTraceAnchor(active.region_id, exit_key.trace_id)) member = active;
        }
    }
    const decision = self.region_policy.accountRegionProfit(.{
        .selected = selected,
        .unclassified_member = member,
        .work = work,
    });
    if (decision.effective) |effective| {
        if (self.region_policy.region_profit.getPtr(effective)) |accum| {
            if (decision.credit) self.creditRegionWork(effective, accum, work);
            if (decision.barren) self.noteBarrenConsumed(effective, accum);
        }
        // Payoff-receipt eviction: the receipt paid the region pipeline for
        // this activation (classify + choose + credit) — charge it, whether
        // or not the destination side is deferred.
        chargePayoffReceipt(self, effective.region_id);
    } else {
        // The receipt resolved to NOTHING, yet it still paid the pipeline
        // (classifyExit + the activeRegionFor walks) purely because some
        // region holds an open activation — possibly in an outer frame,
        // under a call_seq this receipt's context can't see (scimark-lu:
        // every inner-loop receipt program-wide paid ~15% wall this way for
        // a region that promoted once per run). Charge that region: if it
        // never pays off, eviction ends the tax for the whole program.
        if (minOpenRegion(self)) |rid| chargePayoffReceipt(self, rid);
    }
    self.applyDestination(decision.effective, dest, ctx);
    return decision.consumed;
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
    @import("trace_region_policy.zig").RegionPolicy.beginCredit(accum, work);
    while (self.region_policy.nextCreditWindow(key, accum, self.config.min_useful, self.config.freeze_windows, self.penalty.count() == 0 and self.gate.count() == 0)) |decision| {
        applyWindowDecision(self, key, self.config.min_useful, decision.window);
        if (decision.clear_members) self.clearMemberAnchorState(key.region_id);
        // Invalidation backstop: `applyWindowDecision` above may have
        // tombstoned the region (instability / strike-out), which ran
        // `closeRegion` and removed this activation's accum — `accum` must
        // not be dereferenced again, so stop the loop.
        if (self.region_policy.region_defs.get(key.region_id)) |d| {
            if (d.tombstoned) return;
        }
    }
}

/// True when any promoted set currently belongs to `rid` (list is tiny: one
/// live set per region at most, and usually zero or one total).
pub fn regionHasLivePromotion(self: *TraceState, rid: RegionId) bool {
    for (self.registry.native_physical.promotedSets()) |set| {
        if (set.region_key.region_id == rid) return true;
    }
    return false;
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
    applyWindowDecision(self, key, 1, self.region_policy.barrenReceipt(key, accum, self.config.max_barren_run, self.config.min_useful));
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
            if (self.regionMemberPoint(rid, e.key_ptr.proto.id, e.key_ptr.pc)) {
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
    return self.regionMemberPoint(rid, t.code.anchor.proto.id, t.code.anchor.pc);
}

/// Memoized `regionMemberPoint(rid, t.code.anchor)` for the frozen fast path
/// (task #70): the answer is cached on the TRACE (`region_memo_*`), keyed by
/// `(region_defs_gen, rid)`, so the per-row cost in a frozen steady state is
/// two integer compares instead of a footprint scan. Every `region_defs`
/// mutation bumps the generation, so a stale answer can never be returned.
pub inline fn traceRegionMemberMemo(self: *const TraceState, t: *Trace, rid: RegionId) bool {
    if (t.region_memo_gen == self.region_policy.region_defs_gen and
        t.region_memo_rid == @intFromEnum(rid))
        return t.region_memo_member;
    const member = self.regionMemberPoint(rid, t.code.anchor.proto.id, t.code.anchor.pc);
    t.region_memo_gen = self.region_policy.region_defs_gen;
    t.region_memo_rid = @intFromEnum(rid);
    t.region_memo_member = member;
    return member;
}

/// Point-in-footprint test against a region's `member_points`, fail-closed
/// (freed or tombstoned defs own nothing).
// pub for trace_link.zig (file-split pass)
pub fn regionMemberPoint(self: *const TraceState, rid: RegionId, proto_id: u32, pc: u32) bool {
    return self.region_policy.regionMemberPoint(rid, .{ .proto_id = proto_id, .source_pc = pc });
}

pub const MemberAccum = @import("trace_region_policy.zig").MemberAccum;

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
    return self.region_policy.qualifiedActiveMember(.{ .proto_id = proto.id, .source_pc = pc });
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
    self.region_policy.refreshActCache(call_seq);
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
    return self.region_policy.observeFast(.{ .proto_id = proto_id, .source_pc = pc }, .{ .depth = depth, .call_seq = call_seq });
}

/// Set the current physical activation and close accumulators whose recorded
/// membership no longer contains this tier-0 departure point. No allocation;
/// the common empty-map path is one count test.
pub fn observeRegionProgramPoint(self: *TraceState, proto_id: u32, pc: u32, depth: u32, call_seq: u64) void {
    while (self.region_policy.nextDeparture(.{ .proto_id = proto_id, .source_pc = pc }, .{ .depth = depth, .call_seq = call_seq })) |key| self.closeRegion(key);
}

pub fn dropRegionActivation(self: *TraceState, call_seq: u64) void {
    // Empty fast path first: this runs on EVERY tier-0 function return
    // (`opRet`), and with no live profit windows the only possible side
    // effect is invalidating a matching region context — one compare. Without
    // the early-out every return paid `nextActivation`'s call chain and
    // `activeRegionFor`'s key-iterator walk (~19 instructions per return,
    // measured in the embedding-boundary callgrind profile; the map is empty
    // whenever no region accumulation is in flight, i.e. almost always).
    const pol = &self.region_policy;
    if (pol.region_profit.count() == 0) {
        if (pol.region_context_valid and pol.region_context.call_seq == call_seq)
            pol.region_context_valid = false;
        return;
    }
    while (self.region_policy.nextActivation(call_seq)) |key| self.closeRegion(key);
}

pub fn resetRegionProfit(self: *TraceState) void {
    self.resetPromotionCandidate();
    self.region_policy.resetProfit(self.gpa);
}

pub inline fn regionProfitCount(self: *const TraceState) usize {
    return self.region_policy.region_profit.count();
}

pub inline fn setRegionContext(self: *TraceState, depth: u32, call_seq: u64) void {
    self.region_policy.setContext(depth, call_seq);
}

/// Per-segment SELECTION accounting. As of A-vii-c (doc 17 §A8-iii, A-vii.1)
/// this half keeps ONLY the coverage/cycle receipts and the per-trace
/// `hit_count` increment — it no longer reads or writes `penalty`/`gate`.
/// The profitability decision moved to the region window flush
/// (`flushRegionWindow`), keyed by the region OWNER anchor. The same executed
/// transition stream therefore still produces the same `hit_count` ordering
/// inputs; only the separate gate consumes normalized region windows.
pub inline fn accountTraceRun(self: *TraceState, t: *Trace, completed: usize) void {
    const key = t.code.anchor;
    // JIT coverage (gated): this is the single per-trace-commit hook — every
    // trace run (tier-1a/1b, direct dispatch or a `driveChain` hop) reaches here
    // exactly once with its OWN committed count AND its own anchor. Summing
    // `completed` is the "ran as a trace, not tier-0" iteration total; charging
    // the cycle span since the last hop boundary attributes this hop's *time* to
    // *its own anchor* — so a chain hop into an inner trace bills the inner anchor,
    // never the outer entry anchor. Both are disjoint from the interpreted
    // back-edge accounting in the dispatcher (Rule #3: self-consistent).
    if (self.config.coverage) {
        if (completed > 0) self.noteTraceIters(key, t.code.sourceIters(completed));
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
            self.registry.entry_registry.markInstallPending(t);
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
    var it = self.registry.tracesAt(anchor);
    while (it.next()) |t| {
        if (t.native == .compiled) return;
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
    self.rebuildEdgeCacheFallible() catch self.region_policy.clearEdges();
}

const topology = @import("trace_region_topology.zig");

/// Cold structural-change adapter: native facts are resolved outside the builder.
/// Slot-emission facts are NOT materialized here — the builder queries
/// `TraceCode.bridgeEmitsSlot` lazily, only for edges inside candidate cycles
/// (eager traces×exits×slots×IR materialization was a measured 3× rebuild-cost
/// regression on grid_matmul; see TODO doc-41 follow-up 1).
fn topologyView(self: *TraceState, scratch: std.mem.Allocator) !topology.View {
    const records = try scratch.alloc(topology.TraceRecord, self.registry.cache.items.len);
    for (self.registry.cache.items, records) |t, *record| {
        const exits = try scratch.alloc(topology.ExitFact, t.code.exit_prov.len);
        for (t.code.exit_prov, exits) |e, *fact| {
            fact.* = .{ .index = e.index };
            if (self.resolveSuccessorAnchor(t, e)) |succ|
                fact.successor = .{ .proto_id = succ.proto_id, .pc = succ.pc };
        }
        record.* = .{
            .id = t.id,
            .code = &t.code,
            .inner_root = self.hasInnerRootAt(t.code.anchor.proto, t.code.anchor.pc),
            .exits = exits,
        };
    }
    // Doc 55 §2: same-anchor provenance links, for the arrival_entry sibling-group
    // closure. Unresolvable or cross-anchor edges are skipped (fail toward the
    // realizer-only membership that preceded this).
    var links: std.ArrayListUnmanaged(topology.SiblingLink) = .empty;
    for (self.provenance_edges.items) |edge| {
        const p = self.traceById(edge.parent_id) orelse continue;
        const c = self.traceById(edge.child_id) orelse continue;
        if (p.code.anchor.proto.id != c.code.anchor.proto.id or p.code.anchor.pc != c.code.anchor.pc) continue;
        try links.append(scratch, .{ .parent_id = edge.parent_id, .child_id = edge.child_id });
    }
    return topology.View.init(scratch, records, links.items);
}

pub fn rebuildEdgeCacheFallible(self: *TraceState) !void {
    errdefer self.region_policy.clearEdges();
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const view = try topologyView(self, arena.allocator());
    const edges = try topology.buildEdges(self.gpa, view);
    self.region_policy.publishEdges(self.gpa, edges);
}

// pub for trace_link.zig (file-split pass)
pub fn clearPhysicalRegionIndices(self: *TraceState) void {
    self.region_policy.clearPhysicalIndices(self.gpa);
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
    // Any full rebuild satisfies the deferred-rebuild request — consume the
    // flag so a normal (commit/removal-driven) rebuild isn't followed by a
    // redundant deferred one.
    self.pending_region_rebuild = false;
    self.region_rebuilds +|= 1;
    self.rebuildRegionsFallible() catch |err| {
        self.dbg("region: rebuild failed ({s})", .{@errorName(err)});
        self.clearPhysicalRegionIndices();
        // A-vii-d.1 (review blocker 3): the physical indices failed closed
        // to empty, so no region is live-armable — every armed bridge
        // link's provenance is now unvalidatable. Disarm them all.
        self.disarmStaleRegionBridgeLinks(&.{});
    };
}

pub fn rebuildRegionsFallible(self: *TraceState) !void {
    errdefer {
        self.clearPhysicalRegionIndices();
        self.disarmStaleRegionBridgeLinks(&.{});
    }
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const view = try topologyView(self, arena.allocator());
    var staged = topology.build(self.gpa, view, self.region_policy.previousTopology(), &self.region_policy.edge_cache) catch |err| {
        if (err == error.IncompleteRegionGraph) {
            self.dbg("region: rebuild skipped (incomplete graph)", .{});
            self.clearPhysicalRegionIndices();
            self.disarmStaleRegionBridgeLinks(&.{});
            return;
        }
        return err;
    };
    defer staged.deinit(self.gpa);
    try self.region_policy.reserveTopology(self.gpa, &staged);
    // Demotion sees OLD definitions; everything after reservation is infallible.
    self.demoteSetsForRegionDefsMutation();
    for (staged.staged_defs.items) |s| self.dbg("region: mint id={d} kind={s} members={d} armable={}", .{
        @intFromEnum(s.id), @tagName(s.def.classifier.kind), s.def.classifier.member_count, s.def.armable,
    });
    for (staged.staged_tombstones.items) |id|
        self.dbg("region: tombstone id={d} at physical rebuild", .{@intFromEnum(id)});
    self.region_policy.publishTopology(self.gpa, &staged);
    self.disarmStaleRegionBridgeLinks(staged.live_armable_ids.items);
    self.closeNonArmableAccumulators();
}

/// Close every live accumulator whose region def is missing, tombstoned, or
/// non-armable after a physical rebuild (see call site above). Victim-scan
/// restart per removal — `closeRegion` mutates the map.
pub fn closeNonArmableAccumulators(self: *TraceState) void {
    while (true) {
        var victim: ?RegionKey = null;
        var it = self.region_policy.region_profit.keyIterator();
        while (it.next()) |k| {
            const live = if (self.region_policy.region_defs.get(k.region_id)) |d| d.armable else false;
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
    return self.region_policy.source_exit_regions.get(key) orelse &.{};
}
