//! Tests for `proc.run` (doc 75): the options, the result and failure tables,
//! and the record/replay contract (a replay builds the same results and
//! raises the same errors without ever starting a program). `FakeHost`
//! (`interp_testutil.zig`) answers with a scripted result; the real spawn
//! backend is tested in `proc_host.zig` and `host_system.zig`.

const std = @import("std");
const interp = @import("interp.zig");
const io = @import("io.zig");
const system = @import("system.zig");
const effectser = @import("effectser.zig");
const testing = std.testing;

const Vm = interp.Vm;
const EffectMode = interp.EffectMode;
const util = @import("interp_testutil.zig");
const FakeHost = util.FakeHost;
const compileRun = util.compileRun;

const Run = struct {
    out: []u8,
    log: []u8,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.log);
    }
};

const RunOpts = struct {
    host: ?*FakeHost = null,
    mode: EffectMode = .off,
    log: []const u8 = "",
    limit: ?usize = null,
    groups: system.Groups = .{ .proc = true },
};

fn run(gpa: std.mem.Allocator, opts: RunOpts, source: [:0]const u8) !Run {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = io.Writer.fixed(&out_buf);
    vm.out = &out;
    try vm.enableSystem(opts.groups);
    if (opts.host) |h| vm.system = h.system();
    if (opts.limit) |l| vm.effect_log_limit = l;
    if (opts.mode == .replay) try effectser.decodeInto(&vm.effect_log, gpa, vm.heap, opts.log);
    vm.effect_mode = opts.mode;
    try compileRun(gpa, &vm, source);
    if (opts.mode == .replay) try testing.expectEqual(vm.effect_log.entries.items.len, vm.effect_cursor);
    return .{
        .out = try gpa.dupe(u8, out.buffered()),
        .log = if (opts.mode == .record) try effectser.encodeFile(gpa, &vm.effect_log) else try gpa.dupe(u8, ""),
    };
}

/// Record against `host`, replay with no host: same output, and the replay
/// must not start anything.
fn recordReplay(host: *FakeHost, source: [:0]const u8) !Run {
    const gpa = testing.allocator;
    const rec = try run(gpa, .{ .host = host, .mode = .record }, source);
    errdefer rec.deinit(gpa);
    const calls = host.calls;
    const rep = try run(gpa, .{ .mode = .replay, .log = rec.log }, source);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqual(calls, host.calls);
    return rec;
}

const done_ok: system.ProcResult = .{ .done = .{ .status = .{ .exited = 0 }, .stdout = "hello\n", .stderr = "", .truncated = false } };

test "proc: a finished program is a table of how it ended and what it wrote" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    const r = try recordReplay(&host,
        \\local r = proc.run({"echo", "hello"})
        \\print(r.ok, r.code, r.signal, string.decode(r.stdout), #r.stderr, r.truncated, r.timed_out)
        \\print(type(r.stdout), r.stdout[1], r.stdout[6])
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("true\t0\tnil\thello\n\t0\tfalse\tfalse\ntable\t104\t10\n", r.out);
    try testing.expectEqual(@as(usize, 1), host.proc_calls);
    try testing.expectEqual(@as(usize, 2), host.proc_argc);
}

test "proc: each call hands back fresh byte arrays" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    const r = try recordReplay(&host,
        \\local a = proc.run({"x"})
        \\a.stdout[1] = 0
        \\print(proc.run({"x"}).stdout[1])
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("104\n", r.out);
}

test "proc: a failed exit raises a table that reads as a message" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .status = .{ .exited = 3 }, .stdout = "out", .stderr = "err", .truncated = false } };
    const r = try recordReplay(&host,
        \\local ok, e = pcall(proc.run, {"tool", "arg"})
        \\print(ok, type(e), e.kind, e.code, e.program, string.decode(e.stdout), string.decode(e.stderr), e.ok)
        \\print(tostring(e))
        \\local r = proc.run({"tool", check = false})
        \\print(r.ok, r.code, r.kind)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "false\ttable\texit\t3\ttool\tout\terr\tfalse\n" ++
            "command 'tool' exited with status 3\n" ++
            "false\t3\tnil\n",
        r.out,
    );
}

test "proc: a signal and a timeout are results too, and raise by default" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .status = .{ .signaled = "SIGSEGV" }, .stdout = "", .stderr = "", .truncated = false } };
    const sig = try recordReplay(&host,
        \\local r = proc.run({"x", check = false})
        \\print(r.ok, r.code, r.signal, r.timed_out)
        \\local ok, e = pcall(proc.run, {"x"})
        \\print(e.kind, e.signal, tostring(e))
    );
    defer sig.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tnil\tSIGSEGV\tfalse\nsignal\tSIGSEGV\tcommand 'x' was killed by SIGSEGV\n", sig.out);

    host.proc_result = .{ .done = .{ .status = .timed_out, .stdout = "part", .stderr = "", .truncated = true } };
    const t = try recordReplay(&host,
        \\local r = proc.run({"x", timeout = 2.5, check = false})
        \\print(r.ok, r.code, r.signal, r.timed_out, r.truncated, string.decode(r.stdout))
        \\local ok, e = pcall(proc.run, {"x", timeout = 2})
        \\print(e.kind, e.timed_out, tostring(e))
    );
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tnil\tnil\ttrue\ttrue\tpart\ntimeout\ttrue\tcommand 'x' timed out after 2 seconds\n", t.out);
    try testing.expectEqual(@as(?u64, 2_000_000_000), host.proc_timeout_ns);
}

test "proc: streams that are not captured are absent" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .status = .{ .exited = 0 }, .stdout = "", .stderr = "", .truncated = false } };
    const r = try recordReplay(&host,
        \\local r = proc.run({"x", stdout = "null", stderr = "merge"})
        \\print(r.stdout, r.stderr)
        \\local s = proc.run({"x", stderr = "null"})
        \\print(type(s.stdout), s.stderr)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\tnil\ntable\tnil\n", r.out);
}

test "proc: a program that cannot be started raises, whatever check says, and replays the same" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .fail = .not_found };
    const r = try recordReplay(&host,
        \\print(pcall(proc.run, {"nope"}))
        \\print(pcall(proc.run, {"nope", check = false}))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tcannot run 'nope': not found\nfalse\tcannot run 'nope': not found\n", r.out);
}

test "proc: options are checked, and a typo is an error rather than ignored" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    const r = try run(testing.allocator, .{ .host = &host },
        \\local function bad(t) local ok, e = pcall(proc.run, t) print(e) end
        \\bad({})
        \\bad({"x", chekc = false})
        \\bad({"x", stdout = "everything"})
        \\bad({"x", stderr = "merge2"})
        \\bad({"x", timeout = 0})
        \\bad({"x", max_bytes = -1})
        \\bad({"x", env = {A = 1}})
        \\bad({"x", env = {["A=B"] = "1"}})
        \\bad({"x", stdin = 7})
        \\bad({"x", check = "yes"})
        \\bad({"x", 5})
        \\bad(7)
    );
    defer r.deinit(testing.allocator);
    const expected =
        "bad argument #1 to '?' (no program: the table needs the program name at [1])\n" ++
        "bad argument #1 to '?' (unknown option 'chekc')\n" ++
        "bad argument #1 to '?' ('stdout' must be \"capture\", \"null\", \"inherit\", got \"everything\")\n" ++
        "bad argument #1 to '?' ('stderr' must be \"capture\", \"null\", \"inherit\" or \"merge\", got \"merge2\")\n" ++
        "bad argument #1 to '?' ('timeout' must be a positive number of seconds)\n" ++
        "bad argument #1 to '?' ('max_bytes' must be a non-negative integer)\n" ++
        "bad argument #1 to '?' ('env.A' must be a string, got number)\n" ++
        "bad argument #1 to '?' ('env' has an invalid variable name 'A=B')\n" ++
        "bad argument #1 to '?' ('stdin' must be a string, a byte array, {file = path} or {inherit = true}, got number)\n" ++
        "bad argument #1 to '?' ('check' must be a boolean)\n" ++
        "bad argument #1 to '?' (argv[2] must be a string, got number)\n" ++
        "bad argument #1 to '?' (table expected, got number)\n";
    // The call site prefixes each message; compare the tails.
    var got = std.mem.splitScalar(u8, r.out, '\n');
    var want = std.mem.splitScalar(u8, expected, '\n');
    while (want.next()) |w| {
        const g = got.next() orelse return error.TestExpectedEqual;
        try testing.expect(std.mem.endsWith(u8, g, w));
    }
    try testing.expectEqual(@as(usize, 0), host.proc_calls);
}

test "proc: max_bytes and timeout reach the host" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    const r = try run(testing.allocator, .{ .host = &host }, "proc.run({'x', max_bytes = 5, timeout = 1.5})");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), host.proc_max_bytes);
    try testing.expectEqual(@as(?u64, 1_500_000_000), host.proc_timeout_ns);
    const d = try run(testing.allocator, .{ .host = &host }, "proc.run({'x'})");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 64 * 1024), host.proc_max_bytes);
    try testing.expectEqual(@as(?u64, null), host.proc_timeout_ns);
}

test "proc: a call no recording could replay is fatal before anything runs, but runs when not recording" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    for ([_][:0]const u8{
        "proc.run({'x', stdout = 'inherit'})",
        "proc.run({'x', stderr = 'inherit'})",
        "proc.run({'x', stdin = {inherit = true}})",
        // Fatal, so a pcall does not catch it.
        "pcall(proc.run, {'x', stdout = 'inherit'})",
    }) |src| {
        try testing.expectError(error.ProcNotRecordable, run(testing.allocator, .{ .host = &host, .mode = .record }, src));
        const ran = try run(testing.allocator, .{ .host = &host }, src);
        ran.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 4), host.proc_calls);
}

test "proc: a recording makes room for the worst case before the program runs" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    // 100 bytes of room, two captures of up to 64 KiB.
    try testing.expectError(error.EffectLogLimit, run(testing.allocator, .{ .host = &host, .mode = .record, .limit = 100 }, "proc.run({'x'})"));
    try testing.expectEqual(@as(usize, 0), host.proc_calls);
    // The same call with captures small enough to fit runs.
    const r = try run(testing.allocator, .{ .host = &host, .mode = .record, .limit = 400 }, "proc.run({'x', max_bytes = 16})");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), host.proc_calls);
}

test "proc: a replayed record that was not written by this recorder refuses the replay" {
    var log: interp.EffectLog = .{};
    defer log.deinit(testing.allocator);
    // Ended 'exited', then a record cut short.
    try log.appendBytes(testing.allocator, .proc_run, &.{ 0, 0, 0, 0, 0, 0 });
    const bad = try effectser.encodeFile(testing.allocator, &log);
    defer testing.allocator.free(bad);
    try testing.expectError(error.EffectKindMismatch, run(testing.allocator, .{ .mode = .replay, .log = bad }, "proc.run({'x'})"));
}

test "proc: absent without the proc group" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const r = try run(testing.allocator, .{ .host = &host, .groups = .{ .files = true, .env = true } }, "print(proc)");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\n", r.out);
}

test "proc: a host without proc cannot start anything" {
    const r = try run(testing.allocator, .{}, "print(pcall(proc.run, {'x'}))");
    defer r.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, r.out, "cannot run 'x': input/output error\n"));
}
