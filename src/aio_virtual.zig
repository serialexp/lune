//! A virtual-clock `aio` host (doc 73 §7.6) for a host with no threads: the
//! wasm playground. Time is a counter that jumps to each deadline, so a
//! sleep finishes at once, after every sleep due before it (ties in start
//! order): the order the CLI's real timers finish in, without the wait.
//! It runs no file operations (the playground has no `files` group, so
//! they aren't installed); one that arrives fails as `other`.
//!
//! Dependency-free, like `system.zig`: it compiles on every target.

const std = @import("std");
const seam = @import("system.zig");

const AsyncHost = seam.AsyncHost;

pub const VirtualAio = struct {
    gpa: std.mem.Allocator,
    /// Virtual nanoseconds: the deadline of the last sleep that finished.
    now: u64 = 0,
    /// Breaks deadline ties in start order.
    seq: u64 = 0,
    timers: Timers = .empty,
    /// File operations, failed in start order before any sleep finishes.
    refused: std.ArrayList(AsyncHost.OpId) = .empty,

    const Timer = struct { deadline: u64, seq: u64, id: AsyncHost.OpId };
    const Timers = std.PriorityQueue(Timer, void, struct {
        fn order(_: void, a: Timer, b: Timer) std.math.Order {
            return switch (std.math.order(a.deadline, b.deadline)) {
                .eq => std.math.order(a.seq, b.seq),
                else => |o| o,
            };
        }
    }.order);

    pub fn init(gpa: std.mem.Allocator) VirtualAio {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *VirtualAio) void {
        self.timers.deinit(self.gpa);
        self.refused.deinit(self.gpa);
    }

    pub fn host(self: *VirtualAio) AsyncHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: AsyncHost.VTable = .{ .start = &start, .next = &next };

    fn of(ctx: *anyopaque) *VirtualAio {
        return @ptrCast(@alignCast(ctx));
    }

    fn start(ctx: *anyopaque, id: AsyncHost.OpId, request: AsyncHost.Request) bool {
        const self = of(ctx);
        switch (request) {
            .sleep => |ns| {
                self.timers.push(self.gpa, .{ .deadline = self.now +| ns, .seq = self.seq, .id = id }) catch return false;
                self.seq += 1;
            },
            .read, .write => self.refused.append(self.gpa, id) catch return false,
        }
        return true;
    }

    fn next(ctx: *anyopaque) AsyncHost.Completion {
        const self = of(ctx);
        if (self.refused.items.len > 0) return .{ .id = self.refused.orderedRemove(0), .outcome = .{ .fail = .other } };
        const t = self.timers.pop() orelse unreachable; // the VM waits only with operations in flight
        self.now = t.deadline;
        return .{ .id = t.id, .outcome = .done };
    }
};

const testing = std.testing;

test "virtual aio: sleeps finish in deadline order, measured from when each started" {
    var v = VirtualAio.init(testing.allocator);
    defer v.deinit();
    const h = v.host();
    try testing.expect(h.vtable.start(h.ctx, 1, .{ .sleep = 30 }));
    try testing.expect(h.vtable.start(h.ctx, 2, .{ .sleep = 10 }));
    try testing.expect(h.vtable.start(h.ctx, 3, .{ .sleep = 10 }));
    try testing.expectEqual(@as(AsyncHost.OpId, 2), h.vtable.next(h.ctx).id);
    // Started at virtual 10: due at 15, before 1 (30).
    try testing.expect(h.vtable.start(h.ctx, 4, .{ .sleep = 5 }));
    try testing.expect(h.vtable.start(h.ctx, 5, .{ .read = "x" }));
    const r = h.vtable.next(h.ctx);
    try testing.expectEqual(@as(AsyncHost.OpId, 5), r.id);
    try testing.expectEqual(seam.ErrorClass.other, r.outcome.fail);
    for ([_]AsyncHost.OpId{ 3, 4, 1 }) |want| try testing.expectEqual(want, h.vtable.next(h.ctx).id);
    try testing.expectEqual(@as(u64, 30), v.now);
}
