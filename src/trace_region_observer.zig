//! Logical observer predicates; the coordinator applies each bounded close synchronously.
const RegionPolicy = @import("trace_region_policy.zig").RegionPolicy;
const MemberAccum = @import("trace_region_policy.zig").MemberAccum;
const region = @import("trace_region.zig");
const RegionId = region.RegionId;
const RegionKey = region.RegionKey;
const ProgramPoint = @import("trace_types.zig").ProgramPoint;
const RegionContext = region.RegionContext;

pub fn regionMemberPoint(self: *const RegionPolicy, rid: RegionId, point: ProgramPoint) bool {
    const def = self.region_defs.get(rid) orelse return false;
    if (!def.armable) return false;
    for (def.member_points) |p| {
        if (p.proto_id == point.proto_id and p.source_pc == point.source_pc) return true;
    }
    return false;
}

pub fn qualifiedActiveMember(self: *RegionPolicy, point: ProgramPoint) ?MemberAccum {
    const ctx = self.regionContext() orelse return null;
    self.refreshActCache(ctx.call_seq);
    const m = self.act_cache orelse return null;
    if (!self.regionMemberPoint(m.key.region_id, point)) return null;
    return m;
}

pub fn refreshActCache(self: *RegionPolicy, call_seq: u64) void {
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

pub inline fn observeFast(self: *RegionPolicy, point: ProgramPoint, ctx: RegionContext) bool {
    const proto_id = point.proto_id;
    const pc = point.source_pc;
    const depth = ctx.depth;
    const call_seq = ctx.call_seq;
    const h = &self.observer_hot;
    const words = h.words orelse return false;
    if (h.proto_id != proto_id or h.depth != depth or h.call_seq != call_seq) return false;
    const off = pc -% h.base_pc;
    if (off >= h.span_pcs) return false;
    if ((words[off >> 6] >> @intCast(off & 63)) & 1 == 0) return false;
    self.setContext(depth, call_seq);
    return true;
}

pub fn nextDeparture(self: *RegionPolicy, point: ProgramPoint, ctx: RegionContext) ?RegionKey {
    const proto_id = point.proto_id;
    const pc = point.source_pc;
    const depth = ctx.depth;
    const call_seq = ctx.call_seq;
    self.setContext(depth, call_seq);
    if (self.region_profit.count() == 0) return null;
    // A-vii-e.1 fast path: the per-instruction survive verdict for the
    // single-accumulator common case, without touching the hashmap. Exactly
    // the slow loop's predicate below, accelerated:
    //   depth > root                          → survives
    //   depth == root and call_seq != seq     → close
    //   otherwise                             → close iff point ∉ members
    if (self.observer_fast) |f| {
        if (depth > f.root_frame_depth) return null;
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
                        return null;
                    }
                }
            }
        }
        return f.key;
    }
    {
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
        return victim;
    }
}
