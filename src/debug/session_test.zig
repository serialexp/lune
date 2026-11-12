//! Tests for `session.zig`: stopping in place, pause, terminate and the
//! end stop (doc 86 P2, §3.1, §5.5).

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const testutil = @import("testutil.zig");
const interp = @import("../interp.zig");
const io = @import("../io.zig");
const keyframeser = @import("../keyframeser.zig");

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;
const Program = testutil.Program;
const Script = testutil.Script;

const alwaysContinue = testutil.alwaysContinue;

/// Stop again at the next stoppable point after every stop: instruction
/// stepping through the whole program.
fn stepEverything(_: *Script, s: *Session, _: Stop) Resume {
    s.requestPause();
    return .@"continue";
}

test "doc 86 P2: stop on entry, continue, and the end stop after the program returns" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var prog = try Program.init(gpa, &vm, "local x = 1\nprint(x + 1)\nreturn x\n");
    defer prog.deinit();

    var script: Script = .{ .gpa = gpa, .decide = &alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    const result = try s.run(prog.chunk.proto);

    try testing.expectEqual(@as(i64, 1), result.asInt());
    try testing.expectEqualStrings("2\n", sink.buffered());
    try testing.expectEqual(@as(usize, 2), script.seen.items.len);
    try testing.expectEqual(session_mod.Reason.entry, script.seen.items[0].reason);
    try testing.expectEqual(@as(u32, 1), script.seen.items[0].line);
    try testing.expectEqual(session_mod.Reason.ended, script.seen.items[1].reason);
}

test "doc 86 P2: without stop_on_entry the only stop is the end" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "local s = 0\nfor i = 1, 10 do s = s + i end\nreturn s\n");
    defer prog.deinit();

    var script: Script = .{ .gpa = gpa, .decide = &alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    try testing.expectEqual(@as(i64, 55), (try s.run(prog.chunk.proto)).asInt());
    try testing.expectEqual(@as(usize, 1), script.seen.items.len);
    try testing.expectEqual(session_mod.Reason.ended, script.seen.items[0].reason);
}

test "doc 86 P2: a pause after every stop stops once per program step, inside table.sort's comparator too" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local t = {3, 1, 2}
        \\table.sort(t, function(a, b)
        \\    return a < b
        \\end)
        \\return t[1]
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();

    var script: Script = .{ .gpa = gpa, .decide = &stepEverything };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    const before = vm.safepoint_seq;
    try testing.expectEqual(@as(i64, 1), (try s.run(prog.chunk.proto)).asInt());

    // One stop per step of the program, plus the end stop. The comparator
    // runs as a frame above table.sort's activation (doc 68), whose own
    // instructions are the VM's: they are not steps and never stop.
    var in_comparator: usize = 0;
    for (script.seen.items[0 .. script.seen.items.len - 1]) |seen| {
        try testing.expect(seen.reason == .entry or seen.reason == .pause);
        if (seen.line == 3) {
            in_comparator += 1;
            try testing.expect(seen.depth > 1);
        }
    }
    try testing.expect(in_comparator > 0);
    try testing.expectEqual(vm.safepoint_seq - before, script.seen.items.len - 1);
    try testing.expectEqual(session_mod.Reason.ended, script.seen.items[script.seen.items.len - 1].reason);
}

fn terminateOnLineTwo(_: *Script, s: *Session, _: Stop) Resume {
    const at = s.stopped_at orelse return .@"continue";
    if (at.line() == 2) return .terminate;
    s.requestPause();
    return .@"continue";
}

test "doc 86 P2: terminate ends the program through pcall, leaves the VM idle, and makes no end stop" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    const source =
        \\local ok = pcall(function()
        \\    while true do end
        \\end)
        \\print("after", ok)
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();

    var script: Script = .{ .gpa = gpa, .decide = &terminateOnLineTwo };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    try testing.expectError(error.DebugTerminated, s.run(prog.chunk.proto));
    try testing.expectEqualStrings("", sink.buffered());
    try testing.expectEqual(@as(u32, 0), vm.depth);
    try testing.expect(script.seen.items[script.seen.items.len - 1].reason != .ended);
    try testing.expect(!interp.catchable(error.DebugTerminated));

    // The VM is reusable, still under the session.
    var again = try Program.init(gpa, &vm, "return 7");
    defer again.deinit();
    try testing.expectEqual(@as(i64, 7), (try s.run(again.chunk.proto)).asInt());
}

fn terminateAfterThreeRequests(self: *Script, s: *Session) void {
    if (self.requests_taken == 3) s.requestTerminate() else s.notifyRequests();
}

test "doc 86 P2: requests taken while the program runs, and a terminate from there" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "while true do end");
    defer prog.deinit();

    var script: Script = .{ .gpa = gpa, .decide = &alwaysContinue, .on_requests = &terminateAfterThreeRequests };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    s.notifyRequests();
    try testing.expectError(error.DebugTerminated, s.run(prog.chunk.proto));
    try testing.expectEqual(@as(usize, 3), script.requests_taken);
    try testing.expectEqual(@as(usize, 0), script.seen.items.len);
}

test "doc 86 P2: an uncaught error stops where it is raised, then ends with the end stop, which carries it" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "error(\"boom\")");
    defer prog.deinit();

    var script: Script = .{ .gpa = gpa, .decide = &alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    try testing.expectError(error.LuaError, s.run(prog.chunk.proto));
    try testing.expectEqual(@as(usize, 2), script.seen.items.len);
    // `uncaught` is on by default (§5.4).
    try testing.expectEqual(session_mod.Reason.exception, script.seen.items[0].reason);
    try testing.expectEqual(@as(u32, 1), script.seen.items[0].line);
    try testing.expectEqual(session_mod.Reason.ended, script.seen.items[1].reason);
}

fn hotLoopSource() [:0]const u8 {
    return
    \\local s = 0
    \\for i = 1, 2000 do s = s + i % 7 end
    \\local t = {}
    \\for i = 1, 300 do t[i] = "v" .. i end
    \\return s + #t
    ;
}

fn enableJit(vm: *Vm) void {
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = @import("../nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
}

test "doc 86 P2: a session holds the JIT off, and stepping through it leaves the run's state as a plain tier-0 run leaves it" {
    const gpa = testing.allocator;
    const source = hotLoopSource();

    // The reference: tier 0, no session.
    var ref_vm = try Vm.init(gpa);
    defer ref_vm.deinit();
    var ref_prog = try Program.init(gpa, &ref_vm, source);
    defer ref_prog.deinit();
    const want = try ref_vm.run(ref_prog.chunk.proto);
    const want_snap = try keyframeser.encodeSnapshot(gpa, &ref_vm);
    defer gpa.free(want_snap);

    // With the JIT configured on, but debugged, and stopped at every
    // instruction of the first loop's iterations.
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    enableJit(&vm);
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &stepFirstHundred };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    const got = try s.run(prog.chunk.proto);
    s.detach();

    try testing.expectEqual(want.asInt(), got.asInt());
    try testing.expectEqual(@as(u64, 0), vm.trace.entries);
    try testing.expectEqual(@as(usize, 101), script.seen.items.len);
    const got_snap = try keyframeser.encodeSnapshot(gpa, &vm);
    defer gpa.free(got_snap);
    try testing.expectEqualSlices(u8, want_snap, got_snap);
    try testing.expectEqual(ref_vm.safepoint_seq, vm.safepoint_seq);
}

fn stepFirstHundred(self: *Script, s: *Session, _: Stop) Resume {
    self.n += 1;
    if (self.n < 100) s.requestPause();
    return .@"continue";
}

test "doc 86 P2: after detach the JIT runs again" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    enableJit(&vm);
    var script: Script = .{ .gpa = gpa, .decide = &alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    s.detach();
    try testing.expect(vm.debug == null);
    try testing.expect(!vm.trace.suspended());
    var prog = try Program.init(gpa, &vm, hotLoopSource());
    defer prog.deinit();
    _ = try vm.run(prog.chunk.proto);
    if (@import("../nativegen.zig").is_x64_linux) try testing.expect(vm.trace.entries > 0);
}

fn evaluateAtEnd(self: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .ended) return .@"continue";
    const o = s.evaluate("1 + 1") catch @panic("evaluate failed");
    self.n = if (o == .refused) 1 else 2;
    return .@"continue";
}

test "doc 86 P2: evaluate at the end stop is refused, after a return and after an uncaught error" {
    const gpa = testing.allocator;
    inline for (.{ "return 1", "local t = nil\nreturn t.x" }) |source| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var prog = try Program.init(gpa, &vm, source);
        defer prog.deinit();
        var script: Script = .{ .gpa = gpa, .decide = &evaluateAtEnd };
        defer script.deinit();
        var s: Session = undefined;
        s.attach(gpa, &vm, script.driver(), .{});
        defer s.detach();
        _ = s.run(prog.chunk.proto) catch {};
        try testing.expectEqual(@as(usize, 1), script.n);
    }
}

test "doc 86 P2: breakpoints and the entry stop work on every run through a session, after a normal end and after a terminate" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "local a = 1\nlocal b = a + 1\nreturn b");
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]session_mod.Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 2 }}, &out);
    _ = try s.run(prog.chunk.proto);
    _ = try s.run(prog.chunk.proto);
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 2, 2 }, script.breakpointLines(&buf));

    // A terminate ends a run the same way, and the breakpoint survives it.
    var terminating: Script = .{ .gpa = gpa, .decide = &terminateOnLineTwo };
    defer terminating.deinit();
    script.driver_override = null;
    s.driver = terminating.driver();
    try testing.expectError(error.DebugTerminated, s.run(prog.chunk.proto));
    s.driver = script.driver();
    _ = try s.run(prog.chunk.proto);
    try testing.expectEqualSlices(u32, &.{ 2, 2, 2 }, script.breakpointLines(&buf));
}
