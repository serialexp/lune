//! Tests for the doc 56 §4.2 (Phase 1) native exit location map
//! (`nativegen_exitloc.zig`, `nativegen_artifact.ExitLocMap`).

const std = @import("std");
const nativegen = @import("nativegen.zig");
const trace = @import("trace.zig");
const trace_ir = @import("trace_ir.zig");
const SnapIdx = trace_ir.SnapIdx;
const trace_snapshot = @import("trace_snapshot.zig");
const value = @import("value.zig");
const arr = @import("array.zig");
const string = @import("string.zig");
const bytecode = @import("bytecode.zig");
const ngalloc = @import("nativegen_alloc.zig");
const Trace = @import("trace_code.zig").TraceCode;
const Value = value.Value;
const I = trace.IrInstr;
const testing = std.testing;

const McodeArena = nativegen.McodeArena;
const compileInto = nativegen.compileInto;
const is_x64_linux = nativegen.is_x64_linux;

/// The allocator's own answer for `ref`, to hold the map against.
fn analyzed(gpa: std.mem.Allocator, t: *const Trace, kinds: []nativegen.Kind, slot_of: []i32) !ngalloc.Alloc {
    try testing.expect(nativegen.proveKinds(gpa, t, kinds, slot_of));
    return nativegen.analyze(gpa, t, kinds, slot_of) orelse error.AnalyzeBailed;
}

fn expectPlace(row: nativegen.ExitLoc, loc: ngalloc.Loc) !void {
    switch (loc) {
        .reg => |r| {
            try testing.expectEqual(nativegen.ExitLoc.Tag.reg, row.tag);
            try testing.expectEqual(@as(u32, @intFromEnum(r)), row.payload);
        },
        .xmm => |r| {
            try testing.expectEqual(nativegen.ExitLoc.Tag.xmm, row.tag);
            try testing.expectEqual(@as(u32, @intFromEnum(r)), row.payload);
        },
        .spill => |idx| {
            try testing.expectEqual(nativegen.ExitLoc.Tag.spill, row.tag);
            try testing.expectEqual(idx * 8, row.payload);
        },
    }
}

// `while i < limit do local t = i + 1; local u = t + 1; if not (u < limit) … ;
// if not (u < 100) … ; i = u end`, with three exits that carry snapshots:
//   ord 1 (instr 5)  : r0=%0 (i, carried), r1=%1 (limit, invariant)
//   ord 2 (instr 10) : r0=%8, r2=%6 (konst 1), r3=%7 (t, dead after 8), r4=%9
//   ord 3 (instr 13) : r0=%8, r4=%9 (dead after its guard at 10)
const n_instrs = 16;
fn loopInstrs() [n_instrs]I {
    return .{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4, .ord = 1 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: t = i + 1
        .{ .op = .add, .a = 7, .b = 6 }, // 8: u = t + 1 (t's last use)
        .{ .op = .lt, .a = 8, .b = 1 }, // 9
        .{ .op = .guard_true, .a = 9, .ord = 2 }, // 10
        .{ .op = .konst, .aux = 1 }, // 11: 100
        .{ .op = .lt, .a = 8, .b = 11 }, // 12
        .{ .op = .guard_true, .a = 12, .ord = 3 }, // 13
        .{ .op = .phi, .b = 8, .aux = 0 }, // 14: i = u
        .{ .op = .loop }, // 15
    };
}

test "doc 56 exit locations: each needed value gets the allocator's place and its real life" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc", .id = 560 };
    var instrs = loopInstrs();
    var consts = [_]Value{ Value.int(1), Value.int(100) };
    var snaps = [_]trace_snapshot.Snapshot{
        .{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 5 },
        .{ .resume_pc = 0, .slots_begin = 2, .slots_len = 4, .register_count = 5 },
        .{ .resume_pc = 0, .slots_begin = 6, .slots_len = 2, .register_count = 5 },
    };
    var slots = [_]trace_snapshot.SnapshotSlot{
        .{ .slot = 0, .ref = 0 }, .{ .slot = 1, .ref = 1 },
        .{ .slot = 0, .ref = 8 }, .{ .slot = 2, .ref = 6 }, .{ .slot = 3, .ref = 7 }, .{ .slot = 4, .ref = 9 },
        .{ .slot = 0, .ref = 8 }, .{ .slot = 4, .ref = 9 },
    };
    var by_ord = [_]SnapIdx{ 0, 1, 2, 3 };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = 0 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_snapshots = &snaps,
        .exit_snapshot_slots = &slots,
        .exit_snap_by_ord = &by_ord,
    };

    var arena = McodeArena.init(gpa);
    defer arena.deinit();
    var ct = compileInto(gpa, &arena, &t, 560, null, null) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const m = &ct.exit_locs;

    var kinds: [n_instrs]nativegen.Kind = undefined;
    var slot_of: [n_instrs]i32 = undefined;
    var alloc = try analyzed(gpa, &t, &kinds, &slot_of);
    defer alloc.deinit(gpa);

    // One row per distinct needed value, sorted: the snapshot refs (the
    // carried slot's load %0 is among them).
    const want = [_]u16{ 0, 1, 6, 7, 8, 9 };
    try testing.expectEqual(want.len, m.values.len);
    for (want, m.values) |r, row| try testing.expectEqual(r, row.ref);

    // The carried slot's home is listed for write-back.
    try testing.expectEqual(@as(usize, 1), m.carried.len);
    try testing.expectEqual(@as(u16, 0), m.carried[0].slot);
    try testing.expectEqual(@as(u16, 0), m.carried[0].ref);
    try testing.expectEqual(nativegen.Kind.int, m.carried[0].kind);

    // Slot homes: the allocator's home, all body long. Only the invariant
    // one may skip its own slot.
    const i_row = m.find(0).?;
    try expectPlace(i_row, alloc.loc[0]);
    try testing.expectEqual(nativegen.ExitLoc.LIVE_WHOLE_BODY, i_row.live_until);
    try testing.expectEqual(nativegen.ExitLoc.NO_SLOT, i_row.invariant_slot);
    const lim_row = m.find(1).?;
    try expectPlace(lim_row, alloc.loc[1]);
    try testing.expectEqual(@as(u16, 1), lim_row.invariant_slot);
    for ([_]usize{ 5, 10, 13 }) |e| {
        try testing.expect(m.at(0, e) != null);
        try testing.expect(m.at(1, e) != null);
    }

    // A constant is rebuilt from the table, never read from the body.
    const k_row = m.find(6).?;
    try testing.expectEqual(nativegen.ExitLoc.Tag.konst, k_row.tag);
    try testing.expectEqual(@as(u32, 0), k_row.payload);
    try testing.expect(m.at(6, 13) != null);

    // u (%8) lives to the φ, so both later exits hold it.
    const u_row = m.find(8).?;
    try expectPlace(u_row, alloc.loc[8]);
    try testing.expect(m.at(8, 10) != null);
    try testing.expect(m.at(8, 13) != null);
    try testing.expect(m.at(8, 5) == null); // not yet defined

    // t (%7) dies at instr 8, before the exit at 10 that names it: lost
    // there (Phase 1 extends no liveness).
    try testing.expect(m.at(7, 10) == null);

    // %9 is held at its own guard (10) and gone by the next exit (13).
    try testing.expect(m.at(9, 13) == null);
    if (kinds[9] != .none) try testing.expect(m.at(9, 10) != null);

    // Values nobody needs have no row.
    try testing.expect(m.find(4) == null);
    try testing.expect(m.find(12) == null);
}

test "doc 56 exit locations: a value whose register the reader reuses is not held at that reader" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-reuse", .id = 561 };
    var instrs = loopInstrs();
    var consts = [_]Value{ Value.int(1), Value.int(100) };
    var kinds: [n_instrs]nativegen.Kind = undefined;
    var slot_of: [n_instrs]i32 = undefined;
    var snaps = [_]trace_snapshot.Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 1, .register_count = 5 }};
    var slots = [_]trace_snapshot.SnapshotSlot{.{ .slot = 3, .ref = 7 }};
    var by_ord = [_]SnapIdx{ 0, 0, 1, 0 };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = 0 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_snapshots = &snaps,
        .exit_snapshot_slots = &slots,
        .exit_snap_by_ord = &by_ord,
    };
    var alloc = try analyzed(gpa, &t, &kinds, &slot_of);
    defer alloc.deinit(gpa);
    var m = try nativegen.exitloc.build(gpa, &t, &kinds, &alloc);
    defer m.deinit(gpa);

    // t (%7) is last read by u = t + 1 (%8), and the linear scan hands the
    // dying operand's register to the result (win 1) — the fixture relies
    // on that, so pin it. The map must then end t's life one instruction
    // early: an exit AT instr 8 would already see u there.
    try testing.expectEqual(@as(u32, 8), alloc.last_use[7]);
    try testing.expect(ngalloc.locEql(alloc.loc[7], alloc.loc[8]));
    const row = m.find(7).?;
    try testing.expectEqual(@as(u16, 7), row.live_until);
    try testing.expect(!row.holdsAt(8));
    try testing.expect(!row.holdsAt(7)); // its own def: never
}

test "doc 56 exit locations: a sunk store's value, token, table and index are mapped" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-store", .id = 562 };
    // `while k in array do t[k] = false; k = k + 1 end`, with the store sunk
    // below a second bounds exit (on k + 1) that belongs to a later bytecode.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: k
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5, .ord = 1 }, // 6
        .{ .op = .konst, .aux = 0 }, // 7: false
        .{ .op = .konst, .aux = 1 }, // 8: 1
        .{ .op = .add, .a = 3, .b = 8 }, // 9: k + 1
        .{ .op = .aref, .a = 0, .b = 9, .aux = lane }, // 10
        .{ .op = .guard_bounds, .a = 10, .ord = 2 }, // 11
        .{ .op = .astore, .a = 5, .b = 7, .aux = lane, .ord = 1 }, // 12: sunk t[k] = false
        .{ .op = .phi, .b = 9, .aux = 1 }, // 13
        .{ .op = .loop }, // 14
    };
    var consts = [_]Value{ Value.boolean(false), Value.int(1) };
    var snaps = [_]trace_snapshot.Snapshot{
        .{ .resume_pc = 0, .slots_begin = 0, .slots_len = 1, .register_count = 2 },
        .{ .resume_pc = 0, .slots_begin = 1, .slots_len = 1, .register_count = 2 },
    };
    var slots = [_]trace_snapshot.SnapshotSlot{ .{ .slot = 1, .ref = 3 }, .{ .slot = 1, .ref = 9 } };
    var by_ord = [_]SnapIdx{ 0, 1, 2 };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = 0 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_snapshots = &snaps,
        .exit_snapshot_slots = &slots,
        .exit_snap_by_ord = &by_ord,
    };
    var arena = McodeArena.init(gpa);
    defer arena.deinit();
    var ct = compileInto(gpa, &arena, &t, 562, null, null) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const m = &ct.exit_locs;

    // The store's aref token (%5), through it the table (%0) and index
    // (%3), and the stored value (%7) — all needed at the exit at 11,
    // where the adapter must replay the store from ordinal 1.
    for ([_]usize{ 0, 3, 5, 7 }) |r| try testing.expect(m.at(r, 11) != null);
    try testing.expectEqual(nativegen.ExitLoc.Tag.konst, m.find(7).?.tag);
    // The second aref (%10) is not a store operand: no row.
    try testing.expect(m.find(10) == null);
    // k (%3) is the carried slot; the table is invariant for its own slot.
    try testing.expectEqual(@as(usize, 1), m.carried.len);
    try testing.expectEqual(@as(u16, 1), m.carried[0].slot);
    try testing.expectEqual(@as(u16, 0), m.find(0).?.invariant_slot);
}

test "doc 56 exit locations: no exit snapshots, no map" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-none", .id = 563 };
    var instrs = loopInstrs();
    var consts = [_]Value{ Value.int(1), Value.int(100) };
    const t = Trace{ .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &instrs, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };
    var arena = McodeArena.init(gpa);
    defer arena.deinit();
    var ct = compileInto(gpa, &arena, &t, 563, null, null) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    try testing.expectEqual(@as(usize, 0), ct.exit_locs.values.len);
    try testing.expectEqual(@as(usize, 0), ct.exit_locs.carried.len);
    try testing.expectEqual(@as(usize, 0), ct.exit_locs.bytes());
}

/// A trace over `instrs` whose exits carry `snaps`/`slots`, found through
/// `by_ord`. The anchor is a one-`halt` proto (no loop-done guards).
fn snapTrace(proto: *bytecode.Proto, instrs: []I, consts: []Value, snaps: []trace_snapshot.Snapshot, slots: []trace_snapshot.SnapshotSlot, by_ord: []SnapIdx) Trace {
    return .{
        .anchor = .{ .proto = proto, .pc = 0 },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_snapshots = snaps,
        .exit_snapshot_slots = slots,
        .exit_snap_by_ord = by_ord,
    };
}

test "doc 56 exit locations: a carried table is boxed as .heap, and a sunk hstore maps its href, table, key and value" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-heap", .id = 564 };
    // The nbody writeback shape (`bi.v = bi.v + 10; bi = c[k]; k = k + 1`)
    // with the hstore sunk below the bounds exit of a later bytecode.
    var consts = [_]Value{ Value.heap(&key.header), Value.int(10), Value.int(1) };
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = nativegen.VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: k
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 2 }, // 5: bi — carried-heap
        .{ .op = .guard_table, .a = 5 }, // 6
        .{ .op = .konst, .aux = 0 }, // 7: key
        .{ .op = .href, .a = 5, .b = 7, .aux = 3 }, // 8
        .{ .op = .guard_hash, .a = 8, .aux = 1, .ord = 1 }, // 9
        .{ .op = .hload, .a = 8, .ty = .int }, // 10: v
        .{ .op = .konst, .aux = 1 }, // 11: 10
        .{ .op = .add, .a = 10, .b = 11, .ty = .int }, // 12: v + 10
        .{ .op = .aref, .a = 0, .b = 3, .aux = nativegen.VALUE_LANE }, // 13
        .{ .op = .guard_bounds, .a = 13, .ord = 2 }, // 14
        .{ .op = .aload, .a = 13, .aux = nativegen.VALUE_LANE, .ty = .heap }, // 15: next bi
        .{ .op = .konst, .aux = 2 }, // 16: 1
        .{ .op = .add, .a = 3, .b = 16, .ty = .int }, // 17: k + 1
        .{ .op = .hstore, .a = 8, .b = 12, .ord = 1 }, // 18: sunk bi.v = v + 10
        .{ .op = .phi, .b = 17, .aux = 1 }, // 19
        .{ .op = .phi, .b = 15, .aux = 2 }, // 20
        .{ .op = .loop }, // 21
    };
    var snaps = [_]trace_snapshot.Snapshot{
        .{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 3 },
        .{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 3 },
    };
    var slots = [_]trace_snapshot.SnapshotSlot{ .{ .slot = 1, .ref = 3 }, .{ .slot = 2, .ref = 5 } };
    var by_ord = [_]SnapIdx{ 0, 1, 2 };
    const t = snapTrace(&proto, &instrs, &consts, &snaps, &slots, &by_ord);

    var kinds: [instrs.len]nativegen.Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var alloc = try analyzed(gpa, &t, &kinds, &slot_of);
    defer alloc.deinit(gpa);
    var m = try nativegen.exitloc.build(gpa, &t, &kinds, &alloc);
    defer m.deinit(gpa);

    // The load proves `.ptr`, but the slot is carried-heap: its home holds
    // a different table each iteration and every flush boxes it TAG_HEAP.
    try testing.expectEqual(nativegen.Kind.ptr, kinds[5]);
    try testing.expectEqual(nativegen.Kind.heap, m.find(5).?.kind);
    var saw_bi = false;
    for (m.carried) |h| if (h.slot == 2) {
        saw_bi = true;
        try testing.expectEqual(nativegen.Kind.heap, h.kind);
    };
    try testing.expect(saw_bi);

    // The sunk hstore (ordinal 1) is below the bounds exit of ordinal 2: its
    // cell token, the token's table and key, and the value are all held.
    for ([_]usize{ 5, 7, 8, 12 }) |r| try testing.expect(m.at(r, 14) != null);
    try testing.expectEqual(nativegen.ExitLoc.Tag.konst, m.find(7).?.tag);
}

test "doc 56 exit locations: an in-place (win 2) home update ends the entry value's life there" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-win2", .id = 565 };
    var consts = [_]Value{Value.int(1)};
    // `i = i + 1` after the only body exit: the allocator updates i's home
    // in place, so the entry value of i is gone from instr 7 on.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4, .ord = 1 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i + 1, into i's home
        .{ .op = .phi, .b = 7, .aux = 0 }, // 8
        .{ .op = .loop }, // 9
    };
    var snaps = [_]trace_snapshot.Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 1, .register_count = 2 }};
    var slots = [_]trace_snapshot.SnapshotSlot{.{ .slot = 0, .ref = 0 }};
    var by_ord = [_]SnapIdx{ 0, 1 };
    const t = snapTrace(&proto, &instrs, &consts, &snaps, &slots, &by_ord);

    var kinds: [instrs.len]nativegen.Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var alloc = try analyzed(gpa, &t, &kinds, &slot_of);
    defer alloc.deinit(gpa);
    var m = try nativegen.exitloc.build(gpa, &t, &kinds, &alloc);
    defer m.deinit(gpa);

    // The fixture relies on the coalescing actually happening: pin it.
    const s = alloc.slots[@intCast(alloc.slot_id_of_ref[0])];
    try testing.expect(s.coalesced);
    try testing.expectEqual(@as(i32, 7), s.store_ref);
    const row = m.find(0).?;
    try testing.expectEqual(@as(u16, 6), row.live_until);
    try testing.expect(row.holdsAt(5));
    try testing.expect(!row.holdsAt(7));
    try testing.expect(!row.holdsAt(8));
}

test "doc 56 exit locations: a float home is an XMM row" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-float", .id = 566 };
    // `while i < limit do acc = acc + 0.1; i = i + 1 end` (the F1 fixture),
    // with a snapshot restoring acc and i at the loop test.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .slot_load, .aux = 2 }, // 4: acc (float)
        .{ .op = .guard_float, .a = 4 }, // 5
        .{ .op = .lt, .a = 0, .b = 1 }, // 6
        .{ .op = .guard_true, .a = 6, .ord = 1 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 0.1
        .{ .op = .add, .a = 4, .b = 8, .ty = .float }, // 9
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .phi, .b = 11, .aux = 0 },
        .{ .op = .loop },
    };
    var consts = [_]Value{ Value.float(0.1), Value.int(1) };
    var snaps = [_]trace_snapshot.Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 3 }};
    var slots = [_]trace_snapshot.SnapshotSlot{ .{ .slot = 0, .ref = 0 }, .{ .slot = 2, .ref = 4 } };
    var by_ord = [_]SnapIdx{ 0, 1 };
    const t = snapTrace(&proto, &instrs, &consts, &snaps, &slots, &by_ord);

    var kinds: [instrs.len]nativegen.Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var alloc = try analyzed(gpa, &t, &kinds, &slot_of);
    defer alloc.deinit(gpa);
    var m = try nativegen.exitloc.build(gpa, &t, &kinds, &alloc);
    defer m.deinit(gpa);

    const acc = m.find(4).?;
    try testing.expectEqual(nativegen.ExitLoc.Tag.xmm, acc.tag);
    try testing.expectEqual(nativegen.Kind.float, acc.kind);
    try expectPlace(acc, alloc.loc[4]);
    try testing.expect(m.at(4, 7) != null);
    try expectPlace(m.find(0).?, alloc.loc[0]);
}

test "doc 56 exit locations: homes past the register pool are spill rows with frame displacements" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var code = [_]bytecode.Instr{bytecode.Instr.op0(.halt)};
    var proto = bytecode.Proto{ .code = &code, .name = "exitloc-spill", .id = 567 };
    // Twelve carried int slots (more than the nine allocatable GPRs), each
    // `r = r + 1`, with one exit whose snapshot restores all twelve.
    const N = 12;
    const konst_ref = 2 * N;
    const lt_ref = konst_ref + 1;
    const exit_ref = lt_ref + 1;
    const add0 = exit_ref + 1;
    const phi0 = add0 + N;
    var instrs: [phi0 + N + 1]I = undefined;
    for (0..N) |r| {
        instrs[r] = .{ .op = .slot_load, .aux = @intCast(r) };
        instrs[N + r] = .{ .op = .guard_int, .a = @intCast(r) };
        instrs[add0 + r] = .{ .op = .add, .a = @intCast(r), .b = konst_ref };
        instrs[phi0 + r] = .{ .op = .phi, .b = @intCast(add0 + r), .aux = @intCast(r) };
    }
    instrs[konst_ref] = .{ .op = .konst, .aux = 0 };
    instrs[lt_ref] = .{ .op = .lt, .a = 0, .b = 1 };
    instrs[exit_ref] = .{ .op = .guard_true, .a = lt_ref, .ord = 1 };
    instrs[phi0 + N] = .{ .op = .loop };
    var consts = [_]Value{Value.int(1)};
    var snaps = [_]trace_snapshot.Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = N, .register_count = N }};
    var slots: [N]trace_snapshot.SnapshotSlot = undefined;
    for (&slots, 0..) |*ss, r| ss.* = .{ .slot = @intCast(r), .ref = @intCast(r) };
    var by_ord = [_]SnapIdx{ 0, 1 };
    const t = snapTrace(&proto, &instrs, &consts, &snaps, &slots, &by_ord);

    var kinds: [instrs.len]nativegen.Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var alloc = try analyzed(gpa, &t, &kinds, &slot_of);
    defer alloc.deinit(gpa);
    var m = try nativegen.exitloc.build(gpa, &t, &kinds, &alloc);
    defer m.deinit(gpa);

    try testing.expectEqual(@as(usize, N), m.carried.len);
    var spills: usize = 0;
    for (0..N) |r| {
        const row = m.find(r).?;
        try expectPlace(row, alloc.loc[r]);
        try testing.expect(row.holdsAt(exit_ref));
        if (row.tag == .spill) spills += 1;
    }
    try testing.expect(spills > 0);
}
