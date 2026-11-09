//! Calendar arithmetic and `strftime` for `os.time`/`os.date` (doc 65 §8):
//! pure functions of their inputs, so a date formats the same on every
//! machine and in a replay. The host supplies only the instant and the local
//! zone (`system.LocalZone`); everything here is proleptic Gregorian, in the
//! C locale, on 64-bit seconds.
//!
//! Dependency-free on purpose: the VM core imports it on every target.

const std = @import("std");

pub const seconds_per_day = 86400;

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm, exact
/// for every `i64` day the callers can produce). `m` is 1..12, `d` 1..31.
pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp = @mod(m + 9, 12); // March = 0
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

/// Inverse of `daysFromCivil`.
pub fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = m, .day = d };
}

pub fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

/// 0 = Sunday, like C's `tm_wday`.
pub fn weekday(days: i64) u8 {
    return @intCast(@mod(days + 4, 7)); // 1970-01-01 was a Thursday
}

/// A broken-down time: C's `struct tm` with a 64-bit year.
pub const Tm = struct {
    year: i64,
    /// 1..12
    month: u8,
    /// 1..31
    day: u8,
    hour: u8,
    min: u8,
    sec: u8,
    /// 0 = Sunday
    wday: u8,
    /// 0..365
    yday: u16,
};

/// Break down `t` seconds since the epoch, as UTC (add a zone's offset first
/// for local time).
pub fn breakDown(t: i64) Tm {
    const days = @divFloor(t, seconds_per_day);
    const rem: u32 = @intCast(@mod(t, seconds_per_day));
    const c = civilFromDays(days);
    return .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = @intCast(rem / 3600),
        .min = @intCast(rem / 60 % 60),
        .sec = @intCast(rem % 60),
        .wday = weekday(days),
        .yday = @intCast(days - daysFromCivil(c.year, 1, 1)),
    };
}

/// The fields `os.time` reads from a date table, each already range-checked
/// to a C `int` (as Lua's `getfield` does), so the arithmetic below cannot
/// overflow. Out-of-range values normalize like `mktime`: month 13 is January
/// of the next year, day 0 the last day of the previous month.
pub const Fields = struct {
    year: i64,
    /// 1-based, any value
    month: i64,
    day: i64,
    hour: i64,
    min: i64,
    sec: i64,
};

/// The seconds since the epoch the fields name, read as UTC.
pub fn secondsOf(f: Fields) i64 {
    const m0 = f.month - 1;
    const y = f.year + @divFloor(m0, 12);
    const days = daysFromCivil(y, @mod(m0, 12) + 1, 1) + (f.day - 1);
    return days * seconds_per_day + f.hour * 3600 + f.min * 60 + f.sec;
}

/// Whether `year` fits a C `tm_year` (`year - 1900` in an `int`), the range
/// Lua can represent; outside it `os.date`/`os.time` raise.
pub fn yearRepresentable(year: i64) bool {
    return year - 1900 >= std.math.minInt(i32) and year - 1900 <= std.math.maxInt(i32);
}

/// The local zone at one instant: the offset east of UTC, whether daylight
/// saving is in effect, and the abbreviation (`%Z`).
pub const Zone = struct {
    offset: i32,
    dst: bool,
    abbr: []const u8,

    pub const utc: Zone = .{ .offset = 0, .dst = false, .abbr = "GMT" };
};

/// The longest conversion `checkSpec` accepts after the `%`.
pub const max_spec_len = 2;

/// Lua's `checkoption` over C99's `strftime` conversions (LUA_STRFTIMEOPTIONS):
/// the length of the valid specifier at the start of `conv` (the text after a
/// `%`), or null if there is none.
pub fn checkSpec(conv: []const u8) ?usize {
    const single = "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%";
    const doubles = [_][]const u8{ "Ec", "EC", "Ex", "EX", "Ey", "EY", "Od", "Oe", "OH", "OI", "Om", "OM", "OS", "Ou", "OU", "OV", "Ow", "OW", "Oy" };
    if (conv.len == 0) return null;
    if (std.mem.indexOfScalar(u8, single, conv[0]) != null) return 1;
    if (conv.len < 2) return null;
    for (doubles) |d| if (std.mem.eql(u8, d, conv[0..2])) return 2;
    return null;
}

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// The ISO 8601 week-based year and week number (`%G`, `%V`).
fn isoWeek(tm: Tm) struct { year: i64, week: u8 } {
    const wday_mon: i64 = @mod(@as(i64, tm.wday) + 6, 7); // Monday = 0
    const week = @divFloor(@as(i64, tm.yday) - wday_mon + 10, 7);
    if (week < 1) return .{ .year = tm.year - 1, .week = isoWeeksIn(tm.year - 1) };
    if (week > isoWeeksIn(tm.year)) return .{ .year = tm.year + 1, .week = 1 };
    return .{ .year = tm.year, .week = @intCast(week) };
}

fn isoWeeksIn(y: i64) u8 {
    const p = struct {
        fn f(x: i64) i64 {
            return @mod(x + @divFloor(x, 4) - @divFloor(x, 100) + @divFloor(x, 400), 7);
        }
    }.f;
    return if (p(y) == 4 or p(y - 1) == 3) 53 else 52;
}

/// Append one conversion (`spec`, as `checkSpec` measured it: an `E`/`O`
/// modifier is the C locale's plain form) to `out`.
pub fn formatSpec(gpa: std.mem.Allocator, out: *std.ArrayList(u8), spec: []const u8, tm: Tm, zone: Zone) std.mem.Allocator.Error!void {
    const c = spec[spec.len - 1];
    var buf: [64]u8 = undefined;
    const text: []const u8 = switch (c) {
        'a' => day_names[tm.wday][0..3],
        'A' => day_names[tm.wday],
        'b', 'h' => month_names[tm.month - 1][0..3],
        'B' => month_names[tm.month - 1],
        'c' => return formatAll(gpa, out, "%a %b %e %H:%M:%S %Y", tm, zone),
        'C' => pad(&buf, @divFloor(tm.year, 100), 1, '0'),
        'd' => pad(&buf, tm.day, 2, '0'),
        'D', 'x' => return formatAll(gpa, out, "%m/%d/%y", tm, zone),
        'e' => pad(&buf, tm.day, 2, ' '),
        'F' => return formatAll(gpa, out, "%Y-%m-%d", tm, zone),
        'g' => pad(&buf, @mod(isoWeek(tm).year, 100), 2, '0'),
        'G' => pad(&buf, isoWeek(tm).year, 1, '0'),
        'H' => pad(&buf, tm.hour, 2, '0'),
        'I' => pad(&buf, if (tm.hour % 12 == 0) 12 else tm.hour % 12, 2, '0'),
        'j' => pad(&buf, @as(i64, tm.yday) + 1, 3, '0'),
        'm' => pad(&buf, tm.month, 2, '0'),
        'M' => pad(&buf, tm.min, 2, '0'),
        'n' => "\n",
        'p' => if (tm.hour < 12) "AM" else "PM",
        'r' => return formatAll(gpa, out, "%I:%M:%S %p", tm, zone),
        'R' => return formatAll(gpa, out, "%H:%M", tm, zone),
        'S' => pad(&buf, tm.sec, 2, '0'),
        't' => "\t",
        'T', 'X' => return formatAll(gpa, out, "%H:%M:%S", tm, zone),
        'u' => pad(&buf, if (tm.wday == 0) 7 else tm.wday, 1, '0'),
        'U' => pad(&buf, @divFloor(@as(i64, tm.yday) + 7 - tm.wday, 7), 2, '0'),
        'V' => pad(&buf, isoWeek(tm).week, 2, '0'),
        'w' => pad(&buf, tm.wday, 1, '0'),
        'W' => pad(&buf, @divFloor(@as(i64, tm.yday) + 7 - @mod(@as(i64, tm.wday) + 6, 7), 7), 2, '0'),
        'y' => pad(&buf, @mod(tm.year, 100), 2, '0'),
        'Y' => pad(&buf, tm.year, 1, '0'),
        'z' => blk: {
            const a: u32 = @abs(zone.offset);
            break :blk std.fmt.bufPrint(&buf, "{c}{d:0>2}{d:0>2}", .{ @as(u8, if (zone.offset < 0) '-' else '+'), a / 3600, a / 60 % 60 }) catch unreachable;
        },
        'Z' => zone.abbr,
        '%' => "%",
        else => unreachable, // `checkSpec` admitted it
    };
    try out.appendSlice(gpa, text);
}

/// Format a whole `strftime` string whose conversions are known valid (the
/// composite forms above).
fn formatAll(gpa: std.mem.Allocator, out: *std.ArrayList(u8), fmt: []const u8, tm: Tm, zone: Zone) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') {
            try out.append(gpa, fmt[i]);
            continue;
        }
        i += 1;
        try formatSpec(gpa, out, fmt[i .. i + 1], tm, zone);
    }
}

/// `n` in decimal, left-padded with `fill` to `width`; a negative number
/// keeps its sign in front of the padding, as glibc does.
fn pad(buf: []u8, n: i64, width: usize, fill: u8) []const u8 {
    var digits: [24]u8 = undefined;
    const mag = std.fmt.bufPrint(&digits, "{d}", .{@abs(n)}) catch unreachable;
    var len: usize = 0;
    if (n < 0) {
        buf[0] = '-';
        len = 1;
    }
    const want = if (n < 0 and width > 0) width - 1 else width;
    var k = mag.len;
    while (k < want) : (k += 1) {
        buf[len] = fill;
        len += 1;
    }
    @memcpy(buf[len..][0..mag.len], mag);
    return buf[0 .. len + mag.len];
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFormat(fmt: []const u8, t: i64, zone: Zone, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const tm = breakDown(t + zone.offset);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try out.append(testing.allocator, fmt[i]);
            i += 1;
            continue;
        }
        const n = checkSpec(fmt[i + 1 ..]).?;
        try formatSpec(testing.allocator, &out, fmt[i + 1 .. i + 1 + n], tm, zone);
        i += 1 + n;
    }
    try testing.expectEqualStrings(expected, out.items);
}

test "[REQ-89.1] civil dates round-trip over four centuries and the epoch's neighbours" {
    var z: i64 = daysFromCivil(1600, 1, 1);
    while (z < daysFromCivil(2001, 1, 1)) : (z += 1) {
        const c = civilFromDays(z);
        try testing.expectEqual(z, daysFromCivil(c.year, c.month, c.day));
    }
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
    try testing.expectEqual(Civil{ .year = -1, .month = 12, .day = 31 }, civilFromDays(daysFromCivil(0, 1, 1) - 1));
}

test "[REQ-89.2] breakDown matches gmtime" {
    // date -u -d @1700000000: Tue Nov 14 22:13:20 UTC 2023, day 318 of the year.
    try testing.expectEqual(Tm{ .year = 2023, .month = 11, .day = 14, .hour = 22, .min = 13, .sec = 20, .wday = 2, .yday = 317 }, breakDown(1700000000));
    try testing.expectEqual(Tm{ .year = 1969, .month = 12, .day = 31, .hour = 23, .min = 59, .sec = 59, .wday = 3, .yday = 364 }, breakDown(-1));
}

test "[REQ-89.2] secondsOf normalizes like mktime" {
    const base = secondsOf(.{ .year = 2024, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0 });
    try testing.expectEqual(@as(i64, 1704067200), base);
    // Month 13 is next January; day 0 is the last day of the month before.
    try testing.expectEqual(secondsOf(.{ .year = 2025, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0 }), secondsOf(.{ .year = 2024, .month = 13, .day = 1, .hour = 0, .min = 0, .sec = 0 }));
    try testing.expectEqual(secondsOf(.{ .year = 2024, .month = 2, .day = 29, .hour = 0, .min = 0, .sec = 0 }), secondsOf(.{ .year = 2024, .month = 3, .day = 0, .hour = 0, .min = 0, .sec = 0 }));
    try testing.expectEqual(base - 1, secondsOf(.{ .year = 2024, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = -1 }));
    try testing.expectEqual(secondsOf(.{ .year = 2023, .month = 11, .day = 1, .hour = 0, .min = 0, .sec = 0 }), secondsOf(.{ .year = 2024, .month = -1, .day = 1, .hour = 0, .min = 0, .sec = 0 }));
}

test "[REQ-88.1] strftime conversions in the C locale" {
    // 2023-11-14 22:13:20 UTC, a Tuesday.
    const t = 1700000000;
    const z = Zone.utc;
    try expectFormat("%a %A %b %B %h", t, z, "Tue Tuesday Nov November Nov");
    try expectFormat("%c", t, z, "Tue Nov 14 22:13:20 2023");
    try expectFormat("%C %d %D %e %F", t, z, "20 14 11/14/23 14 2023-11-14");
    try expectFormat("%H %I %j %m %M %p %S", t, z, "22 10 318 11 13 PM 20");
    try expectFormat("%r|%R|%T|%x|%X", t, z, "10:13:20 PM|22:13|22:13:20|11/14/23|22:13:20");
    try expectFormat("%u %w %U %W %V %G %g", t, z, "2 2 46 46 46 2023 23");
    try expectFormat("%y %Y %z %Z %% %n%t", t, z, "23 2023 +0000 GMT % \n\t");
    try expectFormat("%Ec|%EY|%Od|%OH", t, z, "Tue Nov 14 22:13:20 2023|2023|14|22");
    // A single-digit day pads with a space for %e; midnight is 12 AM.
    try expectFormat("%e|%I %p", 1700000000 - 13 * seconds_per_day - 22 * 3600, z, " 1|12 AM");
    // A zone east and west of UTC.
    try expectFormat("%H:%M %z %Z", t, .{ .offset = 3600, .dst = false, .abbr = "CET" }, "23:13 +0100 CET");
    try expectFormat("%z", t, .{ .offset = -(9 * 3600 + 30 * 60), .dst = false, .abbr = "-0930" }, "-0930");
}

test "[REQ-88.2] ISO weeks at year boundaries" {
    // 2021-01-03 (Sunday) is in 2020-W53; 2024-12-30 (Monday) is in 2025-W01.
    try expectFormat("%G-W%V-%u", secondsOf(.{ .year = 2021, .month = 1, .day = 3, .hour = 0, .min = 0, .sec = 0 }), Zone.utc, "2020-W53-7");
    try expectFormat("%G-W%V-%u", secondsOf(.{ .year = 2024, .month = 12, .day = 30, .hour = 0, .min = 0, .sec = 0 }), Zone.utc, "2025-W01-1");
    // Sunday 2023-01-01: %U counts weeks from the first Sunday, so it is
    // week 01; %W counts from the first Monday, so it is week 00.
    try expectFormat("%U %W", secondsOf(.{ .year = 2023, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0 }), Zone.utc, "01 00");
}

test "[REQ-88.3] years far from now format as glibc does" {
    try expectFormat("%Y %C %y", secondsOf(.{ .year = 12345, .month = 6, .day = 1, .hour = 0, .min = 0, .sec = 0 }), Zone.utc, "12345 123 45");
    try expectFormat("%Y %C %y", secondsOf(.{ .year = 5, .month = 6, .day = 1, .hour = 0, .min = 0, .sec = 0 }), Zone.utc, "5 0 05");
    try expectFormat("%Y %C %y %G %g", secondsOf(.{ .year = -123, .month = 6, .day = 1, .hour = 0, .min = 0, .sec = 0 }), Zone.utc, "-123 -2 77 -123 77");
}

test "[REQ-88.1] checkSpec follows LUA_STRFTIMEOPTIONS" {
    try testing.expectEqual(@as(?usize, 1), checkSpec("Y-%m"));
    try testing.expectEqual(@as(?usize, 2), checkSpec("Ec"));
    try testing.expectEqual(@as(?usize, 2), checkSpec("Oy"));
    try testing.expectEqual(@as(?usize, null), checkSpec("Ez"));
    try testing.expectEqual(@as(?usize, null), checkSpec("E"));
    try testing.expectEqual(@as(?usize, null), checkSpec("q"));
    try testing.expectEqual(@as(?usize, null), checkSpec(""));
}
