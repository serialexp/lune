//! Byte-slice equality without std's long-slice lowering (Rule Z-2: the
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
