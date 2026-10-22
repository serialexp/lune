//! Tests for doc 70's tier-0 fast functions (`interp.fastResult`,
//! `Vm.opCallFast`).
//!
//! The differential test is the contract: wherever a fast body takes an
//! argument shape, the native itself must return a bit-identical value for
//! the same arguments. The program tests pin the call wiring around it
//! (dynamic argument and result counts, nil padding, the fallback).

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const regwindow = @import("regwindow.zig");
const testutil = @import("interp_testutil.zig");
const Value = value.Value;
const Vm = interp.Vm;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

fn sameBits(a: Value, b: Value) bool {
    return a.tag == b.tag and a.payload.bits == b.payload.bits;
}

/// One fast body against its native over every argument tuple of `arity`
/// drawn from `pool`. Returns how many tuples the fast body took.
fn diffArity(vm: *Vm, bn: interp.BaseNative, fast: function.FastBuiltin, pool: []const Value, arity: usize) !usize {
    var tags: [3]u8 = undefined;
    var payloads: [3]u64 = undefined;
    var args: [3]Value = undefined;
    const regs: RegWindow = .{ .tags = &tags, .payloads = &payloads, .n = 3 };
    var taken: usize = 0;
    var idx = [3]usize{ 0, 0, 0 };
    var total: usize = 1;
    for (0..arity) |_| total *= pool.len;
    for (0..total) |_| {
        for (0..arity) |k| {
            args[k] = pool[idx[k]];
            regs.set(k, args[k]);
        }
        if (interp.fastResult(vm, fast, regs, 0, arity)) |got| {
            taken += 1;
            const want = bn.func(@ptrCast(vm), args[0..arity]) catch |e| {
                std.debug.print("{s}: fast took a shape the native rejects ({s}), args:", .{ bn.name, @errorName(e) });
                for (args[0..arity]) |v| std.debug.print(" {s}", .{v.typeName()});
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            };
            if (!sameBits(got, want)) {
                std.debug.print("{s}: fast and native disagree, args:", .{bn.name});
                for (args[0..arity]) |v| std.debug.print(" {s}:{x}", .{ v.typeName(), v.payload.bits });
                std.debug.print("\n", .{});
                return error.TestUnexpectedResult;
            }
        }
        var k: usize = 0;
        while (k < arity) : (k += 1) {
            idx[k] += 1;
            if (idx[k] < pool.len) break;
            idx[k] = 0;
        }
    }
    return taken;
}

test "fast functions: every fast body agrees with its native, bit for bit" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const arr_t = try vm.heap.newTable();
    for (1..4) |i| try arr_t.set(gpa, Value.int(@intCast(i)), Value.int(@intCast(i * 10)));
    const hash_t = try vm.heap.newTable();
    try hash_t.set(gpa, try vm.heap.internValue("k"), Value.int(1));
    try hash_t.set(gpa, Value.float(2.5), Value.boolean(true));
    const empty_t = try vm.heap.newTable();
    const print_fn = vm.globals.get(try vm.heap.internValue("print"));
    const pool = [_]Value{
        Value.nil(),                         Value.boolean(true),               Value.boolean(false),
        Value.int(0),                        Value.int(-1),                     Value.int(2),
        Value.int(std.math.minInt(i64)),     Value.int(std.math.maxInt(i64)),   Value.float(2.5),
        Value.float(-2.5),                   Value.float(0.0),                  Value.float(-0.0),
        Value.float(std.math.inf(f64)),      Value.float(-std.math.inf(f64)),   Value.float(std.math.nan(f64)),
        Value.float(9223372036854775808.0),  Value.float(-9223372036854775808.0), Value.float(2.0),
        try vm.heap.internValue("#"),        try vm.heap.internValue(""),       try vm.heap.internValue("héllo"),
        try vm.heap.internValue("10"),       Value.heap(&arr_t.header),         Value.heap(&hash_t.header),
        Value.heap(&empty_t.header),         print_fn,
    };

    var checked: usize = 0;
    inline for (interp.base_natives) |bn| {
        if (bn.fast) |fast| {
            checked += 1;
            var taken: usize = 0;
            const max_arity: usize = switch (fast) {
                .min, .max, .select => 3,
                else => 2,
            };
            for (0..max_arity + 1) |arity| taken += try diffArity(&vm, bn, fast, &pool, arity);
            // Non-vacuous: every fast body takes some shape of the pool.
            if (taken == 0) {
                std.debug.print("{s}: the fast body took no shape\n", .{bn.name});
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expectEqual(@as(usize, @typeInfo(function.FastBuiltin).@"enum".field_names.len), checked);
}

test "fast functions: rawget leaves a grid to the native, which deflates it" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try array.ArrayPart.initGrid(gpa, 2, 3, .i32);
    t.array.gridSet(0, 0, Value.int(10));
    var tags: [2]u8 = undefined;
    var payloads: [2]u64 = undefined;
    const regs: RegWindow = .{ .tags = &tags, .payloads = &payloads, .n = 2 };
    regs.set(0, Value.heap(&t.header));
    regs.set(1, Value.int(1));
    try testing.expect(interp.fastResult(&vm, .rawget, regs, 0, 2) == null);
    try testing.expect(t.array.isGrid());
}

test "fast functions: argument and result counts around the fast path" {
    try testutil.expectProgram(
        \\local function n(...) return select('#', ...) end
        \\print(n(), n(nil), n(1, nil, 3))
        \\print(select('#', math.abs(-1)), select('#', type(nil)))
        \\local a, b, c = math.floor(2.5)
        \\print(a, b, c)
        \\math.sqrt(4)
        \\print(math.max(3, 7.5, 7), math.min(2, 2.0), math.max(2.0, 2))
        \\print(type(print), type(nil), rawlen({1, 2}), rawlen("héllo"), string.len("héllo"))
        \\print(rawequal(), rawequal(1, 1.0), rawget({5}, 1), rawget({}, "x"))
        \\print(pcall(function() return math.floor("x") end))
        \\print(pcall(function() return math.floor(1 / 0) end))
        \\print(pcall(function() return rawlen(5) end))
        \\print(select(2, "a", "b"), select('#'))
        \\
    ,
        "0\t1\t3\n" ++
            "1\t1\n" ++
            "2\tnil\tnil\n" ++
            "7.5\t2\t2\n" ++
            "function\tnil\t2\t6\t5\n" ++
            "true\ttrue\t5\tnil\n" ++
            "false\tanonymous:10: bad argument to 'floor'\n" ++
            "false\tanonymous:11: bad argument to 'floor'\n" ++
            "false\tanonymous:12: bad argument to 'rawlen'\n" ++
            "b\t0\n",
    );
}
