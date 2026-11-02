//! Memory accounting and allocation discipline.
//!
//! Allocation is the runtime's main enemy (cache footprint, GPU bandwidth), so
//! mahina treats memory as something to *measure*, not guess at. The discipline:
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
//!
//! `LargeBlockCache` keeps freed large blocks for reuse. Zig's `smp_allocator`
//! (the static CLI's process allocator) maps and unmaps every block past its
//! largest slab class (32 KiB), so a program that keeps building big strings or arrays pays
//! a system call and fresh page faults per allocation; `s = s .. "x"` to 80k
//! spent 1.25 s of its 1.6 s in the kernel. The CLI installs the cache over
//! its process allocator; an embedder whose allocator already reuses memory
//! (any libc malloc) has no need of it.

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

/// An `Allocator` that keeps freed blocks of `min_len` bytes and more, up to
/// `max_len`, and hands them out again. A cached request is rounded up to a
/// size class (eight per doubling, so at most 12.5% is unused) and served
/// from that class's kept blocks when it can be, else from the child. The
/// kept bytes are capped at the larger of `retain_floor` and the program's
/// peak large-block footprint (the GC's `heap_growth` of 2 lets garbage reach
/// the live size between cycles, so that much is what a collection hands
/// back); past the cap the least recently freed blocks go back to the child.
/// A block past `max_len` is taken from the child at the requested length and
/// never kept, but resizes still go to the child, so a huge array is not
/// copied as it grows.
/// Evicting by age, not by class, matters for growing data: a string or
/// array that keeps getting longer leaves its old classes behind, and their
/// blocks must not crowd out the ones the next allocations will ask for.
/// Smaller requests, and alignments past `block_align`, go straight to the
/// child.
///
/// Not thread-safe: give it to one thread's allocations (the CLI's VM `gpa`;
/// the I/O threads keep the process allocator). Must live at a stable address
/// while its `allocator()` handle is in use. `deinit` returns every kept block
/// to the child; blocks still handed out are the caller's to free first.
///
/// `static_vtable`, when given, is the child's vtable, and `init` checks it.
/// Every allocation passes through the cache, so a child called through a
/// run-time vtable costs an indirect call more per allocation and free
/// (+2% instructions on binary-trees); a comptime-known one is inlined.
pub fn LargeBlockCacheOver(comptime static_vtable: ?*const Allocator.VTable) type {
    return struct {
        const Self = @This();

        child: Allocator,
        retain_floor: usize,
        /// Bytes in kept blocks, by class size.
        retained_bytes: usize = 0,
        /// Bytes in cached-class blocks currently handed out, by class size.
        in_use_bytes: usize = 0,
        /// The most `in_use_bytes` has been.
        peak_in_use: usize = 0,
        /// Each class's kept blocks, most recently freed first.
        heads: [class_count]?*FreeBlock = @splat(null),
        /// Every kept block, most recently freed first; `oldest` is the next to go.
        newest: ?*FreeBlock = null,
        oldest: ?*FreeBlock = null,

        /// `smp_allocator`'s largest slab class is 32 KiB; it maps anything past.
        pub const min_len: usize = 32 * 1024;
        pub const max_len: usize = 64 * 1024 * 1024;
        /// The retain floor the CLI uses.
        pub const default_retain_floor: usize = 64 * 1024 * 1024;
        const block_align: Alignment = .@"64";
        const steps_log2 = 3; // eight classes per doubling
        const min_log2: usize = std.math.log2_int(usize, min_len);
        const max_log2: usize = std.math.log2_int(usize, max_len);
        const class_count = (max_log2 - min_log2) * (1 << steps_log2) + 1;

        /// Written into a kept block's first bytes.
        const FreeBlock = struct {
            class: usize,
            class_prev: ?*FreeBlock,
            class_next: ?*FreeBlock,
            age_prev: ?*FreeBlock, // newer
            age_next: ?*FreeBlock, // older
        };

        pub fn init(child: Allocator, retain_floor: usize) Self {
            if (static_vtable) |vt| std.debug.assert(child.vtable == vt);
            return .{ .child = child, .retain_floor = retain_floor };
        }

        // The child's four calls. With a comptime-known vtable each is the
        // child's own function inlined here, so a pass-through allocation
        // costs the range check and nothing more.
        inline fn childAlloc(self: *const Self, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
            if (static_vtable) |vt| return @call(.always_inline, vt.alloc, .{ self.child.ptr, len, alignment, ra });
            return self.child.rawAlloc(len, alignment, ra);
        }
        inline fn childResize(self: *const Self, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
            if (static_vtable) |vt| return @call(.always_inline, vt.resize, .{ self.child.ptr, memory, alignment, new_len, ra });
            return self.child.rawResize(memory, alignment, new_len, ra);
        }
        inline fn childRemap(self: *const Self, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
            if (static_vtable) |vt| return @call(.always_inline, vt.remap, .{ self.child.ptr, memory, alignment, new_len, ra });
            return self.child.rawRemap(memory, alignment, new_len, ra);
        }
        inline fn childFree(self: *const Self, memory: []u8, alignment: Alignment, ra: usize) void {
            if (static_vtable) |vt| return @call(.always_inline, vt.free, .{ self.child.ptr, memory, alignment, ra });
            self.child.rawFree(memory, alignment, ra);
        }

        pub fn allocator(self: *Self) Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn deinit(self: *Self) void {
            while (self.oldest) |blk| self.evict(blk);
            std.debug.assert(self.retained_bytes == 0);
        }

        /// Whether a block of `len` bytes at `alignment` is ours: taken from
        /// the child at `block_align` and `blockSize(len)`. Only those up to
        /// `max_len` are kept when freed; a bigger one is ours so that an
        /// array growing past `max_len` is still resized by the child, not
        /// copied, and so the length alone says how a block is freed.
        fn ours(len: usize, alignment: Alignment) bool {
            return len >= min_len and alignment.compare(.lte, block_align);
        }

        /// What the child is asked for: a class's size up to `max_len`, the
        /// length itself past it.
        fn blockSize(len: usize) usize {
            return if (len <= max_len) classSize(classOf(len)) else len;
        }

        /// The class of a cached length: its size rounded up to the next of
        /// eight steps per doubling.
        fn classOf(len: usize) usize {
            const p = std.math.log2_int(usize, len);
            const step_log2: std.math.Log2Int(usize) = @intCast(p - steps_log2);
            const size = std.mem.alignForward(usize, len, @as(usize, 1) << step_log2);
            const q = std.math.log2_int(usize, size);
            const sub = (size >> @intCast(q - steps_log2)) - (1 << steps_log2);
            return (q - min_log2) * (1 << steps_log2) + sub;
        }

        fn classSize(class: usize) usize {
            const q: std.math.Log2Int(usize) = @intCast(min_log2 + class / (1 << steps_log2));
            const sub = class % (1 << steps_log2);
            return (@as(usize, 1) << q) + sub * (@as(usize, 1) << (q - steps_log2));
        }

        fn retainLimit(self: *const Self) usize {
            return @max(self.retain_floor, self.peak_in_use);
        }

        /// Keep `blk` as the newest block of `class`.
        fn keep(self: *Self, blk: *FreeBlock, class: usize) void {
            blk.* = .{
                .class = class,
                .class_prev = null,
                .class_next = self.heads[class],
                .age_prev = null,
                .age_next = self.newest,
            };
            if (self.heads[class]) |h| h.class_prev = blk;
            self.heads[class] = blk;
            if (self.newest) |n| n.age_prev = blk else self.oldest = blk;
            self.newest = blk;
            self.retained_bytes += classSize(class);
        }

        /// Take `blk` off both lists.
        fn unkeep(self: *Self, blk: *FreeBlock) void {
            if (blk.class_prev) |p| p.class_next = blk.class_next else self.heads[blk.class] = blk.class_next;
            if (blk.class_next) |n| n.class_prev = blk.class_prev;
            if (blk.age_prev) |p| p.age_next = blk.age_next else self.newest = blk.age_next;
            if (blk.age_next) |n| n.age_prev = blk.age_prev else self.oldest = blk.age_prev;
            self.retained_bytes -= classSize(blk.class);
        }

        fn evict(self: *Self, blk: *FreeBlock) void {
            const size = classSize(blk.class);
            self.unkeep(blk);
            const raw: [*]u8 = @ptrCast(blk);
            self.childFree(raw[0..size], block_align, @returnAddress());
        }

        /// A block handed out went from `old_size` to `new_size` (0: none).
        /// Only keepable sizes count toward the footprint the cap follows.
        fn account(self: *Self, old_size: usize, new_size: usize) void {
            if (old_size <= max_len) self.in_use_bytes -= old_size;
            if (new_size <= max_len) {
                self.in_use_bytes += new_size;
                self.peak_in_use = @max(self.peak_in_use, self.in_use_bytes);
            }
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        // `alloc` and `free` keep the pass-through path to one length test
        // and the child's own code; the rest is out of line, so its register
        // saves are not paid by every small allocation.

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (len < min_len) return self.childAlloc(len, alignment, ret_addr);
            return self.allocLarge(len, alignment, ret_addr);
        }

        noinline fn allocLarge(self: *Self, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            if (!ours(len, alignment)) return self.childAlloc(len, alignment, ret_addr);
            const size = blockSize(len);
            if (len <= max_len) {
                const class = classOf(len);
                if (self.heads[class]) |blk| {
                    self.unkeep(blk);
                    self.account(0, size);
                    return @ptrCast(blk);
                }
            }
            const raw = self.childAlloc(size, block_align, ret_addr) orelse return null;
            self.account(0, size);
            return raw;
        }

        /// Within one class a block already has the room. Otherwise the child
        /// resizes it at block sizes (the CLI's child grows a mapping in place
        /// when it can), so a growing array is not copied at every class
        /// step. A block never moves between ours and the child's: the length
        /// it is freed with must say which it is.
        fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const old_ours = ours(memory.len, alignment);
            if (old_ours != ours(new_len, alignment)) return false;
            if (!old_ours) return self.childResize(memory, alignment, new_len, ret_addr);
            const old_size = blockSize(memory.len);
            const new_size = blockSize(new_len);
            if (old_size == new_size) return true;
            if (!self.childResize(memory.ptr[0..old_size], block_align, new_size, ret_addr)) return false;
            self.account(old_size, new_size);
            return true;
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const old_ours = ours(memory.len, alignment);
            if (old_ours != ours(new_len, alignment)) return null;
            if (!old_ours) return self.childRemap(memory, alignment, new_len, ret_addr);
            const old_size = blockSize(memory.len);
            const new_size = blockSize(new_len);
            if (old_size == new_size) return memory.ptr;
            const moved = self.childRemap(memory.ptr[0..old_size], block_align, new_size, ret_addr) orelse return null;
            self.account(old_size, new_size);
            return moved;
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (memory.len < min_len) return self.childFree(memory, alignment, ret_addr);
            self.freeLarge(memory, alignment, ret_addr);
        }

        noinline fn freeLarge(self: *Self, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            if (!ours(memory.len, alignment)) return self.childFree(memory, alignment, ret_addr);
            const size = blockSize(memory.len);
            self.account(size, 0);
            if (memory.len > max_len) return self.childFree(memory.ptr[0..size], block_align, ret_addr);
            // The block always fits: the limit is at least the peak, which counted it.
            self.keep(@ptrCast(@alignCast(memory.ptr)), classOf(memory.len));
            while (self.retained_bytes > self.retainLimit()) self.evict(self.oldest.?);
        }
    };
}

/// A cache over a child known only at run time.
pub const LargeBlockCache = LargeBlockCacheOver(null);

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
test "LargeBlockCache: classes are eight per doubling and cover every cached length" {
    const C = LargeBlockCache;
    try testing.expectEqual(@as(usize, 0), C.classOf(C.min_len));
    try testing.expectEqual(C.min_len, C.classSize(0));
    try testing.expectEqual(@as(usize, 1), C.classOf(C.min_len + 1));
    try testing.expectEqual(C.min_len + C.min_len / 8, C.classSize(1));
    try testing.expectEqual(@as(usize, 8), C.classOf(2 * C.min_len));
    try testing.expectEqual(@as(usize, 7), C.classOf(2 * C.min_len - C.min_len / 8));
    try testing.expectEqual(@as(usize, 8), C.classOf(2 * C.min_len - C.min_len / 8 + 1));
    try testing.expectEqual(C.class_count - 1, C.classOf(C.max_len));
    try testing.expectEqual(C.max_len, C.classSize(C.class_count - 1));
    // Every class's size maps back to it, and the length just past it moves on.
    for (0..C.class_count - 1) |class| {
        const size = C.classSize(class);
        try testing.expectEqual(class, C.classOf(size));
        try testing.expectEqual(class + 1, C.classOf(size + 1));
        // At most 12.5% of a block is unused.
        try testing.expect((size - C.classSize(class -| 1)) * 8 <= size or class == 0);
    }
}

test "LargeBlockCache: a freed large block is handed out again, small ones pass through" {
    var counter = TrackingAllocator.init(testing.allocator);
    var cache = LargeBlockCache.init(counter.allocator(), LargeBlockCache.default_retain_floor);
    defer cache.deinit();
    const a = cache.allocator();

    const b1 = try a.alloc(u8, 100_000);
    const p1 = b1.ptr;
    a.free(b1);
    // The same class (100_000 and 100_500 both round to 106_496): the same block.
    const b2 = try a.alloc(u8, 100_500);
    try testing.expectEqual(p1, b2.ptr);
    a.free(b2);
    try testing.expectEqual(@as(usize, 1), counter.stats.alloc_count);
    try testing.expectEqual(@as(usize, 0), counter.stats.free_count);

    const small = try a.alloc(u8, 1000);
    a.free(small);
    try testing.expectEqual(@as(usize, 2), counter.stats.alloc_count);
    try testing.expectEqual(@as(usize, 1), counter.stats.free_count);

    // Past max_len: taken and given back, never kept. Past block_align:
    // the child's.
    const huge = try a.alloc(u8, LargeBlockCache.max_len + 1);
    a.free(huge);
    const page_aligned = try a.alignedAlloc(u8, .fromByteUnits(4096), 100_000);
    a.free(page_aligned);
    try testing.expectEqual(@as(usize, 4), counter.stats.alloc_count);
    try testing.expectEqual(@as(usize, 3), counter.stats.free_count);
    try testing.expectEqual(@as(usize, 0), cache.in_use_bytes);
    try testing.expectEqual(@as(usize, 106_496), cache.retained_bytes);
}

test "LargeBlockCache: a growing string's allocations reuse one block per class" {
    // The `s = s .. "x"` shape: each step allocates one byte more and frees
    // the previous string. The child sees one allocation per class touched.
    var counter = TrackingAllocator.init(testing.allocator);
    var cache = LargeBlockCache.init(counter.allocator(), LargeBlockCache.default_retain_floor);
    defer cache.deinit();
    const a = cache.allocator();

    var prev = try a.alloc(u8, LargeBlockCache.min_len);
    var len = LargeBlockCache.min_len + 1;
    while (len <= 4 * LargeBlockCache.min_len) : (len += 97) {
        const next = try a.alloc(u8, len);
        a.free(prev);
        prev = next;
    }
    a.free(prev);
    // Classes 0..16 cover min_len..4*min_len; each needs at most two blocks
    // (the live string and the next one can share a class).
    try testing.expect(counter.stats.alloc_count <= 2 * 17);
    try testing.expectEqual(@as(usize, 0), cache.in_use_bytes);
}

test "LargeBlockCache: past the cap the least recently freed blocks go, whatever their class" {
    var counter = TrackingAllocator.init(testing.allocator);
    const floor = 4 * LargeBlockCache.min_len;
    var cache = LargeBlockCache.init(counter.allocator(), floor);
    defer cache.deinit();
    const a = cache.allocator();

    // Peak in use: 8 blocks of min_len, so the cap is 8 blocks.
    var blocks: [8][]u8 = undefined;
    for (&blocks) |*b| b.* = try a.alloc(u8, LargeBlockCache.min_len);
    for (blocks) |b| a.free(b);
    try testing.expectEqual(8 * LargeBlockCache.min_len, cache.retained_bytes);
    try testing.expectEqual(@as(usize, 0), counter.stats.free_count);

    // Two blocks of the next doubling (twice the size) push out the four
    // oldest small ones, not themselves.
    const big1 = try a.alloc(u8, 2 * LargeBlockCache.min_len);
    const big2 = try a.alloc(u8, 2 * LargeBlockCache.min_len);
    a.free(big1);
    a.free(big2);
    try testing.expectEqual(8 * LargeBlockCache.min_len, cache.retained_bytes);
    try testing.expectEqual(@as(usize, 4), counter.stats.free_count);
    // The kept small blocks are the four freed last; a big request is served
    // from the cache without the child.
    try testing.expectEqual(blocks[7].ptr, (try a.alloc(u8, LargeBlockCache.min_len)).ptr);
    a.free(blocks[7]);
    const again = try a.alloc(u8, 2 * LargeBlockCache.min_len);
    try testing.expectEqual(big2.ptr, again.ptr);
    a.free(again);
    try testing.expectEqual(@as(usize, 10), counter.stats.alloc_count);
}

test "LargeBlockCache: resize stays in a class, ArrayList growth across the threshold balances" {
    var cache = LargeBlockCache.init(testing.allocator, LargeBlockCache.default_retain_floor);
    defer cache.deinit();
    const a = cache.allocator();

    const b = try a.alloc(u8, 100_000);
    try testing.expect(a.resize(b, 106_496)); // same class
    try testing.expect(!a.resize(b, 1000)); // into the child's range
    a.free(b);
    // Between classes the child resizes the block: over the page allocator
    // (which Linux grows with mremap) a remap to a later class succeeds
    // without a new allocation, and the accounting follows the block.
    var counter = TrackingAllocator.init(std.heap.page_allocator);
    var cache2 = LargeBlockCache.init(counter.allocator(), LargeBlockCache.default_retain_floor);
    const a2 = cache2.allocator();
    var c = try a2.alloc(u8, 100_000);
    c[99_999] = 7;
    if (a2.remap(c, 300_000)) |grown| {
        c = grown;
        try testing.expectEqual(@as(u8, 7), c[99_999]);
        try testing.expectEqual(@as(usize, 327_680), cache2.in_use_bytes);
    } else {
        try testing.expect(@import("builtin").os.tag != .linux);
    }
    a2.free(c);
    try testing.expectEqual(@as(usize, 0), cache2.in_use_bytes);
    try testing.expectEqual(@as(usize, 1), counter.stats.alloc_count);
    cache2.deinit();
    try testing.expectEqual(@as(usize, 0), counter.stats.live_bytes);

    // Growing through the threshold and past max_len, and back.
    var list: std.ArrayList(u32) = .empty;
    for (0..20_000_000) |i| try list.append(a, @intCast(i));
    list.shrinkAndFree(a, 100);
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    list.clearAndFree(a);
    for (0..200_000) |i| try list.append(a, @intCast(i));
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    list.deinit(a);
    try testing.expectEqual(@as(usize, 0), cache.in_use_bytes);
}
