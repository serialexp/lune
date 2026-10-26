//! Memory for coroutine stacks (doc 73 §5.1): one block per stack, a bounded
//! pool of blocks released by coroutines that died, and handing a pooled
//! block's pages back to the OS. The OS call lives here and nowhere else
//! (Rule Z-2).
//!
//! A block comes from the injected allocator (Rule Z-4). It is large enough
//! that every real backing allocator maps it, so its pages commit only when
//! touched; a stack never moves, which is what keeps open upvalue cells and
//! frame pointers into a suspended stack valid.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this target can hand pages back while keeping the range mapped.
/// A wasm32 linear memory never shrinks. Windows has no equivalent wired up
/// yet (TODO.md).
pub const can_decommit = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// Block alignment, and the alignment of each region inside a block: a page
/// where pages can be handed back (so a decommit covers whole pages of one
/// block), otherwise only what the regions' element types need, since a
/// wasm32 page pad would be committed memory.
pub const block_align: std.mem.Alignment = if (can_decommit) .fromByteUnits(std.heap.page_size_max) else .@"16";

pub const Block = []align(block_align.toByteUnits()) u8;

/// Hand `block`'s pages back to the OS. The range stays mapped and reads as
/// zero when next touched. Advice only: a refusal leaves the pages in
/// place, which nothing can observe.
pub fn decommit(block: Block) void {
    if (!can_decommit) return;
    std.posix.madvise(block.ptr, block.len, std.posix.MADV.DONTNEED) catch {};
}

/// Released blocks, kept for the next coroutine: a burst of short-lived
/// coroutines reuses a few blocks instead of mapping and unmapping one each.
/// At most `cap` are kept. Blocks released since the last `trim` keep the
/// pages their coroutine touched; `trim` (after each collection) hands
/// those back, so between collections the pool holds at most `cap` blocks'
/// touched pages and after one, none.
pub const Pool = struct {
    pub const cap = 16;

    blocks: [cap]Block = undefined,
    len: u8 = 0,
    /// `blocks[0..trimmed]` have had their pages handed back.
    trimmed: u8 = 0,

    /// A pooled block, the most recently released first, or null.
    pub fn take(self: *Pool) ?Block {
        if (self.len == 0) return null;
        self.len -= 1;
        self.trimmed = @min(self.trimmed, self.len);
        return self.blocks[self.len];
    }

    /// Keep `block` for reuse, or free it if the pool is full.
    pub fn put(self: *Pool, gpa: std.mem.Allocator, block: Block) void {
        if (self.len == cap) return gpa.free(block);
        self.blocks[self.len] = block;
        self.len += 1;
    }

    /// Hand back the pages of every block released since the last trim.
    pub fn trim(self: *Pool) void {
        for (self.blocks[self.trimmed..self.len]) |b| decommit(b);
        self.trimmed = self.len;
    }

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        for (self.blocks[0..self.len]) |b| gpa.free(b);
        self.* = .{};
    }
};

test "the pool reuses the latest block, frees past its cap, and trims only new blocks" {
    const gpa = std.testing.allocator;
    var pool: Pool = .{};
    defer pool.deinit(gpa);
    try std.testing.expect(pool.take() == null);
    const size = block_align.toByteUnits() * 2;
    for (0..Pool.cap + 2) |_| pool.put(gpa, try gpa.alignedAlloc(u8, block_align, size));
    try std.testing.expectEqual(@as(u8, Pool.cap), pool.len);
    pool.blocks[Pool.cap - 1][0] = 7;
    pool.trim();
    try std.testing.expectEqual(pool.len, pool.trimmed);
    const b = pool.take().?;
    // Linux zero-fills a page handed back; elsewhere it may keep its bytes.
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u8, 0), b[0]);
    try std.testing.expectEqual(@as(u8, Pool.cap - 1), pool.trimmed);
    pool.put(gpa, b);
    try std.testing.expectEqual(@as(u8, Pool.cap - 1), pool.trimmed);
}
