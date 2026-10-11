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
const Trace = @import("trace_code.zig").TraceCode;
const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const trace_exec = @import("trace_exec.zig");
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

test "shared href and absence string key is materialized in native code" {
    var heap = @import("gc.zig").Heap.init(testing.allocator);
    defer heap.deinit();
    const present = try heap.newTable();
    const absent = try heap.newTable();
    const key = Value.heap(&(try heap.intern("field")).header);
    try present.set(testing.allocator, key, Value.int(7));
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_table, .a = 2 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .href, .a = 0, .b = 4, .aux = 3 },
        .{ .op = .guard_hash, .a = 5, .aux = 1 },
        .{ .op = .hload, .a = 5, .ty = .int },
        .{ .op = .guard_absent, .a = 2, .b = 4 },
        .{ .op = .phi, .b = 7, .aux = 2 },
        .{ .op = .link },
    };
    var consts = [_]Value{key};
    var t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.heap(&present.header), Value.heap(&absent.header), Value.int(0), Value.int(@bitCast(@as(u64, @intFromPtr(present.fieldPtr(key).?)))) };
    try expectMatch(&t, &regs);
    try absent.set(testing.allocator, key, Value.boolean(false));
    try expectMatch(&t, &regs);
}

test "guarded absence matches native for holes, hash overflow, insertion and metatables" {
    const tab = try table.Table.create(testing.allocator);
    defer tab.destroy(testing.allocator);
    const meta = try table.Table.create(testing.allocator);
    defer meta.destroy(testing.allocator);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 2 },
        .{ .op = .guard_absent, .a = 0, .b = 2 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .phi, .b = 5, .aux = 2 },
        .{ .op = .link },
    };
    var consts = [_]Value{Value.nil()};
    var t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.heap(&tab.header), Value.int(9999), Value.int(42) };
    try expectMatch(&t, &regs);
    try tab.set(testing.allocator, Value.int(9999), Value.boolean(false));
    try expectMatch(&t, &regs); // false is present, not nil
    try tab.set(testing.allocator, Value.int(9999), Value.nil());
    try expectMatch(&t, &regs);
    for (1..20) |i| try tab.set(testing.allocator, Value.int(@intCast(i)), Value.int(1));
    try tab.set(testing.allocator, Value.int(5), Value.nil());
    regs[1] = Value.int(5);
    try expectMatch(&t, &regs); // packed presence-bitmap hole
    tab.metatable = meta;
    try expectMatch(&t, &regs);
}

test "guarded absence matches native across bool/value lanes and negative keys" {
    // Same trace shape as above; only the table layouts differ. Each pair of
    // expectMatch calls exercises the inline path's per-lane nil encoding
    // (doc 45 D7): bool lane in-band byte, `.value` lane nil tag, and the
    // negative-key / hash-resident shapes that must reach the callout.
    const gpa = testing.allocator;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 2 },
        .{ .op = .guard_absent, .a = 0, .b = 2 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .phi, .b = 5, .aux = 2 },
        .{ .op = .link },
    };
    var consts = [_]Value{Value.nil()};
    var t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };

    // Bool lane: contiguous booleans, then punch an in-band hole (byte 0).
    const btab = try table.Table.create(gpa);
    defer btab.destroy(gpa);
    for (0..4) |k| try btab.set(gpa, Value.int(@intCast(k)), Value.boolean(k % 2 == 0));
    try btab.set(gpa, Value.int(2), Value.nil());
    try testing.expectEqual(arr.Lane.boolean, btab.array.lane); // premise: bool lane
    var regs = [_]Value{ Value.heap(&btab.header), Value.int(2), Value.int(42) };
    try expectMatch(&t, &regs); // hole → absent → guard passes
    regs[1] = Value.int(3);
    try expectMatch(&t, &regs); // `false` present → guard fails (native == oracle)

    // Value lane: mixed int/table values force the type-erased lane; nil is
    // in-band (a nil-tagged 16-byte Value), probed by tag, no bitmap.
    const vtab = try table.Table.create(gpa);
    defer vtab.destroy(gpa);
    const child = try table.Table.create(gpa);
    defer child.destroy(gpa);
    try vtab.set(gpa, Value.int(0), Value.int(7));
    try vtab.set(gpa, Value.int(1), Value.heap(&child.header));
    try vtab.set(gpa, Value.int(2), Value.int(9));
    try vtab.set(gpa, Value.int(1), Value.nil());
    try testing.expectEqual(arr.Lane.value, vtab.array.lane); // premise: value lane
    regs[0] = Value.heap(&vtab.header);
    regs[1] = Value.int(1);
    try expectMatch(&t, &regs); // in-band nil → absent
    regs[1] = Value.int(2);
    try expectMatch(&t, &regs); // present int → guard fails

    // Negative keys are never in the array part (unsigned-wrap bounds): a
    // hash-resident one must fail the guard THROUGH the callout, an absent
    // one must pass through it (hash non-empty → no inline shortcut).
    const ntab = try table.Table.create(gpa);
    defer ntab.destroy(gpa);
    try ntab.set(gpa, Value.int(-7), Value.int(1));
    regs[0] = Value.heap(&ntab.header);
    regs[1] = Value.int(-7);
    try expectMatch(&t, &regs); // hash-resident → guard fails
    regs[1] = Value.int(-8);
    try expectMatch(&t, &regs); // absent, hash non-empty → callout proves nil
}

// --- doc 44 D12c prerequisite: arbitrary boxed pass-through -----------------

test "one-shot terminal separates incoming and outgoing register kinds" {
    var code = [_]bytecode.Instr{.{ .op = .ret }};
    var proto = bytecode.Proto{ .code = &code, .num_registers = 2 };
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_float, .a = 2 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .phi, .b = 0, .aux = 1 },
        .{ .op = .terminal, .a = 0, .aux = 0 },
    };
    var t = Trace{ .anchor = .{ .proto = &proto, .pc = trace.FUNC_HEAD_PC, .proto_id = proto.id }, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.int(17), Value.float(2.5) };
    try expectMatch(&t, &regs);
    // Prologue refusal must not publish either outgoing snapshot value.
    regs[0] = Value.boolean(true);
    try expectMatch(&t, &regs);
}

test "unguarded slot load may pass through a slot-bound phi with tag and payload intact" {
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 3 },
        .{ .op = .phi, .b = 0, .aux = 2 },
        .{ .op = .link },
    };
    var t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    // A heap-looking payload is intentional: native must copy the arbitrary tag
    // byte and payload independently, not guess an integer or heap kind.
    var regs = [_]Value{ Value.nil(), Value.int(9), Value.nil(), Value.boolean(true) };
    regs[3].payload.bits = 0xFEDC_BA98_7654_3210;
    try expectMatch(&t, &regs);
}

test "unguarded boxed pass-through rejects typed inspection" {
    const typed_ops = [_]trace.IrOp{ .guard_true, .guard_false };
    for (typed_ops) |op| {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 3 },
            .{ .op = op, .a = 0 },
            .{ .op = .phi, .b = 0, .aux = 2 },
            .{ .op = .link },
        };
        var t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
        try expectBail(&t);
    }
    var arithmetic = [_]I{
        .{ .op = .slot_load, .aux = 3 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .phi, .b = 0, .aux = 2 },
        .{ .op = .link },
    };
    var consts = [_]Value{Value.int(1)};
    var at = Trace{ .anchor = undefined, .instrs = &arithmetic, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&at);
}

fn expectBoxedParallel(terminal: trace.IrOp) !void {
    var code = [_]bytecode.Instr{.{ .op = if (terminal == .terminal) .ret else .jmp }};
    var proto = bytecode.Proto{ .code = &code, .num_registers = 4, .name = "boxed-parallel" };
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .slot_load, .aux = 2 },
        .{ .op = .phi, .b = 1, .aux = 0 }, // swap 0 <- 1
        .{ .op = .phi, .b = 0, .aux = 1 }, // swap 1 <- 0
        .{ .op = .phi, .b = 0, .aux = 2 }, // fanout old 0
        .{ .op = .phi, .b = 2, .aux = 3 }, // write-only destination
        .{ .op = terminal, .a = 0, .aux = 0 },
    };
    var t = Trace{ .anchor = .{ .proto = &proto, .pc = trace.FUNC_HEAD_PC, .proto_id = proto.id }, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.int(11), Value.boolean(true), Value.float(3.25), Value.nil() };
    // Distinct payload bits make tag-only and payload-only copy bugs visible.
    regs[0].payload.bits = 0x1111_2222_3333_4444;
    regs[1].payload.bits = 0x5555_6666_7777_8888;
    regs[2].payload.bits = 0x9999_AAAA_BBBB_CCCC;
    const kinds = try testing.allocator.alloc(Kind, instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, instrs.len);
    defer testing.allocator.free(slot_of);
    try testing.expect(proveKinds(testing.allocator, &t, kinds, slot_of));
    var allocation = analyze(testing.allocator, &t, kinds, slot_of) orelse return error.AnalyzeBailedUnexpectedly;
    allocation.deinit(testing.allocator);
    try expectMatch(&t, &regs);
}

test "boxed phi terminal snapshots preserve swaps fanout and write-only destinations" {
    try expectBoxedParallel(.link);
    try expectBoxedParallel(.terminal);
}

test "boxed carried state remains byte-identical on an unrelated preterminal guard failure" {
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .lt, .a = 0, .b = 2 },
        .{ .op = .guard_true, .a = 3 }, // 7 < 0 fails
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .phi, .b = 5, .aux = 2 },
        .{ .op = .link },
    };
    var consts = [_]Value{Value.int(0)};
    var t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.int(7), Value.boolean(false), Value.float(-9.5) };
    regs[1].payload.bits = 0x0123_4567_89AB_CDEF;
    try expectMatch(&t, &regs);
}

test "x64 byte register store emits mandatory REX for sil and extended registers" {
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    try a.movByteMemReg(.rdi, 0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x88, 0x07 }, a.code.items);
    a.code.clearRetainingCapacity();
    try a.movByteMemReg(.rdi, 0, .rsi);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x88, 0x37 }, a.code.items);
    a.code.clearRetainingCapacity();
    try a.movByteMemReg(.rdi, 0, .r8);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x88, 0x07 }, a.code.items);
}

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
    try expectMatch(&t, &regs4);

    var regs0: [CARRIED_SPILL_N + 2]Value = undefined;
    carriedSpillRegs(&regs0, 0);
    try expectMatch(&t, &regs0);
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
    var t = Trace{
        .anchor = .{ .proto = &proto, .pc = 29, .proto_id = proto.id },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &es,
        .entry_guards = &.{},
        .exit_prov = &exit_prov,
    };
    var snap_arena = std.heap.ArenaAllocator.init(gpa);
    defer snap_arena.deinit();
    try @import("trace_testutil.zig").snapshotBranchGuardsFromPhis(snap_arena.allocator(), &t);
    try testing.expect(isCompositeBridgeCandidate(&t, 7));

    var arena = McodeArena.init(gpa);
    defer arena.deinit();
    var ct = compileInto(gpa, &arena, &t, 73, null, null) orelse return error.NativeBailedUnexpectedly;
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
    var ledger: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    const result = ct.runCapturingLedger(
        RegWindow.of(tags[0..], payloads[0..]),
        ledger[0..],
        .{},
    );
    try testing.expectEqual(@as(usize, 0), result.completed);
    try testing.expectEqual(@as(u32, 7), result.exit_instr);
    try testing.expectEqual(@as(usize, 1), result.ledger_len);
    try testing.expectEqual(trace_exec.LedgerKind.deopt, ledger[0].kind);
    try testing.expectEqual(trace_exec.LedgerOutcome.normal, ledger[0].outcome);
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
    var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
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

        var ct = nativegen.compileWithHeap(gpa, &t, 0, &heap) orelse return error.NativeBailedUnexpectedly;
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

        var ct = nativegen.compileWithHeap(gpa, &t, 0, &heap) orelse return error.NativeBailedUnexpectedly;
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
        try testing.expect(compileInto(gpa, &arena, &t, 0, null, null) == null);
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
    var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = regs_init;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try util.expectRegsEqual(&iregs, &nregs);
    try testing.expectEqual(iheap.object_count, nheap.object_count);
}

// --- doc 24 c3: the snew class (ssub/srev/schar1/srep2 + guard_string) ------

/// The c3 flagship shape: `acc = acc + #reverse(sub(s, i, i+2)); i += 1;
/// while i < limit`. regs: r0=i, r1=limit, r2=acc, r3=s (an invariant OBSERVED
/// string → guard_string, prologue-pinned natively). Exercises the one
/// three-operand op (`ssub`, end index in aux), proven-string chaining
/// (srev.a and slen.a are producer results — no further guards), and the
/// budget bound A=2.
fn snewSubRevTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .slot_load, .aux = 3 }, // 6: s
            .{ .op = .guard_string, .a = 6 }, // 7
            .{ .op = .konst, .aux = 0 }, // 8: 2
            .{ .op = .add, .a = 0, .b = 8 }, // 9: i + 2
            .{ .op = .guard_gc, .aux = 2 }, // 10: budget, A = 2
            .{ .op = .ssub, .a = 6, .b = 0, .aux = 9, .ty = .heap }, // 11: sub(s, i, i+2)
            .{ .op = .srev, .a = 11, .ty = .heap }, // 12: reverse(...)
            .{ .op = .slen, .a = 12, .ty = .int }, // 13
            .{ .op = .slot_load, .aux = 2 }, // 14: acc
            .{ .op = .guard_int, .a = 14 }, // 15
            .{ .op = .add, .a = 14, .b = 13 }, // 16
            .{ .op = .konst, .aux = 1 }, // 17: 1
            .{ .op = .add, .a = 0, .b = 17 }, // 18: i + 1
            .{ .op = .phi, .b = 16, .aux = 2 },
            .{ .op = .phi, .b = 18, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 24 c3: ssub + srev chain on a guard_string-pinned slot — tier parity, UTF-8 cp semantics, same allocation count" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(2), Value.int(1) };
    const t = snewSubRevTrace(&consts);

    // Oracle heap owns the subject string; the ssub window slides across a
    // MULTIBYTE region ("héllo": h é l l o), so a byte-indexed sub would
    // diverge from the shared cp-indexed core immediately.
    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const isubj = try iheap.intern("héllo");
    // i = 1..6 commit (exit at 7 > limit... limit=7 → i<7, commits i=1..6):
    // windows hél/éll/llo/lo/o/"" — every sub result is 3,3,3,2,1,0 cps and
    // srev preserves cp count, so acc = 12.
    const regs_init_i = [_]Value{ Value.int(1), Value.int(7), Value.int(0), Value.heap(&isubj.header) };
    const iobjs_before = iheap.object_count;
    var iregs = regs_init_i;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
    try testing.expectEqual(@as(usize, 6), iresult.completed);
    try testing.expectEqual(Value.int(12).payload.bits, iregs[2].payload.bits);
    // The reversed multibyte window is a REAL cp reversal, not a byte reversal
    // (byte-reversed "hél" would be invalid UTF-8).
    try testing.expect(iheap.internedLookup("léh") != null);
    try testing.expect(iheap.internedLookup("olléh") == null); // never a full reverse
    const iallocs = iheap.object_count - iobjs_before;

    // Native: fresh heap + its own copy of the subject, same trace.
    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    const nsubj = try nheap.intern("héllo");
    const regs_init_n = [_]Value{ Value.int(1), Value.int(7), Value.int(0), Value.heap(&nsubj.header) };
    const nobjs_before = nheap.object_count;
    var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = regs_init_n;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    // Scalar registers match bit-for-bit; the two heap registers hold each
    // heap's own subject (pointers differ by construction), so compare the
    // scalars and the subject identity separately.
    try testing.expectEqual(iregs[0].payload.bits, nregs[0].payload.bits);
    try testing.expectEqual(iregs[2].payload.bits, nregs[2].payload.bits);
    try testing.expectEqual(@intFromPtr(&nsubj.header), nregs[3].payload.bits);
    // Same allocation count — the doc 24 D2 id-stream claim for the snew class.
    try testing.expectEqual(iallocs, nheap.object_count - nobjs_before);
    try testing.expect(nheap.internedLookup("léh") != null);

    // Re-running against the SAME heap re-interns nothing (pure cores + intern
    // hits): committed count identical, object_count unchanged.
    const objs_mid = nheap.object_count;
    var rregs = regs_init_n;
    const rresult = try util.runNative(ct, &rregs);
    try testing.expectEqual(iresult.completed, rresult.completed);
    try testing.expectEqual(objs_mid, nheap.object_count);
}

test "doc 24 c3: guard_string prologue pin — a non-string entry fails the prologue with regs untouched" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(2), Value.int(1) };
    const t = snewSubRevTrace(&consts);

    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var ct = nativegen.compileWithHeap(gpa, &t, 0, &heap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();

    // (a) A TABLE in the string slot: TAG_HEAP passes the tag lane, the new
    // `header.type == string` prologue check catches it — completed 0,
    // prologue_fail, nothing allocated, registers untouched.
    {
        const tbl = try table.Table.create(gpa);
        defer tbl.destroy(gpa);
        const regs_init = [_]Value{ Value.int(1), Value.int(7), Value.int(0), Value.heap(&tbl.header) };
        const objs_before = heap.object_count;
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 0), nresult.completed);
        try testing.expectEqual(trace_exec.ExitReason.prologue_fail, nresult.exit_reason);
        try testing.expectEqual(objs_before, heap.object_count);
        try util.expectRegsEqual(&regs_init, &nregs);
        // The tier-1a oracle side-exits at the guard_string body instr instead
        // (it has no hoisted prologue) — same net effect: zero commits, zero
        // allocations, regs untouched.
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &heap }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 0), iresult.completed);
        try testing.expectEqual(@as(u32, 7), iresult.exit_instr);
        try testing.expectEqual(objs_before, heap.object_count);
        try util.expectRegsEqual(&regs_init, &iregs);
    }

    // (b) An INT in the string slot: the [RV-1] TAG_HEAP tag-lane check
    // catches it even earlier — same contract.
    {
        const regs_init = [_]Value{ Value.int(1), Value.int(7), Value.int(0), Value.int(42) };
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 0), nresult.completed);
        try testing.expectEqual(trace_exec.ExitReason.prologue_fail, nresult.exit_reason);
        try util.expectRegsEqual(&regs_init, &nregs);
    }

    // (c) Fail closed with NO heap: the compiler declines any snew trace.
    {
        var arena = McodeArena.init(gpa);
        defer arena.deinit();
        try testing.expect(compileInto(gpa, &arena, &t, 0, null, null) == null);
    }
}

test "doc 24 c3: schar1 + srep2 — tier parity incl. the n<=0 empty repeat and the invalid-codepoint side-exit" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    // acc = acc + #rep(char(base + i), i); i += 1; while i < limit.
    // regs: r0=i, r1=limit, r2=acc. consts: [base, 1].
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: base
        .{ .op = .add, .a = 0, .b = 6 }, // 7: base + i
        .{ .op = .guard_gc, .aux = 2 }, // 8: budget, A = 2
        .{ .op = .schar1, .a = 7, .ty = .heap }, // 9: char(base+i)
        .{ .op = .srep2, .a = 9, .b = 0, .ty = .heap }, // 10: rep(c, i)
        .{ .op = .slen, .a = 10, .ty = .int }, // 11
        .{ .op = .slot_load, .aux = 2 }, // 12: acc
        .{ .op = .guard_int, .a = 12 }, // 13
        .{ .op = .add, .a = 12, .b = 11 }, // 14
        .{ .op = .konst, .aux = 1 }, // 15: 1
        .{ .op = .add, .a = 0, .b = 15 }, // 16: i + 1
        .{ .op = .phi, .b = 14, .aux = 2 },
        .{ .op = .phi, .b = 16, .aux = 0 },
        .{ .op = .loop },
    };
    var es = [_]u16{};

    // (a) Multibyte happy path from a NEGATIVE i: base 233 → char(233+i) is a
    // 2-byte 1-cp "é"-neighbourhood codepoint; i = -2, -1, 0 exercise
    // rep2Core's n<=0 → "" arm (slen 0), then i = 1..4 accumulate i cps each
    // (cp-len, not byte-len). acc = 1+2+3+4 = 10.
    {
        var consts = [_]Value{ Value.int(233), Value.int(1) };
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        const regs_init = [_]Value{ Value.int(-2), Value.int(5), Value.int(0) };

        var iheap = gc.Heap.init(gpa);
        defer iheap.deinit();
        const iobjs_before = iheap.object_count;
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 7), iresult.completed);
        try testing.expectEqual(Value.int(10).payload.bits, iregs[2].payload.bits);
        try testing.expect(iheap.internedLookup("") != null); // the n<=0 arm ran

        var nheap = gc.Heap.init(gpa);
        defer nheap.deinit();
        const nobjs_before = nheap.object_count;
        var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try util.expectRegsEqual(&iregs, &nregs);
        try testing.expectEqual(iheap.object_count - iobjs_before, nheap.object_count - nobjs_before);
    }

    // (b) Invalid codepoint mid-run: base just below the Unicode ceiling, so
    // char(base+i) is valid for i=1,2 (0x10FFFF is the last valid codepoint)
    // and OUT OF RANGE at i=3. Both tiers
    // commit exactly 2 iterations and side-exit at the schar1 (the collapsed
    // D5 vm_error arm: null → clean exit; tier-0 replay re-raises), with
    // byte-identical registers and allocation counts.
    {
        var consts = [_]Value{ Value.int(0x10FFFF - 2), Value.int(1) };
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        const regs_init = [_]Value{ Value.int(1), Value.int(100), Value.int(0) };

        var iheap = gc.Heap.init(gpa);
        defer iheap.deinit();
        const iobjs_before = iheap.object_count;
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 2), iresult.completed);
        try testing.expectEqual(@as(u32, 9), iresult.exit_instr);

        var nheap = gc.Heap.init(gpa);
        defer nheap.deinit();
        const nobjs_before = nheap.object_count;
        var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
        try testing.expectEqual(iheap.object_count - iobjs_before, nheap.object_count - nobjs_before);
    }
}

// --- doc 24 c4: adversarial matrix (D9.2) -----------------------------------

/// The two-allocs-per-iteration vehicle for the c4 budget legs:
/// `acc = acc + #rep(char(base + i), i); i += 1; while i < limit` — schar1 +
/// srep2, A = 2. regs: r0=i, r1=limit, r2=acc. consts: [base, 1].
fn charRepTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .konst, .aux = 0 }, // 6: base
            .{ .op = .add, .a = 0, .b = 6 }, // 7: base + i
            .{ .op = .guard_gc, .aux = 2 }, // 8: budget, A = 2
            .{ .op = .schar1, .a = 7, .ty = .heap }, // 9
            .{ .op = .srep2, .a = 9, .b = 0, .ty = .heap }, // 10
            .{ .op = .slen, .a = 10, .ty = .int }, // 11
            .{ .op = .slot_load, .aux = 2 }, // 12: acc
            .{ .op = .guard_int, .a = 12 }, // 13
            .{ .op = .add, .a = 12, .b = 11 }, // 14
            .{ .op = .konst, .aux = 1 }, // 15: 1
            .{ .op = .add, .a = 0, .b = 15 }, // 16: i + 1
            .{ .op = .phi, .b = 14, .aux = 2 },
            .{ .op = .phi, .b = 16, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 24 c4: two allocs per iteration — the bound declines entry even when ONE would fit; minimal headroom exhausts identically across tiers" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(65), Value.int(1) };
    const t = charRepTrace(&consts);
    const regs_init = [_]Value{ Value.int(1), Value.int(30), Value.int(0) };

    // (a) Exactly one object of headroom: A = 2, so the predicate
    // `object_count + 2 < next_gc` fails and the guard exits with ZERO
    // allocations — even though the first of the two would have fit. That is
    // the design: the bound is conservative per-iteration headroom, never a
    // partial-iteration allowance (a partial burst would need mid-iteration
    // continuation, doc 24 D3v2).
    {
        var iheap = gc.Heap.init(gpa);
        defer iheap.deinit();
        iheap.next_gc = iheap.object_count + 2;
        const iobjs = iheap.object_count;
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 0), iresult.completed);
        try testing.expectEqual(@as(u32, 8), iresult.exit_instr);
        try testing.expectEqual(iobjs, iheap.object_count);
        try util.expectRegsEqual(&regs_init, &iregs);

        var nheap = gc.Heap.init(gpa);
        defer nheap.deinit();
        nheap.next_gc = nheap.object_count + 2;
        const nobjs = nheap.object_count;
        var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 0), nresult.completed);
        try testing.expectEqual(@as(u32, 8), nresult.exit_instr);
        try testing.expectEqual(nobjs, nheap.object_count);
        try util.expectRegsEqual(&regs_init, &nregs);
    }

    // (b) A few objects of headroom: the loop allocates fresh strings each
    // iteration (char is a rotating singleton set, but rep(c, i) grows with i),
    // so `object_count` climbs until the guard re-check fails MID-RUN — the
    // "threshold crossing with the budget guard bouncing entry" leg at unit
    // scale. Both tiers must stop at the same iteration with the same heap
    // delta and byte-identical registers.
    {
        var iheap = gc.Heap.init(gpa);
        defer iheap.deinit();
        iheap.next_gc = iheap.object_count + 9;
        const iobjs = iheap.object_count;
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
        try testing.expect(iresult.completed >= 1);
        try testing.expect(iresult.completed < 29); // it must NOT finish
        try testing.expectEqual(@as(u32, 8), iresult.exit_instr); // stopped at the budget

        var nheap = gc.Heap.init(gpa);
        defer nheap.deinit();
        nheap.next_gc = nheap.object_count + 9;
        const nobjs = nheap.object_count;
        var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
        try testing.expectEqual(iheap.object_count - iobjs, nheap.object_count - nobjs);
    }
}

test "doc 24 c4: an intern-hit loop parked just below next_gc completes natively (the parked case is correct)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(65), Value.int(1) };
    const t = charRepTrace(&consts);
    const regs_init = [_]Value{ Value.int(1), Value.int(30), Value.int(0) };

    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var ct = nativegen.compileWithHeap(gpa, &t, 0, &heap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();

    // Warm run: intern every string the loop produces (ample budget).
    var wregs = regs_init;
    const wresult = try util.runNative(ct, &wregs);
    try testing.expectEqual(@as(usize, 29), wresult.completed);

    // Parked run: every allocation is now an intern HIT (zero links), so
    // `object_count` never moves and the guard passes forever at a fixed
    // one-object headroom — the loop must complete natively, never bouncing.
    heap.next_gc = heap.object_count + 3; // A=2 → headroom of exactly one
    const objs_before = heap.object_count;
    var pregs = regs_init;
    const presult = try util.runNative(ct, &pregs);
    try testing.expectEqual(@as(usize, 29), presult.completed);
    try testing.expectEqual(objs_before, heap.object_count);
    try util.expectRegsEqual(&wregs, &pregs);
}

test "doc 24 c4: OOM injection — the same fail point produces identical completed/exit/heap across tiers (D2 id-stream)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(65), Value.int(1) };
    const t = charRepTrace(&consts);
    const regs_init = [_]Value{ Value.int(1), Value.int(30), Value.int(0) };

    // Both tiers run the SAME shared cores against the heap's gpa, so the
    // heap-allocation SEQUENCE is identical (D2) and a failing allocator with
    // the same fail_index must produce the same observable outcome: a clean
    // side-exit at the failing snew op (null return — no partial link), the
    // same committed count, the same heap delta, byte-identical registers.
    // Sweep several fail points to land the failure in scratch growth, string
    // creation, and strtab paths alike.
    const fail_points = [_]usize{ 3, 5, 8, 13, 21 };
    for (fail_points) |fp| {
        var ifail = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fp });
        var iheap = gc.Heap.init(ifail.allocator());
        defer iheap.deinit();
        const iobjs = iheap.object_count;
        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
        try testing.expect(iresult.completed < 29); // the OOM stopped it early

        var nfail = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fp });
        var nheap = gc.Heap.init(nfail.allocator());
        defer nheap.deinit();
        const nobjs = nheap.object_count;
        var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
        try testing.expectEqual(iheap.object_count - iobjs, nheap.object_count - nobjs);
    }
}

// ---------------------------------------------------------------------------
// doc 25: mod/idiv native lowering
// ---------------------------------------------------------------------------

/// regs: r0=i, r1=a, r2=b, r3=accm, r4=accq. Three iterations of
/// `accm += a % b; accq += a // b` — both ops on the SAME operand pair, so
/// the sign matrix exercises the floor adjustment of each independently.
fn intDivModTrace() [23]I {
    return .{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: limit 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 3
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: a
        .{ .op = .guard_int, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: b
        .{ .op = .guard_int, .a = 7 }, // 8
        .{ .op = .slot_load, .aux = 3 }, // 9: accm
        .{ .op = .guard_int, .a = 9 }, // 10
        .{ .op = .slot_load, .aux = 4 }, // 11: accq
        .{ .op = .guard_int, .a = 11 }, // 12
        .{ .op = .mod, .a = 5, .b = 7, .ty = .int }, // 13: a % b
        .{ .op = .idiv, .a = 5, .b = 7, .ty = .int }, // 14: a // b
        .{ .op = .add, .a = 9, .b = 13 }, // 15
        .{ .op = .add, .a = 11, .b = 14 }, // 16
        .{ .op = .konst, .aux = 1 }, // 17: 1
        .{ .op = .add, .a = 0, .b = 17 }, // 18
        .{ .op = .phi, .b = 15, .aux = 3 },
        .{ .op = .phi, .b = 16, .aux = 4 },
        .{ .op = .phi, .b = 18, .aux = 0 },
        .{ .op = .loop }, // 22
    };
}

test "doc 25: int % and // over the full sign matrix — floor semantics, tier parity (the adjust bug farm)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var consts = [_]Value{ Value.int(3), Value.int(1) };
    var instrs = intDivModTrace();
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // The four sign quadrants: truncating hardware vs Lua's floored results
    // differ in THREE of them — any adjust slip shows up as a regs mismatch.
    try expectMatch(&t, &.{ Value.int(0), Value.int(7), Value.int(3), Value.int(0), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(7), Value.int(-3), Value.int(0), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(-7), Value.int(3), Value.int(0), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(-7), Value.int(-3), Value.int(0), Value.int(0) });
    // Exact division (rem == 0) must NOT adjust, either sign.
    try expectMatch(&t, &.{ Value.int(0), Value.int(6), Value.int(-3), Value.int(0), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(-6), Value.int(3), Value.int(0), Value.int(0) });
    // minInt with an ordinary divisor (hardware-safe, floor still negative).
    const min = std.math.minInt(i64);
    try expectMatch(&t, &.{ Value.int(0), Value.int(min), Value.int(3), Value.int(0), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(min), Value.int(-3), Value.int(0), Value.int(0) });

    // Absolute pin for one floored quadrant (belt over the parity braces):
    // 7 % -3 == -2 and 7 // -3 == -3 per iteration; ×3 iterations.
    const gpa = testing.allocator;
    var iregs = [_]Value{ Value.int(0), Value.int(7), Value.int(-3), Value.int(0), Value.int(0) };
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValues(&t, &iregs, values);
    try testing.expectEqual(@as(usize, 3), iresult.completed);
    try testing.expectEqual(Value.int(-6), iregs[3]);
    try testing.expectEqual(Value.int(-9), iregs[4]);
}

test "doc 25: (minInt, -1) is computed INLINE — native continues, no exit (codex blocker inversion)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(1), Value.int(1) }; // ONE iteration
    var instrs = intDivModTrace();
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    const min = std.math.minInt(i64);
    const regs_init = [_]Value{ Value.int(0), Value.int(min), Value.int(-1), Value.int(0), Value.int(0) };

    // Oracle: the pair is a DEFINED value (mod → 0, idiv → minInt) and the
    // iteration COMPLETES — the exit is the ordinary loop-condition guard on
    // the next header evaluation, not the divide.
    var iregs = regs_init;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValues(&t, &iregs, values);
    try testing.expectEqual(@as(usize, 1), iresult.completed);
    try testing.expectEqual(@as(u32, 4), iresult.exit_instr); // guard_true, NOT the mod/idiv
    try testing.expectEqual(Value.int(0), iregs[3]); // minInt % -1
    try testing.expectEqual(Value.int(min), iregs[4]); // minInt // -1 (wraps)

    // Native: identical — completed, exit instr, and both special results.
    var ct = nativegen.compile(gpa, &t, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = regs_init;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(@as(usize, 1), nresult.completed);
    try testing.expectEqual(@as(u32, 4), nresult.exit_instr);
    try util.expectRegsEqual(&iregs, &nregs);
}

/// regs: r0=i, r1=b (counts down THROUGH zero), r2=acc. `acc += 7 <op> b`,
/// `b -= 1` — the divisor hits 0 mid-run and the divide must side-exit AT
/// ITS OWN instruction (10) so tier-0 re-raises DivisionByZero from the same
/// snapshot tier-1a errors at.
fn divByZeroTrace(op: trace.IrOp) [19]I {
    return .{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: limit 10
        .{ .op = .lt, .a = 0, .b = 2 }, // 3
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: b
        .{ .op = .guard_int, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: acc
        .{ .op = .guard_int, .a = 7 }, // 8
        .{ .op = .konst, .aux = 1 }, // 9: dividend 7
        .{ .op = op, .a = 9, .b = 5, .ty = .int }, // 10: 7 <op> b
        .{ .op = .add, .a = 7, .b = 10 }, // 11
        .{ .op = .konst, .aux = 2 }, // 12: 1
        .{ .op = .sub, .a = 5, .b = 12 }, // 13: b - 1
        .{ .op = .add, .a = 0, .b = 12 }, // 14: i + 1
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .phi, .b = 13, .aux = 1 },
        .{ .op = .phi, .b = 14, .aux = 0 },
        .{ .op = .loop }, // 18
    };
}

test "doc 25: divisor reaches 0 mid-run — % and // side-exit at their own instruction, tier parity" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{ Value.int(10), Value.int(7), Value.int(1) };
    inline for (.{ trace.IrOp.mod, trace.IrOp.idiv }) |op| {
        var instrs = divByZeroTrace(op);
        var es = [_]u16{};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        // b = 3, 2, 1 commit; the 4th iteration divides by 0 → exit at 10.
        const regs_init = [_]Value{ Value.int(0), Value.int(3), Value.int(0) };

        var iregs = regs_init;
        const values = try gpa.alloc(Value, t.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValues(&t, &iregs, values);
        try testing.expectEqual(@as(usize, 3), iresult.completed);
        try testing.expectEqual(@as(u32, 10), iresult.exit_instr);

        var ct = nativegen.compile(gpa, &t, 0) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 3), nresult.completed);
        try testing.expectEqual(@as(u32, 10), nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
    }
}

test "doc 25: float % and // — kernel-callout parity incl. y == 0 → NaN CONTINUING natively" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // regs: r0=i, r1=fa (float), r2=fb (float), r3=facc (float).
    // facc += (fa % fb) + (fa // fb); fa += 0.5 — both float-lane ops in one
    // body, results accumulated so every iteration's bits matter.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: limit 4
        .{ .op = .lt, .a = 0, .b = 2 }, // 3
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: fa
        .{ .op = .guard_float, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: fb
        .{ .op = .guard_float, .a = 7 }, // 8
        .{ .op = .slot_load, .aux = 3 }, // 9: facc
        .{ .op = .guard_float, .a = 9 }, // 10
        .{ .op = .mod, .a = 5, .b = 7, .ty = .float }, // 11: fa % fb
        .{ .op = .idiv, .a = 5, .b = 7, .ty = .float }, // 12: fa // fb
        .{ .op = .add, .a = 11, .b = 12, .ty = .float }, // 13
        .{ .op = .add, .a = 9, .b = 13, .ty = .float }, // 14
        .{ .op = .konst, .aux = 1 }, // 15: 0.5
        .{ .op = .add, .a = 5, .b = 15, .ty = .float }, // 16: fa + 0.5
        .{ .op = .konst, .aux = 2 }, // 17: 1
        .{ .op = .add, .a = 0, .b = 17 }, // 18: i + 1
        .{ .op = .phi, .b = 14, .aux = 3 },
        .{ .op = .phi, .b = 16, .aux = 1 },
        .{ .op = .phi, .b = 18, .aux = 0 },
        .{ .op = .loop }, // 22
    };
    var consts = [_]Value{ Value.int(4), Value.float(0.5), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    try expectMatch(&t, &.{ Value.int(0), Value.float(7.5), Value.float(2.0), Value.float(0.0) });
    try expectMatch(&t, &.{ Value.int(0), Value.float(-7.5), Value.float(2.0), Value.float(0.0) });
    try expectMatch(&t, &.{ Value.int(0), Value.float(7.5), Value.float(-2.0), Value.float(0.0) });
    // y == 0: NaN through IEEE in the shared kernel — the loop RUNS TO ITS
    // LIMIT natively (completed == 4, no divide exit), facc NaN in both tiers.
    try expectMatch(&t, &.{ Value.int(0), Value.float(7.5), Value.float(0.0), Value.float(0.0) });
    // ±inf operands.
    try expectMatch(&t, &.{ Value.int(0), Value.float(std.math.inf(f64)), Value.float(2.0), Value.float(0.0) });
}

test "doc 25: mixed int/float promotion — int operand cvtsi2sd's into the kernel exactly as the oracle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // regs: r0=i (int, ALSO the mod dividend), r1=fb (float), r2=facc.
    // facc += i % fb — `arithResultType` stamps .float (one float operand);
    // the int side must promote via cvtsi2sd == toFloat == @floatFromInt.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: limit 5
        .{ .op = .lt, .a = 0, .b = 2 }, // 3
        .{ .op = .guard_true, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 1 }, // 5: fb
        .{ .op = .guard_float, .a = 5 }, // 6
        .{ .op = .slot_load, .aux = 2 }, // 7: facc
        .{ .op = .guard_float, .a = 7 }, // 8
        .{ .op = .mod, .a = 0, .b = 5, .ty = .float }, // 9: i % fb (mixed)
        .{ .op = .idiv, .a = 0, .b = 5, .ty = .float }, // 10: i // fb (mixed)
        .{ .op = .add, .a = 9, .b = 10, .ty = .float }, // 11
        .{ .op = .add, .a = 7, .b = 11, .ty = .float }, // 12
        .{ .op = .konst, .aux = 1 }, // 13: 1
        .{ .op = .add, .a = 0, .b = 13 }, // 14: i + 1
        .{ .op = .phi, .b = 12, .aux = 2 },
        .{ .op = .phi, .b = 14, .aux = 0 },
        .{ .op = .loop }, // 17
    };
    var consts = [_]Value{ Value.int(5), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{ Value.int(0), Value.float(2.5), Value.float(0.0) });
    try expectMatch(&t, &.{ Value.int(0), Value.float(-2.5), Value.float(0.0) });
}

test "doc 25: malformed ty stamps fail closed — .boolean stamp, and .float on two int operands" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // (a) A .boolean-stamped mod must NOT ride an implicit else-is-int arm.
    {
        var instrs = intDivModTrace();
        instrs[13].ty = .boolean;
        var consts = [_]Value{ Value.int(3), Value.int(1) };
        var es = [_]u16{};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
    // (b) A .float-stamped idiv on two PROVEN-INT operands is malformed (the
    // oracle computes int//int as an integer) → bail, never a divsd lowering.
    {
        var instrs = intDivModTrace();
        instrs[14].ty = .float;
        var consts = [_]Value{ Value.int(3), Value.int(1) };
        var es = [_]u16{};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
}

test "doc 25: int divide + float-kernel callout + spill pressure — div_save owns a unique slot past the callout area" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    // Slots: r0=i, r1..r12=int accs (carried), r13=a, r14=b (invariant int),
    // r15=facc (carried float), r16=fb (invariant float), r17=limit. 18 slots
    // >> 9 GP homes, so int homes spill; the body holds an int `//` + `%`
    // pair (div_save round-trips) AND a float `%` (full callout save/restore)
    // in the same iteration — the codex non-overlap proof: a div_save aliasing
    // a spilled operand or the callout region would corrupt this loop.
    const N = 12;
    var ins: std.ArrayListUnmanaged(I) = .empty;
    defer ins.deinit(gpa);

    const r_i: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 0 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_i });
    const r_lim: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 17 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_lim });
    const r_lt: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .lt, .a = r_i, .b = r_lim });
    try ins.append(gpa, .{ .op = .guard_true, .a = r_lt });
    const r_a: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 13 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_a });
    const r_b: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 14 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_b });
    const r_facc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 15 });
    try ins.append(gpa, .{ .op = .guard_float, .a = r_facc });
    const r_fb: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 16 });
    try ins.append(gpa, .{ .op = .guard_float, .a = r_fb });

    var accrefs: [N]u16 = undefined;
    for (0..N) |k| {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .slot_load, .aux = @intCast(1 + k) });
        try ins.append(gpa, .{ .op = .guard_int, .a = r });
        accrefs[k] = r;
    }
    const r_q: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .idiv, .a = r_a, .b = r_b, .ty = .int });
    const r_m: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .mod, .a = r_a, .b = r_b, .ty = .int });
    var newrefs: [N]u16 = undefined;
    for (0..N) |k| {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .add, .a = accrefs[k], .b = if (k % 2 == 0) r_q else r_m });
        newrefs[k] = r;
    }
    const r_fm: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .mod, .a = r_facc, .b = r_fb, .ty = .float });
    const r_one: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .konst, .aux = 0 });
    const r_inc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .add, .a = r_i, .b = r_one });
    for (0..N) |k| try ins.append(gpa, .{ .op = .phi, .b = newrefs[k], .aux = @intCast(1 + k) });
    try ins.append(gpa, .{ .op = .phi, .b = r_fm, .aux = 15 });
    try ins.append(gpa, .{ .op = .phi, .b = r_inc, .aux = 0 });
    try ins.append(gpa, .{ .op = .loop });

    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = ins.items, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Structural proof: div_save exists, is a real spill slot, and sits
    // wholly PAST the callout save region (never its padding slot).
    {
        const kinds = try gpa.alloc(Kind, ins.items.len);
        defer gpa.free(kinds);
        const slot_of = try gpa.alloc(i32, ins.items.len);
        defer gpa.free(slot_of);
        try testing.expect(proveKinds(gpa, &t, kinds, slot_of));
        var al = analyze(gpa, &t, kinds, slot_of) orelse return error.AnalyzeBailed;
        defer al.deinit(gpa);
        const ds = al.div_save orelse return error.DivSaveMissing;
        try testing.expect(al.callout_save_count != 0); // the float mod IS a callout
        try testing.expect(ds > al.callout_save_base + al.callout_save_count); // past area + padding
        try testing.expect(ds < al.spill_count); // inside the frame
    }

    // Behavioural proof: full tier parity. a=17, b=5 → q=3, m=2 per iter.
    var regs: [18]Value = undefined;
    for (&regs) |*v| v.* = Value.int(0);
    regs[13] = Value.int(17);
    regs[14] = Value.int(5);
    regs[15] = Value.float(123.456);
    regs[16] = Value.float(7.25);
    regs[17] = Value.int(5);
    try expectMatch(&t, &regs);
    // Negative operand pressure leg: floored adjusts live in the same body.
    regs[13] = Value.int(-17);
    try expectMatch(&t, &regs);
}

// --- doc 26: string.upper/lower (supper/slower) + string.codepoint (scp) ----

/// The doc-26 case-producer shape: `u = upper(s); l = lower(u);
/// acc = acc + #u + #l; i += 1; while i < limit`. regs: r0=i, r1=limit,
/// r2=acc, r3=s (observed string → guard_string, prologue-pinned natively).
/// Exercises the FULL Unicode cores (Z-6 — never an ASCII special case),
/// proven-string chaining (slower.a and both slen.a are producer results),
/// and the budget bound A=2 (one link per case producer).
fn caseUpperLowerTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .slot_load, .aux = 3 }, // 6: s
            .{ .op = .guard_string, .a = 6 }, // 7
            .{ .op = .guard_gc, .aux = 2 }, // 8: budget, A = 2
            .{ .op = .supper, .a = 6, .ty = .heap }, // 9: upper(s)
            .{ .op = .slower, .a = 9, .ty = .heap }, // 10: lower(upper(s)) — proven chain
            .{ .op = .slen, .a = 9, .ty = .int }, // 11: #u
            .{ .op = .slen, .a = 10, .ty = .int }, // 12: #l
            .{ .op = .slot_load, .aux = 2 }, // 13: acc
            .{ .op = .guard_int, .a = 13 }, // 14
            .{ .op = .add, .a = 13, .b = 11 }, // 15
            .{ .op = .add, .a = 15, .b = 12 }, // 16
            .{ .op = .konst, .aux = 0 }, // 17: 1
            .{ .op = .add, .a = 0, .b = 17 }, // 18: i + 1
            .{ .op = .phi, .b = 16, .aux = 2 },
            .{ .op = .phi, .b = 18, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 26: supper + slower on a guard_string-pinned slot — tier parity, full Unicode mapping, same allocation count" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{Value.int(1)};
    const t = caseUpperLowerTrace(&consts);

    // A mixed-case, mixed-width subject: ASCII + Latin-1 supplement + Greek.
    // Both directions of the Unicode table are exercised in ONE body (upper
    // then lower), and the cp count (9) differs from the byte count (13), so
    // a byte-level shortcut would diverge from the shared cores immediately.
    const subject = "héLlo Αβγ"; // 9 cps
    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const isubj = try iheap.intern(subject);
    // i = 1..4 commit; acc = 4 iterations x (9 + 9) = 72.
    const regs_init_i = [_]Value{ Value.int(1), Value.int(5), Value.int(0), Value.heap(&isubj.header) };
    const iobjs_before = iheap.object_count;
    var iregs = regs_init_i;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
    try testing.expectEqual(@as(usize, 4), iresult.completed);
    try testing.expectEqual(Value.int(72).payload.bits, iregs[2].payload.bits);
    // The REAL Unicode mappings ran: é→É and Α→Α / β→Β / γ→Γ (Greek), then
    // the round-trip all-lower form — never an ASCII-only mapping.
    try testing.expect(iheap.internedLookup("HÉLLO ΑΒΓ") != null);
    try testing.expect(iheap.internedLookup("héllo αβγ") != null);
    const iallocs = iheap.object_count - iobjs_before;
    try testing.expect(iallocs > 0);

    // Native: fresh heap + its own copy of the subject, same trace.
    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    const nsubj = try nheap.intern(subject);
    const regs_init_n = [_]Value{ Value.int(1), Value.int(5), Value.int(0), Value.heap(&nsubj.header) };
    const nobjs_before = nheap.object_count;
    var ct = nativegen.compileWithHeap(gpa, &t, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = regs_init_n;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try testing.expectEqual(iregs[0].payload.bits, nregs[0].payload.bits);
    try testing.expectEqual(iregs[2].payload.bits, nregs[2].payload.bits);
    try testing.expectEqual(@intFromPtr(&nsubj.header), nregs[3].payload.bits);
    // Same allocation count — the doc 24 D2 id-stream claim, now for the case
    // producers.
    try testing.expectEqual(iallocs, nheap.object_count - nobjs_before);
    try testing.expect(nheap.internedLookup("HÉLLO ΑΒΓ") != null);
    try testing.expect(nheap.internedLookup("héllo αβγ") != null);

    // Re-running against the SAME heap re-interns nothing (pure cores +
    // intern hits): committed count identical, object_count unchanged.
    const objs_mid = nheap.object_count;
    var rregs = regs_init_n;
    const rresult = try util.runNative(ct, &rregs);
    try testing.expectEqual(iresult.completed, rresult.completed);
    try testing.expectEqual(objs_mid, nheap.object_count);

    // Fail closed with NO heap: the case producers allocate, so the compiler
    // declines the trace without one (the doc-24 D5 posture).
    {
        var arena = McodeArena.init(gpa);
        defer arena.deinit();
        try testing.expect(compileInto(gpa, &arena, &t, 0, null, null) == null);
    }
}

/// The doc-26 scp shape: `acc = acc + codepoint(s, i, i); i += 1; while
/// i < limit` — the single-codepoint sliding read. regs: r0=i, r1=limit,
/// r2=acc, r3=s. The 2-arg source form makes b and aux the SAME ref (j
/// defaults to runtime i — recBSCodepoint shares the ref), which this trace
/// mirrors: instr 9's b == aux == 0.
fn scpSlideTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .slot_load, .aux = 3 }, // 6: s
            .{ .op = .guard_string, .a = 6 }, // 7
            .{ .op = .slot_load, .aux = 2 }, // 8: acc
            .{ .op = .scp, .a = 6, .b = 0, .aux = 0, .ty = .int }, // 9: codepoint(s, i, i) — b == aux
            .{ .op = .guard_int, .a = 8 }, // 10
            .{ .op = .add, .a = 8, .b = 9 }, // 11
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

test "doc 26: scp — tier parity, U+0000 as a REAL result, empty-range side-exit, zero allocations, and no heap required" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var consts = [_]Value{Value.int(1)};
    const t = scpSlideTrace(&consts);

    // Subject "a\x00é": U+0000 is a real, in-range scalar whose scp result (0)
    // must flow as an ordinary int — only the −1 sentinel may exit (minor
    // review note 2: full 64-bit signed compare, no result aliasing). The
    // trailing é keeps the read cp-indexed (2 bytes, 1 cp).
    const subject = "a\x00é";
    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const isubj = try iheap.intern(subject);
    // limit = 100 forces the EXIT to come from scp itself: i = 1..3 commit
    // (97 + 0 + 233), i = 4 is past cp_len → codepointCore → null → −1 →
    // side-exit at instr 9 in both tiers. acc = 330.
    const regs_init_i = [_]Value{ Value.int(1), Value.int(100), Value.int(0), Value.heap(&isubj.header) };
    const iobjs_before = iheap.object_count;
    var iregs = regs_init_i;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &t, &iregs, values);
    try testing.expectEqual(@as(usize, 3), iresult.completed);
    try testing.expectEqual(@as(u32, 9), iresult.exit_instr);
    try testing.expectEqual(Value.int(330).payload.bits, iregs[2].payload.bits);
    // The one non-allocating stralloc shim: NOTHING was interned or linked.
    try testing.expectEqual(iobjs_before, iheap.object_count);

    // Native — WITHOUT a heap: scp is non-allocating, so unlike every other
    // stralloc op the trace must compile with heap == null (nothing to bake).
    var ct = nativegen.compile(gpa, &t, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    // The native subject must be the SAME interned string as the oracle's —
    // scp reads through the pointer, no heap identity involved.
    var nregs = regs_init_i;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
    try util.expectRegsEqual(&iregs, &nregs);
    try testing.expectEqual(iobjs_before, iheap.object_count);
}

test "doc 26 (review M5): malformed result-ty stamps fail closed — new ops AND the retrofitted snew arms" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();

    // (a) supper stamped .int instead of .heap: refuse to compile.
    {
        var consts = [_]Value{Value.int(1)};
        const t = caseUpperLowerTrace(&consts);
        const saved = t.instrs[9].ty;
        t.instrs[9].ty = .int;
        defer t.instrs[9].ty = saved;
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (b) scp stamped .heap instead of .int: refuse to compile.
    {
        var consts = [_]Value{Value.int(1)};
        const t = scpSlideTrace(&consts);
        const saved = t.instrs[9].ty;
        t.instrs[9].ty = .heap;
        defer t.instrs[9].ty = saved;
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (c) The RETROFIT is live on the pre-existing arms too: an ssub stamped
    // .int (instr 11 of the c3 flagship trace) now also refuses — before doc
    // 26 this compiled on the stamp's word alone.
    {
        var consts = [_]Value{ Value.int(2), Value.int(1) };
        const t = snewSubRevTrace(&consts);
        const saved = t.instrs[11].ty;
        t.instrs[11].ty = .int;
        defer t.instrs[11].ty = saved;
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (d) Control: the same three traces with honest stamps all compile (the
    // checks above failed for the STAMP, not for some unrelated reason).
    {
        var consts_c = [_]Value{Value.int(1)};
        const tc = caseUpperLowerTrace(&consts_c);
        var c1 = nativegen.compileWithHeap(gpa, &tc, 0, &heap) orelse return error.NativeBailedUnexpectedly;
        c1.deinit();
        const ts = scpSlideTrace(&consts_c);
        var c2 = nativegen.compileWithHeap(gpa, &ts, 0, &heap) orelse return error.NativeBailedUnexpectedly;
        c2.deinit();
        var consts_s = [_]Value{ Value.int(2), Value.int(1) };
        const tv = snewSubRevTrace(&consts_s);
        var c3 = nativegen.compileWithHeap(gpa, &tv, 0, &heap) orelse return error.NativeBailedUnexpectedly;
        c3.deinit();
    }
}

// ---------------------------------------------------------------------------
// Doc 30 c3 — the pattern/str2num callout class, native lowering.
// ---------------------------------------------------------------------------

/// The doc-30 smatch flagship: `st, en = locate(s, "%d+", pos); acc += st;
/// pos = en + 1` — find/match's guarded-callout shape with both char-index
/// projections live. regs: r0=pos, r1=acc, r2=s. The pattern is a HEAP KONST
/// (instr 6) — the first native trace to materialize a string konst as a
/// first-class `.heap` value (baked pointer bits).
fn smatchSlideTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: pos
            .{ .op = .slot_load, .aux = 1 }, // 1: acc
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .slot_load, .aux = 2 }, // 4: s
            .{ .op = .guard_string, .a = 4 }, // 5
            .{ .op = .konst, .aux = 1 }, // 6: the pattern (heap konst)
            .{ .op = .smatch, .a = 4, .b = 0, .aux = 6, .ty = .int }, // 7: status; no_match → exit
            .{ .op = .scap_int, .a = 7, .b = 0, .ty = .int }, // 8: slot_start (1-based char)
            .{ .op = .scap_int, .a = 7, .b = 1, .ty = .int }, // 9: slot_end
            .{ .op = .add, .a = 1, .b = 8 }, // 10: acc + start
            .{ .op = .konst, .aux = 0 }, // 11: 1
            .{ .op = .add, .a = 9, .b = 11 }, // 12: end + 1
            .{ .op = .phi, .b = 10, .aux = 1 },
            .{ .op = .phi, .b = 12, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 30 c3: smatch + scap_int — tier parity, char-index projections, no_match exit, zero allocations" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // "a1b22c333" with %d+: matches at char spans (2,2), (4,5), (7,9); the
    // 4th probe (pos=10, one past the end) is no_match → side-exit at the
    // smatch. acc = 2+4+7 = 13; pos ends at 10.
    const subject = "a1b22c333";
    const patsrc = "%d+";

    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const isubj = try iheap.intern(subject);
    const ipat = try iheap.intern(patsrc);
    var iconsts = [_]Value{ Value.int(1), Value.heap(&ipat.header) };
    const ti = smatchSlideTrace(&iconsts);
    const regs_init_i = [_]Value{ Value.int(1), Value.int(0), Value.heap(&isubj.header) };
    const iobjs_before = iheap.object_count;
    var iregs = regs_init_i;
    const values = try gpa.alloc(Value, ti.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &ti, &iregs, values);
    try testing.expectEqual(@as(usize, 3), iresult.completed);
    try testing.expectEqual(@as(u32, 7), iresult.exit_instr);
    try testing.expectEqual(Value.int(13).payload.bits, iregs[1].payload.bits);
    try testing.expectEqual(Value.int(10).payload.bits, iregs[0].payload.bits);
    // The matcher + int projections allocate NOTHING.
    try testing.expectEqual(iobjs_before, iheap.object_count);

    // Native: fresh heap, own interned copies, same instrs.
    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    const nsubj = try nheap.intern(subject);
    const npat = try nheap.intern(patsrc);
    var nconsts = [_]Value{ Value.int(1), Value.heap(&npat.header) };
    const tn = smatchSlideTrace(&nconsts);
    const nobjs_before = nheap.object_count;
    var ct = nativegen.compileWithHeap(gpa, &tn, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = [_]Value{ Value.int(1), Value.int(0), Value.heap(&nsubj.header) };
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
    try testing.expectEqual(iregs[0].payload.bits, nregs[0].payload.bits);
    try testing.expectEqual(iregs[1].payload.bits, nregs[1].payload.bits);
    try testing.expectEqual(nobjs_before, nheap.object_count);

    // Fail closed with NO heap: smatch bakes/fills `match_scratch`, so the
    // compiler declines the trace without one (unlike sfindp below).
    {
        var arena = McodeArena.init(gpa);
        defer arena.deinit();
        try testing.expect(compileInto(gpa, &arena, &tn, 0, null, null) == null);
    }
}

/// The doc-30 sfindp shape: `idx = plainfind(s, "ab", pos); acc += idx;
/// pos = idx + 1` — heap-free, like scp.
fn sfindpSlideTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: pos
            .{ .op = .slot_load, .aux = 1 }, // 1: acc
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .slot_load, .aux = 2 }, // 4: s
            .{ .op = .guard_string, .a = 4 }, // 5
            .{ .op = .konst, .aux = 1 }, // 6: the needle (heap konst)
            .{ .op = .sfindp, .a = 4, .b = 0, .aux = 6, .ty = .int }, // 7: idx ≥ 1; ≤ 0 → exit
            .{ .op = .add, .a = 1, .b = 7 }, // 8: acc + idx
            .{ .op = .konst, .aux = 0 }, // 9: 1
            .{ .op = .add, .a = 7, .b = 9 }, // 10: idx + 1
            .{ .op = .phi, .b = 8, .aux = 1 },
            .{ .op = .phi, .b = 10, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 30 c3: sfindp — tier parity, heap-FREE compile, no_match exit" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // "xabyabzab" needles at char indices 2, 5, 8; the 4th probe (pos=9)
    // finds nothing → no_match (negative) → side-exit. acc = 15, pos = 9.
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const subj = try heap.intern("xabyabzab");
    const pat = try heap.intern("ab");
    var consts = [_]Value{ Value.int(1), Value.heap(&pat.header) };
    const t = sfindpSlideTrace(&consts);
    const regs_init = [_]Value{ Value.int(1), Value.int(0), Value.heap(&subj.header) };
    const objs_before = heap.object_count;

    var iregs = regs_init;
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = null }, &t, &iregs, values);
    try testing.expectEqual(@as(usize, 3), iresult.completed);
    try testing.expectEqual(@as(u32, 7), iresult.exit_instr);
    try testing.expectEqual(Value.int(15).payload.bits, iregs[1].payload.bits);
    try testing.expectEqual(Value.int(9).payload.bits, iregs[0].payload.bits);

    // Native WITHOUT a heap: sfindp is the heap-free member of the class (the
    // scp precedent) — the trace must compile with heap == null; the string
    // konst is a baked pointer, no heap involved.
    var ct = nativegen.compile(gpa, &t, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = regs_init;
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
    try util.expectRegsEqual(&iregs, &nregs);
    try testing.expectEqual(objs_before, heap.object_count);
}

/// Build a gmatch iterator state table (the c1 layout: [1]=subject,
/// [2]=pattern, [3]=byte pos — an in-lane `.value` int cell).
fn gmatchStateTable(heap: *gc.Heap, subj: *object.GcHeader, pat: *object.GcHeader, pos: i64) !*table.Table {
    const t = try heap.newTable();
    try t.set(testing.allocator, Value.int(1), Value.heap(subj));
    try t.set(testing.allocator, Value.int(2), Value.heap(pat));
    try t.set(testing.allocator, Value.int(3), Value.int(pos));
    return t;
}

/// The doc-30 gmatch composite: `w = step(state); acc += next_pos;
/// commit(state, next_pos)` — sgmatch + scap_str (the produced match string,
/// slot_whole) + scap_int (next_pos) + the DEFERRED sgm_setpos below every
/// guard. regs: r0=state, r1=acc. The expected pattern is consts[1], named by
/// sgmatch's aux as a konst-pool ID (an immediate, baked at emission).
fn gmatchStepTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: state
            .{ .op = .guard_table, .a = 0 }, // 1: invariant table pin → .ptr
            .{ .op = .slot_load, .aux = 1 }, // 2: acc
            .{ .op = .guard_int, .a = 2 }, // 3
            .{ .op = .sgmatch, .a = 0, .aux = 1, .ty = .int }, // 4: status; exhausted → exit
            .{ .op = .scap_str, .a = 4, .b = 2, .ty = .heap }, // 5: the whole-match string (slot_whole)
            .{ .op = .scap_int, .a = 4, .b = 35, .ty = .int }, // 6: next_pos (slot 35)
            .{ .op = .sgm_setpos, .a = 0, .b = 6 }, // 7: the deferred cursor commit
            .{ .op = .add, .a = 2, .b = 6 }, // 8: acc + next_pos
            .{ .op = .phi, .b = 8, .aux = 1 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 30 c3: sgmatch + scap_str + sgm_setpos — tier parity, cursor commit, allocation parity, exhaustion exit" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // "ab cd ef" with %a+: three steps ("ab" np=2, "cd" np=5, "ef" np=8),
    // then exhaustion → side-exit at the sgmatch. acc = 2+5+8 = 15; the
    // state's pos cell ends at 8 (committed by the LAST completed
    // iteration's sgm_setpos — the failing step commits nothing).
    const subject = "ab cd ef";
    const patsrc = "%a+";

    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const isubj = try iheap.intern(subject);
    const ipat = try iheap.intern(patsrc);
    const istate = try gmatchStateTable(&iheap, &isubj.header, &ipat.header, 0);
    var iconsts = [_]Value{ Value.int(1), Value.heap(&ipat.header) };
    const ti = gmatchStepTrace(&iconsts);
    const iobjs_before = iheap.object_count;
    var iregs = [_]Value{ Value.heap(&istate.header), Value.int(0) };
    const values = try gpa.alloc(Value, ti.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &ti, &iregs, values);
    try testing.expectEqual(@as(usize, 3), iresult.completed);
    try testing.expectEqual(@as(u32, 4), iresult.exit_instr);
    try testing.expectEqual(Value.int(15).payload.bits, iregs[1].payload.bits);
    try testing.expectEqual(@as(i64, 8), istate.inLaneValueIntCell(3).?);
    const iallocs = iheap.object_count - iobjs_before;
    // The three whole-match strings were interned (B02: scap_str executes).
    try testing.expect(iheap.internedLookup("cd") != null);
    try testing.expect(iallocs > 0);

    // Native: fresh heap, own state.
    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    const nsubj = try nheap.intern(subject);
    const npat = try nheap.intern(patsrc);
    const nstate = try gmatchStateTable(&nheap, &nsubj.header, &npat.header, 0);
    var nconsts = [_]Value{ Value.int(1), Value.heap(&npat.header) };
    const tn = gmatchStepTrace(&nconsts);
    const nobjs_before = nheap.object_count;
    var ct = nativegen.compileWithHeap(gpa, &tn, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = [_]Value{ Value.heap(&nstate.header), Value.int(0) };
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
    try testing.expectEqual(iregs[1].payload.bits, nregs[1].payload.bits);
    try testing.expectEqual(@as(i64, 8), nstate.inLaneValueIntCell(3).?);
    // Same allocation count — the D2 id-stream claim for the gmatch step.
    try testing.expectEqual(iallocs, nheap.object_count - nobjs_before);
    try testing.expect(nheap.internedLookup("cd") != null);
}

/// The doc-30 guard_sid shape: a counted loop whose body identity-pins a
/// string slot against a konst-pool string. regs: r0=i, r1=limit, r2=s.
fn guardSidTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .slot_load, .aux = 2 }, // 6: s
            .{ .op = .guard_string, .a = 6 }, // 7: prologue TYPE pin
            .{ .op = .guard_sid, .a = 6, .aux = 1 }, // 8: body IDENTITY pin
            .{ .op = .konst, .aux = 0 }, // 9: 1
            .{ .op = .add, .a = 0, .b = 9 }, // 10
            .{ .op = .phi, .b = 10, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 30 c3: guard_sid — identity pass loops, identity mismatch exits at the guard, tier parity" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const expected = try heap.intern("%d+");
    const other = try heap.intern("%a+"); // same TYPE, different identity
    var consts = [_]Value{ Value.int(1), Value.heap(&expected.header) };
    const t = guardSidTrace(&consts);
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);

    // Heap-free like sfindp: the pin is a baked pointer compare.
    var ct = nativegen.compile(gpa, &t, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();

    // (a) Identity HOLDS: the loop runs to its counter exit (guard_true).
    {
        const regs_init = [_]Value{ Value.int(1), Value.int(4), Value.heap(&expected.header) };
        var iregs = regs_init;
        const iresult = irinterp.executeValuesCtx(.{ .heap = null }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 3), iresult.completed);
        try testing.expectEqual(@as(u32, 5), iresult.exit_instr);
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
    }
    // (b) Identity BROKEN (a different interned string — the type pin still
    // passes): exit at the guard_sid, zero committed, both tiers.
    {
        const regs_init = [_]Value{ Value.int(1), Value.int(4), Value.heap(&other.header) };
        var iregs = regs_init;
        const iresult = irinterp.executeValuesCtx(.{ .heap = null }, &t, &iregs, values);
        try testing.expectEqual(@as(usize, 0), iresult.completed);
        try testing.expectEqual(@as(u32, 8), iresult.exit_instr);
        var nregs = regs_init;
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
    }
}

/// The doc-30 str2num shape: a counted loop parsing a string slot each
/// iteration. regs: r0=i, r1=limit, r2=s, r3=acc. `int_kind` picks the
/// baked observed kind (str2num_i + int acc vs str2num_f + float acc).
fn str2numTrace(consts: []Value, comptime int_kind: bool) Trace {
    const instrs = struct {
        var arr_i = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .slot_load, .aux = 1 }, // 1: limit
            .{ .op = .guard_int, .a = 0 }, // 2
            .{ .op = .guard_int, .a = 1 }, // 3
            .{ .op = .lt, .a = 0, .b = 1 }, // 4
            .{ .op = .guard_true, .a = 4 }, // 5
            .{ .op = .slot_load, .aux = 2 }, // 6: s
            .{ .op = .guard_string, .a = 6 }, // 7
            .{ .op = .slot_load, .aux = 3 }, // 8: acc
            .{ .op = .guard_int, .a = 8 }, // 9
            .{ .op = .str2num_i, .a = 6, .ty = .int }, // 10: parse; kind mismatch → exit
            .{ .op = .add, .a = 8, .b = 10 }, // 11
            .{ .op = .konst, .aux = 0 }, // 12: 1
            .{ .op = .add, .a = 0, .b = 12 }, // 13
            .{ .op = .phi, .b = 11, .aux = 3 },
            .{ .op = .phi, .b = 13, .aux = 0 },
            .{ .op = .loop },
        };
        var arr_f = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .slot_load, .aux = 1 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .guard_int, .a = 1 },
            .{ .op = .lt, .a = 0, .b = 1 },
            .{ .op = .guard_true, .a = 4 },
            .{ .op = .slot_load, .aux = 2 },
            .{ .op = .guard_string, .a = 6 },
            .{ .op = .slot_load, .aux = 3 }, // 8: acc (float)
            .{ .op = .guard_float, .a = 8 },
            .{ .op = .str2num_f, .a = 6, .ty = .float }, // 10
            .{ .op = .add, .a = 8, .b = 10, .ty = .float }, // 11
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 12 },
            .{ .op = .phi, .b = 11, .aux = 3 },
            .{ .op = .phi, .b = 13, .aux = 0 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = if (int_kind) &instrs.arr_i else &instrs.arr_f, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 30 c3: str2num_i/_f — tier parity, heap-free, and the kind-mismatch / non-number exits" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const s_int = try heap.intern("42");
    const s_float = try heap.intern("4.5");
    const s_junk = try heap.intern("zz");
    var consts = [_]Value{Value.int(1)};

    const t_i = str2numTrace(&consts, true);
    const t_f = str2numTrace(&consts, false);
    const values = try gpa.alloc(Value, t_i.instrs.len);
    defer gpa.free(values);

    // Heap-free: the ONE arith.toNumber core allocates nothing.
    var ct_i = nativegen.compile(gpa, &t_i, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct_i.deinit();
    var ct_f = nativegen.compile(gpa, &t_f, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct_f.deinit();

    const Case = struct { s: Value, int_kind: bool, completed: usize, exit: u32, acc: Value };
    const cases = [_]Case{
        // Observed kind holds: 3 iterations, counter exit (guard_true, instr 5).
        .{ .s = Value.heap(&s_int.header), .int_kind = true, .completed = 3, .exit = 5, .acc = Value.int(126) },
        .{ .s = Value.heap(&s_float.header), .int_kind = false, .completed = 3, .exit = 5, .acc = Value.float(13.5) },
        // Kind mismatch (a float parse under an int stamp, and vice versa):
        // exit at the parse (instr 10), zero committed, acc untouched.
        .{ .s = Value.heap(&s_float.header), .int_kind = true, .completed = 0, .exit = 10, .acc = Value.int(0) },
        .{ .s = Value.heap(&s_int.header), .int_kind = false, .completed = 0, .exit = 10, .acc = Value.float(0.0) },
        // Not a number at all: same exit, both stamps.
        .{ .s = Value.heap(&s_junk.header), .int_kind = true, .completed = 0, .exit = 10, .acc = Value.int(0) },
        .{ .s = Value.heap(&s_junk.header), .int_kind = false, .completed = 0, .exit = 10, .acc = Value.float(0.0) },
    };
    for (cases) |c| {
        const t = if (c.int_kind) t_i else t_f;
        const regs_init = [_]Value{ Value.int(1), Value.int(4), c.s, c.acc };
        var iregs = regs_init;
        const iresult = irinterp.executeValuesCtx(.{ .heap = null }, &t, &iregs, values);
        try testing.expectEqual(c.completed, iresult.completed);
        try testing.expectEqual(c.exit, iresult.exit_instr);
        var nregs = regs_init;
        const nresult = try util.runNative(if (c.int_kind) ct_i else ct_f, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try util.expectRegsEqual(&iregs, &nregs);
    }
    // The successful int case really summed: 3 x 42 on top of 0.
    {
        const regs_init = [_]Value{ Value.int(1), Value.int(4), Value.heap(&s_int.header), Value.int(0) };
        var nregs = regs_init;
        _ = try util.runNative(ct_i, &nregs);
        try testing.expectEqual(Value.int(126).payload.bits, nregs[3].payload.bits);
        try testing.expectEqual(Value.int(4).payload.bits, nregs[0].payload.bits);
    }
}

test "doc 30 c3: malformed stamps and layouts fail closed — the never-trust-the-IR matrix" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const pat = try heap.intern("%d+");

    // (a) smatch stamped .heap: refuse.
    {
        var consts = [_]Value{ Value.int(1), Value.heap(&pat.header) };
        const t = smatchSlideTrace(&consts);
        const saved = t.instrs[7].ty;
        t.instrs[7].ty = .heap;
        defer t.instrs[7].ty = saved;
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (b) scap_int slot out of bounds: refuse.
    {
        var consts = [_]Value{ Value.int(1), Value.heap(&pat.header) };
        const t = smatchSlideTrace(&consts);
        const saved = t.instrs[8].b;
        t.instrs[8].b = @intCast(gc.MatchScratch.n_slots);
        defer t.instrs[8].b = saved;
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (c) sgmatch whose aux names an INT konst (not a string): refuse.
    {
        var consts = [_]Value{ Value.int(1), Value.int(7) };
        const t = gmatchStepTrace(&consts);
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (d) guard_sid whose aux names an INT konst: refuse.
    {
        var consts = [_]Value{ Value.int(1), Value.int(7) };
        const t = guardSidTrace(&consts);
        try testing.expect(nativegen.compile(gpa, &t, 0) == null);
    }
    // (e) smatch whose pattern ref is a dominating INT (no string proof —
    // the is_string gate, not the bounds gate): refuse.
    {
        var consts = [_]Value{ Value.int(1), Value.heap(&pat.header) };
        const t = smatchSlideTrace(&consts);
        const saved = t.instrs[7].aux;
        t.instrs[7].aux = 0; // the pos slot_load — kind .int, never a string
        defer t.instrs[7].aux = saved;
        try testing.expect(nativegen.compileWithHeap(gpa, &t, 0, &heap) == null);
    }
    // (f) Control: the honest traces all compile (the refusals above were for
    // the STAMP, not some unrelated reason).
    {
        var consts = [_]Value{ Value.int(1), Value.heap(&pat.header) };
        const t1 = smatchSlideTrace(&consts);
        var c1 = nativegen.compileWithHeap(gpa, &t1, 0, &heap) orelse return error.NativeBailedUnexpectedly;
        c1.deinit();
        const t2 = guardSidTrace(&consts);
        var c2 = nativegen.compile(gpa, &t2, 0) orelse return error.NativeBailedUnexpectedly;
        c2.deinit();
    }
}

/// [doc 30 c4b] The RECORDED gmatch for-in shape: the loop variable `w` is a
/// carried STRING slot — guard_string-pinned at the load, consumed by `slen`,
/// then overwritten each iteration by the fresh `scap_str` whole-match. The
/// c4b classification arm admits it: the hoisted guard_string covers the
/// ENTRY value (iteration 1), `isStringProducerOp` proves iterations 2+, and
/// every flush re-boxes TAG_HEAP. regs: r0=state, r1=w (carried), r2=acc.
fn carriedStringTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: state
            .{ .op = .guard_table, .a = 0 }, // 1: invariant .ptr pin
            .{ .op = .slot_load, .aux = 1 }, // 2: w — the carried string
            .{ .op = .guard_string, .a = 2 }, // 3: entry pin (hoisted)
            .{ .op = .slen, .a = 2, .ty = .int }, // 4: #w
            .{ .op = .slot_load, .aux = 2 }, // 5: acc
            .{ .op = .guard_int, .a = 5 }, // 6
            .{ .op = .add, .a = 5, .b = 4 }, // 7: acc + #w
            .{ .op = .sgmatch, .a = 0, .aux = 1, .ty = .int }, // 8: next token; exhaustion → exit
            .{ .op = .scap_str, .a = 8, .b = 2, .ty = .heap }, // 9: whole match — the writeback producer
            .{ .op = .scap_int, .a = 8, .b = 35, .ty = .int }, // 10: next_pos
            .{ .op = .sgm_setpos, .a = 0, .b = 10 }, // 11: deferred cursor commit
            .{ .op = .phi, .b = 9, .aux = 1 }, // w ← scap_str
            .{ .op = .phi, .b = 7, .aux = 2 }, // acc
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

/// Same shape, but the φ writeback for `w` is the string-guarded slot_load
/// itself (`w ← w`) — kind `.heap`, yet NOT a static string PRODUCER. The
/// c4b arm must refuse it: only producer results are strings by construction
/// on iterations 2+ (a guard proves the value it guarded, not a writeback).
fn carriedStringBadWritebackTrace(consts: []Value) Trace {
    const instrs = struct {
        var arr = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: state
            .{ .op = .guard_table, .a = 0 }, // 1
            .{ .op = .slot_load, .aux = 1 }, // 2: w
            .{ .op = .guard_string, .a = 2 }, // 3
            .{ .op = .slen, .a = 2, .ty = .int }, // 4
            .{ .op = .slot_load, .aux = 2 }, // 5: acc
            .{ .op = .guard_int, .a = 5 }, // 6
            .{ .op = .add, .a = 5, .b = 4 }, // 7
            .{ .op = .sgmatch, .a = 0, .aux = 1, .ty = .int }, // 8
            .{ .op = .scap_str, .a = 8, .b = 2, .ty = .heap }, // 9 (produced, unused by the φ)
            .{ .op = .scap_int, .a = 8, .b = 35, .ty = .int }, // 10
            .{ .op = .sgm_setpos, .a = 0, .b = 10 }, // 11
            .{ .op = .phi, .b = 2, .aux = 1 }, // w ← w: NOT a producer
            .{ .op = .phi, .b = 7, .aux = 2 },
            .{ .op = .loop },
        };
    };
    const es = struct {
        var arr = [_]u16{};
    };
    return Trace{ .anchor = undefined, .instrs = &instrs.arr, .consts = consts, .entry_slots = &es.arr, .entry_guards = &.{} };
}

test "doc 30 c4b: carried-string slot — native compiles, runs, flushes TAG_HEAP; prologue pins the entry; non-producer writeback fails closed" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // "ab cd ef" with %a+ and w0 = "xx": three completed iterations
    // (slen(w0)=2 + slen("ab")=2 + slen("cd")=2 → acc=6), then iteration 4
    // consumes "ef" via slen but exits at the exhausted sgmatch BEFORE its φ
    // — flushed state is the LAST COMMITTED iteration's: acc=6, w="ef"
    // (iteration 3's scap_str), pos cell = 8.
    const subject = "ab cd ef";
    const patsrc = "%a+";

    // Tier-1a oracle.
    var iheap = gc.Heap.init(gpa);
    defer iheap.deinit();
    const isubj = try iheap.intern(subject);
    const ipat = try iheap.intern(patsrc);
    const iw0 = try iheap.intern("xx");
    const istate = try gmatchStateTable(&iheap, &isubj.header, &ipat.header, 0);
    var iconsts = [_]Value{ Value.int(1), Value.heap(&ipat.header) };
    const ti = carriedStringTrace(&iconsts);
    const iobjs_before = iheap.object_count;
    var iregs = [_]Value{ Value.heap(&istate.header), Value.heap(&iw0.header), Value.int(0) };
    const values = try gpa.alloc(Value, ti.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &ti, &iregs, values);
    try testing.expectEqual(@as(usize, 3), iresult.completed);
    try testing.expectEqual(@as(u32, 8), iresult.exit_instr);
    try testing.expectEqual(Value.int(6).payload.bits, iregs[2].payload.bits);
    try testing.expect(iregs[1].isHeap() and iregs[1].heapType() == .string);
    try testing.expectEqual(@intFromPtr(&iheap.internedLookup("ef").?.header), @intFromPtr(iregs[1].asHeap()));
    try testing.expectEqual(@as(i64, 8), istate.inLaneValueIntCell(3).?);
    const iallocs = iheap.object_count - iobjs_before;

    // Native leg — fresh heap, same shape; assert full parity plus the
    // TAG_HEAP flush of the carried string.
    var nheap = gc.Heap.init(gpa);
    defer nheap.deinit();
    const nsubj = try nheap.intern(subject);
    const npat = try nheap.intern(patsrc);
    const nw0 = try nheap.intern("xx");
    const nstate = try gmatchStateTable(&nheap, &nsubj.header, &npat.header, 0);
    var nconsts = [_]Value{ Value.int(1), Value.heap(&npat.header) };
    const tn = carriedStringTrace(&nconsts);
    const nobjs_before = nheap.object_count;
    var ct = nativegen.compileWithHeap(gpa, &tn, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = [_]Value{ Value.heap(&nstate.header), Value.heap(&nw0.header), Value.int(0) };
    const nresult = try util.runNative(ct, &nregs);
    try testing.expectEqual(iresult.completed, nresult.completed);
    try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
    try testing.expectEqual(iregs[2].payload.bits, nregs[2].payload.bits);
    try testing.expect(nregs[1].isHeap() and nregs[1].heapType() == .string);
    try testing.expectEqual(@intFromPtr(&nheap.internedLookup("ef").?.header), @intFromPtr(nregs[1].asHeap()));
    try testing.expectEqual(@as(i64, 8), nstate.inLaneValueIntCell(3).?);
    try testing.expectEqual(iallocs, nheap.object_count - nobjs_before);

    // Prologue pins the ENTRY value: an INT in the w slot fails the [RV-1]
    // TAG_HEAP tag lane; a TABLE passes the tag but fails the is_string
    // `header.type == string` pin. Both: completed 0, regs untouched.
    {
        const regs_init = [_]Value{ Value.heap(&nstate.header), Value.int(42), Value.int(0) };
        var xregs = regs_init;
        const xresult = try util.runNative(ct, &xregs);
        try testing.expectEqual(@as(usize, 0), xresult.completed);
        try testing.expectEqual(trace_exec.ExitReason.prologue_fail, xresult.exit_reason);
        try util.expectRegsEqual(&regs_init, &xregs);
    }
    {
        const tbl = try table.Table.create(gpa);
        defer tbl.destroy(gpa);
        const regs_init = [_]Value{ Value.heap(&nstate.header), Value.heap(&tbl.header), Value.int(0) };
        var xregs = regs_init;
        const xresult = try util.runNative(ct, &xregs);
        try testing.expectEqual(@as(usize, 0), xresult.completed);
        try testing.expectEqual(trace_exec.ExitReason.prologue_fail, xresult.exit_reason);
        try util.expectRegsEqual(&regs_init, &xregs);
    }

    // Fail closed: a `.heap` φ writeback that is NOT a static string producer
    // (`w ← w`, a guard-covered slot_load) is refused by the c4b arm.
    {
        var bconsts = [_]Value{ Value.int(1), Value.heap(&npat.header) };
        const tb = carriedStringBadWritebackTrace(&bconsts);
        var arena = McodeArena.init(gpa);
        defer arena.deinit();
        try testing.expect(compileInto(gpa, &arena, &tb, 0, null, &nheap) == null);
    }
}

const stralloc = @import("stralloc.zig");

test "doc 30 c5 (m02): post-sgmatch projection OOM — the deferred sgm_setpos left the cursor un-advanced, so replay yields the SAME token" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // Reference geometry for "ab cd ef" %a+ (byte spans and cursor):
    //   token 1 "ab" span (0,2), pos after commit 2
    //   token 2 "cd" span (3,2), pos after commit 5
    //   token 3 "ef" span (6,2), pos after commit 8
    const subject = "ab cd ef";
    const patsrc = "%a+";
    const pos_after = [_]i64{ 0, 2, 5, 8 };
    const spans = [_][2]u64{ .{ 0, 2 }, .{ 3, 2 }, .{ 6, 2 } };

    // Self-calibrate the sweep: count allocations through setup and through a
    // clean full run, then sweep EVERY fail index in the run's own range —
    // this provably covers the per-iteration scap_str interns regardless of
    // how many allocations setup or the allocator internals cost. The
    // decisive legs are those where the OOM lands in a scap_str intern AFTER
    // >= 1 committed iteration (exit at instr 5 of gmatchStepTrace); require
    // at least one so the test cannot silently degrade into setup-only OOMs.
    var setup_allocs: usize = 0;
    var run_allocs_end: usize = 0;
    {
        var count = std.testing.FailingAllocator.init(gpa, .{});
        var cheap = gc.Heap.init(count.allocator());
        defer cheap.deinit();
        const cs = try cheap.intern(subject);
        const cp = try cheap.intern(patsrc);
        const cst = try gmatchStateTable(&cheap, &cs.header, &cp.header, 0);
        var cconsts = [_]Value{ Value.int(1), Value.heap(&cp.header) };
        const tc = gmatchStepTrace(&cconsts);
        setup_allocs = count.alloc_index;
        var cregs = [_]Value{ Value.heap(&cst.header), Value.int(0) };
        const cvalues = try gpa.alloc(Value, tc.instrs.len);
        defer gpa.free(cvalues);
        _ = irinterp.executeValuesCtx(.{ .heap = &cheap }, &tc, &cregs, cvalues);
        run_allocs_end = count.alloc_index;
    }
    try testing.expect(run_allocs_end > setup_allocs); // the run does intern

    var decisive: usize = 0;
    var fp: usize = setup_allocs;
    while (fp < run_allocs_end) : (fp += 1) {
        var ifail = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fp });
        var iheap = gc.Heap.init(ifail.allocator());
        defer iheap.deinit();
        const isubj = iheap.intern(subject) catch continue; // setup OOM: not a decisive leg
        const ipat = iheap.intern(patsrc) catch continue;
        const istate = gmatchStateTable(&iheap, &isubj.header, &ipat.header, 0) catch continue;
        var iconsts = [_]Value{ Value.int(1), Value.heap(&ipat.header) };
        const ti = gmatchStepTrace(&iconsts);
        var iregs = [_]Value{ Value.heap(&istate.header), Value.int(0) };
        const values = try gpa.alloc(Value, ti.instrs.len);
        defer gpa.free(values);
        const iresult = irinterp.executeValuesCtx(.{ .heap = &iheap }, &ti, &iregs, values);

        // Native leg with the SAME fail point: identical observable outcome
        // (D2 id-stream — both tiers run the same shared cores in the same
        // order against the heap's gpa).
        var nfail = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fp });
        var nheap = gc.Heap.init(nfail.allocator());
        defer nheap.deinit();
        const nsubj = nheap.intern(subject) catch continue;
        const npat = nheap.intern(patsrc) catch continue;
        const nstate = gmatchStateTable(&nheap, &nsubj.header, &npat.header, 0) catch continue;
        var nconsts = [_]Value{ Value.int(1), Value.heap(&npat.header) };
        const tn = gmatchStepTrace(&nconsts);
        var ct = nativegen.compileWithHeap(gpa, &tn, 0, &nheap) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        var nregs = [_]Value{ Value.heap(&nstate.header), Value.int(0) };
        const nresult = try util.runNative(ct, &nregs);
        try testing.expectEqual(iresult.completed, nresult.completed);
        try testing.expectEqual(iresult.exit_instr, nresult.exit_instr);
        try testing.expectEqual(iregs[1].payload.bits, nregs[1].payload.bits);
        try testing.expectEqual(istate.inLaneValueIntCell(3).?, nstate.inLaneValueIntCell(3).?);

        if (iresult.exit_instr != 5 or iresult.completed == 0 or iresult.completed >= 3) continue;
        decisive += 1;
        const k = iresult.completed;

        // The DECISIVE m02 claims, on both heaps:
        // (1) the failing iteration's deferred sgm_setpos did NOT commit —
        //     the cursor still holds iteration k's value;
        // (2) re-running the gmatch step (the pure, non-allocating shim —
        //     exactly what tier-0's replay does through the iterator) yields
        //     token k+1 AGAIN: the same span the failed scap_str was
        //     projecting. No token is lost, none is skipped.
        try testing.expectEqual(pos_after[k], istate.inLaneValueIntCell(3).?);
        try testing.expectEqual(@as(i64, 0), stralloc.sgmatchRuntime(&iheap, &istate.header, &ipat.header));
        try testing.expectEqual(spans[k][0], iheap.match_scratch.words[2 * gc.MatchScratch.slot_whole]);
        try testing.expectEqual(spans[k][1], iheap.match_scratch.words[2 * gc.MatchScratch.slot_whole + 1]);
        try testing.expectEqual(@as(i64, 0), stralloc.sgmatchRuntime(&nheap, &nstate.header, &npat.header));
        try testing.expectEqual(spans[k][0], nheap.match_scratch.words[2 * gc.MatchScratch.slot_whole]);
        try testing.expectEqual(spans[k][1], nheap.match_scratch.words[2 * gc.MatchScratch.slot_whole + 1]);
    }
    try testing.expect(decisive >= 1);
}
