//! Tests for stepping (doc 86 §5.3): step in, over and out, a one-line
//! loop, a coroutine that yields or finishes during a step, an error that
//! unwinds past the step's frame, a breakpoint that ends a step, and
//! stepping by instruction.

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const testutil = @import("testutil.zig");
const interp = @import("../interp.zig");

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;
const Reason = session_mod.Reason;
const Breakpoint = session_mod.Breakpoint;
const Program = testutil.Program;
const Script = testutil.Script;

const in: Resume = .{ .step = .{ .kind = .in } };
const over: Resume = .{ .step = .{ .kind = .over } };
const out: Resume = .{ .step = .{ .kind = .out } };

/// One stop a test expects. `depth` is `vm.depth` at the stop (the main
/// chunk runs at 1); a stop in a coroutine sets `co` instead, and its
/// depth is not compared.
const Want = struct {
    reason: Reason,
    line: u32,
    depth: u32 = 1,
    co: bool = false,
};

fn ended() Want {
    return .{ .reason = .ended, .line = 0, .depth = 0 };
}

/// Run `source` with breakpoints on `lines` of the main chunk, answer the
/// stops with `plan` (then continue), and compare every stop to `want`.
fn expectStops(source: [:0]const u8, lines: []const u32, plan: []const Resume, want: []const Want) !void {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.followPlan, .plan = plan };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var reqs: [8]session_mod.BreakpointRequest = undefined;
    var bps: [8]Breakpoint = undefined;
    for (lines, 0..) |l, i| reqs[i] = .{ .line = l };
    try s.setBreakpoints("main", reqs[0..lines.len], bps[0..lines.len]);
    _ = try s.run(prog.chunk.proto);

    const seen = script.seen.items;
    errdefer for (seen, 0..) |x, i| std.debug.print("stop {d}: {s} line {d} depth {d} co {d}\n", .{ i, @tagName(x.reason), x.line, x.depth, x.co });
    try testing.expectEqual(want.len, seen.len);
    for (want, seen) |w, x| {
        try testing.expectEqual(w.reason, x.reason);
        try testing.expectEqual(w.line, x.line);
        try testing.expectEqual(w.co, x.co != 0);
        if (!w.co) try testing.expectEqual(w.depth, x.depth);
    }
}

const calls =
    \\local function f(x)
    \\    local y = x + 1
    \\    return y
    \\end
    \\local a = f(1) * 1
    \\local b = f(2) * 1
    \\return a + b
;

test "doc 86 P2: step over runs a call to its end and stops on the next line" {
    try expectStops(calls, &.{5}, &.{ over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 5 },
        .{ .reason = .step, .line = 6 },
        .{ .reason = .step, .line = 7 },
        ended(),
    });
}

test "doc 86 P2: step in enters the callee, and its return stops in the caller" {
    try expectStops(calls, &.{5}, &.{ in, in, in, in, in }, &.{
        .{ .reason = .breakpoint, .line = 5 },
        .{ .reason = .step, .line = 2, .depth = 2 },
        .{ .reason = .step, .line = 3, .depth = 2 },
        // The frame is gone: the first stoppable pc below it, the `* 1`
        // still on the line of the call. (With nothing left on that line,
        // as in `local a = f(1)`, it is the next line's first pc.)
        .{ .reason = .step, .line = 5 },
        .{ .reason = .step, .line = 6 },
        .{ .reason = .step, .line = 2, .depth = 2 },
        ended(),
    });
}

test "doc 86 P2: step out stops in the caller once the frame returns" {
    try expectStops(calls, &.{2}, &.{ out, over }, &.{
        .{ .reason = .breakpoint, .line = 2, .depth = 2 },
        .{ .reason = .step, .line = 5 },
        .{ .reason = .step, .line = 6 },
        // The breakpoint again, in f(2).
        .{ .reason = .breakpoint, .line = 2, .depth = 2 },
        ended(),
    });
}

test "doc 86 P2: step over on a function's last line stops in the caller" {
    try expectStops(calls, &.{3}, &.{ over, over }, &.{
        .{ .reason = .breakpoint, .line = 3, .depth = 2 },
        .{ .reason = .step, .line = 5 },
        .{ .reason = .step, .line = 6 },
        .{ .reason = .breakpoint, .line = 3, .depth = 2 },
        ended(),
    });
}

test "doc 86 P2: a breakpoint reached during a step stops there and ends the step" {
    try expectStops(calls, &.{ 5, 2 }, &.{over}, &.{
        .{ .reason = .breakpoint, .line = 5 },
        .{ .reason = .breakpoint, .line = 2, .depth = 2 },
        // The step is over: continue runs to the next breakpoint.
        .{ .reason = .breakpoint, .line = 2, .depth = 2 },
        ended(),
    });
}

test "doc 86 P2: step over on a one-line loop stops on every pass" {
    try expectStops("local s = 0\nfor i = 1, 3 do s = s + i end\nreturn s\n", &.{1}, &.{ over, over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 1 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 3 },
        ended(),
    });
}

test "doc 86 P2: step over skips a recursive call, which runs the same lines deeper" {
    const source =
        \\local function fact(n)
        \\    if n <= 1 then return 1 end
        \\    return n * fact(n - 1)
        \\end
        \\return fact(3)
    ;
    try expectStops(source, &.{5}, &.{ in, in, over }, &.{
        .{ .reason = .breakpoint, .line = 5 },
        .{ .reason = .step, .line = 2, .depth = 2 },
        .{ .reason = .step, .line = 3, .depth = 2 },
        // Lines 2 and 3 ran at depths 3 and 4, and the multiply after the
        // return is the same visit: the next stop is below the frame.
        .{ .reason = .step, .line = 5 },
        ended(),
    });
}

fn pauseThenStep(self: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .breakpoint or self.n > 0) return .@"continue";
    self.n += 1;
    s.requestPause();
    return over;
}

test "doc 86 P2: a pause that comes first ends the step" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, calls);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &pauseThenStep };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var bps: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 5 }}, &bps);
    _ = try s.run(prog.chunk.proto);
    const seen = script.seen.items;
    try testing.expectEqual(@as(usize, 3), seen.len);
    try testing.expectEqual(Reason.breakpoint, seen[0].reason);
    // The pause stops at the next stoppable instruction, still on line 5,
    // and the step is gone: continue runs to the end.
    try testing.expectEqual(Reason.pause, seen[1].reason);
    try testing.expectEqual(@as(u32, 5), seen[1].line);
    try testing.expectEqual(Reason.ended, seen[2].reason);
}

const coroutines =
    \\local co = coroutine.create(function(a)
    \\    local b = coroutine.yield(a + 1)
    \\    return b * 2
    \\end)
    \\local r1 = coroutine.resume(co, 1) and 1
    \\local r2 = coroutine.resume(co, 10) and 2
    \\return r1 + r2
;

test "doc 86 P2: step over a resume does not stop inside the coroutine" {
    try expectStops(coroutines, &.{5}, &.{ over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 5 },
        .{ .reason = .step, .line = 6 },
        .{ .reason = .step, .line = 7 },
        ended(),
    });
}

test "doc 86 P2: a coroutine that yields or finishes during a step stops in its resumer" {
    try expectStops(coroutines, &.{2}, &.{ over, over, in, over }, &.{
        .{ .reason = .breakpoint, .line = 2, .co = true },
        // The yield: the first stoppable pc in the resumer, the `and` on
        // the line of the resume.
        .{ .reason = .step, .line = 5 },
        .{ .reason = .step, .line = 6 },
        // Step in follows the resume into the coroutine, which goes on with
        // the visit its yield was in, so the next visit is line 3.
        .{ .reason = .step, .line = 3, .co = true },
        // The coroutine finishes: back in the resumer, mid-line again.
        .{ .reason = .step, .line = 6 },
        ended(),
    });
}

test "doc 86 P2: an error that unwinds past the step's frame stops where it is caught" {
    const source =
        \\local function bad()
        \\    error("boom")
        \\end
        \\local ok = pcall(bad) or 0
        \\return ok
    ;
    try expectStops(source, &.{2}, &.{ over, over }, &.{
        .{ .reason = .breakpoint, .line = 2, .depth = 2 },
        // The first stoppable pc below the unwound frame: the `or`, on the
        // line of the pcall, not the next line's visit.
        .{ .reason = .step, .line = 4 },
        .{ .reason = .step, .line = 5 },
        ended(),
    });
}

fn stepByInstruction(_: *Script, _: *Session, stop: Stop) Resume {
    if (stop.reason == .ended) return .@"continue";
    return .{ .step = .{ .kind = .in, .granularity = .instruction } };
}

fn pauseEveryStop(_: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .ended) s.requestPause();
    return .@"continue";
}

/// The stops of a run from the entry stop, each answered by `decide`.
fn stopCount(source: [:0]const u8, decide: *const fn (*Script, *Session, Stop) Resume) !usize {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = decide };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    _ = try s.run(prog.chunk.proto);
    return script.seen.items.len;
}

test "doc 86 P2: step in by instruction stops at every stoppable instruction" {
    const source =
        \\local function f(n) return n * 2 end
        \\local t = {}
        \\for i = 1, 4 do t[i] = f(i) end
        \\local co = coroutine.wrap(function() coroutine.yield(1) return 2 end)
        \\return co() + co() + #t
    ;
    // A pause at every stop stops at every stoppable instruction once.
    try testing.expectEqual(try stopCount(source, &pauseEveryStop), try stopCount(source, &stepByInstruction));
}

test "doc 86 P2: step over a generic for stops on its header each pass, and skips the body of a loop that runs none" {
    // `ipairs(t)` is a call, so the loop is the closing form (`tfor_prep`).
    try expectStops(
        \\local t = {10, 20}
        \\local s = 0
        \\for i, v in ipairs(t) do
        \\    s = s + v
        \\end
        \\local e = {}
        \\for i, v in ipairs(e) do
        \\    s = s + v
        \\end
        \\return s
    , &.{1}, &.{ over, over, over, over, over, over, over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 1 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 4 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 4 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 6 },
        .{ .reason = .step, .line = 7 },
        .{ .reason = .step, .line = 10 },
        ended(),
    });
}

test "doc 86 P2: step over a generic for without a closing value stops the same way" {
    try expectStops(
        \\local t = {x = 1}
        \\local n = 0
        \\for k, v in next, t do
        \\    n = n + v
        \\end
        \\return n
    , &.{1}, &.{ over, over, over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 1 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 4 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 6 },
        ended(),
    });
}

test "doc 86 P2: step over a while loop stops on its test each pass" {
    try expectStops(
        \\local n = 0
        \\while n < 2 do
        \\    n = n + 1
        \\end
        \\return n
    , &.{1}, &.{ over, over, over, over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 1 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 3 },
        .{ .reason = .step, .line = 2 },
        .{ .reason = .step, .line = 5 },
        ended(),
    });
}

test "doc 86 P2: step over a call that ends its statement stops on the next line" {
    // No operator follows the call, so nothing after it is on the call's line.
    try expectStops(
        \\local function f(x)
        \\    return x + 1
        \\end
        \\local a = f(1)
        \\local b = f(2)
        \\return a + b
    , &.{4}, &.{ over, over, over }, &.{
        .{ .reason = .breakpoint, .line = 4 },
        .{ .reason = .step, .line = 5 },
        .{ .reason = .step, .line = 6 },
        ended(),
    });
}
