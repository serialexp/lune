//! Tests for the `os` library (doc 65 Phase 4): dates in a local zone and in
//! UTC, `mktime`'s normalization, the date-table errors, removing and
//! renaming files, temporary names, `os.exit`, and the record/replay
//! contract — a replay reproduces every date and file result with no host.
//! `FakeHost` (`interp_testutil.zig`) stands in for the OS, with a POSIX
//! `TZ` rule for its zone, so the expected text is what `lua5.4` prints
//! under the same `TZ`.

const std = @import("std");
const interp = @import("interp.zig");
const io = @import("io.zig");
const system = @import("system.zig");
const tzif = @import("tzif.zig");
const effectser = @import("effectser.zig");
const testing = std.testing;

const Vm = interp.Vm;
const EffectKind = interp.EffectKind;
const EffectMode = interp.EffectMode;
const util = @import("interp_testutil.zig");
const FakeHost = util.FakeHost;
const compileRun = util.compileRun;

/// Central European time, as glibc reads `TZ=CET-1CEST,M3.5.0,M10.5.0/3`.
const cet = "CET-1CEST,M3.5.0,M10.5.0/3";

const Run = struct {
    out: []u8,
    log: []u8,
    kinds: []EffectKind,
    /// `Error.Exit` ended the run, with this status.
    exit: ?i32,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.log);
        gpa.free(self.kinds);
    }
};

const RunOpts = struct {
    host: ?*FakeHost = null,
    mode: EffectMode = .off,
    log: []const u8 = "",
    io_errors: system.IoErrors = .raise,
    groups: system.Groups = .{ .files = true, .env = true, .time = true },
};

/// Run `source` in a fresh VM; an `os.exit` is a result, not a failure.
fn run(gpa: std.mem.Allocator, opts: RunOpts, source: [:0]const u8) !Run {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = io.Writer.fixed(&out_buf);
    vm.out = &out;
    try vm.enableSystem(opts.groups);
    if (opts.host) |h| vm.system = h.system();
    vm.io_errors = opts.io_errors;
    if (opts.mode == .replay) try effectser.decodeInto(&vm.effect_log, gpa, vm.heap, opts.log);
    vm.effect_mode = opts.mode;
    var exit: ?i32 = null;
    compileRun(gpa, &vm, source) catch |e| {
        if (e != error.Exit) return e;
        // `run` unwound the stack: the VM is idle, as after a finished run.
        try testing.expectEqual(@as(u32, 0), vm.depth);
        exit = vm.exit_status;
    };
    if (opts.mode == .replay) try testing.expectEqual(vm.effect_log.entries.items.len, vm.effect_cursor);
    const kinds = try gpa.alloc(EffectKind, vm.effect_log.entries.items.len);
    errdefer gpa.free(kinds);
    for (vm.effect_log.entries.items, kinds) |e, *k| k.* = e.kind;
    return .{
        .out = try gpa.dupe(u8, out.buffered()),
        .log = if (opts.mode == .record) try effectser.encodeFile(gpa, &vm.effect_log) else try gpa.dupe(u8, ""),
        .kinds = kinds,
        .exit = exit,
    };
}

fn expectOut(host: *FakeHost, source: [:0]const u8, expected: []const u8) !void {
    const r = try run(testing.allocator, .{ .host = host }, source);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(expected, r.out);
}

/// Record against `host`, replay with no host: the outputs and the exit
/// must match, and the replay must not call the host.
fn recordReplay(gpa: std.mem.Allocator, host: *FakeHost, opts: RunOpts, source: [:0]const u8) !Run {
    var rec_opts = opts;
    rec_opts.host = host;
    rec_opts.mode = .record;
    const rec = try run(gpa, rec_opts, source);
    errdefer rec.deinit(gpa);
    const calls = host.calls;
    var rep_opts = opts;
    rep_opts.host = null;
    rep_opts.mode = .replay;
    rep_opts.log = rec.log;
    const rep = try run(gpa, rep_opts, source);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqual(rec.exit, rep.exit);
    try testing.expectEqual(calls, host.calls);
    return rec;
}

test "os: os.time and os.date read the host clock and zone" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.now = 1_700_000_000;
    host.tz = tzif.Posix.parse(cet).?;
    try expectOut(&host,
        \\print(os.time())
        \\print(os.date("%Y-%m-%d %H:%M:%S %Z %z"))
        \\print(os.date("!%Y-%m-%d %H:%M:%S %Z %z"))
        \\print(os.date("%c", 1690000000))
        \\local t = os.date("*t", 1690000000)
        \\print(t.year, t.month, t.day, t.hour, t.min, t.sec, t.yday, t.wday, t.isdst)
        \\local g = os.date("!*t", 1690000000)
        \\print(g.hour, g.isdst)
        \\print(os.date())
    , "1700000000\n2023-11-14 23:13:20 CET +0100\n2023-11-14 22:13:20 GMT +0000\n" ++
        "Sat Jul 22 06:26:40 2023\n2023\t7\t22\t6\t26\t40\t203\t7\ttrue\n4\tfalse\n" ++
        "Tue Nov 14 23:13:20 2023\n");
}

test "os: os.time(t) reads local wall time like mktime and normalizes the table" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.tz = tzif.Posix.parse(cet).?;
    try expectOut(&host,
        \\local u = {year=2024, month=14, day=-3, hour=25}
        \\print(os.time(u), u.year, u.month, u.day, u.hour, u.min, u.sec, u.yday, u.wday, u.isdst)
        \\print(os.time({year=2024, month=7, day=1}))
        \\print(os.time({year=2024, month=3, day=31, hour=2, min=30}))
        \\print(os.time({year=2024, month=10, day=27, hour=2, min=30}))
        \\print(os.time({year=2024, month=7, day=1, isdst=false}))
        \\print(os.time({year=2024, month=1, day=1, isdst=true}))
        \\print(os.time({year=1900, month=1, day=1, hour=0}))
    , "1738108800\t2025\t1\t29\t1\t0\t0\t29\t4\tfalse\n" ++
        "1719828000\n1711848600\n1729992600\n1719831600\n1704103200\n-2208992400\n");
}

test "os: a UTC host needs no zone, and an abbreviation is any UTF-8" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.tz = tzif.Posix.parse("<+0530>-5:30").?;
    try expectOut(&host,
        \\print(os.date("%H:%M %Z %z", 0))
        \\print(os.time({year=1970, month=1, day=1, hour=5, min=30}))
    , "05:30 +0530 +0530\n0\n");
}

test "os: date tables and formats are checked as Lua checks them" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try expectOut(&host,
        \\print(pcall(function() return os.time({day=1}) end))
        \\print(pcall(function() return os.time({year=2000, month=1, day=1.5}) end))
        \\print(pcall(function() return os.time({year=2000, month=1, day=2^40}) end))
        \\print(pcall(function() return os.time({year=2000, month="x", day=1}) end))
        \\print(pcall(function() return os.time({year=2^31 + 1899, month=13, day=1}) end))
        \\print(pcall(function() return os.time(5) end))
        \\print(pcall(function() return os.date("%Q") end))
        \\print(pcall(function() return os.date("%Ex %E") end))
        \\print(pcall(function() return os.date("*t", 1.5) end))
        \\print(pcall(function() return os.date("!%c", 2^60) end))
        \\print(os.time({year=2000, month=1, day=1, hour=0.0}))
    , "false\tanonymous:1: field 'year' missing in date table\n" ++
        "false\tanonymous:2: field 'day' is not an integer\n" ++
        "false\tanonymous:3: field 'day' is out-of-bound\n" ++
        "false\tanonymous:4: field 'month' is not an integer\n" ++
        "false\tanonymous:5: time result cannot be represented in this installation\n" ++
        "false\tanonymous:6: bad argument #1 to 'time' (table expected, got number)\n" ++
        "false\tanonymous:7: bad argument #1 to 'date' (invalid conversion specifier '%Q')\n" ++
        "false\tanonymous:8: bad argument #1 to 'date' (invalid conversion specifier '%E')\n" ++
        "false\tanonymous:9: bad argument #2 to 'date' (number has no integer representation)\n" ++
        "false\tanonymous:10: date result cannot be represented in this installation\n" ++
        "946684800\n");
}

test "os: remove, rename and tmpname, failures in both error modes" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try host.put("a.txt", "A");
    host.locked = &.{"locked.txt"};
    try expectOut(&host,
        \\print(os.rename("a.txt", "b.txt"))
        \\print(io.open("b.txt"):read("a"))
        \\print(os.remove("b.txt"))
        \\print(pcall(os.remove, "b.txt"))
        \\print(pcall(os.rename, "b.txt", "c.txt"))
        \\print(pcall(os.remove, "locked.txt"))
        \\local n = os.tmpname()
        \\print(n, io.open(n):read("a"))
        \\print(os.remove(n))
    , "true\nA\ntrue\nfalse\tcannot remove 'b.txt': not found\n" ++
        "false\tcannot rename 'b.txt': not found\n" ++
        "false\tcannot remove 'locked.txt': permission denied\n" ++
        "/tmp/lua_1\t\ntrue\n");
    try testing.expect(host.contentOf("a.txt") == null);
    const r = try run(testing.allocator, .{ .host = &host, .io_errors = .lua },
        \\print(os.remove("nope"))
        \\print(os.rename("nope", "x"))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\tcannot remove 'nope': not found\t1\nnil\tcannot rename 'nope': not found\t1\n", r.out);
}

test "os: every host input records and replays with no host" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.now = 1_700_000_000;
    host.tz = tzif.Posix.parse(cet).?;
    try host.put("a.txt", "A");
    const r = try recordReplay(testing.allocator, &host, .{},
        \\print(os.time(), os.date("%c %Z"), os.date("!%c"))
        \\print(os.time({year=2024, month=10, day=27, hour=2, min=30, isdst=false}))
        \\print(os.rename("a.txt", "b.txt"), pcall(os.remove, "a.txt"))
        \\local n = os.tmpname()
        \\print(n, os.remove(n))
        \\os.exit(3)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("1700000000\tTue Nov 14 23:13:20 2023 CET\tTue Nov 14 22:13:20 2023\n" ++
        "1729992600\ntrue\tfalse\tcannot remove 'a.txt': not found\n/tmp/lua_1\ttrue\n", r.out);
    try testing.expectEqual(@as(?i32, 3), r.exit);
    var seen: std.EnumSet(EffectKind) = .empty;
    for (r.kinds) |k| seen.insert(k);
    for ([_]EffectKind{ .wall_clock, .local_zone, .fs_mutate, .fs_tmpname, .io_error_mode }) |k|
        try testing.expect(seen.contains(k));
}

test "os: os.exit ends the run with its status, and pcall cannot stop it" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const cases = [_]struct { src: [:0]const u8, status: i32 }{
        .{ .src = "os.exit()", .status = 0 },
        .{ .src = "os.exit(true)", .status = 0 },
        .{ .src = "os.exit(false)", .status = 1 },
        .{ .src = "os.exit(300)", .status = 300 },
        .{ .src = "os.exit(-1, true)", .status = -1 },
        .{ .src = "os.exit(7.0)", .status = 7 },
    };
    for (cases) |c| {
        const r = try run(testing.allocator, .{ .host = &host }, c.src);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(?i32, c.status), r.exit);
    }
    const r = try run(testing.allocator, .{ .host = &host },
        \\local x = 1
        \\local function get() return x end
        \\print(pcall(function() print("in"); os.exit(4) end))
        \\print("not reached")
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("in\n", r.out);
    try testing.expectEqual(@as(?i32, 4), r.exit);
    const bad = try run(testing.allocator, .{ .host = &host }, "print(pcall(os.exit, 'x'))");
    defer bad.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tbad argument #1 to 'exit' (number expected, got string)\n", bad.out);
}

fn enableEnv(vm: *Vm) anyerror!void {
    try vm.enableSystem(.{ .env = true });
}

test "os: os.exit from a hot loop ends the run in every trace mode" {
    const source =
        \\local function f(i) if i == 300 then os.exit(9) end return i end
        \\local s = 0
        \\for i = 1, 1000 do s = s + f(i) end
        \\print(s)
    ;
    for (std.enums.values(util.TraceMode)) |mode| {
        var buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        try testing.expectError(error.Exit, util.runCapturedTuned(testing.allocator, source, &sink, false, mode, .{ .setup = &enableEnv }));
        try testing.expectEqualStrings("", sink.buffered());
    }
}

test "os: calling a member of a group that is off says which interface it needs" {
    const r = try run(testing.allocator, .{ .groups = .{ .clock = true } },
        \\print(pcall(function() io.open("x") end))
        \\print(pcall(function() return os.date() end))
        \\print(pcall(function() return io.stdin:read() end))
        \\print(pcall(function() return io.read() end))
        \\print(pcall(function() os.exit(1) end))
        \\print(pcall(function() return io.nope() end))
    );
    defer r.deinit(testing.allocator);
    const tail = ", which this VM does not have)\n";
    try testing.expectEqualStrings(
        "false\tanonymous:1: attempt to call a nil value (field 'open'; io.open needs the 'files' system interface" ++ tail ++
            "false\tanonymous:2: attempt to call a nil value (field 'date'; os.date needs the 'time' system interface" ++ tail ++
            "false\tanonymous:3: attempt to index a nil value (field 'stdin'; io.stdin needs the 'stdio' system interface" ++ tail ++
            "false\tanonymous:4: attempt to call a nil value (field 'read'; io.read needs the 'files' or 'stdio' system interface" ++ tail ++
            "false\tanonymous:5: attempt to call a nil value (field 'exit'; os.exit needs the 'env' system interface" ++ tail ++
            "false\tanonymous:6: attempt to call a nil value (field 'nope')\n",
        r.out,
    );
    // With the group on, a member the program removed is just missing.
    const removed = try run(testing.allocator, .{}, "io.open = nil print(pcall(function() io.open('x') end))");
    defer removed.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tanonymous:1: attempt to call a nil value (field 'open')\n", removed.out);
}

test "os: the interface hint is the same from a hot loop in every trace mode" {
    const source =
        \\local function f(i) if i == 300 then return os.time() end return i end
        \\local s = 0
        \\print(pcall(function() for i = 1, 1000 do s = s + f(i) end end))
    ;
    for (std.enums.values(util.TraceMode)) |mode| {
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        try util.runCapturedTuned(testing.allocator, source, &sink, false, mode, .{});
        try testing.expectEqualStrings(
            "false\tf:1: attempt to call a nil value (field 'time'; os.time needs the 'time' system interface, which this VM does not have)\n",
            sink.buffered(),
        );
    }
}

test "os: a group that is off installs none of its functions" {
    const r = try run(testing.allocator, .{ .groups = .{ .clock = true } },
        \\print(os.time, os.date, os.remove, os.rename, os.tmpname, os.exit, os.difftime ~= nil)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\tnil\tnil\tnil\tnil\tnil\ttrue\n", r.out);
}
