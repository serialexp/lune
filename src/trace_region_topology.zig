//! Owned staged topology and immutable input contract.
//! Coordinator: build edges, build regions, reserve logical maps, DEMOTE sets,
//! publish logical changes and physical indices, bump defs generation, disarm
//! stale bridges using live_armable_ids, then close non-armable accumulators.
//! On any failure retain logical entries/next id, empty physical indices and
//! disarm stale bridges with an empty live set. No input borrows survive build.
const std = @import("std");
const region = @import("trace_region.zig");
const types = @import("trace_types.zig");
const TraceCode = @import("trace_code.zig").TraceCode;
const Proto = @import("bytecode.zig").Proto;
const RegionId = region.RegionId;
const RegionDef = region.RegionDef;
const RegionBridgeDef = region.RegionBridgeDef;
const StructuralEdgeId = types.StructuralEdgeId;
const AnchorKey = types.AnchorKey;
pub const EdgeMap = std.AutoHashMapUnmanaged(types.ExitKey, StructuralEdgeId);
pub const DefMap = std.AutoHashMapUnmanaged(RegionId, RegionDef);
pub const ExitFact = struct {
    index: u32,
    successor: ?struct { proto_id: u32, pc: u32 } = null,
};
pub const TraceRecord = struct {
    id: u32,
    code: *const TraceCode,
    inner_root: bool,
    exits: []const ExitFact,
};
/// A same-anchor sibling provenance link (doc 17 §B.5 `ProvenanceEdge`, exit
/// dropped): `child` was recorded off one of `parent`'s exits at the same anchor.
pub const SiblingLink = struct { parent_id: u32, child_id: u32 };

/// The build's read-only input. Build it with `init`, which indexes it so
/// both lookups are O(1); the indices live in the caller's scratch allocator.
pub const View = struct {
    traces: []const TraceRecord,
    /// Doc 55 §2: closes `arrival_entry_regions` over same-anchor sibling groups.
    sibling_links: []const SiblingLink = &.{},
    /// Trace id → index into `traces` (the first record carrying the id).
    by_id: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Anchors where some record has `inner_root`.
    inner_roots: std.AutoHashMapUnmanaged(AnchorKey, void) = .empty,

    pub fn init(scratch: std.mem.Allocator, traces: []const TraceRecord, sibling_links: []const SiblingLink) !View {
        var v: View = .{ .traces = traces, .sibling_links = sibling_links };
        try v.by_id.ensureTotalCapacity(scratch, @intCast(traces.len));
        for (traces, 0..) |t, i| {
            const gop = v.by_id.getOrPutAssumeCapacity(t.id);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
            if (t.inner_root) try v.inner_roots.put(scratch, t.code.anchor, {});
        }
        return v;
    }
    pub fn traceById(self: View, id: u32) ?TraceRecord {
        const i = self.by_id.get(id) orelse return null;
        return self.traces[i];
    }
    pub fn hasInnerRootAt(self: View, proto: *const Proto, pc: u32) bool {
        return self.inner_roots.contains(.{ .proto = proto, .pc = pc });
    }
};
pub const Previous = struct {
    intern: *const region.RegionInternMap,
    defs: *const DefMap,
    next_id: u64,
};
pub const build = @import("trace_region_topology_build.zig").build;
pub fn buildEdges(gpa: std.mem.Allocator, view: View) !EdgeMap {
    var out: EdgeMap = .empty;
    errdefer out.deinit(gpa);
    var upper: usize = 0;
    for (view.traces) |t| upper = std.math.add(usize, upper, t.code.exit_prov.len) catch return error.OutOfMemory;
    if (upper > 1 << 30) return error.OutOfMemory;
    try out.ensureTotalCapacity(gpa, @intCast(upper));
    // `exits[i]` is the fact for `exit_prov[i]` (the view is built that way).
    for (view.traces) |t| for (t.code.exit_prov, t.exits) |e, fact| {
        std.debug.assert(fact.index == e.index);
        const succ = fact.successor orelse continue;
        out.putAssumeCapacity(.{ .trace_id = t.id, .exit_instr = e.index }, .{
            .anchor_proto_id = t.code.anchor.proto.id,
            .anchor_pc = t.code.anchor.pc,
            .exit = e.prov,
            .succ_anchor_proto_id = succ.proto_id,
            .succ_anchor_pc = succ.pc,
        });
    };
    return out;
}
pub const StagedIntern = struct { edges: []StructuralEdgeId, id: RegionId };
pub const StagedDef = struct { id: RegionId, def: RegionDef };
pub const StagedBridgeUpdate = struct { id: RegionId, bridges: []RegionBridgeDef };
pub const StagedOwnerUpdate = struct { id: RegionId, owner: AnchorKey };
pub const StagedArmableUpdate = struct {
    id: RegionId,
    armable: bool,
    fallback_owner: bool = false,
    /// Effective dormancy after this rebind (kept from the stored def when the
    /// election tier is unchanged; reset to `fallback_owner` when it flips).
    dormant: bool = false,
    /// True when the election tier flipped primary↔fallback: publish must zero
    /// the region's fallback learning counters (instability, no_candidate_runs,
    /// admission_failures) so stale evidence never crosses a tier change.
    reset_learning: bool = false,
};
pub const Rebuild = struct {
    staged_interns: std.ArrayListUnmanaged(StagedIntern) = .empty,
    staged_defs: std.ArrayListUnmanaged(StagedDef) = .empty,
    staged_bridge_updates: std.ArrayListUnmanaged(StagedBridgeUpdate) = .empty,
    staged_tombstones: std.ArrayListUnmanaged(RegionId) = .empty,
    staged_owner_updates: std.ArrayListUnmanaged(StagedOwnerUpdate) = .empty,
    staged_armable_updates: std.ArrayListUnmanaged(StagedArmableUpdate) = .empty,
    live_armable_ids: std.ArrayListUnmanaged(RegionId) = .empty,
    source: std.AutoHashMapUnmanaged(types.ExitKey, []RegionId) = .empty,
    dest: std.AutoHashMapUnmanaged(u32, []RegionId) = .empty,
    arrival: std.AutoHashMapUnmanaged(u32, []RegionId) = .empty,
    next_id: u64,
    pub fn deinit(self: *Rebuild, gpa: std.mem.Allocator) void {
        for (self.staged_interns.items) |s| gpa.free(s.edges);
        for (self.staged_defs.items) |s| {
            gpa.free(s.def.members);
            gpa.free(s.def.member_points);
            region.freeRegionBridges(gpa, s.def.bridges);
        }
        for (self.staged_bridge_updates.items) |s| region.freeRegionBridges(gpa, s.bridges);
        self.staged_interns.deinit(gpa);
        self.staged_defs.deinit(gpa);
        self.staged_bridge_updates.deinit(gpa);
        self.staged_tombstones.deinit(gpa);
        self.staged_owner_updates.deinit(gpa);
        self.staged_armable_updates.deinit(gpa);
        self.live_armable_ids.deinit(gpa);
        region.freeRegionSetMap(types.ExitKey, &self.source, gpa);
        region.freeRegionSetMap(u32, &self.dest, gpa);
        region.freeRegionSetMap(u32, &self.arrival, gpa);
        self.* = undefined;
    }
};

test {
    _ = @import("trace_region_topology_test.zig");
}
