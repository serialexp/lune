//! Tests for `nativegen.zig` — float.
//!
//! Extracted verbatim from `nativegen.zig`; bodies are unchanged.
//! Shared harness lives in `nativegen_testutil.zig`.

const nativegen = @import("nativegen.zig");
const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("x64.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const Value = value.Value;
const RegWindow = @import("regwindow.zig").RegWindow;
const Trace = @import("trace_code.zig").TraceCode;
const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const I = trace.IrInstr;
const S = trace.SlotStore;

const is_x64_linux = nativegen.is_x64_linux;

const util = @import("nativegen_testutil.zig");
const expectBail = util.expectBail;
const expectMatch = util.expectMatch;

// --- Phase D / F1: float add/sub/mul native path -----------------------------

test "nativegen(F1): float-accumulate loop matches the strict-FP oracle (movq const + addsd + XMM carry + float flush)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // int-controlled loop, float body: while (i < limit) { acc += 0.1; i += 1 }
    // r0=i (int), r1=limit (int), r2=acc (float). The loop condition stays int
    // (float compares are F2), so the only float work is the carried accumulator.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc (float)
        .{ .op = .guard_float, .a = 6 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 0.1 (float)
        .{ .op = .add, .a = 6, .b = 8, .ty = .float }, // 9: acc + 0.1 → float
        .{ .op = .konst, .aux = 1 }, // 10: 1 (int)
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1 (int)
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.float(0.1), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // 0.1 is not exactly representable: native must accumulate it bit-identically to
    // the oracle's strict-FP addsd (the classic 0.1-drift). 10 iterations.
    try expectMatch(&t, &.{ Value.int(0), Value.int(10), Value.float(0.0) });
    // 0 iterations: acc stays exactly 0.0, flushed as a float (tag must be 3).
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.float(0.0) });
}

test "nativegen(F1): mixed int+float add promotes the int operand via cvtsi2sd" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (i < limit) { acc += i; i += 1 }  — acc is float, i is int → the float
    // add reads an int operand, which must be cvtsi2sd-promoted at the use site.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc (float)
        .{ .op = .guard_float, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0, .ty = .float }, // 8: acc + i (int promoted)
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .phi, .b = 10, .aux = 0 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // i=1..4 → acc = 1+2+3+4 = 10.0 (exact). cvtsi2sd round-to-nearest matches @floatFromInt.
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.float(0.0) });
    // A larger run whose partial sums are non-exact once divided would also match,
    // but addition of small ints stays exact; verify a longer carry too.
    try expectMatch(&t, &.{ Value.int(1), Value.int(20), Value.float(100.0) });
}

test "nativegen(F1): float sub and mul preserve operand order, bit-exact" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (i < limit) { acc = acc * 1.5; acc = acc - 0.25; i += 1 }
    // Exercises mulsd then subsd (order matters: acc-0.25, not 0.25-acc).
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc (float)
        .{ .op = .guard_float, .a = 6 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 1.5
        .{ .op = .mul, .a = 6, .b = 8, .ty = .float }, // 9: acc * 1.5
        .{ .op = .konst, .aux = 1 }, // 10: 0.25
        .{ .op = .sub, .a = 9, .b = 10, .ty = .float }, // 11: (acc*1.5) - 0.25
        .{ .op = .konst, .aux = 2 }, // 12: 1 (int)
        .{ .op = .add, .a = 0, .b = 12 }, // 13: i + 1
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .phi, .b = 13, .aux = 0 },
        .{ .op = .loop }, // 14
    };
    var consts = [_]Value{ Value.float(1.5), Value.float(0.25), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{ Value.int(0), Value.int(6), Value.float(1.0) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(3), Value.float(-2.0) });
}

test "nativegen(F1): a carried slot loaded float but stored int bails (lk != sk)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // Slot 2 is loaded via guard_float (.float) but its exit_store references an int
    // value — the load/store classes disagree, so analyze must bail (RV-3) and the
    // whole trace falls back to tier-1a rather than miscompiling the home class.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: loaded as float...
        .{ .op = .guard_float, .a = 6 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 1 (int)
        .{ .op = .add, .a = 0, .b = 8 }, // 9: i + 1 (int)
        .{ .op = .phi, .b = 9, .aux = 0 },
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .loop }, // 10
    };
    var consts = [_]Value{Value.int(1)};
    // slot 2 carried: load=float(ref6), store=int(ref9) → mismatch.
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&t);
}

test "nativegen(F1): a malformed int+int add stamped ty=.float bails (no float/int divergence)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // [review] Defensive: a hand-built/deserialized trace whose add has BOTH operands
    // int but ty=.float must NOT lower as a float op — the oracle (arith.zig) computes
    // int-wrap + TAG_INT, so a float lowering would diverge on side-exit. proveKinds
    // bails to tier-1a (it never trusts ins.ty alone). The recorder never emits this.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1 (int)
        .{ .op = .add, .a = 0, .b = 6, .ty = .float }, // 7: int+int but LIES ty=.float
        .{ .op = .phi, .b = 7, .aux = 0 },
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&t);
}

// --- Phase D / F2: float comparisons (ucomisd + NaN-aware combine) ------------

/// Run a single float comparison `x <op> y` through both tiers and assert the boolean
/// result matches bit-for-bit. The trace: an int counter drives exactly one iteration;
/// the body loads two float slots (x, y), computes `x <op> y` into a write-only bool
/// slot, then bumps the counter. expectMatch compares regs[], so the committed bool
/// (slot 3) is checked against the arith.zig oracle — including its NaN semantics.
fn expectFloatCmp(op: trace.IrOp, x: f64, y: f64) !void {
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (int counter)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 1 (int limit)
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 1 (int compare — loop control)
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: x (float)
        .{ .op = .guard_float, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: y (float)
        .{ .op = .guard_float, .a = 7 }, // 8
        .{ .op = op, .a = 5, .b = 7 }, // 9: x <op> y → bool (the float compare)
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .phi, .b = 9, .aux = 3 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.int(1), Value.int(1) };
    // slot 3 = the bool result (write-only); slot 0 = the counter (carried).
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{ Value.int(0), Value.float(x), Value.float(y), Value.nil() });
}

test "nativegen(F2): float lt/le/eq/ne match the oracle on finite, equal, and ±inf operands" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const inf = std.math.inf(f64);
    const cases = [_]struct { x: f64, y: f64 }{
        .{ .x = 1.5, .y = 2.5 }, // x < y
        .{ .x = 2.5, .y = 1.5 }, // x > y
        .{ .x = 3.0, .y = 3.0 }, // x == y
        .{ .x = -0.0, .y = 0.0 }, // signed zeros compare equal
        .{ .x = inf, .y = 1.0 }, // +inf > finite
        .{ .x = -inf, .y = inf }, // -inf < +inf
        .{ .x = inf, .y = inf }, // +inf == +inf
    };
    for (cases) |c| {
        try expectFloatCmp(.lt, c.x, c.y);
        try expectFloatCmp(.le, c.x, c.y);
        try expectFloatCmp(.eq, c.x, c.y);
        try expectFloatCmp(.ne, c.x, c.y);
    }
}

test "nativegen(F2): NaN in either operand → lt/le/eq false, ne true (ucomisd unordered)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const others = [_]f64{ 0.0, 1.5, -1.5, inf, -inf, nan };
    for (others) |o| {
        // NaN on the left.
        try expectFloatCmp(.lt, nan, o);
        try expectFloatCmp(.le, nan, o);
        try expectFloatCmp(.eq, nan, o);
        try expectFloatCmp(.ne, nan, o);
        // NaN on the right.
        try expectFloatCmp(.lt, o, nan);
        try expectFloatCmp(.le, o, nan);
        try expectFloatCmp(.eq, o, nan);
        try expectFloatCmp(.ne, o, nan);
    }
}

test "nativegen(F2): a float-controlled while loop compiles (ucomisd drives guard_true)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (x < limit) { x = x + 1.5 }  — the loop condition is a FLOAT compare whose
    // bool feeds guard_true; x is a carried float. Exercises the compare in the hot
    // position (not just a stored result).
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: x (float)
        .{ .op = .guard_float, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 1 }, // 2: limit (float)
        .{ .op = .guard_float, .a = 2 }, // 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 4: x < limit (FLOAT compare)
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1.5
        .{ .op = .add, .a = 0, .b = 6, .ty = .float }, // 7: x + 1.5
        .{ .op = .phi, .b = 7, .aux = 0 },
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{Value.float(1.5)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // x: 0.0, 1.5, 3.0, 4.5 (<5), then 6.0 (>=5) → 4 commits.
    try expectMatch(&t, &.{ Value.float(0.0), Value.float(5.0) });
    // Already past the limit → 0 commits, x flushed unchanged as a float.
    try expectMatch(&t, &.{ Value.float(9.0), Value.float(5.0) });
}

test "nativegen(F2): a mixed int/float compare bails (oracle compares exactly, not via cvtsi2sd)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // x is float, y is int → value.compareNumeric uses an EXACT int-vs-float compare,
    // which a cvtsi2sd-then-ucomisd lowering cannot reproduce for large ints. proveKinds
    // must bail the whole trace to tier-1a rather than risk a divergence.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (counter)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 1
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 1
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: x (float)
        .{ .op = .guard_float, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: y (int)
        .{ .op = .guard_int, .a = 7 }, // 8
        .{ .op = .lt, .a = 5, .b = 7 }, // 9: float < int — MIXED → bail
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11
        .{ .op = .phi, .b = 9, .aux = 3 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.int(1), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&t);
}
