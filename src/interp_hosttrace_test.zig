//! Doc 63 §5.4: a traced host call is made exactly once, route by route,
//! under all ten equivalence legs (`interp_testutil.zig`).
//!
//! Every host here logs its first argument, so a test sees not just how many
//! calls ran but which iterations made them: a call replayed by a deopt, or
//! skipped by a trace that ran ahead, shows up as a repeated or missing entry.
//! `traced` counts the calls a trace made (the shim sets `suspended_trace`), so
//! the executing legs prove the route ran on a trace, not only in tier-0.

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const testing = std.testing;

const Vm = interp.Vm;
const Value = value.Value;

const util = @import("interp_testutil.zig");
const TraceMode = util.TraceMode;

/// One leg's host log. `setup` clears it, `inspect` checks it.
const Log = struct {
    var args: [512]i64 = undefined;
    var len: usize = 0;
    var traced: usize = 0;
    /// The calls the test expects: the arguments 1 .. `want`, in order.
    var want: usize = 0;
    /// The argument at which a host misbehaves (raises, returns a float,
    /// collects); 0 never.
    var at: i64 = 0;
    /// When set, the calls the test expects instead of 1 .. `want`.
    var expected: ?[]const i64 = null;
    /// Whether the executing legs must make some call from a trace.
    var expect_traced: bool = true;
    /// `hcol` and `hkill` at `at`: collect this many times, then raise if
    /// `fail`.
    var collects: u8 = 1;
    var fail: bool = false;
    /// What the misbehaving call saw: a recording in progress, the most
    /// retirements waiting on the deferred queue after its collections, and
    /// whether the trace it was called from (if any) had been doomed.
    var at_recording: bool = false;
    var deferred_seen: usize = 0;
    var doomed_suspended: bool = false;
    /// `hcount()` snapshots: how many cached traces had host sites.
    var counts: [4]usize = undefined;
    var ncounts: usize = 0;

    fn reset() void {
        len = 0;
        traced = 0;
        at_recording = false;
        deferred_seen = 0;
        doomed_suspended = false;
        ncounts = 0;
    }

    fn hostTraces(vm: *Vm) usize {
        var n: usize = 0;
        for (vm.trace.registry.cache.items) |t| {
            if (t.code.host_sites.len != 0) n += 1;
        }
        return n;
    }

    fn note(vm: *Vm, x: i64) void {
        args[len] = x;
        len += 1;
        if (vm.trace.suspended_trace != null) traced += 1;
    }
};

const Hosts = struct {
    fn arg(args: []const Value) !i64 {
        if (args.len < 1 or args[0].tag != .int) return error.TypeError;
        return args[0].asInt();
    }

    /// `hid(x)`: returns x.
    fn hid(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        const x = try arg(args);
        Log.note(vm, x);
        if (out.len == 0) return 0;
        out[0] = Value.int(x);
        return 1;
    }

    /// `hraise(x)`: returns x, except at `Log.at`, where it raises.
    fn hraise(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        const x = try arg(args);
        Log.note(vm, x);
        if (x == Log.at) return vm.raiseLocatedError("hraise", 1);
        if (out.len == 0) return 0;
        out[0] = Value.int(x);
        return 1;
    }

    /// `hfloat(x)`: returns x, except at `Log.at`, where it returns x + 0.5,
    /// so the result's tag differs from the one the trace recorded.
    fn hfloat(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        const x = try arg(args);
        Log.note(vm, x);
        if (out.len == 0) return 0;
        out[0] = if (x == Log.at) Value.float(@as(f64, @floatFromInt(x)) + 0.5) else Value.int(x);
        return 1;
    }

    /// `hcollect(x)`: returns x, after a full collection at `Log.at`, which
    /// moves the epoch (and so disturbs the native).
    fn hcollect(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        const x = try arg(args);
        Log.note(vm, x);
        if (x == Log.at) vm.collect();
        if (out.len == 0) return 0;
        out[0] = Value.int(x);
        return 1;
    }

    /// `hcol(x)`: returns x; at `Log.at` it collects `Log.collects` times
    /// first, then raises if `Log.fail`.
    fn hcol(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        const x = try arg(args);
        Log.note(vm, x);
        if (x == Log.at) {
            Log.at_recording = vm.trace.isRecording();
            for (0..Log.collects) |_| {
                vm.collect();
                Log.deferred_seen = @max(Log.deferred_seen, vm.trace.registry.deferred_retire.items.len);
            }
            if (Log.fail) return vm.raiseLocatedError("hcol", 1);
        }
        if (out.len == 0) return 0;
        out[0] = Value.int(x);
        return 1;
    }

    /// `hkill(x)`: returns x; at `Log.at` it drops the global `h1` and
    /// collects, which frees `h1`'s native if nothing else holds it, then
    /// raises if `Log.fail`.
    fn hkill(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        const x = try arg(args);
        Log.note(vm, x);
        if (x == Log.at) {
            try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("h1"), Value.nil());
            vm.collect();
            Log.deferred_seen = @max(Log.deferred_seen, vm.trace.registry.deferred_retire.items.len);
            if (vm.trace.suspended_trace) |t| Log.doomed_suspended = t.doomed;
            if (Log.fail) return vm.raiseLocatedError("hkill", 1);
        }
        if (out.len == 0) return 0;
        out[0] = Value.int(x);
        return 1;
    }

    /// `hcount()`: snapshots `Log.hostTraces` into `Log.counts`.
    fn hcount(_: ?*anyopaque, vmp: *anyopaque, _: []const Value, _: []Value) anyerror!usize {
        const vm: *Vm = @ptrCast(@alignCast(vmp));
        Log.counts[Log.ncounts] = Log.hostTraces(vm);
        Log.ncounts += 1;
        return 0;
    }

    // Never called: a host native dispatches through its binding.
    fn stub(_: *anyopaque, _: []const Value) anyerror!Value {
        return error.TypeError;
    }
};

fn install(vm: *Vm, name: []const u8, call: function.HostFn) !void {
    const gpa = vm.heap.gpa;
    const binding = try gpa.create(function.HostBinding);
    errdefer gpa.destroy(binding);
    binding.* = .{ .call = call, .name = try gpa.dupe(u8, name) };
    errdefer gpa.free(binding.name);
    const native = try vm.heap.newNative(&Hosts.stub, binding.name);
    native.host = binding;
    native.protocol = .host;
    try vm.globals.set(gpa, try vm.heap.internValue(name), Value.heap(&native.header));
}

fn setup(vm: *Vm) anyerror!void {
    Log.reset();
    try install(vm, "hid", &Hosts.hid);
    try install(vm, "hraise", &Hosts.hraise);
    try install(vm, "hfloat", &Hosts.hfloat);
    try install(vm, "hcollect", &Hosts.hcollect);
    try install(vm, "hcol", &Hosts.hcol);
    try install(vm, "hkill", &Hosts.hkill);
    try install(vm, "hcount", &Hosts.hcount);
    // Two more natives with `hid`'s behaviour, so a test can drop one.
    try install(vm, "h1", &Hosts.hid);
    try install(vm, "hid2", &Hosts.hid);
    try util.installCollect(vm);
}

/// Every leg made exactly the calls 1 .. `Log.want`, in order, and the legs
/// that execute traces made some of them from a trace. Not the stress legs:
/// their collection at every safepoint moves the epoch between the call and
/// its result, so the recorder refuses the host call (`host_barrier`) and no
/// host trace forms there.
fn inspect(vm: *Vm, mode: TraceMode) anyerror!void {
    if (Log.expected) |want| {
        testing.expectEqualSlices(i64, want, Log.args[0..Log.len]) catch |e| {
            std.debug.print("leg {s}: the calls differ\n", .{@tagName(mode)});
            return e;
        };
    } else {
        testing.expectEqual(Log.want, Log.len) catch |e| {
            std.debug.print("leg {s}: {d} calls, want {d}\n", .{ @tagName(mode), Log.len, Log.want });
            return e;
        };
        for (Log.args[0..Log.len], 1..) |x, i| testing.expectEqual(@as(i64, @intCast(i)), x) catch |e| {
            std.debug.print("leg {s}: call {d} had argument {d}\n", .{ @tagName(mode), i, x });
            return e;
        };
    }
    // Every deferred retirement was released by the end of the run.
    try testing.expectEqual(@as(usize, 0), vm.trace.registry.deferred_retire.items.len);
    try testing.expectEqual(@as(u32, 0), vm.trace.suspend_depth);
    try testing.expectEqual(@as(u32, 0), vm.trace.entry_leases);
    switch (mode) {
        .off, .record_only => try testing.expectEqual(@as(usize, 0), Log.traced),
        .record_execute_noopt, .record_execute, .record_execute_native => if (!vm.heap.gc_stress and Log.expect_traced) testing.expect(Log.traced > 0) catch |e| {
            std.debug.print("leg {s}: no call was made from a trace\n", .{@tagName(mode)});
            return e;
        },
    }
}

fn expectRoute(source: [:0]const u8, expected: []const u8, want: usize, at: i64) !void {
    Log.want = want;
    Log.at = at;
    Log.expected = null;
    try util.expectProgramTuned(source, expected, .{ .trace_host_calls = true, .setup = &setup, .inspect = &inspect });
}

/// A §5.10 run: the calls must be exactly `calls`, and `check` runs after
/// `inspect`'s common checks on every leg.
fn expectLifetime(source: [:0]const u8, expected: []const u8, calls: []const i64, check: *const fn (*Vm, TraceMode) anyerror!void) !void {
    Log.expected = calls;
    lifetime_check = check;
    defer {
        Log.expected = null;
        Log.expect_traced = true;
    }
    try util.expectProgramTuned(source, expected, .{ .trace_host_calls = true, .setup = &setup, .inspect = &inspectLifetime });
}

var lifetime_check: *const fn (*Vm, TraceMode) anyerror!void = undefined;

fn inspectLifetime(vm: *Vm, mode: TraceMode) anyerror!void {
    try inspect(vm, mode);
    try lifetime_check(vm, mode);
}

/// The legs in which host traces form: not tier-0, and not under GC stress
/// (see `inspect`).
fn hostTracing(vm: *const Vm, mode: TraceMode) bool {
    return mode != .off and !vm.heap.gc_stress;
}

fn executing(vm: *const Vm, mode: TraceMode) bool {
    return hostTracing(vm, mode) and mode != .record_only;
}

/// `1 .. n`, `reps` times over, into `buf`.
fn seq(buf: []i64, n: usize, reps: usize) []const i64 {
    var k: usize = 0;
    for (0..reps) |_| {
        for (1..n + 1) |i| {
            buf[k] = @intCast(i);
            k += 1;
        }
    }
    return buf[0..k];
}

test "doc 63 §5.4: the loop-done exit, every call once" {
    try expectRoute(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hid(i) end
        \\  return s
        \\end
        \\print(f(60))
        \\
    , "1830\n", 60, 0);
}

test "doc 63 §5.4: a guard failing before the call leaves the call to tier-0" {
    try expectRoute(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do
        \\    if i > 40 then s = s + 1 end
        \\    s = s + hid(i)
        \\  end
        \\  return s
        \\end
        \\print(f(60))
        \\
    , "1850\n", 60, 0);
}

test "doc 63 §5.4: a guard failing after the call resumes past it" {
    try expectRoute(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do
        \\    s = s + hid(i)
        \\    if i > 40 then s = s + 1 end
        \\  end
        \\  return s
        \\end
        \\print(f(60))
        \\
    , "1850\n", 60, 0);
}

test "doc 63 §5.4: a helper exit after the call never replays it" {
    try expectRoute(
        \\local d = {}
        \\for i = 1, 60 do d[i] = 1 end
        \\d[50] = 0
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hid(i) + i // d[i] end
        \\  return s
        \\end
        \\print((pcall(f, 60)))
        \\
    , "false\n", 50, 0);
}

test "doc 63 §5.4: an epoch exit resumes after the call with its result" {
    try expectRoute(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hcollect(i) end
        \\  return s
        \\end
        \\print(f(60))
        \\
    , "1830\n", 60, 30);
}

test "doc 63 §5.4: a result-tag exit resumes after the call with its result" {
    try expectRoute(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hfloat(i) end
        \\  return s
        \\end
        \\print(f(60))
        \\
    , "1830.5\n", 60, 30);
}

test "doc 63 §5.4: a raising host is called once and raises at the call" {
    try expectRoute(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hraise(i) end
        \\  return s
        \\end
        \\local ok, e = pcall(f, 60)
        \\print(ok, e)
        \\
    , "false\tmain:3: hraise\n", 30, 30);
}

// ---------------------------------------------------------------------------
// §5.10: GC lifetime across a callback. Each run checks the calls as above,
// that the deferred queue, the suspension and the leases are all back to
// zero at the end, and the event the test is about, in the legs where host
// traces form.
// ---------------------------------------------------------------------------

test "doc 63 §5.10 F1: a host function replaced and collected retires the traces that guard it" {
    var buf: [120]i64 = undefined;
    try expectLifetime(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hid(i) end
        \\  return s
        \\end
        \\print(f(60))
        \\hcount()
        \\hid = hid2
        \\collect()
        \\hcount()
        \\print(f(60))
        \\hcount()
        \\
    , "1830\n1830\n", seq(&buf, 60, 2), &struct {
        fn check(vm: *Vm, mode: TraceMode) anyerror!void {
            try testing.expectEqual(@as(usize, 3), Log.ncounts);
            if (!hostTracing(vm, mode)) return;
            // A trace guarded `hid`; the collection that freed it retired
            // that trace; the second run traced `hid2` afresh.
            try testing.expect(Log.counts[0] >= 1);
            try testing.expectEqual(@as(usize, 0), Log.counts[1]);
            try testing.expect(Log.counts[2] >= 1);
        }
    }.check);
}

test "doc 63 §5.9: a host function that disturbs once is blacklisted from every trace that calls it" {
    // `hcol(30)` collects from the trace, so the native has disturbed; the
    // next entry's `guard_native` fails and retires the trace, and no later
    // recording traces the call again (both runs end with no host trace).
    Log.at = 30;
    Log.collects = 1;
    Log.fail = false;
    var buf: [120]i64 = undefined;
    try expectLifetime(
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hcol(i) end
        \\  return s
        \\end
        \\print(f(60))
        \\print(f(60))
        \\hcount()
        \\
    , "1830\n1830\n", seq(&buf, 60, 2), &struct {
        fn check(vm: *Vm, mode: TraceMode) anyerror!void {
            if (!executing(vm, mode)) return;
            try testing.expect(vm.trace.host_blacklists >= 1);
            try testing.expectEqual(@as(usize, 0), Log.counts[0]);
        }
    }.check);
}

/// The recording-time runs: `g`'s trace pins a pattern nothing else holds,
/// and `hcol(5)`, called by tier-0 while `f`'s loop records, collects it.
/// The retirement waits on the deferred queue until the call lowers its
/// suspension, and the recording aborts (the epoch moved) without ever
/// having entered a trace. That call disturbs `hcol`, so no trace ever
/// calls it.
fn expectRecordingCollect(collects: u8, fail: bool) !void {
    Log.at = 5;
    Log.expect_traced = false;
    Log.collects = collects;
    Log.fail = fail;
    var buf: [60]i64 = undefined;
    const check = &struct {
        fn check(vm: *Vm, mode: TraceMode) anyerror!void {
            try testing.expectEqual(@as(usize, 0), Log.traced);
            if (!hostTracing(vm, mode)) return;
            try testing.expect(Log.at_recording);
            try testing.expect(Log.deferred_seen >= 1);
        }
    }.check;
    const prelude =
        \\local find = string.find
        \\local function g(p)
        \\  local n = 0
        \\  for i = 1, 200 do if find("ab12", p) then n = n + 1 end end
        \\  return n
        \\end
        \\print(g("%d" .. "+"))
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + hcol(i) end
        \\  return s
        \\end
        \\
    ;
    if (fail) {
        try expectLifetime(prelude ++ "print((pcall(f, 60)))\n", "200\nfalse\n", seq(&buf, 5, 1), check);
    } else {
        try expectLifetime(prelude ++ "print(f(60))\n", "200\n1830\n", seq(&buf, 60, 1), check);
    }
}

test "doc 63 §5.10: a recording-time callback that collects once defers the retirement it causes" {
    try expectRecordingCollect(1, false);
}

test "doc 63 §5.10: a recording-time callback that collects twice defers both and frees once" {
    try expectRecordingCollect(2, false);
}

test "doc 63 §5.10: a failing recording-time callback that collects still releases the queue" {
    try expectRecordingCollect(1, true);
    try expectRecordingCollect(2, true);
}

/// `hkill(40)`, called from the trace, drops `h1` and collects: the trace's
/// own pool names `h1`, so the trace it is suspended in is doomed, its
/// physical retirement waits for the entry lease, and the call returns into
/// the coherent exit (or raises through it).
fn expectDoomExecuting(fail: bool) !void {
    Log.at = 40;
    Log.fail = fail;
    var buf: [80]i64 = undefined;
    for (0..40) |i| {
        buf[2 * i] = @intCast(i + 1);
        buf[2 * i + 1] = @intCast(i + 1);
    }
    const check = &struct {
        fn check(vm: *Vm, mode: TraceMode) anyerror!void {
            if (!executing(vm, mode)) return;
            try testing.expect(Log.doomed_suspended);
            try testing.expect(Log.deferred_seen >= 1);
        }
    }.check;
    const prelude =
        \\local function f(n)
        \\  local s = 0
        \\  for i = 1, n do s = s + h1(i) + hkill(i) end
        \\  return s
        \\end
        \\
    ;
    if (fail) {
        try expectLifetime(prelude ++ "print((pcall(f, 40)))\n", "false\n", &buf, check);
    } else {
        try expectLifetime(prelude ++ "print(f(40))\n", "1640\n", &buf, check);
    }
}

test "doc 63 §5.10: a callback collection that dooms the executing trace, then a return" {
    try expectDoomExecuting(false);
}

test "doc 63 §5.10: a callback collection that dooms the executing trace, then a raise" {
    try expectDoomExecuting(true);
}
