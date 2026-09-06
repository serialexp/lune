const std = @import("std");
const topology = @import("trace_region_topology.zig");
const region = @import("trace_region.zig");

test "empty immutable graph stages without changing logical identity" {
    var intern: region.RegionInternMap = .empty;
    defer intern.deinit(std.testing.allocator);
    var defs: topology.DefMap = .empty;
    defer defs.deinit(std.testing.allocator);
    const view: topology.View = .{ .traces = &.{} };
    var edges = try topology.buildEdges(std.testing.allocator, view);
    defer edges.deinit(std.testing.allocator);
    var result = try topology.build(std.testing.allocator, view, .{ .intern = &intern, .defs = &defs, .next_id = 42 }, &edges);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), result.next_id);
    try std.testing.expectEqual(@as(u32, 0), result.source.count());
    try std.testing.expectEqual(@as(usize, 0), result.staged_defs.items.len);
}
