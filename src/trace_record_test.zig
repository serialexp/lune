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
const MAX_PENDING_STORES = trace.MAX_PENDING_STORES;
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try st2.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    const M: u32 = 11;
    st2.rec.cur_pc = M + 1;
    inline for (.{ IrOp.guard_number, IrOp.int_of_float }) |op| {
        const ref = try st2.emit(.{ .op = op, .a = 0 });
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
        .{ .tab = Value.heap(&t.header), .key = Value.int(1), .why = .bad_type }, // hole at 1
        .{ .tab = Value.heap(&t.header), .key = Value.int(9999), .why = .bad_type }, // out of bounds
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
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

test "recArrayGet aborts on a .value-lane non-table element — nyi scope cut" {
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    // Access index 2 (the boolean) — non-table element in .value lane → nyi_opcode.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(2) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.nyi_opcode, state.rec.abort_reason.?);
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
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 7 }, proto.num_registers);
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 7 }, proto.num_registers);
    state.recordInstr(Instr.opAB(.new_table, 0, 0), winRO(&regs), &proto, 3, Value.nil());
    try testing.expectEqual(@as(usize, 2), state.abort_log.items.len);

    // With the flag off, nothing is logged.
    var quiet = TraceState.init(gpa);
    defer quiet.deinit();
    try quiet.rec.reset(gpa, .{ .proto = &proto, .pc = 7 }, proto.num_registers);
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
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index in-bounds in-lane store.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
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
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (3), r0 = value (false); `set_index a=1 b=2 c=0` → t[3]=false.
    var regs = [_]Value{ Value.boolean(false), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // clean record — no abort
    const ops = state.rec.instrs.items;
    // value resolved first (for the C1 taint scan): slot_load(value), then
    // slot_load(table), guard_table, guard_lane, slot_load(key), guard_int, aref,
    // guard_bounds, guard_fits, astore. No guard_present — astore creates presence.
    // guard_fits is now emitted for the bool lane too (value-stability: a non-bool
    // free-variable store side-exits to tier-0 instead of tripping the oracle).
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op); // value (r0)
    try testing.expectEqual(IrOp.slot_load, ops[1].op); // table (r1)
    try testing.expectEqual(IrOp.guard_table, ops[2].op);
    try testing.expectEqual(IrOp.guard_lane, ops[3].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[3].aux);
    try testing.expectEqual(IrOp.slot_load, ops[4].op); // key (r2)
    try testing.expectEqual(IrOp.guard_int, ops[5].op);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(@as(Ref, 1), ops[6].a); // table ref
    try testing.expectEqual(@as(Ref, 4), ops[6].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[7].op);
    try testing.expectEqual(@as(Ref, 6), ops[7].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[8].op);
    try testing.expectEqual(@as(Ref, 0), ops[8].a); // range-checks the false slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[8].aux);
    try testing.expectEqual(IrOp.astore, ops[9].op);
    try testing.expectEqual(@as(Ref, 6), ops[9].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 0), ops[9].b); // value = the false slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[9].aux);
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (asize), r0 = value (true); `set_index a=1 b=2 c=0`.
    var regs = [_]Value{ Value.boolean(true), Value.heap(&t.header), Value.int(append_key) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // clean record — the append path, no abort
    const ops = state.rec.instrs.items;
    // Same prologue as the in-bounds store, but guard_bounds → guard_append and
    // astore → astore_append: slot_load(value), slot_load(table), guard_table,
    // guard_lane, slot_load(key), guard_int, aref, guard_append, guard_fits,
    // astore_append.
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(IrOp.guard_append, ops[7].op);
    try testing.expectEqual(@as(Ref, 6), ops[7].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[8].op);
    try testing.expectEqual(IrOp.astore_append, ops[9].op);
    try testing.expectEqual(@as(Ref, 6), ops[9].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 0), ops[9].b); // value = the true slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[9].aux);

    // The recorder must NOT have mutated the table — recording is side-effect free.
    try testing.expectEqual(len_before, t.array.asize);
}

test "recArraySet aborts: non-table, non-int key, OOB, out-of-lane value, .value lane" {
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
        // .value-lane array — deferred scope cut.
        .{ .tab = Value.heap(&tv.header), .key = Value.int(1), .val = Value.int(20), .why = .nyi_opcode },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try testing.expectEqual(@as(usize, 1), state.rec.pending_store_count);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.boolean)), state.rec.pending_stores[0].lane_ord);
    // The store is deferred — NOT yet in the instruction stream (it lands at commit).
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);

    // A subsequent packed read must abort: the sunk store has to be the LAST array
    // access (else on-trace store-then-read would diverge from tier-0 replay).
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key. r0 = t[r2] (a packed read).
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(false) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    // Branch on the read (a guard), then store a *constant* false (r3). The store
    // sinks below the branch guard — still recording, store deferred.
    state.recordInstr(Instr.opABC(.jmp_if_true, 0, 0, 0), winRO(&regs), &proto, 0, Value.nil());
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_store_count);
}

test "recArraySet sinks multiple RMW stores (Gap C: butterfly shape)" {
    // All reads precede all stores (the FFT butterfly shape): read t[3], read t[4],
    // then store t[3], store t[4]. Both stores are RMW (follow reads) → both defer
    // and sink, so `pending_store_count == 2` and neither `astore` is in the stream
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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try testing.expectEqual(@as(usize, 2), state.rec.pending_store_count);
    // Recorded order preserved: store #0 → key 3's aref, store #1 → key 4's aref.
    try testing.expect(state.rec.pending_stores[0].aref != state.rec.pending_stores[1].aref);
    // Neither store is in the stream yet — they flush at commit.
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);
}

test "recArraySet aborts when sunk stores exceed MAX_PENDING_STORES" {
    // One read arms deferral; then MAX_PENDING_STORES in-bounds RMW stores defer, and
    // the next one exceeds the cap and aborts cleanly (no regression — it aborted
    // under Gap B too, just one store sooner). Guards the bounded buffer.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key, r3 = bool value. One read to arm deferral.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(state.isRecording());

    // MAX_PENDING_STORES deferred stores (distinct in-bounds keys 3..3+MAX-1) record.
    var k: i64 = 3;
    while (k < 3 + @as(i64, MAX_PENDING_STORES)) : (k += 1) {
        regs[2] = Value.int(k);
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(state.isRecording());
    }
    try testing.expectEqual(@as(usize, MAX_PENDING_STORES), state.rec.pending_store_count);

    // One more store exceeds the cap → abort.
    regs[2] = Value.int(3 + @as(i64, MAX_PENDING_STORES));
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), winRO(&regs), &proto, 0, Value.nil());
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
}

// --- pure-builtin tracing (math.sqrt → guard_pure/fsqrt, doc 12) --------------

/// A do-nothing `NativeFn` body for recorder unit tests: the recorder never
/// *calls* the native (it inlines `fsqrt` directly), it only reads the heap
/// `Native`'s `pure` tag, so the body is irrelevant.
fn sqrtStub(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    _ = args;
    return Value.nil();
}

test "recPureSqrt: sqrt(float) records guard_pure, guard_float, fsqrt" {
    const gpa = testing.allocator;
    const nat = try function.Native.create(gpa, &sqrtStub, "math.sqrt");
    defer nat.destroy(gpa);
    nat.pure = .sqrt;

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r0 = sqrt (callee + result dest), r1 = arg (a float). `call r0, 1, 1`.
    var regs = [_]Value{ Value.heap(&nat.header), Value.float(2.0), Value.nil() };
    state.recordInstr(Instr.opABC(.call, 0, 1, 1), winRO(&regs), &proto, 0, Value.nil());

    try testing.expect(state.isRecording()); // a clean record — no abort
    const ops = state.rec.instrs.items;
    // slot_load(callee), guard_pure, slot_load(arg), guard_float, fsqrt.
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_pure, ops[1].op);
    try testing.expectEqual(@as(Ref, 0), ops[1].a); // guards the seeded callee ref
    try testing.expectEqual(@as(i32, @intFromEnum(function.PureBuiltin.sqrt)), ops[1].aux);
    try testing.expectEqual(IrOp.slot_load, ops[2].op);
    try testing.expectEqual(IrOp.guard_float, ops[3].op);
    try testing.expectEqual(@as(Ref, 2), ops[3].a); // guards the arg ref
    try testing.expectEqual(IrOp.fsqrt, ops[4].op);
    try testing.expectEqual(@as(Ref, 2), ops[4].a); // fsqrt reads the arg ref
    try testing.expectEqual(ObsType.float, ops[4].ty);
    // The call's destination register holds the fsqrt result (ref 4), not the callee.
    try testing.expectEqual(@as(Ref, 4), try state.refOf(0));
}

test "recPureSqrt aborts: bad arity, non-float arg, and a non-pure native" {
    const gpa = testing.allocator;
    const sq = try function.Native.create(gpa, &sqrtStub, "math.sqrt");
    defer sq.destroy(gpa);
    sq.pure = .sqrt;
    const plain = try function.Native.create(gpa, &sqrtStub, "print");
    defer plain.destroy(gpa); // pure == null

    const Case = struct { callee: *function.Native, arg: Value, b: u16, c: u16, why: AbortReason };
    const cases = [_]Case{
        // sqrt(a, b): two args → no leaf shape.
        .{ .callee = sq, .arg = Value.float(2.0), .b = 2, .c = 1, .why = .cross_frame },
        // x, y = sqrt(a): two results → no leaf shape.
        .{ .callee = sq, .arg = Value.float(2.0), .b = 1, .c = 2, .why = .cross_frame },
        // sqrt(int): v1 is float-only; tier-0 owns the int→float promotion.
        .{ .callee = sq, .arg = Value.int(4), .b = 1, .c = 1, .why = .bad_type },
        // print(x): a native with no `pure` tag stays the host barrier.
        .{ .callee = plain, .arg = Value.float(2.0), .b = 1, .c = 1, .why = .host_barrier },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&c.callee.header), c.arg, Value.nil() };
        state.recordInstr(Instr.opABC(.call, 0, c.b, c.c), winRO(&regs), &proto, 0, Value.nil());
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "per-guard PC recording: guard_int aux carries the bytecode PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A 3-register frame: r0=r1+r2, both ints, at PC 42.
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

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
