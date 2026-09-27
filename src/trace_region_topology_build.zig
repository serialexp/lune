//! Immutable topology discovery. No registry, coordinator, callbacks, or native mutation.
const std = @import("std");
const region = @import("trace_region.zig");
const types = @import("trace_types.zig");
const api = @import("trace_region_topology.zig");
const bytecode = @import("bytecode.zig");
const Proto = bytecode.Proto;
const AnchorKey = types.AnchorKey;
const ExitKey = types.ExitKey;
const StructuralEdgeId = types.StructuralEdgeId;
const ProgramPoint = types.ProgramPoint;
const RegionId = region.RegionId;
const RegionDef = region.RegionDef;
const RegionBridgeDef = region.RegionBridgeDef;
const RegionClassifier = region.RegionClassifier;
const RegionSetBuilder = region.RegionSetBuilder;
const freeRegionBridges = region.freeRegionBridges;
const cloneRegionBridges = region.cloneRegionBridges;
const programPointLess = region.programPointLess;
const programPointsEqual = region.programPointsEqual;
const appendUniqueSlot = region.appendUniqueSlot;
const freeRegionSetMap = region.freeRegionSetMap;
const StagedIntern = api.StagedIntern;
const StagedDef = api.StagedDef;
const StagedBridgeUpdate = api.StagedBridgeUpdate;
const StagedOwnerUpdate = api.StagedOwnerUpdate;
const StagedArmableUpdate = api.StagedArmableUpdate;
pub fn build(gpa: std.mem.Allocator, view: api.View, old: api.Previous, edge_cache: *const api.EdgeMap) !api.Rebuild {
    for (view.traces) |t| if (!t.code.exit_prov_complete) return error.IncompleteRegionGraph;
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
    for (view.traces) |t| try proto_by_id.put(gpa, t.code.anchor.proto.id, t.code.anchor.proto);

    // 1. Nodes + edges from the ephemeral structural-edge cache.
    var nodes: std.ArrayListUnmanaged(AnchorId) = .empty;
    defer nodes.deinit(gpa);
    var node_index: std.AutoHashMapUnmanaged(AnchorId, u32) = .empty;
    defer node_index.deinit(gpa);
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    defer edges.deinit(gpa);

    var ec_it = edge_cache.iterator();
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
        /// Doc 47 Increment B: the owner above was elected by the closed-SCC
        /// FALLBACK tier, not the primary external-entry/enclosing predicate.
        /// Threaded into `RegionDef.fallback_owner` (mint + rebind) so the
        /// window-strike policy can tombstone instead of gate+disarm.
        fallback_owner: bool,
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
            if (view.traceById(tid)) |t| {
                if (!t.code.rec_path_complete) membership_complete = false;
                for (t.code.rec_path) |pp| try mp_list.append(gpa, pp);
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
            const t = view.traceById(tid) orelse continue;
            const ni = node_index.get(.{ .proto_id = t.code.anchor.proto.id, .pc = t.code.anchor.pc }) orelse
                return error.RegionGraphInconsistent;
            for (t.code.entry_slots) |slot| _ = try appendUniqueSlot(&live_in[ni], gpa, slot);
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (edges.items) |e| {
                if (comp[e.from] != c or comp[e.to] != c) continue;
                const parent = view.traceById(e.key.trace_id) orelse continue;
                for (live_in[e.to].items) |slot| {
                    if (parent.code.bridgeEmitsSlot(e.key.exit_instr, slot)) continue;
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
            const parent = view.traceById(e.key.trace_id) orelse continue;
            if (!parent.code.isBridgeCandidate(e.key.exit_instr)) continue;

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
                    if (!parent.code.bridgeEmitsSlot(e.key.exit_instr, slot))
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
                if (!parent.code.bridgeEmitsSlot(e.key.exit_instr, slot))
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
            const has_root = view.hasInnerRootAt(proto, a.pc);
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
                const ext = bytecode.loopExtentFor(proto, a.pc) orelse break :blk false;
                // Doc 58 B1: numeric roots only, as before; B2 admits every
                // loop kind.
                if (ext.back_edge_op != .for_loop) break :blk false;
                for (0..nnodes) |m| {
                    if (comp[m] != c or m == n) continue;
                    const b = nodes.items[m];
                    if (b.proto_id != a.proto_id) break :blk false;
                    if (b.pc == a.pc or b.pc < ext.start or b.pc > ext.end) break :blk false;
                }
                break :blk true;
            };
            if ((is_ext or enclosing) and has_root) {
                both_count += 1;
                owner_node = @intCast(n);
            }
        }
        // 3e-b (doc 47 Increment B): fully-CLOSED SCC fallback. A cycle whose
        // every entry comes from the dispatcher (no incoming boundary edge at
        // all) has no member the primary predicate can elect: `is_ext` is
        // structurally false everywhere, and `enclosing` fails whenever a
        // continuation anchor lies OUTSIDE the loop root's body span (sparse:
        // post-inner cont pc34 vs inner root pc21 — the exact doc 47 shape).
        // Elect the unique loop-root DESTINATION of a continuation back-edge:
        // an internal `.link_terminal`-provenance edge from a non-root member
        // into a root. Identified by the edge's structural provenance, never
        // by anchor shape alone (review tightening: "source has no root" also
        // matches ordinary side anchors). v1 scope is deliberately same-proto
        // and top-level (`inline_depth == 0`, local source proto), matching
        // `enclosing`'s conservative posture — cross-proto cycles stay
        // unarmable. Zero or several qualifying roots keep today's
        // deterministic placeholder + armable=false ("multiple qualifying
        // roots stay unarmable"), and qualification counts destination NODES,
        // not edges, so several physical `.link` continuations targeting one
        // root still elect exactly that root. Runs strictly as a fallback
        // tier (`both_count == 0`), so every region that elects an owner
        // under the primary predicate is untouched by construction.
        const primary_count = both_count;
        if (both_count == 0) closed: {
            for (edges.items) |e| {
                if (comp[e.to] == c and comp[e.from] != c) break :closed; // open SCC: incoming boundary edge
            }
            var scc_proto_id: ?u32 = null;
            for (0..nnodes) |n| {
                if (comp[n] != c) continue;
                const pid = nodes.items[n].proto_id;
                if (scc_proto_id) |p| {
                    if (p != pid) break :closed; // cross-proto: out of v1 scope
                } else scc_proto_id = pid;
            }
            const pid = scc_proto_id orelse break :closed;
            const proto = proto_by_id.get(pid) orelse return error.RegionGraphInconsistent;
            for (0..nnodes) |n| {
                if (comp[n] != c) continue;
                if (!view.hasInnerRootAt(proto, nodes.items[n].pc)) continue;
                const qualifies = blk: {
                    for (edges.items) |e| {
                        if (e.to != @as(u32, @intCast(n)) or e.from == e.to) continue;
                        if (comp[e.from] != c) continue;
                        if (view.hasInnerRootAt(proto, nodes.items[e.from].pc)) continue;
                        switch (e.eid.exit) {
                            .link_terminal => |lt| {
                                if (lt.inline_depth != 0) continue;
                                if (lt.source_proto_id != pid) continue;
                                break :blk true;
                            },
                            .guard => continue,
                        }
                    }
                    break :blk false;
                };
                if (qualifies) {
                    both_count += 1;
                    owner_node = @intCast(n);
                }
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
            .fallback_owner = primary_count == 0 and both_count == 1,
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
    const ActiveRegion = struct { id: RegionId, comp: u32, armable: bool, dormant: bool, member_trace_ids: []u32 };
    var staged_interns: std.ArrayListUnmanaged(StagedIntern) = .empty;
    errdefer {
        for (staged_interns.items) |s| gpa.free(s.edges);
        staged_interns.deinit(gpa);
    }
    var staged_defs: std.ArrayListUnmanaged(StagedDef) = .empty;
    errdefer {
        for (staged_defs.items) |s| {
            gpa.free(s.def.members);
            gpa.free(s.def.member_points);
            freeRegionBridges(gpa, s.def.bridges);
        }
        staged_defs.deinit(gpa);
    }
    var staged_bridge_updates: std.ArrayListUnmanaged(StagedBridgeUpdate) = .empty;
    errdefer {
        for (staged_bridge_updates.items) |s| freeRegionBridges(gpa, s.bridges);
        staged_bridge_updates.deinit(gpa);
    }
    var staged_tombstones: std.ArrayListUnmanaged(RegionId) = .empty;
    errdefer staged_tombstones.deinit(gpa);
    var staged_owner_updates: std.ArrayListUnmanaged(StagedOwnerUpdate) = .empty;
    errdefer staged_owner_updates.deinit(gpa);
    // A-vii-d.0: rebind-recomputed armability, staged like the owner updates so
    // a fallible mid-pass failure publishes nothing.
    var staged_armable_updates: std.ArrayListUnmanaged(StagedArmableUpdate) = .empty;
    errdefer staged_armable_updates.deinit(gpa);
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

    var new_id_counter: u64 = old.next_id;
    for (candidates.items) |cand| {
        if (old.intern.lookup(cand.sorted_internal)) |existing_id| {
            // Rebind: confirm compatible membership or fail closed (§A3.5).
            const stored = old.defs.get(existing_id) orelse return error.RegionGraphInconsistent;
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
            // Doc 47 Increment B follow-up: dormancy is admission state, not
            // graph state — a rebind keeps the stored bit (an admitted region
            // stays admitted) UNLESS the election tier flipped, which resets
            // ALL fallback learning: dormancy re-arms (a re-fallback region
            // needs fresh admission evidence) and publish zeroes the counters.
            const tier_changed = stored.fallback_owner != cand.fallback_owner;
            const eff_dormant = cand.fallback_owner and (tier_changed or stored.dormant);
            staged_armable_updates.appendAssumeCapacity(.{
                .id = existing_id,
                .armable = eff_armable,
                .fallback_owner = cand.fallback_owner,
                .dormant = eff_dormant,
                .reset_learning = tier_changed,
            });
            // Keep the stored owner fresh: the unique external-entry loop-root can MOVE
            // to a different anchor with the internal edge set (hence the id) unchanged,
            // so the arm site must track the current owner, not the first-sight one.
            staged_owner_updates.appendAssumeCapacity(.{ .id = existing_id, .owner = cand.owner });
            const bridge_copy = try cloneRegionBridges(gpa, cand.bridges);
            staged_bridge_updates.appendAssumeCapacity(.{ .id = existing_id, .bridges = bridge_copy });
            const mt_copy = try gpa.dupe(u32, cand.member_trace_ids);
            active_regions.appendAssumeCapacity(.{ .id = existing_id, .comp = cand.comp, .armable = eff_armable, .dormant = eff_dormant, .member_trace_ids = mt_copy });
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
                .fallback_owner = cand.fallback_owner,
                // Demand-driven admission: fallback regions mint dormant and
                // stay out of the receipt maps until a full-cap yielded ledger
                // proves a promotable set (`tryDormantAdmission`).
                .dormant = cand.fallback_owner,
            } });
            active_regions.appendAssumeCapacity(.{ .id = new_id, .comp = cand.comp, .armable = first_armable, .dormant = cand.fallback_owner, .member_trace_ids = mt_copy });
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
        // Dormant fallback regions stay OUT of the receipt maps — the whole
        // point of demand admission is that `receiptsInert()` keeps
        // short-circuiting until a ledger proves the region can pay for the
        // per-receipt accounting this map entry would enable.
        if (!R.armable or R.dormant) continue;
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
    // component every member anchor is the destination of an internal edge). This is
    // the member proof — bridge child selection (`traceInRegion`) reads it.
    //
    // arrival_entry: dest_entry CLOSED over same-anchor sibling provenance links
    // (doc 55 §2), read only by the activation's destination step. A physical member
    // is a realizer of an internal edge (round-12 finding 3), but with same-anchor
    // siblings the trace an internal edge physically LANDS in need not be one: fft's
    // inner loop-done lands in the `:193` sibling that only hands off (t7) through
    // its armed provenance edge to the realizer of the back-edge (t8). Excluding t7
    // read every lap's landing as a departure, closed the activation with work=1,
    // and tombstoned the region in warm-up. A sibling joined to a member by a
    // provenance edge (side trace recorded off a member's exit, or a member recorded
    // off its exit) is part of the member's physical group at that anchor; a sibling
    // with no such link (A-ii.4's A′, which only leaves) stays excluded.
    //
    // Arrival only: the closure does NOT extend `member_points` (a linked sibling's
    // recorded path can run outside the cycle — t7 walks into the stage transition),
    // nor `source_exit_regions` (a linked sibling's rows credit through the
    // anchor-keyed unclassified-member path, exactly as before), nor `dest_entry`
    // (a linked sibling is not a bridge target: when one map served both jobs,
    // nsieve's bridge armed into the sibling that deopts on entry — 364 → 10k
    // trace entries, seam 8.7% → 45.8%).
    var arr_builder = RegionSetBuilder(u32){};
    defer arr_builder.deinit(gpa);
    var group: std.ArrayListUnmanaged(u32) = .empty;
    defer group.deinit(gpa);
    for (active_regions.items) |a| {
        if (!a.armable or a.dormant) continue;
        for (a.member_trace_ids) |tid| try dst_builder.add(gpa, tid, a.id);
        group.clearRetainingCapacity();
        try group.appendSlice(gpa, a.member_trace_ids);
        var grew = true;
        while (grew) {
            grew = false;
            for (view.sibling_links) |l| {
                const has_p = std.mem.indexOfScalar(u32, group.items, l.parent_id) != null;
                const has_c = std.mem.indexOfScalar(u32, group.items, l.child_id) != null;
                if (has_p == has_c) continue;
                const add = if (has_p) l.child_id else l.parent_id;
                const t = view.traceById(add) orelse continue;
                const ni = node_index.get(.{ .proto_id = t.code.anchor.proto.id, .pc = t.code.anchor.pc }) orelse continue;
                if (comp[ni] != a.comp) continue;
                try group.append(gpa, add);
                grew = true;
            }
        }
        for (group.items) |tid| try arr_builder.add(gpa, tid, a.id);
    }

    var new_source = try src_builder.finalize(gpa);
    errdefer freeRegionSetMap(ExitKey, &new_source, gpa);
    var new_dest = try dst_builder.finalize(gpa);
    errdefer freeRegionSetMap(u32, &new_dest, gpa);
    var new_arrival = try arr_builder.finalize(gpa);
    errdefer freeRegionSetMap(u32, &new_arrival, gpa);

    // A-vii-d.1 (review blocker 3): the live-armable region-id set for the
    // stale-bridge disarm sweep in the publish phase (fallible scratch).
    // `active_regions[i].armable` already reflects this pass's tombstones —
    // `eff_armable` conjoins `compatible ∧ membership_complete`, the exact
    // tombstone conditions — so this set equals post-publish armability.
    var live_armable_ids: std.ArrayListUnmanaged(RegionId) = .empty;
    errdefer live_armable_ids.deinit(gpa);
    try live_armable_ids.ensureUnusedCapacity(gpa, active_regions.items.len);
    for (active_regions.items) |a| {
        if (a.armable) live_armable_ids.appendAssumeCapacity(a.id);
    }

    return .{
        .staged_interns = staged_interns,
        .staged_defs = staged_defs,
        .staged_bridge_updates = staged_bridge_updates,
        .staged_tombstones = staged_tombstones,
        .staged_owner_updates = staged_owner_updates,
        .staged_armable_updates = staged_armable_updates,
        .live_armable_ids = live_armable_ids,
        .source = new_source,
        .dest = new_dest,
        .arrival = new_arrival,
        .next_id = new_id_counter,
    };
}
