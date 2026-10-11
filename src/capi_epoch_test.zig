//! Doc 63 Phase 1: `Heap.host_epoch` and `Native.disturbs`.
//!
//! The epoch moves at every §5.6 site: every C API entry not on the
//! exemption list, guest execution (`exec`, `callValue`, `execWithEntry`,
//! so also metamethod dispatch), every collection, and grid deflation. Each
//! exempt entry is shown to leave it alone, the other half of the contract
//! (`capi.bumpEpoch`). `disturbs` counts host calls during which the epoch
//! moved, through both invocation funnels (the dispatch `.call` arm and
//! `callValue`), on success and on failure, saturating.
//!
//! Each site is pinned on its own: a C API entry is called with an argument
//! it rejects right after its boundary bump, so no deeper site can stand in
//! for it, and the core sites are pinned by their exact delta.
//!
//! Nothing outside these tests reads either value yet (Phase 2c adds the
//! guard and admission readers).

const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");
const mahina = @import("mahina");

const Value = mahina.Value;
const Native = mahina.function.Native;
const mh_value = capi.mh_value;
const mh_str = capi.mh_str;
const Status = capi.mh_status;

fn s(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn newVm() !*capi.VmBox {
    return capi.createVm(testing.allocator, .{});
}

fn freeVm(box: *capi.VmBox) void {
    testing.expectEqual(Status.ok, capi.mh_vm_free(box)) catch unreachable;
}

fn epoch(box: *capi.VmBox) u64 {
    return box.vm.heap.host_epoch;
}

/// The VM value behind a C value (the same mapping as `capi.fromC`).
fn toValue(cv: mh_value) Value {
    return .{ .tag = @enumFromInt(cv.tag), .payload = .{ .bits = cv.payload } };
}

/// A value `capi.fromC` rejects (an unknown tag).
const bad: mh_value = .{ .tag = 0xff };

fn eval(box: *capi.VmBox, src: []const u8, out: []mh_value) !usize {
    var n: usize = 0;
    const st = capi.mh_eval(box, s(src), s("test"), out.ptr, out.len, &n);
    if (st != .ok) {
        const e = capi.mh_last_error(box);
        std.debug.print("eval failed: {s}\n", .{if (e.ptr) |p| p[0..e.len] else ""});
        return error.EvalFailed;
    }
    return n;
}

fn global(box: *capi.VmBox, name: []const u8) !mh_value {
    var v: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_global_get(box, s(name), &v));
    return v;
}

fn nativeOf(box: *capi.VmBox, name: []const u8) !*Native {
    const v = toValue(try global(box, name));
    return Native.fromHeader(v.asHeap());
}

/// Expect the epoch to have moved by exactly `delta` since `before`.
fn expectDelta(box: *capi.VmBox, what: []const u8, before: u64, delta: u64) !void {
    const got = epoch(box) -% before;
    if (got != delta) {
        std.debug.print("{s}: epoch moved by {d}, expected {d}\n", .{ what, got, delta });
        return error.EpochDelta;
    }
}

fn hostNop(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ vm, userdata, args, nargs, results, max_results };
    nresults.* = 0;
    return .ok;
}

test "doc 63 epoch: every non-exempt C API entry bumps at its boundary" {
    const box = try newVm();
    defer freeVm(box);
    var out: [1]mh_value = undefined;
    _ = try eval(box, "T = {1, 2, 3} f = function() return 7 end", &out);
    const t = try global(box, "T");
    const f = try global(box, "f");
    var n: usize = 0;
    var b: u64 = undefined;

    // Each call fails its first argument check, which sits right after the
    // bump: the delta is the boundary bump alone.
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_compile(box, s("return 1"), s("c"), null));
    try expectDelta(box, "mh_compile", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_run(box, null, null, 0, &n));
    try expectDelta(box, "mh_run", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_eval(box, s("return 1"), s("e"), null, 0, null));
    try expectDelta(box, "mh_eval", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_call(box, f, null, 0, null, 0, null));
    try expectDelta(box, "mh_call", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mhCallViaH1(box, f, null, 0, null, 0, null));
    try expectDelta(box, "mhCallViaH1", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.hostcallReference(box, f, null, 0, null, 0, null));
    try expectDelta(box, "hostcallReference", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_global_get(box, s("g"), null));
    try expectDelta(box, "mh_global_get", b, 1);
    b = epoch(box);
    try testing.expect(capi.mh_global_set(box, s("g"), bad) != .ok);
    try expectDelta(box, "mh_global_set", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_ref_create(box, t, null));
    try expectDelta(box, "mh_ref_create", b, 1);
    b = epoch(box);
    try testing.expect(capi.mh_ref_free(box, 0xdead_beef) != .ok);
    try expectDelta(box, "mh_ref_free", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_register_fn(box, s("nop"), null, null, null));
    try expectDelta(box, "mh_register_fn", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_table_get(box, t, capi.mh_int(1), null));
    try expectDelta(box, "mh_table_get", b, 1);
    b = epoch(box);
    try testing.expect(capi.mh_table_set(box, bad, capi.mh_int(1), capi.mh_int(9)) != .ok);
    try expectDelta(box, "mh_table_set", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_table_len(box, t, null));
    try expectDelta(box, "mh_table_len", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_table_metatable_get(box, t, null));
    try expectDelta(box, "mh_table_metatable_get", b, 1);
    b = epoch(box);
    try testing.expect(capi.mh_table_metatable_set(box, bad, capi.mh_nil()) != .ok);
    try expectDelta(box, "mh_table_metatable_set", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_table_iter_new(box, t, null));
    try expectDelta(box, "mh_table_iter_new", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.err_api, capi.mh_table_iter_next(box, null, null, null, null));
    try expectDelta(box, "mh_table_iter_next", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.ok, capi.mh_table_iter_free(box, null));
    try expectDelta(box, "mh_table_iter_free", b, 1);

    // `mh_collect` has no rejecting argument: its boundary bump plus the
    // collection's own.
    b = epoch(box);
    try testing.expectEqual(Status.ok, capi.mh_collect(box));
    try expectDelta(box, "mh_collect", b, 2);

    // The successful paths still move it (a plain table read reaches no
    // deeper site, so it is the boundary bump again).
    var v: mh_value = .{};
    b = epoch(box);
    try testing.expectEqual(Status.ok, capi.mh_table_get(box, t, capi.mh_int(1), &v));
    try expectDelta(box, "mh_table_get (ok)", b, 1);
    b = epoch(box);
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("nop"), &hostNop, null, null));
    try expectDelta(box, "mh_register_fn (ok)", b, 1);
}

test "doc 63 epoch: the exempt C API entries leave it alone" {
    const box = try newVm();
    defer freeVm(box);
    var out: [1]mh_value = undefined;
    _ = try eval(box, "S = 'abc' print('out')", &out);
    const sv = try global(box, "S");
    var ref: u64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_ref_create(box, sv, &ref));
    defer _ = capi.mh_ref_free(box, ref);
    var sb: *capi.ScriptBox = undefined;
    try testing.expectEqual(Status.ok, capi.mh_compile(box, s("return 1"), s("c"), &sb));

    const before = epoch(box);
    // Value constructors and readers.
    var i: i64 = 0;
    var fl: f64 = 0;
    var bo: c_int = 0;
    _ = capi.mh_nil();
    _ = capi.mh_bool(1);
    _ = capi.mh_float(1.5);
    const iv = capi.mh_int(3);
    _ = capi.mh_value_type(iv);
    _ = capi.mh_value_truthy(iv);
    try testing.expectEqual(Status.ok, capi.mh_value_int(iv, &i));
    try testing.expectEqual(Status.ok, capi.mh_value_float(iv, &fl));
    try testing.expectEqual(Status.ok, capi.mh_value_bool(capi.mh_bool(0), &bo));
    try expectDelta(box, "value constructors and readers", before, 0);
    var str: mh_str = .{};
    try testing.expectEqual(Status.ok, capi.mh_value_str(box, sv, &str));
    try expectDelta(box, "mh_value_str", before, 0);
    // Exempt allocations.
    var nv: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_string_new(box, s("fresh string"), &nv));
    try expectDelta(box, "mh_string_new", before, 0);
    try testing.expectEqual(Status.ok, capi.mh_table_new(box, &nv));
    try expectDelta(box, "mh_table_new", before, 0);
    try testing.expectEqual(Status.ok, capi.mh_ref_get(box, ref, &nv));
    try expectDelta(box, "mh_ref_get", before, 0);
    capi.mh_error_set(box, s("staged"));
    try expectDelta(box, "mh_error_set", before, 0);
    // Box-side readers and clears.
    _ = capi.mh_last_error(box);
    _ = capi.mh_output(box);
    capi.mh_output_clear(box);
    _ = capi.mh_warnings(box);
    capi.mh_warnings_clear(box);
    var ms: capi.mh_mem_stats = undefined;
    try testing.expectEqual(Status.ok, capi.mh_mem_stats_get(box, &ms));
    try expectDelta(box, "box-side readers and clears", before, 0);
    capi.mh_script_free(sb);
    try expectDelta(box, "mh_script_free", before, 0);
    // Another VM's lifecycle does not touch this one.
    var other: *capi.VmBox = undefined;
    try testing.expectEqual(Status.ok, capi.mh_vm_new(null, &other));
    try testing.expectEqual(Status.ok, capi.mh_vm_free(other));
    try expectDelta(box, "mh_vm_new/mh_vm_free of another VM", before, 0);
}

/// Tries to free its own VM mid-call, which `mh_vm_free` refuses; reports
/// whether the refusal left the epoch alone.
fn hostFreesSelf(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ userdata, args, nargs, max_results };
    const before = epoch(vm.?);
    const st = capi.mh_vm_free(vm);
    results.?[0] = capi.mh_bool(@intFromBool(st == .err_api and epoch(vm.?) == before));
    nresults.* = 1;
    return .ok;
}

test "doc 63 epoch: mh_vm_free refused mid-call leaves it alone" {
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("frees"), &hostFreesSelf, null, null));
    var out: [1]mh_value = undefined;
    _ = try eval(box, "return frees()", &out);
    try testing.expectEqual(@as(u8, @intFromEnum(capi.mh_type.boolean)), @intFromEnum(capi.mh_value_type(out[0])));
    try testing.expectEqual(@as(c_int, 1), capi.mh_value_truthy(out[0]));
}

test "doc 63 epoch: guest execution, metamethods, collection and grid deflation move it" {
    const box = try newVm();
    defer freeVm(box);
    const vm = &box.vm;
    var out: [1]mh_value = undefined;
    _ = try eval(box,
        \\f = function(x) return x + 1 end
        \\P = setmetatable({}, { __index = function(t, k) return k end })
    , &out);
    const f = toValue(try global(box, "f"));
    const p = toValue(try global(box, "P"));
    const native = toValue(try global(box, "tostring"));
    var b: u64 = undefined;

    // `exec`, which `Vm.run`/`start`/resume enter (the CLI and replay; the
    // C API runs chunks as closures through `callValue`): a call-free chunk
    // reaches no other site.
    var sb: *capi.ScriptBox = undefined;
    try testing.expectEqual(Status.ok, capi.mh_compile(box, s("return 1"), s("c"), &sb));
    defer capi.mh_script_free(sb);
    b = epoch(box);
    try testing.expectEqual(@as(i64, 1), (try vm.run(sb.proto)).asInt());
    try expectDelta(box, "Vm.run of a call-free chunk", b, 1);
    // `mh_run`: the boundary bump, then `callValue` and `execWithEntry`.
    var n: usize = 0;
    b = epoch(box);
    try testing.expectEqual(Status.ok, capi.mh_run(box, sb, null, 0, &n));
    try expectDelta(box, "mh_run of a call-free chunk", b, 3);

    // `callValue` on a native reaches no other site; on a closure it adds
    // `execWithEntry`'s.
    var res: [1]Value = undefined;
    b = epoch(box);
    _ = try vm.callValue(native, &.{Value.int(1)}, &res);
    try expectDelta(box, "callValue(native)", b, 1);
    b = epoch(box);
    _ = try vm.callValue(f, &.{Value.int(1)}, &res);
    try expectDelta(box, "callValue(closure)", b, 2);

    // `__index` dispatch, reached without the C API.
    b = epoch(box);
    _ = try vm.indexGet(p, Value.int(5));
    try testing.expect(epoch(box) != b);

    // Every collection.
    b = epoch(box);
    vm.collect();
    try expectDelta(box, "collect", b, 1);

    // Grid deflation, the path a C API read takes without guest reentry.
    // Built through the VM's own (tracking) allocator: deflation frees the
    // grid storage through it.
    const gpa = vm.gpa;
    const t = try mahina.table.Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try mahina.array.ArrayPart.initGrid(gpa, 2, 3, .i32);
    b = epoch(box);
    try vm.heap.deflateGrid(t);
    try expectDelta(box, "deflateGrid", b, 1);
}

// --- Native.disturbs ---------------------------------------------------------

/// A host that only computes: never disturbs.
fn hostPure(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ vm, userdata, max_results };
    if (nargs < 1) return .err_api;
    var x: i64 = 0;
    if (capi.mh_value_int(args.?[0], &x) != .ok) return .err_api;
    results.?[0] = capi.mh_int(x * 2);
    nresults.* = 1;
    return .ok;
}

/// A host that allocates through exempt entries only: never disturbs.
fn hostAllocs(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ userdata, args, nargs, max_results };
    var t: mh_value = .{};
    if (capi.mh_table_new(vm, &t) != .ok) return .err_api;
    var str: mh_value = .{};
    if (capi.mh_string_new(vm, s("made by host"), &str) != .ok) return .err_api;
    results.?[0] = t;
    nresults.* = 1;
    return .ok;
}

/// A host that calls back into the guest (`cb`), then succeeds, or fails
/// when `userdata` points at `true`.
fn hostCallsBack(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ args, nargs, max_results };
    const fail: *const bool = @ptrCast(userdata.?);
    var cb: mh_value = .{};
    if (capi.mh_global_get(vm, s("cb"), &cb) != .ok) return .err_api;
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    if (capi.mh_call(vm, cb, null, 0, &r, 1, &n) != .ok) return .err_api;
    if (fail.*) {
        capi.mh_error_set(vm, s("host fails after its callback"));
        return .err_runtime;
    }
    results.?[0] = r[0];
    nresults.* = 1;
    return .ok;
}

test "doc 63 disturbs: pure and allocating hosts never disturb" {
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("pure"), &hostPure, null, null));
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("allocs"), &hostAllocs, null, null));
    var out: [1]mh_value = undefined;
    _ = try eval(box,
        \\local s = 0
        \\for i = 1, 300 do s = s + pure(i) local t = allocs() end
        \\return s
    , &out);
    try testing.expectEqual(@as(u8, 0), (try nativeOf(box, "pure")).disturbs);
    try testing.expectEqual(@as(u8, 0), (try nativeOf(box, "allocs")).disturbs);
}

test "doc 63 disturbs: a calling-back host counts on success and on failure, through both funnels" {
    const box = try newVm();
    defer freeVm(box);
    var fail = false;
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("back"), &hostCallsBack, &fail, null));
    var out: [1]mh_value = undefined;
    _ = try eval(box, "cb = function() return 5 end", &out);
    const nat = try nativeOf(box, "back");
    try testing.expectEqual(@as(u8, 0), nat.disturbs);

    // The dispatch `.call` arm.
    _ = try eval(box, "return back()", &out);
    try testing.expectEqual(@as(u8, 1), nat.disturbs);

    // `callValue`'s `.native` arm, through `pcall` and through `mh_call`.
    _ = try eval(box, "return pcall(back)", &out);
    try testing.expectEqual(@as(u8, 2), nat.disturbs);
    const back = try global(box, "back");
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.ok, capi.mh_call(box, back, null, 0, &r, 1, &n));
    try testing.expectEqual(@as(u8, 3), nat.disturbs);

    // A failing return counts the same, in both funnels.
    fail = true;
    var n2: usize = 0;
    try testing.expectEqual(Status.err_runtime, capi.mh_eval(box, s("return back()"), s("t"), &out, 1, &n2));
    try testing.expectEqual(@as(u8, 4), nat.disturbs);
    _ = try eval(box, "return pcall(back)", &out);
    try testing.expectEqual(@as(u8, 5), nat.disturbs);

    // Saturating.
    fail = false;
    nat.disturbs = std.math.maxInt(u8);
    _ = try eval(box, "return back()", &out);
    try testing.expectEqual(std.math.maxInt(u8), nat.disturbs);
}

test "doc 63 epoch: a staged host error followed by a successful return raises nothing" {
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("stages"), &hostStagesThenSucceeds, null, null));
    var out: [1]mh_value = undefined;
    const n = try eval(box, "return stages()", &out);
    try testing.expectEqual(@as(usize, 1), n);
    var x: i64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_value_int(out[0], &x));
    try testing.expectEqual(@as(i64, 42), x);
    try testing.expectEqual(@as(u8, 0), (try nativeOf(box, "stages")).disturbs);
}

fn hostStagesThenSucceeds(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ userdata, args, nargs, max_results };
    capi.mh_error_set(vm, s("staged but never raised"));
    results.?[0] = capi.mh_int(42);
    nresults.* = 1;
    return .ok;
}
