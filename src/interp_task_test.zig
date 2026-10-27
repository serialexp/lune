//! Tests for doc 73 §7's `async function` and `await`: the task library
//! (`stdlib/task.lua`) over coroutines. Every program runs on the full GC ×
//! trace-mode matrix. Nothing a program can call makes a task wait yet
//! (the host's operations are P4b), so `installTaskHost` stands in for a
//! host: `pending()` makes an operation in flight, `settle(op, ok, ...)`
//! finishes it.

const std = @import("std");
const util = @import("interp_testutil.zig");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Vm = interp.Vm;
const Value = value.Value;

/// The task library's `pending` and `settle` as the globals of the same
/// names, as natives that call them.
fn installTaskHost(vm: *Vm) !void {
    const host = struct {
        fn libCall(ctx: *anyopaque, index: i64, args: []const Value) anyerror!Value {
            const v: *Vm = @ptrCast(@alignCast(ctx));
            const lib = try v.taskLib();
            var out: [1]Value = undefined;
            const n = try v.callValue(lib.get(Value.int(index)), args, &out);
            return if (n >= 1) out[0] else Value.nil();
        }
        fn pending(ctx: *anyopaque, args: []const Value) anyerror!Value {
            return libCall(ctx, 4, args);
        }
        fn settle(ctx: *anyopaque, args: []const Value) anyerror!Value {
            return libCall(ctx, 5, args);
        }
    };
    inline for (.{ .{ "pending", &host.pending }, .{ "settle", &host.settle } }) |nf| {
        const native = try vm.heap.newNative(nf[1], nf[0]);
        try vm.globals.set(vm.heap.gpa, try vm.heap.internValue(nf[0]), Value.heap(&native.header));
    }
}

fn expectTasks(source: [:0]const u8, expected: []const u8) !void {
    return util.expectProgramTuned(source, expected, .{ .setup = &installTaskHost });
}

fn expectTasksFault(source: [:0]const u8, expected: []const u8, message: []const u8) !void {
    return util.expectProgramFault(source, expected, message, .{ .setup = &installTaskHost });
}

test "async: a call runs the body at once and await takes all its results" {
    try expectTasks(
        \\local async function add(a, b) return a + b, a * b end
        \\print(await add(2, 3))
        \\local t = add(4, 5)
        \\print(type(t), await t, await t)
        \\print(await 7, await nil)
        \\async function count(...) return select("#", ...) end
        \\print(await count(1, nil, 3))
        \\local o = { v = 9 }
        \\async function o:get(k) return self.v + k end
        \\print(await o:get(1), await (async function(x) return -x end)(3))
        \\local async function rec(n) if n == 0 then return 0 end return 1 + await rec(n - 1) end
        \\print(await rec(40), await 1 + 1)
    , "5\t6\ntable\t9\t9\t20\n7\tnil\n3\n10\t-3\n40\t2\n");
}

test "async: an error before the first wait is the call's; a yield is one from outside a coroutine" {
    try expectTasks(
        \\local async function f() error("boom") end
        \\print(pcall(f))
        \\local async function y() coroutine.yield(1) end
        \\print(pcall(y))
        \\print(pcall(function() return type(await coroutine.running()) end))
    , "false\tmain:1: boom\nfalse\tattempt to yield from outside a coroutine\ntrue\tthread\n");
}

test "async: a settled operation wakes its waiters in the order they waited" {
    try expectTasks(
        \\local p = pending()
        \\local log = {}
        \\local async function w(name)
        \\  local v = await p
        \\  log[#log + 1] = name .. v
        \\  return v * 10
        \\end
        \\local a, b = w("a"), w("b")
        \\log[#log + 1] = "spawned"
        \\settle(p, true, 1)
        \\log[#log + 1] = "settled"
        \\print(await b, await a)
        \\print(table.concat(log, " "))
    , "10\t10\nspawned settled a1 b1\n");
}

test "async: the tasks still ready when the main chunk returns run after it" {
    try expectTasks(
        \\local p = pending()
        \\local async function w(i) print("woke", i, await p) end
        \\w(1)
        \\w(2)
        \\settle(p, true, "x")
        \\local async function never() await pending() print("never") end
        \\never()
        \\print("main end")
    , "main end\nwoke\t1\tx\nwoke\t2\tx\n");
}

test "async: a failure after the first wait is raised at every await of the task" {
    try expectTasks(
        \\local p = pending()
        \\local async function f() await p error("late") end
        \\local t = f()
        \\settle(p, true)
        \\print(pcall(function() return await t end))
        \\print(pcall(function() return await t end))
        \\local q = pending()
        \\local u = (async function() return await q end)()
        \\settle(q, false, { code = 7 })
        \\local ok, e = pcall(function() return await u end)
        \\print(ok, e.code)
    , "false\tmain:2: late\nfalse\tmain:2: late\nfalse\t7\n");
}

test "async: a failure no one awaited is fatal once nothing is ready" {
    try expectTasksFault(
        \\local p = pending()
        \\local async function f() await p error("lost") end
        \\f()
        \\settle(p, true)
        \\print("end")
    , "end\n", "unobserved task error: main:2: lost");
}

test "async: awaiting what can never finish is a deadlock, and a task can't await itself" {
    try expectTasks(
        \\local p = pending()
        \\print(pcall(function() return await p end))
        \\local q = pending()
        \\local t
        \\local async function f() await q return await t end
        \\t = f()
        \\settle(q, true)
        \\print(pcall(function() return await t end))
    , "false\tmain:2: deadlock: the awaited task can never finish\n" ++
        "false\tmain:5: a task cannot await itself\n");
}

test "async: await in a coroutine inside a task runs the ready tasks in place" {
    try expectTasks(
        \\local p, q = pending(), pending()
        \\local async function g() await q settle(p, true, "via g") end
        \\g()
        \\settle(q, true)
        \\local async function f()
        \\  local co = coroutine.wrap(function() return await p end)
        \\  return co()
        \\end
        \\print(await f())
    , "via g\n");
}

test "async: many tasks waiting in a hot loop" {
    try expectTasks(
        \\local p = pending()
        \\local n = 0
        \\local async function w(i) local v = await p n = n + v * i end
        \\for i = 1, 300 do w(i) end
        \\local async function last() await p print(n) end
        \\last()
        \\settle(p, true, 2)
        \\local done = 0
        \\for i = 1, 300 do local t = (async function() return i end)() done = done + await t end
        \\print(done)
    , "45150\n90300\n");
}

test "async: the main chunk's results survive the drain" {
    const gpa = std.testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const compiler = @import("compiler.zig");
    const src: [:0]const u8 =
        \\local p = pending()
        \\local async function w() await p end
        \\w()
        \\settle(p, true)
        \\return "kept", 2
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    try installTaskHost(&vm);
    var chunk = try compiler.compile(gpa, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();
    const v = try vm.run(chunk.proto);
    try std.testing.expectEqualStrings("kept", interp.strBytes(v).?);
}
