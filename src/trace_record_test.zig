//! Tests for `trace.zig` — record.
//!
//! Extracted verbatim from `trace.zig`; bodies are unchanged.
//! Shared harness lives in `trace_testutil.zig`.

const trace = @import("trace.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

const AbortReason = trace.AbortReason;
const IrOp = trace.IrOp;
const ObsType = trace.ObsType;
const Ref = trace.Ref;
const TraceState = trace.TraceState;
const guardExitPc = trace.guardExitPc;
const guardSourcePc = trace.guardSourcePc;

const util = @import("trace_testutil.zig");
const winRO = util.winRO;

test "recArrayGet: t[k] on a bool lane records the full guarded read sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // nsieve's bool sieve → a narrow boolean lane.
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key (3) ; `get_index r0, r1, r2`  →  r0 = t[3]
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // a clean record — no abort
    const ops = state.rec.instrs.items;
    // slot_load(table), guard_table, guard_lane, slot_load(key), guard_int,
    // aref, guard_bounds, guard_present, aload.
    try testing.expectEqual(@as(usize, 9), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_table, ops[1].op);
    try testing.expectEqual(IrOp.guard_lane, ops[2].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[2].aux);
    try testing.expectEqual(IrOp.slot_load, ops[3].op);
    try testing.expectEqual(IrOp.guard_int, ops[4].op);
    try testing.expectEqual(IrOp.aref, ops[5].op);
    try testing.expectEqual(ops[0].a, ops[5].a); // aref.table == the table slot_load... (ref check below)
    try testing.expectEqual(@as(Ref, 0), ops[5].a); // table ref
    try testing.expectEqual(@as(Ref, 3), ops[5].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[6].op);
    try testing.expectEqual(@as(Ref, 5), ops[6].a); // guards the aref
    try testing.expectEqual(IrOp.guard_present, ops[7].op);
    try testing.expectEqual(@as(Ref, 5), ops[7].a);
    try testing.expectEqual(IrOp.aload, ops[8].op);
    try testing.expectEqual(@as(Ref, 5), ops[8].a); // loads through the aref
    try testing.expectEqual(ObsType.boolean, ops[8].ty); // bool lane → boolean
}

test "recArrayGet: an integral-FLOAT key narrows via guard_float + int_of_float (keyRefNarrowed)" {
    // `t[3.0]` — the key a float division produces (fft_bitreverse's `j`). Tier-0's
    // `normalizeKey` folds it to the int slot; the recorder must mirror that with a
    // guarded narrow, not abort. Sequence: slot_load(table), guard_table, guard_lane,
    // slot_load(key), guard_float, int_of_float, aref(key = the NARROWED ref),
    // guard_bounds, guard_present, aload.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.float(3.0) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // narrows, does NOT abort
    const ops = state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.guard_float, ops[4].op); // key observed float
    try testing.expectEqual(@as(Ref, 3), ops[4].a); // ...guards the key slot_load
    try testing.expectEqual(IrOp.int_of_float, ops[5].op); // the narrow
    try testing.expectEqual(@as(Ref, 3), ops[5].a);
    try testing.expectEqual(ObsType.int, ops[5].ty);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(@as(Ref, 5), ops[6].b); // aref keys on the NARROWED ref
    try testing.expectEqual(IrOp.aload, ops[9].op);
}

test "recArraySet: an integral-FLOAT key narrows and stores through the narrowed ref" {
    // `t[3.0] = false` on a bool lane: same narrow as the read side; the astore's
    // aref must key on the int_of_float result.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // set_index: a=table b=key c=value
    var regs = [_]Value{ Value.heap(&t.header), Value.float(3.0), Value.boolean(false) };
    state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // slot_load(value), slot_load(table), guard_table, guard_lane, slot_load(key),
    // guard_float, int_of_float, aref, guard_bounds, guard_fits, astore.
    var saw_iof: ?Ref = null;
    var aref_key: ?Ref = null;
    var saw_astore = false;
    for (ops, 0..) |ins, idx| {
        if (ins.op == .int_of_float) saw_iof = @intCast(idx);
        if (ins.op == .aref) aref_key = ins.b;
        if (ins.op == .astore) saw_astore = true;
    }
    try testing.expect(saw_iof != null);
    try testing.expectEqual(saw_iof.?, aref_key.?); // store keys on the narrowed ref
    try testing.expect(saw_astore);
}

test "recCompare narrows an observed integral float in a mixed numeric comparison" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "mixed_compare", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r0 = r1 < r2, with the arithmetic-derived operand observed as 3.0.
    // The comparison must consume the int_of_float result, not the float ref.
    var regs = [_]Value{ Value.nil(), Value.int(2), Value.float(3.0) };
    state.recordInstr(Instr.opABC(.lt, 0, 1, 2), winRO(&regs), &proto, 7, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    try testing.expectEqual(IrOp.guard_int, ops[2].op);
    try testing.expectEqual(IrOp.guard_float, ops[3].op);
    try testing.expectEqual(IrOp.int_of_float, ops[4].op);
    try testing.expectEqual(IrOp.lt, ops[5].op);
    try testing.expectEqual(@as(Ref, 0), ops[5].a);
    try testing.expectEqual(@as(Ref, 4), ops[5].b);
}

test "guardSourcePc: source-opcode PC is exit PC − 1 (H-1b), pinned independently" {
    const gpa = testing.allocator;

    // (1) Recorded path. Record a real `get_index` as if its opcode sat at a known
    // bytecode index N: the tier-0 dispatch loop hands `recordInstr` the
    // POST-INCREMENT pc (N+1) (interp.zig:1762), so the emitted `guard_int` must
    // report source-opcode N and resume/exit N+1. We assert against the
    // INDEPENDENTLY chosen N — not `source+1 == exit`, which is tautological given
    // `guardSourcePc := exit − 1`.
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    const N: u32 = 5; // chosen known source-opcode index
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, N + 1, Value.nil());
    try testing.expect(state.isRecording());

    var saw_guard = false;
    for (state.rec.instrs.items) |ins| {
        if (guardExitPc(ins)) |exit_pc| {
            try testing.expectEqual(@as(u32, N + 1), exit_pc); // stamped post-increment pc
            try testing.expectEqual(@as(u32, N), guardSourcePc(ins).?); // owning opcode
            saw_guard = true;
        }
    }
    try testing.expect(saw_guard); // the bool-lane get_index emits a PC-carrying guard_int

    // (2) emit-fixture for the two ops a simple recorded op can't reach:
    // `guard_number` (the production `guardNum` only ever picks int/float,
    // trace.zig ~4165) and `int_of_float`. Set the recorder's post-increment pc to a
    // known M+1 and emit each directly; both must stamp `aux` and report source M /
    // exit M+1.
    var st2 = TraceState.init(gpa);
    defer st2.deinit();
    try st2.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    const M: u32 = 11;
    st2.rec.cur_pc = M + 1;
    inline for (.{ IrOp.guard_number, IrOp.int_of_float }) |op| {
        const ref = try st2.rec.emit(.{ .op = op, .a = 0 });
        const ins = st2.rec.instrs.items[ref];
        try testing.expectEqual(@as(u32, M + 1), guardExitPc(ins).?);
        try testing.expectEqual(@as(u32, M), guardSourcePc(ins).?);
    }

    // (3) a non-PC-carrying op yields null from BOTH accessors (never a category error).
    try testing.expectEqual(@as(?u32, null), guardExitPc(.{ .op = .aload, .a = 0 }));
    try testing.expectEqual(@as(?u32, null), guardSourcePc(.{ .op = .aload, .a = 0 }));

    // (4) the 0 sentinel ("no usable PC") maps to null through the source accessor too.
    try testing.expectEqual(@as(?u32, null), guardSourcePc(.{ .op = .guard_true, .a = 0, .aux = 0 }));
}

test "recArrayGet aborts: non-table container, non-int key, hole, and out-of-bounds" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };

    const Case = struct { tab: Value, key: Value, why: AbortReason };
    const cases = [_]Case{
        .{ .tab = Value.int(7), .key = Value.int(3), .why = .bad_type }, // not a table
        .{ .tab = Value.heap(&t.header), .key = Value.boolean(true), .why = .bad_type }, // non-int key
        .{ .tab = Value.heap(&t.header), .key = Value.float(1.5), .why = .bad_type }, // FRACTIONAL float — hash territory, no narrow
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), c.tab, c.key };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording()); // aborted
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recArrayGet records a .value-lane table element (array-of-structs)" {
    const gpa = testing.allocator;
    // Create a table whose array part holds a table — forces .value lane.
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const outer = try table_mod.Table.create(gpa);
    defer outer.destroy(gpa);
    try outer.set(gpa, Value.int(1), Value.heap(&inner.header));
    try testing.expectEqual(arr.Lane.value, outer.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&outer.header), Value.int(1) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    // Recording should succeed — the .value-lane table path emits IR.
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(?AbortReason, null), state.rec.abort_reason);
    // Verify the IR sequence: the last two instructions should be
    // aload(.value, ty=.heap) followed by guard_table (on the loaded element).
    const instrs = state.rec.instrs.items;
    const last = instrs[instrs.len - 1];
    try testing.expectEqual(IrOp.guard_table, last.op);
    const aload_ref = last.a;
    const aload_ins = instrs[@intCast(aload_ref)];
    try testing.expectEqual(IrOp.aload, aload_ins.op);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.value)), aload_ins.aux);
}

test "recArrayGet aborts on a .value-lane bool element — nyi scope cut" {
    const gpa = testing.allocator;
    // Force .value lane by storing a table then a boolean at different indices.
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.heap(&inner.header)); // → .value lane
    try t.set(gpa, Value.int(2), Value.boolean(true)); // stays .value (can't narrow)
    try testing.expectEqual(arr.Lane.value, t.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    // Access index 2 (the boolean) — a bool has no *strict* type guard (`guard_true`
    // would wave a truthy heap value through), so it stays out of doc 32's admission.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.nyi_opcode, state.rec.abort_reason.?);
}

/// Build a heterogeneous `.value`-lane table: index 1 holds `inner` (a table, which
/// is what forces the lane), index 2 holds `scalar`. Mirrors the real shape doc 32
/// targets — an array whose elements are not one uniform narrow type.
fn valueLaneWith(gpa: std.mem.Allocator, inner: *table_mod.Table, scalar: Value) !*table_mod.Table {
    const t = try table_mod.Table.create(gpa);
    errdefer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.heap(&inner.header)); // → .value lane
    try t.set(gpa, Value.int(2), scalar); // stays .value (can't narrow)
    try testing.expectEqual(arr.Lane.value, t.array.lane);
    return t;
}

test "recArrayGet: doc 32 — a .value-lane int element records with guard_int and no guard_present" {
    const gpa = testing.allocator;
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try valueLaneWith(gpa, inner, Value.int(42));
    defer t.destroy(gpa);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(?AbortReason, null), state.rec.abort_reason);
    const ops = state.rec.instrs.items;
    // slot_load(table), guard_table, guard_lane(.value), slot_load(key),
    // guard_int(key), aref, guard_bounds, aload(ty=.int), guard_int(loaded).
    // NO guard_present: the `.value` lane has no presence bitmap — a hole reads back
    // as an in-band nil, which the trailing guard_int rejects.
    try testing.expectEqual(@as(usize, 9), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_table, ops[1].op);
    try testing.expectEqual(IrOp.guard_lane, ops[2].op);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.value)), ops[2].aux);
    try testing.expectEqual(IrOp.slot_load, ops[3].op);
    try testing.expectEqual(IrOp.guard_int, ops[4].op); // the KEY guard
    try testing.expectEqual(IrOp.aref, ops[5].op);
    try testing.expectEqual(IrOp.guard_bounds, ops[6].op);
    try testing.expectEqual(IrOp.aload, ops[7].op);
    try testing.expectEqual(ObsType.int, ops[7].ty);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.value)), ops[7].aux);
    try testing.expectEqual(IrOp.guard_int, ops[8].op); // the ELEMENT guard
    try testing.expectEqual(@as(Ref, 7), ops[8].a); // …on the aload, not the key
    for (ops) |o| try testing.expect(o.op != .guard_present);
}

test "recArrayGet: doc 32 — a .value-lane float element records with guard_float" {
    const gpa = testing.allocator;
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try valueLaneWith(gpa, inner, Value.float(2.5));
    defer t.destroy(gpa);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 9), ops.len);
    try testing.expectEqual(IrOp.aload, ops[7].op);
    try testing.expectEqual(ObsType.float, ops[7].ty);
    // The element guard follows the OBSERVED type — a float element pins guard_float,
    // so a later iteration handing back an int side-exits rather than silently
    // changing the value's subtype.
    try testing.expectEqual(IrOp.guard_float, ops[8].op);
    try testing.expectEqual(@as(Ref, 7), ops[8].a);
    for (ops) |o| try testing.expect(o.op != .guard_present);
}

test "recArraySet: doc 32 — a .value-lane numeric store pins the value with guardNum, not guard_fits" {
    const gpa = testing.allocator;
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try valueLaneWith(gpa, inner, Value.int(42));
    defer t.destroy(gpa);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    // r0 = value (7), r1 = table, r2 = key (2) ; `set_index r1, r2, r0` → t[2] = 7
    var regs = [_]Value{ Value.int(7), Value.heap(&t.header), Value.int(2) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(?AbortReason, null), state.rec.abort_reason);
    const ops = state.rec.instrs.items;
    // slot_load(val), slot_load(tab), guard_table, guard_lane(.value), slot_load(key),
    // guard_int(key), aref, guard_bounds, guard_int(val), astore.
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.guard_lane, ops[3].op);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.value)), ops[3].aux);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(IrOp.guard_bounds, ops[7].op);
    // THE point of the test: the store's type pin is a guard on the VALUE ref (the
    // slot_load at 0), not a guard_fits. `laneFits(.value, _)` is unconditionally
    // true, so guard_fits would pin nothing and a drifted non-numeric value would
    // reach the oracle's setInLane. (Review finding 1 on doc 32.)
    try testing.expectEqual(IrOp.guard_int, ops[8].op);
    try testing.expectEqual(@as(Ref, 0), ops[8].a);
    try testing.expectEqual(IrOp.astore, ops[9].op);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.value)), ops[9].aux);
    for (ops) |o| try testing.expect(o.op != .guard_fits);
    for (ops) |o| try testing.expect(o.op != .guard_present);
}

test "abort log records (anchor, reason, opcode) and dedups recurrences" {
    const gpa = testing.allocator;
    // Force .value lane by storing a table at [1] and a boolean at [2].
    // Accessing [2] (a non-table in .value lane) triggers nyi_opcode.
    const inner = try table_mod.Table.create(gpa);
    defer inner.destroy(gpa);
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.heap(&inner.header)); // → .value lane
    try t.set(gpa, Value.int(2), Value.boolean(true)); // stays .value
    try testing.expectEqual(arr.Lane.value, t.array.lane);

    const proto = Proto{ .code = &.{}, .name = "loop", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.record_aborts = true; // what --dump-aborts flips on

    // Access index 2 (the boolean, not the table) → nyi_opcode.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    // Re-arm and abort the same anchor/op three times: a real loop aborts on every
    // back-edge, and the log must collapse that to one row with count == 3.
    for (0..3) |_| {
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 7, .proto_id = proto.id }, proto.num_registers);
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 9, Value.nil());
    }

    try testing.expectEqual(@as(usize, 1), state.abort_log.items.len);
    const row = state.abort_log.items[0];
    try testing.expectEqual(@as(u64, 3), row.count);
    try testing.expectEqual(@as(u32, 7), row.anchor_pc);
    try testing.expectEqual(@as(u32, 9), row.abort_pc);
    try testing.expectEqual(OpCode.get_index, row.op);
    try testing.expectEqual(AbortReason.nyi_opcode, row.reason);
    // `ir_len` is the CUMULATIVE partial-trace length at abort time. This anchor
    // records nothing before the aborting `get_index`, so it is 0. In a real loop
    // (nbody's `bodies[i]`, array3d's `a[i][j]`) the loop header contributes a few
    // IR instrs first, so the same abort shows ir_len≈2 — "got this far, then died".
    try testing.expectEqual(@as(u32, 0), row.ir_len);

    // A distinct reason at the same anchor is a separate row.
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 7, .proto_id = proto.id }, proto.num_registers);
    state.recordInstr(Instr.opAB(.new_table, 0, 0), winRO(&regs), &proto, 3, Value.nil());
    try testing.expectEqual(@as(usize, 2), state.abort_log.items.len);

    // With the flag off, nothing is logged.
    var quiet = TraceState.init(gpa);
    defer quiet.deinit();
    try quiet.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 7, .proto_id = proto.id }, proto.num_registers);
    quiet.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 9, Value.nil());
    try testing.expectEqual(@as(usize, 0), quiet.abort_log.items.len);
}

test "recArrayGet/recArraySet abort on a metatable-bearing table (chunk 2a)" {
    const gpa = testing.allocator;
    // A dense boolean array — exactly the shape the recorder would otherwise
    // trace (`recArrayGet`/`recArraySet` lower it) — but carrying a metatable.
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    const mt = try table_mod.Table.create(gpa);
    defer mt.destroy(gpa);
    t.metatable = mt; // the metatable edge the access might dispatch through

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };

    // get_index: present, in-bounds, bool-lane — would record without a metatable.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index in-bounds in-lane store.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&t.header), Value.int(3), Value.boolean(false) };
        state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index append store (`t[len+1]=true`) — the path that would fire
    // `__newindex` on an absent key.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&t.header), Value.int(33), Value.boolean(true) };
        state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
}

test "recArraySet: t[k]=false on a bool lane records the full guarded write sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key (3), r0 = value (false); `set_index a=1 b=2 c=0` → t[3]=false.
    var regs = [_]Value{ Value.boolean(false), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // clean record — no abort
    const ops = state.rec.instrs.items;
    // value resolved first (for the C1 taint scan): slot_load(value), which doc 57
    // value-specializes — guard_is_false on it, then the konst `false` every later
    // use reads. Then slot_load(table), guard_table, guard_lane, slot_load(key),
    // guard_int, aref, guard_bounds, guard_fits, astore. No guard_present — astore
    // creates presence. guard_fits is still emitted for the bool lane (it guards
    // the konst now, and tropt folds it as always-pass).
    try testing.expectEqual(@as(usize, 12), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op); // value (r0)
    try testing.expectEqual(IrOp.guard_is_false, ops[1].op);
    try testing.expectEqual(@as(Ref, 0), ops[1].a); // pins the value slot_load
    try testing.expectEqual(IrOp.konst, ops[2].op); // the pinned `false`
    try testing.expectEqual(IrOp.slot_load, ops[3].op); // table (r1)
    try testing.expectEqual(IrOp.guard_table, ops[4].op);
    try testing.expectEqual(IrOp.guard_lane, ops[5].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[5].aux);
    try testing.expectEqual(IrOp.slot_load, ops[6].op); // key (r2)
    try testing.expectEqual(IrOp.guard_int, ops[7].op);
    try testing.expectEqual(IrOp.aref, ops[8].op);
    try testing.expectEqual(@as(Ref, 3), ops[8].a); // table ref
    try testing.expectEqual(@as(Ref, 6), ops[8].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[9].op);
    try testing.expectEqual(@as(Ref, 8), ops[9].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[10].op);
    try testing.expectEqual(@as(Ref, 2), ops[10].a); // range-checks the pinned konst
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[10].aux);
    try testing.expectEqual(IrOp.astore, ops[11].op);
    try testing.expectEqual(@as(Ref, 8), ops[11].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 2), ops[11].b); // value = the pinned konst
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[11].aux);
}

test "recArraySet: a bool-lane append (t[asize]=true) records the guarded grow sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // Fill 2..32 (keys 0 and 1 stay holes) so the table rehashes to the boolean
    // lane and drains its hash — exactly nsieve's init-loop steady state. The next
    // append-successor store is `t[asize]` (doc 18 D2.3: the key IS the extent).
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);
    try testing.expectEqual(@as(usize, 0), t.hash.count()); // hash drained → migrate is a no-op
    const len_before = t.array.asize;
    const append_key: i64 = @intCast(len_before);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key (asize), r0 = value (true); `set_index a=1 b=2 c=0`.
    var regs = [_]Value{ Value.boolean(true), Value.heap(&t.header), Value.int(append_key) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // clean record — the append path, no abort
    const ops = state.rec.instrs.items;
    // Same prologue as the in-bounds store, but guard_bounds → guard_append and
    // astore → astore_append: slot_load(value), guard_is_true + konst (doc 57
    // pin), slot_load(table), guard_table, guard_lane, slot_load(key), guard_int,
    // aref, guard_append, guard_fits, astore_append.
    try testing.expectEqual(@as(usize, 12), ops.len);
    try testing.expectEqual(IrOp.guard_is_true, ops[1].op);
    try testing.expectEqual(IrOp.konst, ops[2].op);
    try testing.expectEqual(IrOp.aref, ops[8].op);
    try testing.expectEqual(IrOp.guard_append, ops[9].op);
    try testing.expectEqual(@as(Ref, 8), ops[9].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[10].op);
    try testing.expectEqual(IrOp.astore_append, ops[11].op);
    try testing.expectEqual(@as(Ref, 8), ops[11].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 2), ops[11].b); // value = the pinned konst
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[11].aux);

    // The recorder must NOT have mutated the table — recording is side-effect free.
    try testing.expectEqual(len_before, t.array.asize);
}

test "recArraySet aborts: non-table, non-int key, OOB, out-of-lane value, non-numeric .value store" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    // A separate .value-lane table: a heap value can only live in the .value lane
    // (eager commit leaves it there — laneForValue of a heap ref is .value).
    const tv = try table_mod.Table.create(gpa);
    defer tv.destroy(gpa);
    try tv.set(gpa, Value.int(1), Value.heap(&tv.header));
    try testing.expectEqual(arr.Lane.value, tv.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    const Case = struct { tab: Value, key: Value, val: Value, why: AbortReason };
    const cases = [_]Case{
        // not a table container.
        .{ .tab = Value.int(7), .key = Value.int(3), .val = Value.boolean(false), .why = .bad_type },
        // non-int key (hash-part territory).
        .{ .tab = Value.heap(&t.header), .key = Value.boolean(true), .val = Value.boolean(false), .why = .bad_type },
        // out of bounds (k > len would grow the array).
        .{ .tab = Value.heap(&t.header), .key = Value.int(9999), .val = Value.boolean(false), .why = .bad_type },
        // out-of-lane value (an int into a bool lane would widen → shape change).
        .{ .tab = Value.heap(&t.header), .key = Value.int(3), .val = Value.int(5), .why = .bad_type },
        // nil value — a hole-punch / delete, out of B3 scope.
        .{ .tab = Value.heap(&t.header), .key = Value.int(3), .val = Value.nil(), .why = .bad_type },
        // .value-lane array with a NON-numeric value — still a scope cut (doc 32 §6):
        // a heap value is the one shape that would need a real write barrier under a
        // future generational/incremental collector. An int or a float DOES record
        // here now; that is pinned by the positive test below.
        .{ .tab = Value.heap(&tv.header), .key = Value.int(1), .val = Value.heap(&t.header), .why = .nyi_opcode },
        .{ .tab = Value.heap(&tv.header), .key = Value.int(1), .val = Value.boolean(true), .why = .nyi_opcode },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ c.val, c.tab, c.key };
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recArraySet defers an RMW store (store-sinking) instead of aborting" {
    // The old C1 rule aborted any store that followed a packed read. Store-sinking
    // (Gap B) instead DEFERS the single store and flushes it below every guard at
    // trace close, so a read-modify-write records and runs native. See
    // `docs/design/07-rmw-store-sinking.md`.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key. First: r0 = t[r2] (a packed read → aload). The recorder's
    // get_index executes against the live table; r0 then logically holds t[3] = true.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.nil() };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording()); // the read records cleanly

    // Now t[k] = (the value just read), an RMW. The store defers (sinks) rather
    // than aborting: the trace stays live and `pending_store` is armed.
    regs[0] = Value.boolean(true); // r0 = t[3], a boolean
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_stores.items.len);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.boolean)), state.rec.pending_stores.items[0].lane_ord);
    // The store is deferred — NOT yet in the instruction stream (it lands at commit).
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);

    // A subsequent must-alias read forwards the newest pending value. The trace
    // remains live and no physical `aload` is emitted after the deferred store.
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(state.rec.pending_stores.items[0].value, state.rec.reg_map[0].ref);
}

test "post-store array load proves constant non-aliasing without a runtime relation guard" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 16) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(true) };
    state.recordInstr(.{ .op = .load_int, .a = 2, .aux = 3 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_stores.items.len);

    regs[2] = Value.int(4);
    state.recordInstr(.{ .op = .load_int, .a = 2, .aux = 4 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    var saw_relation = false;
    var saw_aload = false;
    for (state.rec.instrs.items) |ins| {
        if (ins.op == .eq or ins.op == .ne) saw_relation = true;
        if (ins.op == .aload) saw_aload = true;
    }
    try testing.expect(!saw_relation);
    try testing.expect(saw_aload);
}

test "post-store array load with ambiguous key emits runtime ne disambiguation guard" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 16) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "ambiguous_alias", .num_registers = 5 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r2 and r3 are unrelated loop inputs. Their observed 3 != 4 relation is not
    // a static proof, so the recorder emits a runtime `ne` guard to disambiguate
    // the sunk store's key from the load's key (store_fwd_ambiguity → ne guard).
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.int(4), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 4), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 3), winRO(&regs), &proto, 0, Value.nil());
    // Recording continues (no abort) — the ne guard allows it.
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(?AbortReason, null), state.rec.abort_reason);
    // The IR must contain at least one `.ne` instruction (the disambiguation guard).
    var saw_ne = false;
    for (state.rec.instrs.items) |ins| {
        if (ins.op == .ne) saw_ne = true;
    }
    try testing.expect(saw_ne);
}

test "doc 51 F1: array load via a second SSA ref to the OBSERVED-SAME table forwards behind guard_false" {
    // Two register slots hold the SAME table (`t[1]`/`t[2]` both = a, the flat
    // alias_doa shape): the load's table ref differs from the sunk store's, but
    // record-time object identity proves they alias. Pre-fix the recorder
    // emitted `ne` + `guard_true` — false during its own recording, a trace
    // that completed 0 iterations forever (the F1 turnstile). Now: konst keys
    // classify `.must`, the identity is pinned with `ne` + `guard_false`, and
    // the pending value forwards.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 16) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "same_tab_two_refs", .num_registers = 6 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 AND r2 hold the same table; r3 = konst key; r4 = value.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.heap(&t.header), Value.int(3), Value.boolean(true), Value.nil() };
    state.recordInstr(.{ .op = .load_int, .a = 3, .aux = 3 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 3), winRO(&regs), &proto, 0, Value.nil()); // read via r1 (RMW trigger)
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 4), winRO(&regs), &proto, 0, Value.nil()); // sinks
    try testing.expectEqual(@as(usize, 1), state.rec.pending_stores.items.len);
    const pending_val = state.rec.pending_stores.items[0].value;

    state.recordInstr(Instr.opABC(.get_index, 0, 2, 3), winRO(&regs), &proto, 0, Value.nil()); // read via r2
    try testing.expect(state.isRecording());
    // Forwarded, not re-loaded: r0 now holds the pending store's value ref.
    try testing.expectEqual(pending_val, state.rec.reg_map[0].ref);
    var n_ne: usize = 0;
    var n_gf: usize = 0;
    var n_aload: usize = 0;
    for (state.rec.instrs.items) |ins| {
        if (ins.op == .ne) n_ne += 1;
        if (ins.op == .guard_false) n_gf += 1;
        if (ins.op == .aload) n_aload += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_ne); // the identity pin
    try testing.expectEqual(@as(usize, 1), n_gf); // guarded in the OBSERVED direction
    try testing.expectEqual(@as(usize, 1), n_aload); // only the first read touched the heap
}

test "doc 51 F1: array load via a second ref to an OBSERVED-DIFFERENT table guards ne true and reads the heap" {
    // The honest arm: two genuinely different tables — `ne` observed TRUE, so
    // `guard_true` (as before the fix, but now proven honest at record time)
    // and the load emits its own heap read.
    const gpa = testing.allocator;
    const t1 = try table_mod.Table.create(gpa);
    defer t1.destroy(gpa);
    const t2 = try table_mod.Table.create(gpa);
    defer t2.destroy(gpa);
    var i: i64 = 1;
    while (i <= 16) : (i += 1) {
        try t1.set(gpa, Value.int(i), Value.boolean(true));
        try t2.set(gpa, Value.int(i), Value.boolean(true));
    }

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "two_tabs", .num_registers = 6 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    var regs = [_]Value{ Value.nil(), Value.heap(&t1.header), Value.heap(&t2.header), Value.int(3), Value.boolean(true), Value.nil() };
    state.recordInstr(.{ .op = .load_int, .a = 3, .aux = 3 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 3), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 4), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    var n_ne: usize = 0;
    var n_gf: usize = 0;
    var n_aload: usize = 0;
    for (state.rec.instrs.items) |ins| {
        if (ins.op == .ne) n_ne += 1;
        if (ins.op == .guard_false) n_gf += 1;
        if (ins.op == .aload) n_aload += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_ne);
    try testing.expectEqual(@as(usize, 0), n_gf); // no false-direction guard
    try testing.expectEqual(@as(usize, 2), n_aload); // the second read hits the heap
}

test "doc 51 F1: loop-varying keys OBSERVED EQUAL on the observed-same table abort store_fwd_ambiguity" {
    // Different table SSA refs to the same table, keys from two loop-input
    // slots that happen to hold the SAME value at record time: `.may` with an
    // observed collision. Forwarding would pin an unproven per-iteration
    // relation (turnstile); guarding `ne` would be false at record time (DOA).
    // The only sound move is the abort.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 16) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "collided_keys", .num_registers = 6 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r3 and r4 are unrelated loop inputs BOTH holding 3 right now.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.heap(&t.header), Value.int(3), Value.int(3), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 3), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 5), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 2, 4), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(@as(?AbortReason, .store_fwd_ambiguity), state.rec.abort_reason);
}

test "doc 51 F1: loop-varying keys observed different on the observed-same table pin ONLY the key inequality" {
    // Same table through two refs, `.may` keys observed 3 != 4: the key
    // inequality guard alone suffices (a table-equality guard would
    // over-specialize — if the tables differ at runtime the store can't touch
    // the cell regardless, and a spurious key-collision exit is C1-sound).
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 16) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "varying_keys", .num_registers = 6 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.heap(&t.header), Value.int(3), Value.int(4), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 3), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 5), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.get_index, 0, 2, 4), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    var n_ne: usize = 0;
    var n_gf: usize = 0;
    for (state.rec.instrs.items) |ins| {
        if (ins.op == .ne) n_ne += 1;
        if (ins.op == .guard_false) n_gf += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_ne); // the key guard, nothing else
    try testing.expectEqual(@as(usize, 0), n_gf);
}

test "recArraySet sinks a read-steered const store (control channel) instead of aborting" {
    // `if t[i] then t[i]=false else t[i]=true end`: a guard on a read picks the
    // branch, so even a *constant* store could replay differently after a deopt.
    // Store-sinking handles this too — the store sits below the branch guard, so on
    // any side-exit the store has not executed and tier-0 re-runs the read+branch
    // cleanly. The trace records (deferred), no longer aborts.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key. r0 = t[r2] (a packed read).
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(false) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    // Branch on the read (a guard), then store a *constant* false (r3). The store
    // sinks below the branch guard — still recording, store deferred.
    state.recordInstr(Instr.opABC(.jmp_if_true, 0, 0, 0), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_stores.items.len);
}

test "recArraySet sinks multiple RMW stores (Gap C: butterfly shape)" {
    // All reads precede all stores (the FFT butterfly shape): read t[3], read t[4],
    // then store t[3], store t[4]. Both stores are RMW (follow reads) → both defer
    // and sink, so the pending list has 2 entries and neither `astore` is in the stream
    // yet (they flush at commit, in this recorded order). Under Gap B's single-store
    // rule the SECOND store aborted; Gap C records it. See `docs/design/08-...`.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 8 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key 3, r3 = key 4. r0 = t[3], r4 = t[4] (both reads first).
    var regs = [_]Value{
        Value.nil(),         Value.heap(&t.header), Value.int(3), Value.int(4),
        Value.boolean(true), Value.nil(),           Value.nil(),  Value.nil(),
    };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil()); // r0 = t[3]
    state.recordInstr(Instr.opABC(.get_index, 4, 1, 3), winRO(&regs), &proto, 0, Value.nil()); // r4 = t[4]
    try testing.expect(state.isRecording());

    // Tier-0 would have loaded the read values into r0/r4; mirror that so the
    // RMW stores below carry in-lane (boolean) values, not the initial nils.
    regs[0] = Value.boolean(true); // r0 = t[3]
    regs[4] = Value.boolean(true); // r4 = t[4]

    // Now write both back: t[3] = r0, t[4] = r4. Both defer.
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 4), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 2), state.rec.pending_stores.items.len);
    // Recorded order preserved: store #0 → key 3's aref, store #1 → key 4's aref.
    try testing.expect(state.rec.pending_stores.items[0].aref != state.rec.pending_stores.items[1].aref);
    // Neither store is in the stream yet — they flush at commit.
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);
}

test "recArraySet virtual store buffer grows past the legacy four-store cap" {
    // One read arms deferral; eight in-bounds stores then remain buffered. The
    // recorder's `maxrecord` budget is the bound now, rather than an FFT-sized
    // fixed array that rejected otherwise-valid store/load regions.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r1 = table, r2 = key, r3 = bool value. One read to arm deferral.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());

    const store_count = 8;
    var k: i64 = 3;
    while (k < 3 + store_count) : (k += 1) {
        regs[2] = Value.int(k);
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(state.isRecording());
    }
    try testing.expectEqual(@as(usize, store_count), state.rec.pending_stores.items.len);
}

// --- pure-builtin tracing (math.sqrt → guard_builtin/fsqrt, doc 12) --------------

/// A do-nothing `NativeFn` body for recorder unit tests: the recorder never
/// *calls* the native (it inlines `fsqrt` directly), it only reads the heap
/// `Native`'s `pure` tag, so the body is irrelevant.
fn sqrtStub(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    _ = args;
    return Value.nil();
}

test "recPureSqrt: sqrt(float) records guard_builtin, guard_float, fsqrt" {
    const gpa = testing.allocator;
    const nat = try function.Native.create(gpa, &sqrtStub, "math.sqrt");
    defer nat.destroy(gpa);
    nat.recorded = .sqrt;

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r0 = sqrt (callee + result dest), r1 = arg (a float). `call r0, 1, 1`.
    var regs = [_]Value{ Value.heap(&nat.header), Value.float(2.0), Value.nil() };
    state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // a clean record — no abort
    const ops = state.rec.instrs.items;
    // slot_load(callee), guard_builtin, slot_load(arg), guard_float, fsqrt.
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
    try testing.expectEqual(@as(Ref, 0), ops[1].a); // guards the seeded callee ref
    try testing.expectEqual(@as(i32, @intFromEnum(function.RecordedBuiltin.sqrt)), ops[1].aux);
    try testing.expectEqual(IrOp.slot_load, ops[2].op);
    try testing.expectEqual(IrOp.guard_float, ops[3].op);
    try testing.expectEqual(@as(Ref, 2), ops[3].a); // guards the arg ref
    try testing.expectEqual(IrOp.fsqrt, ops[4].op);
    try testing.expectEqual(@as(Ref, 2), ops[4].a); // fsqrt reads the arg ref
    try testing.expectEqual(ObsType.float, ops[4].ty);
    // The call's destination register holds the fsqrt result (ref 4), not the callee.
    try testing.expectEqual(@as(Ref, 4), try state.rec.refOf(0));
}

test "recPureSqrt aborts: bad arity, non-float arg, and a non-pure native" {
    const gpa = testing.allocator;
    const sq = try function.Native.create(gpa, &sqrtStub, "math.sqrt");
    defer sq.destroy(gpa);
    sq.recorded = .sqrt;
    const plain = try function.Native.create(gpa, &sqrtStub, "print");
    defer plain.destroy(gpa); // pure == null

    const Case = struct { callee: *function.Native, arg: Value, b: u16, c: u16, why: AbortReason };
    const cases = [_]Case{
        // sqrt(a, b): two args → no leaf shape.
        .{ .callee = sq, .arg = Value.float(2.0), .b = 2, .c = 1, .why = .cross_frame },
        // x, y = sqrt(a): two results → no leaf shape.
        .{ .callee = sq, .arg = Value.float(2.0), .b = 1, .c = 2, .why = .cross_frame },
        // sqrt(nil): non-numeric arg — no leaf shape (an INT arg records:
        // it promotes via the shared guard_int + cvtsi2sd discipline).
        .{ .callee = sq, .arg = Value.nil(), .b = 1, .c = 1, .why = .bad_type },
        // print(x): a native with no `pure` tag stays the host barrier.
        .{ .callee = plain, .arg = Value.float(2.0), .b = 1, .c = 1, .why = .host_barrier },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&c.callee.header), c.arg, Value.nil() };
        state.recordInstr(Instr.opABC(.call, 0, c.b, c.c), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recFloatUnary: sin/cos(float) record guard_builtin, guard_float, fsin/fcos" {
    const gpa = testing.allocator;
    const Case = struct { name: [:0]const u8, tag: function.RecordedBuiltin, op: IrOp };
    const cases = [_]Case{
        .{ .name = "math.sin", .tag = .sin, .op = .fsin },
        .{ .name = "math.cos", .tag = .cos, .op = .fcos },
    };
    for (cases) |c| {
        const nat = try function.Native.create(gpa, &sqrtStub, c.name);
        defer nat.destroy(gpa);
        nat.recorded = c.tag;

        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

        // r0 = callee (+ result dest), r1 = arg (a float). `call r0, 1, 1`.
        var regs = [_]Value{ Value.heap(&nat.header), Value.float(0.5), Value.nil() };
        state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &proto, 0, Value.nil());

        try testing.expect(state.isRecording()); // a clean record — no abort
        const ops = state.rec.instrs.items;
        // Same 5-op shape as fsqrt: slot_load(callee), guard_builtin,
        // slot_load(arg), guard_float, fsin/fcos.
        try testing.expectEqual(@as(usize, 5), ops.len);
        try testing.expectEqual(IrOp.slot_load, ops[0].op);
        try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
        try testing.expectEqual(@as(i32, @intFromEnum(c.tag)), ops[1].aux);
        try testing.expectEqual(IrOp.guard_float, ops[3].op);
        try testing.expectEqual(c.op, ops[4].op);
        try testing.expectEqual(@as(Ref, 2), ops[4].a); // reads the arg ref
        try testing.expectEqual(ObsType.float, ops[4].ty);
        // The call's destination register holds the result (ref 4).
        try testing.expectEqual(@as(Ref, 4), try state.rec.refOf(0));
    }
}

test "recFloatUnary: sin(int) records guard_int and promotes" {
    const gpa = testing.allocator;
    const nat = try function.Native.create(gpa, &sqrtStub, "math.sin");
    defer nat.destroy(gpa);
    nat.recorded = .sin;

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // sin(k) with an INT k — the partialsums shape (doc 23 D4 note): the
    // observed int is pinned by guard_int and promoted inside the op.
    var regs = [_]Value{ Value.heap(&nat.header), Value.int(3), Value.nil() };
    state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.guard_int, ops[3].op); // int pin, not guard_float
    try testing.expectEqual(IrOp.fsin, ops[4].op);
    try testing.expectEqual(ObsType.float, ops[4].ty); // result is still a float
}

test "recFloatUnary aborts: sin(nil) bad_type, sin(a, b) cross_frame" {
    const gpa = testing.allocator;
    const nat = try function.Native.create(gpa, &sqrtStub, "math.sin");
    defer nat.destroy(gpa);
    nat.recorded = .sin;

    const Case = struct { arg: Value, b: u16, c: u16, why: AbortReason };
    const cases = [_]Case{
        // sin(nil): non-numeric arg — no leaf shape.
        .{ .arg = Value.nil(), .b = 1, .c = 1, .why = .bad_type },
        // sin(a, b): two args → no leaf shape.
        .{ .arg = Value.float(0.5), .b = 2, .c = 1, .why = .cross_frame },
        // x, y = sin(a): two results → no leaf shape.
        .{ .arg = Value.float(0.5), .b = 1, .c = 2, .why = .cross_frame },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&nat.header), c.arg, Value.nil() };
        state.recordInstr(Instr.opABC(.call, 0, c.b, c.c), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

// --- doc 23 arc A: fold-to-konst builtin arms ------------------------------

const gc = @import("gc.zig");

/// Harness for the fold arms: a heap (for `internedLookup`), a builtin native
/// carrying `tag`, and a recording state whose `rec_heap` channel is wired the
/// way the dispatch loop wires it. `constants` become the proto's constant
/// pool (for `load_const`-seeded konst arguments).
const FoldHarness = struct {
    heap: gc.Heap,
    nat: *function.Native,
    state: TraceState,
    proto: Proto,

    fn init(gpa: std.mem.Allocator, tag: function.RecordedBuiltin, constants: []const Value) !FoldHarness {
        var h = FoldHarness{
            .heap = gc.Heap.init(gpa),
            .nat = try function.Native.create(gpa, &sqrtStub, "b"),
            .state = TraceState.init(gpa),
            .proto = Proto{ .code = &.{}, .name = "t", .num_registers = 8, .constants = constants },
        };
        h.nat.recorded = tag;
        return h;
    }

    fn start(self: *FoldHarness, gpa: std.mem.Allocator) !void {
        try self.state.startRecordingForTest(gpa, .{ .proto = &self.proto, .pc = 0, .proto_id = self.proto.id }, self.proto.num_registers);
        self.state.rec_heap = &self.heap;
    }

    fn deinit(self: *FoldHarness, gpa: std.mem.Allocator) void {
        self.state.deinit();
        self.nat.destroy(gpa);
        self.heap.deinit();
    }
};

test "recBType: type(int) folds to the interned 'number' konst under guard_int" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .type, &.{});
    defer h.deinit(gpa);
    const number_s = try h.heap.intern("number");
    try h.start(gpa);

    const objs_before = h.heap.strtab_count;
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.int(7), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());

    try testing.expect(h.state.isRecording());
    // slot_load(callee), guard_builtin(type), slot_load(arg), guard_int, konst.
    const ops = h.state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
    try testing.expectEqual(@as(i32, @intFromEnum(function.RecordedBuiltin.type)), ops[1].aux);
    try testing.expectEqual(IrOp.guard_int, ops[3].op);
    try testing.expectEqual(IrOp.konst, ops[4].op);
    // The dest holds the interned "number" string konst — the exact object.
    const dest = h.state.rec.konstValueOf(try h.state.rec.refOf(0)).?;
    try testing.expectEqual(@intFromPtr(&number_s.header), @intFromPtr(dest.asHeap()));
    // The arc-A invariant: recording created NO guest heap object.
    try testing.expectEqual(objs_before, h.heap.strtab_count);
}

test "recBType: lookup miss aborts .bad_type and allocates nothing (the arc-A invariant)" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .type, &.{});
    defer h.deinit(gpa);
    // "number" is deliberately NOT interned: the fold must abort, never intern.
    try h.start(gpa);
    const objs_before = h.heap.strtab_count;
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.int(7), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(!h.state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, h.state.rec.abort_reason.?);
    try testing.expectEqual(objs_before, h.heap.strtab_count);
}

test "recBType: metatable'd table aborts; plain table folds 'table' under guard_table" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .type, &.{});
    defer h.deinit(gpa);
    _ = try h.heap.intern("table");

    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    const mt = try table_mod.Table.create(gpa);
    defer mt.destroy(gpa);

    // Plain table: records guard_table + konst("table").
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&t.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    try testing.expectEqual(IrOp.guard_table, ops[3].op);

    // Metatable'd table: no guard can express "table WITH metatable" — abort.
    t.metatable = mt;
    var h2 = try FoldHarness.init(gpa, .type, &.{});
    defer h2.deinit(gpa);
    _ = try h2.heap.intern("table");
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.heap(&t.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(!h2.state.isRecording());
    try testing.expectEqual(AbortReason.has_metatable, h2.state.rec.abort_reason.?);
}

test "recBSelect: konst '#' selector folds to the fixed arg count; non-konst aborts" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const hash_s = try heap.intern("#");
    const consts = [_]Value{Value.heap(&hash_s.header)};

    var h = try FoldHarness.init(gpa, .select, &consts);
    defer h.deinit(gpa);
    try h.start(gpa);
    // r1 = konst "#" (load_const), then select('#', a, b, c): call r0, 4, 1.
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&hash_s.header), Value.int(10), Value.int(20), Value.int(30), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(.{ .op = .load_const, .a = 1, .b = 0 }, winRO(&regs), &h.proto, 0, Value.nil());
    h.state.recordInstr(Instr.opABC(.call, 0, 4, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const dest = h.state.rec.konstValueOf(try h.state.rec.refOf(0)).?;
    try testing.expectEqual(@as(i64, 3), dest.asInt());

    // Non-konst selector (a live register holding "#"): abort — the identity
    // would need a runtime guard the vocabulary doesn't have.
    var h2 = try FoldHarness.init(gpa, .select, &consts);
    defer h2.deinit(gpa);
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.heap(&hash_s.header), Value.int(10), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(!h2.state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, h2.state.rec.abort_reason.?);
}

test "recBTonumber: konst string folds via arith.toNumber; observed number passes through" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const hex = try heap.intern("0x1F");
    const consts = [_]Value{Value.heap(&hex.header)};

    // Konst fold: tonumber("0x1F") → konst int 31 (no interning — result is an int).
    var h = try FoldHarness.init(gpa, .tonumber, &consts);
    defer h.deinit(gpa);
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&hex.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(.{ .op = .load_const, .a = 1, .b = 0 }, winRO(&regs), &h.proto, 0, Value.nil());
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    try testing.expectEqual(@as(i64, 31), h.state.rec.konstValueOf(try h.state.rec.refOf(0)).?.asInt());

    // Pass-through: tonumber(x) on an observed int is the identity under guard_int.
    var h2 = try FoldHarness.init(gpa, .tonumber, &.{});
    defer h2.deinit(gpa);
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.int(9), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(h2.state.isRecording());
    const ops = h2.state.rec.instrs.items;
    try testing.expectEqual(IrOp.guard_int, ops[ops.len - 1].op); // arg pin; dest = arg ref
    const arg_ref = try h2.state.rec.refOf(1);
    try testing.expectEqual(arg_ref, try h2.state.rec.refOf(0));
}

test "recBRawequal: NaN pin — float same-ref aborts; table same-ref folds true; konsts fold" {
    const gpa = testing.allocator;

    // Same-ref float: rawequal(x, x) with x float must NOT fold (0/0 ~= 0/0).
    var h = try FoldHarness.init(gpa, .rawequal, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.float(1.5), Value.float(1.5), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    // Seed slots 1 and 2 from the same source slot so both hold the same ref.
    h.state.recordInstr(.{ .op = .move, .a = 2, .b = 1 }, winRO(&regs), &h.proto, 0, Value.nil());
    h.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(!h.state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, h.state.rec.abort_reason.?);

    // Same-ref table folds true under guard_table.
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var h2 = try FoldHarness.init(gpa, .rawequal, &.{});
    defer h2.deinit(gpa);
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.heap(&t.header), Value.heap(&t.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(.{ .op = .move, .a = 2, .b = 1 }, winRO(&regs2), &h2.proto, 0, Value.nil());
    h2.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(h2.state.isRecording());
    try testing.expect(h2.state.rec.konstValueOf(try h2.state.rec.refOf(0)).?.asBool());

    // Konst×konst folds exactly (ints via load_int).
    var h3 = try FoldHarness.init(gpa, .rawequal, &.{});
    defer h3.deinit(gpa);
    try h3.start(gpa);
    var regs3 = [_]Value{ Value.heap(&h3.nat.header), Value.int(5), Value.int(6), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h3.state.recordInstr(.{ .op = .load_int, .a = 1, .aux = 5 }, winRO(&regs3), &h3.proto, 0, Value.nil());
    h3.state.recordInstr(.{ .op = .load_int, .a = 2, .aux = 6 }, winRO(&regs3), &h3.proto, 0, Value.nil());
    h3.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs3), &h3.proto, 0, Value.nil());
    try testing.expect(h3.state.isRecording());
    try testing.expect(!h3.state.rec.konstValueOf(try h3.state.rec.refOf(0)).?.asBool());
}

test "recBRawlen: konst string folds to BYTE length (vs #s cp_len — UTF-8 differential)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const s = try heap.intern("héllo"); // 6 bytes, 5 code points
    const consts = [_]Value{Value.heap(&s.header)};

    var h = try FoldHarness.init(gpa, .rawlen, &consts);
    defer h.deinit(gpa);
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&s.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(.{ .op = .load_const, .a = 1, .b = 0 }, winRO(&regs), &h.proto, 0, Value.nil());
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    // rawlen = String.len = 6 BYTES. (#s is cp_len = 5 — a different quantity;
    // the two must never share an emission. Codex catch #7.)
    try testing.expectEqual(@as(i64, 6), h.state.rec.konstValueOf(try h.state.rec.refOf(0)).?.asInt());
}

test "recBTostring: konst int folds via the shared renderer; konst string aborts (mutable string metatable)" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .tostring, &.{});
    defer h.deinit(gpa);
    const s42 = try h.heap.intern("42");
    try h.start(gpa);
    const objs_before = h.heap.strtab_count;
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.int(42), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(.{ .op = .load_int, .a = 1, .aux = 42 }, winRO(&regs), &h.proto, 0, Value.nil());
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const dest = h.state.rec.konstValueOf(try h.state.rec.refOf(0)).?;
    try testing.expectEqual(@intFromPtr(&s42.header), @intFromPtr(dest.asHeap()));
    try testing.expectEqual(objs_before, h.heap.strtab_count); // no allocation

    // A konst STRING argument does not fold: the shared string metatable is
    // mutable at runtime, so a `__tostring` could appear with no guard for it.
    const hs = try h.heap.intern("x");
    const consts = [_]Value{Value.heap(&hs.header)};
    var h2 = try FoldHarness.init(gpa, .tostring, &consts);
    defer h2.deinit(gpa);
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.heap(&hs.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(.{ .op = .load_const, .a = 1, .b = 0 }, winRO(&regs2), &h2.proto, 0, Value.nil());
    h2.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(!h2.state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, h2.state.rec.abort_reason.?);
}

test "recBTostring: scalar non-konst records guard_gc + tostr_int/tostr_num (doc 24 c2)" {
    const gpa = testing.allocator;
    // Int argument: the arg's slot_load resolves FIRST (refOf before the callee
    // guard), then the callee pin, the type guard, and the lazily-placed
    // guard_gc immediately before the trace's first `.alloc` op.
    var h = try FoldHarness.init(gpa, .tostring, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    const objs_before = h.heap.strtab_count;
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.int(7), Value.heap(&h.nat.header), Value.int(9), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 6), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op); // arg (slot 1)
    try testing.expectEqual(IrOp.slot_load, ops[1].op); // callee (slot 0)
    try testing.expectEqual(IrOp.guard_builtin, ops[2].op);
    try testing.expectEqual(@as(i32, @intFromEnum(function.RecordedBuiltin.tostring)), ops[2].aux);
    try testing.expectEqual(IrOp.guard_int, ops[3].op);
    try testing.expectEqual(IrOp.guard_gc, ops[4].op);
    try testing.expectEqual(IrOp.tostr_int, ops[5].op);
    try testing.expectEqual(@as(trace.Ref, 0), ops[5].a); // the arg slot_load
    try testing.expectEqual(trace.ObsType.heap, ops[5].ty);
    // The recorder bookkeeping behind commit-time stamping.
    try testing.expectEqual(@as(u32, 1), h.state.rec.alloc_count);
    try testing.expectEqual(@as(?trace.Ref, 4), h.state.rec.guard_gc_ref);
    // Recording emitted IR only — no guest allocation (arc-A invariant holds
    // for the RECORDER even in arc B; allocation happens at EXECUTION).
    try testing.expectEqual(objs_before, h.heap.strtab_count);
    // The dest reg now maps to the tostr result.
    try testing.expectEqual(@as(trace.Ref, 5), try h.state.rec.refOf(0));

    // A SECOND allocating call in the same recording (fresh callee/arg slots so
    // the first call's dest remap does not shadow the callee): guard_gc is
    // emitted once per trace, but the bound counts every `.alloc` op.
    h.state.recordInstr(Instr.opABC(.call, 2, 1, 1), winRO(&regs), &h.proto, 1, Value.nil());
    try testing.expect(h.state.isRecording());
    try testing.expectEqual(@as(u32, 2), h.state.rec.alloc_count);
    var n_guard_gc: usize = 0;
    for (h.state.rec.instrs.items) |ins| {
        if (ins.op == .guard_gc) n_guard_gc += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_guard_gc);

    // Float argument: guard_float + tostr_num.
    var h2 = try FoldHarness.init(gpa, .tostring, &.{});
    defer h2.deinit(gpa);
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.float(0.5), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(h2.state.isRecording());
    const ops2 = h2.state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 6), ops2.len);
    try testing.expectEqual(IrOp.guard_float, ops2[3].op);
    try testing.expectEqual(IrOp.guard_gc, ops2[4].op);
    try testing.expectEqual(IrOp.tostr_num, ops2[5].op);
}

test "len opcode: #tostring(i) is a PROVEN string — slen with no guard_string (doc 24 c2)" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .tostring, &.{});
    defer h.deinit(gpa);
    const s7 = try h.heap.intern("7"); // what tier-0 materialized for the dest reg
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.int(7), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    // Tier-0 has executed the call by the time `.len` records: reg 0 holds the
    // rendered string. The recorder's reg map holds the tostr ref for it.
    regs[0] = Value.heap(&s7.header);
    h.state.recordInstr(Instr.opABC(.len, 3, 0, 0), winRO(&regs), &h.proto, 1, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    // ...guard_gc(4), tostr_int(5), slen(6) — and NO guard_string anywhere: the
    // producer proves the type.
    try testing.expectEqual(@as(usize, 7), ops.len);
    try testing.expectEqual(IrOp.slen, ops[6].op);
    try testing.expectEqual(@as(trace.Ref, 5), ops[6].a);
    try testing.expectEqual(trace.ObsType.int, ops[6].ty);
    for (ops) |ins| try testing.expect(ins.op != .guard_string);
}

test "len opcode: #s of an OBSERVED string records guard_string + slen (doc 24 c2)" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .tostring, &.{});
    defer h.deinit(gpa);
    const s = try h.heap.intern("héllo"); // 6 bytes, 5 code points — slen is cp_len
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&s.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.len, 2, 1, 0), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 3), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_string, ops[1].op);
    try testing.expectEqual(@as(trace.Ref, 0), ops[1].a);
    try testing.expectEqual(IrOp.slen, ops[2].op);
    try testing.expectEqual(@as(trace.Ref, 0), ops[2].a);
    // An observed `#s` allocates nothing: no guard_gc, alloc bound stays 0.
    try testing.expectEqual(@as(u32, 0), h.state.rec.alloc_count);
    for (ops) |ins| try testing.expect(ins.op != .guard_gc);
}

test "recBSSub: sub(s, lo, hi) records guard_string + guard_ints + guard_gc + ssub (doc 24 c3)" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .sub, &.{});
    defer h.deinit(gpa);
    const s = try h.heap.intern("abcdefgh");
    try h.start(gpa);
    const objs_before = h.heap.strtab_count;
    // call sub(s, 2, 5): callee at r0, args r1..r3, one result.
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&s.header), Value.int(2), Value.int(5), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 3, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    // callee slot_load, guard_builtin, s slot_load, guard_string, lo slot_load,
    // guard_int, hi slot_load, guard_int, guard_gc (lazy, before the first
    // `.alloc`), ssub.
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
    try testing.expectEqual(@as(i32, @intFromEnum(function.RecordedBuiltin.sub)), ops[1].aux);
    try testing.expectEqual(IrOp.slot_load, ops[2].op);
    try testing.expectEqual(IrOp.guard_string, ops[3].op);
    try testing.expectEqual(@as(Ref, 2), ops[3].a);
    try testing.expectEqual(IrOp.guard_int, ops[5].op);
    try testing.expectEqual(IrOp.guard_int, ops[7].op);
    try testing.expectEqual(IrOp.guard_gc, ops[8].op);
    try testing.expectEqual(IrOp.ssub, ops[9].op);
    // The one three-operand op (codex #4): string in a, start in b, end in aux.
    try testing.expectEqual(@as(Ref, 2), ops[9].a);
    try testing.expectEqual(@as(Ref, 4), ops[9].b);
    try testing.expectEqual(@as(i32, 6), ops[9].aux);
    try testing.expectEqual(trace.ObsType.heap, ops[9].ty);
    try testing.expectEqual(@as(u32, 1), h.state.rec.alloc_count);
    // Recording emitted IR only — no guest allocation.
    try testing.expectEqual(objs_before, h.heap.strtab_count);
    try testing.expectEqual(@as(Ref, 9), try h.state.rec.refOf(0));

    // 2-arg shape sub(s, 2): the default end records as a konst(-1) — the same
    // value tier-0 defaults to — so both shapes share one op.
    var h2 = try FoldHarness.init(gpa, .sub, &.{});
    defer h2.deinit(gpa);
    const s2 = try h2.heap.intern("abcdefgh");
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.heap(&s2.header), Value.int(2), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h2.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(h2.state.isRecording());
    const ops2 = h2.state.rec.instrs.items;
    // ..., konst(-1)@6, guard_gc@7, ssub@8 (aux = the konst ref).
    try testing.expectEqual(@as(usize, 9), ops2.len);
    try testing.expectEqual(IrOp.konst, ops2[6].op);
    try testing.expectEqual(Value.int(-1), h2.state.rec.consts.items[@intCast(ops2[6].aux)]);
    try testing.expectEqual(IrOp.guard_gc, ops2[7].op);
    try testing.expectEqual(IrOp.ssub, ops2[8].op);
    try testing.expectEqual(@as(i32, 6), ops2[8].aux);
}

test "recBSRev: reverse(s) records guard_string + srev; its result is PROVEN for #" {
    const gpa = testing.allocator;
    var h = try FoldHarness.init(gpa, .reverse, &.{});
    defer h.deinit(gpa);
    const s = try h.heap.intern("héllo"); // 6 bytes, 5 cps
    const rev = try h.heap.intern("olléh"); // what tier-0 materialized for the dest
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&s.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    // callee slot_load, guard_builtin, s slot_load, guard_string, guard_gc, srev.
    try testing.expectEqual(@as(usize, 6), ops.len);
    try testing.expectEqual(IrOp.guard_string, ops[3].op);
    try testing.expectEqual(IrOp.guard_gc, ops[4].op);
    try testing.expectEqual(IrOp.srev, ops[5].op);
    try testing.expectEqual(@as(Ref, 2), ops[5].a);
    try testing.expectEqual(trace.ObsType.heap, ops[5].ty);

    // `#` of the srev result: the producer PROVES stringness (isProvenStringRef
    // covers the whole snew class) — slen with no second guard_string.
    regs[0] = Value.heap(&rev.header); // tier-0 has executed the call by now
    h.state.recordInstr(Instr.opABC(.len, 2, 0, 0), winRO(&regs), &h.proto, 1, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops_after = h.state.rec.instrs.items;
    try testing.expectEqual(IrOp.slen, ops_after[ops_after.len - 1].op);
    try testing.expectEqual(@as(Ref, 5), ops_after[ops_after.len - 1].a);
    var n_gs: usize = 0;
    for (ops_after) |ins| {
        if (ins.op == .guard_string) n_gs += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_gs); // only the observed-input pin
}

test "recBSChar1/recBSRep2: char(c) and rep(s, n) record; both are one guard_gc (doc 24 c3)" {
    const gpa = testing.allocator;
    // char(c): guard_int on the codepoint, then schar1 (range failure is a
    // side-exit at run time, not a record-time concern).
    var h = try FoldHarness.init(gpa, .char, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.int(65), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    // callee slot_load, guard_builtin, c slot_load, guard_int, guard_gc, schar1.
    try testing.expectEqual(@as(usize, 6), ops.len);
    try testing.expectEqual(IrOp.guard_int, ops[3].op);
    try testing.expectEqual(IrOp.guard_gc, ops[4].op);
    try testing.expectEqual(IrOp.schar1, ops[5].op);
    try testing.expectEqual(@as(Ref, 2), ops[5].a);

    // rep(s, n): guard_string + guard_int, then srep2 — and the SECOND alloc op
    // in a trace shares the one guard_gc (the bound counts both).
    var h2 = try FoldHarness.init(gpa, .rep, &.{});
    defer h2.deinit(gpa);
    const s = try h2.heap.intern("ab");
    try h2.start(gpa);
    var regs2 = [_]Value{ Value.heap(&h2.nat.header), Value.heap(&s.header), Value.int(3), Value.heap(&h2.nat.header), Value.heap(&s.header), Value.int(2), Value.nil(), Value.nil() };
    h2.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs2), &h2.proto, 0, Value.nil());
    try testing.expect(h2.state.isRecording());
    const ops2 = h2.state.rec.instrs.items;
    // callee, guard_builtin, s, guard_string, n, guard_int, guard_gc, srep2.
    try testing.expectEqual(@as(usize, 8), ops2.len);
    try testing.expectEqual(IrOp.guard_gc, ops2[6].op);
    try testing.expectEqual(IrOp.srep2, ops2[7].op);
    try testing.expectEqual(@as(Ref, 2), ops2[7].a);
    try testing.expectEqual(@as(Ref, 4), ops2[7].b);
    // Second rep call at a fresh callee/arg base: no second guard_gc, bound = 2.
    h2.state.recordInstr(Instr.opABC(.call, 3, 2, 1), winRO(&regs2), &h2.proto, 1, Value.nil());
    try testing.expect(h2.state.isRecording());
    try testing.expectEqual(@as(u32, 2), h2.state.rec.alloc_count);
    var n_gc: usize = 0;
    for (h2.state.rec.instrs.items) |ins| {
        if (ins.op == .guard_gc) n_gc += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_gc);
}

test "snew abort matrix: variadic char, 3-arg rep, non-string s, float count (doc 24 c3)" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    const Case = struct { tag: function.RecordedBuiltin, args: [3]Value, b: u16, why: AbortReason };
    var heap = @import("gc.zig").Heap.init(gpa);
    defer heap.deinit();
    const s = try heap.intern("ab");
    const cases = [_]Case{
        // char(a, b): the variadic shape — IrInstr carries no operand vector
        // (codex #4), so only 1-arg records.
        .{ .tag = .char, .args = .{ Value.int(65), Value.int(66), Value.nil() }, .b = 2, .why = .cross_frame },
        // rep(s, n, sep): the separator shape stays tier-0 (pinned arity).
        .{ .tag = .rep, .args = .{ Value.heap(&s.header), Value.int(2), Value.heap(&s.header) }, .b = 3, .why = .cross_frame },
        // sub(t, 1, 2): non-string subject — tier-0 owns coercions + raising.
        .{ .tag = .sub, .args = .{ Value.heap(&t.header), Value.int(1), Value.int(2) }, .b = 3, .why = .bad_type },
        // rep(s, 1.5): float count — tier-0 owns the integral-float coercion.
        .{ .tag = .rep, .args = .{ Value.heap(&s.header), Value.float(1.5), Value.nil() }, .b = 2, .why = .bad_type },
        // reverse(42): non-string subject.
        .{ .tag = .reverse, .args = .{ Value.int(42), Value.nil(), Value.nil() }, .b = 1, .why = .bad_type },
    };
    for (cases) |c| {
        var h = try FoldHarness.init(gpa, c.tag, &.{});
        defer h.deinit(gpa);
        try h.start(gpa);
        var regs = [_]Value{ Value.heap(&h.nat.header), c.args[0], c.args[1], c.args[2], Value.nil(), Value.nil(), Value.nil(), Value.nil() };
        h.state.recordInstr(Instr.opABC(.call, 0, c.b, 1), winRO(&regs), &h.proto, 0, Value.nil());
        try testing.expect(!h.state.isRecording());
        try testing.expectEqual(c.why, h.state.rec.abort_reason.?);
        // An aborted snew record leaves no allocation accounting behind.
        try testing.expectEqual(@as(u32, 0), h.state.rec.alloc_count);
    }
}

test "recBRawget: int key reuses the array-get shape under guard_builtin" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * 10));

    var h = try FoldHarness.init(gpa, .rawget, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    // rawget(t, 3): callee r0, table r1, key r2 → call r0, 2, 1.
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&t.header), Value.int(3), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 2, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    // slot_load(callee), guard_builtin, then the get_index sequence verbatim:
    // slot_load(tab), guard_table, guard_lane, slot_load(key), guard_int,
    // aref, guard_bounds, guard_present, aload.
    try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
    try testing.expectEqual(@as(i32, @intFromEnum(function.RecordedBuiltin.rawget)), ops[1].aux);
    var found: [4]bool = @splat(false);
    for (ops) |ins| switch (ins.op) {
        .guard_table => found[0] = true,
        .aref => found[1] = true,
        .guard_present => found[2] = true,
        .aload => found[3] = true,
        else => {},
    };
    for (found) |g| try testing.expect(g);
    // The dest register holds the aload result.
    try testing.expectEqual(IrOp.aload, ops[@intCast(try h.state.rec.refOf(0))].op);
}

test "recBRawset: int key reuses the array-set shape; dest is the table ref" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * 10));

    var h = try FoldHarness.init(gpa, .rawset, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    // rawset(t, 3, 99): callee r0, args r1..r3 → call r0, 3, 1.
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&t.header), Value.int(3), Value.int(99), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 3, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
    // In-bounds pure-write store (no prior load) emits astore inline.
    var saw_store = false;
    for (ops) |ins| {
        if (ins.op == .astore) saw_store = true;
    }
    try testing.expect(saw_store);
    // rawset returns the table: the dest ref is the table's slot_load.
    const dest_ref = try h.state.rec.refOf(0);
    try testing.expectEqual(dest_ref, try h.state.rec.refOf(1));
}

test "recBRawset: statement form (c == 0, the common case) records the store, defines no dest" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * 10));

    var h = try FoldHarness.init(gpa, .rawset, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&t.header), Value.int(3), Value.int(99), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 3, 0), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    var saw_store = false;
    for (h.state.rec.instrs.items) |ins| {
        if (ins.op == .astore) saw_store = true;
    }
    try testing.expect(saw_store);
    // No result: slot 0 keeps its callee ref (the slot_load at 0), not the table.
    try testing.expectEqual(@as(Ref, 0), try h.state.rec.refOf(0));
}

test "recBRawget: wrong arity and non-table abort without recording garbage" {
    const gpa = testing.allocator;
    const Case = struct { b: u16, arg1: Value, why: AbortReason };
    const cases = [_]Case{
        .{ .b = 1, .arg1 = Value.int(1), .why = .cross_frame }, // rawget(t) — one arg
        .{ .b = 2, .arg1 = Value.int(1), .why = .bad_type }, // rawget(1, k) — non-table
    };
    for (cases) |c| {
        var h = try FoldHarness.init(gpa, .rawget, &.{});
        defer h.deinit(gpa);
        try h.start(gpa);
        var regs = [_]Value{ Value.heap(&h.nat.header), c.arg1, Value.int(1), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
        h.state.recordInstr(Instr.opABC(.call, 0, c.b, 1), winRO(&regs), &h.proto, 0, Value.nil());
        try testing.expect(!h.state.isRecording());
        try testing.expectEqual(c.why, h.state.rec.abort_reason.?);
    }
}

test "len opcode: #t on a bitmap-lane table records guard_table + alen" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * 10));
    try testing.expect(t.array.lane.scalarPresenceLane());

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.nil() };
    state.recordInstr(.{ .op = .len, .a = 0, .b = 1 }, winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // slot_load(table), guard_table, alen.
    try testing.expectEqual(@as(usize, 3), ops.len);
    try testing.expectEqual(IrOp.guard_table, ops[1].op);
    try testing.expectEqual(IrOp.alen, ops[2].op);
    try testing.expectEqual(ObsType.int, ops[2].ty);
    try testing.expectEqual(@as(Ref, 2), try state.rec.refOf(0));
}

test "len opcode: alen abort matrix — in-band lane, hash border, metatable" {
    const gpa = testing.allocator;

    // Boolean lane: presence is in-band, the fast case can't certify the border.
    {
        const t = try table_mod.Table.create(gpa);
        defer t.destroy(gpa);
        var i: i64 = 1;
        while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
        try testing.expectEqual(arr.Lane.boolean, t.array.lane);
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.nil() };
        state.recordInstr(.{ .op = .len, .a = 0, .b = 1 }, winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
    }

    // Non-empty hash part: the border may continue past the array — abort.
    {
        const t = try table_mod.Table.create(gpa);
        defer t.destroy(gpa);
        var i: i64 = 1;
        while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i));
        try t.set(gpa, Value.int(1000), Value.int(1)); // hash-part key
        try testing.expect(t.hash.count() != 0);
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.nil() };
        state.recordInstr(.{ .op = .len, .a = 0, .b = 1 }, winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
    }

    // Metatable: `__len` could fire — abort .has_metatable.
    {
        const t = try table_mod.Table.create(gpa);
        defer t.destroy(gpa);
        const mt = try table_mod.Table.create(gpa);
        defer mt.destroy(gpa);
        var i: i64 = 1;
        while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i));
        t.metatable = mt;
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.nil() };
        state.recordInstr(.{ .op = .len, .a = 0, .b = 1 }, winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
}

test "alen records past a pending sunk store (doc 24 D7 refinement)" {
    // The arc-A conservative abort is gone: sunk stores are in-bounds only
    // (asize invariant), never clear presence, and alen is itself a
    // side-exiting op below which the stores flush — so the stale pre-store
    // read either matches tier-0's answer (asize-only) or side-exits cleanly.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i));
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.int(9) };
    // A read arms deferral, then the RMW store sinks into pending_stores.
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expect(state.rec.pending_stores.items.len == 1);
    state.recordInstr(.{ .op = .len, .a = 0, .b = 1 }, winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording()); // records now — no abort
    const ops = state.rec.instrs.items;
    // The alen sits in the stream; the sunk astore is still pending (flushes
    // at commit, below it).
    try testing.expectEqual(IrOp.alen, ops[ops.len - 1].op);
    try testing.expectEqual(@as(usize, 1), state.rec.pending_stores.items.len);
}

test "recBMType: int folds 'integer', float folds 'float', table folds nil" {
    const gpa = testing.allocator;
    // Pre-intern the two result strings the way steady-state tier-0 would have.
    var h = try FoldHarness.init(gpa, .mtype, &.{});
    defer h.deinit(gpa);
    _ = try h.heap.internValue("integer");
    _ = try h.heap.internValue("float");
    try h.start(gpa);

    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);

    const Case = struct { arg: Value, want_nil: bool, want: []const u8 };
    const cases = [_]Case{
        .{ .arg = Value.int(7), .want_nil = false, .want = "integer" },
        .{ .arg = Value.float(0.5), .want_nil = false, .want = "float" },
        .{ .arg = Value.heap(&t.header), .want_nil = true, .want = "" },
    };
    for (cases) |c| {
        var st = TraceState.init(gpa);
        defer st.deinit();
        st.rec_heap = &h.heap;
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try st.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&h.nat.header), c.arg, Value.nil() };
        const before = h.heap.strtab_count;
        st.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(st.isRecording());
        try testing.expectEqual(before, h.heap.strtab_count); // no allocation
        const dest = st.rec.konstValueOf(try st.rec.refOf(0)).?;
        if (c.want_nil) {
            try testing.expect(dest.isNil());
        } else {
            const s = @import("string.zig").String.fromHeader(dest.asHeap());
            try testing.expectEqualStrings(c.want, s.bytes());
        }
    }
}

test "recBRawlen: observed table records guard_builtin + guard_table + alen" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i));

    var h = try FoldHarness.init(gpa, .rawlen, &.{});
    defer h.deinit(gpa);
    try h.start(gpa);
    var regs = [_]Value{ Value.heap(&h.nat.header), Value.heap(&t.header), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    h.state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &h.proto, 0, Value.nil());
    try testing.expect(h.state.isRecording());
    const ops = h.state.rec.instrs.items;
    // slot_load(callee), guard_builtin, slot_load(tab), guard_table, alen.
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.guard_builtin, ops[1].op);
    try testing.expectEqual(IrOp.alen, ops[4].op);
    try testing.expectEqual(@as(Ref, 4), try h.state.rec.refOf(0));
}

test "alen fast case is exactly Table.length() under its premises (differential)" {
    const gpa = testing.allocator;
    // Shapes: dense int (i8), wide int (i64), f64, u8, singleton, and post-append.
    const Fill = struct { count: i64, mul: i64, float: bool };
    const shapes = [_]Fill{
        .{ .count = 1, .mul = 1, .float = false },
        .{ .count = 8, .mul = 10, .float = false },
        .{ .count = 100, .mul = 100000, .float = false }, // i64-ish lane
        .{ .count = 33, .mul = 1, .float = true }, // f64 lane
    };
    for (shapes) |sh| {
        const t = try table_mod.Table.create(gpa);
        defer t.destroy(gpa);
        var i: i64 = 1;
        while (i <= sh.count) : (i += 1) {
            const v = if (sh.float) Value.float(@as(f64, @floatFromInt(i)) * 1.5) else Value.int(i * sh.mul);
            try t.set(gpa, Value.int(i), v);
        }
        // Premises of the fast case must hold for the shape to be comparable.
        if (t.hash.count() != 0 or !t.array.lane.scalarPresenceLane()) continue;
        const asize = t.array.asize;
        if (asize > 1 and !t.array.isPresent(asize - 1)) continue;
        const fast: i64 = if (asize == 0) 0 else @intCast(asize - 1);
        try testing.expectEqual(t.length(), fast);
    }
}

test "recEq: konst×konst folds to a bool konst (the type(x)=='number' collapse)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.int(5), Value.int(5), Value.nil() };
    state.recordInstr(.{ .op = .load_int, .a = 1, .aux = 5 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(.{ .op = .load_int, .a = 2, .aux = 5 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.eq, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    // No guards, no eq op — just the two konst loads and the folded bool.
    try testing.expect(state.rec.konstValueOf(try state.rec.refOf(0)).?.asBool());
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op == .konst);
}

test "recEq: observed number vs konst nil pins the number and folds false (the `x == nil` idiom)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    // r1 = observed int (a loaded slot), r2 = nil via load_nil (a konst).
    var regs = [_]Value{ Value.nil(), Value.int(7), Value.nil(), Value.nil() };
    state.recordInstr(.{ .op = .load_nil, .a = 2 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.eq, 0, 1, 2), winRO(&regs), &proto, 1, Value.nil());
    try testing.expect(state.isRecording());
    // Expected IR: konst(nil), slot_load(r1), guard_int(r1), konst(false).
    // Cross-type Lua equality is false, and the guard is what keeps the fold
    // honest — an iteration where r1 stops being an int side-exits.
    const ops = state.rec.instrs.items;
    try testing.expectEqual(@as(usize, 4), ops.len);
    try testing.expectEqual(IrOp.konst, ops[0].op);
    try testing.expectEqual(IrOp.slot_load, ops[1].op);
    try testing.expectEqual(IrOp.guard_int, ops[2].op);
    try testing.expectEqual(IrOp.konst, ops[3].op);
    const rres = state.rec.konstValueOf(try state.rec.refOf(0)).?;
    try testing.expect(!rres.asBool());
}

test "recEq: observed float vs konst nil folds under guard_float; ne folds true; swapped sides fold" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 6 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.float(2.5), Value.nil(), Value.int(9), Value.nil(), Value.nil() };
    state.recordInstr(.{ .op = .load_nil, .a = 2 }, winRO(&regs), &proto, 0, Value.nil());
    // r0 = (float r1 ~= nil r2) → guard_float(r1), konst true.
    state.recordInstr(Instr.opABC(.ne, 0, 1, 2), winRO(&regs), &proto, 1, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expect(state.rec.konstValueOf(try state.rec.refOf(0)).?.asBool());
    var saw_guard_float = false;
    for (state.rec.instrs.items) |ins| {
        if (ins.op == .guard_float) saw_guard_float = true;
    }
    try testing.expect(saw_guard_float);
    // r4 = (nil r2 == int r3) — konst on the LEFT, observed number on the
    // right: same fold, guarding the c side.
    state.recordInstr(Instr.opABC(.eq, 4, 2, 3), winRO(&regs), &proto, 2, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expect(!state.rec.konstValueOf(try state.rec.refOf(4)).?.asBool());
}

test "recEq: doc 57 — an observed bool input vs konst nil pins the input and folds" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    // r1 = observed bool (an untyped slot_load). Doc 57 value-specializes it
    // (`guard_is_true`), so both sides are konsts and the compare folds away.
    var regs = [_]Value{ Value.nil(), Value.boolean(true), Value.nil(), Value.nil() };
    state.recordInstr(.{ .op = .load_nil, .a = 2 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.eq, 0, 1, 2), winRO(&regs), &proto, 1, Value.nil());
    try testing.expect(state.isRecording());
    var pins: usize = 0;
    for (state.rec.instrs.items) |ins| {
        try testing.expect(ins.op != .eq);
        if (ins.op == .guard_is_true) pins += 1;
    }
    try testing.expectEqual(@as(usize, 1), pins);
    // r0 now holds the folded konst `false`.
    const r0 = state.rec.reg_map[0].ref;
    try testing.expect(state.rec.konstValueOf(r0).?.eql(Value.boolean(false)));
}

test "recEq: an observed unproven heap value vs konst nil still aborts bad_type" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);
    // r1 = observed table: no pin covers a heap value's type here (only the
    // numeric guards and doc 57's nil/bool pins do), so this stays out of scope.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.nil(), Value.nil() };
    state.recordInstr(.{ .op = .load_nil, .a = 2 }, winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.eq, 0, 1, 2), winRO(&regs), &proto, 1, Value.nil());
    try testing.expect(!state.isRecording());
}

test "per-guard PC recording: guard_int aux carries the bytecode PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A 3-register frame: r0=r1+r2, both ints, at PC 42.
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    var regs = [_]Value{ Value.nil(), Value.int(10), Value.int(20) };
    state.recordInstr(Instr.opABC(.add, 0, 1, 2), winRO(&regs), &proto, 42, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // Expected: slot_load(r1), slot_load(r2), guard_int(r1), guard_int(r2), add
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.slot_load, ops[1].op);
    try testing.expectEqual(IrOp.guard_int, ops[2].op);
    try testing.expectEqual(@as(i32, 42), ops[2].aux); // PC stored in aux
    try testing.expectEqual(IrOp.guard_int, ops[3].op);
    try testing.expectEqual(@as(i32, 42), ops[3].aux); // PC stored in aux
    try testing.expectEqual(IrOp.add, ops[4].op);
    try testing.expectEqual(@as(i32, 0), ops[4].aux); // add doesn't use aux
}

test "per-guard PC recording: guard_true aux carries the branch PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    try state.startRecordingForTest(gpa, .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, proto.num_registers);

    // r0 is truthy (int 1), so jmp_if_false emits guard_true at PC 7.
    var regs = [_]Value{ Value.int(1), Value.nil() };
    state.recordInstr(Instr.opABC(.jmp_if_false, 0, 0, 0), winRO(&regs), &proto, 7, Value.nil());

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // Expected: slot_load(r0), guard_true
    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_true, ops[1].op);
    try testing.expectEqual(@as(i32, 7), ops[1].aux); // PC stored in aux
}
