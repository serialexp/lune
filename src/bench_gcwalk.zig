//! Doc 61 §6.3 (Phase 1, global Rule #20) — `zig build bench-gcwalk`
//! (ReleaseFast).
//!
//! The masked `.gc` root walk at its boundary: a register stack filled close
//! to its 65,536 slots by 200 Lua frames. Each frame has 170 locals, half
//! live across its recursive call and half dead, and passes 70 surplus
//! varargs to the next, so every frame owns a vararg alias span next to its
//! window (the call window's argument registers bring a frame to about 315
//! slots). The heap stays small (integers in every register), so a
//! collection's cost is the root walk. At the deepest frame a native
//! collects `reps` times twice: once with every proto maskable (the masked
//! walk) and once with every proto marked non-maskable (each frame kept
//! whole, the unmasked walk's work through the same code). Columns are the
//! best of `rounds` per-collection averages.
//!
//! Target (doc 61 §6.3): the masked walk within noise of the pre-masking
//! walk at this size. Run the same file in a `just shadow` tree of the
//! baseline for that A/B; there the two rows coincide, since `maskable`
//! gates nothing. Oct 2026: baseline 8.7–9.5 µs, masked 5.9–6.0 µs, whole
//! frames 3.4–3.6 µs; the masked-minus-whole gap is building the mask
//! (about 12 ns per frame). Informational, not a gate (global Rule #22).

const std = @import("std");
const mahina = @import("mahina");

const Value = mahina.value.Value;
const Vm = mahina.interp.Vm;

/// `f(depth)` plus the main chunk: `max_call_depth` frames at the probe.
const depth = mahina.interp.max_call_depth - 2;
const locals = 170;
const live_locals = 85;
const surplus = 70;
const reps = 2000;
const rounds = 7;

var g_io: std.Io = undefined;
var g_masked_ns: u64 = std.math.maxInt(u64);
var g_whole_ns: u64 = std.math.maxInt(u64);
var g_stack_top: usize = 0;
var g_frames: usize = 0;

fn source(gpa: std.mem.Allocator) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64]u8 = undefined;
    try out.appendSlice(gpa, "local function f(n, ...)\n");
    for (1..locals + 1) |i| try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "  local a{d} = n + {d}\n", .{ i, i }));
    try out.appendSlice(gpa, "  if n == 0 then probe() return 0 end\n  local d = 0");
    // The dead half: read once here, never after the call.
    for (live_locals + 1..locals + 1) |i| try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, " + a{d}", .{i}));
    try out.appendSlice(gpa, "\n  local r = f(n - 1");
    for (1..surplus + 1) |i| try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, ", a{d}", .{i}));
    try out.appendSlice(gpa, ")\n  return r + d");
    // The live half: read after the call.
    for (1..live_locals + 1) |i| try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, " + a{d}", .{i}));
    try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "\nend\nreturn f({d})\n", .{depth}));
    return out.toOwnedSliceSentinel(gpa, 0);
}

fn now() u64 {
    return @intCast(std.Io.Timestamp.now(g_io, .awake).nanoseconds);
}

fn timeCollects(vm: *Vm) u64 {
    const t0 = now();
    for (0..reps) |_| vm.collect();
    return (now() - t0) / reps;
}

fn setMaskable(vm: *Vm, on: bool) void {
    for (vm.frames[0..vm.depth]) |f| @constCast(f.closure.proto).maskable = on;
}

fn probe(ctx: *anyopaque, _: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    g_stack_top = vm.stack_top;
    g_frames = vm.depth;
    for (0..rounds) |_| {
        g_masked_ns = @min(g_masked_ns, timeCollects(vm));
        setMaskable(vm, false);
        g_whole_ns = @min(g_whole_ns, timeCollects(vm));
        setMaskable(vm, true);
    }
    return Value.nil();
}

pub fn main(init: std.process.Init) u8 {
    run(init.gpa, init.io) catch |e| {
        mahina.io.eprint("bench-gcwalk: error: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    g_io = io;
    const src = try source(gpa);
    defer gpa.free(src);
    var diags = mahina.diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina.parser.parse(gpa, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const native = try vm.heap.newNative(&probe, "probe");
    try vm.globals.set(vm.gpa, try vm.heap.internValue("probe"), Value.heap(&native.header));
    var chunk = try mahina.compiler.compile(gpa, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();
    if (diags.hasErrors()) return error.CompileFailed;
    if (!chunk.proto.protos[0].maskable) return error.NotMaskable;
    _ = try vm.run(chunk.proto);
    if (g_frames != mahina.interp.max_call_depth) return error.WrongDepth;
    mahina.io.print(
        \\bench-gcwalk: {d} frames, stack_top {d} of 65536, {d} collections per sample
        \\  masked walk:   {d: >8.2} us per collection
        \\  unmasked walk: {d: >8.2} us per collection
        \\
    , .{ g_frames, g_stack_top, reps, us(g_masked_ns), us(g_whole_ns) });
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}
