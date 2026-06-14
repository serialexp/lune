//! String objects.
//!
//! Strings are **immutable and interned** (the interning table lives in the heap,
//! `gc.zig`): two strings with the same bytes are the *same* object, so string
//! equality and table-key lookup are pointer comparisons. That is a direct gift
//! to the JIT (string guards become pointer guards) and to table performance.
//!
//! Storage is a **single inline allocation**: the byte payload follows the
//! `String` header in the same block, so a string is one object with one
//! lifetime — the layout the non-moving GC (Phase 4) wants, and cache-local.
//! Nothing stores an interior `data` pointer (which a moving GC would have to
//! fix up); the bytes are found by offset from `self`.

const std = @import("std");
const object = @import("object.zig");
const GcHeader = object.GcHeader;

/// An interned, immutable string. `extern` so `header` is guaranteed at offset 0
/// (the embedding convention), and the raw bytes live immediately after the
/// struct in the same allocation.
pub const String = extern struct {
    header: GcHeader,
    /// Content hash (Wyhash, seed 0 — matches the interning map's `StringContext`
    /// so a lookup-by-bytes and the stored hash agree). Cached for fast table-key
    /// hashing.
    hash: u64,
    /// Byte length of the inline payload.
    len: usize,
    // `len` raw bytes follow here, inline, in the same allocation.

    /// The string's bytes (a view into this same allocation; valid as long as the
    /// object is).
    pub fn bytes(self: *const String) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return base[@sizeOf(String) .. @sizeOf(String) + self.len];
    }

    /// Allocate a `String` owning a copy of `content`. This is the raw allocation
    /// only — it does **not** intern or GC-link the object; the heap does that
    /// (`gc.zig`). Callers should go through `Heap.intern`, not here.
    pub fn create(gpa: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!*String {
        const total = @sizeOf(String) + content.len;
        const raw = try gpa.alignedAlloc(u8, std.mem.Alignment.of(String), total);
        const self: *String = @ptrCast(raw.ptr);
        self.* = .{
            .header = GcHeader.init(.string),
            .hash = std.hash.Wyhash.hash(0, content),
            .len = content.len,
        };
        @memcpy(raw[@sizeOf(String) .. @sizeOf(String) + content.len], content);
        return self;
    }

    /// Recover the concrete string from its embedded header (the header is at
    /// offset 0, but `@fieldParentPtr` is layout-independent regardless).
    pub fn fromHeader(h: *GcHeader) *String {
        // `@alignCast` is a no-op on native (GcHeader is already 8-aligned there)
        // but required on wasm32, where a bare `*GcHeader` is 4-aligned while
        // `String` (an inline `u64` hash) demands 8. The object really is
        // 8-aligned at runtime — every `String` is allocated at `@alignOf(String)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    /// Free a `String` allocated by `create` (reconstructs the inline block).
    pub fn destroy(self: *String, gpa: std.mem.Allocator) void {
        const total = @sizeOf(String) + self.len;
        const raw: [*]align(@alignOf(String)) u8 = @ptrCast(self);
        gpa.free(raw[0..total]);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "String header is at offset 0 and bytes round-trip inline" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(String, "header"));

    const s = try String.create(testing.allocator, "hello");
    defer s.destroy(testing.allocator);

    try testing.expectEqual(object.ObjectType.string, s.header.type);
    try testing.expectEqual(@as(usize, 5), s.len);
    try testing.expectEqualStrings("hello", s.bytes());
    // hash matches the interning map's StringContext (Wyhash seed 0)
    try testing.expectEqual(std.hash.Wyhash.hash(0, "hello"), s.hash);
}

test "empty string is representable" {
    const s = try String.create(testing.allocator, "");
    defer s.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.len);
    try testing.expectEqualStrings("", s.bytes());
}
