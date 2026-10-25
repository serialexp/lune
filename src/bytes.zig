//! Byte-slice equality and order without std's slow lowerings (Rule Z-2: the
//! workaround for a toolchain codegen problem lives here, in one place).
//!
//! `std.mem.eql(u8, …)` (0.17.0) compares a slice of up to 64 bytes with two
//! overlapping `@Vector(32, u8)` loads, but a longer one in `@bitCast`
//! `@Vector(64, u8)` chunks, and on an AVX-512 target LLVM builds each such
//! chunk one lane at a time from a stack copy. Measured on the dev machine
//! (ReleaseFast, native CPU): ~12 instructions for a 64-byte compare, ~1093
//! for 65 bytes and for 100, ~36 for 100 bytes on `x86_64_v3`. `eql` here is
//! std's algorithm up to 64 bytes, restated so a short compare pays no extra
//! branch, and past it walks the slices in 32-byte vector loads (29
//! instructions at 65 bytes, 57 at 200).
//!
//! Use it where a compare can see long data at run time: the string-intern
//! lookup, a pattern back-reference. Short, fixed names stay on `std.mem.eql`.
//!
//! `std.mem.order(u8, …)` is a byte loop, ~10 instructions a byte (610 for
//! two equal 60-byte slices, 1010 for 100). `order` finds the first
//! difference 32, 16, 8 or 4 bytes at a time.
//!
//! `std.mem.indexOfPos(u8, …)` builds a 256-entry `usize` Boyer-Moore-
//! Horspool table on every call once the haystack reaches 52 bytes (2 KiB of
//! stores; 555 instructions for a 60-byte needle in 120 bytes) and verifies
//! through the slow long `mem.eql`. `find` needs no table: it filters 32
//! positions at a time on the needle's first and last bytes.

const std = @import("std");

/// Whether `a` and `b` hold the same bytes. Kept out of line, as std's
/// `eqlBytes` is: inlined into `Heap.internImpl` it cost every intern ~0.2-0.8%
/// in instructions (`io_lines`, `scalar`), hit or miss.
pub noinline fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;
    if (a.len <= 16) {
        if (a.len < 4) {
            const x = (a[0] ^ b[0]) | (a[a.len - 1] ^ b[a.len - 1]) | (a[a.len / 2] ^ b[a.len / 2]);
            return x == 0;
        }
        // Four overlapping 4-byte words cover any length in 4..16.
        var x: u32 = 0;
        for ([_]usize{ 0, a.len - 4, (a.len / 8) * 4, a.len - 4 - ((a.len / 8) * 4) }) |n| {
            x |= @as(u32, @bitCast(a[n..][0..4].*)) ^ @as(u32, @bitCast(b[n..][0..4].*));
        }
        return x == 0;
    }
    if (a.len <= 32) return halvesEql(16, a, b);
    if (a.len <= 64) return halvesEql(32, a, b);
    const V = @Vector(32, u8);
    const zero: V = @splat(0);
    var i: usize = 0;
    while (i + 32 < a.len) : (i += 32) {
        const x = @as(V, a[i..][0..32].*) ^ @as(V, b[i..][0..32].*);
        if (@reduce(.Or, x != zero)) return false;
    }
    // The last 32 bytes, overlapping the loop's final chunk when the length
    // is not a multiple of 32.
    const t = a.len - 32;
    const x = @as(V, a[t..][0..32].*) ^ @as(V, b[t..][0..32].*);
    return !@reduce(.Or, x != zero);
}

/// The byte-wise order of `a` and `b` (`std.mem.order(u8, a, b)`): the first
/// differing byte decides, else the shorter slice is less. Lua's string
/// order is `strcoll`'s, which in the C locale is this. The first byte, which
/// decides most compares, and one slice (an interned string compared with
/// itself) are checked inline; the rest is out of line, as `eql` is.
pub inline fn order(a: []const u8, b: []const u8) std.math.Order {
    if (a.len != 0 and b.len != 0 and a[0] != b[0]) return std.math.order(a[0], b[0]);
    if (a.ptr == b.ptr and a.len == b.len) return .eq;
    return orderFrom(a, b);
}

noinline fn orderFrom(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    // Each width compares its chunks in order and ends with one that
    // overlaps the last: the overlap is known equal, so the first
    // difference in that chunk is the first overall.
    // Shortest first: a short string is the common operand.
    const d: ?usize = if (n < 4) blk: {
        for (0..n) |i| if (a[i] != b[i]) break :blk i;
        break :blk null;
    } else if (n < 8)
        firstDiff(4, a, b, 0) orelse firstDiff(4, a, b, n - 4)
    else if (n < 16)
        firstDiff(8, a, b, 0) orelse firstDiff(8, a, b, n - 8)
    else if (n < 32)
        firstDiff(16, a, b, 0) orelse firstDiff(16, a, b, n - 16)
    else blk: {
        var i: usize = 0;
        while (i + 32 < n) : (i += 32) {
            if (firstDiff(32, a, b, i)) |d| break :blk d;
        }
        break :blk firstDiff(32, a, b, n - 32);
    };
    if (d) |i| return std.math.order(a[i], b[i]);
    return std.math.order(a.len, b.len);
}

/// The first index at or after `start` where `needle` occurs in `haystack`
/// (`std.mem.indexOfPos(u8, …)`). A vector of 32 candidate positions is
/// kept where both the needle's first byte and its last byte (at the
/// needle's length from it) match, and each kept one is checked with `eql`
/// (Muła's "generic SIMD" search). Like Lua's `lmemfind`, adversarial input
/// is O(haystack × needle); there is no per-call setup.
pub fn find(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len > haystack.len or start > haystack.len - needle.len) {
        return if (needle.len == 0 and start <= haystack.len) start else null;
    }
    if (needle.len == 0) return start;
    if (needle.len == 1) return std.mem.findScalarPos(u8, haystack, start, needle[0]);
    return findFrom(haystack, start, needle);
}

noinline fn findFrom(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    // The last position a match can start at.
    const last = haystack.len - needle.len;
    const positions = last + 1 - start;
    if (positions >= 32) return findBlocks(32, haystack, start, needle);
    if (positions >= 16) return findBlocks(16, haystack, start, needle);
    const m = needle.len;
    for (start..last + 1) |i| {
        if (haystack[i] == needle[0] and haystack[i + m - 1] == needle[m - 1] and
            eql(haystack[i + 1 ..][0 .. m - 2], needle[1 .. m - 1])) return i;
    }
    return null;
}

/// `findFrom` over at least `w` candidate positions, `w` at a time.
inline fn findBlocks(comptime w: usize, haystack: []const u8, start: usize, needle: []const u8) ?usize {
    const m = needle.len;
    const last = haystack.len - m;
    const V = @Vector(w, u8);
    const Mask = @Int(.unsigned, w);
    const first_b: V = @splat(needle[0]);
    const last_b: V = @splat(needle[m - 1]);
    var i = start;
    while (true) : (i += w) {
        // The final block overlaps the one before; its lanes below `i` were
        // checked there.
        const at0 = @min(i, last + 1 - w);
        const f = @as(V, haystack[at0..][0..w].*) == first_b;
        const l = @as(V, haystack[at0 + m - 1 ..][0..w].*) == last_b;
        var hits: Mask = @bitCast(f & l);
        hits &= ~@as(Mask, 0) << @intCast(i - at0);
        while (hits != 0) : (hits &= hits - 1) {
            const at = at0 + @ctz(hits);
            if (eql(haystack[at + 1 ..][0 .. m - 2], needle[1 .. m - 1])) return at;
        }
        if (at0 + w > last) return null;
    }
}

/// The index of the first differing byte of the `w` bytes at `at`, or null.
inline fn firstDiff(comptime w: usize, a: []const u8, b: []const u8, at: usize) ?usize {
    if (w <= 8) {
        const T = @Int(.unsigned, 8 * w);
        const x = std.mem.readInt(T, a[at..][0..w], .little);
        const y = std.mem.readInt(T, b[at..][0..w], .little);
        // The lowest differing byte is the first in memory.
        return if (x == y) null else at + @ctz(x ^ y) / 8;
    }
    const V = @Vector(w, u8);
    // A mask, bit k for lane k (`vpmovmskb`): `std.simd.firstTrue` lowers
    // to a ~15-instruction minimum over lane indices.
    const ne: @Int(.unsigned, w) = @bitCast(@as(V, a[at..][0..w].*) != @as(V, b[at..][0..w].*));
    return if (ne == 0) null else at + @ctz(ne);
}

/// Equal slices of length in `(n, 2n]`: the first and the last `n` bytes,
/// overlapping in the middle.
inline fn halvesEql(comptime n: usize, a: []const u8, b: []const u8) bool {
    const V = @Vector(n, u8);
    var x = @as(V, a[0..n].*) ^ @as(V, b[0..n].*);
    x |= @as(V, a[a.len - n ..][0..n].*) ^ @as(V, b[a.len - n ..][0..n].*);
    return !@reduce(.Or, x != @as(V, @splat(0)));
}

test "eql agrees with std.mem.eql at every length and difference position" {
    var a: [300]u8 = undefined;
    var b: [300]u8 = undefined;
    for (&a, 0..) |*x, i| x.* = @truncate(i *% 7 +% 3);
    for (0..a.len + 1) |len| {
        @memcpy(b[0..len], a[0..len]);
        try std.testing.expect(eql(a[0..len], b[0..len]));
        for (0..len) |d| {
            b[d] ^= 0x40;
            try std.testing.expect(!eql(a[0..len], b[0..len]));
            b[d] ^= 0x40;
        }
        if (len > 0) try std.testing.expect(!eql(a[0..len], b[0 .. len - 1]));
    }
}

test "order agrees with std.mem.order at every length and difference position" {
    var a: [300]u8 = undefined;
    var b: [300]u8 = undefined;
    for (&a, 0..) |*x, i| x.* = @truncate(i *% 7 +% 3);
    for (0..a.len + 1) |len| {
        @memcpy(b[0..len], a[0..len]);
        try std.testing.expectEqual(std.math.Order.eq, order(a[0..len], b[0..len]));
        for (0..len) |d| {
            // Above and below, including across the sign bit.
            for ([_]u8{ 1, 0x80, 0xff }) |delta| {
                b[d] = a[d] +% delta;
                try std.testing.expectEqual(std.mem.order(u8, a[0..len], b[0..len]), order(a[0..len], b[0..len]));
                try std.testing.expectEqual(std.mem.order(u8, b[0..len], a[0..len]), order(b[0..len], a[0..len]));
            }
            b[d] = a[d];
        }
        if (len > 0) {
            try std.testing.expectEqual(std.math.Order.gt, order(a[0..len], b[0 .. len - 1]));
            try std.testing.expectEqual(std.math.Order.lt, order(a[0 .. len - 1], b[0..len]));
        }
    }
}

test "find agrees with std.mem.indexOfPos" {
    var hay: [200]u8 = undefined;
    // A small alphabet, so needles recur and near-misses abound.
    for (&hay, 0..) |*x, i| x.* = "abcab"[(i * i + i / 3) % 5];
    for (0..hay.len + 1) |hlen| {
        const h = hay[0..hlen];
        for ([_]usize{ 0, 1, 2, 3, 5, 31, 32, 33, 70 }) |nlen| {
            for ([_]usize{ 0, 7, 40, 100, 150 }) |from| {
                if (from + nlen > hay.len) continue;
                const n = hay[from..][0..nlen];
                for ([_]usize{ 0, 1, 30, 64, hlen }) |st| {
                    if (st > hlen) continue;
                    try std.testing.expectEqual(std.mem.indexOfPos(u8, h, st, n), find(h, st, n));
                }
            }
        }
        try std.testing.expectEqual(std.mem.indexOfPos(u8, h, 0, "zz"), find(h, 0, "zz"));
    }
}
