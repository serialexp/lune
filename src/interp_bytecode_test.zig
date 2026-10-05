//! Tests for `interp.zig` — bytecode.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.
//! Shared harness lives in `interp_testutil.zig`.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const Error = interp.Error;
const Vm = interp.Vm;

// ---------------------------------------------------------------------------
// Tests — hand-assembled prototypes (no compiler yet; that is Increment C).
// ---------------------------------------------------------------------------

/// Build a one-off prototype, run it, and return the first result.
fn runCode(code: []const Instr, constants: []const Value, num_registers: u16) Error!Value {
    const proto = Proto{
        .code = code,
        .constants = constants,
        .num_registers = num_registers,
        .name = "test",
    };
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    return vm.run(&proto);
}

test "arithmetic: (2 + 3) * 4 == 20" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 2),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.add, 0, 0, 1), // r0 = 2 + 3
        Instr.opAx(.load_int, 1, 4),
        Instr.opABC(.mul, 0, 0, 1), // r0 = 5 * 4
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &.{}, 2);
    try testing.expect(r.isInt());
    try testing.expectEqual(@as(i64, 20), r.asInt());
}

test "describeFault: arithmetic on a nil value names the op, type, line, and span" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const src =
        \\local s = 0
        \\s = s + d
    ;
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    try testing.expectError(Error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fault = try vm.describeFault(src, Error.TypeError, arena.allocator());
    try testing.expectEqual(@as(u32, 2), fault.line);
    try testing.expect(std.mem.indexOf(u8, fault.message, "arithmetic") != null);
    try testing.expect(std.mem.indexOf(u8, fault.message, "nil") != null);
    // The faulting span underlines the whole `s + d` operation on line 2.
    try testing.expectEqualStrings("s + d", src[fault.start..fault.end]);
}

test "describeFault: calling a nil value names the call and the type" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const src =
        \\local f
        \\f()
    ;
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    try testing.expectError(Error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fault = try vm.describeFault(src, Error.TypeError, arena.allocator());
    try testing.expectEqual(@as(u32, 2), fault.line);
    try testing.expect(std.mem.indexOf(u8, fault.message, "call") != null);
    try testing.expect(std.mem.indexOf(u8, fault.message, "nil") != null);
}

test "describeFault: a nested fault yields a deepest-first backtrace (leaf + call site)" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    // `f` faults on line 2 (nil arithmetic); it is called from `main` on line 5.
    const src =
        \\function f(x)
        \\  return x + nope
        \\end
        \\local s = 0
        \\s = f(1)
    ;
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    try testing.expectError(Error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fault = try vm.describeFault(src, Error.TypeError, arena.allocator());

    // Two live frames at the fault: f (leaf) called from main.
    try testing.expectEqual(@as(usize, 2), fault.frames.len);
    // Leaf = f, faulting on line 2; top-level fields mirror the leaf.
    try testing.expectEqualStrings("f", fault.frames[0].name);
    try testing.expectEqual(@as(u32, 2), fault.frames[0].line);
    try testing.expectEqual(@as(u32, 2), fault.line);
    try testing.expect(std.mem.indexOf(u8, fault.message, "arithmetic") != null);
    // Parent = main, located at the call site `f(1)` on line 5 (pc -| 1).
    try testing.expectEqualStrings("main", fault.frames[1].name);
    try testing.expectEqual(@as(u32, 5), fault.frames[1].line);
}

test "load_const pulls float literals from the pool" {
    const consts = [_]Value{ Value.float(1.5), Value.float(2.5) };
    const code = [_]Instr{
        Instr.opAB(.load_const, 0, 0),
        Instr.opAB(.load_const, 1, 1),
        Instr.opABC(.add, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &consts, 2);
    try testing.expectEqual(@as(f64, 4.0), r.asFloat());
}

test "comparison writes a boolean; not inverts truthiness" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 3),
        Instr.opAx(.load_int, 1, 5),
        Instr.opABC(.lt, 0, 0, 1), // r0 = 3 < 5 = true
        Instr.opAB(.not, 0, 0), // r0 = not true = false
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &.{}, 2);
    try testing.expect(r.isBool());
    try testing.expectEqual(false, r.asBool());
}

test "gt/ge are lt/le with swapped operands" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.gt, 0, 0, 1), // 5 > 3 = true
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectEqual(true, (try runCode(&code, &.{}, 2)).asBool());
}

test "forward jump skips an instruction" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 1),
        Instr.opJ(.jmp, 1), // skip the next instruction
        Instr.opAx(.load_int, 0, 999), // skipped
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectEqual(@as(i64, 1), (try runCode(&code, &.{}, 1)).asInt());
}

test "conditional jump + back-edge: sum 1..5 == 15" {
    // r0 = i (counter, counts down 5..1), r1 = acc, r2 = scratch
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5), //  0: i = 5
        Instr.opAx(.load_int, 1, 0), //  1: acc = 0
        // loop:
        Instr.opAx(.load_int, 2, 0), //  2: scratch = 0
        Instr.opABC(.le, 2, 0, 2), //  3: scratch = (i <= 0)
        Instr.opAx(.jmp_if_true, 2, 4), //  4: if i<=0 goto end (pc 9)
        Instr.opABC(.add, 1, 1, 0), //  5: acc += i
        Instr.opAx(.load_int, 2, 1), //  6: scratch = 1
        Instr.opABC(.sub, 0, 0, 2), //  7: i -= 1
        Instr.opJ(.jmp, -7), //  8: goto loop (back to pc 2)
        // end:
        Instr.opAB(.ret, 1, 1), //  9: return acc
    };
    const r = try runCode(&code, &.{}, 3);
    try testing.expectEqual(@as(i64, 15), r.asInt());
}

test "numeric for: sum i=1..5 == 15 via for_prep/for_loop" {
    // r0=acc, r1=idx, r2=limit, r3=step, r4=loop var
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 0), // 0: acc = 0
        Instr.opAx(.load_int, 1, 1), // 1: idx = 1
        Instr.opAx(.load_int, 2, 5), // 2: limit = 5
        Instr.opAx(.load_int, 3, 1), // 3: step = 1
        Instr.opAx(.for_prep, 1, 1), // 4: prep, jump to for_loop (pc 6)
        Instr.opABC(.add, 0, 0, 4), // 5: body: acc += i
        Instr.opAx(.for_loop, 1, -2), // 6: step+test, back-edge to body (pc 5)
        Instr.opAB(.ret, 0, 1), // 7: return acc
    };
    try testing.expectEqual(@as(i64, 15), (try runCode(&code, &.{}, 5)).asInt());
}

test "type error propagates from a bad operand" {
    const code = [_]Instr{
        Instr.opA(.load_nil, 0),
        Instr.opAx(.load_int, 1, 1),
        Instr.opABC(.add, 0, 0, 1), // nil + 1
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "ret with no values yields nil; halt yields nil" {
    const r0 = try runCode(&[_]Instr{Instr.opAB(.ret, 0, 0)}, &.{}, 1);
    try testing.expect(r0.isNil());
    const r1 = try runCode(&[_]Instr{Instr.op0(.halt)}, &.{}, 1);
    try testing.expect(r1.isNil());
}

test "new_table + set_index + get_index round-trips a value" {
    // local t = {}; t[1] = 42; return t[1]
    const code = [_]Instr{
        Instr.opA(.new_table, 0),
        Instr.opAx(.load_int, 1, 1), // key
        Instr.opAx(.load_int, 2, 42), // value
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opABC(.get_index, 1, 0, 1),
        Instr.opAB(.ret, 1, 1),
    };
    // Result is a scalar int, so the deinit-after-return helper is safe here.
    try testing.expectEqual(@as(i64, 42), (try runCode(&code, &.{}, 3)).asInt());
}

test "#t counts the sequence border" {
    // t = {10, 20, 30}; return #t
    const code = [_]Instr{
        Instr.opA(.new_table, 0),
        Instr.opAx(.load_int, 1, 1),
        Instr.opAx(.load_int, 2, 10),
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 2),
        Instr.opAx(.load_int, 2, 20),
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 3),
        Instr.opAx(.load_int, 2, 30),
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAB(.len, 1, 0),
        Instr.opAB(.ret, 1, 1),
    };
    try testing.expectEqual(@as(i64, 3), (try runCode(&code, &.{}, 3)).asInt());
}

test "indexing a non-table is a type error" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opAx(.load_int, 1, 1),
        Instr.opABC(.get_index, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "call a closure: double(21) == 42 via the call convention" {
    // child: double(x) -> x * 2
    const child_code = [_]Instr{
        Instr.opAx(.load_int, 1, 2), // R1 = 2
        Instr.opABC(.mul, 1, 0, 1), // R1 = x * 2
        Instr.opAB(.ret, 1, 1), // return R1
    };
    var child = Proto{ .code = &child_code, .num_registers = 2, .num_params = 1, .name = "double" };
    const protos = [_]*const Proto{&child};
    // main: f = closure(double); return f(21)
    const main_code = [_]Instr{
        Instr.opAB(.closure, 0, 0), // R0 = closure(double)
        Instr.opAx(.load_int, 1, 21), // R1 = 21 (arg)
        Instr.opABC(.call, 0, 1, 1), // call R0 with 1 arg, want 1 result → R0
        Instr.opAB(.ret, 0, 1),
    };
    const main = Proto{ .code = &main_code, .num_registers = 2, .protos = &protos, .name = "main" };
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 42), (try vm.run(&main)).asInt());
}

test "calling a non-function is a type error" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opABC(.call, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

// ---------------------------------------------------------------------------
// Varargs V1 — the frame cursor + the four opcodes, exercised on hand-built
// protos (the compiler lowering lands in V2). A vararg callee with one fixed
// param, called with extra args, leaves the surplus in the caller's window;
// the cursor (`varargs_base`/`varargs_count`) points at it with no copy.
// ---------------------------------------------------------------------------

/// Build a `main` that creates a closure over `child`, loads `args` into the
/// call window, and calls it wanting `want` results, returning the first.
fn runVararg(child: *Proto, args: []const i64, want: u16) Error!Value {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // main: R0 = closure(child); R1.. = args; call R0(args) want `want`; ret R0
    var code: std.ArrayList(Instr) = .empty;
    defer code.deinit(testing.allocator);
    try code.append(testing.allocator, Instr.opAB(.closure, 0, 0));
    for (args, 0..) |v, i| try code.append(testing.allocator, Instr.opAx(.load_int, @intCast(1 + i), @intCast(v)));
    try code.append(testing.allocator, Instr.opABC(.call, 0, @intCast(args.len), want));
    // Sum up to `want` results so a spread's values are observable (want<=3 here).
    var r: u16 = 1;
    while (r < want) : (r += 1) try code.append(testing.allocator, Instr.opABC(.add, 0, 0, r));
    try code.append(testing.allocator, Instr.opAB(.ret, 0, 1));
    const protos = [_]*const Proto{child};
    const main = Proto{ .code = code.items, .num_registers = @intCast(1 + args.len + 2), .protos = &protos, .name = "main" };
    return vm.run(&main);
}

test "vararg_len counts the surplus args (and is 0 with none)" {
    const child_code = [_]Instr{ Instr.opA(.vararg_len, 0), Instr.opAB(.ret, 0, 1) };
    var child = Proto{ .code = &child_code, .num_registers = 1, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expectEqual(@as(i64, 3), (try runVararg(&child, &.{ 10, 20, 30, 40 }, 1)).asInt());
    try testing.expectEqual(@as(i64, 0), (try runVararg(&child, &.{10}, 1)).asInt());
}

test "vararg_first yields the first surplus arg, or nil when there are none" {
    const child_code = [_]Instr{ Instr.opA(.vararg_first, 0), Instr.opAB(.ret, 0, 1) };
    var child = Proto{ .code = &child_code, .num_registers = 1, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expectEqual(@as(i64, 20), (try runVararg(&child, &.{ 10, 20, 30 }, 1)).asInt());
    try testing.expect((try runVararg(&child, &.{10}, 1)).isNil());
}

test "vararg_get is 1-based and bounds-checked (nil out of range)" {
    // child: idx in R1; R0 = vararg[R1]; return R0.
    const in_range = [_]Instr{ Instr.opAx(.load_int, 1, 2), Instr.opAB(.vararg_get, 0, 1), Instr.opAB(.ret, 0, 1) };
    var c1 = Proto{ .code = &in_range, .num_registers = 2, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expectEqual(@as(i64, 30), (try runVararg(&c1, &.{ 10, 20, 30, 40 }, 1)).asInt()); // varargs 20,30,40 → [2]=30
    const out_of_range = [_]Instr{ Instr.opAx(.load_int, 1, 5), Instr.opAB(.vararg_get, 0, 1), Instr.opAB(.ret, 0, 1) };
    var c2 = Proto{ .code = &out_of_range, .num_registers = 2, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expect((try runVararg(&c2, &.{ 10, 20, 30, 40 }, 1)).isNil());
    const zero_index = [_]Instr{ Instr.opAx(.load_int, 1, 0), Instr.opAB(.vararg_get, 0, 1), Instr.opAB(.ret, 0, 1) };
    var c3 = Proto{ .code = &zero_index, .num_registers = 2, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expect((try runVararg(&c3, &.{ 10, 20, 30, 40 }, 1)).isNil());
}

test "vararg_spread feeds all surplus args to the caller via all_results" {
    // child: spread all varargs from R0, return them all (producer half).
    const child_code = [_]Instr{ Instr.opA(.vararg_spread, 0), Instr.opAB(.ret, 0, bytecode.all_results) };
    var child = Proto{ .code = &child_code, .num_registers = 1, .num_params = 1, .is_vararg = true, .name = "f" };
    // main wants 3 results and sums them: 20 + 30 + 40 = 90.
    try testing.expectEqual(@as(i64, 90), (try runVararg(&child, &.{ 10, 20, 30, 40 }, 3)).asInt());
}

test "print is installed as a native global; output goes through the sink" {
    // Exercises the host-effect seam end to end, capturing output in a buffer
    // (never the real stdout — the test runner owns fd 1).
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    const consts = [_]Value{
        try vm.heap.internValue("print"),
        try vm.heap.internValue("ok"),
    };
    const code = [_]Instr{
        Instr.opAB(.get_global, 0, 0), // R0 = print
        Instr.opAB(.load_const, 1, 1), // R1 = "ok"
        Instr.opABC(.call, 0, 1, 1), // print("ok") → R0  (R0=fn, 1 arg in R1)
        Instr.opAB(.ret, 0, 1),
    };
    const proto = Proto{ .code = &code, .constants = &consts, .num_registers = 2, .name = "t" };
    try testing.expect((try vm.run(&proto)).isNil());
    try testing.expectEqualStrings("ok\n", sink.buffered());
}

test "set_global and get_global on a hand-built proto (no slot hints)" {
    // Hand-built protos leave `global_slot_hints` empty (doc 62 §4.1): both
    // global opcodes then take the plain table lookup.
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const consts = [_]Value{try vm.heap.internValue("g")};
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 7),
        Instr.opAB(.set_global, 0, 0), // g = 7
        Instr.opAx(.load_int, 0, 0),
        Instr.opAB(.get_global, 1, 0), // R1 = g
        Instr.opAB(.ret, 1, 1),
    };
    const proto = Proto{ .code = &code, .constants = &consts, .num_registers = 2, .name = "t" };
    try testing.expectEqual(@as(usize, 0), proto.global_slot_hints.len);
    try testing.expectEqual(@as(i64, 7), (try vm.run(&proto)).asInt());
    try testing.expectEqual(@as(i64, 7), vm.globals.get(try vm.heap.internValue("g")).asInt());
}

test "concat joins strings and coerces numbers; result is interned" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // "x=" .. 42  ->  "x=42"
    const consts = [_]Value{try vm.heap.internValue("x=")};
    const code = [_]Instr{
        Instr.opAB(.load_const, 0, 0),
        Instr.opAx(.load_int, 1, 42),
        Instr.opABC(.concat, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const proto = Proto{ .code = &code, .constants = &consts, .num_registers = 2, .name = "t" };
    const r = try vm.run(&proto); // inspect before deinit (heap result)
    try testing.expect(r.isHeap());
    try testing.expectEqualStrings("x=42", string.String.fromHeader(r.asHeap()).bytes());
}
