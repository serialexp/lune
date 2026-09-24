//! Tests for `nativegen.zig` — core.
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

const McodeArena = nativegen.McodeArena;
const NativeResult = nativegen.NativeResult;
const NativeResultLedgerLayout = nativegen.NativeResultLedgerLayout;
const compileInto = nativegen.compileInto;
const is_x64_linux = nativegen.is_x64_linux;
const mapExecutable = nativegen.mapExecutable;

const util = @import("nativegen_testutil.zig");
const expectMatch = util.expectMatch;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "nativegen B-3a: NativeResult silent ABI tail preserves every ledger offset" {
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_len"), @offsetOf(NativeResult, "ledger_len"));
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_cum"), @offsetOf(NativeResult, "ledger_cum"));
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_id"), @offsetOf(NativeResult, "ledger_id"));
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_exit"), @offsetOf(NativeResult, "ledger_exit"));
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_reason"), @offsetOf(NativeResult, "ledger_reason"));
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_kind"), @offsetOf(NativeResult, "ledger_kind"));
    try testing.expectEqual(@offsetOf(NativeResultLedgerLayout, "ledger_outcome"), @offsetOf(NativeResult, "ledger_outcome"));
    try testing.expectEqual(@sizeOf(NativeResultLedgerLayout), @offsetOf(NativeResult, "silent_active"));
}

test "nativegen doc 55 §2d: link, linked-loop-done, and deopt exits carry a data-switched silent check" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var arena = McodeArena.init(gpa);
    defer arena.deinit();

    var link_code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var link_proto = bytecode.Proto{ .code = &link_code, .name = "b3-link", .id = 501 };
    var link_instrs = [_]I{.{ .op = .link, .aux = 0 }};
    var link_trace = Trace{ .anchor = .{ .proto = &link_proto, .pc = 0 }, .instrs = &link_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var link_ct = compileInto(gpa, &arena, &link_trace, 501, null, null) orelse return error.NativeBailedUnexpectedly;
    defer link_ct.deinit();
    var saw_link = false;
    for (link_ct.silent_sites) |p| if (p.kind == .link_terminal) {
        saw_link = true;
        try util.expectSilentCheck(&link_ct, p);
        try testing.expectEqual(@as(usize, 0), p.metadata_cell.*);
    };
    try testing.expect(saw_link);
    var no_tags = [_]u8{};
    var no_payloads = [_]u64{};
    const unpromoted = link_ct.run(RegWindow.of(&no_tags, &no_payloads));
    try testing.expectEqual(@as(u64, 0), unpromoted.silent_active);
    try testing.expectEqual(@as(u64, 0), unpromoted.silent_transitions);
    try testing.expectEqual(@as(u64, 0), unpromoted.silent_cell);
    try testing.expectEqual(@as(u64, 0), unpromoted.silent_cum);

    var loop_code = [_]bytecode.Instr{ bytecode.Instr.op0(.halt), bytecode.Instr.opAx(.for_loop, 0, 0), bytecode.Instr.op0(.halt) };
    var loop_proto = bytecode.Proto{ .code = &loop_code, .name = "b3-loopdone", .id = 502 };
    var loop_instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .lt, .a = 0, .b = 1 },
        .{ .op = .guard_true, .a = 4, .aux = 2 },
        .{ .op = .loop },
    };
    var loop_trace = Trace{ .anchor = .{ .proto = &loop_proto, .pc = 1 }, .instrs = &loop_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var loop_ct = compileInto(gpa, &arena, &loop_trace, 502, null, null) orelse return error.NativeBailedUnexpectedly;
    defer loop_ct.deinit();
    var saw_loopdone = false;
    for (loop_ct.silent_sites) |p| if (p.kind == .loop_done_linked) {
        saw_loopdone = true;
        try util.expectSilentCheck(&loop_ct, p);
        try testing.expectEqual(@as(usize, 0), p.metadata_cell.*);
    };
    try testing.expect(saw_loopdone);

    var deopt_code = [_]bytecode.Instr{ bytecode.Instr.op0(.halt), bytecode.Instr.op0(.halt) };
    var deopt_proto = bytecode.Proto{ .code = &deopt_code, .name = "b3-deopt", .id = 503 };
    loop_instrs[5].aux = 1;
    var deopt_trace = Trace{ .anchor = .{ .proto = &deopt_proto, .pc = 0 }, .instrs = &loop_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var deopt_ct = compileInto(gpa, &arena, &deopt_trace, 503, null, null) orelse return error.NativeBailedUnexpectedly;
    defer deopt_ct.deinit();
    var saw_deopt = false;
    for (deopt_ct.silent_sites) |p| if (p.kind == .deopt) {
        saw_deopt = true;
        try util.expectSilentCheck(&deopt_ct, p);
        // The deopt fall-through is the unchanged `jmp deopt_exit` (E9 rel32).
        try testing.expectEqual(@as(u8, 0xE9), deopt_ct.page.code[p.resume_off]);
        try testing.expectEqual(@as(usize, 0), p.metadata_cell.*);
    };
    try testing.expect(saw_deopt);
}

test "nativegen: ?RecordedBuiltin is laid out [payload, has_value] (guard_builtin prologue contract)" {
    // The native `guard_builtin` prologue reads the callee's `pure` field with two byte
    // compares relative to NATIVE_PURE_OFF: the payload ordinal at +0 and the non-null
    // flag at +1. Pin that `[payload, has_value]` order here so a toolchain change to
    // the optional-enum layout fails this test instead of silently miscompiling the
    // identity guard (the size is comptime-asserted next to the constant above).
    var p: ?function.RecordedBuiltin = .sqrt;
    const bytes = std.mem.asBytes(&p);
    try std.testing.expectEqual(@as(u8, @intFromEnum(function.RecordedBuiltin.sqrt)), bytes[0]); // payload at +0
    try std.testing.expectEqual(@as(u8, 1), bytes[1]); // has_value flag at +1
    p = null;
    try std.testing.expectEqual(@as(u8, 0), bytes[1]); // flag clears on null
}

test "nativegen: clean integer counting loop matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (i < limit) { acc += i; i += 1; }  — regs: r0=i, r1=limit, r2=acc.
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

    // i=1..5: commits 4 iterations (1+2+3+4=10), exits when i==5 (5<5 false).
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    // A tighter limit: 0 commits.
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.int(100) });
}

/// Build a one-iteration-shaped loop whose body computes `acc = X <op> N` with X and N
/// integer constants, carrying the result into slot 2. The native `emitShift` lowering
/// is differential-checked against the tier-1a oracle (`arith.shl`/`arith.shr`), which is
/// the source of truth for Lua's shift semantics — so this exercises every count regime
/// (in-range, ≥64 → 0, negative → reverse direction, INT64_MIN) without re-deriving the
/// expected bits here.
fn expectShiftMatch(op: trace.IrOp, x: i64, n: i64) !void {
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc (overwritten each iter)
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .konst, .aux = 1 }, // 8: X
        .{ .op = .konst, .aux = 2 }, // 9: N
        .{ .op = op, .a = 8, .b = 9, .ty = .int }, // 10: X <op> N
        .{ .op = .konst, .aux = 0 }, // 11: 1
        .{ .op = .add, .a = 0, .b = 11, .ty = .int }, // 12: i + 1
        .{ .op = .phi, .b = 10, .aux = 2 }, // 13: acc <- X <op> N
        .{ .op = .phi, .b = 12, .aux = 0 }, // 14: i carry
        .{ .op = .loop }, // 15
    };
    var consts = [_]Value{ Value.int(1), Value.int(x), Value.int(n) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // i=0, limit=3 → 3 iterations, each storing the same X<op>N into acc.
    try expectMatch(&t, &.{ Value.int(0), Value.int(3), Value.int(0) });
}

test "nativegen: shl/shr native lowering matches the Lua shift oracle across count regimes" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const MIN = std.math.minInt(i64);
    // shl: logical left for n≥0, logical right by |n| for n<0, 0 for |n|≥64.
    try expectShiftMatch(.shl, 1, 0); // identity
    try expectShiftMatch(.shl, 1, 5); // 32
    try expectShiftMatch(.shl, 1, 63); // sign bit set → INT64_MIN pattern
    try expectShiftMatch(.shl, 1, 64); // ≥64 → 0
    try expectShiftMatch(.shl, 1, 100); // ≥64 → 0
    try expectShiftMatch(.shl, 0x1234, -4); // negative → logical >>4
    try expectShiftMatch(.shl, -1, -1); // all-ones, logical >>1 → 0x7FFF…F
    try expectShiftMatch(.shl, -1, -64); // |n|=64 → 0
    try expectShiftMatch(.shl, 1, MIN); // INT64_MIN count (neg wraps) → 0
    try expectShiftMatch(.shl, -1, MIN); // INT64_MIN count, all-ones value → 0
    // shr: mirror — logical right for n≥0, logical left by |n| for n<0.
    try expectShiftMatch(.shr, 256, 4); // 16
    try expectShiftMatch(.shr, -1, 63); // logical >>63 → 1
    try expectShiftMatch(.shr, -1, 64); // ≥64 → 0
    try expectShiftMatch(.shr, 1, -5); // negative → logical <<5 → 32
    try expectShiftMatch(.shr, 1, -64); // |n|=64 → 0
    try expectShiftMatch(.shr, -1, MIN); // INT64_MIN count → 0
    // sar (~>>): arithmetic right for n≥0 (sign-extends), logical left by |n| for n<0,
    // sign-fill for n≥64, 0 for |n|≥64 on the reverse leg.
    try expectShiftMatch(.sar, 256, 4); // 16 (positive operand == logical)
    try expectShiftMatch(.sar, -1, 1); // sign-extend → -1
    try expectShiftMatch(.sar, -1, 63); // sign-extend → -1 (NOT 1 like shr)
    try expectShiftMatch(.sar, -4, 1); // -2
    try expectShiftMatch(.sar, -1, 64); // ≥64 → sign fill -1
    try expectShiftMatch(.sar, -1, 100); // ≥64 → sign fill -1
    try expectShiftMatch(.sar, 1, 64); // ≥64, positive → 0
    try expectShiftMatch(.sar, MIN, 100); // ≥64, negative → -1
    try expectShiftMatch(.sar, MIN, 63); // sign-extend INT64_MIN → -1
    try expectShiftMatch(.sar, 1, -5); // negative count → logical <<5 → 32
    try expectShiftMatch(.sar, 1, -64); // |n|=64 → 0
    try expectShiftMatch(.sar, -1, MIN); // INT64_MIN count → 0
}

test "nativegen(E2): an internal φ (slot-less carry) matches the oracle and is never flushed" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // A hand-built trace shaped like an SR product (no source trigger yet): a
    // slot-less internal φ `m` is initialised in the preheader to 100 and steps
    // +10 each iteration; the body accumulates it into a real slot.
    //   m = 100;  while (i < limit) { acc += m; i += 1; m += 10; }
    // regs: r0=i, r1=limit, r2=acc. `m` backs NO register (aux = PHI_INTERNAL) —
    // it lives in a computed home, is excluded from the prologue tag-checks, and
    // is NEVER written to regs[] at deopt. A wrong home/flush corrupts r0/r1/r2,
    // which the oracle compares bit-for-bit.
    var instrs = [_]I{
        .{ .op = .konst, .aux = 0 }, // 0: 100 — m init (run-once region)
        .{ .op = .preheader }, // 1: marker
        .{ .op = .slot_load, .aux = 0 }, // 2: i
        .{ .op = .slot_load, .aux = 1 }, // 3: limit
        .{ .op = .phi, .a = 0, .b = 15, .aux = trace.PHI_INTERNAL, .ty = .int }, // 4: m (b → node 15, m+10)
        .{ .op = .guard_int, .a = 2 }, // 5
        .{ .op = .guard_int, .a = 3 }, // 6
        .{ .op = .lt, .a = 2, .b = 3 }, // 7: i < limit
        .{ .op = .guard_true, .a = 7 }, // 8
        .{ .op = .slot_load, .aux = 2 }, // 9: acc
        .{ .op = .guard_int, .a = 9 }, // 10
        .{ .op = .add, .a = 9, .b = 4, .ty = .int }, // 11: acc + m
        .{ .op = .konst, .aux = 1 }, // 12: 1
        .{ .op = .add, .a = 2, .b = 12, .ty = .int }, // 13: i + 1
        .{ .op = .konst, .aux = 2 }, // 14: 10
        .{ .op = .add, .a = 4, .b = 14, .ty = .int }, // 15: m + 10  (m back-edge)
        .{ .op = .phi, .b = 11, .aux = 2 }, // 16: acc carry  (b → node 11, acc+m)
        .{ .op = .phi, .b = 13, .aux = 0 }, // 17: i carry
        .{ .op = .loop }, // 18
    };
    var consts = [_]Value{ Value.int(100), Value.int(1), Value.int(10) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // i=0..5, limit=5: m runs 100,110,...,140; acc = 100+110+120+130+140 = 600.
    try expectMatch(&t, &.{ Value.int(0), Value.int(5), Value.int(0) });
    // Mid-loop exit after 3 commits (limit=3): m never reaches regs[].
    try expectMatch(&t, &.{ Value.int(0), Value.int(3), Value.int(0) });
    // Immediate exit (i >= limit on entry): 0 commits, regs untouched.
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.int(0) });

    // Hand-check the oracle itself against expected regs — expectMatch only
    // proves tier-1a ≡ tier-1b, so a shared wrong Δ would pass it. Pin the
    // actual values so the internal-φ carry arithmetic is independently correct.
    {
        var regs = [_]Value{ Value.int(0), Value.int(5), Value.int(0) };
        const values = try testing.allocator.alloc(Value, instrs.len);
        defer testing.allocator.free(values);
        const completed = irinterp.executeValues(&t, &regs, values).completed;
        try testing.expectEqual(@as(usize, 5), completed);
        try testing.expectEqual(@as(i64, 5), regs[0].asInt()); // i
        try testing.expectEqual(@as(i64, 5), regs[1].asInt()); // limit
        try testing.expectEqual(@as(i64, 600), regs[2].asInt()); // acc
    }
}

test "nativegen(E2): a FLOAT internal φ (the SR `denom` shape) carries in an XMM computed home" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // The actual strength-reduction target shape (pi_leibniz's `denom`): a float
    // internal φ initialised in the preheader and stepped by a float constant.
    //   denom = 1.0;  while (i < limit) { acc += denom; i += 1; denom += 2.0; }
    // r0=i (int), r1=limit (int), r2=acc (FLOAT). `denom` lives in an XMM computed
    // home — it is seeded once before loop_top and shuffled at the back-edge, never
    // flushed at deopt. acc is a carried FLOAT slot (XMM home, TAG_FLOAT flush), so
    // the test also exercises a float computed home alongside a float carried slot.
    var instrs = [_]I{
        .{ .op = .konst, .aux = 0 }, // 0: 1.0 — denom init (run-once)
        .{ .op = .preheader }, // 1
        .{ .op = .slot_load, .aux = 0 }, // 2: i
        .{ .op = .slot_load, .aux = 1 }, // 3: limit
        .{ .op = .phi, .a = 0, .b = 15, .aux = trace.PHI_INTERNAL, .ty = .float }, // 4: denom
        .{ .op = .guard_int, .a = 2 }, // 5
        .{ .op = .guard_int, .a = 3 }, // 6
        .{ .op = .lt, .a = 2, .b = 3 }, // 7: i < limit
        .{ .op = .guard_true, .a = 7 }, // 8
        .{ .op = .slot_load, .aux = 2 }, // 9: acc
        .{ .op = .guard_float, .a = 9 }, // 10
        .{ .op = .add, .a = 9, .b = 4, .ty = .float }, // 11: acc + denom
        .{ .op = .konst, .aux = 1 }, // 12: 1
        .{ .op = .add, .a = 2, .b = 12, .ty = .int }, // 13: i + 1
        .{ .op = .konst, .aux = 2 }, // 14: 2.0
        .{ .op = .add, .a = 4, .b = 14, .ty = .float }, // 15: denom + 2.0 (back-edge)
        .{ .op = .phi, .b = 11, .aux = 2 }, // 16: acc carry
        .{ .op = .phi, .b = 13, .aux = 0 }, // 17: i carry
        .{ .op = .loop }, // 18
    };
    var consts = [_]Value{ Value.float(1.0), Value.int(1), Value.float(2.0) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // i=0..4, limit=4: denom = 1,3,5,7; acc = 1+3+5+7 = 16.0.
    try expectMatch(&t, &.{ Value.int(0), Value.int(4), Value.float(0.0) });
    // Mid-loop exit (limit=2): denom carried, acc=1+3=4.0; denom never in regs[].
    try expectMatch(&t, &.{ Value.int(0), Value.int(2), Value.float(0.0) });

    // Hand-check the oracle's actual float values (expectMatch is Δ-blind).
    {
        var regs = [_]Value{ Value.int(0), Value.int(4), Value.float(0.0) };
        const values = try testing.allocator.alloc(Value, instrs.len);
        defer testing.allocator.free(values);
        const completed = irinterp.executeValues(&t, &regs, values).completed;
        try testing.expectEqual(@as(usize, 4), completed);
        try testing.expectEqual(@as(i64, 4), regs[0].asInt());
        try testing.expectEqual(@as(f64, 16.0), regs[2].asFloat());
    }
}

test "nativegen: a guard_int failure side-exits with completed==0" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit (will be a float at runtime)
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3 — fails: limit is float
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i+1
        .{ .op = .phi, .b = 7, .aux = 0 },
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // limit is a float → guard_int #3 fails on the very first iteration.
    try expectMatch(&t, &.{ Value.int(0), Value.float(5.0) });
}

test "nativegen: a loop-carried boolean is boxed with the boolean tag" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // r1 := (i < 10) each iteration; r0 := i+1. Exits when i==10.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 10
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 10  (BOOL, loop-carried)
        .{ .op = .konst, .aux = 1 }, // 4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // 5: i + 1
        .{ .op = .guard_true, .a = 3 }, // 6
        .{ .op = .phi, .b = 5, .aux = 0 },
        .{ .op = .phi, .b = 3, .aux = 1 },
        .{ .op = .loop }, // 7
    };
    var consts = [_]Value{ Value.int(10), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // r1 must end as boolean(true) (tag=1), NOT int(1) (tag=2) — the oracle catches it.
    try expectMatch(&t, &.{ Value.int(0), Value.nil() });
}

test "nativegen: guard_true on an integer always passes (int 0 is truthy)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (starts at 0)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .guard_true, .a = 0 }, // 2: truthy-guard on the int itself
        .{ .op = .konst, .aux = 0 }, // 3: 3
        .{ .op = .lt, .a = 0, .b = 3 }, // 4: i < 3
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 1 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i+1
        .{ .op = .phi, .b = 7, .aux = 0 },
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{ Value.int(3), Value.int(1) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // i=0,1,2 commit (guard_true on int 0 must NOT exit); exits at i=3. completed==3.
    try expectMatch(&t, &.{Value.int(0)});
}

test "nativegen: guard_false on an integer side-exits immediately" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .guard_false, .a = 0 }, // 2: int is truthy → guard_false fails
        .{ .op = .phi, .b = 0, .aux = 0 },
        .{ .op = .loop }, // 3
    };
    var consts = [_]Value{};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectMatch(&t, &.{Value.int(5)}); // completed==0, regs unchanged
}
