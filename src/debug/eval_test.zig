//! Tests for the pure-read evaluator (doc 86 §7.3) and the breakpoint
//! conditions and hit counts built on it (§5.2).

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const eval = @import("eval.zig");
const testutil = @import("testutil.zig");
const interp = @import("../interp.zig");
const io = @import("../io.zig");
const keyframeser = @import("../keyframeser.zig");

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;
const Breakpoint = session_mod.Breakpoint;
const Program = testutil.Program;
const Script = testutil.Script;

/// The outcome as one line of text, for comparing.
fn render(buf: []u8, o: eval.Outcome) []const u8 {
    var w = io.Writer.fixed(buf);
    switch (o) {
        .ok => |v| switch (v) {
            .text => |t| w.print("text {s}", .{t}) catch unreachable,
            .value => |x| {
                w.writeAll("value ") catch unreachable;
                io.writeValue(&w, x) catch unreachable;
            },
        },
        .refused => |m| w.print("refused: {s}", .{m}) catch unreachable,
        .failed => |m| w.print("failed: {s}", .{m}) catch unreachable,
    }
    return w.buffered();
}

const Case = struct { expr: []const u8, want: []const u8 };

/// The expressions to evaluate at the first breakpoint stop, and what each
/// gave.
var cases: []const Case = &.{};
var got: [32][128]u8 = undefined;
var got_len: [32]usize = undefined;
var evaluated = false;

fn evaluateAtFirstHit(_: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .breakpoint or evaluated) return .@"continue";
    evaluated = true;
    for (cases, 0..) |c, i| {
        const o = s.evaluate(c.expr) catch @panic("evaluate failed");
        const r = render(&got[i], o);
        got_len[i] = r.len;
    }
    return .@"continue";
}

const program =
    \\local t = {1, 2, 3, name = "box"}
    \\local s = "hi"
    \\local n = 7
    \\local f = 2.5
    \\local mt = setmetatable({}, {__index = function() return 1 end, __add = function() return 0 end, __len = function() return 9 end})
    \\local function g() return n end
    \\print(n, f, #t, s, rawlen(mt), g)
;

fn runCases(want: []const Case) !void {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var prog = try Program.init(gpa, &vm, program);
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &evaluateAtFirstHit };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 7 }}, &out);
    cases = want;
    evaluated = false;
    _ = try s.run(prog.chunk.proto);
    try testing.expect(evaluated);
    for (want, 0..) |c, i| {
        testing.expectEqualStrings(c.want, got[i][0..got_len[i]]) catch |err| {
            std.debug.print("expression: {s}\n", .{c.expr});
            return err;
        };
    }
}

test "doc 86 P2: evaluate reads locals, fields, globals and operators" {
    try runCases(&.{
        .{ .expr = "n", .want = "value 7" },
        .{ .expr = "n * 2 + 1", .want = "value 15" },
        .{ .expr = "n / 2", .want = "value 3.5" },
        .{ .expr = "n // 2", .want = "value 3" },
        .{ .expr = "f > n or n == 7", .want = "value true" },
        .{ .expr = "t[2]", .want = "value 2" },
        .{ .expr = "t.name", .want = "value box" },
        .{ .expr = "t['name'] == 'box'", .want = "value true" },
        .{ .expr = "#t", .want = "value 3" },
        .{ .expr = "#s", .want = "value 2" },
        .{ .expr = "s .. '!' .. n", .want = "text hi!7" },
        .{ .expr = "`{s} {n} {t.missing}`", .want = "text hi 7 nil" },
        .{ .expr = "t.missing ?? 'dflt'", .want = "text dflt" },
        .{ .expr = "not t", .want = "value false" },
        .{ .expr = "n & 3", .want = "value 3" },
        .{ .expr = "print == nil", .want = "value false" },
        .{ .expr = "nosuchglobal", .want = "value nil" },
        .{ .expr = "'a' < 'b'", .want = "value true" },
    });
}

test "doc 86 P2: a dead local is unavailable, not a stale value" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var prog = try Program.init(gpa, &vm, "local unused = {}\nlocal n = 1\nprint(n)\n");
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &evaluateAtFirstHit };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 3 }}, &out);
    cases = &.{.{ .expr = "unused", .want = "refused: 'unused' is not available here (its register is dead)" }};
    evaluated = false;
    _ = try s.run(prog.chunk.proto);
    try testing.expectEqualStrings(cases[0].want, got[0][0..got_len[0]]);
}

test "doc 86 P2: evaluate refuses calls and metamethods, and faults as the program would" {
    try runCases(&.{
        .{ .expr = "g()", .want = "refused: evaluate does not call functions" },
        .{ .expr = "s:upper()", .want = "refused: evaluate does not call functions" },
        .{ .expr = "{}", .want = "refused: evaluate does not make tables" },
        .{ .expr = "mt.anything", .want = "refused: the field is absent and the table has an __index metamethod" },
        .{ .expr = "mt + 1", .want = "refused: the operand has a __add metamethod" },
        .{ .expr = "#mt", .want = "refused: the table has a __len metamethod" },
        .{ .expr = "s.len", .want = "refused: indexing a string goes through its metatable" },
        .{ .expr = "nil + 1", .want = "failed: attempt to perform arithmetic on a nil value" },
        .{ .expr = "n // 0", .want = "failed: attempt to perform 'n//0'" },
        .{ .expr = "t < 1", .want = "failed: attempt to compare table with number" },
        .{ .expr = "t .. 'x'", .want = "failed: attempt to concatenate a table value" },
        .{ .expr = "n.x", .want = "failed: attempt to index a number value" },
        .{ .expr = "n +", .want = "refused: the expression does not parse: expected an expression" },
        .{ .expr = "n, s", .want = "refused: evaluate takes one expression" },
    });
}

fn evaluateEveryStop(self: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .breakpoint) return .@"continue";
    self.n += 1;
    const o = s.evaluate("s .. 'zz' .. 'top' .. #t") catch @panic("evaluate failed");
    if (o != .ok or o.ok != .text) @panic("expected text");
    return .@"continue";
}

test "doc 86 P2: evaluating changes nothing: no string interned, no step taken, the same final snapshot" {
    const gpa = testing.allocator;
    const source =
        \\local t = {}
        \\local s = "a"
        \\for i = 1, 5 do
        \\    t[i] = s .. i
        \\end
        \\return #t
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
    var script: Script = .{ .gpa = gpa, .decide = &evaluateEveryStop };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    var out: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 4 }}, &out);
    _ = try s.run(prog.chunk.proto);
    s.detach();

    try testing.expectEqual(@as(usize, 5), script.n);
    try testing.expect(vm.heap.internedLookup("azztop1") == null);
    try testing.expectEqual(ref_vm.safepoint_seq, vm.safepoint_seq);
    const got_snap = try keyframeser.encodeSnapshot(gpa, &vm);
    defer gpa.free(got_snap);
    try testing.expectEqualSlices(u8, want, got_snap);
}

/// Run a five-pass loop with one breakpoint on its body, and return the
/// values of `i` at the stops.
fn stopsAt(req: session_mod.BreakpointRequest, script: *Script, buf: []i64) ![]i64 {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, "local s = 0\nfor i = 1, 5 do\n    s = s + i\nend\nreturn s\n");
    defer prog.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    var r = req;
    r.line = 3;
    try s.setBreakpoints("main", &.{r}, &out);
    if (out[0].message != null) return error.NotVerified;
    stop_values = buf;
    stop_count = 0;
    _ = try s.run(prog.chunk.proto);
    return buf[0..stop_count];
}

var stop_values: []i64 = &.{};
var stop_count: usize = 0;

fn recordI(_: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason != .breakpoint) return .@"continue";
    const o = s.evaluate("i") catch @panic("evaluate failed");
    stop_values[stop_count] = o.ok.value.asInt();
    stop_count += 1;
    return .@"continue";
}

test "doc 86 P2: a breakpoint condition stops only where it holds" {
    var script: Script = .{ .gpa = testing.allocator, .decide = &recordI };
    defer script.deinit();
    var buf: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{ 2, 4 }, try stopsAt(.{ .line = 0, .condition = "i % 2 == 0" }, &script, &buf));
}

test "doc 86 P2: hit conditions N, >= N and % N, counted where the condition holds" {
    var script: Script = .{ .gpa = testing.allocator, .decide = &recordI };
    defer script.deinit();
    var buf: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{3}, try stopsAt(.{ .line = 0, .hit_condition = "3" }, &script, &buf));
    try testing.expectEqualSlices(i64, &.{ 4, 5 }, try stopsAt(.{ .line = 0, .hit_condition = ">= 4" }, &script, &buf));
    try testing.expectEqualSlices(i64, &.{ 2, 4 }, try stopsAt(.{ .line = 0, .hit_condition = "% 2" }, &script, &buf));
    // Hits count only where the condition holds: the odd passes are 1, 3, 5.
    try testing.expectEqualSlices(i64, &.{5}, try stopsAt(.{ .line = 0, .condition = "i % 2 == 1", .hit_condition = "3" }, &script, &buf));
    try testing.expectError(error.NotVerified, stopsAt(.{ .line = 0, .hit_condition = "three" }, &script, &buf));
}

var console_lines: usize = 0;

fn countConsole(_: *anyopaque, _: *Session, text: []const u8) void {
    console_lines += 1;
    std.testing.expect(std.mem.indexOf(u8, text, "nil + 1") != null) catch @panic("console text");
}

test "doc 86 P2: a condition that cannot be evaluated counts as false, reported once" {
    var script: Script = .{ .gpa = testing.allocator, .decide = &recordI };
    defer script.deinit();
    console_lines = 0;
    var drv = script.driver();
    drv.console = &countConsole;
    script.driver_override = drv;
    var buf: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{}, try stopsAt(.{ .line = 0, .condition = "nil + 1" }, &script, &buf));
    try testing.expectEqual(@as(usize, 1), console_lines);
}

var grid_seen = false;

fn evaluateGrid(script: *Script, s: *Session, stop: Stop) Resume {
    if (stop.reason == .breakpoint and !evaluated) {
        // A collection flattens a numeric matrix into a grid; do that now,
        // and check it took, or this tests nothing.
        const o = s.evaluate("g") catch @panic("evaluate failed");
        grid_seen = switch (o) {
            .ok => |v| switch (v) {
                .value => |x| blk: {
                    if (!x.isHeap() or x.heapType() != .table) break :blk false;
                    const t = @import("../table.zig").Table.fromHeader(x.asHeap());
                    _ = s.vm.heap.inflateToGrid(t);
                    break :blk t.array.isGrid();
                },
                .text => false,
            },
            else => false,
        };
    }
    return evaluateAtFirstHit(script, s, stop);
}

test "doc 86 P2: evaluate reads a grid's rows without deflating it, and a row is no table's key" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var prog = try Program.init(gpa, &vm, "local g = { { 1, 2, 3 }, { 4, 5, 6 } }\nlocal t = { 1, x = 1 }\nprint(#g, #t)\nprint(g[2][3], t[1])\n");
    defer prog.deinit();
    var script: Script = .{ .gpa = gpa, .decide = &evaluateGrid };
    defer script.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, script.driver(), .{});
    defer s.detach();
    var out: [1]Breakpoint = undefined;
    try s.setBreakpoints("main", &.{.{ .line = 3 }}, &out);
    grid_seen = false;
    cases = &.{
        .{ .expr = "g[1][2]", .want = "value 2" },
        .{ .expr = "g[1] == g[1]", .want = "value true" },
        .{ .expr = "g[2][3] + g[1][1]", .want = "value 7" },
        .{ .expr = "#g[2]", .want = "value 3" },
        .{ .expr = "g[1][9]", .want = "value nil" },
        .{ .expr = "g[1].x", .want = "value nil" },
        .{ .expr = "t[g[1]]", .want = "value nil" },
        .{ .expr = "g[3]", .want = "value nil" },
    };
    evaluated = false;
    _ = try s.run(prog.chunk.proto);
    try testing.expect(evaluated);
    try testing.expect(grid_seen);
    for (cases, 0..) |c, i| {
        testing.expectEqualStrings(c.want, got[i][0..got_len[i]]) catch |err| {
            std.debug.print("expression: {s}\n", .{c.expr});
            return err;
        };
    }
    // Read only: the program prints what an undisturbed run prints.
    try testing.expectEqualStrings("2\t1\n6\t1\n", sink.buffered());
}
