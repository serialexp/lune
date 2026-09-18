//! Physical native deployment owner. No coordinator or region-policy authority.
//! Arena is borrowed per transaction; records and published metadata stay stable.
const std = @import("std");
const nativegen = @import("nativegen.zig");
const Trace = @import("trace_record.zig").TraceRecord;
const ExitKey = @import("trace_types.zig").ExitKey;
const StructuralEdgeId = @import("trace_types.zig").StructuralEdgeId;
const RegionId = @import("trace_region.zig").RegionId;
const RegionKey = @import("trace_region.zig").RegionKey;
pub const PROMOTED_SET_CAP: usize = 16;
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
    /// Return-page dynamic resume-PC slot (four per compiled page).
    ret_cont,
    /// Continuation-page self-call slot into the proto head page.
    call_head,
};
pub const NativeLink = struct {
    parent: *Trace,
    /// Logical key: IR exit for ordinary links; resume PC for `.ret_cont`;
    /// terminal IR index for `.call_head`.
    slot_index: u32,
    /// Actual cell in `CompiledTrace.slots`, kept separate from the logical key.
    physical_slot: u32 = std.math.maxInt(u32),
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
/// Doc 52 P1: the RESIDENT sentinel activation. A resident promoted set is
/// keyed `RegionKey{ .region_id, .activation = RESIDENT_ACTIVATION }` —
/// unreachable by real activations (call creation panics long before
/// `call_seq` could get there). The sentinel is the STORAGE representation
/// only; every policy site goes through `isResidentKey`/`PromotedSet.
/// isResident`, never a raw compare.
pub const RESIDENT_ACTIVATION: u64 = std.math.maxInt(u64);

pub fn isResidentKey(key: RegionKey) bool {
    return key.activation == RESIDENT_ACTIVATION;
}

pub const PromotedSet = struct {
    edges: []PromotedEdge,
    summary: []nativegen.SilentSummaryCell,
    metadata: []nativegen.SilentExitMetadata,
    region_key: RegionKey,
    id: u32,

    /// Doc 52 P1: region-lifetime resident set (dormant region, no
    /// activation). Exempt from the activation sweep, the frozen-accumulator
    /// drain rules, and barren accounting.
    pub fn isResident(self: *const PromotedSet) bool {
        return isResidentKey(self.region_key);
    }
};
/// Parked physical-set evidence (doc 47 Increment B follow-up, codex C′
/// "parked promotion proofs"): the edge set of a promotion demoted by a clean
/// `.region_close`, retained keyed by RegionId so the region's next
/// activation can re-promote through the full fail-closed `promoteSet`
/// validation without re-earning the `promote_after` observation streak.
/// Activation-scoped AUTHORIZATION is untouched — a parked proof never
/// executes; it only lets a new frozen activation of the SAME region skip the
/// observational re-detection its physical set already passed. The edges hold
/// *Trace pointers and validation dereferences them, so proofs are eagerly
/// dropped whenever a referenced trace retires (`resetLinksTouching`) and
/// conservatively on link/defs-wide invalidation and teardown; the policy
/// owner additionally drops on region invalidation and topology rebuild.
pub const ParkedProof = struct {
    region_id: RegionId,
    edges: []PromotedEdge,
};
pub const DemotionReason = enum { activation, region_close, slot_mutation, trace_invalidation, teardown, unfreeze, membership_growth };
pub const PendingDemotion = struct { id: u32, reason: DemotionReason };
pub const SlotMutationReason = enum { arm, rearm, retire, disarm_all, disarm_one };
pub const PreparedSlotMutation = struct { compiled: *nativegen.CompiledTrace, exit: u32 };
pub const RegionArmProof = struct {
    id: RegionId,
    generation: u32,
};
pub const ArmRequest = struct {
    parent: *Trace,
    slot_index: u32,
    child: *Trace,
    kind: ArmKind,
    region: ?RegionArmProof = null,
};
pub fn exitPatchFor(compiled: *nativegen.CompiledTrace, exit: u32) ?*nativegen.ExitPatch {
    for (compiled.exit_patches) |*patch| if (patch.exit_instr == exit) return patch;
    return null;
}
pub fn originalRel32Target(compiled: *const nativegen.CompiledTrace, patch: *const nativegen.ExitPatch) usize {
    const bits: u32 = @as(u32, patch.original[1]) |
        (@as(u32, patch.original[2]) << 8) |
        (@as(u32, patch.original[3]) << 16) |
        (@as(u32, patch.original[4]) << 24);
    const disp: i32 = @bitCast(bits);
    const next = @intFromPtr(compiled.page.code.ptr) + patch.patch_off + 5;
    return @intCast(@as(i128, @intCast(next)) + disp);
}
fn physicalSlot(link: NativeLink) u32 {
    return if (link.physical_slot == std.math.maxInt(u32)) link.slot_index else link.physical_slot;
}

// Transition keys are page-lifetime allocation metadata, not arm state. A
// disarm resets only the executable target; retaining the first four distinct
// resume PCs makes allocation deterministic and prevents eviction-by-disarm.
pub fn clearSiblingLatch(link: NativeLink) void {
    if (link.kind != .sibling_handoff) return;
    link.parent.sibling_arms -|= 1;
    link.parent.sibling_watch_exit = std.math.maxInt(u32);
    link.parent.sibling_watch_count = 0;
    // The arm set touching this trace changed — the ineligible memo may have
    // been the armed-slot exclusion, so it must be re-derived.
    link.parent.sibling_reject_exit = std.math.maxInt(u32);
}

pub fn samePromotionEdges(a: []const PromotedEdge, b: []const PromotedEdge) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.parent.id != y.parent.id or x.exit != y.exit or x.child.id != y.child.id or
            x.kind != y.kind or x.arm_kind != y.arm_kind or x.resume_pc != y.resume_pc)
            return false;
    }
    return true;
}

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

pub const NativePhysicalRegistry = struct {
    gpa: std.mem.Allocator,
    provenance_invalidated: bool = false,
    /// Synchronized by the coordinator before physical transactions; no owner back-pointer.
    debug_log: bool = false,
    /// Armed native links (P-E, doc 17 Increment 2.3). Each record is a `parent`
    /// trace whose frameless exit slot `parent.native.compiled.slots[slot_index]`
    /// has been written to jump directly into `child`'s body. Kept so a retiring
    /// trace can be made lifetime-safe: when `child` is destroyed its arena slot
    /// returns to the reuse free-list and could be overwritten by unrelated code,
    /// so every parent slot pointing at it must first be reset to `shared_exit`;
    /// and when `parent` is destroyed its slot array is freed, so its records
    /// must be dropped before any child-retire tries to write through them.
    /// `resetLinksTouching` handles both directions by trace *identity* (never a
    /// raw slot pointer), so it is correct regardless of retire order.
    armed_links: std.ArrayListUnmanaged(NativeLink) = .empty,
    /// B-3b.2 silent-cycle registry; `promotedSets()` is the readers' view.
    promoted_sets: std.ArrayListUnmanaged(PromotedSet) = .empty,
    /// The exclusive physical-exit ownership index required by §B3.9(4); ids,
    /// rather than list indices, remain stable across swap-removal.
    promoted_exit_owners: std.AutoHashMapUnmanaged(ExitKey, u32) = .empty,
    next_promoted_set_id: u32 = 1,
    promotion_candidate: []PromotedEdge = &.{},
    promotion_candidate_run: u32 = 0,
    promotion_candidate_region: ?RegionKey = null,
    /// Cycle ids queued while replay is validating the armed-link registry.
    /// Capacity is reserved before promotion publication, so queuing is
    /// infallible.
    pending_demote: std.ArrayListUnmanaged(PendingDemotion) = .empty,
    replay_walk_depth: u32 = 0,
    pending_disarm_all: bool = false,
    /// Parked promotion proofs, one at most per RegionId (few regions live at
    /// once — a linear scan; see `ParkedProof`).
    parked_proofs: std.ArrayListUnmanaged(ParkedProof) = .empty,
    /// Doc 52 P1: cached counts of live sets by keying, maintained strictly at
    /// PHYSICAL publication/removal — incremented when a set is actually
    /// patched in (`promoteSet` append), decremented when it is actually
    /// unpatched and swap-removed (`demoteSetReason`'s removal path) — never
    /// when a deferred demotion is merely queued, since the patches stay live
    /// until `drainBarrier` applies it and the count-gated staging/sweep fast
    /// paths must agree with the patched reality.
    activation_set_count: usize = 0,
    resident_set_count: usize = 0,
    /// Doc 52 P1: resident-demotion notice. The demotion owner has no
    /// `RegionDef` access, and a demoted resident set's recurrence proof must
    /// be re-earned against the post-demotion world — the coordinator drains
    /// this in `syncNativeInvalidation` and zeroes that def's streak/signature.
    /// A single slot suffices: at most one resident set is live (invariant 1).
    resident_demotion_notice: ?RegionId = null,
    silent_promotions: u64 = 0,
    silent_demotions: u64 = 0,
    silent_demotion_reasons: PromotionDemotions = .{},
    native_link_disarms: u64 = 0,
    native_link_peak: usize = 0,
    pub fn init(gpa: std.mem.Allocator) NativePhysicalRegistry {
        return .{ .gpa = gpa };
    }
    inline fn dbg(self: *const NativePhysicalRegistry, comptime fmt: []const u8, args: anytype) void {
        const jitdbg = @import("jitdbg.zig");
        if (comptime jitdbg.enabled) {
            if (self.debug_log) jitdbg.log(fmt, args);
        }
    }
    pub fn armedLinks(self: *const NativePhysicalRegistry) []const NativeLink {
        return self.armed_links.items;
    }
    /// Replay-barrier bracket (A-vii-d.1): while a ledger walk is in flight,
    /// destructive link mutation is deferred or panics (every guard in this
    /// owner validates against the depth). Drivers bracket the walk with
    /// enter/exit; `replay_walk_depth` is owner state — never written directly
    /// by callers.
    pub fn enterReplayWalk(self: *NativePhysicalRegistry) void {
        self.replay_walk_depth += 1;
    }
    pub fn exitReplayWalk(self: *NativePhysicalRegistry) void {
        std.debug.assert(self.replay_walk_depth > 0);
        self.replay_walk_depth -= 1;
    }
    pub fn inReplayWalk(self: *const NativePhysicalRegistry) bool {
        return self.replay_walk_depth != 0;
    }
    /// Update only the memo of the exact relation/proof the reader validated.
    pub fn memoizeBridgeEdge(self: *NativePhysicalRegistry, parent: *Trace, slot: u32, child: *Trace, expected: RegionArmProof, edge: StructuralEdgeId, generation: u32) bool {
        for (self.armed_links.items) |*link| {
            if (link.parent != parent or link.slot_index != slot or link.child != child) continue;
            if (link.kind != .region_bridge or link.region_id != expected.id or link.armed_gen != expected.generation) return false;
            link.bridge_edge = edge;
            link.bridge_edge_gen = generation;
            return true;
        }
        return false;
    }
    /// Const view of the live promoted sets, mirroring `armedLinks`: readers
    /// iterate this; mutation goes through promote/demote/mailbox owner
    /// operations.
    pub fn promotedSets(self: *const NativePhysicalRegistry) []const PromotedSet {
        return self.promoted_sets.items;
    }
    /// Whether a live promoted set already owns this (trace, exit) relation.
    pub fn exitIsPromoted(self: *const NativePhysicalRegistry, trace_id: u32, exit_instr: u32) bool {
        return self.promoted_exit_owners.contains(.{ .trace_id = trace_id, .exit_instr = exit_instr });
    }
    /// Clear every live set's per-call summary mailbox. Native epilogues only
    /// add; the burst driver calls this once after consuming the complete
    /// image — every live set, not just the entry one, or a second live set
    /// that fused into the call would re-apply its work on its own next drain.
    pub fn clearSilentSummaries(self: *NativePhysicalRegistry) void {
        for (self.promoted_sets.items) |*c|
            @memset(c.summary, std.mem.zeroes(nativegen.SilentSummaryCell));
    }
    pub fn promotionCandidate(self: *const NativePhysicalRegistry) []const PromotedEdge {
        return self.promotion_candidate;
    }
    /// Takes ownership of edges allocated by this registry's allocator, even
    /// when an equal observation is discarded. Returned streak is saturating.
    pub fn observePromotionCandidate(self: *NativePhysicalRegistry, edges: []PromotedEdge, region: RegionKey) u32 {
        if (self.promotion_candidate_region != null and
            std.meta.eql(self.promotion_candidate_region.?, region) and
            samePromotionEdges(self.promotion_candidate, edges))
        {
            self.gpa.free(edges);
            self.promotion_candidate_run +|= 1;
        } else {
            self.resetPromotionCandidate();
            self.promotion_candidate = edges;
            self.promotion_candidate_region = region;
            self.promotion_candidate_run = 1;
        }
        return self.promotion_candidate_run;
    }
    pub fn takeInvalidation(self: *NativePhysicalRegistry) bool {
        const result = self.provenance_invalidated;
        self.provenance_invalidated = false;
        return result;
    }
    /// Doc 52 P1: drain the resident-demotion notice (see field doc). Take
    /// semantics; the coordinator zeroes the named def's recurrence proof.
    pub fn takeResidentDemotionNotice(self: *NativePhysicalRegistry) ?RegionId {
        const notice = self.resident_demotion_notice;
        self.resident_demotion_notice = null;
        return notice;
    }
    pub fn patchPromotedEdge(_: *NativePhysicalRegistry, arena: *nativegen.McodeArena, edge: PromotedEdge, promote: bool) nativegen.PatchError!void {
        const compiled = switch (edge.parent.native) {
            .compiled => |*c| c,
            else => return error.StalePage,
        };
        const generation = compiled.pageGeneration() orelse return error.NotArenaOwned;
        const patch = exitPatchFor(compiled, edge.exit) orelse return error.OffsetOutOfBounds;
        if (patch.kind != edge.kind) return error.OpcodeMismatch;
        const epilogue = @intFromPtr(compiled.page.code.ptr) + patch.epilogue_off;
        switch (edge.kind) {
            .deopt => try arena.*.patchRel32(
                &compiled.page,
                generation,
                patch.patch_off,
                if (promote) epilogue else originalRel32Target(compiled, patch),
            ),
            .link_terminal, .loop_done_linked, .region_bridge => try arena.*.patchWindow(
                &compiled.page,
                generation,
                patch.patch_off,
                patch.original,
                epilogue,
                promote,
            ),
        }
    }
    pub fn resetPromotionCandidate(self: *NativePhysicalRegistry) void {
        if (self.promotion_candidate.len != 0) self.gpa.free(self.promotion_candidate);
        self.promotion_candidate = &.{};
        self.promotion_candidate_run = 0;
        self.promotion_candidate_region = null;
    }
    pub fn queueDemote(self: *NativePhysicalRegistry, id: u32, reason: DemotionReason) void {
        for (self.pending_demote.items) |pending| if (pending.id == id) return;
        self.pending_demote.appendAssumeCapacity(.{ .id = id, .reason = reason });
    }
    /// Park a copy of `edges` as this region's proof, replacing any earlier
    /// one. OOM skips the park — a proof is an optimization, never load
    /// correctness state, so failing to retain it merely re-earns the streak.
    pub fn parkPromotionProof(self: *NativePhysicalRegistry, region_id: RegionId, edges: []const PromotedEdge) void {
        const copy = self.gpa.dupe(PromotedEdge, edges) catch return;
        self.dropParkedProof(region_id);
        self.parked_proofs.append(self.gpa, .{ .region_id = region_id, .edges = copy }) catch {
            self.gpa.free(copy);
            return;
        };
        self.dbg("silent-park: rid={d} len={d}", .{ @intFromEnum(region_id), edges.len });
    }
    /// Remove and return the region's parked proof (caller owns/frees), or
    /// null. Removal on take is deliberate: a proof that fails re-validation
    /// must not be retried forever.
    pub fn takeParkedProof(self: *NativePhysicalRegistry, region_id: RegionId) ?[]PromotedEdge {
        for (self.parked_proofs.items, 0..) |p, i| {
            if (p.region_id == region_id) {
                const edges = p.edges;
                _ = self.parked_proofs.swapRemove(i);
                return edges;
            }
        }
        return null;
    }
    pub fn dropParkedProof(self: *NativePhysicalRegistry, region_id: RegionId) void {
        for (self.parked_proofs.items, 0..) |p, i| {
            if (p.region_id == region_id) {
                self.gpa.free(p.edges);
                _ = self.parked_proofs.swapRemove(i);
                return;
            }
        }
    }
    pub fn dropAllParkedProofs(self: *NativePhysicalRegistry) void {
        for (self.parked_proofs.items) |p| self.gpa.free(p.edges);
        self.parked_proofs.clearRetainingCapacity();
    }
    /// A physical (parent, exit) relation is being mutated; every parked
    /// proof naming that exit is falsified and dropped.
    pub fn dropParkedProofsTouchingExit(self: *NativePhysicalRegistry, parent: *Trace, exit: u32) void {
        var i = self.parked_proofs.items.len;
        while (i > 0) {
            i -= 1;
            for (self.parked_proofs.items[i].edges) |edge| {
                if (edge.parent == parent and edge.exit == exit) {
                    self.gpa.free(self.parked_proofs.items[i].edges);
                    _ = self.parked_proofs.swapRemove(i);
                    break;
                }
            }
        }
    }
    /// A retiring trace's memory is about to be reused; every parked proof
    /// whose edges point at it becomes a dangling-pointer hazard (validation
    /// dereferences `edge.parent`/`edge.child`) and is dropped eagerly.
    pub fn dropParkedProofsTouching(self: *NativePhysicalRegistry, t: *Trace) void {
        var i = self.parked_proofs.items.len;
        while (i > 0) {
            i -= 1;
            for (self.parked_proofs.items[i].edges) |edge| {
                if (edge.parent == t or edge.child == t) {
                    self.gpa.free(self.parked_proofs.items[i].edges);
                    _ = self.parked_proofs.swapRemove(i);
                    break;
                }
            }
        }
    }
    pub fn demoteSet(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, idx: usize) void {
        self.demoteSetReason(arena, idx, .trace_invalidation);
    }
    /// Doc 52 P1: the cached by-keying counts must always agree with the live
    /// list — they gate the native-entry sweep and staging fast paths.
    fn assertSetCountsConsistent(self: *const NativePhysicalRegistry) void {
        if (std.debug.runtime_safety) {
            var residents: usize = 0;
            var activations: usize = 0;
            for (self.promoted_sets.items) |*s| {
                if (s.isResident()) residents += 1 else activations += 1;
            }
            std.debug.assert(residents == self.resident_set_count);
            std.debug.assert(activations == self.activation_set_count);
        }
    }
    pub fn demoteSetReason(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, idx: usize, reason: DemotionReason) void {
        const set = self.promoted_sets.items[idx];
        if (self.replay_walk_depth > 0) {
            // Deferred: patches stay live until `drainBarrier` re-enters this
            // funnel at depth 0 — counts and notices move only on the physical
            // removal below (doc 52 P1).
            self.queueDemote(set.id, reason);
            return;
        }
        // Teardown order is the inverse publication order: code first, cells
        // second, then ownership/storage. A failed restore intentionally leaves
        // every cell and allocation live before terminating the process.
        for (set.edges) |edge| self.patchPromotedEdge(arena, edge, false) catch
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
        // Doc 52 P1: physical removal — decrement the keying count and, for a
        // resident set, record the notice so the coordinator re-earns the
        // recurrence proof (any demotion reason; the post-demotion world is a
        // different promotion target).
        if (isResidentKey(set.region_key)) {
            self.resident_set_count -= 1;
            self.resident_demotion_notice = set.region_key.region_id;
        } else {
            self.activation_set_count -= 1;
        }
        self.assertSetCountsConsistent();
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
    pub fn demoteSetsTouching(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, parent: *Trace, exit: u32) void {
        const id = self.promoted_exit_owners.get(.{ .trace_id = parent.id, .exit_instr = exit }) orelse return;
        for (self.promoted_sets.items, 0..) |set, i| {
            if (set.id == id) {
                self.demoteSetReason(arena, i, .slot_mutation);
                return;
            }
        }
        @panic("demoteSetsTouching: owner names no live set");
    }
    pub fn demoteSetsTouchingTrace(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, trace: *Trace) void {
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
            if (touches) self.demoteSetReason(arena, i, .trace_invalidation);
        }
    }
    pub fn demoteAllSets(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena) void {
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            self.demoteSetReason(arena, i, .teardown);
        }
    }
    pub fn demoteSetsForRegionDefsMutation(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena) void {
        // Region membership is part of every parked proof too.
        self.dropAllParkedProofs();
        self.resetPromotionCandidate();
        var i = self.promoted_sets.items.len;
        while (i > 0) {
            i -= 1;
            // Region membership is part of every promotion proof, and a bridge
            // additionally freezes its exact structural edge. Any defs mutation
            // invalidates both facts, so no promoted set may survive the gen bump.
            self.demoteSetReason(arena, i, .trace_invalidation);
        }
    }
    pub fn prepareSlotMutation(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, parent: *Trace, exit: u32, reason: SlotMutationReason) !PreparedSlotMutation {
        // Sole physical slot-write funnel; identical convergence re-arms
        // short-circuit before reaching it, so every call is a REAL relation
        // mutation. A parked proof naming this exit is falsified by it —
        // dropped here so a later equivalent re-arm cannot resurrect evidence
        // that negative provenance invalidated (codex round-4 blocker).
        self.dropParkedProofsTouchingExit(parent, exit);
        switch (reason) {
            .retire, .disarm_all, .disarm_one => self.resetPromotionCandidate(),
            .arm, .rearm => {}, // caller distinguishes identical convergence re-arms
        }
        const compiled = switch (parent.native) {
            .compiled => |*c| c,
            else => return error.NativeTraceUnavailable,
        };
        if (exit >= compiled.slots.len) return error.InvalidNativeSlot;
        self.demoteSetsTouching(arena, parent, exit);
        if (self.promoted_exit_owners.contains(.{ .trace_id = parent.id, .exit_instr = exit }))
            return error.DemotionDeferred;
        return .{ .compiled = compiled, .exit = exit };
    }
    pub fn commitSlotMutation(_: *NativePhysicalRegistry, prepared: PreparedSlotMutation, target: usize) void {
        prepared.compiled.slots[prepared.exit] = target;
    }
    pub fn resetLinksTouching(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, t: *Trace) void {
        if (self.replay_walk_depth != 0) @panic("resetLinksTouching during replay");
        self.dropParkedProofsTouching(t);
        self.demoteSetsTouchingTrace(arena, t);
        const shared_exit = arena.*.trampoline_exit orelse 0;
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
                const p = physicalSlot(link);
                switch (link.parent.native) {
                    .compiled => |*c| if (p < c.slots.len) {
                        const prepared = self.prepareSlotMutation(arena, link.parent, p, .retire) catch
                            @panic("resetLinksTouching: invalid native slot mutation");
                        self.commitSlotMutation(prepared, shared_exit);
                    },
                    else => {},
                }
            }
            _ = self.armed_links.swapRemove(i);
            // A removed arm may be re-publishable from a surviving provenance
            // edge — let the drain re-evaluate at the next safe point.
            self.provenance_invalidated = true;
        }
    }
    pub fn disarmAllLinks(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena) void {
        // Parked proofs drop FIRST, unconditionally — before the deferred
        // branch and before the empty-links early return (codex round-4
        // blocker: `TraceRegistry.clear` reaches this with zero armed links
        // and then DESTROYS every trace, so a surviving proof would dangle;
        // and a blackout must never let pre-blackout evidence be resurrected
        // by an equivalent later re-arm). Dropping is pointer-safe mid-walk —
        // no code patching is involved.
        self.dropAllParkedProofs();
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
        const shared_exit = arena.*.trampoline_exit orelse 0;
        for (self.armed_links.items) |link| {
            clearSiblingLatch(link);
            const p = physicalSlot(link);
            switch (link.parent.native) {
                .compiled => |*c| if (p < c.slots.len) {
                    const prepared = self.prepareSlotMutation(arena, link.parent, p, .disarm_all) catch
                        @panic("disarmAllLinks: invalid native slot mutation");
                    self.commitSlotMutation(prepared, shared_exit);
                },
                else => {},
            }
        }
        self.armed_links.clearRetainingCapacity();
        // See resetLinksTouching: removed arms re-open provenance publication.
        self.provenance_invalidated = true;
    }
    pub fn disarmLinkAt(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, idx: usize) void {
        if (self.replay_walk_depth != 0) @panic("disarmLinkAt during replay");
        const link = self.armed_links.items[idx];
        self.native_link_disarms +|= 1;
        clearSiblingLatch(link);
        const shared_exit = arena.*.trampoline_exit orelse 0;
        const p = physicalSlot(link);
        switch (link.parent.native) {
            .compiled => |*c| if (p < c.slots.len) {
                const prepared = self.prepareSlotMutation(arena, link.parent, p, .disarm_one) catch
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
        self.provenance_invalidated = true;
    }
    /// The physical promotability prologue, shared with the coordinator's
    /// policy wrapper so error precedence lives in exactly one place: bounds
    /// and id space, then one-live-set-per-region, then exit ownership.
    /// `promoteSet` re-runs it before mutating (fail-closed even on a direct
    /// owner call).
    ///
    /// B-3d (§B3.17 R1): ONE live set per region key, enforced — not assumed.
    /// The reachable race this closes: a growth demote queued mid-walk has not
    /// applied yet when a promotion-eligible candidate arrives; accepting the
    /// second set would put two overlapping promotions on one region and break
    /// the PROVENANCE_VERDICT_CAP sizing argument. The reject resets the
    /// candidate streak (caller), costing one extra 4-window round —
    /// deterministic and accepted (§B3.18 R7 churn note).
    pub fn checkPromotable(self: *const NativePhysicalRegistry, edges: []const PromotedEdge, region_key: RegionKey) !void {
        if (edges.len == 0 or edges.len > PROMOTED_SET_CAP) return error.InvalidPromotionSet;
        if (self.next_promoted_set_id == std.math.maxInt(u32)) return error.PromotionIdExhausted;
        // Doc 52 P1 invariant 1: at most one live resident set globally. A
        // second region's recurrence streak holds — saturating — until the
        // occupant demotes.
        if (isResidentKey(region_key) and self.resident_set_count != 0)
            return error.PromotionResidentOccupied;
        for (self.promoted_sets.items) |s| {
            if (std.meta.eql(s.region_key, region_key)) return error.PromotionRegionOwned;
            // Doc 52 P1 invariant 3: per-RegionId uniqueness ACROSS keyings —
            // a sentinel key and a real activation key for the same RegionId
            // must never coexist (fail-closed backstop; resident regions are
            // dormant and never open activations, so this is near-impossible
            // in practice).
            if (s.region_key.region_id == region_key.region_id)
                return error.PromotionRegionIdOwned;
        }
        for (edges) |edge| {
            if (self.promoted_exit_owners.contains(.{ .trace_id = edge.parent.id, .exit_instr = edge.exit })) return error.PromotionExitOwned;
        }
    }
    pub fn promoteSet(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, edges: []const PromotedEdge, region_key: RegionKey, min_useful: usize) !void {
        try self.checkPromotable(edges, region_key);
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
                .min_useful = min_useful,
                .reporting_target = switch (edge.kind) {
                    .deopt => originalRel32Target(compiled, exitPatchFor(compiled, edge.exit).?),
                    .link_terminal, .loop_done_linked, .region_bridge => @intFromPtr(compiled.page.code.ptr) +
                        exitPatchFor(compiled, edge.exit).?.patch_off + 5,
                },
                // Doc 52 P1: residency is decided at promotion time, per set —
                // resident edges neither advance nor reset the barren run.
                .barren_exempt = @intFromBool(isResidentKey(region_key)),
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
                self.patchPromotedEdge(arena, owned_edges[patched], false) catch
                    @panic("promoteSet: failed to restore reporting code during unwind");
            }
            for (owned_edges) |edge| edge.parent.native.compiled.metadata_cells[edge.exit] = 0;
        }
        for (owned_edges) |edge| {
            try self.patchPromotedEdge(arena, edge, true);
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
        // Doc 52 P1: physical publication — the set is patched in as of the
        // loop above, so the keying count moves here (and only here).
        if (isResidentKey(region_key))
            self.resident_set_count += 1
        else
            self.activation_set_count += 1;
        self.assertSetCountsConsistent();
        self.silent_promotions +|= 1;
    }
    pub const ArmOutcome = enum { declined, unchanged, changed };
    pub fn publishValidatedLink(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, request: ArmRequest) !ArmOutcome {
        const parent = request.parent;
        const child = request.child;
        const kind = request.kind;
        const slot_index = request.slot_index;
        const region_id: ?RegionId = if (request.region) |proof| proof.id else null;
        const armed_gen: u32 = if (request.region) |proof| proof.generation else 0;
        const c = switch (parent.native) {
            .compiled => |*cc| cc,
            else => return .declined,
        };
        const ir_slots: u32 = @intCast(parent.code.instrs.len);
        var physical_slot: u32 = slot_index;
        switch (kind) {
            .ret_cont => {
                if (c.ret_cont_keys.len != nativegen.RET_CONT_SLOTS) return .declined;
                var free: ?u32 = null;
                for (c.ret_cont_keys, 0..) |key, i| {
                    if (key == slot_index) {
                        physical_slot = ir_slots + @as(u32, @intCast(i));
                        free = null;
                        break;
                    }
                    if (key == std.math.maxInt(u32) and free == null) free = @intCast(i);
                } else if (free) |i| {
                    physical_slot = ir_slots + i;
                } else return .declined;
            },
            .call_head => physical_slot = ir_slots + @as(u32, nativegen.RET_CONT_SLOTS),
            else => {},
        }
        if (physical_slot >= c.slots.len) return .declined;
        const child_c = switch (child.native) {
            .compiled => |*cc| cc,
            else => return .declined,
        };
        const target = switch (kind) {
            .link_terminal => child_c.linked_entry orelse return .declined,
            .region_bridge => child_c.ordinary_entry orelse @panic("armNativeLink(.region_bridge): child has no ordinary_entry"),
            else => child_c.ordinary_entry orelse return .declined,
        };
        // A re-arm of this exact slot supersedes any prior child it pointed at.
        // Mutate the existing record IN PLACE (no allocation) — the earlier
        // remove-then-append ordering could OOM after dropping the old record,
        // stranding the slot armed-but-untracked (2.3a review BUG-1). Because at
        // most one record exists per (parent, slot_index) — this loop guarantees
        // it — the first match is the only match.
        for (self.armed_links.items) |*l| {
            const existing_physical = if (l.physical_slot == std.math.maxInt(u32)) l.slot_index else l.physical_slot;
            if (l.parent == parent and existing_physical == physical_slot) {
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
                if (l.child == child and l.kind == kind and c.slots[physical_slot] == target and
                    kind != .sibling_handoff)
                {
                    // Refresh proof metadata within the publication owner, including
                    // convergence re-arms that leave physical code unchanged.
                    if (request.region != null) {
                        if (l.region_id != region_id or l.armed_gen != armed_gen) {
                            l.bridge_edge = null;
                            l.bridge_edge_gen = 0;
                        }
                        l.region_id = region_id;
                        l.armed_gen = armed_gen;
                    }
                    self.dbg("arm (identical re-arm short-circuit): parent id={d} pc={d} slot={d} kind={s}", .{
                        parent.id, parent.code.anchor.pc, slot_index, @tagName(kind),
                    });
                    return .unchanged;
                }
                // Convergence sites re-publish an identical relation on every
                // terminal observation. Keep that from breaking the consecutive
                // detection streak; a changed relation invalidates the candidate.
                if (l.child != child or l.kind != kind or c.slots[physical_slot] != target)
                    self.resetPromotionCandidate();
                const prepared = self.prepareSlotMutation(arena, parent, physical_slot, .rearm) catch return .declined;
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
                    self.provenance_invalidated = true;
                if (l.kind == .sibling_handoff)
                    clearSiblingLatch(l.*);
                l.child = child;
                l.kind = kind;
                l.physical_slot = physical_slot;
                l.region_id = region_id;
                l.armed_gen = armed_gen;
                l.bridge_edge = null; // drop the replay memo with the old child
                l.bridge_edge_gen = 0;
                self.commitSlotMutation(prepared, target);
                self.dbg("arm (re-arm): parent id={d} pc={d} slot={d} -> child id={d} pc={d} kind={s}", .{
                    parent.id, parent.code.anchor.pc, slot_index, child.id, child.code.anchor.pc, @tagName(kind),
                });

                return .changed;
            }
        }
        // Fresh slot: append the record BEFORE writing the slot, so a failed append
        // leaves the slot at its prior `shared_exit` value with no dangling record.
        self.resetPromotionCandidate();
        const prepared = self.prepareSlotMutation(arena, parent, physical_slot, .arm) catch return .declined;
        try self.armed_links.append(self.gpa, .{ .parent = parent, .slot_index = slot_index, .physical_slot = physical_slot, .child = child, .kind = kind, .region_id = region_id, .armed_gen = armed_gen });
        if (kind == .ret_cont) c.ret_cont_keys[physical_slot - ir_slots] = slot_index;
        if (self.armed_links.items.len > self.native_link_peak) self.native_link_peak = self.armed_links.items.len;
        self.commitSlotMutation(prepared, target);
        self.dbg("arm: parent id={d} pc={d} slot={d} -> child id={d} pc={d} kind={s}", .{
            parent.id, parent.code.anchor.pc, slot_index, child.id, child.code.anchor.pc, @tagName(kind),
        });

        return .changed;
    }
    pub fn drainBarrier(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena) bool {
        if (self.replay_walk_depth != 0) @panic("drainBarrier during replay");
        while (self.pending_demote.items.len > 0) {
            const pending = self.pending_demote.pop().?;
            for (self.promoted_sets.items, 0..) |set, i| {
                if (set.id == pending.id) {
                    self.demoteSetReason(arena, i, pending.reason);
                    break;
                }
            }
        }
        if (!self.pending_disarm_all) return false;
        self.pending_disarm_all = false;
        self.disarmAllLinks(arena);
        return true;
    }
    pub fn deinit(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena) void {
        if (self.replay_walk_depth != 0) @panic("native registry teardown during replay");
        self.demoteAllSets(arena);
        self.disarmAllLinks(arena);
        self.armed_links.deinit(self.gpa);
        self.pending_demote.deinit(self.gpa);
        self.resetPromotionCandidate();
        self.dropAllParkedProofs();
        self.parked_proofs.deinit(self.gpa);
        self.promoted_exit_owners.deinit(self.gpa);
        self.promoted_sets.deinit(self.gpa);
    }
};

test "frame link physical cells disarm without recycling the first four return keys" {
    var arena = nativegen.McodeArena.init(std.testing.allocator);
    defer arena.deinit();
    var registry = NativePhysicalRegistry.init(std.testing.allocator);
    defer registry.deinit(&arena);
    var proto: @import("bytecode.zig").Proto = .{ .code = &.{} };
    var instrs = [_]@import("trace_ir.zig").IrInstr{.{ .op = .terminal }};
    var slots = [_]usize{ 0, 0, 0, 0, 0, 0 };
    const unset = std.math.maxInt(u32);
    var keys = [_]u32{ unset, unset, unset, unset };
    var parent: Trace = .{
        .id = 100,
        .code = .{ .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} },
        .native = .{ .compiled = .{ .page = undefined, .gpa = std.testing.allocator, .slots = &slots, .ret_cont_keys = &keys } },
    };
    var child: Trace = .{
        .id = 101,
        .code = .{ .anchor = parent.code.anchor, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} },
        .native = .{ .compiled = .{ .page = undefined, .gpa = std.testing.allocator, .ordinary_entry = 0xCAFE } },
    };
    // No executable code is needed: the physical owner mutates data cells only.
    for (0..4) |i| {
        const pc: u32 = @intCast(1000 + i);
        try std.testing.expect(try registry.publishValidatedLink(&arena, .{ .parent = &parent, .child = &child, .slot_index = pc, .kind = .ret_cont }) == .changed);
        try std.testing.expect(keys[i] == pc and slots[i + 1] == 0xCAFE);
    }
    try std.testing.expect(slots[0] == 0);
    registry.disarmAllLinks(&arena);
    for (slots) |target| try std.testing.expect(target == 0);
    for (keys, 0..) |pc, i| try std.testing.expect(pc == 1000 + i);
    try std.testing.expect(try registry.publishValidatedLink(&arena, .{ .parent = &parent, .child = &child, .slot_index = 2000, .kind = .ret_cont }) == .declined);
    try std.testing.expect(try registry.publishValidatedLink(&arena, .{ .parent = &parent, .child = &child, .slot_index = 1002, .kind = .ret_cont }) == .changed);
    try std.testing.expect(slots[3] == 0xCAFE);
    try std.testing.expect(try registry.publishValidatedLink(&arena, .{ .parent = &parent, .child = &child, .slot_index = 0, .kind = .call_head }) == .changed);
    try std.testing.expect(slots[5] == 0xCAFE);
    registry.resetLinksTouching(&arena, &child);
    for (slots) |target| try std.testing.expect(target == 0);
    for (keys, 0..) |pc, i| try std.testing.expect(pc == 1000 + i);
    try std.testing.expect(registry.armedLinks().len == 0);
}

test "native owner barrier cancels policy arm even with no live links" {
    var arena = nativegen.McodeArena.init(std.testing.allocator);
    defer arena.deinit();
    var registry = NativePhysicalRegistry.init(std.testing.allocator);
    defer registry.deinit(&arena);
    registry.replay_walk_depth = 1;
    registry.disarmAllLinks(&arena);
    try std.testing.expect(registry.pending_disarm_all);
    registry.replay_walk_depth = 0;
    try std.testing.expect(registry.drainBarrier(&arena));
    try std.testing.expect(!registry.drainBarrier(&arena));
}

test "native owner invalidation is consumed exactly once" {
    var registry = NativePhysicalRegistry.init(std.testing.allocator);
    registry.provenance_invalidated = true;
    try std.testing.expect(registry.takeInvalidation());
    try std.testing.expect(!registry.takeInvalidation());
}

test "native owner candidate consumes equal observations and replaces by region" {
    var registry = NativePhysicalRegistry.init(std.testing.allocator);
    defer registry.resetPromotionCandidate();
    var parent: Trace = undefined;
    parent.id = 1;
    var child: Trace = undefined;
    child.id = 2;
    const edges = [_]PromotedEdge{.{ .parent = &parent, .child = &child, .exit = 3, .kind = .deopt, .arm_kind = .ordinary_guard, .resume_pc = 4 }};
    const key = RegionKey{ .region_id = @enumFromInt(1), .activation = 7 };
    const first = try std.testing.allocator.dupe(PromotedEdge, &edges);
    try std.testing.expectEqual(@as(u32, 1), registry.observePromotionCandidate(first, key));
    try std.testing.expectEqual(@as(u32, 2), registry.observePromotionCandidate(try std.testing.allocator.dupe(PromotedEdge, &edges), key));
    try std.testing.expect(registry.promotionCandidate().ptr == first.ptr);
    try std.testing.expectEqual(@as(u32, 1), registry.observePromotionCandidate(try std.testing.allocator.dupe(PromotedEdge, &edges), .{ .region_id = key.region_id, .activation = 8 }));
    registry.resetPromotionCandidate();
    try std.testing.expectEqual(@as(usize, 0), registry.promotionCandidate().len);
}

test "native owner bridge memo requires exact relation and proof" {
    var registry = NativePhysicalRegistry.init(std.testing.allocator);
    defer registry.armed_links.deinit(std.testing.allocator);
    var parent: Trace = undefined;
    var child: Trace = undefined;
    var other: Trace = undefined;
    const proof = RegionArmProof{ .id = @enumFromInt(1), .generation = 2 };
    try registry.armed_links.append(std.testing.allocator, .{ .parent = &parent, .child = &child, .slot_index = 3, .kind = .region_bridge, .region_id = proof.id, .armed_gen = proof.generation });
    const edge = StructuralEdgeId{ .anchor_proto_id = 0, .anchor_pc = 0, .exit = .{ .link_terminal = std.mem.zeroes(@import("trace_types.zig").LinkTerminalProvenance) }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 0 };
    try std.testing.expect(!registry.memoizeBridgeEdge(&other, 3, &child, proof, edge, 4));
    try std.testing.expect(!registry.memoizeBridgeEdge(&parent, 4, &child, proof, edge, 4));
    try std.testing.expect(!registry.memoizeBridgeEdge(&parent, 3, &other, proof, edge, 4));
    try std.testing.expect(!registry.memoizeBridgeEdge(&parent, 3, &child, .{ .id = proof.id, .generation = 3 }, edge, 4));
    try std.testing.expect(!registry.memoizeBridgeEdge(&parent, 3, &child, .{ .id = @enumFromInt(2), .generation = 2 }, edge, 4));
    try std.testing.expectEqual(@as(u32, 0), registry.armedLinks()[0].bridge_edge_gen);
    try std.testing.expect(registry.memoizeBridgeEdge(&parent, 3, &child, proof, edge, 4));
    try std.testing.expectEqual(@as(u32, 4), registry.armedLinks()[0].bridge_edge_gen);
}
