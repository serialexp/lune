//! Doc 87 Phase 0: the glue census on real programs.
//!
//! `trace_glue_census.zig` tests the census on events written by hand.
//! These run a program and check what the interpreter's hooks reported, so
//! they exist only in a `-Djit-debug` build, where the hooks do
//! (`zig build test -Djit-debug=true`).

const std = @import("std");
const interp = @import("interp.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const jitdbg = @import("jitdbg.zig");
const nativegen = @import("nativegen.zig");
const census = @import("trace_glue_census.zig");

const testing = std.testing;
const Vm = interp.Vm;
const GlueCensus = census.GlueCensus;
const Shape = census.Shape;
const Flags = census.Flags;

/// Run `source` with the census on and hand it to `check`, closed
/// (`finish`). Every source keeps its driver loop on tier 0: the driver's
/// `a ~= b` is the program's only `jeq`, which the recorder is told to
/// refuse, so each call of a helper is a visit of the helper's loop from
/// tier 0. Native where there is a backend, tier 1a elsewhere: the census
/// watches tier 0 and is the same for both.
fn censusRun(source: [:0]const u8, expected_out: []const u8, comptime check: fn (*const GlueCensus) anyerror!void) !void {
    if (!jitdbg.enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = nativegen.is_x64_linux;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    vm.trace.config.refuse_op = .jeq;
    try vm.trace.enableGlueCensus();
    var out: [64]u8 = undefined;
    var sink = io.Writer.fixed(&out);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(expected_out, sink.buffered());
    const g = vm.trace.glue.?;
    g.finish();
    try testing.expectEqual(@as(u64, 0), g.stats.dropped);
    try check(g);
}

/// The windows with exactly these loops, events and flags.
fn countExact(g: *const GlueCensus, from: census.LoopKind, to: census.Outcome, shape: Shape, flags: Flags) u64 {
    var n: u64 = 0;
    var it = g.windows.iterator();
    while (it.next()) |e| {
        const k: census.WindowKey = @bitCast(e.key_ptr.*);
        if (k.from == from and k.to == to and k.shape_len == shape.len and k.shape_bits == shape.bits and k.flags == flags)
            n += e.value_ptr.*;
    }
    return n;
}

test "glue census (doc 87 Phase 0): two helpers' loops called in turn are RC and RBC windows" {
    try censusRun(
        \\local function sum(t)
        \\  local s = 0
        \\  for i = 1, #t do s = s + t[i] end
        \\  return s
        \\end
        \\local function weigh(t)
        \\  local s = 0
        \\  for i = 1, #t do s = s + t[i] * i end
        \\  return s
        \\end
        \\local t = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
        \\local a, b = {}, {}
        \\local acc = 0
        \\for round = 1, 400 do
        \\  if a ~= b then acc = acc + sum(t) + weigh(t) end
        \\end
        \\print(acc)
    , "652800\n", struct {
        fn check(g: *const GlueCensus) !void {
            // sum's loop ends, sum returns, the driver calls weigh.
            try testing.expect(countExact(g, .numeric_for, .numeric_for, Shape.of("RC"), .{}) >= 350);
            // weigh's loop ends, weigh returns, the driver's own loop goes
            // round on tier 0, the driver calls sum.
            try testing.expect(countExact(g, .numeric_for, .numeric_for, Shape.of("RBC"), .{}) >= 350);
            // Each helper's loop is visited once a round and ends there.
            try testing.expect(g.stats.opened >= 700 and g.stats.opened <= 800);
            try testing.expectEqual(@as(u64, 0), g.stats.ret_inside);
            try testing.expectEqual(@as(u64, 0), g.stats.lost);
        }
    }.check);
}

test "glue census (doc 87 Phase 0): a vararg helper under pcall marks its return and its call" {
    try censusRun(
        \\local function count(...)
        \\  local n = ...
        \\  local i, s = 0, 0
        \\  while i < n do
        \\    s = s + i
        \\    i = i + 1
        \\  end
        \\  return s
        \\end
        \\local a, b = {}, {}
        \\local acc = 0
        \\for round = 1, 400 do
        \\  if a ~= b then
        \\    local ok, v = pcall(count, 16)
        \\    acc = acc + v
        \\  end
        \\end
        \\print(acc)
    , "48000\n", struct {
        fn check(g: *const GlueCensus) !void {
            // One loop, entered again every round: a ring onto itself,
            // through the driver's loop.
            const flags: Flags = .{
                .ret_vararg = true,
                .ret_protected = true,
                .call_vararg = true,
                .call_protected = true,
            };
            try testing.expect(countExact(g, .while_loop, .while_loop, Shape.of("RBC"), flags) >= 350);
            try testing.expect(g.windowCount(.{
                .from = .while_loop,
                .to = .while_loop,
                .self_ring = true,
                .same_proto = true,
                .shape_len = 3,
                .shape_bits = Shape.of("RBC").bits,
                .flags = flags,
            }) >= 350);
        }
    }.check);
}

test "glue census (doc 87 Phase 0): a return from inside the loop is not a window" {
    try censusRun(
        \\local function find(t, x)
        \\  for i = 1, #t do
        \\    if t[i] >= x then return i end
        \\  end
        \\  return 0
        \\end
        \\local t = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
        \\local a, b = {}, {}
        \\local acc = 0
        \\for round = 1, 400 do
        \\  if a ~= b then acc = acc + find(t, 12) end
        \\end
        \\print(acc)
    , "4800\n", struct {
        fn check(g: *const GlueCensus) !void {
            // The trace leaves through the `>=` guard and tier 0 returns
            // from inside the loop: a visit, never a loop that ended.
            try testing.expect(g.stats.ret_inside >= 350);
            try testing.expect(g.totalWindows() <= 20);
        }
    }.check);
}
