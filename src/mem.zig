//! Memory accounting and allocation discipline.
//!
//! Allocation is the runtime's main enemy (cache footprint, GPU bandwidth), so
//! lune treats memory as something to *measure*, not guess at. The discipline:
//!
//!   1. **Inject allocators.** Every subsystem takes an `std.mem.Allocator`;
//!      nothing reaches for a global heap. (The lone deliberate exception is the
//!      diagnostic stdout path in `src/io.zig`, which is not VM data.)
//!   2. **Account at the boundary.** A `TrackingAllocator` wraps a backing
//!      allocator and records live/peak/total bytes and outstanding allocation
//!      count. Wrap the VM's backing allocator once and every subsystem fed from
//!      it is measured — for embedding (host wants to know a script's footprint),
//!      for the visualiser, and for leak assertions outside the test runner.
//!
//! This composes with, rather than replaces, `std.testing.allocator` (a
//! leak-checking `DebugAllocator`): tests still run on it, and a
//! `TrackingAllocator` can wrap it to add byte-level accounting. The wrapper is
//! cheap (a few integer updates per op) — fine to leave enabled in release if
//! the host wants live stats; drop it for zero overhead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Stats = struct {
    /// Bytes currently allocated and not yet freed.
    live_bytes: usize = 0,
    /// High-water mark of `live_bytes`.
    peak_bytes: usize = 0,
    /// Cumulative bytes ever handed out (including growth on resize/remap).
    total_bytes: usize = 0,
    /// Number of `alloc` calls that succeeded.
    alloc_count: usize = 0,
    /// Number of `free` calls.
    free_count: usize = 0,
    /// Outstanding allocations (`alloc` successes minus `free`s). Zero means no
    /// leaks.
    live_allocations: usize = 0,
};

/// An `Allocator` that forwards to a child allocator while accounting for every
/// byte. Must live at a stable address while its `allocator()` handle is in use
/// (the handle stores a pointer back to this struct).
pub const TrackingAllocator = struct {
    child: Allocator,
    stats: Stats = .{},

    pub fn init(child: Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn hasLeaks(self: *const TrackingAllocator) bool {
        return self.stats.live_allocations != 0;
    }

    pub fn leakedBytes(self: *const TrackingAllocator) usize {
        return self.stats.live_bytes;
    }

    /// Assert nothing is still allocated. Use in `deinit` paths that should have
    /// freed everything; fires in safe builds, compiles out in release-fast.
    pub fn assertNoLeaks(self: *const TrackingAllocator) void {
        std.debug.assert(self.stats.live_allocations == 0);
        std.debug.assert(self.stats.live_bytes == 0);
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn notePeak(self: *TrackingAllocator) void {
        if (self.stats.live_bytes > self.stats.peak_bytes)
            self.stats.peak_bytes = self.stats.live_bytes;
    }

    fn grow(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            const delta = new_len - old_len;
            self.stats.live_bytes += delta;
            self.stats.total_bytes += delta;
            self.notePeak();
        } else {
            self.stats.live_bytes -= old_len - new_len;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        if (result != null) {
            self.stats.live_bytes += len;
            self.stats.total_bytes += len;
            self.stats.alloc_count += 1;
            self.stats.live_allocations += 1;
            self.notePeak();
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (ok) self.grow(memory.len, new_len);
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (result != null) self.grow(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.stats.live_bytes -= memory.len;
        self.stats.free_count += 1;
        self.stats.live_allocations -= 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tracks a single alloc/free to net zero" {
    var ta = TrackingAllocator.init(testing.allocator);
    const a = ta.allocator();

    const buf = try a.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), ta.stats.live_bytes);
    try testing.expectEqual(@as(usize, 1), ta.stats.live_allocations);
    try testing.expectEqual(@as(usize, 1), ta.stats.alloc_count);
    try testing.expect(ta.hasLeaks());

    a.free(buf);
    try testing.expectEqual(@as(usize, 0), ta.stats.live_bytes);
    try testing.expectEqual(@as(usize, 0), ta.stats.live_allocations);
    try testing.expectEqual(@as(usize, 1), ta.stats.free_count);
    try testing.expect(!ta.hasLeaks());
    // Peak captured the high-water mark even though we are back to zero.
    try testing.expectEqual(@as(usize, 64), ta.stats.peak_bytes);
    ta.assertNoLeaks();
}

test "accounts through ArrayList growth (resize/remap/free) to net zero" {
    var ta = TrackingAllocator.init(testing.allocator);
    const a = ta.allocator();

    var list: std.ArrayList(u32) = .empty;
    for (0..1000) |i| try list.append(a, @intCast(i));
    try testing.expect(ta.stats.live_bytes >= 1000 * @sizeOf(u32));
    try testing.expect(ta.stats.peak_bytes >= ta.stats.live_bytes);

    list.deinit(a);
    // Everything handed back; the child (testing.allocator) would also flag a
    // leak if our accounting let one slip.
    try testing.expectEqual(@as(usize, 0), ta.stats.live_bytes);
    try testing.expect(!ta.hasLeaks());
    ta.assertNoLeaks();
}

test "total_bytes is cumulative, peak is the high-water mark" {
    var ta = TrackingAllocator.init(testing.allocator);
    const a = ta.allocator();

    const b1 = try a.alloc(u8, 100);
    a.free(b1);
    const b2 = try a.alloc(u8, 30);
    a.free(b2);

    try testing.expectEqual(@as(usize, 130), ta.stats.total_bytes); // 100 + 30
    try testing.expectEqual(@as(usize, 100), ta.stats.peak_bytes); // never 130 at once
    try testing.expectEqual(@as(usize, 0), ta.stats.live_bytes);
}

test "leak is observable (and cleaned up so the child stays happy)" {
    var ta = TrackingAllocator.init(testing.allocator);
    const a = ta.allocator();

    const leaked = try a.alloc(u8, 16);
    try testing.expect(ta.hasLeaks());
    try testing.expectEqual(@as(usize, 16), ta.leakedBytes());

    a.free(leaked); // don't actually leak under testing.allocator
    try testing.expect(!ta.hasLeaks());
}
