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
};
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
pub const PromotedSet = struct {
    edges: []PromotedEdge,
    summary: []nativegen.SilentSummaryCell,
    metadata: []nativegen.SilentExitMetadata,
    region_key: RegionKey,
    id: u32,
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
    armed_links: std.ArrayListUnmanaged(NativeLink) = .empty,
    promoted_sets: std.ArrayListUnmanaged(PromotedSet) = .empty,
    promoted_exit_owners: std.AutoHashMapUnmanaged(ExitKey, u32) = .empty,
    next_promoted_set_id: u32 = 1,
    promotion_candidate: []PromotedEdge = &.{},
    promotion_candidate_run: u32 = 0,
    promotion_candidate_region: ?RegionKey = null,
    pending_demote: std.ArrayListUnmanaged(PendingDemotion) = .empty,
    replay_walk_depth: u32 = 0,
    pending_disarm_all: bool = false,
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
    pub fn demoteSet(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, idx: usize) void {
        self.demoteSetReason(arena, idx, .trace_invalidation);
    }
    pub fn demoteSetReason(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, idx: usize, reason: DemotionReason) void {
        const set = self.promoted_sets.items[idx];
        if (self.replay_walk_depth > 0) {
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
                switch (link.parent.native) {
                    .compiled => |*c| if (link.slot_index < c.slots.len) {
                        const prepared = self.prepareSlotMutation(arena, link.parent, link.slot_index, .retire) catch
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
            switch (link.parent.native) {
                .compiled => |*c| if (link.slot_index < c.slots.len) {
                    const prepared = self.prepareSlotMutation(arena, link.parent, link.slot_index, .disarm_all) catch
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
        switch (link.parent.native) {
            .compiled => |*c| if (link.slot_index < c.slots.len) {
                const prepared = self.prepareSlotMutation(arena, link.parent, link.slot_index, .disarm_one) catch
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
    pub fn promoteSet(self: *NativePhysicalRegistry, arena: *nativegen.McodeArena, edges: []const PromotedEdge, region_key: RegionKey, min_useful: usize) !void {
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
        for (edges) |edge| {
            if (self.promoted_exit_owners.contains(.{ .trace_id = edge.parent.id, .exit_instr = edge.exit })) return error.PromotionExitOwned;
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
                .min_useful = min_useful,
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
        if (slot_index >= c.slots.len) return .declined;
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
                if (l.child != child or l.kind != kind or c.slots[slot_index] != target)
                    self.resetPromotionCandidate();
                const prepared = self.prepareSlotMutation(arena, parent, slot_index, .rearm) catch return .declined;
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
        const prepared = self.prepareSlotMutation(arena, parent, slot_index, .arm) catch return .declined;
        try self.armed_links.append(self.gpa, .{ .parent = parent, .slot_index = slot_index, .child = child, .kind = kind, .region_id = region_id, .armed_gen = armed_gen });
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
        self.promoted_exit_owners.deinit(self.gpa);
        self.promoted_sets.deinit(self.gpa);
    }
};

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
