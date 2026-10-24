//! The local time zone from TZif data (RFC 8536) and POSIX `TZ` rules, for
//! the host's `localZone` (doc 65 §8). mahina links no libc on most targets,
//! so the CLI and libmahina read `/etc/localtime` or `$TZ` themselves rather
//! than calling `localtime_r`.
//!
//! Pure: parsing and lookup are functions of the bytes, so a zone answers the
//! same on every machine that has the same file. Leap-second records (the
//! `right/` zones) are ignored — instants are POSIX seconds, as Lua's are.

const std = @import("std");
const datetime = @import("datetime.zig");

const Zone = datetime.Zone;

/// One `TZ` rule date: `Jn` (1..365, February 29 never counted), `n`
/// (0..365, counted), or `Mm.w.d` (day `d` of week `w` of month `m`, week 5
/// meaning the last), and the local time of day it takes effect.
const RuleDate = struct {
    kind: union(enum) { julian1: u16, julian0: u16, mwd: struct { m: u8, w: u8, d: u8 } },
    /// Seconds after local midnight; RFC 8536 allows -167..167 hours.
    time: i32 = 2 * 3600,

    /// The rule's instant in `year`, as local seconds since the epoch.
    fn localSeconds(self: RuleDate, year: i64) i64 {
        const jan1 = datetime.daysFromCivil(year, 1, 1);
        const day: i64 = switch (self.kind) {
            .julian1 => |n| jan1 + n - 1 + @intFromBool(datetime.isLeap(year) and n >= 60),
            .julian0 => |n| jan1 + n,
            .mwd => |r| blk: {
                const first = datetime.daysFromCivil(year, r.m, 1);
                var d = first + @mod(@as(i64, r.d) - datetime.weekday(first), 7) + (@as(i64, r.w) - 1) * 7;
                const next_month = if (r.m == 12) datetime.daysFromCivil(year + 1, 1, 1) else datetime.daysFromCivil(year, r.m + 1, 1);
                while (d >= next_month) d -= 7;
                break :blk d;
            },
        };
        return day * datetime.seconds_per_day + self.time;
    }
};

/// A POSIX `TZ` string: `std offset [dst [offset] [,start[/time],end[/time]]]`.
/// The abbreviations borrow the parsed string.
pub const Posix = struct {
    std_abbr: []const u8,
    /// East of UTC (the string's sign is the opposite).
    std_offset: i32,
    dst: ?struct {
        abbr: []const u8,
        offset: i32,
        start: RuleDate,
        end: RuleDate,
    } = null,

    pub fn parse(s: []const u8) ?Posix {
        var p: Parser = .{ .s = s };
        const std_abbr = p.abbr() orelse return null;
        const std_west = p.offset(24) orelse return null;
        var tz: Posix = .{ .std_abbr = std_abbr, .std_offset = -std_west };
        if (p.done()) return tz;
        const dst_abbr = p.abbr() orelse return null;
        var dst_offset = tz.std_offset + 3600;
        if (!p.done() and p.peek() != ',') dst_offset = -(p.offset(24) orelse return null);
        // A zone named with daylight saving but no rule uses the US rule, as
        // glibc does.
        var start: RuleDate = .{ .kind = .{ .mwd = .{ .m = 3, .w = 2, .d = 0 } } };
        var end: RuleDate = .{ .kind = .{ .mwd = .{ .m = 11, .w = 1, .d = 0 } } };
        if (!p.done()) {
            if (!p.eat(',')) return null;
            start = p.ruleDate() orelse return null;
            if (!p.eat(',')) return null;
            end = p.ruleDate() orelse return null;
            if (!p.done()) return null;
        }
        tz.dst = .{ .abbr = dst_abbr, .offset = dst_offset, .start = start, .end = end };
        return tz;
    }

    pub fn lookup(self: Posix, utc: i64) Zone {
        const standard: Zone = .{ .offset = self.std_offset, .dst = false, .abbr = self.std_abbr };
        const d = self.dst orelse return standard;
        const year = datetime.breakDown(utc + self.std_offset).year;
        // The start is given in standard time, the end in daylight time.
        const start = d.start.localSeconds(year) - self.std_offset;
        const end = d.end.localSeconds(year) - d.offset;
        const in_dst = if (start < end) utc >= start and utc < end else !(utc >= end and utc < start);
        return if (in_dst) .{ .offset = d.offset, .dst = true, .abbr = d.abbr } else standard;
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn done(p: *const Parser) bool {
        return p.i >= p.s.len;
    }
    fn peek(p: *const Parser) u8 {
        return p.s[p.i];
    }
    fn eat(p: *Parser, c: u8) bool {
        if (p.done() or p.s[p.i] != c) return false;
        p.i += 1;
        return true;
    }

    /// `<...>` (any characters but `>`) or three or more letters.
    fn abbr(p: *Parser) ?[]const u8 {
        if (p.eat('<')) {
            const start = p.i;
            while (!p.done() and p.peek() != '>') p.i += 1;
            const name = p.s[start..p.i];
            if (!p.eat('>') or name.len < 3) return null;
            return name;
        }
        const start = p.i;
        while (!p.done() and std.ascii.isAlphabetic(p.peek())) p.i += 1;
        if (p.i - start < 3) return null;
        return p.s[start..p.i];
    }

    fn number(p: *Parser, max: u32) ?u32 {
        const start = p.i;
        var n: u32 = 0;
        while (!p.done() and std.ascii.isDigit(p.peek()) and p.i - start < 3) : (p.i += 1) n = n * 10 + (p.peek() - '0');
        if (p.i == start or n > max) return null;
        return n;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, the sign as written (west positive).
    fn offset(p: *Parser, max_hours: u32) ?i32 {
        var sign: i32 = 1;
        if (p.eat('-')) sign = -1 else _ = p.eat('+');
        var secs: i32 = @intCast(3600 * (p.number(max_hours) orelse return null));
        if (p.eat(':')) {
            secs += @intCast(60 * (p.number(59) orelse return null));
            if (p.eat(':')) secs += @intCast(p.number(59) orelse return null);
        }
        return sign * secs;
    }

    fn ruleDate(p: *Parser) ?RuleDate {
        var r: RuleDate = undefined;
        if (p.eat('J')) {
            const n = p.number(365) orelse return null;
            if (n < 1) return null;
            r = .{ .kind = .{ .julian1 = @intCast(n) } };
        } else if (p.eat('M')) {
            const m = p.number(12) orelse return null;
            if (m < 1 or !p.eat('.')) return null;
            const w = p.number(5) orelse return null;
            if (w < 1 or !p.eat('.')) return null;
            const d = p.number(6) orelse return null;
            r = .{ .kind = .{ .mwd = .{ .m = @intCast(m), .w = @intCast(w), .d = @intCast(d) } } };
        } else {
            r = .{ .kind = .{ .julian0 = @intCast(p.number(365) orelse return null) } };
        }
        if (p.eat('/')) r.time = p.offset(167) orelse return null;
        return r;
    }
};

/// A parsed TZif file. Owns a copy of the bytes; the transition table is
/// read in place (big-endian), so parsing allocates once.
pub const TzInfo = struct {
    data: []u8,
    /// Where each table starts in `data`, and the 64- or 32-bit time width.
    times: usize,
    indices: usize,
    types: usize,
    chars: usize,
    time_size: usize,
    timecnt: usize,
    typecnt: usize,
    charcnt: usize,
    /// The footer's rule for instants after the last transition (v2+).
    footer: ?Posix,

    pub const Error = error{ InvalidTzif, OutOfMemory };

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!TzInfo {
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        var info = try layout(data, 0, 4);
        if (data[4] >= '2') {
            // Skip the v1 block to the 64-bit header and its data.
            const v1_end = try blockEnd(data, 0, info, 8);
            info = try layout(data, v1_end, 8);
            const after = try blockEnd(data, v1_end, info, 12);
            // The footer: "\n" TZ-string "\n" (an empty string means none).
            if (after >= data.len or data[after] != '\n') return error.InvalidTzif;
            const nl = std.mem.indexOfScalarPos(u8, data, after + 1, '\n') orelse return error.InvalidTzif;
            const s = data[after + 1 .. nl];
            if (s.len > 0) info.footer = Posix.parse(s) orelse return error.InvalidTzif;
        }
        info.data = data;
        try info.validate();
        return info;
    }

    pub fn deinit(self: *TzInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
    }

    /// A header count, widened so offset arithmetic cannot wrap on a
    /// 32-bit host (every sum is checked against the length before use).
    fn countAt(data: []const u8, at: usize) u64 {
        return std.mem.readInt(u32, data[at..][0..4], .big);
    }

    /// The table offsets of the header at `at` (whose data follows it).
    fn layout(data: []const u8, at: usize, time_size: usize) Error!TzInfo {
        if (data.len < 44 or at > data.len - 44 or !std.mem.eql(u8, data[at..][0..4], "TZif")) return error.InvalidTzif;
        const timecnt = countAt(data, at + 32);
        const typecnt = countAt(data, at + 36);
        const charcnt = countAt(data, at + 40);
        const times: u64 = at + 44;
        const indices = times + timecnt * time_size;
        const types = indices + timecnt;
        const chars = types + typecnt * 6;
        if (typecnt == 0 or chars + charcnt > data.len) return error.InvalidTzif;
        return .{
            .data = &.{},
            .times = @intCast(times),
            .indices = @intCast(indices),
            .types = @intCast(types),
            .chars = @intCast(chars),
            .time_size = time_size,
            .timecnt = @intCast(timecnt),
            .typecnt = @intCast(typecnt),
            .charcnt = @intCast(charcnt),
            .footer = null,
        };
    }

    /// The end of the data block `info` describes (header at `at`): past the
    /// leap-second records (`leap_size` bytes each) and the two indicator
    /// tables.
    fn blockEnd(data: []const u8, at: usize, info: TzInfo, leap_size: u64) Error!usize {
        const end = @as(u64, info.chars) + info.charcnt + countAt(data, at + 28) * leap_size + countAt(data, at + 24) + countAt(data, at + 20);
        if (end > data.len) return error.InvalidTzif;
        return @intCast(end);
    }

    fn validate(self: *const TzInfo) Error!void {
        for (self.data[self.indices..][0..self.timecnt]) |i| if (i >= self.typecnt) return error.InvalidTzif;
        const chars = self.data[self.chars..][0..self.charcnt];
        for (0..self.typecnt) |t| {
            const rec = self.data[self.types + t * 6 ..][0..6];
            const idx = rec[5];
            if (idx >= self.charcnt) return error.InvalidTzif;
            if (std.mem.indexOfScalarPos(u8, chars, idx, 0) == null) return error.InvalidTzif;
            if (std.mem.readInt(i32, rec[0..4], .big) == std.math.minInt(i32)) return error.InvalidTzif;
        }
        var prev: i64 = std.math.minInt(i64);
        for (0..self.timecnt) |i| {
            const t = self.transition(i);
            if (i > 0 and t <= prev) return error.InvalidTzif;
            prev = t;
        }
    }

    fn transition(self: *const TzInfo, i: usize) i64 {
        const at = self.times + i * self.time_size;
        return if (self.time_size == 8)
            std.mem.readInt(i64, self.data[at..][0..8], .big)
        else
            std.mem.readInt(i32, self.data[at..][0..4], .big);
    }

    fn zoneOfType(self: *const TzInfo, t: usize) Zone {
        const rec = self.data[self.types + t * 6 ..][0..6];
        const chars = self.data[self.chars..][0..self.charcnt];
        const end = std.mem.indexOfScalarPos(u8, chars, rec[5], 0).?;
        return .{ .offset = std.mem.readInt(i32, rec[0..4], .big), .dst = rec[4] != 0, .abbr = chars[rec[5]..end] };
    }

    pub fn lookup(self: *const TzInfo, utc: i64) Zone {
        if (self.timecnt == 0) return if (self.footer) |f| f.lookup(utc) else self.zoneOfType(0);
        // Before the first transition: type 0 (RFC 8536 §3.2).
        if (utc < self.transition(0)) return self.zoneOfType(0);
        if (utc >= self.transition(self.timecnt - 1)) {
            if (self.footer) |f| return f.lookup(utc);
        }
        // The last transition at or before `utc`.
        var lo: usize = 0;
        var hi: usize = self.timecnt;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.transition(mid) <= utc) lo = mid else hi = mid;
        }
        return self.zoneOfType(self.data[self.indices + lo]);
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectZone(expected: Zone, got: Zone) !void {
    try testing.expectEqual(expected.offset, got.offset);
    try testing.expectEqual(expected.dst, got.dst);
    try testing.expectEqualStrings(expected.abbr, got.abbr);
}

const cet: Zone = .{ .offset = 3600, .dst = false, .abbr = "CET" };
const cest: Zone = .{ .offset = 7200, .dst = true, .abbr = "CEST" };

fn utcAt(y: i64, m: i64, d: i64, h: i64) i64 {
    return datetime.secondsOf(.{ .year = y, .month = m, .day = d, .hour = h, .min = 0, .sec = 0 });
}

test "POSIX TZ: a northern-hemisphere rule switches at the right instants" {
    const tz = Posix.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    // 2024: summer time from 2024-03-31 01:00 UTC to 2024-10-27 01:00 UTC.
    const start = utcAt(2024, 3, 31, 1);
    const end = utcAt(2024, 10, 27, 1);
    try expectZone(cet, tz.lookup(start - 1));
    try expectZone(cest, tz.lookup(start));
    try expectZone(cest, tz.lookup(end - 1));
    try expectZone(cet, tz.lookup(end));
    try expectZone(cet, tz.lookup(utcAt(2024, 1, 1, 0)));
}

test "POSIX TZ: a southern-hemisphere rule wraps the year" {
    const tz = Posix.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try expectZone(.{ .offset = 11 * 3600, .dst = true, .abbr = "AEDT" }, tz.lookup(utcAt(2024, 1, 15, 0)));
    try expectZone(.{ .offset = 10 * 3600, .dst = false, .abbr = "AEST" }, tz.lookup(utcAt(2024, 7, 15, 0)));
    // 2024-04-07 03:00 AEDT = 2024-04-06 16:00 UTC ends summer time.
    const end = utcAt(2024, 4, 6, 16);
    try testing.expect(tz.lookup(end - 1).dst);
    try testing.expect(!tz.lookup(end).dst);
}

test "POSIX TZ: forms without daylight saving, quoted names, defaults" {
    try expectZone(.{ .offset = 0, .dst = false, .abbr = "UTC" }, Posix.parse("UTC0").?.lookup(0));
    try expectZone(.{ .offset = 5 * 3600 + 1800, .dst = false, .abbr = "+0530" }, Posix.parse("<+0530>-5:30").?.lookup(0));
    try expectZone(.{ .offset = -(3 * 3600), .dst = false, .abbr = "-03" }, Posix.parse("<-03>3").?.lookup(0));
    // EST5EDT with no rule: the US rule, 2nd Sunday of March to 1st of November.
    const us = Posix.parse("EST5EDT").?;
    try expectZone(.{ .offset = -4 * 3600, .dst = true, .abbr = "EDT" }, us.lookup(utcAt(2024, 7, 1, 0)));
    try expectZone(.{ .offset = -5 * 3600, .dst = false, .abbr = "EST" }, us.lookup(utcAt(2024, 12, 1, 0)));
    // All-year daylight saving (RFC 8536's example).
    try testing.expect(Posix.parse("EST5EDT,0/0,J365/25").?.lookup(utcAt(2024, 12, 31, 12)).dst);
    // Julian day 60 is March 1 in every year for Jn.
    const j: RuleDate = .{ .kind = .{ .julian1 = 60 } };
    try testing.expectEqual(datetime.daysFromCivil(2024, 3, 1) * 86400 + 7200, j.localSeconds(2024));
    for ([_][]const u8{ "", "U0", "UTC", "UTC0X", "CET-1CEST,M3.5.0", "CET-1CEST,M13.1.0,M10.5.0", "<AB>1", "UTC25" }) |bad|
        try testing.expect(Posix.parse(bad) == null);
}

const TypeSpec = struct { off: i32, dst: bool, abbr: []const u8 };

fn putCounts(o: *std.ArrayList(u8), g: std.mem.Allocator, counts: [6]u32) !void {
    try o.appendSlice(g, "TZif2");
    try o.appendNTimes(g, 0, 15);
    for (counts) |c| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, c, .big);
        try o.appendSlice(g, &b);
    }
}

/// A minimal TZif v2 file: a v1 block with one type and no transitions, and
/// a v2 block with the given transitions, types and footer.
fn buildTzif(gpa: std.mem.Allocator, times: []const i64, idx: []const u8, types: []const TypeSpec, footer: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chars: std.ArrayList(u8) = .empty;
    defer chars.deinit(gpa);
    var abbr_at: [8]u8 = undefined;
    for (types, 0..) |t, i| {
        abbr_at[i] = @intCast(chars.items.len);
        try chars.appendSlice(gpa, t.abbr);
        try chars.append(gpa, 0);
    }
    try putCounts(&out, gpa, .{ 0, 0, 0, 0, 1, 1 });
    try out.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0, 0 });
    try putCounts(&out, gpa, .{ 0, 0, 0, @intCast(times.len), @intCast(types.len), @intCast(chars.items.len) });
    for (times) |t| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, t, .big);
        try out.appendSlice(gpa, &b);
    }
    try out.appendSlice(gpa, idx);
    for (types, 0..) |t, i| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, t.off, .big);
        try out.appendSlice(gpa, &b);
        try out.append(gpa, @intFromBool(t.dst));
        try out.append(gpa, abbr_at[i]);
    }
    try out.appendSlice(gpa, chars.items);
    try out.append(gpa, '\n');
    try out.appendSlice(gpa, footer);
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

test "TZif: transitions, the time before the first, and the footer after the last" {
    const gpa = testing.allocator;
    // LMT until 1900, then CET, CEST and CET again in 2000, then the footer.
    const t1900 = utcAt(1900, 1, 1, 0);
    const s2000 = utcAt(2000, 3, 26, 1);
    const e2000 = utcAt(2000, 10, 29, 1);
    const bytes = try buildTzif(gpa, &.{ t1900, s2000, e2000 }, &.{ 1, 2, 1 }, &.{
        .{ .off = 1172, .dst = false, .abbr = "LMT" },
        .{ .off = 3600, .dst = false, .abbr = "CET" },
        .{ .off = 7200, .dst = true, .abbr = "CEST" },
    }, "CET-1CEST,M3.5.0,M10.5.0/3");
    defer gpa.free(bytes);
    var tz = try TzInfo.parse(gpa, bytes);
    defer tz.deinit(gpa);
    try expectZone(.{ .offset = 1172, .dst = false, .abbr = "LMT" }, tz.lookup(t1900 - 1));
    try expectZone(cet, tz.lookup(t1900));
    try expectZone(cest, tz.lookup(s2000));
    try expectZone(cest, tz.lookup(e2000 - 1));
    try expectZone(cet, tz.lookup(e2000));
    // 2024 comes from the footer.
    try expectZone(cest, tz.lookup(utcAt(2024, 7, 1, 0)));
    try expectZone(cet, tz.lookup(utcAt(2024, 12, 1, 0)));
}

test "TZif: malformed files are refused, never read past their end" {
    const gpa = testing.allocator;
    const good = try buildTzif(gpa, &.{0}, &.{0}, &.{.{ .off = 0, .dst = false, .abbr = "UTC" }}, "UTC0");
    defer gpa.free(good);
    var ok = try TzInfo.parse(gpa, good);
    ok.deinit(gpa);
    // Every truncation is refused.
    for (0..good.len) |n| try testing.expectError(error.InvalidTzif, TzInfo.parse(gpa, good[0..n]));
    // A transition naming a type that does not exist.
    const bad_idx = try buildTzif(gpa, &.{0}, &.{1}, &.{.{ .off = 0, .dst = false, .abbr = "UTC" }}, "");
    defer gpa.free(bad_idx);
    try testing.expectError(error.InvalidTzif, TzInfo.parse(gpa, bad_idx));
    // Transitions out of order.
    const unordered = try buildTzif(gpa, &.{ 10, 5 }, &.{ 0, 0 }, &.{.{ .off = 0, .dst = false, .abbr = "UTC" }}, "");
    defer gpa.free(unordered);
    try testing.expectError(error.InvalidTzif, TzInfo.parse(gpa, unordered));
}
