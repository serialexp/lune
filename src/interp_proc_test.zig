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
    if (opts.mode == .replay) try effectser.decodeInto(&vm.effect_log, gpa, opts.log);
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

const stage_ok = [_]system.ProcStage{.{ .status = .{ .exited = 0 }, .stderr = "" }};
const stage_exit3 = [_]system.ProcStage{.{ .status = .{ .exited = 3 }, .stderr = "err" }};
const stage_segv = [_]system.ProcStage{.{ .status = .{ .signaled = "SIGSEGV" }, .stderr = "" }};
const stage_term = [_]system.ProcStage{.{ .status = .{ .signaled = "SIGTERM" }, .stderr = "" }};

const done_ok: system.ProcResult = .{ .done = .{ .stages = &stage_ok, .stdout = "hello\n", .timed_out = false, .truncated = false } };

test "[REQ-12.1] [REQ-17.3] proc: a finished program is a table of how it ended and what it wrote" {
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

test "[REQ-12.2] proc: each call hands back fresh byte arrays" {
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

test "[REQ-13.1] [REQ-13.3] proc: a failed exit raises a table that reads as a message" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &stage_exit3, .stdout = "out", .timed_out = false, .truncated = false } };
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

test "[REQ-13.2] [REQ-13.3] proc: a signal and a timeout are results too, and raise by default" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &stage_segv, .stdout = "", .timed_out = false, .truncated = false } };
    const sig = try recordReplay(&host,
        \\local r = proc.run({"x", check = false})
        \\print(r.ok, r.code, r.signal, r.timed_out)
        \\local ok, e = pcall(proc.run, {"x"})
        \\print(e.kind, e.signal, tostring(e))
    );
    defer sig.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tnil\tSIGSEGV\tfalse\nsignal\tSIGSEGV\tcommand 'x' was killed by SIGSEGV\n", sig.out);

    host.proc_result = .{ .done = .{ .stages = &stage_term, .stdout = "part", .timed_out = true, .truncated = true } };
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

test "[REQ-16.2] proc: streams that are not captured are absent" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &stage_ok, .stdout = "", .timed_out = false, .truncated = false, .stdout_captured = false, .stderr_captured = false } };
    const r = try recordReplay(&host,
        \\local r = proc.run({"x", stdout = "null", stderr = "merge"})
        \\print(r.stdout, r.stderr)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\tnil\n", r.out);
    host.proc_result = .{ .done = .{ .stages = &stage_ok, .stdout = "", .timed_out = false, .truncated = false, .stderr_captured = false } };
    const s = try recordReplay(&host,
        \\local s = proc.run({"x", stderr = "null"})
        \\print(type(s.stdout), s.stderr)
    );
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("table\tnil\n", s.out);
}

test "[REQ-14.1] proc: a program that cannot be started raises, whatever check says, and replays the same" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .fail = .{ .class = .not_found } };
    const r = try recordReplay(&host,
        \\print(pcall(proc.run, {"nope"}))
        \\print(pcall(proc.run, {"nope", check = false}))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tcannot run 'nope': not found\nfalse\tcannot run 'nope': not found\n", r.out);
}

test "[REQ-15.1] proc: options are checked, and a typo is an error rather than ignored" {
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

test "[REQ-16.1] proc: max_bytes and timeout reach the host" {
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

test "[REQ-17.1] proc: a call no recording could replay is fatal before anything runs, but runs when not recording" {
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

test "[REQ-17.2] proc: a recording makes room for the worst case before the program runs" {
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

test "[REQ-17.4] proc: a replayed record that was not written by this recorder refuses the replay" {
    var log: interp.EffectLog = .{};
    defer log.deinit(testing.allocator);
    // Ended 'exited', then a record cut short.
    try log.appendBytes(testing.allocator, .proc_run, &.{ 0, 0, 0, 0, 0, 0 });
    const bad = try effectser.encodeFile(testing.allocator, &log);
    defer testing.allocator.free(bad);
    try testing.expectError(error.EffectKindMismatch, run(testing.allocator, .{ .mode = .replay, .log = bad }, "proc.run({'x'})"));
}

test "[REQ-18.1] proc: absent without the proc group" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const r = try run(testing.allocator, .{ .host = &host, .groups = .{ .files = true, .env = true } }, "print(proc)");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\n", r.out);
}

test "[REQ-18.1] proc: a host without proc cannot start anything" {
    const r = try run(testing.allocator, .{}, "print(pcall(proc.run, {'x'}))");
    defer r.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, r.out, "cannot run 'x': input/output error\n"));
}

const pipe_exits_ok = [_]system.ProcStage{
    .{ .status = .{ .exited = 0 }, .stderr = "e1" },
    .{ .status = .{ .exited = 0 }, .stderr = "" },
    .{ .status = .{ .exited = 0 }, .stderr = "e3" },
};
const pipe_exits_mid = [_]system.ProcStage{
    .{ .status = .{ .exited = 1 }, .stderr = "e1" },
    .{ .status = .{ .exited = 0 }, .stderr = "" },
    .{ .status = .{ .exited = 3 }, .stderr = "e3" },
};
const pipe_last_fails = [_]system.ProcStage{
    .{ .status = .{ .exited = 0 }, .stderr = "" },
    .{ .status = .{ .exited = 0 }, .stderr = "" },
    .{ .status = .{ .exited = 2 }, .stderr = "" },
};
const pipe_sigpipe_first = [_]system.ProcStage{
    .{ .status = .{ .signaled = "SIGPIPE" }, .stderr = "" },
    .{ .status = .{ .exited = 0 }, .stderr = "" },
};
const pipe_sigpipe_last = [_]system.ProcStage{
    .{ .status = .{ .exited = 0 }, .stderr = "" },
    .{ .status = .{ .signaled = "SIGPIPE" }, .stderr = "" },
};

test "[REQ-19.1] proc.pipe: a pipeline is one result with the last stdout and each stage's story" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &pipe_exits_ok, .stdout = "42\n", .timed_out = false, .truncated = false } };
    const r = try recordReplay(&host,
        \\local r = proc.pipe({{"cat", "f"}, {"grep", "E"}, {"wc", "-l"}})
        \\print(r.ok, r.code, string.decode(r.stdout), #r.stages, r.stderr)
        \\print(r.stages[1].code, string.decode(r.stages[1].stderr), r.stages[1].ok, string.decode(r.stages[3].stderr))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("true\t0\t42\n\t3\tnil\n0\te1\ttrue\te3\n", r.out);
    try testing.expectEqual(@as(usize, 1), host.proc_calls);
    try testing.expectEqual(@as(usize, 3), host.proc_stages);
}

test "[REQ-20.1] proc.pipe: it fails like pipefail, on the rightmost failing stage" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &pipe_exits_mid, .stdout = "out", .timed_out = false, .truncated = false } };
    const r = try recordReplay(&host,
        \\local ok, e = pcall(proc.pipe, {{"a"}, {"b"}, {"c", "x"}})
        \\print(ok, e.kind, e.code, e.program, string.decode(e.stderr), string.decode(e.stdout), #e.stages)
        \\print(tostring(e))
        \\local r = proc.pipe({{"a"}, {"b"}, {"c"}, check = false})
        \\print(r.ok, r.code, r.stages[1].ok, r.stages[1].code, r.stages[3].ok)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "false\texit\t3\tc\te3\tout\t3\n" ++
            "command 'c' exited with status 3\n" ++
            "false\t3\tfalse\t1\tfalse\n",
        r.out,
    );
}

test "[REQ-20.2] proc.pipe: a reader that stopped early is not a failure, but SIGPIPE at the end is" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &pipe_sigpipe_first, .stdout = "y\n", .timed_out = false, .truncated = false } };
    const a = try recordReplay(&host,
        \\local r = proc.pipe({{"yes"}, {"head", "-n", "1"}})
        \\print(r.ok, r.code, r.stages[1].signal, r.stages[1].ok)
    );
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("true\t0\tSIGPIPE\ttrue\n", a.out);

    host.proc_result = .{ .done = .{ .stages = &pipe_sigpipe_last, .stdout = "", .timed_out = false, .truncated = false } };
    const b = try recordReplay(&host,
        \\local ok, e = pcall(proc.pipe, {{"a"}, {"b"}})
        \\print(e.kind, e.signal, tostring(e))
    );
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("signal\tSIGPIPE\tcommand 'b' was killed by SIGPIPE\n", b.out);
}

test "[REQ-21.2] proc.pipe: a timeout names the whole pipeline" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .done = .{ .stages = &pipe_last_fails, .stdout = "", .timed_out = true, .truncated = false } };
    const r = try recordReplay(&host,
        \\local ok, e = pcall(proc.pipe, {{"a"}, {"b"}, {"c"}, timeout = 3})
        \\print(e.kind, e.program, e.code, tostring(e))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("timeout\ta | b | c\tnil\tcommand 'a | b | c' timed out after 3 seconds\n", r.out);
}

test "[REQ-21.1] proc.pipe: a stage that cannot start names itself, and a record of another shape refuses" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = .{ .fail = .{ .stage = 1, .class = .permission_denied } };
    const r = try recordReplay(&host, "print(pcall(proc.pipe, {{'a'}, {'locked'}, {'c'}}))");
    defer r.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, r.out, "cannot run 'locked': permission denied\n"));

    // A recording of a one-program call is not a two-stage pipeline's.
    host.proc_result = done_ok;
    const rec = try run(testing.allocator, .{ .host = &host, .mode = .record }, "proc.run({'x'})");
    defer rec.deinit(testing.allocator);
    try testing.expectError(error.EffectKindMismatch, run(testing.allocator, .{ .mode = .replay, .log = rec.log }, "proc.pipe({{'x'}, {'y'}})"));
}

test "[REQ-21.3] [REQ-21.4] proc.pipe: the table is checked, and the shared rules apply to every stage" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.proc_result = done_ok;
    const r = try run(testing.allocator, .{ .host = &host },
        \\local function bad(t) local ok, e = pcall(proc.pipe, t) print(e) end
        \\bad({})
        \\bad({{"a"}, "b"})
        \\bad({{"a"}, {}})
        \\bad({{"a"}, {"b", 5}})
        \\bad({{"a"}, {"b", cwd = "/"}})
        \\bad({{"a"}, {"b"}, chekc = 1})
        \\bad(7)
    );
    defer r.deinit(testing.allocator);
    const expected =
        "bad argument #1 to '?' (no stages: the table needs a table of argv for each stage at [1])\n" ++
        "bad argument #1 to '?' (stage 2 must be a table of strings, got string)\n" ++
        "bad argument #1 to '?' (stage 2 has no program: it needs the program name at [1])\n" ++
        "bad argument #1 to '?' (stage 2[2] must be a string, got number)\n" ++
        "bad argument #1 to '?' (stage 2 has an unexpected key; a stage is just its argv)\n" ++
        "bad argument #1 to '?' (unknown option 'chekc')\n" ++
        "bad argument #1 to '?' (table expected, got number)\n";
    var got = std.mem.splitScalar(u8, r.out, '\n');
    var want = std.mem.splitScalar(u8, expected, '\n');
    while (want.next()) |w| {
        const g = got.next() orelse return error.TestExpectedEqual;
        try testing.expect(std.mem.endsWith(u8, g, w));
    }
    try testing.expectEqual(@as(usize, 0), host.proc_calls);

    // Inherited stdio is fatal for the pipeline as a whole, before anything runs.
    try testing.expectError(error.ProcNotRecordable, run(testing.allocator, .{ .host = &host, .mode = .record }, "proc.pipe({{'a'}, {'b'}, stderr = 'inherit'})"));
    // The worst case grows with the stages: three stderr captures of 64 KiB.
    try testing.expectError(error.EffectLogLimit, run(testing.allocator, .{ .host = &host, .mode = .record, .limit = 3 * 1024 }, "proc.pipe({{'a'}, {'b'}, {'c'}, max_bytes = 1024, stdout = 'null'})"));
    try testing.expectEqual(@as(usize, 0), host.proc_calls);
}

const job_done_out = system.ProcJobState{ .done = .{ .stages = &stage_exit3, .stdout = "out", .timed_out = false, .truncated = false, .stderr_captured = true } };
const job_done_ok = system.ProcJobState{ .done = .{ .stages = &stage_ok, .stdout = "fine\n", .timed_out = false, .truncated = false } };

test "[REQ-22.1] [REQ-22.2] proc.spawn: a job has a pid and methods, and is only ever live" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.job_states = &.{ .running, .running, job_done_ok };
    const r = try run(testing.allocator, .{ .host = &host },
        \\local j = proc.spawn({"sleep", "1"})
        \\print(j.pid, j.program, j.check, j.timeout, type(j.wait), type(j.poll), type(j.kill))
        \\print(j:poll(), j:poll())
        \\local r = j:wait()
        \\print(r.ok, r.code, string.decode(r.stdout))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("4242\tsleep\ttrue\tnil\tfunction\tfunction\tfunction\nnil\tnil\ntrue\t0\tfine\n\n", r.out);
    try testing.expectEqual(@as(usize, 1), host.job_blocked);
    // stdout is the parent's unless asked for.
    try testing.expect(host.proc_stdout_inherit);
}

test "[REQ-22.2] proc.spawn: poll hands back the result once the job has ended" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.job_states = &.{ .running, job_done_ok };
    const r = try run(testing.allocator, .{ .host = &host },
        \\local j = proc.spawn({"x"})
        \\print(j:poll())
        \\local r = j:poll()
        \\print(r.ok, r.code, string.decode(r.stdout))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\ntrue\t0\tfine\n\n", r.out);
}

test "[REQ-23.1] proc.spawn: a job that was signalled or timed out raises on wait too" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.job_states = &.{.{ .done = .{ .stages = &stage_segv, .stdout = "", .timed_out = false, .truncated = false } }};
    const sig = try run(testing.allocator, .{ .host = &host },
        \\local j = proc.spawn({"x"})
        \\local ok, e = pcall(j.wait, j)
        \\print(ok, e.kind, e.signal, tostring(e))
        \\print(proc.spawn({"x", check = false}):wait().signal)
    );
    defer sig.deinit(testing.allocator);
    try testing.expectEqualStrings("false\tsignal\tSIGSEGV\tcommand 'x' was killed by SIGSEGV\nSIGSEGV\n", sig.out);
    host.job_states = &.{.{ .done = .{ .stages = &stage_term, .stdout = "", .timed_out = true, .truncated = false } }};
    const t = try run(testing.allocator, .{ .host = &host },
        \\local j = proc.spawn({"x", timeout = 2})
        \\local ok, e = pcall(j.wait, j)
        \\print(ok, e.kind, e.timed_out)
    );
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("false\ttimeout\ttrue\n", t.out);
}

test "[REQ-24.1] proc.spawn: kill sends TERM by default" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const r = try run(testing.allocator, .{ .host = &host }, "print(proc.spawn({'x'}):kill())");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("true\n", r.out);
    try testing.expectEqualStrings("TERM", host.kill_signal[0..host.kill_signal_len]);
}

test "[REQ-23.1] [REQ-23.2] proc.spawn: a job that ended badly raises on wait unless check is false" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.job_states = &.{job_done_out};
    const r = try run(testing.allocator, .{ .host = &host },
        \\local j = proc.spawn({"tool", timeout = 5})
        \\local ok, e = pcall(j.wait, j)
        \\print(ok, e.kind, e.code, e.program, string.decode(e.stdout), tostring(e))
        \\local q = proc.spawn({"tool", check = false})
        \\print(q:wait().code, q.timeout, j.timeout)
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("false\texit\t3\ttool\tout\tcommand 'tool' exited with status 3\n3\tnil\t5\n", r.out);
    // The last spawn had no timeout; one with a timeout hands it to the host.
    try testing.expectEqual(@as(?u64, null), host.proc_timeout_ns);
    const t = try run(testing.allocator, .{ .host = &host }, "proc.spawn({'x', timeout = 5})");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 5_000_000_000), host.proc_timeout_ns);
}

test "[REQ-24.1] [REQ-24.2] proc.spawn: kill names the signal, and says whether it was sent" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const r = try run(testing.allocator, .{ .host = &host },
        \\local j = proc.spawn({"x"})
        \\print(j:kill(), j:kill("SIGINT"))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("true\ttrue\n", r.out);
    try testing.expectEqualStrings("SIGINT", host.kill_signal[0..host.kill_signal_len]);
    host.kill_result = .finished;
    const f = try run(testing.allocator, .{ .host = &host }, "print(proc.spawn({'x'}):kill())");
    defer f.deinit(testing.allocator);
    try testing.expectEqualStrings("false\n", f.out);
    host.kill_result = .bad_signal;
    const b = try run(testing.allocator, .{ .host = &host }, "print(pcall(proc.spawn({'x'}).kill, proc.spawn({'x'}), 'NOPE'))");
    defer b.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, b.out, "unknown signal 'NOPE'") != null);
}

test "[REQ-25.1] [REQ-25.2] proc.spawn: a job the host does not know is gone, and a spawn that fails raises" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.job_states = &.{.gone};
    const g = try run(testing.allocator, .{ .host = &host }, "print(pcall(proc.spawn({'x'}).wait, proc.spawn({'x'})))");
    defer g.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, g.out, "the job is gone") != null);
    host.spawn_result = .{ .fail = .{ .class = .not_found } };
    const f = try run(testing.allocator, .{ .host = &host }, "print(pcall(proc.spawn, {'nope'}))");
    defer f.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, f.out, "cannot run 'nope': not found\n"));
}

test "[REQ-22.3] proc.spawn: a recording refuses a job outright, and a job's methods are live-only" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try testing.expectError(error.ProcNotRecordable, run(testing.allocator, .{ .host = &host, .mode = .record }, "proc.spawn({'x'})"));
    var log: interp.EffectLog = .{};
    defer log.deinit(testing.allocator);
    const empty = try effectser.encodeFile(testing.allocator, &log);
    defer testing.allocator.free(empty);
    try testing.expectError(error.ProcNotRecordable, run(testing.allocator, .{ .mode = .replay, .log = empty }, "proc.spawn({'x'})"));
    try testing.expectEqual(@as(usize, 0), host.proc_calls);
}
