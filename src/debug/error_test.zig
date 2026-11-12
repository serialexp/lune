//! Tests for error stops (doc 86 §5.4): each site an error is raised at,
//! the two filters, one stop per raise however many dispatches it leaves,
//! and what a stop at an error allows (evaluate, step, terminate).

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const testutil = @import("testutil.zig");
const interp = @import("../interp.zig");
const keyframeser = @import("../keyframeser.zig");

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;
const Reason = session_mod.Reason;
const Filters = session_mod.ExceptionFilters;
const Program = testutil.Program;
const Script = testutil.Script;

const both: Filters = .{ .uncaught = true, .caught = true };

/// One error stop a test expects: its line, whether it is caught, and a
/// piece of its text.
const Want = struct {
    line: u32,
    caught: bool,
    text: []const u8,
};

/// Run `source` under `filters`, continuing at every stop, and compare its
/// error stops to `want`. Returns how the run ended.
fn expectErrorStops(source: [:0]const u8, filters: Filters, want: []const Want) !?interp.Error {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    s.setExceptionFilters(filters);
    const ended: ?interp.Error = if (s.run(prog.chunk.proto)) |_| null else |e| e;

    const seen = script.seen.items;
    errdefer for (seen, 0..) |x, i| std.debug.print("stop {d}: {s} line {d} caught {} `{s}`\n", .{ i, @tagName(x.reason), x.line, x.caught, x.text });
    // The error stops, then the end stop.
    try testing.expectEqual(want.len + 1, seen.len);
    for (want, seen[0..want.len]) |w, x| {
        try testing.expectEqual(Reason.exception, x.reason);
        try testing.expectEqual(w.line, x.line);
        try testing.expectEqual(w.caught, x.caught);
        try testing.expect(std.mem.indexOf(u8, x.text, w.text) != null);
    }
    try testing.expectEqual(Reason.ended, seen[want.len].reason);
    return ended;
}

test "doc 86 P2: an uncaught runtime fault stops at the instruction, with the text its catcher would see" {
    const ended = try expectErrorStops("local t = nil\nlocal x = t.a\nreturn x\n", .{}, &.{
        .{ .line = 2, .caught = false, .text = "main:2: attempt to index a nil value (local 't')" },
    });
    try testing.expectEqual(@as(?interp.Error, error.TypeError), ended);
}

test "doc 86 P2: by default a caught error does not stop" {
    _ = try expectErrorStops("local ok = pcall(error, \"x\")\nreturn ok\n", .{}, &.{});
}

test "doc 86 P2: with only `caught`, an uncaught error does not stop" {
    _ = try expectErrorStops("error(\"boom\")\n", .{ .uncaught = false, .caught = true }, &.{});
}

test "doc 86 P2: an error under pcall stops where it is raised, as caught" {
    _ = try expectErrorStops(
        \\local function bad() error("boom") end
        \\local ok, e = pcall(bad)
        \\return e
    , both, &.{
        .{ .line = 1, .caught = true, .text = "main:1: boom" },
    });
}

test "doc 86 P2: a native that pcall calls directly stops at the pcall's line" {
    _ = try expectErrorStops("local ok, e = pcall(error, \"direct\")\nreturn e\n", both, &.{
        .{ .line = 1, .caught = true, .text = "direct" },
    });
}

test "doc 86 P2: an error that leaves several dispatches stops once" {
    // The comparator's error leaves its own dispatch, then table.sort, then
    // the pcall made in Zig.
    _ = try expectErrorStops(
        \\local t = { 3, 1, 2 }
        \\local ok, e = pcall(table.sort, t, function(a, b) error("cmp") end)
        \\return e
    , both, &.{
        .{ .line = 2, .caught = true, .text = "cmp" },
    });
}

test "doc 86 P2: an xpcall handler's own error is a raise of its own" {
    _ = try expectErrorStops(
        \\local function bad() error("boom") end
        \\local ok, e = xpcall(bad, function(m) error("again") end)
        \\return e
    , both, &.{
        .{ .line = 1, .caught = true, .text = "boom" },
        .{ .line = 2, .caught = true, .text = "again" },
    });
}

test "doc 86 P2: a coroutine's error is caught by its resume" {
    _ = try expectErrorStops(
        \\local co = coroutine.create(function() error("in co") end)
        \\local ok, e = coroutine.resume(co)
        \\return e
    , both, &.{
        .{ .line = 1, .caught = true, .text = "in co" },
    });
}

test "doc 86 P2: a wrap function raises its coroutine's error again, which stops once" {
    // The coroutine closes a variable as it dies, so guest code runs
    // between its raise and the wrap's; the wrap's is the same error.
    _ = try expectErrorStops(
        \\local f = coroutine.wrap(function()
        \\    local x <close> = setmetatable({}, { __close = function() end })
        \\    error("in wrap")
        \\end)
        \\f()
    , both, &.{
        .{ .line = 3, .caught = false, .text = "in wrap" },
    });
}

test "doc 86 P2: a wrap function called from Zig raises again too, under a pcall or not" {
    _ = try expectErrorStops(
        \\local ok = pcall(coroutine.wrap(function() error("caught") end))
        \\table.sort({ 1, 2 }, coroutine.wrap(function() error("uncaught") end))
    , both, &.{
        .{ .line = 1, .caught = true, .text = "caught" },
        .{ .line = 2, .caught = false, .text = "uncaught" },
    });
}

test "doc 86 P2: an error a __close raises while unwinding is a raise of its own" {
    _ = try expectErrorStops(
        \\do
        \\    local x <close> = setmetatable({}, { __close = function() error("in close") end })
        \\    error("first")
        \\end
    , both, &.{
        .{ .line = 3, .caught = false, .text = "first" },
        .{ .line = 2, .caught = false, .text = "in close" },
    });
}

fn terminateAtError(_: *Script, _: *Session, stop: Stop) Resume {
    return if (stop.reason == .exception) .terminate else .@"continue";
}

fn runTerminating(source: [:0]const u8) !usize {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &terminateAtError };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    s.setExceptionFilters(both);
    try testing.expectError(error.DebugTerminated, s.run(prog.chunk.proto));
    return script.seen.items.len;
}

test "doc 86 P2: terminate at an error stop ends the run, caught or not, with no end stop" {
    try testing.expectEqual(@as(usize, 1), try runTerminating("error(\"boom\")\n"));
    try testing.expectEqual(@as(usize, 1), try runTerminating("local ok = pcall(error, \"x\")\nlocal y = 1\nreturn y\n"));
}

fn stepOverAtError(self: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .exception) return .@"continue";
    // The faulting frame's local, read where it raised.
    const o = s.evaluate("n") catch @panic("evaluate failed");
    self.n = @intCast(o.ok.value.asInt());
    return .{ .step = .{ .kind = .over } };
}

test "doc 86 P2: at an error stop, evaluate reads the raising frame, and a step stops where it is caught" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function bad(n)
        \\    local t = nil
        \\    return t[n]
        \\end
        \\local ok = pcall(bad, 5) or 0
        \\return ok
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &stepOverAtError };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    s.setExceptionFilters(both);
    _ = try s.run(prog.chunk.proto);
    const seen = script.seen.items;
    try testing.expectEqual(@as(usize, 3), seen.len);
    try testing.expectEqual(Reason.exception, seen[0].reason);
    try testing.expectEqual(@as(u32, 3), seen[0].line);
    try testing.expectEqual(@as(usize, 5), script.n);
    // The step: the frame is gone, so the first pc below it, the `or`.
    try testing.expectEqual(Reason.step, seen[1].reason);
    try testing.expectEqual(@as(u32, 5), seen[1].line);
    try testing.expectEqual(@as(u32, 1), seen[1].depth);
    try testing.expectEqual(Reason.ended, seen[2].reason);
}

test "doc 86 P2: an error stop changes nothing: the same steps and the same final snapshot" {
    const gpa = testing.allocator;
    const source =
        \\local n = 0
        \\for i = 1, 3 do
        \\    local ok = pcall(function() return nil + i end)
        \\    local ok2 = pcall(error, { code = i })
        \\    if not ok and not ok2 then n = n + 1 end
        \\end
        \\return n
    ;
    var ref_vm = try Vm.init(gpa);
    defer ref_vm.deinit();
    var ref_prog = try Program.init(gpa, &ref_vm, source);
    defer ref_prog.deinit();
    _ = try ref_vm.run(ref_prog.chunk.proto);
    const want = try keyframeser.encodeSnapshot(gpa, &ref_vm);
    defer gpa.free(want);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    s.setExceptionFilters(both);
    _ = try s.run(prog.chunk.proto);
    s.detach();

    // Six error stops and the end stop; a raised table renders by type.
    try testing.expectEqual(@as(usize, 7), script.seen.items.len);
    try testing.expectEqualStrings("(error object is a table value)", script.seen.items[1].text);
    try testing.expectEqual(ref_vm.safepoint_seq, vm.safepoint_seq);
    const got = try keyframeser.encodeSnapshot(gpa, &vm);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

test "doc 86 P2: terminate at an uncaught error stop leaves the VM idle, and the same session runs again" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "error(\"boom\")\n");
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &terminateAtError };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    s.setExceptionFilters(both);
    try testing.expectError(error.DebugTerminated, s.run(prog.chunk.proto));
    try testing.expectEqual(@as(u32, 0), vm.depth);
    try testing.expect(vm.pending_error == null);
    var again = try Program.init(gpa, &vm, "return 7");
    defer again.deinit();
    try testing.expectEqual(@as(i64, 7), (try s.run(again.chunk.proto)).asInt());
}

fn terminateWhenPending(_: *Script, s: *Session, _: Stop) Resume {
    if (s.vm.reg_top_pending) return .terminate;
    s.requestPause();
    return .@"continue";
}

test "doc 86 P2: terminate where a multiple-result call is pending leaves the VM reusable" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function f() return 1, 2 end
        \\local function g() return f() end
        \\return g()
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &terminateWhenPending };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    try testing.expectError(error.DebugTerminated, s.run(prog.chunk.proto));
    try testing.expect(!vm.reg_top_pending);
    var again = try Program.init(gpa, &vm, "local function f() return 1, 2 end\nreturn (f())");
    defer again.deinit();
    try testing.expectEqual(@as(i64, 1), (try s.run(again.chunk.proto)).asInt());
}
