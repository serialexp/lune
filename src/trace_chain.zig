//! Chain dispatch: the tier-up execution drivers over `TraceState` — stub
//! enterability, `driveChain` (side-exit chain walking), silent bursts,
//! ledger replay (`replayLedger*`), linked bursts (`runLinkedBurst` /
//! `driveBurstCore`), the dispatcher-ledger drivers, and native-call
//! provenance capture — carved out of `trace.zig` (file-split pass).
//!
//! Every function here is a `TraceState` method body moved verbatim: free
//! functions taking `self: *TraceState`, re-exported inside `TraceState` as
//! forwarding decls (`pub const driveChain = trace_chain.driveChain;`) so
//! every `self.driveChain(...)` spelling keeps working. Pure code motion —
//! behaviour identical by construction.

const std = @import("std");
const trace_mod = @import("trace.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const io = @import("io.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const trace_exec = @import("trace_exec.zig");
const jitdbg = @import("jitdbg.zig");
const function = @import("function.zig");
const Value = value.Value;
const Proto = bytecode.Proto;

const TraceState = trace_mod.TraceState;
const Trace = trace_mod.Trace;
const AnchorKey = trace_mod.AnchorKey;
const ExitKey = trace_mod.ExitKey;
const StructuralEdgeId = trace_mod.StructuralEdgeId;
const RegionId = trace_mod.RegionId;
const RegionKey = trace_mod.RegionKey;
const RegionAccum = trace_mod.RegionAccum;
const ChargeKind = trace_mod.ChargeKind;
const IrOp = trace_mod.IrOp;
const IrInstr = trace_mod.IrInstr;
const Ref = trace_mod.Ref;
const guardExitPc = trace_mod.guardExitPc;
const guardSourcePc = trace_mod.guardSourcePc;
const isSideExitGuardOp = trace_mod.isSideExitGuardOp;
const isLoopDoneGuardIndex = trace_mod.isLoopDoneGuardIndex;
const isWhileLoopDoneGuardIndex = trace_mod.isWhileLoopDoneGuardIndex;
const isAnyLoopDoneGuardIndex = trace_mod.isAnyLoopDoneGuardIndex;
const whileLoopDonePostPc = trace_mod.whileLoopDonePostPc;
const whileDoneCoherentAtZero = trace_mod.whileDoneCoherentAtZero;
const accountCandidateCharge = TraceState.accountCandidateCharge;
const readCycles = trace_mod.readCycles;
const cycleDelta = trace_mod.cycleDelta;
const PromotedEdge = trace_mod.PromotedEdge;
const PromotedSet = trace_mod.PromotedSet;
const NativeLink = trace_mod.NativeLink;
const ProvenanceVerdict = trace_mod.ProvenanceVerdict;
const ProvenanceAction = trace_mod.ProvenanceAction;
const ExitProvenance = trace_mod.ExitProvenance;
const NativeSeedCtx = trace_mod.NativeSeedCtx;
const ChainResult = trace_mod.ChainResult;
const ChainTier = trace_mod.ChainTier;
const ArmKind = trace_mod.ArmKind;
const ExitMaterialization = trace_mod.ExitMaterialization;
const RegionDestination = trace_mod.RegionDestination;
// pub'd in trace.zig for trace_link.zig (file-split pass):
const isInnerLoopRoot = TraceState.isInnerLoopRoot;
const PROVENANCE_VERDICT_CAP = trace_mod.TraceState.PROVENANCE_VERDICT_CAP;

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
pub fn seedForTier1a(self: *TraceState, t: *const Trace, proto: *const Proto) bool {
    if (t.code.inputs.len == 0) return true;
    const ctx = self.registry.native_seed_ctx orelse return false;
    const f = ctx.seed_tier1a_fn orelse return false;
    std.debug.assert(ctx.proto == @as(*const anyopaque, @ptrCast(proto)));
    const rc = f(ctx, &t.code);
    self.dbg("chain-seed: trace={d} inputs={d} rc={d}", .{ t.id, t.code.inputs.len, rc });
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
// pub for trace_regionops.zig (file-split pass)
pub fn liveEpisodeProto(self: *const TraceState) ?*const anyopaque {
    const ctx = self.registry.native_seed_ctx orelse return null;
    const rctx = self.region_policy.region_context orelse return null;
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
    if (t.code.anchor.proto != proto) return .no_compilation;
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
/// (`resume_pc == null` ⇒ resume at `failed.code.anchor.pc`), or null if nothing
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
    result: trace_exec.ExecResult,
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
        .ordinary_header => failed.code.anchor.pc,
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
            const wp = guardExitPc(failed.code.instrs[exit_instr]) orelse return null;
            if (wp == 0 or wp == failed.code.anchor.pc) return null;
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
        if (!safe_to_arm and sct.code.alloc_bound > 0) continue;
        // Doc 26 D1 tripwire, chain half: see `enterSelectedTrace`.
        if (sct.code.requires_unicode_pin) std.debug.assert(unicode_pinned);
        const is_link = sct.code.instrs.len != 0 and sct.code.instrs[sct.code.instrs.len - 1].op == .link;
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
        if (sct.code.inputs.len != 0 and tier != .native_only) {
            if (!self.seedForTier1a(sct, proto)) continue;
        }

        // Once a productive loop-done exit has committed, the ordinary loop-
        // header deopt path is no longer valid: tier-0 must resume at the PC
        // matching the now-committed state (the post-inner continuation PC,
        // advancing to the inner-root PC after a `.link` snapshot flush). For
        // native the commit already happened (`runLinkedLoopDone`); for tier-1a
        // loop-done we flush the failed trace's final iteration from scratch now.
        var flushed_resume_pc: ?u32 = null;
        var sresult: trace_exec.ExecResult = undefined;
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
            const sbuf = self.valuesPush(sct.code.instrs.len) catch continue;
            if (loop_done_values) |vals| {
                if (!irinterp.flushNumericForLoopDone(&failed.code, regs, vals, exit_instr)) return null;
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
            sresult = irinterp.executeCtx(.{ .heap = self.exec_heap }, &sct.code, regs, sbuf);
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
            sresult.final_trace_id != trace_exec.NO_TRACE_ID and
            sresult.final_trace_id != sct.id;
        if (is_link and (sresult.exit_instr == sct.code.instrs.len - 1 or sresult_fused)) {
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
            //    where `sct` is a same-anchor ramp (walk_pc == failed.code.anchor.pc) -- never
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

pub fn driveSeedSilentResult(
    self: *TraceState,
    seed: *Trace,
    result: trace_exec.ExecResult,
    proto: *const Proto,
    regs: RegWindow,
    safe_to_arm: bool,
    materialization: ExitMaterialization,
) ?ChainResult {
    var linked_completed: usize = 0;
    const seed_inner_pc: u32 = if (seed.code.instrs.len != 0 and seed.code.instrs[seed.code.instrs.len - 1].op == .link)
        @intCast(seed.code.instrs[seed.code.instrs.len - 1].aux)
    else
        seed.code.anchor.pc;
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
pub const LedgerReplay = union(enum) {
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
pub const ReplayOrigin = enum { continuation_call, inner_call, dispatcher_root };

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
pub const BurstCursor = struct {
    current_link: *Trace,
    linked_completed: usize,
    resume_pc: u32,
    hops: usize,
    start_at_continuation: bool = false,
};

pub const FrozenFast = struct { key: RegionKey, accum: *RegionAccum };

pub const OrdinaryGuardEntry = struct { parent: *Trace, source_local: usize };

pub const EntryMaterialization = union(enum) {
    ordinary,
    via_bridge,
    via_handoff,
    /// Suppressed M1 source guard. The successor ramp's terminal contract
    /// resumes at this predecessor's coherent anchor, not at the ramp.
    via_ordinary_guard: OrdinaryGuardEntry,
};

pub const ReplayCursor = struct {
    cont: *Trace,
    link_pc: u32,
    prev_cum: usize,
    next_entry: EntryMaterialization,
    frozen_fast: ?FrozenFast,
    /// false only for a silent-prefix suffix entry, where row 0's owner is the
    /// promoted set's off-cycle successor, not the burst's seed owner.
    check_seed: bool = true,
};

pub const SuffixInit = struct {
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
pub fn applyEdgeCursorTransition(
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

pub const SilentCellOwner = struct { set: *PromotedSet, phase: usize };

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
pub fn silentCellOwner(self: *TraceState, cell_addr: u64) ?SilentCellOwner {
    if (cell_addr == 0) return null;
    var found: ?SilentCellOwner = null;
    for (self.registry.native_physical.promoted_sets.items) |*set| {
        for (set.metadata, 0..) |*metadata, phase| {
            if (@intFromPtr(metadata) != cell_addr) continue;
            if (found != null)
                @panic("driveSilentBurst: silent metadata cell is ambiguous");
            found = .{ .set = set, .phase = phase };
        }
    }
    return found;
}

pub const SilentSiblingEvidence = struct {
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
    suffix_rows: []const trace_exec.LedgerEntry,
) SilentSiblingEvidence {
    if (cell.last_ordinal == 0)
        @panic("driveSilentBurst: fired edge has no firing ordinal");
    var returned = false;
    for (self.registry.native_physical.promoted_sets.items) |*c| {
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
    result: trace_exec.ExecResult,
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
    const seam_t0: u64 = if (self.config.coverage and self.registry.native_physical.replay_walk_depth == 0)
        readCycles()
    else
        0;
    self.registry.native_physical.replay_walk_depth += 1;
    defer {
        self.registry.native_physical.replay_walk_depth -= 1;
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
    for (self.registry.native_physical.promoted_sets.items) |*c| {
        if (c.edges.len == 0 or c.edges.len != c.summary.len or
            c.edges.len != c.metadata.len)
            @panic("driveSilentBurst: promoted set storage is inconsistent");
    }
    if (result.ledger_len > trace_exec.LEDGER_CAP)
        @panic("driveSilentBurst: suffix ledger exceeds cap");
    const last_edge_local = last_set.summary[last_phase].last_local;
    if (last_edge_local > std.math.maxInt(usize))
        @panic("driveSilentBurst: last edge local exceeds usize");
    self.silent_provenance_len = 0;

    // The ordinal space is call-global and monotonic across every live cycle, so
    // "did anything make progress at or after this firing" stays one comparison.
    var last_productive_ordinal: u64 = 0;
    var total_firings: u64 = 0;
    for (self.registry.native_physical.promoted_sets.items) |*c| {
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
    const active = if (self.region_policy.region_context) |ctx| self.activeRegionFor(ctx.call_seq) else null;
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
    for (self.registry.native_physical.promoted_sets.items) |*c| {
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
        const c_accum = self.region_policy.region_profit.getPtr(c.region_key) orelse
            @panic("driveSilentBurst: promoted set accumulator is missing");
        if (!c_accum.frozen)
            @panic("driveSilentBurst: promoted set accumulator is not frozen");
        if (region_work > std.math.maxInt(usize))
            @panic("driveSilentBurst: region summary exceeds usize");
        if (region_work != 0) self.creditRegionWork(c.region_key, c_accum, @intCast(region_work));
    }
    // Every fired edge proved `region_key == active`, so they all share one
    // accumulator; the entry set always fired, so its lookup names it.
    const accum = self.region_policy.region_profit.getPtr(entry_set.region_key) orelse
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
    for (self.registry.native_physical.promoted_sets.items) |*c|
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
    result: trace_exec.ExecResult,
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
    result: trace_exec.ExecResult,
    out: []ProvenanceVerdict,
) usize {
    if (result.silent_active == 0) return 0;
    if (result.ledger_len > trace_exec.LEDGER_CAP)
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
    result: trace_exec.ExecResult,
    entries: []const trace_exec.LedgerEntry,
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
    entries: []const trace_exec.LedgerEntry,
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
    if (self.region_policy.region_context) |rctx| {
        if (self.activeRegionFor(rctx.call_seq)) |akey| {
            if (self.region_policy.region_profit.getPtr(akey)) |accum| {
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
    entries: []const trace_exec.LedgerEntry,
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
    if (self.region_policy.region_context) |rctx| {
        if (self.activeRegionFor(rctx.call_seq)) |akey| {
            if (self.region_policy.region_profit.getPtr(akey)) |accum| {
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

pub fn replayLedgerFrom(
    self: *TraceState,
    entries: []const trace_exec.LedgerEntry,
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
    if (entries.len == 0 or entries.len > trace_exec.LEDGER_CAP)
        @panic("replayLedger: ledger length outside [1, LEDGER_CAP]");
    // A-vii-d.1: never inherit a bridge-arm request from a previous ledger.
    self.pending_bridge_arm = null;
    // Seam timing (diagnostic, `--jit-stats` only): bracket the OUTERMOST walk
    // so `cycles_seam` splits the traced bucket into native-vs-steering. A
    // `seam_t0` of 0 doubles as the "not bracketed" sentinel (coverage off,
    // nested walk, or no TSC on this target — all cases where we skip).
    const seam_t0: u64 = if (self.config.coverage and self.registry.native_physical.replay_walk_depth == 0)
        readCycles()
    else
        0;
    // A-vii-d.1: defer any `disarmAllLinks` for the duration of the walk
    // (see `replay_walk_depth`); the driver applies it right after.
    self.registry.native_physical.replay_walk_depth += 1;
    defer {
        self.registry.native_physical.replay_walk_depth -= 1;
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
        if (e.outcome == .yielded and !(is_last and entries.len == trace_exec.LEDGER_CAP))
            @panic("replayLedger: forced-yield entry is not the last of a full ledger");
        const row_local = e.cum - cursor.prev_cum;

        // Static owner shape: a continuation ends in `.link`, an inner root in
        // `.loop`. Used per-kind to reject a kind on the wrong owner shape.
        const ends_link = owner.code.instrs.len != 0 and
            owner.code.instrs[owner.code.instrs.len - 1].op == .link;
        const ends_loop = owner.code.instrs.len != 0 and
            owner.code.instrs[owner.code.instrs.len - 1].op == .loop;

        // A-iv consumes the same per-transition ledger the steering machine
        // validates below. Work and structural transition are orthogonal:
        // loop-done is one outer traversal, deopt carries its segment-local
        // committed work, and link/prologue receipts carry none. A concrete
        // fused successor is known only when the next ledger row exists.
        const region_key: ?ExitKey = if (e.kind != .prologue_fail and e.exit < owner.code.instrs.len)
            .{ .trace_id = owner.id, .exit_instr = e.exit }
        else
            null;
        // Part S: is THIS row a fused sibling handoff? Resolved here, before the
        // region receipt, because the handoff changes that receipt's destination
        // (below) — and because the `.deopt` arm must agree with it exactly.
        // Armed-edge provenance only, never position or opcode.
        const sibling_succ: ?*Trace = if (!is_last and e.kind == .deopt and
            e.reason == .normal and e.outcome == .normal and e.exit < owner.code.instrs.len)
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
                    resume_pc.* = m1.parent.code.anchor.pc;
                    return .{ .return_result = .{
                        .completed = linked_completed.*,
                        .resume_pc = m1.parent.code.anchor.pc,
                    } };
                }
            },
            .prologue_fail => {
                if (!(is_last and ends_link and e.reason == .prologue_fail and
                    e.exit == std.math.maxInt(u32) and e.outcome == .normal and row_local == 0))
                    @panic("replayLedger: silent M1 ramp prologue-fail violates terminal contract");
                self.onSideExit(owner, 0, .entry_refusal);
                resume_pc.* = m1.parent.code.anchor.pc;
                return .{ .return_result = .{
                    .completed = linked_completed.*,
                    .resume_pc = m1.parent.code.anchor.pc,
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
                resume_pc.* = m1.parent.code.anchor.pc;
                return .{ .return_result = .{
                    .completed = linked_completed.*,
                    .resume_pc = m1.parent.code.anchor.pc,
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
                // (`penalty.get(cont.code.anchor) == null` after a bridge row) and the
                // bridged-successor test pins the `.loop`-ending successor shape.
                self.accountTraceRun(owner, @max(local, 1));
                accountCandidateCharge(owner, .entered);
                self.native_region_bridge_fused +|= 1;
                applyEdgeCursorTransition(cursor, .region_bridge, owner, succ, edge.succ_anchor_pc, local, resume_pc);
            },
            .link_terminal => {
                // A continuation reached its single-contract `.link` terminal.
                if (!(e.reason == .normal and ends_link and e.exit == owner.code.instrs.len - 1))
                    @panic("replayLedger: link_terminal entry is not owner's .link");
                if (ordinary_guard_entry != null) {
                    if (row_local != 0)
                        @panic("replayLedger: M1 ramp link committed iterations");
                    self.prime_side_chain_follows +|= 1;
                }
                // One `native_link_exits` bump per `.link` marker — this replaces
                // BOTH the old per-fused-span bump and the standalone-`.link` bump.
                self.native_link_exits +|= 1;
                const owner_inner_pc: u32 = @intCast(owner.code.instrs[owner.code.instrs.len - 1].aux);
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
                if (succ.code.inputs.len != 0 and !self.stubEnterable(succ, .linked, proto))
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
                // otherwise resume at `I.code.anchor.pc`, wrong; `post_pc` == the following
                // continuation's anchor in every modeled shape).
                const post_pc = guardExitPc(owner.code.instrs[e.exit]) orelse
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
                        for (self.registry.cache.items) |t| {
                            if (t.code.anchor.proto != proto or t.code.anchor.pc != post_pc) continue;
                            const tail_link = t.code.instrs.len != 0 and t.code.instrs[t.code.instrs.len - 1].op == .link;
                            self.dbg("  candidate id={d}: inputs={d} tail_link={} native={s}", .{
                                t.id, t.code.inputs.len, tail_link, @tagName(t.native),
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
                if (!(succ.code.instrs.len != 0 and
                    succ.code.instrs[succ.code.instrs.len - 1].op == .link and
                    succ.code.anchor.proto == proto and succ.code.anchor.pc == post_pc))
                    @panic("replayLedger: fused successor is not the expected continuation");
                // B-iv.3 (doc 22 §B.5): seeded continuations are newly admitted
                // (the `inputs.len == 0` shape clause is gone), but only under
                // the rule — the loop-done arm dispatched into this
                // continuation's `ordinary_entry`, so a seeded page must be
                // stub-enterable right now (it just self-seeded this frame).
                // Zero-input continuations keep the pre-B-iv shape-only
                // contract (widened with the rule, never narrowed).
                if (succ.code.inputs.len != 0 and !self.stubEnterable(succ, .ordinary, proto))
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
                        applyEdgeCursorTransition(cursor, .sibling_handoff, owner, sibling_succ.?, owner.code.anchor.pc, local, resume_pc);
                        continue;
                    }
                    if (e.outcome != .normal)
                        @panic("replayLedger: fused M1 .deopt is a forced yield");
                    if (e.exit >= owner.code.instrs.len)
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
                    std.debug.assert(self.countTracesAt(owner.code.anchor) >= 2);
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
                    // `onSideExit(ramp, 0); resume owner.code.anchor.pc`. (`succ.cum ==
                    // owner.cum`, so `succ`'s own `local` is 0 regardless.) Resume at
                    // `owner`'s OWN anchor — the source trace's coherent header — NOT
                    // `seed_owner`'s: for the flat 2-entry M1 they coincide (owner is
                    // the seed), but a future nested `[…, I.deopt(armed), R.deopt]`
                    // would resume at `I.code.anchor.pc`, not the outer seed. `succ` (`R`)
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
                            .resume_pc = owner.code.anchor.pc,
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
                    // `onSideExit(ramp, 0)` + resume at `walk_pc == owner.code.anchor.pc`
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
                        if (!(succ.code.instrs.len != 0 and succ.code.instrs[succ.code.instrs.len - 1].op == .link))
                            @panic("replayLedger: fused M1 sub-case (c) ramp does not end in .link");
                        self.onSideExit(succ, 0, .entry_refusal);
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = owner.code.anchor.pc,
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
                        if (!(succ.code.instrs.len != 0 and succ.code.instrs[succ.code.instrs.len - 1].op == .link))
                            @panic("replayLedger: fused M1 sub-case (d) ramp does not end in .link");
                        return .{ .return_result = .{
                            .completed = linked_completed.*,
                            .resume_pc = owner.code.anchor.pc,
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
                if (e.exit >= owner.code.instrs.len)
                    @panic("replayLedger: .deopt exit index out of range");
                const exit_op = owner.code.instrs[e.exit].op;
                if (exit_op == .link or exit_op == .loop)
                    @panic("replayLedger: .deopt exit names a terminator, not a guard");
                // A-vii-d.1: a terminal composite-candidate deopt is the fused-span
                // observation of the edge-4 exit. Record the at-most-one pending
                // arm request; the ledger DRIVER drains it after this replay
                // returns (never mid-walk — review blocker 5).
                if (e.outcome == .normal and owner.code.isBridgeCandidate(e.exit))
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
                    if (resume_pc.* != owner.code.anchor.pc)
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
                    if (resume_pc.* != owner.code.anchor.pc)
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
                    if (resume_pc.* != owner.code.anchor.pc)
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
                    if (resume_pc.* != owner.code.anchor.pc and cursor.link_pc == owner.code.anchor.pc)
                        @panic("replayLedger: continuation seed-decline resume mismatches the decliner's anchor");
                    return .{ .return_result = .{
                        .completed = linked_completed.*,
                        .resume_pc = owner.code.anchor.pc,
                    } };
                }
                if (!ends_loop)
                    @panic("replayLedger: seed-decline owner is neither continuation nor inner root");
                // Linked inner decline: resume at the decliner's own anchor.
                // For the linked C⇄I grammar the most-recent `.link` names
                // exactly that PC — release-assert the two agree so any
                // future grammar drift fails loudly instead of misresuming.
                if (cursor.link_pc != owner.code.anchor.pc)
                    @panic("replayLedger: linked inner seed-decline link_pc mismatches the decliner's anchor");
                return .{ .return_result = .{
                    .completed = linked_completed.*,
                    .resume_pc = owner.code.anchor.pc,
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
    sresult: trace_exec.ExecResult,
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
        .resume_pc = @intCast(sct.code.instrs[sct.code.instrs.len - 1].aux),
        .hops = 0,
    };
    // 2.3b-1: a *fused* continuation run (armed `.link` slot jumped straight into
    // inner) hands the inner loop-done/mid result forward so the core consumes it
    // WITHOUT re-running inner. Only ever non-null on the native path.
    const fused_inner: ?trace_exec.ExecResult = if (sresult_fused) sresult else null;
    return self.driveBurstCore(sct, cursor, fused_inner, snt_in, tier, proto, regs, safe_to_arm);
}

/// The shared continuation⇄inner-root ping-pong core. Runs from an already-built
/// `cursor` — fresh zero-progress from `runLinkedBurst`, or an already-accounted
/// cursor the dispatcher hands over after a `replayLedger` M1 drain (2.3c-2d
/// D2b-ii). `seed` is the burst's origin trace, used only by the zero-progress
/// tail's `onSideExit(seed, 0)`. This function owns NO one-time entry counters —
/// its caller charges those before handing over the cursor.
pub fn driveBurstCore(
    self: *TraceState,
    seed: *Trace,
    cursor: BurstCursor,
    fused_inner_in: ?trace_exec.ExecResult,
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
    var fused_inner: ?trace_exec.ExecResult = fused_inner_in;
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
        const link_term = current_link.code.instrs[current_link.code.instrs.len - 1];
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
            if (inner.code.inputs.len != 0 and tier != .native_only) {
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

            var iresult: trace_exec.ExecResult = undefined;
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
                ibuf = self.valuesPush(inner.code.instrs.len) catch break;
                iresult = irinterp.executeCtx(.{ .heap = self.exec_heap }, &inner.code, regs, ibuf);
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

            const inner_guard = inner.code.instrs[iresult.exit_instr];
            const inner_exit_pc = guardExitPc(inner_guard) orelse break;
            // The inner root reached its numeric loop-done ⟺ its exit PC
            // follows a `for_loop` (mode-invariant static bytecode; the same
            // discriminator `isSourceBranchGuardExit` uses inverted). This
            // must NOT be `inner_exit_pc == current_link.code.anchor.pc`: that
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
                if (!irinterp.flushNumericForLoopDone(&inner.code, regs, ibuf, iresult.exit_instr)) break;
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
            if (current_link.code.anchor.pc != post_pc) {
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
            resume_pc = current_link.code.anchor.pc;

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
            const arm_term = current_link.code.instrs[current_link.code.instrs.len - 1];
            if (tier == .native_only and safe_to_arm and
                self.stubEnterable(inner, .linked, proto) and
                arm_term.op == .link and @as(u32, @intCast(arm_term.aux)) == inner_pc)
            {
                const slot: u32 = @intCast(current_link.code.instrs.len - 1);
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
            if (current_link.code.inputs.len != 0 and !self.seedForTier1a(current_link, proto))
                return .{ .completed = linked_completed, .resume_pc = resume_pc };
            const cbuf = self.valuesPush(current_link.code.instrs.len) catch break;
            const cresult = irinterp.executeCtx(.{ .heap = self.exec_heap }, &current_link.code, regs, cbuf);
            if (cresult.exit_instr == current_link.code.instrs.len - 1) {
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
                if (cresult.exit_instr < current_link.code.instrs.len)
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
pub fn noteDispatcherLedgerTerminal(
    self: *TraceState,
    entries: []const trace_exec.LedgerEntry,
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
    if (term.exit < owner.code.instrs.len and !isLoopDoneGuardIndex(owner, term.exit))
        self.noteTakenExit(owner, term.exit, term_local, proto);
}

pub fn driveDispatcherLedger(
    self: *TraceState,
    seed: *Trace,
    entries: []const trace_exec.LedgerEntry,
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
    var resume_pc: u32 = seed.code.anchor.pc;
    var hops: usize = 0;
    // The seed is a directly-dispatched trace (never a `.link`), so it has no
    // inner-root PC of its own; `inner_pc` only seeds `replayLedger`'s `link_pc`
    // fallback for an inner mid-loop-deopt before any `.link` marker — which the
    // modeled M1 grammar never reaches (its first `.link` sets the real cursor).
    // Pass the seed anchor as an inert placeholder.
    const inner_pc: u32 = seed.code.anchor.pc;
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

pub fn finishDispatcherDirective(
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
    result: trace_exec.ExecResult,
    proto: *const Proto,
    regs: RegWindow,
    safe_to_arm: bool,
) ?ChainResult {
    var linked_completed: usize = 0;
    var resume_pc: u32 = seed.code.anchor.pc;
    var hops: usize = 0;
    const max_hops: usize = 8;
    if (result.silent_active != 0 and result.ledger_len != 0) {
        if (result.ledger_len > trace_exec.LEDGER_CAP)
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
    entries: []const trace_exec.LedgerEntry,
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
            if (!(seed.code.instrs.len != 0 and seed.code.instrs[seed.code.instrs.len - 1].op == .link))
                @panic("driveSeedLedger: seed does not end in .link");
            if (e0.exit != seed.code.instrs.len - 1)
                @panic("driveSeedLedger: first entry is not the seed's .link terminal");
        },
        .region_bridge => {
            if (entries.len < 2)
                @panic("driveSeedLedger: bridge-headed ledger has no successor row");
            if (!seed.code.isBridgeCandidate(e0.exit))
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
    const seed_inner_pc: u32 = if (seed.code.instrs.len != 0 and seed.code.instrs[seed.code.instrs.len - 1].op == .link)
        @intCast(seed.code.instrs[seed.code.instrs.len - 1].aux)
    else
        seed.code.anchor.pc;
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
