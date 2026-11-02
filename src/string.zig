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

/// The intern table's primary hash (doc 28 §5, L3): LuaJIT's `hash_sparse`
/// (`lj_str.c`), the length mixed with sampled 32-bit words, so it costs the
/// same at any length. LuaJIT samples four (first, last, middle, quarter);
/// from eight bytes we also read the second and the second-to-last, so the
/// first and last eight bytes all count. That is where structured strings
/// keep what tells them apart: a line number, a counter, a key's suffix
/// (`io_lines`, `str_long_keys`). Loads are little-endian, so the value is
/// the same on every target, and the seed is fixed, so it is a pure function
/// of the bytes. It only chooses a bucket: the intern table still compares
/// the bytes, so strings that agree on the samples share a chain but never
/// an object. A chain that collects too many of them moves to `denseHash`
/// (`gc.Heap.strtabRehashChain`).
pub fn sparseHash(content: []const u8) u64 {
    const n = content.len;
    var h: u32 = @as(u32, @truncate(n)) ^ sparse_seed;
    var a: u32 = undefined;
    var b: u32 = undefined;
    if (n >= 4) {
        a = word(content, 0);
        h ^= word(content, n - 4);
        if (n >= 8) {
            a ^= std.math.rotl(u32, word(content, 4), 13);
            h ^= std.math.rotl(u32, word(content, n - 8), 19);
        }
        b = word(content, (n >> 1) - 2);
        h ^= b;
        h -%= std.math.rotl(u32, b, 14);
        b +%= word(content, (n >> 2) - 1);
    } else if (n != 0) {
        a = content[0];
        h ^= content[n - 1];
        b = content[n >> 1];
        h ^= b;
        h -%= std.math.rotl(u32, b, 14);
    } else {
        a = 0;
        b = 0;
    }
    a ^= h;
    a -%= std.math.rotl(u32, h, 11);
    b ^= a;
    b -%= std.math.rotl(u32, a, 25);
    h ^= b;
    h -%= std.math.rotl(u32, b, 16);
    return h;
}

/// The hash of a chain `sparseHash` overloaded (doc 28 §5): every byte,
/// keyed differently from the sparse one.
pub fn denseHash(content: []const u8) u64 {
    return std.hash.Wyhash.hash(dense_seed, content);
}

const sparse_seed: u32 = 0x9e37_79b9;
const dense_seed: u64 = 0x2545_f491_4f6c_dd1d;

inline fn word(content: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, content[at..][0..4], .little);
}

/// An interned, immutable string. `extern` so `header` is guaranteed at offset 0
/// (the embedding convention), and the raw bytes live immediately after the
/// struct in the same allocation.
pub const String = extern struct {
    header: GcHeader,
    /// The intern table's hash of the content: `sparseHash`, or `denseHash`
    /// when the string's sparse bucket was rehashed (doc 28 §5); the heap
    /// sets it when it interns the string (`Heap.strtabHash`). Consumed ONLY
    /// by the intern table (`Heap.strtab*`) — table keys hash heap values by
    /// stable `GcHeader.id`, NOT by this field, and observable iteration
    /// order is canonically sorted (doc 02), so this hash function is free to
    /// change without touching any observable behaviour. Not serialized.
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
    /// Every string's construction scan, so it runs at memory speed: a
    /// code point is a byte that is not a continuation byte (`10xxxxxx`), and
    /// the string is ASCII if no byte has its high bit set. Vector lanes count
    /// in `u8`s, summed before they can wrap (255 chunks).
    fn countCodepoints(content: []const u8) Counted {
        var n: usize = 0;
        var high: u8 = 0;
        var rest = content;
        if (comptime std.simd.suggestVectorLength(u8)) |L| {
            const V = @Vector(L, u8);
            const zero: V = @splat(0);
            var high_v = zero;
            while (rest.len >= L) {
                const chunks: usize = @min(rest.len / L, 255);
                var leads = zero;
                for (0..chunks) |c| {
                    const v: V = rest[c * L ..][0..L].*;
                    leads += @select(u8, v & @as(V, @splat(0xC0)) != @as(V, @splat(0x80)), @as(V, @splat(1)), zero);
                    high_v |= v;
                }
                n += @reduce(.Add, @as(@Vector(L, u16), leads));
                rest = rest[chunks * L ..];
            }
            high = @reduce(.Or, high_v);
        }
        for (rest) |b| {
            if (b & 0xC0 != 0x80) n += 1;
            high |= b;
        }
        return .{ .cp_len = n, .ascii = high < 0x80 };
    }

    test "countCodepoints matches the byte-at-a-time definition at every length" {
        var buf: [9000]u8 = undefined;
        var xs: [9000]u8 = undefined;
        @memset(&xs, 'x');
        // A mix of ASCII, 2-, 3- and 4-byte sequences; the counter only
        // classifies bytes, so the cut points need not be on characters.
        const pattern = "aé€𝄞z";
        for (&buf, 0..) |*b, i| b.* = pattern[i % pattern.len];
        var len: usize = 0;
        while (len <= buf.len) : (len += if (len < 300) 1 else 97) {
            const s = buf[0..len];
            var n: usize = 0;
            var ascii = true;
            for (s) |b| {
                if (b & 0xC0 != 0x80) n += 1;
                if (b >= 0x80) ascii = false;
            }
            try std.testing.expectEqual(Counted{ .cp_len = n, .ascii = ascii }, countCodepoints(s));
            try std.testing.expectEqual(Counted{ .cp_len = len, .ascii = true }, countCodepoints(xs[0..len]));
        }
    }

    /// Allocate a `String` owning a copy of `content`. This is the raw allocation
    /// only — it does **not** intern or GC-link the object; the heap does that
    /// (`gc.zig`). Callers should go through `Heap.intern`, not here. The hash
    /// is the sparse one; the heap resets it if the string's bucket is dense
    /// (`Heap.internRestoredUnique`).
    pub fn create(gpa: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!*String {
        return createWithHash(gpa, content, sparseHash(content));
    }

    /// `create` with the content hash already computed. For `Heap.intern`, which
    /// has just hashed `content` to probe the intern table — the miss path must
    /// not pay the hash twice. `hash` MUST be what `Heap.strtabHash` gives
    /// `content`; every other caller goes through `create`.
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

    /// A string built in place (doc 80 §4): the producer writes its bytes
    /// straight into the allocation the string will own, so a result whose
    /// length is known up front (concat) copies each part once, and the
    /// parts' character facts stand in for the construction scan.
    /// `Heap.internBuilt` seals and interns it; `deinit` frees one that was
    /// never handed over.
    pub const Builder = struct {
        raw: ?[]align(@alignOf(String)) u8,
        len: usize = 0,
        cp_len: usize = 0,
        ascii: bool = true,

        /// A builder for exactly `len` bytes.
        pub fn init(gpa: std.mem.Allocator, len: usize) std.mem.Allocator.Error!Builder {
            const total = std.math.add(usize, @sizeOf(String), len) catch return error.OutOfMemory;
            return .{ .raw = try gpa.alignedAlloc(u8, std.mem.Alignment.of(String), total) };
        }

        pub fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
            if (self.raw) |raw| gpa.free(raw);
            self.raw = null;
        }

        /// Append `part`, whose code-point count and ASCII bit the caller
        /// knows (a string operand's cached ones, or a number's text). A
        /// wrong claim traps in `finish` in safe builds.
        pub fn append(self: *Builder, part: []const u8, cp_len: usize, ascii: bool) void {
            const raw = self.raw.?;
            std.debug.assert(@sizeOf(String) + self.len + part.len <= raw.len);
            @memcpy(raw[@sizeOf(String) + self.len ..][0..part.len], part);
            self.len += part.len;
            self.cp_len += cp_len;
            self.ascii = self.ascii and ascii;
        }

        /// Seal the filled builder into an unlinked `String`, its hash and
        /// character caches set, and hand its allocation over to it.
        pub fn finish(self: *Builder) *String {
            const raw = self.raw.?;
            std.debug.assert(@sizeOf(String) + self.len == raw.len);
            self.raw = null;
            const content = raw[@sizeOf(String)..];
            std.debug.assert(std.meta.eql(Counted{ .cp_len = self.cp_len, .ascii = self.ascii }, countCodepoints(content)));
            var header = GcHeader.init(.string);
            header.flags.str_ascii = self.ascii;
            const s: *String = @ptrCast(raw.ptr);
            s.* = .{
                .header = header,
                .hash = 0, // `Heap.internBuilt` sets it
                .len = self.len,
                .cp_len = self.cp_len,
                .next_intern = null,
            };
            return s;
        }
    };

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
    try testing.expectEqual(sparseHash("hello"), s.hash);
}

test "sparseHash is LuaJIT's hash_sparse, widened, with our fixed seed" {
    // Values from lj_str.c's hash_sparse with the two extra words, compiled
    // from C with seed 0x9e3779b9 (doc 28 §5): the port, word order and
    // wrapping included. Below eight bytes they are LuaJIT's own values.
    const cases = .{
        .{ "", 4112797746 },              .{ "a", 2105022239 },
        .{ "ab", 3570053872 },            .{ "abc", 3570053872 },
        .{ "abcd", 152015797 },           .{ "hello", 4040743631 },
        .{ "abcdefg", 3451932861 },       .{ "abcdefgh", 2610000187 },
        .{ "hello world", 347140700 },    .{ "key_000123", 3203954009 },
        .{ "\xc3\xa9t\xc3\xa9", 2420152850 },
        .{ "0123456789abcdefghijklmnopqrstuvwxyz0123456789", 1106307625 },
    };
    inline for (cases) |c| try testing.expectEqual(@as(u64, c[1]), sparseHash(c[0]));
    // It samples: "ab" and "abc" collide, which the intern table resolves by
    // comparing bytes.
}

test "sparseHash reads every one of the first and last eight bytes" {
    var buf: [72]u8 = undefined;
    @memset(&buf, 'x');
    const base = sparseHash(&buf);
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 64, 65, 66, 67, 68, 69, 70, 71 }) |at| {
        buf[at] = 'y';
        try testing.expect(sparseHash(&buf) != base);
        buf[at] = 'x';
    }
    // A byte between the samples is not read: those strings share a hash.
    buf[50] = 'y';
    try testing.expectEqual(base, sparseHash(&buf));
}

test "Builder: parts written in place make the same string as create" {
    var b = try String.Builder.init(testing.allocator, 3 + 4);
    defer b.deinit(testing.allocator);
    b.append("a\xc3\xa9", 2, false); // "aé"
    b.append("xyzw", 4, true);
    const s = b.finish();
    defer s.destroy(testing.allocator);
    const ref = try String.create(testing.allocator, "a\xc3\xa9xyzw");
    defer ref.destroy(testing.allocator);
    try testing.expectEqualStrings(ref.bytes(), s.bytes());
    try testing.expectEqual(ref.cp_len, s.cp_len);
    try testing.expectEqual(ref.isAscii(), s.isAscii());
    try testing.expectEqual(@as(usize, 6), s.cpLen());
}

test "Builder: deinit frees a builder that was never finished" {
    var b = try String.Builder.init(testing.allocator, 4);
    b.append("ab", 2, true);
    b.deinit(testing.allocator); // testing.allocator reports a leak otherwise
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
