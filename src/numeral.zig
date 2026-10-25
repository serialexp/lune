//! Lua 5.4's numeral grammar (`lobject.c` `l_str2int` and `l_str2d`,
//! `lbaselib.c` `b_str2int`): the one conversion behind numeric literals
//! (the lexer classifies and the parser converts with it), `tonumber` and
//! `file:read("n")`, so a numeral means the same thing everywhere. Pure:
//! no allocation, no heap, no locale.
//!
//! An integer numeral is decimal, or hex wrapping modulo 2^64 (`0xffffffffffffffff`
//! is -1). A decimal integer that does not fit is read as a float instead.
//! A float numeral is decimal or hex (`0x1.8p+1`), with no `inf` or `nan`
//! spelling, no digit separators and no `0b`/`0o` prefixes.

const std = @import("std");

pub const Numeral = union(enum) { int: i64, float: f64 };

/// The C `isspace` set `tonumber` trims before reading a numeral (Lua's
/// `lisspace`, LuaJIT's `LJ_CHAR_SPACE`).
pub const space = " \t\n\r\x0B\x0C";

/// `t`, which has no surrounding space, as a numeral: an integer if it
/// reads as one, else a float, else null (Lua's `luaO_str2num`).
pub fn parse(t: []const u8) ?Numeral {
    if (parseInt(t)) |i| return .{ .int = i };
    if (parseFloat(t)) |f| return .{ .float = f };
    return null;
}

/// Lua's `l_str2int`: an optional sign, then hex digits after `0x` (the
/// value wraps) or decimal digits (null if the value does not fit, so it
/// reads as a float). Nothing may follow. Inline: it is `tonumber`'s hot path.
pub inline fn parseInt(t: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < t.len and (t[i] == '-' or t[i] == '+')) {
        neg = t[i] == '-';
        i += 1;
    }
    var a: u64 = 0;
    if (i + 1 < t.len and t[i] == '0' and (t[i + 1] == 'x' or t[i + 1] == 'X')) {
        i += 2;
        const start = i;
        while (i < t.len) : (i += 1) {
            const d = hexValue(t[i]) orelse return null;
            a = a *% 16 +% d;
        }
        if (i == start) return null;
    } else {
        const ds = t[i..];
        if (ds.len == 0) return null;
        // 18 digits cannot overflow, and the bound lets the loop unroll;
        // a longer run takes Lua's checked loop.
        if (ds.len > 18) return decimalChecked(ds, neg);
        for (ds) |c| {
            const d = c -% '0';
            if (d > 9) return null;
            a = a * 10 + d;
        }
    }
    return @bitCast(if (neg) 0 -% a else a);
}

/// Decimal digits `ds` as an integer of the given sign, or null if one is
/// not a digit or the value is out of range (Lua's `maxby10`/`maxlastd`).
fn decimalChecked(ds: []const u8, neg: bool) ?i64 {
    const max_by_10: u64 = std.math.maxInt(i64) / 10;
    const max_last: u64 = std.math.maxInt(i64) % 10;
    var a: u64 = 0;
    for (ds) |c| {
        const d: u64 = c -% '0';
        if (d > 9) return null;
        if (a >= max_by_10 and (a > max_by_10 or d > max_last + @intFromBool(neg))) return null;
        a = a * 10 + d;
    }
    return @bitCast(if (neg) 0 -% a else a);
}

/// Lua's `l_str2d` (C `strtod` without `inf`/`nan`): an optional sign;
/// decimal digits with at most one `.` and an optional `e` exponent, or
/// `0x`, hex digits with at most one `.` and an optional `p` exponent (a
/// power of two). The mantissa needs a digit; an exponent needs a decimal
/// digit. Rounds correctly; out of range is ±inf or ±0, as `strtod`.
pub fn parseFloat(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
    const hex = i + 1 < t.len and t[i] == '0' and (t[i + 1] == 'x' or t[i + 1] == 'X');
    if (hex) i += 2;
    var digits: usize = 0;
    var point = false;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '.' and !point) {
            point = true;
        } else if (if (hex) hexValue(c) != null else (c >= '0' and c <= '9')) {
            digits += 1;
        } else break;
    }
    if (digits == 0) return null;
    if (i < t.len and (if (hex) (t[i] == 'p' or t[i] == 'P') else (t[i] == 'e' or t[i] == 'E'))) {
        i += 1;
        if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
        const exp_start = i;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
        if (i == exp_start) return null;
    }
    if (i != t.len) return null;
    // The grammar above is a subset of what std's parser reads (it also
    // takes `_` separators and `inf`/`nan`, which never get this far).
    return std.fmt.parseFloat(f64, t) catch unreachable;
}

/// Lua's `b_str2int` (`tonumber(s, base)`, `base` in 2..36): space, an
/// optional sign, one or more alphanumeric digits below `base` (letters
/// are 10..35 in either case; the value wraps modulo 2^64), then space.
pub fn parseBase(s: []const u8, base: u8) ?i64 {
    std.debug.assert(base >= 2 and base <= 36);
    var i: usize = 0;
    while (i < s.len and std.mem.indexOfScalar(u8, space, s[i]) != null) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (i >= s.len or !std.ascii.isAlphanumeric(s[i])) return null;
    var n: u64 = 0;
    while (i < s.len and std.ascii.isAlphanumeric(s[i])) : (i += 1) {
        const c = s[i];
        const d: u64 = if (std.ascii.isDigit(c)) c - '0' else std.ascii.toUpper(c) - 'A' + 10;
        if (d >= base) return null;
        n = n *% base +% d;
    }
    while (i < s.len and std.mem.indexOfScalar(u8, space, s[i]) != null) i += 1;
    if (i != s.len) return null;
    return @bitCast(if (neg) 0 -% n else n);
}

fn hexValue(c: u8) ?u64 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests — every expectation below was checked against lua5.4 (5.4.6).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectNumeral(t: []const u8, want: ?Numeral) !void {
    const got = parse(t);
    if (want == null) {
        if (got != null) {
            std.debug.print("\"{s}\" should not be a numeral\n", .{t});
            return error.TestUnexpectedResult;
        }
        return;
    }
    const g = got orelse {
        std.debug.print("\"{s}\" should be a numeral\n", .{t});
        return error.TestUnexpectedResult;
    };
    switch (want.?) {
        .int => |w| try testing.expectEqual(Numeral{ .int = w }, g),
        .float => |w| {
            try testing.expect(g == .float);
            try testing.expectEqual(@as(u64, @bitCast(w)), @as(u64, @bitCast(g.float)));
        },
    }
}

test "integers: decimal, hex wrapping, decimal overflow reads as a float" {
    try expectNumeral("0", .{ .int = 0 });
    try expectNumeral("00420", .{ .int = 420 });
    try expectNumeral("-7", .{ .int = -7 });
    try expectNumeral("+7", .{ .int = 7 });
    try expectNumeral("-0", .{ .int = 0 });
    try expectNumeral("9223372036854775807", .{ .int = std.math.maxInt(i64) });
    try expectNumeral("-9223372036854775808", .{ .int = std.math.minInt(i64) });
    try expectNumeral("9223372036854775808", .{ .float = 9223372036854775808.0 });
    try expectNumeral("-9223372036854775809", .{ .float = -9223372036854775809.0 });
    try expectNumeral("0000000000000000000001", .{ .int = 1 });
    try expectNumeral("123456789012345678", .{ .int = 123456789012345678 });
    try expectNumeral("1234567890123456789", .{ .int = 1234567890123456789 });
    try expectNumeral("-0000000000000000000000009", .{ .int = -9 });
    try expectNumeral("0x10", .{ .int = 16 });
    try expectNumeral("0X1f", .{ .int = 31 });
    try expectNumeral("-0x10", .{ .int = -16 });
    try expectNumeral("0xffffffffffffffff", .{ .int = -1 });
    try expectNumeral("0x10000000000000000", .{ .int = 0 });
    try expectNumeral("0x7fffffffffffffff", .{ .int = std.math.maxInt(i64) });
}

test "floats: decimal and hex, correctly rounded" {
    try expectNumeral("1.0", .{ .float = 1.0 });
    try expectNumeral("1.", .{ .float = 1.0 });
    try expectNumeral(".5", .{ .float = 0.5 });
    try expectNumeral("-0.0", .{ .float = -0.0 });
    try expectNumeral("1e5", .{ .float = 1e5 });
    try expectNumeral("1E+5", .{ .float = 1e5 });
    try expectNumeral("2.5e-3", .{ .float = 2.5e-3 });
    try expectNumeral("1e999", .{ .float = std.math.inf(f64) });
    try expectNumeral("-1e999", .{ .float = -std.math.inf(f64) });
    try expectNumeral("1e-999", .{ .float = 0.0 });
    try expectNumeral("0x1.8p+1", .{ .float = 3.0 });
    try expectNumeral("0x1p-3", .{ .float = 0.125 });
    try expectNumeral("0x.8", .{ .float = 0.5 });
    try expectNumeral("0x1.", .{ .float = 1.0 });
    try expectNumeral("0xA.8P0", .{ .float = 10.5 });
    try expectNumeral("0x1.999999999999ap-4", .{ .float = 0.1 });
    try expectNumeral("0x0.0000000000001p-1022", .{ .float = 4.9406564584124654e-324 });
    try expectNumeral("0x1p99999", .{ .float = std.math.inf(f64) });
    // More hex digits than a double holds: rounded, not truncated.
    try expectNumeral("0x1.00000000000008p0", .{ .float = 1.0 });
    try expectNumeral("0x1.00000000000018p0", .{ .float = 1.0000000000000004 });
}

test "not numerals: separators, other prefixes, inf/nan, stray text" {
    const bad = [_][]const u8{
        "",       "+",     "-",       ".",    "e5",    "1e",     "1e+",   "0x",   "0x.",  "0xp1",
        "1_000",  "1__0",  "_10",     "10_",  "0b101", "0o17",   "0x_10", "inf",  "-inf", "nan",
        "infinity", "1 2", "12a",     "a12",  "1.2.3", "1e5.0",  "0x1e+5", "1p3",  "0x1p", "٤٢",
        "--1",    "+-1",   "0x1.8e3p", " 1",  "1 ",
        // Past 18 digits the checked loop must still reject a non-digit.
        "1234567890123456789x", "12345678901234567890123x",
    };
    for (bad) |t| try expectNumeral(t, null);
}

test "tonumber with a base: b_str2int" {
    try testing.expectEqual(@as(?i64, 255), parseBase("ff", 16));
    try testing.expectEqual(@as(?i64, 255), parseBase("  FF  ", 16));
    try testing.expectEqual(@as(?i64, -1), parseBase("ffffffffffffffff", 16));
    try testing.expectEqual(@as(?i64, -5), parseBase("-101", 2));
    try testing.expectEqual(@as(?i64, 5), parseBase("+101", 2));
    try testing.expectEqual(@as(?i64, 35), parseBase("z", 36));
    try testing.expectEqual(@as(?i64, 35), parseBase("Z", 36));
    try testing.expectEqual(@as(?i64, null), parseBase("2", 2));
    try testing.expectEqual(@as(?i64, null), parseBase("", 10));
    try testing.expectEqual(@as(?i64, null), parseBase("  ", 10));
    try testing.expectEqual(@as(?i64, null), parseBase("- 1", 10));
    try testing.expectEqual(@as(?i64, null), parseBase("1 1", 10));
    try testing.expectEqual(@as(?i64, null), parseBase("0x10", 16));
    try testing.expectEqual(@as(?i64, null), parseBase("1.0", 10));
    try testing.expectEqual(@as(?i64, null), parseBase("1\x000", 10));
}
