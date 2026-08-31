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
    /// so a lookup-by-bytes and the stored hash agree). Consumed ONLY by the
    /// intern table (`Heap.strtab*`) — table keys hash heap values by stable
    /// `GcHeader.id` (`table.ValueContext`), NOT by this field, and observable
    /// iteration order is canonically sorted (doc 02), so this hash function is
    /// free to change without touching any observable behaviour. Not serialized:
    /// restore recomputes it through `create`.
    hash: u64,
    /// Byte length of the inline payload.
    len: usize,
    /// Cached count of Unicode code points (S-B, design doc 06). A mahina `string`
    /// is code-point-native (UTF-8 inside), so `#s`/`string.len` must report the
    /// number of characters, not bytes. Strings are immutable and interned, so we
    /// compute this once at construction (`create`) and cache it — `#s` stays
    /// O(1). For all-ASCII content `cp_len == len`. Not serialized: restore goes
    /// through `create`, which recomputes it (no keyframe/schema change).
    cp_len: usize,
    /// Intern-chain link: the next string in this string's `Heap.strtab` bucket
    /// (lj_str.c shape — the interning table is a power-of-2 array of chain heads
    /// threaded through the strings themselves, so interning allocates nothing
    /// beyond the string). Owned entirely by `gc.zig`: set on intern, rebuilt
    /// from scratch on every sweep, meaningless in between collections only to
    /// the extent gc.zig says so.
    ///
    /// This is a WEAK edge, not a GC child: `blacken`/snapshot traversal must
    /// never follow it (a string has no children), and table membership must
    /// never keep a string alive — the sweep rebuild drops dead strings from the
    /// chains by construction. Not serialized (runtime-private index state).
    next_intern: ?*String,
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

    /// EXACT pure-ASCII proof (cached `GcFlags.str_ascii`, one fused scan at
    /// construction): every payload byte is < 0x80, so char index == byte index
    /// at every seam. Deliberately NOT `cp_len == len` — that equivalence needs
    /// valid UTF-8, and the effect log parks raw non-UTF-8 host bytes as
    /// interned strings by design (validate-after-log). Doc 28 §2. O(1).
    pub fn isAscii(self: *const String) bool {
        return self.header.flags.str_ascii;
    }

    /// Producer-known character facts about a string's bytes (doc 28 §6): what
    /// a construction site can prove WITHOUT scanning — e.g. a substring's
    /// character count is `j - i + 1` by definition, a repetition/permutation
    /// preserves the source's ASCII bit. Either field may be null (unknown →
    /// derived by the fused scan). A wrong claim traps in safe builds — the
    /// construction path asserts every resolved fact against the scan, so a
    /// bad producer cannot mint a string with lying caches.
    ///
    /// NB: the §6 review-era shape was `known_cp: ?usize` alone; the exact
    /// `str_ascii` bit (§2, discovered in c1) cannot be inferred from a count,
    /// so the channel carries both facts independently.
    pub const Known = struct { cp_len: ?usize = null, ascii: ?bool = null };

    /// One fused scan: code-point count (every byte that is not a continuation
    /// byte `0b10xxxxxx` starts a code point — equals
    /// `std.unicode.utf8CountCodepoints` for valid UTF-8, merely defined for
    /// stray non-UTF-8 bytes) AND the exact all-ASCII bit.
    const Counted = struct { cp_len: usize, ascii: bool };
    fn countCodepoints(content: []const u8) Counted {
        var n: usize = 0;
        var ascii = true;
        for (content) |b| {
            if (b & 0xC0 != 0x80) n += 1;
            if (b >= 0x80) ascii = false;
        }
        return .{ .cp_len = n, .ascii = ascii };
    }

    /// Allocate a `String` owning a copy of `content`. This is the raw allocation
    /// only — it does **not** intern or GC-link the object; the heap does that
    /// (`gc.zig`). Callers should go through `Heap.intern`, not here.
    pub fn create(gpa: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!*String {
        return createWithHash(gpa, content, std.hash.Wyhash.hash(0, content));
    }

    /// `create` with the content hash already computed. For `Heap.intern`, which
    /// has just hashed `content` to probe the intern table — the miss path must
    /// not pay the hash twice. `hash` MUST be `Wyhash.hash(0, content)`; every
    /// other caller goes through `create`, which guarantees it.
    pub fn createWithHash(gpa: std.mem.Allocator, content: []const u8, hash: u64) std.mem.Allocator.Error!*String {
        return createWithHashKnown(gpa, content, hash, .{});
    }

    /// `createWithHash` with producer-`Known` character facts (doc 28 §6): each
    /// known fact skips its half of the construction scan; each is asserted
    /// against the scan in safe builds (a wrong claim is a producer bug, never
    /// a silently-lying cache). Callers go through `Heap.internKnown`.
    pub fn createWithHashKnown(gpa: std.mem.Allocator, content: []const u8, hash: u64, known: Known) std.mem.Allocator.Error!*String {
        // NB: no valid-UTF-8 assert here, deliberately — program-visible strings
        // ARE valid by construction (S-B: validated literals/decode/host seams),
        // but the effect log parks raw non-UTF-8 host input as interned strings
        // (validate-after-log, so a recorded bad input replays byte-identically)
        // and those bytes legitimately pass through here on record, replay, and
        // restore. The ASCII fast paths therefore rest on the EXACT `str_ascii`
        // bit below, never on UTF-8 validity.
        // Checked size: a hostile/huge length must fail as OOM, not wrap the
        // allocation size (mahina's counterpart of LuaJIT's LJ_MAX_STR guard).
        const total = std.math.add(usize, @sizeOf(String), content.len) catch return error.OutOfMemory;
        const raw = try gpa.alignedAlloc(u8, std.mem.Alignment.of(String), total);
        const self: *String = @ptrCast(raw.ptr);
        const counted: Counted = if (known.cp_len != null and known.ascii != null)
            .{ .cp_len = known.cp_len.?, .ascii = known.ascii.? }
        else blk: {
            const scanned = countCodepoints(content);
            break :blk .{
                .cp_len = known.cp_len orelse scanned.cp_len,
                .ascii = known.ascii orelse scanned.ascii,
            };
        };
        std.debug.assert(std.meta.eql(counted, countCodepoints(content)));
        var header = GcHeader.init(.string);
        header.flags.str_ascii = counted.ascii;
        self.* = .{
            .header = header,
            .hash = hash,
            .len = content.len,
            .cp_len = counted.cp_len,
            .next_intern = null,
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

test "str_ascii is EXACT: set for ASCII, clear for multibyte AND for bytes that counterfeit cp_len == len (doc 28 §2)" {
    const a = try String.create(testing.allocator, "hello");
    defer a.destroy(testing.allocator);
    try testing.expect(a.isAscii());

    const e = try String.create(testing.allocator, "");
    defer e.destroy(testing.allocator);
    try testing.expect(e.isAscii()); // vacuously ASCII

    const b = try String.create(testing.allocator, "héllo");
    defer b.destroy(testing.allocator);
    try testing.expect(!b.isAscii());

    // All-0xFF: every byte is a non-continuation byte, so cp_len == len even
    // though nothing here is ASCII — exactly the counterfeit the fused-scan
    // bit exists to defeat. (Such bytes are constructible on purpose: the
    // effect log parks raw non-UTF-8 host input as interned strings.)
    const f = try String.create(testing.allocator, "\xFF\xFF\xFF");
    defer f.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 3), f.cpLen());
    try testing.expect(!f.isAscii());

    // A stray continuation byte drops cp_len below len — also not ASCII.
    const g = try String.create(testing.allocator, "a\x80b");
    defer g.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.cpLen());
    try testing.expect(!g.isAscii());
}
