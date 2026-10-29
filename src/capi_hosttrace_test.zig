//! Doc 63 Phase 2c: host calls recorded in precise loop roots, run by tier-1a.
//!
//! Every test counts the host invocations through the function's userdata:
//! exactly once per guest `.call`, in whichever tier ran it (H1). Each pairs
//! the traced run with a `trace_host_calls = false` control that gets the
//! same answer and the same call count, so a passing test cannot be a trace
//! that never formed: the traced run also asserts a precise trace with a
//! host site exists.

const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");
const mahina = @import("mahina");

const mh_value = capi.mh_value;
const mh_str = capi.mh_str;
const Status = capi.mh_status;

fn s(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

const Counter = struct { calls: u64 = 0, fail_at: i64 = -1 };

/// `hid(x)`: returns `x`. Pure: reads and allocates nothing.
fn hostId(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ vm, max_results };
    const c: *Counter = @ptrCast(@alignCast(userdata.?));
    c.calls += 1;
    if (nargs != 1) return .err_api;
    results.?[0] = args.?[0];
    nresults.* = 1;
    return .ok;
}

/// `hfail(x)`: returns `x`, but raises when `x` is the counter's `fail_at`.
fn hostFail(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = max_results;
    const c: *Counter = @ptrCast(@alignCast(userdata.?));
    c.calls += 1;
    if (nargs != 1) return .err_api;
    var x: i64 = 0;
    if (capi.mh_value_int(args.?[0], &x) == .ok and x == c.fail_at) {
        capi.mh_error_set(vm, s("host failed"));
        return .err_runtime;
    }
    results.?[0] = args.?[0];
    nresults.* = 1;
    return .ok;
}

/// `hcb(x)`: calls the global `cbf(x)` back through `mh_call`, which moves the
/// epoch (guest execution), and returns its result. A disturbing host.
fn hostCb(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = max_results;
    const c: *Counter = @ptrCast(@alignCast(userdata.?));
    c.calls += 1;
    if (nargs != 1) return .err_api;
    const box = vm.?;
    var f: mh_value = .{};
    if (capi.mh_global_get(box, s("cbf"), &f) != .ok) return .err_api;
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_call(box, f, args.?, 1, &r, 1, &n);
    if (st != .ok) return st;
    results.?[0] = if (n == 0) capi.mh_nil() else r[0];
    nresults.* = 1;
    return .ok;
}

const program =
    \\function cbf(x) return x + 1000 end
    \\function loop_id(n) local s = 0 for i = 1, n do s = s + hid(i) end return s end
    \\function loop_fail(n) local s = 0 for i = 1, n do s = s + hfail(i) end return s end
    \\function loop_cb(n) local s = 0 for i = 1, n do s = s + hcb(i) end return s end
    \\function loop_wide(n)
    \\  local a, b, c, s = 3, 4, 5, 0
    \\  for i = 1, n do local r = hid(i) s = s + r + a * b - c a = a + 1 end
    \\  return s, a
    \\end
;

const Fixture = struct {
    box: *capi.VmBox,
    id: Counter = .{},
    fail: Counter = .{},
    cb: Counter = .{},

    fn init(self: *Fixture, trace_host_calls: bool) !void {
        self.* = .{ .box = try capi.createVm(testing.allocator, .{}) };
        errdefer _ = capi.mh_vm_free(self.box);
        self.box.vm.trace.config.trace_host_calls = trace_host_calls;
        try testing.expectEqual(Status.ok, capi.mh_register_fn(self.box, s("hid"), &hostId, &self.id, null));
        try testing.expectEqual(Status.ok, capi.mh_register_fn(self.box, s("hfail"), &hostFail, &self.fail, null));
        try testing.expectEqual(Status.ok, capi.mh_register_fn(self.box, s("hcb"), &hostCb, &self.cb, null));
        var n: usize = 0;
        try testing.expectEqual(Status.ok, capi.mh_eval(self.box, s(program), s("prog"), null, 0, &n));
    }

    fn deinit(self: *Fixture) void {
        testing.expectEqual(Status.ok, capi.mh_vm_free(self.box)) catch unreachable;
    }

    fn evalInt(self: *Fixture, src: []const u8) !i64 {
        var out: [1]mh_value = undefined;
        var n: usize = 0;
        const st = capi.mh_eval(self.box, s(src), s("t"), &out, 1, &n);
        if (st != .ok) return error.EvalFailed;
        var x: i64 = 0;
        try testing.expectEqual(Status.ok, capi.mh_value_int(out[0], &x));
        return x;
    }

    /// Whether the trace cache holds a precise trace with `sites` host sites.
    fn hasHostTrace(self: *Fixture, sites: usize) bool {
        for (self.box.vm.trace.registry.cache.items) |t| {
            if (t.code.deopt_mode == .precise and t.code.host_sites.len == sites) return true;
        }
        return false;
    }
};

test "doc 63 2c: a pure host call in a loop is traced and called exactly once per iteration" {
    var traced: Fixture = undefined;
    try traced.init(true);
    defer traced.deinit();
    var control: Fixture = undefined;
    try control.init(false);
    defer control.deinit();
    const n: i64 = 5000;
    const want = @divExact(n * (n + 1), 2);
    try testing.expectEqual(want, try traced.evalInt("return loop_id(5000)"));
    try testing.expectEqual(want, try control.evalInt("return loop_id(5000)"));
    try testing.expectEqual(@as(u64, n), traced.id.calls);
    try testing.expectEqual(control.id.calls, traced.id.calls);
    try testing.expect(traced.hasHostTrace(1));
    try testing.expect(!control.hasHostTrace(1));
}

test "doc 63 2c: a wide window flushes every slot and keeps the results" {
    var traced: Fixture = undefined;
    try traced.init(true);
    defer traced.deinit();
    var control: Fixture = undefined;
    try control.init(false);
    defer control.deinit();
    try testing.expectEqual(try control.evalInt("return (loop_wide(3000))"), try traced.evalInt("return (loop_wide(3000))"));
    try testing.expectEqual(try control.evalInt("local _, a = loop_wide(3000) return a"), try traced.evalInt("local _, a = loop_wide(3000) return a"));
    try testing.expectEqual(control.id.calls, traced.id.calls);
    try testing.expect(traced.hasHostTrace(1));
}

test "doc 63 2c: a host that raises mid-loop is called once, and the catcher sees the loop's state" {
    var traced: Fixture = undefined;
    try traced.init(true);
    defer traced.deinit();
    var control: Fixture = undefined;
    try control.init(false);
    defer control.deinit();
    // Warm the trace on a loop that does not fail, then fail on iteration 3000.
    try testing.expectEqual(try control.evalInt("return loop_fail(2000)"), try traced.evalInt("return loop_fail(2000)"));
    try testing.expect(traced.hasHostTrace(1));
    traced.fail.fail_at = 3000;
    control.fail.fail_at = 3000;
    const src = "local ok, e = pcall(loop_fail, 5000) if ok then return -1 end return #e";
    try testing.expectEqual(try control.evalInt(src), try traced.evalInt(src));
    try testing.expectEqual(control.fail.calls, traced.fail.calls);
}

test "doc 63 2c: a host that calls back disturbs once, then the loop runs without the trace's call" {
    var traced: Fixture = undefined;
    try traced.init(true);
    defer traced.deinit();
    var control: Fixture = undefined;
    try control.init(false);
    defer control.deinit();
    try testing.expectEqual(try control.evalInt("return loop_cb(4000)"), try traced.evalInt("return loop_cb(4000)"));
    try testing.expectEqual(@as(u64, 4000), traced.cb.calls);
    try testing.expectEqual(control.cb.calls, traced.cb.calls);
    // The first disturbing call ended the native's tracing (Q4, threshold 1).
    try testing.expect(!traced.hasHostTrace(1));
}
