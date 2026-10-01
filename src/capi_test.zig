//! Tests for the C-ABI embedding surface (`src/capi.zig`, doc 59).
//!
//! Everything goes through the exported `mh_*` functions exactly as a C/Rust
//! embedder would (the exports are plain Zig functions too), except VM
//! construction, which uses `capi.createVm(std.testing.allocator, …)` so the
//! leak-checking test allocator covers the whole VM + box.

const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");
const mahina = @import("mahina");

const mh_value = capi.mh_value;
const mh_str = capi.mh_str;

fn s(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn newVm() !*capi.VmBox {
    return capi.createVm(testing.allocator, .{});
}

fn newVmNoJit() !*capi.VmBox {
    return capi.createVm(testing.allocator, .{ .jit = 2 });
}

fn freeVm(box: *capi.VmBox) void {
    try_free(box) catch unreachable;
}

fn try_free(box: *capi.VmBox) !void {
    try testing.expectEqual(capi.mh_status.ok, capi.mh_vm_free(box));
}

fn evalOne(box: *capi.VmBox, src: []const u8) !mh_value {
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_eval(box, s(src), s("test"), &results, 1, &n);
    if (st != .ok) {
        std.debug.print("eval failed: {s}\n", .{lastError(box)});
        return error.EvalFailed;
    }
    try testing.expectEqual(@as(usize, 1), n);
    return results[0];
}

fn lastError(box: *capi.VmBox) []const u8 {
    const e = capi.mh_last_error(box);
    if (e.ptr) |p| return p[0..e.len];
    return "";
}

fn expectInt(v: mh_value, want: i64) !void {
    var got: i64 = 0;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_value_int(v, &got));
    try testing.expectEqual(want, got);
}

fn expectStrEql(box: *capi.VmBox, v: mh_value, want: []const u8) !void {
    var sv: mh_str = .{};
    try testing.expectEqual(capi.mh_status.ok, capi.mh_value_str(box, v, &sv));
    try testing.expectEqualStrings(want, sv.ptr.?[0..sv.len]);
}

test "lifecycle: create and free, no leaks" {
    const box = try newVm();
    try try_free(box);
}

test "eval: scalar arithmetic" {
    const box = try newVm();
    defer freeVm(box);
    const v = try evalOne(box, "return 1 + 2");
    try testing.expectEqual(capi.mh_type.int, capi.mh_value_type(v));
    try expectInt(v, 3);
}

test "eval: multiple results and truncation" {
    const box = try newVm();
    defer freeVm(box);
    var results: [4]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_eval(box, s("return 1, 'two', true"), s("t"), &results, 4, &n));
    try testing.expectEqual(@as(usize, 3), n);
    try expectInt(results[0], 1);
    try expectStrEql(box, results[1], "two");
    try testing.expectEqual(capi.mh_type.boolean, capi.mh_value_type(results[2]));
    // results[3] is deliberately NOT inspected: beyond *nresults the buffer is
    // undefined by contract (no O(max_results) nil-fill per call).

    // Truncation: more results than the buffer wants is fine.
    try testing.expectEqual(capi.mh_status.ok, capi.mh_eval(box, s("return 1, 2, 3"), s("t"), &results, 2, &n));
    try testing.expectEqual(@as(usize, 2), n);
}

test "eval: float accessor accepts int and float" {
    const box = try newVm();
    defer freeVm(box);
    var f: f64 = 0;
    const vi = try evalOne(box, "return 21");
    try testing.expectEqual(capi.mh_status.ok, capi.mh_value_float(vi, &f));
    try testing.expectEqual(@as(f64, 21), f);
    const vf = try evalOne(box, "return 1.5");
    try testing.expectEqual(capi.mh_status.ok, capi.mh_value_float(vf, &f));
    try testing.expectEqual(@as(f64, 1.5), f);
}

test "compile error: status + diagnostics, VM stays usable" {
    const box = try newVm();
    defer freeVm(box);
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_eval(box, s("return +"), s("bad"), &results, 1, &n);
    try testing.expectEqual(capi.mh_status.err_compile, st);
    try testing.expect(lastError(box).len > 0);
    // Still usable.
    const v = try evalOne(box, "return 7");
    try expectInt(v, 7);
}

test "runtime error: located message, boundary restored, VM reusable" {
    const box = try newVm();
    defer freeVm(box);
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_eval(box, s("error('boom')"), s("errchunk"), &results, 1, &n);
    try testing.expectEqual(capi.mh_status.err_runtime, st);
    try testing.expect(std.mem.indexOf(u8, lastError(box), "boom") != null);
    // The protected entry restored the boundary: depth 0, next eval works.
    try testing.expectEqual(@as(u32, 0), box.vm.depth);
    const v = try evalOne(box, "return 8");
    try expectInt(v, 8);
}

test "runtime error: non-error fault (indexing nil) also restores" {
    const box = try newVm();
    defer freeVm(box);
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_eval(box, s("local t = nil\nreturn t.x"), s("f"), &results, 1, &n);
    try testing.expectEqual(capi.mh_status.err_runtime, st);
    try testing.expect(std.mem.indexOf(u8, lastError(box), "index") != null);
    const v = try evalOne(box, "return 9");
    try expectInt(v, 9);
}

test "compile once, run twice" {
    const box = try newVm();
    defer freeVm(box);
    var script: *capi.ScriptBox = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_compile(box, s("n = (n or 0) + 1\nreturn n"), s("inc"), &script));
    defer capi.mh_script_free(script);
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_run(box, script, &results, 1, &n));
    try expectInt(results[0], 1);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_run(box, script, &results, 1, &n));
    try expectInt(results[0], 2);
}

test "globals: set from host, read from guest, and back" {
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_global_set(box, s("answer"), capi.mh_int(42)));
    const v = try evalOne(box, "return answer");
    try expectInt(v, 42);

    _ = try evalOne(box, "greeting = 'hello'\nreturn 0");
    var g: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_global_get(box, s("greeting"), &g));
    try expectStrEql(box, g, "hello");
}

test "strings: intern from host, round trip through guest" {
    const box = try newVm();
    defer freeVm(box);
    var sv: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_string_new(box, s("from host"), &sv));
    try testing.expectEqual(capi.mh_type.string, capi.mh_value_type(sv));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_global_set(box, s("hs"), sv));
    const v = try evalOne(box, "return hs .. '!'");
    try expectStrEql(box, v, "from host!");
}

test "output capture: print goes to the sink, not stdout" {
    const box = try newVm();
    defer freeVm(box);
    _ = try evalOne(box, "print('captured')\nreturn 0");
    const out = capi.mh_output(box);
    try testing.expect(std.mem.indexOf(u8, out.ptr.?[0..out.len], "captured") != null);
    capi.mh_output_clear(box);
    try testing.expectEqual(@as(usize, 0), capi.mh_output(box).len);
}

test "refs: root a guest table across an explicit collect" {
    const box = try newVm();
    defer freeVm(box);
    const tv = try evalOne(box, "return { x = 42 }");
    var ref: u64 = 0;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_ref_create(box, tv, &ref));

    // A fresh eval clears the park; only the ref keeps the table alive now.
    _ = try evalOne(box, "return 0");
    try testing.expectEqual(capi.mh_status.ok, capi.mh_collect(box));

    var got: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_ref_get(box, ref, &got));
    var key: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_string_new(box, s("x"), &key));
    var x: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_get(box, got, key, &x));
    try expectInt(x, 42);

    try testing.expectEqual(capi.mh_status.ok, capi.mh_ref_free(box, ref));
    // Stale ref (freed slot, bumped generation) is a checked error.
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_ref_get(box, ref, &got));
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_ref_free(box, ref));
}

test "parked results survive a collect (the park is a root)" {
    const box = try newVm();
    defer freeVm(box);
    const tv = try evalOne(box, "return { y = 7 }");
    // No ref taken: only the park roots the table. mh_collect is
    // deliberately non-clearing.
    try testing.expectEqual(capi.mh_status.ok, capi.mh_collect(box));
    var key: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_string_new(box, s("y"), &key));
    var y: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_get(box, tv, key, &y));
    try expectInt(y, 7);
}

test "tables: new/set/get/len/metatable from the host" {
    const box = try newVm();
    defer freeVm(box);
    var t: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_new(box, &t));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_set(box, t, capi.mh_int(1), capi.mh_int(10)));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_set(box, t, capi.mh_int(2), capi.mh_int(20)));
    var len: i64 = 0;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_len(box, t, &len));
    try testing.expectEqual(@as(i64, 2), len);

    // Metatable with __index via a second table.
    var mt: mh_value = undefined;
    var idx: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_new(box, &mt));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_new(box, &idx));
    var k_index: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_string_new(box, s("__index"), &k_index));
    var k_fall: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_string_new(box, s("fallback"), &k_fall));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_set(box, idx, k_fall, capi.mh_int(99)));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_set(box, mt, k_index, idx));
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_metatable_set(box, t, mt));

    var got_mt: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_metatable_get(box, t, &got_mt));
    try testing.expectEqual(capi.mh_type.table, capi.mh_value_type(got_mt));

    // __index-aware get through the C API.
    var fb: mh_value = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_get(box, t, k_fall, &fb));
    try expectInt(fb, 99);
}

test "table iteration: deterministic order, O(1) steps" {
    const box = try newVm();
    defer freeVm(box);
    const tv = try evalOne(box, "return { 10, 20, 30, b = 2, a = 1 }");
    var it: *capi.IterBox = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_iter_new(box, tv, &it));
    defer _ = capi.mh_table_iter_free(box, it);

    // Array part first (ascending, exact), then the two hash keys in the
    // canonical (deterministic, but not humanly obvious) order.
    var vals: [5]i64 = undefined;
    var step: usize = 0;
    while (true) {
        var k: mh_value = undefined;
        var v: mh_value = undefined;
        var done: c_int = 0;
        try testing.expectEqual(capi.mh_status.ok, capi.mh_table_iter_next(box, it, &k, &v, &done));
        if (done != 0) break;
        try testing.expectEqual(capi.mh_status.ok, capi.mh_value_int(v, &vals[step]));
        step += 1;
    }
    try testing.expectEqual(@as(usize, 5), step);
    try testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, vals[0..3]);
    try testing.expect((vals[3] == 1 and vals[4] == 2) or (vals[3] == 2 and vals[4] == 1));

    // Determinism: a second pass yields the identical order.
    var it2: *capi.IterBox = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_table_iter_new(box, tv, &it2));
    defer _ = capi.mh_table_iter_free(box, it2);
    var step2: usize = 0;
    while (true) {
        var k: mh_value = undefined;
        var v: mh_value = undefined;
        var done: c_int = 0;
        try testing.expectEqual(capi.mh_status.ok, capi.mh_table_iter_next(box, it2, &k, &v, &done));
        if (done != 0) break;
        var got: i64 = 0;
        try testing.expectEqual(capi.mh_status.ok, capi.mh_value_int(v, &got));
        try testing.expectEqual(vals[step2], got);
        step2 += 1;
    }
    try testing.expectEqual(@as(usize, 5), step2);
}

test "mh_call: call a guest function from the host" {
    const box = try newVm();
    defer freeVm(box);
    const f = try evalOne(box, "return function(a, b) return a * b, a + b end");
    var results: [2]mh_value = undefined;
    var n: usize = 0;
    const args = [_]mh_value{ capi.mh_int(6), capi.mh_int(7) };
    try testing.expectEqual(capi.mh_status.ok, capi.mh_call(box, f, &args, 2, &results, 2, &n));
    try testing.expectEqual(@as(usize, 2), n);
    try expectInt(results[0], 42);
    try expectInt(results[1], 13);
}

test "mh_call: guest fault during call restores the boundary" {
    const box = try newVm();
    defer freeVm(box);
    const f = try evalOne(box, "return function() error('called-boom') end");
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(capi.mh_status.err_runtime, capi.mh_call(box, f, null, 0, &results, 1, &n));
    try testing.expect(std.mem.indexOf(u8, lastError(box), "called-boom") != null);
    try testing.expectEqual(@as(u32, 0), box.vm.depth);
    const v = try evalOne(box, "return 5");
    try expectInt(v, 5);
}

// --- host functions --------------------------------------------------------

const AddCtx = struct {
    calls: usize = 0,
    destroyed: bool = false,
};

fn hostAdd(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) capi.mh_status {
    _ = vm;
    const ctx: *AddCtx = @ptrCast(@alignCast(userdata.?));
    ctx.calls += 1;
    if (nargs < 2 or max_results < 1) return .err_api;
    var a: i64 = 0;
    var b: i64 = 0;
    if (capi.mh_value_int(args.?[0], &a) != .ok) return .err_api;
    if (capi.mh_value_int(args.?[1], &b) != .ok) return .err_api;
    results.?[0] = capi.mh_int(a + b);
    nresults.* = 1;
    return .ok;
}

fn hostDestroy(userdata: ?*anyopaque) callconv(.c) void {
    const ctx: *AddCtx = @ptrCast(@alignCast(userdata.?));
    ctx.destroyed = true;
}

test "host fn: register, call from guest, destructor at vm free" {
    var ctx: AddCtx = .{};
    {
        const box = try newVm();
        defer freeVm(box);
        try testing.expectEqual(capi.mh_status.ok, capi.mh_register_fn(box, s("add"), &hostAdd, &ctx, &hostDestroy));
        const v = try evalOne(box, "return add(2, 3)");
        try expectInt(v, 5);
        try testing.expectEqual(@as(usize, 1), ctx.calls);
        try testing.expect(!ctx.destroyed);
    }
    try testing.expect(ctx.destroyed);
}

test "host fn: module.field registration" {
    var ctx: AddCtx = .{};
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_register_fn(box, s("mymod.add"), &hostAdd, &ctx, null));
    const v = try evalOne(box, "return mymod.add(20, 22)");
    try expectInt(v, 42);
}

test "host fn: guest dropping the last reference runs the destructor at GC" {
    var ctx: AddCtx = .{};
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_register_fn(box, s("temp"), &hostAdd, &ctx, &hostDestroy));
    _ = try evalOne(box, "temp = nil\nreturn 0");
    try testing.expect(!ctx.destroyed);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_collect(box));
    try testing.expect(ctx.destroyed);
}

test "host fn: name collisions with builtins are rejected" {
    var ctx: AddCtx = .{};
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_register_fn(box, s("print"), &hostAdd, &ctx, null));
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_register_fn(box, s("string.format"), &hostAdd, &ctx, null));
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_register_fn(box, s("string"), &hostAdd, &ctx, null));
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_register_fn(box, s("a.b.c"), &hostAdd, &ctx, null));
}

fn hostFail(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) capi.mh_status {
    _ = userdata;
    _ = args;
    _ = nargs;
    _ = results;
    _ = max_results;
    nresults.* = 0;
    capi.mh_error_set(vm.?, s("host says no"));
    return .err_runtime;
}

test "host fn: failure surfaces as a catchable located guest error" {
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_register_fn(box, s("fail"), &hostFail, null, null));
    var results: [2]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_eval(box, s("local ok, e = pcall(fail)\nreturn ok, e"), s("p"), &results, 2, &n));
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(c_int, 0), capi.mh_value_truthy(results[0]));
    var es: mh_str = .{};
    try testing.expectEqual(capi.mh_status.ok, capi.mh_value_str(box, results[1], &es));
    try testing.expect(std.mem.indexOf(u8, es.ptr.?[0..es.len], "host says no") != null);

    // Uncaught, the same failure exits the C entry as a runtime error.
    try testing.expectEqual(capi.mh_status.err_runtime, capi.mh_eval(box, s("fail()"), s("p2"), &results, 0, &n));
    try testing.expect(std.mem.indexOf(u8, lastError(box), "host says no") != null);
}

const ReentryCtx = struct {
    vm_free_status: capi.mh_status = .ok,
};

fn hostReenter(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) capi.mh_status {
    const ctx: *ReentryCtx = @ptrCast(@alignCast(userdata.?));
    if (nargs < 1 or max_results < 1) return .err_api;
    // Freeing the VM mid-callback must be refused.
    ctx.vm_free_status = capi.mh_vm_free(vm);
    // Call the guest function we were handed, doubling its result.
    var inner: [1]mh_value = undefined;
    var n: usize = 0;
    const call_args = [_]mh_value{capi.mh_int(21)};
    if (capi.mh_call(vm, args.?[0], &call_args, 1, &inner, 1, &n) != .ok) return .err_runtime;
    var x: i64 = 0;
    if (capi.mh_value_int(inner[0], &x) != .ok) return .err_api;
    results.?[0] = capi.mh_int(x);
    nresults.* = 1;
    return .ok;
}

test "host fn: reentrant mh_call from inside a callback; vm_free refused" {
    var ctx: ReentryCtx = .{};
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(capi.mh_status.ok, capi.mh_register_fn(box, s("twice"), &hostReenter, &ctx, null));
    const v = try evalOne(box, "return twice(function(x) return x * 2 end)");
    try expectInt(v, 42);
    try testing.expectEqual(capi.mh_status.err_api, ctx.vm_free_status);
}

test "bad values from C are rejected, not trusted" {
    const box = try newVm();
    defer freeVm(box);
    // Garbage tag byte.
    const garbage: mh_value = .{ .tag = 200, .payload = 0xdeadbeef };
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_global_set(box, s("g"), garbage));
    // heap_ref with a null pointer.
    const nullref: mh_value = .{ .tag = 4, .payload = 0 };
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_global_set(box, s("g"), nullref));
    // Wrong-type accessors.
    var i: i64 = 0;
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_value_int(capi.mh_float(1.5), &i));
}

test "scripts are VM-checked" {
    const box_a = try newVm();
    defer freeVm(box_a);
    const box_b = try newVm();
    defer freeVm(box_b);
    var script: *capi.ScriptBox = undefined;
    try testing.expectEqual(capi.mh_status.ok, capi.mh_compile(box_a, s("return 1"), s("x"), &script));
    defer capi.mh_script_free(script);
    var results: [1]mh_value = undefined;
    var n: usize = 0;
    try testing.expectEqual(capi.mh_status.err_api, capi.mh_run(box_b, script, &results, 1, &n));
}

test "jit on: a hot guest loop runs correctly through the embedding API" {
    const box = try newVm(); // default config = JIT on
    defer freeVm(box);
    const v = try evalOne(box,
        \\local sum = 0
        \\for i = 1, 200000 do sum = sum + i end
        \\return sum
    );
    try expectInt(v, 20000100000);
}

test "mem stats reflect VM allocation" {
    const box = try newVm();
    defer freeVm(box);
    var stats: capi.mh_mem_stats = .{};
    try testing.expectEqual(capi.mh_status.ok, capi.mh_mem_stats_get(box, &stats));
    try testing.expect(stats.live_bytes > 0);
    try testing.expect(stats.live_allocations > 0);
}
