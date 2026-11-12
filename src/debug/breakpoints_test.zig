//! Tests for line breakpoints (doc 86 §5.2): binding, moving to the next
//! line with code, nested functions, pending breakpoints on a chunk that
//! loads later, and replacing a source's set while stopped.

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const testutil = @import("testutil.zig");
const interp = @import("../interp.zig");
const io = @import("../io.zig");

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;
const Breakpoint = session_mod.Breakpoint;
const Program = testutil.Program;
const Script = testutil.Script;

/// Set `lines` as the breakpoints of `source` and return the bindings.
fn setLines(s: *Session, source: []const u8, lines: []const u32, out: []Breakpoint) ![]Breakpoint {
    var reqs: [16]session_mod.BreakpointRequest = undefined;
    for (lines, 0..) |l, i| reqs[i] = .{ .line = l };
    try s.setBreakpoints(source, reqs[0..lines.len], out[0..lines.len]);
    return out[0..lines.len];
}

test "doc 86 P2: a line breakpoint stops at its line each time the line runs, and names its id" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local s = 0
        \\for i = 1, 3 do
        \\    s = s + i
        \\end
        \\return s
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();

    // Bound before the chunk is known to the session: pending, until `run`.
    var out: [4]Breakpoint = undefined;
    const bps = try setLines(&s, "main", &.{ 3, 5 }, &out);
    try testing.expect(!bps[0].verified);
    try testing.expectEqual(@as(u32, 3), bps[0].line);

    try testing.expectEqual(@as(i64, 6), (try s.run(prog.chunk.proto)).asInt());
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 3, 3, 5 }, script.breakpointLines(&buf));
    try testing.expectEqual(bps[0].id, script.seen.items[0].hit);
    try testing.expectEqual(bps[1].id, script.seen.items[3].hit);
    try testing.expect(bps[0].id != bps[1].id);
    // Both were verified when `run` indexed the chunk.
    try testing.expectEqual(@as(usize, 2), script.changed.items.len);
    try testing.expect(script.changed.items[0].verified and script.changed.items[1].verified);
}

test "doc 86 P2: a breakpoint on a line with no code moves to the next line that has code" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local a = 1
        \\
        \\-- a comment
        \\local b = a + 1
        \\return b
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    // Set at the entry stop, once the chunk is indexed.
    script.decide = &setOnEntry;
    _ = try s.run(prog.chunk.proto);
    try testing.expect(entry_bps[0].verified);
    try testing.expectEqual(@as(u32, 4), entry_bps[0].line);
    // Past the last line: no code anywhere after it.
    try testing.expect(!entry_bps[1].verified);
    try testing.expectEqual(@as(u32, 99), entry_bps[1].line);
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{4}, script.breakpointLines(&buf));
}

var entry_bps: [2]Breakpoint = undefined;

fn setOnEntry(_: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason == .entry) _ = setLines(s, "main", &.{ 2, 99 }, &entry_bps) catch @panic("setBreakpoints failed");
    return .@"continue";
}

test "doc 86 P2: a breakpoint binds in nested functions, and in every proto with code on its line" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function inner(x)
        \\    return x * 2
        \\end
        \\local twice = function(y) return inner(y) + inner(y) end
        \\return twice(3)
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [4]Breakpoint = undefined;
    _ = try setLines(&s, "main", &.{ 2, 4 }, &out);
    try testing.expectEqual(@as(i64, 12), (try s.run(prog.chunk.proto)).asInt());
    // Line 4 binds in the main chunk (making the closure) and in `twice`'s
    // body, which runs once; line 2 runs once per call of `inner`.
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 4, 4, 2, 2 }, script.breakpointLines(&buf));
    try testing.expectEqual(@as(u32, 1), script.seen.items[0].depth);
    try testing.expect(script.seen.items[1].depth > 1);
}

test "doc 86 P2: a pending breakpoint binds when a chunk with its name loads, and the driver hears of it" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    const source =
        \\local f = load("local n = ...\nprint(n)\nreturn n + 1", "mod")
        \\print(f(41))
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [4]Breakpoint = undefined;
    const bps = try setLines(&s, "mod", &.{2}, &out);
    try testing.expect(!bps[0].verified);

    _ = try s.run(prog.chunk.proto);
    try testing.expectEqualStrings("41\n42\n", sink.buffered());
    try testing.expectEqual(@as(usize, 1), script.changed.items.len);
    try testing.expectEqual(Breakpoint{ .id = bps[0].id, .line = 2, .verified = true }, script.changed.items[0]);
    var lines: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{2}, script.breakpointLines(&lines));
    try testing.expectEqual(bps[0].id, script.seen.items[0].hit);
}

fn clearAtFirstHit(self: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .breakpoint) return .@"continue";
    self.n += 1;
    if (self.n == 2) {
        // Keep line 3, drop line 4: line 3 keeps its id.
        var out: [1]Breakpoint = undefined;
        s.setBreakpoints("main", &.{.{ .line = 3 }}, &out) catch @panic("setBreakpoints failed");
        kept = out[0];
    }
    return .@"continue";
}

var kept: Breakpoint = undefined;

test "doc 86 P2: setBreakpoints while stopped replaces the source's set, and a line that stays keeps its id" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local s = 0
        \\for i = 1, 3 do
        \\    s = s + i
        \\    s = s * 1
        \\end
        \\return s
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &clearAtFirstHit };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [4]Breakpoint = undefined;
    const bps = try setLines(&s, "main", &.{ 3, 4 }, &out);
    _ = try s.run(prog.chunk.proto);
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 4, 3, 3 }, script.breakpointLines(&buf));
    try testing.expectEqual(bps[0].id, kept.id);
    try testing.expect(kept.verified);

    // An empty set drops the source's breakpoints, and the flag with them.
    _ = try setLines(&s, "main", &.{}, &out);
    try testing.expectEqual(@as(u32, 0), s.hooks.flags.load(.monotonic) & session_mod.Flags.breakpoints);
}

test "doc 86 P2: a breakpoint and a pause on the same instruction make one stop, reported as the breakpoint" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "local a = 1\nreturn a\n");
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{ .stop_on_entry = true });
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    _ = try setLines(&s, "main", &.{1}, &out);
    _ = try s.run(prog.chunk.proto);
    try testing.expectEqual(@as(usize, 2), script.seen.items.len);
    try testing.expectEqual(session_mod.Reason.breakpoint, script.seen.items[0].reason);
    try testing.expectEqual(session_mod.Reason.ended, script.seen.items[1].reason);
}

/// Run `source` with breakpoints on `lines` of the main chunk, and return
/// the breakpoint stops' lines in `buf`.
fn hitLines(source: [:0]const u8, lines: []const u32, buf: []u32) ![]u32 {
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
    var out: [8]Breakpoint = undefined;
    _ = try setLines(&s, "main", lines, &out);
    _ = try s.run(prog.chunk.proto);
    const got = script.breakpointLines(buf);
    return got;
}

test "doc 86 P2: a breakpoint on a one-line loop stops on every pass" {
    var buf: [16]u32 = undefined;
    const got = try hitLines("local s = 0\nfor i = 1, 3 do s = s + i end\nreturn s\n", &.{2}, &buf);
    try testing.expectEqualSlices(u32, &.{ 2, 2, 2 }, got);
}

test "doc 86 P2: a call returning into its line does not start a new visit" {
    var buf: [16]u32 = undefined;
    const got = try hitLines("local function f() return 1 end\nlocal x = f() + f()\nreturn x\n", &.{2}, &buf);
    try testing.expectEqualSlices(u32, &.{2}, got);
}

test "doc 86 P2: a coroutine resumed in the middle of a line goes on with that visit" {
    var buf: [16]u32 = undefined;
    const source =
        \\local co = coroutine.wrap(function()
        \\    for i = 1, 2 do coroutine.yield(i) end
        \\end)
        \\co()
        \\co()
        \\co()
    ;
    // One stop per pass of the loop: the resumes after each yield go on
    // with the pass the yield was in.
    const got = try hitLines(source, &.{2}, &buf);
    try testing.expectEqualSlices(u32, &.{ 2, 2 }, got);
}

const table_mod = @import("breakpoints.zig");

test "doc 86 P2: an empty or blank condition is no condition" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local s = 0
        \\for i = 1, 3 do
        \\    s = s + i
        \\end
        \\return s
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [2]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{ .{ .line = 3, .condition = "" }, .{ .line = 5, .condition = "  " } }, &out);
    _ = try s.run(prog.chunk.proto);
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 3, 3, 5 }, script.breakpointLines(&buf));
}

test "doc 86 P2: a re-sent line that a breakpoint moved to keeps that breakpoint, and its hits" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local s = 0
        \\
        \\for i = 1, 3 do
        \\    s = s + i
        \\end
        \\return s
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    // Asked for line 2 (no code): it binds to line 3.
    try s.setBreakpoints("main", &.{.{ .line = 2 }}, &out);
    _ = try s.run(prog.chunk.proto);
    const id = out[0].id;
    const bound = s.breakpoints.entry(id).?;
    try testing.expectEqual(@as(u32, 3), bound.line);
    const hits = bound.hits;
    try testing.expect(hits > 0);
    // The client sends back the line the breakpoint moved to.
    var again: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 3 }}, &again);
    try testing.expectEqual(id, again[0].id);
    try testing.expectEqual(hits, s.breakpoints.entry(id).?.hits);
}

test "doc 86 P2: a condition is parsed once, however many hits" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local s = 0
        \\for i = 1, 50 do
        \\    s = s + i
        \\end
        \\return s
    ;
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 3, .condition = "i % 10 == 0" }}, &out);
    _ = try s.run(prog.chunk.proto);
    var buf: [64]u32 = undefined;
    try testing.expectEqual(@as(usize, 5), script.breakpointLines(&buf).len);
    try testing.expectEqual(@as(u32, 1), s.breakpoints.entry(out[0].id).?.parses);
    // Re-sending the same condition keeps the parse.
    try s.setBreakpoints("main", &.{.{ .line = 3, .condition = "i % 10 == 0" }}, &out);
    try testing.expectEqual(@as(u32, 1), s.breakpoints.entry(out[0].id).?.parses);
    // A different one does not.
    try s.setBreakpoints("main", &.{.{ .line = 3, .condition = "i > 3" }}, &out);
    try testing.expectEqual(@as(u32, 0), s.breakpoints.entry(out[0].id).?.parses);
}

fn tableUnderFailure(gpa: std.mem.Allocator, root: *const @import("../bytecode.zig").Proto) !void {
    var t = table_mod.Table.init(gpa);
    defer t.deinit();
    var out: [2]Breakpoint = undefined;
    const reqs = [_]table_mod.Request{ .{ .line = 3, .condition = "i > 1" }, .{ .line = 5, .hit_condition = ">= 2" } };
    try t.set("main", &reqs, &out);
    try t.addChunk(root, null);
    // Replace the set once the chunk is known: the reuse path.
    try t.set("main", &reqs, &out);
    try t.set("main", reqs[0..1], out[0..1]);
}

test "doc 86 P2: the breakpoint table leaks and double-frees nothing when an allocation fails" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "local s = 0\nfor i = 1, 3 do\n    s = s + i\nend\nreturn s");
    defer prog.deinit();
    try testing.checkAllAllocationFailures(gpa, tableUnderFailure, .{prog.chunk.proto});
}

fn resetInCallback(ctx: *anyopaque, s: *Session, bp: Breakpoint) void {
    const script: *Script = @ptrCast(@alignCast(ctx));
    script.changed.append(script.gpa, bp) catch @panic("OOM in a test driver");
    var out: [1]Breakpoint = undefined;
    s.setBreakpoints("main", &.{.{ .line = bp.line }}, &out) catch @panic("setBreakpoints in a callback");
}

test "doc 86 P2: setBreakpoints from a breakpoint_changed callback is safe" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "local s = 0\nfor i = 1, 3 do\n    s = s + i\nend\nreturn s");
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &testutil.alwaysContinue };
    defer script.deinit();
    var d = script.driver();
    d.breakpoint_changed = &resetInCallback;
    script.driver_override = d;
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 3 }}, &out);
    _ = try s.run(prog.chunk.proto);
    var buf: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 3, 3 }, script.breakpointLines(&buf));
}
