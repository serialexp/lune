//! Allocation and physical lifetime owner. No coordinator references or policy callbacks.
//! Constituents are composed by value and borrowed only for each operation: init is movable.
const std = @import("std");
const Trace = @import("trace_record.zig").TraceRecord;
const NativeSeedCtx = @import("trace_code.zig").NativeSeedCtx;
const nativegen = @import("nativegen.zig");
const EntryRegistry = @import("trace_entry_registry.zig").EntryRegistry;
const NativePhysicalRegistry = @import("trace_native_registry.zig").NativePhysicalRegistry;

pub const TraceRegistry = struct {
    gpa: std.mem.Allocator,
    cache: std.ArrayListUnmanaged(*Trace) = .empty,
    trace_by_id: std.ArrayListUnmanaged(?*Trace) = .empty,
    next_trace_id: u32 = 0,
    cache_gen: u32 = 1,
    entry_registry: EntryRegistry,
    native_physical: NativePhysicalRegistry,
    mcode_arena: nativegen.McodeArena,
    native_seed_ctx: ?*NativeSeedCtx = null,

    pub fn init(gpa: std.mem.Allocator) TraceRegistry {
        return .{ .gpa = gpa, .entry_registry = EntryRegistry.init(gpa), .native_physical = NativePhysicalRegistry.init(gpa), .mcode_arena = nativegen.McodeArena.init(gpa) };
    }
    fn changed(self: *TraceRegistry) void {
        self.cache_gen +%= 1;
        if (self.cache_gen == 0) self.cache_gen = 1;
    }
    /// Unpublished storage; caller prepares code, and owns its arrays until publish succeeds.
    pub fn allocate(self: *TraceRegistry) !*Trace {
        const t = try self.gpa.create(Trace);
        t.* = .{ .id = self.next_trace_id, .code = undefined };
        self.next_trace_id += 1;
        return t;
    }
    pub fn discardAllocation(self: *TraceRegistry, t: *Trace) void {
        self.gpa.destroy(t);
    }
    /// Ownership transfers only on success. Index allocation is an optional acceleration.
    pub fn publish(self: *TraceRegistry, t: *Trace) !void {
        try self.cache.append(self.gpa, t);
        self.changed();
        if (t.id >= self.trace_by_id.items.len) {
            const old_len = self.trace_by_id.items.len;
            self.trace_by_id.resize(self.gpa, @as(usize, t.id) + 1) catch return;
            @memset(self.trace_by_id.items[old_len..], null);
        }
        self.trace_by_id.items[t.id] = t;
    }
    pub fn traceById(self: *const TraceRegistry, id: u32) ?*Trace {
        if (id < self.trace_by_id.items.len) if (self.trace_by_id.items[id]) |t| return t;
        for (self.cache.items) |t| if (t.id == id) return t;
        return null;
    }
    /// Retirement is forbidden during replay: deferred disarm cannot protect freed pages.
    pub fn retire(self: *TraceRegistry, t: *Trace) bool {
        if (self.native_physical.replay_walk_depth != 0) @panic("trace retirement during replay");
        for (self.cache.items, 0..) |live, idx| {
            if (live != t) continue;
            self.native_physical.resetLinksTouching(&self.mcode_arena, t);
            // Disable dispatch before freeing the record; restore is deferred to the
            // safe-point drain so borrowed entry-patch pointers remain stable.
            if (t.entry_slot) |slot| self.entry_registry.markEntryPatchPending(slot);
            _ = self.cache.swapRemove(idx);
            if (t.id < self.trace_by_id.items.len) self.trace_by_id.items[t.id] = null;
            self.changed();
            t.destroy(self.gpa);
            return true;
        }
        return false;
    }
    /// Self-contained epoch safety; never relies on coordinator pre-disarm.
    pub fn clear(self: *TraceRegistry) void {
        if (self.native_physical.replay_walk_depth != 0) @panic("trace clear during replay");
        self.native_physical.demoteAllSets(&self.mcode_arena);
        self.native_physical.disarmAllLinks(&self.mcode_arena);
        self.native_physical.resetPromotionCandidate();
        _ = self.native_physical.drainBarrier(&self.mcode_arena);
        self.entry_registry.dropEntryPatchState();
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.clearRetainingCapacity();
        @memset(self.trace_by_id.items, null);
        self.changed();
    }
    pub fn createSeedContext(self: *TraceRegistry, value: NativeSeedCtx) !void {
        std.debug.assert(self.native_seed_ctx == null);
        const ctx = try self.gpa.create(NativeSeedCtx);
        ctx.* = value;
        self.native_seed_ctx = ctx;
    }
    pub fn deinit(self: *TraceRegistry) void {
        self.clear();
        self.native_physical.deinit(&self.mcode_arena);
        self.entry_registry.deinit();
        self.cache.deinit(self.gpa);
        self.trace_by_id.deinit(self.gpa);
        self.mcode_arena.deinit();
        if (self.native_seed_ctx) |ctx| self.gpa.destroy(ctx);
    }
};

fn emptyCandidate(registry: *TraceRegistry) !*Trace {
    const t = try registry.allocate();
    t.code = .{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    return t;
}

test "registry publication retirement and clear preserve monotonic identity" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    const first = try emptyCandidate(&registry);
    const first_id = first.id;
    try registry.publish(first);
    try testing.expectEqual(first, registry.traceById(first_id).?);
    const generation = registry.cache_gen;
    try testing.expect(registry.retire(first));
    try testing.expect(registry.traceById(first_id) == null);
    try testing.expect(registry.cache_gen != generation);
    const second = try emptyCandidate(&registry);
    const second_id = second.id;
    try testing.expect(second_id > first_id);
    try registry.publish(second);
    registry.clear();
    try testing.expect(registry.traceById(second_id) == null);
    const third = try emptyCandidate(&registry);
    defer registry.discardAllocation(third);
    try testing.expect(third.id > second_id);
}

test "registry failed publication keeps candidate ownership with caller" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    const t = try emptyCandidate(&registry);
    defer registry.discardAllocation(t);
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = registry.gpa;
    registry.gpa = failing.allocator();
    defer registry.gpa = allocator;
    const generation = registry.cache_gen;
    try testing.expectError(error.OutOfMemory, registry.publish(t));
    try testing.expectEqual(generation, registry.cache_gen);
    try testing.expect(registry.traceById(t.id) == null);
}

test "registry clear drops candidate references even without armed links" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    const t = try emptyCandidate(&registry);
    try registry.publish(t);
    const Edge = @import("trace_native_registry.zig").PromotedEdge;
    const edges = try testing.allocator.alloc(Edge, 1);
    edges[0] = .{ .parent = t, .child = t, .exit = 0, .kind = .deopt, .arm_kind = .ordinary_guard, .resume_pc = 0 };
    // Candidate storage is independent from live promotions and armed links.
    registry.native_physical.promotion_candidate = edges;
    registry.clear();
    try testing.expectEqual(@as(usize, 0), registry.native_physical.promotionCandidate().len);
}

test "registry optional index OOM preserves successful publication and swap order" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.cache.ensureTotalCapacity(testing.allocator, 3);
    const first = try emptyCandidate(&registry);
    const middle = try emptyCandidate(&registry);
    const last = try emptyCandidate(&registry);
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    registry.gpa = failing.allocator();
    // Cache has capacity; only the optional identity index needs allocation.
    registry.publish(first) catch unreachable;
    registry.publish(middle) catch unreachable;
    registry.publish(last) catch unreachable;
    registry.gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), registry.trace_by_id.items.len);
    try testing.expectEqual(first, registry.traceById(first.id).?);
    try testing.expect(registry.retire(middle));
    try testing.expectEqual(first, registry.cache.items[0]);
    try testing.expectEqual(last, registry.cache.items[1]);
    try testing.expectEqual(last, registry.traceById(last.id).?);
}
