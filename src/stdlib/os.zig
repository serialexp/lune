//! The `os` library's host operations (doc 65 Phase 4): the wall clock and
//! dates, removing and renaming files, temporary names, and `os.exit`.
//! (`os.clock`, `os.nsclock` and `os.getenv` are interpreter natives;
//! `os.difftime` is pure, in `basic.zig`.)
//!
//! Each host call is one effect (doc 65 §4.2), as in `io.zig`: `off`/`record`
//! ask the host, `record` logs the answer, `replay` takes it from the log.
//! Dates are pure arithmetic over two host inputs (§8): the instant
//! (`wall_clock`) and the local zone at an instant (`local_zone`, its offset,
//! whether daylight saving is in effect, and its abbreviation). Formatting is
//! `datetime.zig`, in the C locale, so a date reads the same on every machine.
//!
//! `os.exit` is not an input and logs nothing (§7): it sets `Vm.exit_status`
//! and unwinds as the non-catchable `Error.Exit`, which the CLI turns into the
//! process status and the C API into `MH_EXIT`.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const system = @import("../system.zig");
const table = @import("../table.zig");
const datetime = @import("../datetime.zig");
const io = @import("io.zig");
const string = @import("string.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Table = table.Table;
const ErrorClass = system.ErrorClass;
const Zone = datetime.Zone;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// Argument `i` (0-based) as string bytes.
fn strArg(vm: *Vm, args: []const Value, i: usize) anyerror![]const u8 {
    if (i >= args.len) return vm.badArg(i + 1, "string", null);
    return interp.strBytes(args[i]) orelse vm.badArg(i + 1, "string", args[i]);
}

// ---------------------------------------------------------------------------
// Host inputs: the instant and the zone
// ---------------------------------------------------------------------------

/// The wall clock, in whole seconds since the epoch: the `wall_clock` effect.
/// A host that enabled the time group without a clock behind it is an
/// embedding error, like a missing `Vm.clock`.
fn wallSeconds(vm: *Vm) anyerror!i64 {
    if (vm.effect_mode == .replay) return switch (try interp.replayHost(vm, .wall_clock)) {
        .value => |v| if (v.isInt()) v.asInt() else error.EffectKindMismatch,
        else => error.EffectKindMismatch,
    };
    const sys = vm.system orelse return error.ClockUnavailable;
    const now = sys.vtable.wallSeconds orelse return error.ClockUnavailable;
    const t = now(sys.ctx);
    try interp.recordHost(vm, .wall_clock, .{ .value = Value.int(t) });
    return t;
}

/// A zone whose abbreviation lives in a caller-owned buffer, so it outlives
/// the host's and the log's memory.
const ZoneBuf = struct {
    rec: [system.max_local_zone_len]u8 = undefined,
    zone: Zone = Zone.utc,
};

/// The local zone at `utc`: the `local_zone` effect. A host without
/// `localZone` is in UTC. The abbreviation is program-visible (`%Z`), so
/// it is cut to `max_abbr_len` and to valid UTF-8 before it is logged (S-B);
/// a replayed one that is not valid UTF-8 was not written by this recorder.
fn zoneAt(vm: *Vm, utc: i64, zb: *ZoneBuf) anyerror!Zone {
    if (vm.effect_mode == .replay) {
        const rec = switch (try interp.replayHost(vm, .local_zone)) {
            .bytes => |span| vm.effect_log.bytesOf(span),
            else => return error.EffectKindMismatch,
        };
        if (rec.len > zb.rec.len or !std.unicode.utf8ValidateSlice(rec[system.local_zone_fixed_len..]))
            return error.EffectKindMismatch;
        @memcpy(zb.rec[0..rec.len], rec);
        zb.zone = system.decodeLocalZone(zb.rec[0..rec.len]);
        return zb.zone;
    }
    var live: Zone = Zone.utc;
    if (vm.system) |sys| if (sys.vtable.localZone) |lz| {
        live = lz(sys.ctx, utc);
    };
    var abbr = live.abbr[0..@min(live.abbr.len, system.max_abbr_len)];
    while (!std.unicode.utf8ValidateSlice(abbr)) abbr = abbr[0 .. abbr.len - 1];
    live.abbr = abbr;
    const rec = system.encodeLocalZone(live, &zb.rec);
    try interp.recordHostBytes(vm, .local_zone, rec);
    zb.zone = system.decodeLocalZone(rec);
    return zb.zone;
}

/// Half a (Julian) year of seconds: `localToUtc`'s probe step.
const half_year: i64 = (365 * datetime.seconds_per_day + datetime.seconds_per_day / 4) / 2;

/// The UTC instant of local wall time `wall` (seconds, as if UTC), the way
/// C's `mktime` reads it. The offset at `wall` itself is a guess (the wall
/// time is not an instant); the offset at the instant that guess gives is the
/// answer, which is exact away from a zone change and picks one side of a
/// gap or an overlap at one. When the table asked for daylight saving to be
/// on or off (`isdst`) and the zone at the result disagrees, the wall time is
/// read in the offset of an instant with the requested state, as glibc does.
/// glibc steps a week at a time for the nearest such instant, up to about
/// 7.2 years either way (up to ~760 lookups, each of which would be a logged
/// effect here); this looks every half year out to 7 years either side,
/// nearest first, so summers and winters alternate, then, like glibc when
/// its search finds nothing, assumes daylight saving is one hour. The two
/// agree wherever the nearest instant with the requested state has the
/// offset of the first probe that finds one, which holds for every zone's
/// current rules; a mismatched request costs at most 28 lookups.
///
/// `zb` ends holding the zone at the returned instant when `.known` says so
/// (the usual case: the guess was right), saving the caller that lookup.
fn localToUtc(vm: *Vm, wall: i64, isdst: ?bool, zb: *ZoneBuf) anyerror!struct { utc: i64, known: bool } {
    const guess = wall - (try zoneAt(vm, wall, zb)).offset;
    const z = try zoneAt(vm, guess, zb);
    const utc = wall - z.offset;
    const want = isdst orelse return .{ .utc = utc, .known = utc == guess };
    if (z.dst == want) return .{ .utc = utc, .known = utc == guess };
    for (1..15) |k| {
        const d = @as(i64, @intCast(k)) * half_year;
        for ([_]i64{ utc - d, utc + d }) |probe| {
            const other = try zoneAt(vm, probe, zb);
            if (other.dst == want) return .{ .utc = wall - other.offset, .known = false };
        }
    }
    // Wanted standard time and got daylight saving: an hour later; the
    // reverse, an hour earlier.
    return .{ .utc = if (want) utc - 3600 else utc + 3600, .known = false };
}

// ---------------------------------------------------------------------------
// Date tables
// ---------------------------------------------------------------------------

/// Write the fields of `tm` into `t`, as Lua's `setallfields` does: the
/// eight numbers and `isdst`.
fn setAllFields(vm: *Vm, t: *Table, tm: datetime.Tm, isdst: bool) anyerror!void {
    const fields = [_]struct { []const u8, i64 }{
        .{ "year", tm.year },
        .{ "month", tm.month },
        .{ "day", tm.day },
        .{ "hour", tm.hour },
        .{ "min", tm.min },
        .{ "sec", tm.sec },
        .{ "yday", @as(i64, tm.yday) + 1 },
        .{ "wday", @as(i64, tm.wday) + 1 },
    };
    for (fields) |f| try t.set(vm.gpa, try vm.heap.internValue(f[0]), Value.int(f[1]));
    try t.set(vm.gpa, try vm.heap.internValue("isdst"), Value.boolean(isdst));
}

/// Lua's `getfield`: field `key` of a date table as an integer that fits a C
/// `int` once `delta` is taken off (`year - 1900`, `month - 1`), or `default`
/// when absent (null: required).
fn getField(vm: *Vm, t: *Table, comptime key: []const u8, default: ?i64, delta: i64) anyerror!i64 {
    const v = t.get(try vm.heap.internValue(key));
    const n: i64 = if (v.isInt())
        v.asInt()
    else if (v.isFloat() and value.floatAsExactInt(v.asFloat()) != null)
        value.floatAsExactInt(v.asFloat()).?
    else if (v.isNil())
        return default orelse vm.raiseLocatedError("field '" ++ key ++ "' missing in date table", 1)
    else
        return vm.raiseLocatedError("field '" ++ key ++ "' is not an integer", 1);
    const in_range = if (n >= 0) n - delta <= std.math.maxInt(i32) else std.math.minInt(i32) + delta <= n;
    if (!in_range) return vm.raiseLocatedError("field '" ++ key ++ "' is out-of-bound", 1);
    return n;
}

// ---------------------------------------------------------------------------
// os.time / os.date
// ---------------------------------------------------------------------------

/// `os.time([t])`: now, or the instant date table `t` names in local time.
/// The table's fields are normalized in place, as C's `mktime` does.
fn osTimeN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    if (args.len == 0 or args[0].isNil()) return io.putResults(out, &.{Value.int(try wallSeconds(vm))});
    const tv = args[0];
    if (!tv.isHeap() or tv.heapType() != .table) return vm.badArg(1, "table", tv);
    const t = Table.fromHeader(tv.asHeap());
    const f: datetime.Fields = .{
        .year = try getField(vm, t, "year", null, 1900),
        .month = try getField(vm, t, "month", null, 1),
        .day = try getField(vm, t, "day", null, 0),
        .hour = try getField(vm, t, "hour", 12, 0),
        .min = try getField(vm, t, "min", 0, 0),
        .sec = try getField(vm, t, "sec", 0, 0),
    };
    const isdst_v = t.get(try vm.heap.internValue("isdst"));
    const isdst: ?bool = if (isdst_v.isNil()) null else isdst_v.isTruthy();
    const wall = datetime.secondsOf(f);
    // The normalized year must fit a C `tm_year`, or `mktime` fails.
    if (!datetime.yearRepresentable(datetime.breakDown(wall).year))
        return vm.raiseLocatedError("time result cannot be represented in this installation", 1);
    var zb: ZoneBuf = .{};
    const r = try localToUtc(vm, wall, isdst, &zb);
    const utc = r.utc;
    const zone = if (r.known) zb.zone else try zoneAt(vm, utc, &zb);
    const tm = datetime.breakDown(utc + zone.offset);
    if (!datetime.yearRepresentable(tm.year))
        return vm.raiseLocatedError("time result cannot be represented in this installation", 1);
    try setAllFields(vm, t, tm, zone.dst);
    return io.putResults(out, &.{Value.int(utc)});
}

/// `os.date([format [, time]])`: `time` (default now) formatted in local
/// time, or in UTC after a leading `!`. `*t` returns the fields as a table;
/// otherwise each `%` conversion is C's `strftime`, in the C locale.
fn osDateN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    var fmt: []const u8 = if (args.len >= 1 and !args[0].isNil()) try strArg(vm, args, 0) else "%c";
    const t: i64 = if (args.len >= 2 and !args[1].isNil())
        try vm.optIntArg(args, 1, 0)
    else
        try wallSeconds(vm);
    // The year must fit a C `tm_year` in UTC before the host is asked for a
    // zone at an instant it cannot represent.
    if (!datetime.yearRepresentable(datetime.breakDown(t).year))
        return vm.raiseLocatedError("date result cannot be represented in this installation", 1);
    var zb: ZoneBuf = .{};
    const zone: Zone = if (fmt.len > 0 and fmt[0] == '!') blk: {
        fmt = fmt[1..];
        break :blk Zone.utc;
    } else try zoneAt(vm, t, &zb);
    const tm = datetime.breakDown(t + zone.offset);
    if (!datetime.yearRepresentable(tm.year))
        return vm.raiseLocatedError("date result cannot be represented in this installation", 1);

    if (std.mem.eql(u8, fmt, "*t")) {
        const tt = try vm.heap.newTableSized(9);
        try setAllFields(vm, tt, tm, zone.dst);
        return io.putResults(out, &.{Value.heap(&tt.header)});
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(vm.gpa);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try text.append(vm.gpa, fmt[i]);
            i += 1;
            continue;
        }
        const rest = fmt[i + 1 ..];
        const n = datetime.checkSpec(rest) orelse {
            const reason = try std.fmt.allocPrint(vm.gpa, "invalid conversion specifier '%{s}'", .{rest});
            defer vm.gpa.free(reason);
            return vm.badArgReason(1, reason);
        };
        try datetime.formatSpec(vm.gpa, &text, rest[0..n], tm, zone);
        i += 1 + n;
    }
    return io.putResults(out, &.{try vm.heap.internValue(text.items)});
}

// ---------------------------------------------------------------------------
// Files by name
// ---------------------------------------------------------------------------

/// `os.remove(filename)`: delete a file or an empty directory.
fn osRemoveN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const path = try strArg(vm, args, 0);
    try interp.noteIoErrorMode(vm);
    const err = try io.control(vm, .fs_mutate, struct {
        path: []const u8,
        pub fn run(self: @This(), v: *Vm) anyerror!?ErrorClass {
            const sys = v.system orelse return .other;
            const remove = sys.vtable.remove orelse return .other;
            return remove(sys.ctx, self.path);
        }
    }{ .path = path });
    if (err) |c| return io.failWith(vm, out, "remove", .{ .path = path }, c, false);
    return io.putResults(out, &.{Value.boolean(true)});
}

/// `os.rename(oldname, newname)`.
fn osRenameN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const from = try strArg(vm, args, 0);
    const to = try strArg(vm, args, 1);
    try interp.noteIoErrorMode(vm);
    const err = try io.control(vm, .fs_mutate, struct {
        from: []const u8,
        to: []const u8,
        pub fn run(self: @This(), v: *Vm) anyerror!?ErrorClass {
            const sys = v.system orelse return .other;
            const rename = sys.vtable.rename orelse return .other;
            return rename(sys.ctx, self.from, self.to);
        }
    }{ .from = from, .to = to });
    if (err) |c| return io.failWith(vm, out, "rename", .{ .path = from }, c, false);
    return io.putResults(out, &.{Value.boolean(true)});
}

/// `os.tmpname()`: the name of a new, empty file in the temporary directory
/// (created, so no other program takes the name). Raises on failure in both
/// error modes, as Lua's does.
fn osTmpnameN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    _ = args;
    const vm = vmOf(ctx);
    const name: Value = switch (vm.effect_mode) {
        .replay => switch (try interp.replayHost(vm, .fs_tmpname)) {
            .value => |v| if (interp.strBytes(v) != null) v else return error.EffectKindMismatch,
            .fail => return vm.raiseLocatedError("unable to generate a unique filename", 1),
            .bytes => return error.EffectKindMismatch,
        },
        .off, .record => blk: {
            const r: system.Result([]const u8) = if (vm.system) |sys|
                if (sys.vtable.tmpname) |tmp| tmp(sys.ctx) else .{ .fail = .other }
            else
                .{ .fail = .other };
            // A name that is not UTF-8 cannot become a string (S-B); the
            // program sees the same failure as a host that made none.
            const ok: ?[]const u8 = switch (r) {
                .ok => |s| if (std.unicode.utf8ValidateSlice(s)) s else null,
                .fail => null,
            };
            const v: ?Value = if (ok) |s| try vm.heap.internValue(s) else null;
            try interp.recordHost(vm, .fs_tmpname, if (v) |vv| .{ .value = vv } else .{ .fail = switch (r) {
                .fail => |c| c,
                .ok => .not_utf8,
            } });
            break :blk v orelse return vm.raiseLocatedError("unable to generate a unique filename", 1);
        },
    };
    return io.putResults(out, &.{name});
}

// ---------------------------------------------------------------------------
// os.exit
// ---------------------------------------------------------------------------

/// `os.exit([code [, close]])`: end the program with `code` (`true` is 0,
/// `false` 1, an integer as given; default 0). `close` is accepted and has
/// nothing to do: the CLI closes every file at teardown either way, and an
/// embedded VM is never closed by the program it runs.
fn osExitN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    _ = out;
    const vm = vmOf(ctx);
    const code: i64 = if (args.len >= 1 and args[0].isBool())
        @intFromBool(!args[0].asBool())
    else
        try vm.optIntArg(args, 0, 0);
    // C's `exit` takes an `int`.
    vm.exit_status = @truncate(code);
    return error.Exit;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

fn entry(comptime name: []const u8, comptime core: function.NativeMultiFn, comptime field: []const u8, comptime groups: system.Groups) function.BaseNative {
    return .{ .name = name, .func = io.single(core), .multi = core, .module = "os", .field = field, .groups = groups };
}

pub const natives = [_]function.BaseNative{
    entry("os.time", &osTimeN, "time", .{ .time = true }),
    entry("os.date", &osDateN, "date", .{ .time = true }),
    entry("os.remove", &osRemoveN, "remove", .{ .files = true }),
    entry("os.rename", &osRenameN, "rename", .{ .files = true }),
    entry("os.tmpname", &osTmpnameN, "tmpname", .{ .files = true }),
    entry("os.exit", &osExitN, "exit", .{ .env = true }),
};
