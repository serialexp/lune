//! Doc 73 §7.5: tasks and the host's operations through the C API — the
//! host makes a pending operation, the guest awaits it, and the host
//! settles it later, either from its wait callback or between calls
//! (`MH_WAITING`, `mh_tasks_run`, `mh_task_result`).

const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");

const mh_value = capi.mh_value;
const mh_str = capi.mh_str;
const Status = capi.mh_status;

fn s(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn lastError(box: *capi.VmBox) []const u8 {
    const e = capi.mh_last_error(box);
    if (e.ptr) |p| return p[0..e.len];
    return "";
}

fn expectInt(v: mh_value, want: i64) !void {
    var got: i64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_value_int(v, &got));
    try testing.expectEqual(want, got);
}

fn expectBool(v: mh_value, want: bool) !void {
    var got: c_int = 0;
    try testing.expectEqual(Status.ok, capi.mh_value_bool(v, &got));
    try testing.expectEqual(want, got != 0);
}

/// The host's side: the operations `start_op` made, held by ref, and how
/// many times the wait callback ran.
const Host = struct {
    ops: [4]u64 = undefined,
    nops: usize = 0,
    waits: usize = 0,
    /// What the wait callback settles the oldest open operation with.
    settle_with: i64 = 41,
    next_open: usize = 0,

    fn op(self: *Host, box: *capi.VmBox, i: usize) !mh_value {
        var v: mh_value = .{};
        try testing.expectEqual(Status.ok, capi.mh_ref_get(box, self.ops[i], &v));
        return v;
    }

    fn settle(self: *Host, box: *capi.VmBox, i: usize, ok: bool, v: mh_value) !void {
        const o = try self.op(box, i);
        try testing.expectEqual(Status.ok, capi.mh_pending_settle(box, o, @intFromBool(ok), &[_]mh_value{v}, 1));
    }

    fn deinit(self: *Host, box: *capi.VmBox) void {
        for (self.ops[0..self.nops]) |r| _ = capi.mh_ref_free(box, r);
    }
};

/// `start_op()`: a new pending operation, returned to the guest.
fn hostStartOp(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ args, nargs, max_results };
    const host: *Host = @ptrCast(@alignCast(userdata.?));
    var op: mh_value = .{};
    if (capi.mh_pending_new(vm, &op) != .ok) return .err_api;
    if (capi.mh_ref_create(vm, op, &host.ops[host.nops]) != .ok) return .err_api;
    host.nops += 1;
    results.?[0] = op;
    nresults.* = 1;
    return .ok;
}

/// The wait callback: settle the oldest open operation.
fn hostWait(vm: ?*capi.VmBox, userdata: ?*anyopaque) callconv(.c) Status {
    const host: *Host = @ptrCast(@alignCast(userdata.?));
    host.waits += 1;
    if (host.next_open >= host.nops) {
        capi.mh_error_set(vm, s("nothing to wait for"));
        return .err_runtime;
    }
    var op: mh_value = .{};
    if (capi.mh_ref_get(vm, host.ops[host.next_open], &op) != .ok) return .err_api;
    host.next_open += 1;
    if (capi.mh_pending_settle(vm, op, 1, &[_]mh_value{capi.mh_int(host.settle_with)}, 1) != .ok) return .err_api;
    return .ok;
}

fn newVm(host: *Host) !*capi.VmBox {
    const box = try capi.createVm(testing.allocator, .{});
    errdefer _ = capi.mh_vm_free(box);
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("start_op"), &hostStartOp, host, null));
    return box;
}

fn freeVm(box: *capi.VmBox, host: *Host) void {
    host.deinit(box);
    std.debug.assert(capi.mh_vm_free(box) == .ok);
}

/// `mh_eval` of `src`, expecting `want`; its first result, held by ref.
fn evalHold(box: *capi.VmBox, src: []const u8, want: Status) !u64 {
    var r: [2]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_eval(box, s(src), s("test"), &r, 2, &n);
    if (st != want) std.debug.print("eval: {s} ({s})\n", .{ @tagName(st), lastError(box) });
    try testing.expectEqual(want, st);
    try testing.expect(n >= 1);
    var ref: u64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_ref_create(box, r[0], &ref));
    return ref;
}

fn taskResult(box: *capi.VmBox, ref: u64, out: []mh_value, n: *usize) Status {
    var t: mh_value = .{};
    std.debug.assert(capi.mh_ref_get(box, ref, &t) == .ok);
    return capi.mh_task_result(box, t, out.ptr, out.len, n);
}

test "doc 73 §7.5: an await on a host operation hands MH_WAITING back, and the task finishes once it is settled" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    const task = try evalHold(box, "local v = await start_op() return v + 1, 'done'", .waiting);
    defer _ = capi.mh_ref_free(box, task);
    try testing.expectEqual(@as(usize, 1), host.nops);

    var r: [2]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.waiting, taskResult(box, task, &r, &n));
    try testing.expectEqual(Status.waiting, capi.mh_tasks_run(box));

    try host.settle(box, 0, true, capi.mh_int(41));
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
    try testing.expectEqual(Status.ok, taskResult(box, task, &r, &n));
    try testing.expectEqual(@as(usize, 2), n);
    try expectInt(r[0], 42);
}

test "doc 73 §7.5: with a wait callback an await waits in place, and the entry runs as plain code" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    try testing.expectEqual(Status.ok, capi.mh_set_wait_fn(box, &hostWait, &host));
    var r: [2]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.ok, capi.mh_eval(box,
        s("local a = await start_op() local b = await start_op() local _, main = coroutine.running() return a + b, main"),
        s("test"), &r, 2, &n));
    try testing.expectEqual(@as(usize, 2), n);
    try expectInt(r[0], 82);
    try expectBool(r[1], true);
    try testing.expectEqual(@as(usize, 2), host.waits);
}

test "doc 73 §7.5: a failing wait callback raises its message where the guest awaits" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    try testing.expectEqual(Status.ok, capi.mh_set_wait_fn(box, &hostWait, &host));
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    // The task awaits an operation the callback never settles: it fails.
    host.next_open = 1;
    try testing.expectEqual(Status.err_runtime, capi.mh_eval(box, s("return await start_op()"), s("test"), &r, 1, &n));
    try testing.expect(std.mem.indexOf(u8, lastError(box), "nothing to wait for") != null);
    // The VM stays usable, and the operation still in flight is waited for
    // after the next chunk, as the CLI's drain would.
    host.next_open = 0;
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s("return 1"), s("test"), &r, 1, &n));
    try testing.expectEqual(@as(usize, 2), host.waits);
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
}

test "doc 73 §7.5: mh_call runs as a task once the VM has the task library" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s("function get() return (await start_op()) * 2 end"), s("test"), &r, 1, &n));
    var f: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_global_get(box, s("get"), &f));
    try testing.expectEqual(Status.waiting, capi.mh_call(box, f, null, 0, &r, 1, &n));
    try testing.expectEqual(@as(usize, 1), n);
    var task: u64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_ref_create(box, r[0], &task));
    defer _ = capi.mh_ref_free(box, task);
    try host.settle(box, 0, true, capi.mh_int(21));
    // `mh_call` doesn't drain; `mh_tasks_run` runs the woken task.
    try testing.expectEqual(Status.waiting, taskResult(box, task, &r, &n));
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
    try testing.expectEqual(Status.ok, taskResult(box, task, &r, &n));
    try testing.expectEqual(@as(usize, 1), n);
    try expectInt(r[0], 42);
}

test "doc 73 §7.5: a failed operation raises in the task awaiting it, which mh_task_result reports" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    const task = try evalHold(box, "return await start_op()", .waiting);
    defer _ = capi.mh_ref_free(box, task);
    var msg: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_string_new(box, s("disk on fire"), &msg));
    try host.settle(box, 0, false, msg);
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.err_runtime, taskResult(box, task, &r, &n));
    try testing.expectEqualStrings("disk on fire", lastError(box));
    // Reported once observed: the next run raises nothing.
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
}

test "doc 73 §7.5: a chunk without async runs as plain code; the tasks it starts wait for mh_tasks_run" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s(
        \\async function load() got = await start_op() end
        \\function go() return load() end
    ), s("test"), &r, 1, &n));
    // No async in this chunk: it runs plainly, and returns once `go` has
    // started the task, which waits.
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s("go() local _, main = coroutine.running() return main"), s("test"), &r, 1, &n));
    try expectBool(r[0], true);
    try testing.expectEqual(Status.waiting, capi.mh_tasks_run(box));
    try host.settle(box, 0, true, capi.mh_int(7));
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s("return got"), s("test"), &r, 1, &n));
    try expectInt(r[0], 7);
}

test "doc 73 §7.5: an await outside a task's own coroutine, with no callback, is an error" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.err_runtime, capi.mh_eval(box,
        s("return coroutine.wrap(function() return await start_op() end)()"), s("test"), &r, 1, &n));
    try testing.expect(std.mem.indexOf(u8, lastError(box), "await would block") != null);
}

test "doc 73 §7.5: misuse — no task, no pending operation, nothing loaded" {
    var host: Host = .{};
    const box = try newVm(&host);
    defer freeVm(box, &host);
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    // Before the library loads.
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
    try testing.expectEqual(Status.err_api, capi.mh_task_result(box, capi.mh_int(1), &r, 1, &n));
    // After.
    var op: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_pending_new(box, &op));
    try testing.expectEqual(Status.err_api, capi.mh_task_result(box, capi.mh_int(1), &r, 1, &n));
    try testing.expectEqual(Status.err_runtime, capi.mh_pending_settle(box, capi.mh_int(1), 1, null, 0));
    try testing.expect(std.mem.indexOf(u8, lastError(box), "not a pending operation") != null);
    // Settling twice.
    try testing.expectEqual(Status.ok, capi.mh_pending_settle(box, op, 1, null, 0));
    try testing.expectEqual(Status.ok, capi.mh_pending_new(box, &op));
    var ref: u64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_ref_create(box, op, &ref));
    defer _ = capi.mh_ref_free(box, ref);
    try testing.expectEqual(Status.ok, capi.mh_pending_settle(box, op, 1, null, 0));
    try testing.expectEqual(Status.ok, capi.mh_ref_get(box, ref, &op));
    try testing.expectEqual(Status.err_runtime, capi.mh_pending_settle(box, op, 1, null, 0));
    // A settled operation is a done task.
    try testing.expectEqual(Status.ok, capi.mh_task_result(box, op, &r, 1, &n));
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(Status.ok, capi.mh_tasks_run(box));
}
