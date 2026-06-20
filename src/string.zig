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
    /// Cached count of Unicode code points (S-B, design doc 06). A lune `string`
    /// is code-point-native (UTF-8 inside), so `#s`/`string.len` must report the
    /// number of characters, not bytes. Strings are immutable and interned, so we
    /// compute this once at construction (`create`) and cache it — `#s` stays
    /// O(1). For all-ASCII content `cp_len == len`. Not serialized: restore goes
    /// through `create`, which recomputes it (no keyframe/schema change).
    cp_len: usize,
    // `len` raw bytes follow here, inline, in the same allocation.

    /// The string's bytes (a view into this same allocation; valid as long as the
    /// object is).
    pub fn bytes(self: *const String) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return base[@sizeOf(String) .. @sizeOf(String) + self.len];
    }

    /// The number of Unicode code points (cached). O(1).
    pub fn cpLen(self: *const String) usize {
        return self.cp_len;
    }

    /// Count Unicode code points in valid UTF-8 `content`: every byte that is not
    /// a continuation byte (`0b10xxxxxx`) starts a new code point. Total and
    /// branch-light; for valid UTF-8 it equals `std.unicode.utf8CountCodepoints`
    /// without the error path. (Post-S-B every string is valid UTF-8 by
    /// construction; for stray non-UTF-8 bytes this is merely defined, not used.)
    fn countCodepoints(content: []const u8) usize {
        var n: usize = 0;
        for (content) |b| {
            if (b & 0xC0 != 0x80) n += 1;
        }
        return n;
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
            .cp_len = countCodepoints(content),
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
    try testing.expectEqual(@as(usize, 0), s.cpLen());
    try testing.expectEqualStrings("", s.bytes());
}

test "cp_len counts code points, not bytes (S-B)" {
    // ASCII: cp_len == len.
    const a = try String.create(testing.allocator, "hello");
    defer a.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 5), a.len);
    try testing.expectEqual(@as(usize, 5), a.cpLen());

    // "héllo": 'é' (U+00E9) is 2 UTF-8 bytes → 6 bytes, 5 code points.
    const b = try String.create(testing.allocator, "héllo");
    defer b.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 6), b.len);
    try testing.expectEqual(@as(usize, 5), b.cpLen());

    // "ab😀": '😀' (U+1F600) is 4 UTF-8 bytes → 6 bytes, 3 code points.
    const c = try String.create(testing.allocator, "ab😀");
    defer c.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 6), c.len);
    try testing.expectEqual(@as(usize, 3), c.cpLen());
}
