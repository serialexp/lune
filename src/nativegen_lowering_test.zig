//! Tests for `nativegen.zig` — lowering.
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
const Trace = trace.Trace;
const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const I = trace.IrInstr;
const S = trace.SlotStore;

const Kind = nativegen.Kind;
const McodeArena = nativegen.McodeArena;
const SlotClass = nativegen.SlotClass;
const analyze = nativegen.analyze;
const compileInto = nativegen.compileInto;
const isCompositeBridgeCandidate = nativegen.isCompositeBridgeCandidate;
const is_x64_linux = nativegen.is_x64_linux;
const mapExecutable = nativegen.mapExecutable;
const proveKinds = nativegen.proveKinds;
const regBit = nativegen.regBit;

const util = @import("nativegen_testutil.zig");
const expectBail = util.expectBail;
const expectMatch = util.expectMatch;
const expectMatchFrameless = util.expectMatchFrameless;

// --- Phase D / F3: div (always float; divsd, cvtsi2sd int operands) ----------

/// Run a single float division `x / y` through both tiers and assert the result
/// matches bit-for-bit. The trace: an int counter drives exactly one iteration; the
/// body loads two float slots (x, y), computes `x / y` into a write-only float slot
/// (slot 3), then bumps the counter. expectMatch compares regs[] via exact payload
/// bits, so +inf / nan results are checked bit-exactly against arith.zig's strict-FP
/// divsd (which is the same scalar SSE2 op native emits).
fn expectFloatDiv(x: f64, y: f64) !void {
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (int counter)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 1 (int limit)
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 1 (int loop control)
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: x (float)
        .{ .op = .guard_float, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: y (float)
        .{ .op = .guard_float, .a = 7 }, // 8
        .{ .op = .div, .a = 5, .b = 7, .ty = .float }, // 9: x / y → float (divsd)
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .phi, .b = 9, .aux = 3 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.int(1), Value.int(1) };
    // slot 3 is write-only float (the quotient); slot 0 is the int counter.
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // regs: i=0, x, y, slot3=placeholder (overwritten by the quotient each iteration).
    try expectMatch(&t, &.{ Value.int(0), Value.float(x), Value.float(y), Value.float(0.0) });
}

test "nativegen(F3): float division is bit-exact vs the strict-FP oracle, incl. inf/nan" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    try expectFloatDiv(1.0, 3.0); // 0.333… — non-terminating binary, the bit-exactness probe
    try expectFloatDiv(10.0, 4.0); // 2.5 — exact
    try expectFloatDiv(-7.0, 2.0); // -3.5 — sign + order preserved (x/y, not y/x)
    try expectFloatDiv(1.0, 0.0); // +inf
    try expectFloatDiv(-1.0, 0.0); // -inf
    try expectFloatDiv(0.0, 0.0); // nan — exact payload bits must match divsd's QNaN
}

test "nativegen: a write-only table temporary is boxed as a heap value" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tb = try table.Table.create(gpa);
    defer tb.destroy(gpa);

    // slot 2 is not read at trace entry; the loop body assigns it from the
    // guarded table in slot 1. This is the compiler-temporary shape produced when
    // a recording crosses a while header. Native must flush TAG_HEAP, not reject
    // the trace or mis-box the raw pointer as an integer.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .lt, .a = 0, .b = 2 },
        .{ .op = .guard_true, .a = 3 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_table, .a = 5 },
        .{ .op = .konst, .aux = 1 },
        .{ .op = .add, .a = 0, .b = 7 },
        .{ .op = .phi, .b = 5, .aux = 2 },
        .{ .op = .phi, .b = 8, .aux = 0 },
        .{ .op = .loop },
    };
    var consts = [_]Value{ Value.int(1), Value.int(1) };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&tr, &.{ Value.int(0), Value.heap(&tb.header), Value.nil() });
}

test "nativegen(F3): a float-accumulate loop dividing by a constant matches (carried divsd)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (i < limit) { acc = acc / 3.0; i += 1 }  — acc carried in an XMM home,
    // divided by a non-exact-reciprocal constant each iteration. The classic drift
    // (1/3, 1/9, 1/27, …) must accumulate bit-identically to the oracle's divsd.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc (float)
        .{ .op = .guard_float, .a = 6 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 3.0
        .{ .op = .div, .a = 6, .b = 8, .ty = .float }, // 9: acc / 3.0
        .{ .op = .konst, .aux = 1 }, // 10: 1 (int)
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.float(3.0), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{ Value.int(0), Value.int(8), Value.float(1.0) });
    try expectMatch(&t, &.{ Value.int(3), Value.int(3), Value.float(1.0) }); // 0 iters, acc flushed unchanged
}

test "nativegen(F3): int/int division yields a float via cvtsi2sd on both operands" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // c = x / y where BOTH x and y are guard_int (int) — Lua's `/` is always float,
    // even on integers (7/2 == 3.5). proveKinds gives div .float regardless, so native
    // cvtsi2sd-promotes both operands then divsd. The oracle computes
    // x.toFloat()/y.toFloat() (== @floatFromInt == cvtsi2sd) → bit-exact, incl. int/0.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (counter)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 1 (int limit)
        .{ .op = .lt, .a = 0, .b = 2 }, // 3
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: x (int)
        .{ .op = .guard_int, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: y (int)
        .{ .op = .guard_int, .a = 7 }, // 8
        .{ .op = .div, .a = 5, .b = 7, .ty = .float }, // 9: x / y → float
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11
        .{ .op = .phi, .b = 9, .aux = 3 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.int(1), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{ Value.int(0), Value.int(7), Value.int(2), Value.float(0.0) }); // 7/2 = 3.5
    try expectMatch(&t, &.{ Value.int(0), Value.int(6), Value.int(3), Value.float(0.0) }); // 6/3 = 2.0 (exact)
    try expectMatch(&t, &.{ Value.int(0), Value.int(1), Value.int(0), Value.float(0.0) }); // 1/0 = +inf
    try expectMatch(&t, &.{ Value.int(0), Value.int(0), Value.int(0), Value.float(0.0) }); // 0/0 = nan
}

test "nativegen: derived guard_int on int arithmetic compiles and matches (#1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = acc + (i+7)*(i+7); i += 1; while i < limit — the `CSE-able body` shape.
    // The recorder guards the *derived* (i+7) and (i+7)*(i+7); both are statically
    // int (int-op-of-ints), so the guards must lower to nothing and the trace must
    // compile. regs: r0=i, r1=limit, r2=acc.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2: slot_load guard (hoisted)
        .{ .op = .guard_int, .a = 1 }, // 3: slot_load guard (hoisted)
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7: slot_load guard (hoisted)
        .{ .op = .konst, .aux = 0 }, // 8: 7
        .{ .op = .add, .a = 0, .b = 8 }, // 9: i + 7   (derived)
        .{ .op = .guard_int, .a = 9 }, // 10: DERIVED guard on the add → no-op
        .{ .op = .mul, .a = 9, .b = 9 }, // 11: (i+7)*(i+7)   (derived)
        .{ .op = .guard_int, .a = 11 }, // 12: DERIVED guard on the mul → no-op
        .{ .op = .add, .a = 6, .b = 11 }, // 13: acc + (i+7)^2
        .{ .op = .konst, .aux = 1 }, // 14: 1
        .{ .op = .add, .a = 0, .b = 14 }, // 15: i + 1
        .{ .op = .phi, .b = 13, .aux = 2 },
        .{ .op = .phi, .b = 15, .aux = 0 },
        .{ .op = .loop }, // 16
    };
    var consts = [_]Value{ Value.int(7), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // i=1,2,3 commit: acc = 8^2+9^2+10^2 = 245; exits at i==4.
    try expectMatch(&t, &.{ Value.int(1), Value.int(4), Value.int(0) });
    // 0 commits (i already == limit): regs unchanged.
    try expectMatch(&t, &.{ Value.int(10), Value.int(10), Value.int(99) });
}

test "nativegen: bails on unsupported traces" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var es = [_]u16{};

    // (a) a float constant → not provably int.
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 2 },
            .{ .op = .phi, .b = 3, .aux = 0 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.float(1.5)};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
    // (b) a slot_load with no covering guard_int.
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 1 },
            .{ .op = .phi, .b = 2, .aux = 0 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.int(1)};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
    // (c) guard_number (a float passes it → can't prove int).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_number, .a = 0 },
            .{ .op = .loop },
        };
        var consts = [_]Value{};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
    // (d) a deferred op (mod — div now compiles via the XMM path, F3; mod still
    // bails: it needs a libm-free integer/float remainder native doesn't emit).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .mod, .a = 0, .b = 2 },
            .{ .op = .phi, .b = 0, .aux = 0 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.int(2)};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
    // (e) [#1] a guard_int on a *bool* (a compare result) is not discharge-able →
    // must still bail (only proven-int operands are accepted by the relaxed guard).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .guard_int, .a = 0 }, // 1
            .{ .op = .konst, .aux = 0 }, // 2: 5
            .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 5  → bool
            .{ .op = .guard_int, .a = 3 }, // 4: guard_int on a bool → bail
            .{ .op = .phi, .b = 0, .aux = 0 },
            .{ .op = .loop }, // 5
        };
        var consts = [_]Value{Value.int(5)};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
}

/// Helper: run proveKinds + analyze and return whether the carried slot `slot`
/// coalesced its store into its home (win 2). Caller frees nothing; this owns it.
fn slotCoalesced(t: *const Trace, slot: u16) !bool {
    const kinds = try testing.allocator.alloc(Kind, t.instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, t.instrs.len);
    defer testing.allocator.free(slot_of);
    if (!proveKinds(testing.allocator, t, kinds, slot_of)) return error.ProveFailed;
    var al = analyze(testing.allocator, t, kinds, slot_of) orelse return error.AnalyzeBailed;
    defer al.deinit(testing.allocator);
    for (al.slots) |s| {
        if (s.slot == slot) return s.coalesced;
    }
    return error.NoSuchSlot;
}

test "nativegen win2: accumulator coalesces when no guard follows the update" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // guard_true is at index 5 (before the acc update at 8) → cond 1 holds → coalesce.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5  ← last body guard
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i   (after the guard → coalesces)
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1    (after the guard → coalesces)
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .phi, .b = 10, .aux = 0 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(try slotCoalesced(&t, 2)); // acc, left-operand home
    try testing.expect(try slotCoalesced(&t, 0)); // i,  left-operand home
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.int(100) });
}

test "nativegen win2: a guard AFTER the accumulation blocks coalescing (cond 1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc update at 8, then a guard_true at 10 reading a body bool: cond 1 fails for acc.
    // On that guard's failure the snapshot must restore the loop-header acc, NOT acc+i.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .slot_load, .aux = 2 }, // 4: acc
        .{ .op = .guard_int, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i + 1
        .{ .op = .add, .a = 4, .b = 0 }, // 8: acc + i    (precedes a later guard)
        .{ .op = .lt, .a = 7, .b = 1 }, // 9: (i+1) < limit
        .{ .op = .guard_true, .a = 9 }, // 10 ← guard AFTER the acc update
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .phi, .b = 7, .aux = 0 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(!(try slotCoalesced(&t, 2))); // acc must NOT coalesce
    try testing.expect(!(try slotCoalesced(&t, 0))); // i  must NOT coalesce
    // i=1,limit=5 → exits at the guard when i+1==5<5 false; acc/i restored to header.
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(1), Value.int(2), Value.int(50) }); // exits 2nd iter
}

test "nativegen win2(H1): an hload AFTER the accumulation blocks coalescing (cond 1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // H1 regression. `hload` is a mid-body side-exit: it tag-checks the field cell
    // against the guarded type and jumps to deopt_exit on mismatch (e.g. the field
    // drifted int→float between trace entries). So an accumulator update that PRECEDES
    // an hload must NOT coalesce into its home — otherwise the deopt flush at the hload
    // would commit the bumped accumulator even though the iteration aborted, diverging
    // from the tier-1a oracle (which side-exits at hload with the carried slot
    // untouched). Guard: `hload` must be in `last_body_guard`.
    //   acc += 1 at idx 6 precedes the hload at idx 9 → cond 1 must block acc's coalesce.
    const kt = try table.Table.create(testing.allocator);
    defer kt.destroy(testing.allocator);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: interned key (heap string stand-in)
        .{ .op = .slot_load, .aux = 1 }, // 3: acc
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .konst, .aux = 1 }, // 5: 1
        .{ .op = .add, .a = 3, .b = 5, .ty = .int }, // 6: acc + 1  (precedes the hload)
        .{ .op = .href, .a = 0, .b = 2, .aux = 0 }, // 7: cell
        .{ .op = .guard_hash, .a = 7 }, // 8
        .{ .op = .hload, .a = 7, .ty = .int }, // 9 ← mid-body side-exit AFTER the acc update
        .{ .op = .phi, .b = 6, .aux = 1 }, // acc carry ← acc+1
        .{ .op = .phi, .b = 9, .aux = 2 }, // lastseen carry ← hload (keeps hload live)
        .{ .op = .loop }, // 10
    };
    // const 0 must be a heap value (the href key); const 1 is the int step.
    var consts = [_]Value{ Value.heap(&kt.header), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(!(try slotCoalesced(&t, 1))); // acc must NOT coalesce
}

test "nativegen win2: old value still live blocks coalescing (cond 2)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // tmp = acc (slot3 write-only); acc = acc + i. acc's old slot_load is read by the
    // tmp store, which is live to the back-edge → cond 2 fails → no coalesce.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .phi, .b = 10, .aux = 0 },
        .{ .op = .phi, .b = 6, .aux = 3 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    // slot3 := acc_old (%6), still reading the old acc at the back-edge.
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(!(try slotCoalesced(&t, 2))); // acc's old value is still live
    try expectMatch(&t, &.{ Value.int(1), Value.int(4), Value.int(0), Value.int(-1) });
}

test "nativegen win2: commutative-right home coalesces; non-commutative-right does not" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = i + acc  (commutative, home is the RIGHT operand) → coalesces.
    var add_instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 0, .b = 6 }, // 8: i + acc   (home = b, commutative)
        .{ .op = .konst, .aux = 0 }, // 9
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .phi, .b = 10, .aux = 0 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const ta = Trace{ .anchor = undefined, .instrs = &add_instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(try slotCoalesced(&ta, 2));
    try expectMatch(&ta, &.{ Value.int(1), Value.int(5), Value.int(0) });

    // acc = k - acc  (non-commutative, home is the RIGHT operand) → must NOT coalesce
    // (sub home, k would compute acc-k, not k-acc).
    var sub_instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .konst, .aux = 1 }, // 8: 100
        .{ .op = .sub, .a = 8, .b = 6 }, // 9: 100 - acc   (home = b, NON-commutative)
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop }, // 12
    };
    var consts2 = [_]Value{ Value.int(1), Value.int(100) };
    const ts = Trace{ .anchor = undefined, .instrs = &sub_instrs, .consts = &consts2, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(!(try slotCoalesced(&ts, 2)));
    try expectMatch(&ts, &.{ Value.int(1), Value.int(4), Value.int(0) });
}

test "nativegen win2: unary into a carried slot whose operand is NOT its home" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // x = neg y, stored to slot x.  home(x) holds the OLD x, not y, so `neg home(x)`
    // would compute -x_old, not -y.  cond 3 (operand must be home(S)) blocks it.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: x (carried, but unused as operand)
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 3 }, // 8: y
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .neg, .a = 8 }, // 10: -y  (stored into x; operand is y, not x)
        .{ .op = .konst, .aux = 0 }, // 11: 1
        .{ .op = .add, .a = 0, .b = 11 }, // 12: i + 1
        .{ .op = .phi, .b = 10, .aux = 2 },
        .{ .op = .phi, .b = 12, .aux = 0 },
        .{ .op = .loop }, // 13
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(!(try slotCoalesced(&t, 2))); // x = -y must NOT coalesce into home(x)
    try expectMatch(&t, &.{ Value.int(0), Value.int(3), Value.int(0), Value.int(7) });
}

test "nativegen win2: a coalesced result consumed by a later op is not scavenged" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = acc + 1 (coalesces into home(acc)); u = acc_new band 7 (write-only slot).
    // win 1 must NOT reuse home(acc) for u (it is snapshot state), and the loop must
    // carry acc_new.  The guard is early so both are post-guard.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 1
        .{ .op = .add, .a = 6, .b = 8 }, // 9: acc + 1  (coalesces into home(acc))
        .{ .op = .konst, .aux = 1 }, // 10: 7
        .{ .op = .band, .a = 9, .b = 10 }, // 11: acc_new band 7  (reads the coalesced value)
        .{ .op = .add, .a = 0, .b = 8 }, // 12: i + 1
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .phi, .b = 11, .aux = 3 },
        .{ .op = .phi, .b = 12, .aux = 0 },
        .{ .op = .loop }, // 13
    };
    var consts = [_]Value{ Value.int(1), Value.int(7) };
    // slot3 := acc_new band 7 (write-only); acc := acc+1; i := i+1.
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(try slotCoalesced(&t, 2)); // acc coalesces
    try expectMatch(&t, &.{ Value.int(0), Value.int(5), Value.int(0), Value.int(0) });
}

test "nativegen win2: chained accumulators both coalesce (b reads new a)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // a = a + 1; b = b + a_new.  Both coalesce into their homes; b's in-place add reads
    // home(a) as a pure source (already updated to a_new this iteration).
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: a
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 3 }, // 8: b
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 6, .b = 10 }, // 11: a + 1   (→ home(a))
        .{ .op = .add, .a = 8, .b = 11 }, // 12: b + a_new (→ home(b), reads home(a))
        .{ .op = .add, .a = 0, .b = 10 }, // 13: i + 1
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .phi, .b = 12, .aux = 3 },
        .{ .op = .phi, .b = 13, .aux = 0 },
        .{ .op = .loop }, // 14
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try testing.expect(try slotCoalesced(&t, 2)); // a
    try testing.expect(try slotCoalesced(&t, 3)); // b
    try expectMatch(&t, &.{ Value.int(0), Value.int(4), Value.int(10), Value.int(100) });
}

test "nativegen: a swap loop exercises a register home cycle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // for i=0..limit { a, b = b, a }  — slot0=a, slot1=b, slot2=i, slot3=limit.
    // a's writeback is b's loaded value and vice-versa ⇒ home(a)<-home(b), home(b)<-home(a):
    // a 2-cycle the parallel-move must break with the scratch.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 2 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 3 }, // 2: limit
        .{ .op = .guard_int, .a = 2 }, // 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 0 }, // 6: a
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 1 }, // 8: b
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .phi, .b = 8, .aux = 0 },
        .{ .op = .phi, .b = 6, .aux = 1 },
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{Value.int(1)};
    // a<-b(ref8), b<-a(ref6), i<-i+1(ref11)
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // a=10, b=20, i=0, limit=3: three swaps ⇒ a=20, b=10. The oracle is the judge.
    try expectMatch(&t, &.{ Value.int(10), Value.int(20), Value.int(0), Value.int(3) });
    // limit=0: zero iterations, no swap.
    try expectMatch(&t, &.{ Value.int(10), Value.int(20), Value.int(0), Value.int(0) });
}

test "nativegen: operand-chain reuses one register across a left-folded sum" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = ((((acc + i) + k1) + k2) + k3); i += 1.  Each intermediate dies at the next
    // add (last_use == def+1), so operand coalescing folds the whole chain onto one
    // register (win 1). The oracle judges; this just exercises the coalescing path.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 1 }, // 2: limit
        .{ .op = .guard_int, .a = 2 }, // 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i        (transient t8)
        .{ .op = .konst, .aux = 0 }, // 9: 10
        .{ .op = .add, .a = 8, .b = 9 }, // 10: t8 + 10        (reuses t8's reg)
        .{ .op = .konst, .aux = 1 }, // 11: 100
        .{ .op = .add, .a = 10, .b = 11 }, // 12: t10 + 100    (reuses again)
        .{ .op = .konst, .aux = 2 }, // 13: 1
        .{ .op = .add, .a = 0, .b = 13 }, // 14: i + 1
        .{ .op = .phi, .b = 12, .aux = 2 },
        .{ .op = .phi, .b = 14, .aux = 0 },
        .{ .op = .loop }, // 15
    };
    var consts = [_]Value{ Value.int(10), Value.int(100), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{ Value.int(0), Value.int(4), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(2), Value.int(2), Value.int(7) }); // zero iters
}

/// Build a spill-forcing counting loop into `ins`: `acc = acc + i + (x0..x9)` with 10
/// invariant slots → 13 homes > 9 GP homes (`ALLOC_ORDER`), so homes spill. Because slot
/// homes are pinned in first-`slot_load` order and i/limit/acc load first, the CARRIED
/// homes (i, acc) keep registers and the later INVARIANT homes (x0..x9) are what spill —
/// enough to exercise the register allocator's spill path, but not the carried-home flush
/// (see `buildCarriedSpillLoop` for that). Every guard carries `aux == 0`, so the loop-
/// exit `guard_true` classifies as an ORDINARY guard (`isNumericForLoopDoneGuard` short-
/// circuits on `exit_pc == 0` before touching the undefined anchor). Register layout:
/// r0=i (carried), r1=limit (invariant), r2=acc (carried), r3..r12 = x0..x9 (invariant).
fn buildSpillLoop(gpa: std.mem.Allocator, ins: *std.ArrayListUnmanaged(I)) !void {
    const r_i: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 0 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_i });
    const r_lim: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 1 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_lim });
    const r_lt: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .lt, .a = r_i, .b = r_lim });
    try ins.append(gpa, .{ .op = .guard_true, .a = r_lt });
    const r_acc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 2 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_acc });

    var xrefs: [10]u16 = undefined;
    var k: usize = 0;
    while (k < 10) : (k += 1) {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .slot_load, .aux = @intCast(3 + k) });
        try ins.append(gpa, .{ .op = .guard_int, .a = r });
        xrefs[k] = r;
    }
    var sum: u16 = r_acc;
    for (xrefs) |xr| {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .add, .a = sum, .b = xr });
        sum = r;
    }
    {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .add, .a = sum, .b = r_i });
        sum = r;
    }
    const r_one: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .konst, .aux = 0 });
    const r_inc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .add, .a = r_i, .b = r_one });
    // slot-bound φs (the old exit_stores): acc←sum, i←r_inc, spliced before `loop`.
    try ins.append(gpa, .{ .op = .phi, .b = sum, .aux = 2 }); // acc
    try ins.append(gpa, .{ .op = .phi, .b = r_inc, .aux = 0 }); // i
    try ins.append(gpa, .{ .op = .loop });
}

/// Fill a 13-Value register file for the spill loop: i=0, limit, acc=0, x0..x9 = 1..10.
fn spillLoopRegs(regs: *[13]Value, limit: i64) void {
    regs[0] = Value.int(0); // i
    regs[1] = Value.int(limit); // limit
    regs[2] = Value.int(0); // acc
    var j: usize = 0;
    while (j < 10) : (j += 1) regs[3 + j] = Value.int(@intCast(j + 1)); // x0..x9 = 1..10
}

/// Number of carried accumulators in `buildCarriedSpillLoop`. i + N accumulators are all
/// CARRIED homes; with N = 12 that is 13 carried homes > 9 GP homes (`ALLOC_ORDER`), so
/// several carried homes are guaranteed to spill regardless of allocation order.
const CARRIED_SPILL_N = 12;

/// Build an ALL-CARRIED spill loop into `ins`: `for (i < limit) { acc_k += i for k in
/// 0..N }`. Unlike `buildSpillLoop` (whose spills land on invariants), EVERY spilled home
/// here is a loop-CARRIED accumulator, so at the ordinary loop-exit guard the shared
/// `deopt_exit` flush re-boxes a spilled carried home through `flushSlot`'s `.mem` branch
/// — the exact rax-scratch path that the old rax-staged dispatch holder collided with
/// (blocker-1). Guards carry `aux == 0` → the exit `guard_true` is an ORDINARY guard.
/// Slot layout: r0 = i (carried), r1..rN = acc_0..acc_{N-1} (carried), r(N+1) = limit
/// (invariant). Register file length is N + 2.
fn buildCarriedSpillLoop(gpa: std.mem.Allocator, ins: *std.ArrayListUnmanaged(I)) !void {
    const N = CARRIED_SPILL_N;
    const r_i: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 0 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_i });
    const r_lim: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = N + 1 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_lim });
    const r_lt: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .lt, .a = r_i, .b = r_lim });
    try ins.append(gpa, .{ .op = .guard_true, .a = r_lt });

    var accrefs: [N]u16 = undefined;
    var k: usize = 0;
    while (k < N) : (k += 1) {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .slot_load, .aux = @intCast(1 + k) });
        try ins.append(gpa, .{ .op = .guard_int, .a = r });
        accrefs[k] = r;
    }
    // acc_k += i for each accumulator.
    var newrefs: [N]u16 = undefined;
    k = 0;
    while (k < N) : (k += 1) {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .add, .a = accrefs[k], .b = r_i });
        newrefs[k] = r;
    }
    const r_one: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .konst, .aux = 0 });
    const r_inc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .add, .a = r_i, .b = r_one });
    // slot-bound φs: acc_k ← new_k (slot 1+k), i ← inc (slot 0).
    k = 0;
    while (k < N) : (k += 1) try ins.append(gpa, .{ .op = .phi, .b = newrefs[k], .aux = @intCast(1 + k) });
    try ins.append(gpa, .{ .op = .phi, .b = r_inc, .aux = 0 });
    try ins.append(gpa, .{ .op = .loop });
}

/// Fill a carried-spill register file: i=0, acc_0..acc_{N-1}=0, limit at slot N+1.
fn carriedSpillRegs(regs: *[CARRIED_SPILL_N + 2]Value, limit: i64) void {
    for (regs) |*v| v.* = Value.int(0);
    regs[CARRIED_SPILL_N + 1] = Value.int(limit);
}

test "nativegen: more carried+invariant slots than registers forces spilled homes" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var ins: std.ArrayListUnmanaged(I) = .empty;
    defer ins.deinit(gpa);
    try buildSpillLoop(gpa, &ins);

    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = ins.items, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    var regs: [13]Value = undefined;
    spillLoopRegs(&regs, 4);
    try expectMatch(&t, &regs);
}

test "nativegen: frameless spilled carried homes dispatch the ordinary guard exit cleanly (blocker-1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // 2.3c-0 blocker-1 regression. `buildCarriedSpillLoop` spills loop-CARRIED homes
    // (13 carried > 9 GP homes), so at the ordinary loop-exit `guard_true` (aux == 0)
    // the shared `deopt_exit` flush re-boxes a spilled carried home through `flushSlot`'s
    // `.mem` branch — which scratches rax. The old design staged the dispatch holder in
    // rax, so that spilled-home flush clobbered it before `jmp [rax]`, jumping through a
    // corrupt address. Now the resolved target rides in the flush-immune
    // `NativeResult.exit_target`, so the flush cannot touch it. If it regressed, this run
    // would jump into garbage and crash; a clean match against the tier-1a oracle proves
    // it survives. (buildSpillLoop's spills land on invariants, which the flush skips —
    // it would exercise the exit but NOT the carried-home rax path, so use this loop.)
    const gpa = testing.allocator;
    var ins: std.ArrayListUnmanaged(I) = .empty;
    defer ins.deinit(gpa);
    try buildCarriedSpillLoop(gpa, &ins);

    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = ins.items, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // limit=4 → commits 4 iterations, then the `i < limit` guard fails and the ORDINARY
    // exit fires with all (spilled) carried homes live. limit=0 → the guard fails on the
    // very first check (zero committed iterations), exercising the exit before any
    // back-edge. The oracle covers the exact flushed values.
    var regs4: [CARRIED_SPILL_N + 2]Value = undefined;
    carriedSpillRegs(&regs4, 4);
    try expectMatchFrameless(&t, &regs4);

    var regs0: [CARRIED_SPILL_N + 2]Value = undefined;
    carriedSpillRegs(&regs0, 0);
    try expectMatchFrameless(&t, &regs0);
}

test "nativegen A-v: composite bridge prefix emits but unarmed exit takes ordinary_mini" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // A continuation anchored at PC 29 re-tests the same proto's outer branch at
    // PC 13 (post-fetch exit PC 14). The slot-0 phi update is defined before the
    // guard, so E={r0}; the phi node itself remains post-guard, as in the recorded
    // edge-4 shape.
    var code: [30]bytecode.Instr = undefined;
    @memset(code[0..], bytecode.Instr.op0(.halt));
    code[13] = bytecode.Instr.opAx(.jmp_if_true, 0, 0);
    var proto = bytecode.Proto{ .code = &code, .name = "a-v-bridge", .id = 41 };
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: outer re-test
        .{ .op = .konst, .aux = 0 }, // 5: 1
        .{ .op = .add, .a = 0, .b = 5, .ty = .int }, // 6: next i (dominates guard)
        .{ .op = .guard_true, .a = 4, .aux = 14 }, // 7: edge-4 composite guard
        .{ .op = .phi, .b = 6, .aux = 0 }, // 8: post-guard node, pre-guard update
        .{ .op = .loop }, // 9
    };
    var consts = [_]Value{Value.int(1)};
    var exit_prov = [_]trace.ExitProvEntry{.{
        .index = 7,
        .prov = .{ .guard = .{
            .source_proto_id = proto.id,
            .source_pc = 13,
            .role = .branch_cond,
            .operand = .a,
            .polarity = .taken,
        } },
    }};
    var es = [_]u16{};
    const t = Trace{
        .id = 73,
        .anchor = .{ .proto = &proto, .pc = 29 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &es,
        .entry_guards = &.{},
        .exit_prov = &exit_prov,
    };
    try testing.expect(isCompositeBridgeCandidate(&t, 7));

    var arena = McodeArena.init(gpa);
    defer arena.deinit();
    var ct = compileInto(gpa, &arena, &t, null, null) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const shared_exit = arena.trampoline_exit.?;
    try testing.expectEqual(shared_exit, ct.slots[7]); // A-v publishes no bridge arm.

    // Pin the emitted head through the conditional-branch opcode. The rel32
    // displacement itself is deliberately excluded because ordinary_mini follows
    // the entire dead armed body; the two embedded addresses make this sequence
    // unique within the trace page.
    var prefix = x64.Assembler.init(gpa);
    defer prefix.deinit();
    const ordinary_mini = try prefix.label();
    try prefix.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&ct.slots[7]))));
    try prefix.movRegMem(.rax, .rax, 0);
    try prefix.movRegImm64(.rcx, @bitCast(@as(u64, shared_exit)));
    try prefix.cmpRegReg(.rax, .rcx);
    try prefix.jcc(.e, ordinary_mini);
    prefix.bind(ordinary_mini);
    prefix.resolve();
    try testing.expect(prefix.code.items.len > 4);
    try testing.expect(std.mem.indexOf(
        u8,
        ct.page.code,
        prefix.code.items[0 .. prefix.code.items.len - 4],
    ) != null);

    // Fail the composite guard immediately. The unarmed prefix must select
    // ordinary_mini → deopt_exit → shared_exit: one terminal `.deopt` receipt,
    // no `.region_bridge`, unchanged registers, and the legacy exit index.
    var tags = [_]u8{
        @intFromEnum(Value.int(5).tag),
        @intFromEnum(Value.int(3).tag),
    };
    var payloads = [_]u64{
        Value.int(5).payload.bits,
        Value.int(3).payload.bits,
    };
    var ledger: [irinterp.LEDGER_CAP]irinterp.LedgerEntry = undefined;
    const result = ct.runCapturingLedger(
        RegWindow.of(tags[0..], payloads[0..]),
        ledger[0..],
        .{},
    );
    try testing.expectEqual(@as(usize, 0), result.completed);
    try testing.expectEqual(@as(u32, 7), result.exit_instr);
    try testing.expectEqual(@as(usize, 1), result.ledger_len);
    try testing.expectEqual(irinterp.LedgerKind.deopt, ledger[0].kind);
    try testing.expectEqual(irinterp.LedgerOutcome.normal, ledger[0].outcome);
    try testing.expectEqual(@intFromEnum(Value.int(5).tag), tags[0]);
    try testing.expectEqual(Value.int(5).payload.bits, payloads[0]);
    try testing.expectEqual(@intFromEnum(Value.int(3).tag), tags[1]);
    try testing.expectEqual(Value.int(3).payload.bits, payloads[1]);
}

test "nativegen: analyze classifies slots and pins disjoint homes" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // Same clean counting loop: r0=i (carried), r1=limit (invariant), r2=acc (carried).
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .phi, .b = 10, .aux = 0 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    const kinds = try testing.allocator.alloc(Kind, instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, instrs.len);
    defer testing.allocator.free(slot_of);
    try testing.expect(proveKinds(testing.allocator, &t, kinds, slot_of));

    var al = analyze(testing.allocator, &t, kinds, slot_of) orelse return error.AnalyzeBailed;
    defer al.deinit(testing.allocator);

    // Three distinct slots, classified.
    try testing.expectEqual(@as(usize, 3), al.slots.len);
    for (al.slots) |s| {
        switch (s.slot) {
            0 => try testing.expectEqual(SlotClass.carried, s.class), // i: read+write
            1 => try testing.expectEqual(SlotClass.invariant, s.class), // limit: read-only
            2 => try testing.expectEqual(SlotClass.carried, s.class), // acc: read+write
            else => return error.UnexpectedSlot,
        }
        try testing.expectEqual(Kind.int, s.kind);
    }
    // Carried/invariant homes are register-disjoint (small trace ⇒ all in regs).
    var seen: u16 = 0;
    for (al.slots) |s| {
        try testing.expect(s.home == .reg);
        try testing.expect(seen & regBit(s.home.reg) == 0);
        seen |= regBit(s.home.reg);
    }
    // slot_load refs resolve to their slot home (no own register).
    try testing.expectEqual(al.slots[0].home, al.loc[0]); // ref 0 ↔ slot 0
    // Each exit_store's producer is live through to the loop marker (the back-edge).
    try testing.expectEqual(@as(u32, instrs.len - 1), al.last_use[8]); // acc+i
    try testing.expectEqual(@as(u32, instrs.len - 1), al.last_use[10]); // i+1
}

test "nativegen: analyze rejects a type-unstable carried slot" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // slot 0 is loaded as int (guarded) but stored as a bool (a comparison result) —
    // the oracle would deopt next iteration; cut-2 must refuse to compile it.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (int)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 3 (BOOL)
        .{ .op = .phi, .b = 3, .aux = 0 }, // slot 0 stored as the bool
        .{ .op = .loop }, // 4
    };
    var consts = [_]Value{Value.int(3)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    const kinds = try testing.allocator.alloc(Kind, instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, instrs.len);
    defer testing.allocator.free(slot_of);
    try testing.expect(proveKinds(testing.allocator, &t, kinds, slot_of));

    try testing.expect(analyze(testing.allocator, &t, kinds, slot_of) == null);
}

test "exec memory: assemble, map, and call a native fn(i64)->i64" {
    if (comptime !is_x64_linux) return error.SkipZigTest;

    // f(x) = 2*x + 1, SysV: arg in rdi, return in rax.
    //   mov rax, rdi ; add rax, rdi ; inc rax ; ret
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    try a.movRegReg(.rax, .rdi);
    try a.addRegReg(.rax, .rdi);
    try a.incReg(.rax);
    try a.ret();
    a.resolve();

    var page = try mapExecutable(a.code.items);
    defer page.deinit();

    const f = page.entry(fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 1), f(0));
    try testing.expectEqual(@as(i64, 21), f(10));
    try testing.expectEqual(@as(i64, -1), f(-1));
}

test "exec memory: a loop with a backward jump runs natively" {
    if (comptime !is_x64_linux) return error.SkipZigTest;

    // f(n) = sum(1..n) the dumb way:  rax=0; rcx=n; L: (n<=0?exit) rax+=rcx; rcx-=1; jnz-ish
    // Keep it simple & branch-exercising:  rax=0 ; while (rdi != 0) { rax += rdi; rdi -= 1; }
    //   xor-free version using cmp/jcc:
    //   mov rax, 0
    //   L: cmp rdi, 0 ; je END ; add rax, rdi ; sub rdi, 1 ; jmp L
    //   END: ret
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    const loop = try a.label();
    const end = try a.label();
    try a.movRegImm64(.rax, 0);
    a.bind(loop);
    try a.cmpRegImm32(.rdi, 0);
    try a.jcc(.e, end);
    try a.addRegReg(.rax, .rdi);
    try a.subRegImm32(.rdi, 1);
    try a.jmp(loop);
    a.bind(end);
    try a.ret();
    a.resolve();

    var page = try mapExecutable(a.code.items);
    defer page.deinit();

    const f = page.entry(fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 0), f(0));
    try testing.expectEqual(@as(i64, 15), f(5)); // 5+4+3+2+1
    try testing.expectEqual(@as(i64, 55), f(10));
}

// --- doc 24 c2: allocating traces (tostr_int/tostr_num + slen + guard_gc) ---

const gc = @import("gc.zig");
const string_mod = @import("string.zig");

/// The doc 24 c2 shape: `acc = acc + #tostring(i); i += 1; while i < limit`.
/// regs: r0=i, r1=limit, r2=acc. `guard_gc` carries the trace's alloc bound
/// (A=1) and sits, per the lazy-placement rule, immediately before the first
/// `.alloc` op.
fn tostrLenTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .guard_gc, .aux = 1 }, // 6: budget guard, A = 1
            .{ .op = .tostr_int, .a = 0, .ty = .heap }, // 7: tostring(i)
            .{ .op = .slen, .a = 7, .ty = .int }, // 8: #tostring(i)
            .{ .op = .slot_load, .aux = 2 }, // 9: acc
            .{ .op = .guard_int, .a = 9 }, // 10
            .{ .op = .add, .a = 9, .b = 8 }, // 11: acc + len
            .{ .op = .konst, .aux = 0 }, // 12: 1
            .{ .op = .add, .a = 0, .b = 12 }, // 13: i + 1
            .{ .op = .phi, .b = 11, .aux = 2 },
            .{ .op = .phi, .b = 13, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 24 c2: tostr_int + slen + guard_gc — tier-1a and native match, same allocation count" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{Value.int(1)};
    const t = tostrLenTrace(&consts);
    // i = 1..12 commit (exit when i == 13): acc = 9×1 + 3×2 = 15. Crosses the
    // 1-digit → 2-digit rendering boundary, so slen isn't constant.
    const regs_init = [_]Value{ Value.int(1), Value.int(13), Value.int(0) };

    // Oracle: tier-1a with its own heap.
    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const iobjs_before = iheap.object_count;
    var iregs = regs_init;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
    try testing.expectEqual(@as(usize, 12), iresult.completed);
    try testing.expectEqual(Value.int(13).payload.bits, iregs[0].payload.bits);
    try testing.expectEqual(Value.int(15).payload.bits, iregs[2].payload.bits);
    // Twelve fresh interned strings ("1".."12"), each exactly once.
    try testing.expectEqual(iobjs_before + 12, iheap.object_count);
    try testing.expect(iheap.internedLookup("12") != null);

    // Native: fresh heap, same trace, byte-identical registers AND the same
    // allocation count — the doc 24 D2 id-stream claim at this trace's scale.
    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    const nobjs_before = nheap.object_count;
    var ct = nativegen.compileWithHeap(gpa, &t, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs_arr = regs_init;
    const nregs: []Value = &nregs_arr;
    const nresult = try util.runNative(ct, nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try util.expectRegsEqual(&iregs, nregs);
    try testing.expectEqual(iheap.object_count - iobjs_before, nheap.object_count - nobjs_before);
    try testing.expect(nheap.internedLookup("12") != null);

    // Re-running against the SAME heap re-interns nothing (intern hits), and
    // the committed count is identical — rendering is pure.
    const objs_mid = nheap.object_count;
    var rregs_arr = regs_init;
    const rresult = try util.runNative(ct, &rregs_arr);
    try testing.expectEqual(iresult.completed, rresult.completed);
    try testing.expectEqual(objs_mid, nheap.object_count);
}

test "doc 24 c2: guard_gc declines at the header — budget exceeded, gc_stress, and no-heap all exit with ZERO allocations" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{Value.int(1)};
    const t = tostrLenTrace(&consts);
    const regs_init = [_]Value{ Value.int(1), Value.int(13), Value.int(0) };

    // (a) Budget exceeded: object_count + A >= next_gc fails the guard on
    // entry — completed == 0, exit at the guard_gc instr, nothing interned,
    // registers untouched.
    {
        var heap = gc.Heap.init(gpa);
        defer heap.deinit();
        heap.next_gc = heap.object_count; // saturate the budget
        const objs_before = heap.object_count;
        const strs_before = heap.strtab_count;

        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &heap }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 0), iresult.completed);
        try testing.expectEqual(@as(u32, 6), iresult.exit_instr);
        try testing.expectEqual(objs_before, heap.object_count);
        try testing.expectEqual(strs_before, heap.strtab_count);
        try util.expectRegsEqual(&regs_init, &iregs);

        var ct = nativegen.compileWithHeap(gpa, &t, &heap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 0), nresult.completed);
        try testing.expectEqual(@as(u32, 6), nresult.exit_instr);
        try testing.expectEqual(objs_before, heap.object_count);
        try util.expectRegsEqual(&regs_init, &nregs);
    }

    // (b) gc_stress: the budget arithmetic passes but the stress conjunct
    // fails — every entry must fall back to tier-0 (which owns per-safepoint
    // collection under stress).
    {
        var heap = gc.Heap.init(gpa);
        defer heap.deinit();
        heap.gc_stress = true;
        const objs_before = heap.object_count;

        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &heap }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 0), iresult.completed);
        try testing.expectEqual(@as(u32, 6), iresult.exit_instr);
        try testing.expectEqual(objs_before, heap.object_count);

        var ct = nativegen.compileWithHeap(gpa, &t, &heap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 0), nresult.completed);
        try testing.expectEqual(@as(u32, 6), nresult.exit_instr);
        try testing.expectEqual(objs_before, heap.object_count);
    }

    // (c) Fail closed with NO heap: tier-1a's guard_gc arm side-exits (bare
    // harness), and the native compiler declines the trace outright.
    {
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValues(&t, &iregs, values);
        try testing.expectEqual(@as(usize, 0), iresult.completed);
        try testing.expectEqual(@as(u32, 6), iresult.exit_instr);

        var arena = McodeArena.init(gpa);
        defer arena.deinit();
        try testing.expect(compileInto(gpa, &arena, &t, null, null) == null);
    }
}

test "doc 24 c2: tostr_num renders floats through the one shared renderer (tier parity)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    // acc = acc + #tostring(f); f += 0.5; while f < limit. regs: r0=f, r1=limit, r2=acc.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: f
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_float, .a = 0 }, // 2
        .{ .op = .guard_float, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .guard_gc, .aux = 1 }, // 6
        .{ .op = .tostr_num, .a = 0, .ty = .heap }, // 7
        .{ .op = .slen, .a = 7, .ty = .int }, // 8
        .{ .op = .slot_load, .aux = 2 }, // 9: acc
        .{ .op = .guard_int, .a = 9 }, // 10
        .{ .op = .add, .a = 9, .b = 8 }, // 11
        .{ .op = .konst, .aux = 0 }, // 12: 0.5
        .{ .op = .add, .a = 0, .b = 12, .ty = .float }, // 13: f + 0.5
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .phi, .b = 13, .aux = 0 },
        .{ .op = .loop },
    };
    var consts = [_]Value{Value.float(0.5)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // f = 1.0, 1.5, 2.0, 2.5 commit (exit at 3.0): io.writeValue renders
    // shortest-round-trip ("1", "1.5", "2", "2.5") → 1+3+1+3 = 8. Pins that
    // tostr_num goes through the ONE shared renderer — the same lengths tier-0's
    // bToString produces, so a renderer swap that breaks parity trips this.
    const regs_init = [_]Value{ Value.float(1.0), Value.float(3.0), Value.int(0) };

    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    var iregs = regs_init;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
    try testing.expectEqual(@as(usize, 4), iresult.completed);
    try testing.expectEqual(Value.int(8).payload.bits, iregs[2].payload.bits);
    try testing.expect(iheap.internedLookup("1.5") != null);

    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    var ct = nativegen.compileWithHeap(gpa, &t, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = regs_init;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try util.expectRegsEqual(&iregs, &nregs);
    try testing.expectEqual(iheap.object_count, nheap.object_count);
}
