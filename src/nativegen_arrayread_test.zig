//! Tests for `nativegen.zig` — arrayread.
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

const VALUE_LANE = nativegen.VALUE_LANE;
const compile = nativegen.compile;
const is_x64_linux = nativegen.is_x64_linux;

const util = @import("nativegen_testutil.zig");
const expectBail = util.expectBail;
const expectMatch = util.expectMatch;
const expectTablesEqual = util.expectTablesEqual;
const runNative = util.runNative;

// ---------------------------------------------------------------------------
// B2c: lane-aware native array READ path — differential tests (bool lane)
// ---------------------------------------------------------------------------

test "nativegen: bool-lane t[k] read scan matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);

    // nsieve's sieve shape: p[2..K] = true → a narrow boolean lane (key 1 a hole).
    const K: i64 = 64;
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var consts = [_]Value{Value.int(1)};
    // r0=table, r1=index, r2=last load. Each iteration loads t[index] (bool lane),
    // advances the index, and side-exits on a bounds/present miss.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8: v = t[index]
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index + 1
        .{ .op = .phi, .b = 10, .aux = 1 },
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .loop }, // 11
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Start at 2 (first present): scans the whole dense run, bounds-exits past K.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(2), Value.nil() });
    // Start at 1: key 1 is a hole → guard_present side-exits on iteration 0.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(1), Value.nil() });
    // Start past the run: guard_bounds side-exits immediately.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(K + 5), Value.nil() });
    // Start mid-run: a shorter clean prefix, then bounds-exit.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(40), Value.nil() });
}

test "nativegen: int-lane t[k] read scan matches the interpreter (i8/i16/i32/i64)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;

    const Cfg = struct { lane: arr.Lane, bump: i64 };
    // `bump` is a value past the previous lane's max, so the (monotonic) rehash
    // widening lands the array on exactly `lane`. Negative slot values exercise
    // the load's SIGN extension (movsx/movsxd), not just zero-extension.
    const cfgs = [_]Cfg{
        .{ .lane = .i8, .bump = 100 }, // all |v| <= 127
        .{ .lane = .i16, .bump = 1000 }, // exceeds i8
        .{ .lane = .i32, .bump = 100_000 }, // exceeds i16
        .{ .lane = .i64, .bump = 5_000_000_000 }, // exceeds i32
    };

    for (cfgs) |cfg| {
        const t = try table.Table.create(gpa);
        defer t.destroy(gpa);
        var i: i64 = 2;
        while (i <= K) : (i += 1) {
            const v: i64 = if (@rem(i, 2) == 0) i else -i; // alternate sign
            try t.set(gpa, Value.int(i), Value.int(v));
        }
        try t.set(gpa, Value.int(K), Value.int(cfg.bump)); // pin the widest value
        try testing.expectEqual(cfg.lane, t.array.lane);

        const lane: i32 = @intFromEnum(cfg.lane);
        var consts = [_]Value{Value.int(1)};
        // r0=table, r1=index, r2=last load. Same scan shape as the bool test, but
        // the aload decodes a sign-extended int (carried as TAG_INT at exit).
        var full = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: table
            .{ .op = .guard_table, .a = 0 }, // 1
            .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
            .{ .op = .slot_load, .aux = 1 }, // 3: index
            .{ .op = .guard_int, .a = 3 }, // 4
            .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
            .{ .op = .guard_bounds, .a = 5 }, // 6
            .{ .op = .guard_present, .a = 5 }, // 7
            .{ .op = .aload, .a = 5, .aux = lane }, // 8: v = t[index]
            .{ .op = .konst, .aux = 0 }, // 9: 1
            .{ .op = .add, .a = 3, .b = 9 }, // 10: index + 1
            .{ .op = .phi, .b = 10, .aux = 1 },
            .{ .op = .phi, .b = 8, .aux = 2 },
            .{ .op = .loop }, // 11
        };
        var es = [_]u16{};
        const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

        try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(2), Value.nil() }); // full scan
        try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(1), Value.nil() }); // hole at key 1
        try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(K + 3), Value.nil() }); // OOB
        try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(K), Value.nil() }); // last present (=bump)
    }
}

test "nativegen(Phase F): .value-lane array-of-structs int-field read matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The canonical `bodies[i].field` array-of-structs shape, hand-built as IR:
    //   container[i] is a *table* (a `.value`-lane element), and the hot loop reads a
    //   scalar field out of each element table via the full Phase F chain
    //   aload(.value, ty=.heap) → guard_table → href(aux=-1) → guard_hash → hload.
    // A single interned string is the shared field key, so the href key const and
    // every element's stored key are the same object (pointer-identity hit).
    const key = try @import("string.zig").String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 32;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);

    const container = try table.Table.create(gpa);
    defer container.destroy(gpa);

    // Element i (1-based) has exactly one hash field `v = i` (an int). Storing the
    // element tables (heap values) into contiguous int keys forces the container's
    // array part onto the `.value` lane.
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const e = try table.Table.create(gpa);
        elems[i] = e;
        built += 1;
        try e.set(gpa, key_val, Value.int(@intCast(i + 1)));
        try container.set(gpa, Value.int(@intCast(i + 1)), Value.heap(&e.header));
    }
    try testing.expectEqual(arr.Lane.value, container.array.lane);

    const lane: i32 = VALUE_LANE;
    // consts[0] = the interned field key (an href key → proven `.none`); [1] = int 1.
    var consts = [_]Value{ key_val, Value.int(1) };
    // r0=container, r1=index, r2=acc. Each iteration reads container[index].v,
    // accumulates it, advances the index, and bounds-exits past the dense run.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1: (prologue-hoisted .ptr guard)
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = lane, .ty = .heap }, // 7: element *Table
        .{ .op = .guard_table, .a = 7 }, // 8: per-iteration element guard (.heap)
        .{ .op = .konst, .aux = 0 }, // 9: the field key
        .{ .op = .href, .a = 7, .b = 9, .aux = -1 }, // 10: per-iteration cell
        .{ .op = .guard_hash, .a = 10, .aux = 1 }, // 11: element has 1 field
        .{ .op = .hload, .a = 10, .ty = .int }, // 12: v = element.v
        .{ .op = .slot_load, .aux = 2 }, // 13: acc
        .{ .op = .guard_int, .a = 13 }, // 14
        .{ .op = .add, .a = 13, .b = 12, .ty = .int }, // 15: acc + v
        .{ .op = .konst, .aux = 1 }, // 16: 1
        .{ .op = .add, .a = 3, .b = 16, .ty = .int }, // 17: index + 1
        .{ .op = .phi, .b = 17, .aux = 1 }, // index carry
        .{ .op = .phi, .b = 15, .aux = 2 }, // acc carry
        .{ .op = .loop }, // 18
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Full scan from 1: sums v over the whole dense run, bounds-exits past N.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.int(0) });
    // Start mid-run: a shorter clean prefix, then bounds-exit.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(20), Value.int(0) });
    // Start past the run: guard_bounds side-exits immediately (completed==0).
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(@intCast(N + 5)), Value.int(0) });
}

test "nativegen: invariant heap identity compares stable IDs, not addresses" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var heap = @import("gc.zig").Heap.init(gpa);
    defer heap.deinit();

    const first = try heap.newTable();
    const second = try heap.newTable();
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_table, .a = 2 },
        .{ .op = .ne, .a = 0, .b = 2, .ty = .boolean },
        .{ .op = .guard_true, .a = 4 },
        .{ .op = .link },
    };
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    try expectMatch(&tr, &.{ Value.heap(&first.header), Value.heap(&second.header) });
    try expectMatch(&tr, &.{ Value.heap(&first.header), Value.heap(&first.header) });

    // Keyframe restore preserves IDs while rebuilding objects at new addresses.
    // The invariant-pointer path must therefore use the same identity rule as
    // Value.eql and the IR interpreter.
    second.header.id = first.header.id;
    try testing.expect(@intFromPtr(&first.header) != @intFromPtr(&second.header));
    try expectMatch(&tr, &.{ Value.heap(&first.header), Value.heap(&second.header) });
}

test "nativegen: value-lane heap identity compares stable IDs, not addresses" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var heap = @import("gc.zig").Heap.init(gpa);
    defer heap.deinit();

    const first = try heap.newTable();
    const second = try heap.newTable();
    const container = try heap.newTable();
    try container.set(gpa, Value.int(1), Value.heap(&first.header));
    try container.set(gpa, Value.int(2), Value.heap(&second.header));
    try testing.expectEqual(arr.Lane.value, container.array.lane);

    const lane: i32 = VALUE_LANE;
    var consts = [_]Value{ Value.int(1), Value.int(2) };
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = lane },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane },
        .{ .op = .guard_bounds, .a = 4 },
        .{ .op = .aload, .a = 4, .aux = lane, .ty = .heap },
        .{ .op = .guard_table, .a = 6 },
        .{ .op = .konst, .aux = 1 },
        .{ .op = .aref, .a = 0, .b = 8, .aux = lane },
        .{ .op = .guard_bounds, .a = 9 },
        .{ .op = .aload, .a = 9, .aux = lane, .ty = .heap },
        .{ .op = .guard_table, .a = 11 },
        .{ .op = .ne, .a = 6, .b = 11, .ty = .boolean },
        .{ .op = .guard_true, .a = 13 },
        .{ .op = .link },
    };
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &.{}, .entry_guards = &.{} };
    const regs = [_]Value{Value.heap(&container.header)};

    // Distinct IDs pass `ne`; the same object in both cells fails it.
    try expectMatch(&tr, &regs);
    try container.set(gpa, Value.int(2), Value.heap(&first.header));
    try expectMatch(&tr, &regs);

    // A restored twin may occupy a different address but preserve the original
    // stable ID. The oracle considers the pair equal, and native must agree.
    try container.set(gpa, Value.int(2), Value.heap(&second.header));
    second.header.id = first.header.id;
    try testing.expect(@intFromPtr(&first.header) != @intFromPtr(&second.header));
    try expectMatch(&tr, &regs);
}

test "nativegen(Phase F): .value-lane array-of-structs float-field read matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // As above but the element field is a FLOAT (the real `bodies[i].x` type), so
    // `hload` tag-checks TAG_FLOAT and lands the value in an XMM home; the carried
    // accumulator is a float. Proves the Phase F chain's float `hload` arm.
    const key = try @import("string.zig").String.create(gpa, "x");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 24;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);

    const container = try table.Table.create(gpa);
    defer container.destroy(gpa);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const e = try table.Table.create(gpa);
        elems[i] = e;
        built += 1;
        try e.set(gpa, key_val, Value.float(@as(f64, @floatFromInt(i + 1)) * 1.5));
        try container.set(gpa, Value.int(@intCast(i + 1)), Value.heap(&e.header));
    }
    try testing.expectEqual(arr.Lane.value, container.array.lane);

    const lane: i32 = VALUE_LANE;
    var consts = [_]Value{ key_val, Value.int(1) };
    // r0=container, r1=index, r2=acc(float). Reads container[index].x (a float),
    // accumulates into the float acc via addsd, advances the index.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = lane, .ty = .heap }, // 7: element *Table
        .{ .op = .guard_table, .a = 7 }, // 8
        .{ .op = .konst, .aux = 0 }, // 9: field key
        .{ .op = .href, .a = 7, .b = 9, .aux = -1 }, // 10: per-iteration cell
        .{ .op = .guard_hash, .a = 10, .aux = 1 }, // 11
        .{ .op = .hload, .a = 10, .ty = .float }, // 12: x = element.x (float)
        .{ .op = .slot_load, .aux = 2 }, // 13: acc (float)
        .{ .op = .guard_float, .a = 13 }, // 14
        .{ .op = .add, .a = 13, .b = 12, .ty = .float }, // 15: acc + x
        .{ .op = .konst, .aux = 1 }, // 16: 1
        .{ .op = .add, .a = 3, .b = 16, .ty = .int }, // 17: index + 1
        .{ .op = .phi, .b = 17, .aux = 1 }, // index carry
        .{ .op = .phi, .b = 15, .aux = 2 }, // acc carry
        .{ .op = .loop }, // 18
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.float(0.0) });
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(10), Value.float(0.0) });
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(@intCast(N + 5)), Value.float(0.0) });
}

test "nativegen: guard_table failure side-exits natively with completed==0" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = lane },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 3 },
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane },
        .{ .op = .guard_bounds, .a = 5 },
        .{ .op = .guard_present, .a = 5 },
        .{ .op = .aload, .a = 5, .aux = lane },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 3, .b = 9 },
        .{ .op = .phi, .b = 10, .aux = 1 },
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .loop },
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // r0 is an int, not a table → the prologue guard_table check fails (completed==0,
    // regs untouched). The oracle agrees.
    try expectMatch(&tr, &.{ Value.int(99), Value.int(2), Value.nil() });
}

/// `while (i < limit) { acc += i; i += 1 }` with an extra invariant `.func`
/// snapshot slot (slot 3) guarded by a `guard_func aux=guard_id` at the top — the
/// cross-frame callee identity check (U1). The guard is an entry guard hoisted to
/// the prologue: when the snapshot closure's `proto.id` matches `guard_id` it runs
/// the whole loop; on a mismatch the prologue side-exits (completed==0, regs
/// untouched), exactly like the tier-1a oracle's `guard_func` arm.
fn funcGuardTrace(full: *[16]I, consts: *[1]Value, es: *[0]u16, guard_id: u32) Trace {
    consts.* = .{Value.int(1)};
    full.* = .{
        .{ .op = .slot_load, .aux = 3 }, // 0: func snapshot (invariant, slot 3)
        .{ .op = .guard_func, .a = 0, .aux = @bitCast(guard_id) }, // 1: callee identity
        .{ .op = .slot_load, .aux = 0 }, // 2: i
        .{ .op = .slot_load, .aux = 1 }, // 3: limit
        .{ .op = .guard_int, .a = 2 }, // 4
        .{ .op = .guard_int, .a = 3 }, // 5
        .{ .op = .lt, .a = 2, .b = 3 }, // 6: i < limit
        .{ .op = .guard_true, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 2 }, // 8: acc
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .add, .a = 8, .b = 2 }, // 10: acc + i
        .{ .op = .konst, .aux = 0 }, // 11: 1
        .{ .op = .add, .a = 2, .b = 11 }, // 12: i + 1
        .{ .op = .phi, .b = 10, .aux = 2 }, // 13: acc carry
        .{ .op = .phi, .b = 12, .aux = 0 }, // 14: i carry
        .{ .op = .loop }, // 15
    };
    return Trace{ .anchor = undefined, .instrs = full, .consts = consts, .entry_slots = es, .entry_guards = &.{} };
}

test "nativegen: guard_func passes when the snapshot closure matches the recorded proto.id" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var proto = bytecode.Proto{ .code = &.{}, .name = "callee", .id = 7 };
    const cl = try function.Closure.create(gpa, &proto, 0);
    defer cl.destroy(gpa);

    var full: [16]I = undefined;
    var consts: [1]Value = undefined;
    var es = [_]u16{};
    const t = funcGuardTrace(&full, &consts, &es, 7); // guard id == proto.id

    // i=1..5, limit=5 → 4 iterations (acc=10); func snapshot in slot 3 passes the
    // prologue identity check every entry, so it never side-exits on the guard.
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0), Value.heap(&cl.header) });
}

test "nativegen: guard_func side-exits when the snapshot closure has a different proto.id" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var proto = bytecode.Proto{ .code = &.{}, .name = "callee", .id = 9 };
    const cl = try function.Closure.create(gpa, &proto, 0);
    defer cl.destroy(gpa);

    var full: [16]I = undefined;
    var consts: [1]Value = undefined;
    var es = [_]u16{};
    const t = funcGuardTrace(&full, &consts, &es, 7); // recorded id 7 ≠ closure's 9

    // The prologue `cmp [proto+id], 7` fails → completed==0, regs untouched. The
    // oracle's guard_func arm side-exits at instr 1 identically.
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0), Value.heap(&cl.header) });
}

test "nativegen: guard_func side-exits when the snapshot value is not a closure" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var full: [16]I = undefined;
    var consts: [1]Value = undefined;
    var es = [_]u16{};
    const t = funcGuardTrace(&full, &consts, &es, 7);

    // slot 3 holds an int, not a heap closure → the prologue TAG_HEAP tag-check
    // fails before the identity check (completed==0, regs untouched). The oracle's
    // `isHeap()` guard side-exits at instr 1 identically.
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0), Value.int(42) });
}

test "nativegen: two guard_funcs with conflicting ids on one snapshot decline native" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // A malformed trace the recorder never emits (dedup gives one synthetic slot →
    // one resolved closure → one id): two guard_funcs on slot_load 0 with *different*
    // recorded ids. The prologue can only hoist one id; the oracle re-checks each and
    // would side-exit on the second — a native≠oracle divergence. `analyzeInner`'s
    // duplicate-aux bail must decline native (tier-1a stays the oracle) rather than
    // miscompile.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 3 }, // 0: func snapshot
        .{ .op = .guard_func, .a = 0, .aux = 7 }, // 1: id 7
        .{ .op = .guard_func, .a = 0, .aux = 8 }, // 2: conflicting id 8
        .{ .op = .slot_load, .aux = 0 }, // 3: i
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .konst, .aux = 0 }, // 5: 1
        .{ .op = .add, .a = 3, .b = 5 }, // 6: i + 1
        .{ .op = .phi, .b = 6, .aux = 0 }, // 7: i carry
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&t);
}

/// An f64-lane table with keys 2..K mapping to distinct doubles (`i * 0.5`).
/// Mirrors `buildIntTable` but for the float lane; the array-part lane settles to
/// `.f64` (asserted by the callers).
fn buildFloatTable(gpa: std.mem.Allocator, K: i64) !*table.Table {
    const t = try table.Table.create(gpa);
    var i: i64 = 2;
    while (i <= K) : (i += 1) {
        try t.set(gpa, Value.int(i), Value.float(@as(f64, @floatFromInt(i)) * 0.5));
    }
    return t;
}

/// `while (k in array) { t[k] = C; k += 1 }` over the f64 lane, with the (no-op
/// for f64) guard_fits ahead of the store — exactly the shape `recArraySet` emits
/// for a constant-float fill before tropt folds the redundant guard. r0 = table
/// (invariant .ptr), r1 = index (carried int), the store value is a float konst.
/// A pure constant write → no `aload`, so C1 is trivially satisfied.
fn floatWriteTrace(full: *[14]I, consts: *[2]Value, es: *[0]u16, store_const: f64) Trace {
    const lane: i32 = @intFromEnum(arr.Lane.f64);
    consts.* = .{ Value.float(store_const), Value.int(1) };
    full.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .konst, .aux = 0 }, // 7: C (float)
        .{ .op = .guard_fits, .a = 7, .aux = lane }, // 8: no-op for f64 (every double fits)
        .{ .op = .astore, .a = 5, .b = 7, .aux = lane }, // 9: t[index] = C
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 3, .b = 10 }, // 11: index + 1
        .{ .op = .phi, .b = 11, .aux = 1 }, // 12: index carry
        .{ .op = .loop }, // 13
    };
    return Trace{ .anchor = undefined, .instrs = full, .consts = consts, .entry_slots = es, .entry_guards = &.{} };
}

test "nativegen: f64-lane t[k]=C write matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // The f64 array lane now lowers natively (Phase D Gap A): aref + guard_bounds +
    // guard_fits (a no-op for f64) + a full-width `movsd` store + presence `bts`.
    // Native and the tier-1a oracle must agree bit-for-bit on the mutated heap and
    // the carried index. `2.5` is exactly representable, so the stored bits are
    // unambiguous.
    const gpa = testing.allocator;
    const K: i64 = 48;
    const C: f64 = 2.5;
    var full: [14]I = undefined;
    var consts: [2]Value = undefined;
    var es: [0]u16 = undefined;
    const tr = floatWriteTrace(&full, &consts, &es, C);

    // Separate tables (the trace mutates the heap): native vs the oracle.
    const t_o = try buildFloatTable(gpa, K);
    defer t_o.destroy(gpa);
    try testing.expectEqual(arr.Lane.f64, t_o.array.lane);
    var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
    const ovals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(ovals);
    const oresult = irinterp.executeValues(&tr, &oregs, ovals);

    const t_n = try buildFloatTable(gpa, K);
    defer t_n.destroy(gpa);
    var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const ncomp = try runNative(ct, &nregs);

    try testing.expectEqual(oresult.completed, ncomp.completed);
    try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
    try expectTablesEqual(t_o, t_n, K);
    // Sanity: every present slot 2..K now reads the stored constant bit-for-bit.
    var k: i64 = 2;
    while (k <= K) : (k += 1) try testing.expectEqual(@as(u64, @bitCast(C)), t_n.getInt(k).payload.bits);
}

test "nativegen: f64-lane astore deopt-replay leaves a deterministic heap (idempotent re-run)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // C1 oracle on the f64 lane: a native pass then a full tier-0 re-run over the
    // SAME heap must equal a single clean run on a DISTINCT table. The constant
    // write is idempotent, so a replayed (side-exit) iteration is safe.
    const gpa = testing.allocator;
    const K: i64 = 40;
    const C: f64 = -3.25;
    var full: [14]I = undefined;
    var consts: [2]Value = undefined;
    var es: [0]u16 = undefined;
    const tr = floatWriteTrace(&full, &consts, &es, C);

    const t_replay = try buildFloatTable(gpa, K);
    defer t_replay.destroy(gpa);
    try testing.expectEqual(arr.Lane.f64, t_replay.array.lane);
    var r_native = [_]Value{ Value.heap(&t_replay.header), Value.int(2) };
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    _ = try runNative(ct, &r_native);
    var r_replay = [_]Value{ Value.heap(&t_replay.header), Value.int(2) };
    const vals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(vals);
    _ = irinterp.executeValues(&tr, &r_replay, vals);

    const t_once = try buildFloatTable(gpa, K);
    defer t_once.destroy(gpa);
    var r_once = [_]Value{ Value.heap(&t_once.header), Value.int(2) };
    const vals2 = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(vals2);
    _ = irinterp.executeValues(&tr, &r_once, vals2);

    try expectTablesEqual(t_replay, t_once, K);
}

test "nativegen: f64-lane read reduction (aload) matches the strict-FP oracle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (k in array) { acc = acc + a[k]; k += 1 } over the f64 lane. The f64
    // `aload` lowers to `lea` + `movsd` into an XMM, then `addsd` into the carried
    // float accumulator — exercising the read side of Gap A (the write side is
    // covered by the floatWriteTrace tests above). r0=table (.ptr, invariant),
    // r1=k (int, carried), r2=acc (float, carried; proven via the in-loop
    // guard_float). Native and the tier-1a oracle must agree on the accumulated
    // sum bit-for-bit (both use strict-FP `addsd`).
    const gpa = testing.allocator;
    const K: i64 = 40;
    const lane: i32 = @intFromEnum(arr.Lane.f64);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: k
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8: a[k] (float)
        .{ .op = .slot_load, .aux = 2 }, // 9: acc
        .{ .op = .guard_float, .a = 9 }, // 10: acc is float
        .{ .op = .add, .a = 9, .b = 8, .ty = .float }, // 11: acc + a[k] → float
        .{ .op = .konst, .aux = 0 }, // 12: 1 (int)
        .{ .op = .add, .a = 3, .b = 12 }, // 13: k + 1 (int)
        .{ .op = .phi, .b = 11, .aux = 2 }, // acc carry
        .{ .op = .phi, .b = 13, .aux = 1 }, // k carry
        .{ .op = .loop }, // 16
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    const t_f = try buildFloatTable(gpa, K);
    defer t_f.destroy(gpa);
    try testing.expectEqual(arr.Lane.f64, t_f.array.lane);
    // Start at k=2 (the first present key) with acc=0.0; the loop reads a[2..K] and
    // exits when k steps past the dense run. The read is pure (no astore), so a
    // shared table across native + oracle is safe.
    try expectMatch(&tr, &.{ Value.heap(&t_f.header), Value.int(2), Value.float(0.0) });
}

test "nativegen: f64-lane read-modify-write (sunk astore) matches the oracle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // The Gap B store-sinking shape: `while (k in array) { a[k] = a[k] * C; k += 1 }`
    // — a read-modify-write the old C1 rule aborted. The trace reads a[k] (`aload`),
    // multiplies by a constant, and the `astore` is SUNK to the end of the body
    // (after the index increment, before the φ/`.loop`), exactly as `commit()`
    // emits it. The store reuses the read's `aref` (post-CSE the two are one). The
    // native backend must lower the sunk store and agree with the tier-1a oracle
    // bit-for-bit on the mutated heap and the carried index. Termination is via
    // `guard_present` (k steps past the dense run), so the final partial iteration
    // side-exits BEFORE the read — never reaching the sunk store. C = 2.0 is exactly
    // representable, so the products are unambiguous.
    const gpa = testing.allocator;
    const K: i64 = 40;
    const C: f64 = 2.0;
    const lane: i32 = @intFromEnum(arr.Lane.f64);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: k
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5: &a[k]
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8: a[k] (float)
        .{ .op = .konst, .aux = 0 }, // 9: C (float)
        .{ .op = .mul, .a = 8, .b = 9, .ty = .float }, // 10: a[k] * C → the RMW value
        .{ .op = .guard_fits, .a = 10, .aux = lane }, // 11: no-op for f64
        .{ .op = .konst, .aux = 1 }, // 12: 1 (int)
        .{ .op = .add, .a = 3, .b = 12 }, // 13: k + 1
        .{ .op = .astore, .a = 5, .b = 10, .aux = lane }, // 14: SUNK store a[k] = a[k]*C
        .{ .op = .phi, .b = 13, .aux = 1 }, // 15: k carry
        .{ .op = .loop }, // 16
    };
    var consts = [_]Value{ Value.float(C), Value.int(1) };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Separate tables (the trace mutates the heap): native vs the oracle.
    const t_o = try buildFloatTable(gpa, K);
    defer t_o.destroy(gpa);
    try testing.expectEqual(arr.Lane.f64, t_o.array.lane);
    var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
    const ovals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(ovals);
    const oresult = irinterp.executeValues(&tr, &oregs, ovals);

    const t_n = try buildFloatTable(gpa, K);
    defer t_n.destroy(gpa);
    var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const ncomp = try runNative(ct, &nregs);

    try testing.expectEqual(oresult.completed, ncomp.completed);
    try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
    try expectTablesEqual(t_o, t_n, K);
    // Every present slot 2..K now reads (k*0.5)*C, bit-for-bit.
    var k: i64 = 2;
    while (k <= K) : (k += 1) {
        const want: f64 = (@as(f64, @floatFromInt(k)) * 0.5) * C;
        try testing.expectEqual(@as(u64, @bitCast(want)), t_n.getInt(k).payload.bits);
    }
}

test "nativegen: f64-lane multi-store RMW (two sunk astores) matches the oracle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // Gap C (doc 08): the butterfly shape — two RMW stores to two distinct indices per
    // iteration. `while (k, k+1 in array) { a[k]=a[k]*C1; a[k+1]=a[k+1]*C2; k+=2 }`.
    // Both reads (`aload` of a[k] and a[k+1]) precede both stores; the two `astore`s
    // are SUNK to the end of the body (after the k+=2 increment, before the φ/`.loop`),
    // in recorded order — exactly as `commit()` flushes `pending_stores`. The native
    // backend must lower both sunk stores and agree with the tier-1a oracle bit-for-bit
    // on the doubly-mutated heap and the carried index. Termination: the k=K iteration
    // reads a[K] then a[K+1]; `guard_present` on a[K+1] fails (past the dense run) and
    // side-exits BEFORE either sunk store — so that iteration writes nothing in either
    // tier. C1=2.0, C2=3.0 are exactly representable.
    const gpa = testing.allocator;
    const K: i64 = 40;
    const C1: f64 = 2.0;
    const C2: f64 = 3.0;
    const lane: i32 = @intFromEnum(arr.Lane.f64);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: k
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5: &a[k]
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8: a[k]
        .{ .op = .konst, .aux = 1 }, // 9: 1 (int)
        .{ .op = .add, .a = 3, .b = 9 }, // 10: k+1 (int key)
        .{ .op = .aref, .a = 0, .b = 10, .aux = lane }, // 11: &a[k+1]
        .{ .op = .guard_bounds, .a = 11 }, // 12
        .{ .op = .guard_present, .a = 11 }, // 13
        .{ .op = .aload, .a = 11, .aux = lane }, // 14: a[k+1]
        .{ .op = .konst, .aux = 2 }, // 15: C1 (float)
        .{ .op = .mul, .a = 8, .b = 15, .ty = .float }, // 16: a[k]*C1
        .{ .op = .konst, .aux = 3 }, // 17: C2 (float)
        .{ .op = .mul, .a = 14, .b = 17, .ty = .float }, // 18: a[k+1]*C2
        .{ .op = .guard_fits, .a = 16, .aux = lane }, // 19: no-op for f64
        .{ .op = .guard_fits, .a = 18, .aux = lane }, // 20: no-op for f64
        .{ .op = .konst, .aux = 0 }, // 21: 2 (int step)
        .{ .op = .add, .a = 3, .b = 21 }, // 22: k+2
        .{ .op = .astore, .a = 5, .b = 16, .aux = lane }, // 23: SUNK store #1 a[k]=a[k]*C1
        .{ .op = .astore, .a = 11, .b = 18, .aux = lane }, // 24: SUNK store #2 a[k+1]=a[k+1]*C2
        .{ .op = .phi, .b = 22, .aux = 1 }, // 25: k carry
        .{ .op = .loop }, // 26
    };
    var consts = [_]Value{ Value.int(2), Value.int(1), Value.float(C1), Value.float(C2) };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Separate tables (the trace mutates the heap): native vs the oracle.
    const t_o = try buildFloatTable(gpa, K);
    defer t_o.destroy(gpa);
    try testing.expectEqual(arr.Lane.f64, t_o.array.lane);
    var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
    const ovals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(ovals);
    const oresult = irinterp.executeValues(&tr, &oregs, ovals);

    const t_n = try buildFloatTable(gpa, K);
    defer t_n.destroy(gpa);
    var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const ncomp = try runNative(ct, &nregs);

    try testing.expectEqual(oresult.completed, ncomp.completed);
    try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
    try expectTablesEqual(t_o, t_n, K);
    // Spot-check the differential result: even keys 2..38 scaled by C1, odd keys 3..39
    // by C2, key 40 untouched (its iteration side-exited on a[41]'s guard_present).
    var k: i64 = 2;
    while (k <= 39) : (k += 1) {
        const base: f64 = @as(f64, @floatFromInt(k)) * 0.5;
        const want: f64 = if (@rem(k, 2) == 0) base * C1 else base * C2;
        try testing.expectEqual(@as(u64, @bitCast(want)), t_n.getInt(k).payload.bits);
    }
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 20.0))), t_n.getInt(40).payload.bits);
}

test "nativegen: a carried .ptr (table) slot bails (no int/ptr type confusion)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // slot 0 is loaded as a table (guard_table → .ptr) AND written back as an int
    // → it would be classified `carried` and treated as int end-to-end, skipping the
    // table/lane prologue checks and dereferencing an int as a *GcHeader. Must bail.
    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8
        .{ .op = .konst, .aux = 0 }, // 9: 1 (an int)
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index+1
        .{ .op = .phi, .b = 9, .aux = 0 },
        .{ .op = .phi, .b = 10, .aux = 1 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    // slot 0 (the table) carried as an int store → the type-confusion trigger.
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&tr);
}

test "nativegen: guard_present/aload without a dominating guard_bounds bails" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // A malformed trace where guard_present precedes guard_bounds. `present` may be
    // null and idx0 may be OOB → the bitmap `bt`/data load would be unsafe. compile
    // must reject it (never trust the handed-in IR).
    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_present, .a = 5 }, // 6: BEFORE bounds — unsafe
        .{ .op = .guard_bounds, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8
        .{ .op = .konst, .aux = 0 }, // 9
        .{ .op = .add, .a = 3, .b = 9 }, // 10
        .{ .op = .phi, .b = 10, .aux = 1 },
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&tr);
}

// ---------------------------------------------------------------------------
// doc 32: `.value`-lane SCALAR element access — reads and writes.
//
// The `.value` lane is where an array lands once it holds more than one narrow
// type (e.g. an int-lane array that takes a float store: `widenFor` has no
// cross-family rung, so it erases to `.value` permanently). These traces prove
// the fused tag-check-and-side-exit `aload` and the tag+payload `astore`.
// ---------------------------------------------------------------------------

/// A heterogeneous `.value`-lane table: slot 1 holds `anchor` (a table — that is
/// what forces the lane and keeps `optimalLane` from ever re-narrowing it), slots
/// 2..N hold `f(i)`. Mirrors the real erased-array shape.
fn buildValueScalarTable(
    gpa: std.mem.Allocator,
    anchor: *table.Table,
    n: usize,
    comptime f: fn (usize) Value,
) !*table.Table {
    const t = try table.Table.create(gpa);
    errdefer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.heap(&anchor.header));
    var i: usize = 2;
    while (i <= n) : (i += 1) try t.set(gpa, Value.int(@intCast(i)), f(i));
    try testing.expectEqual(arr.Lane.value, t.array.lane);
    return t;
}

fn intElem(i: usize) Value {
    return Value.int(@intCast(i * 3));
}
fn floatElem(i: usize) Value {
    return Value.float(@as(f64, @floatFromInt(i)) * 1.25);
}

test "nativegen(doc 32): .value-lane int-element read scan matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const anchor = try table.Table.create(gpa);
    defer anchor.destroy(gpa);
    const t = try buildValueScalarTable(gpa, anchor, 40, intElem);
    defer t.destroy(gpa);

    const lane: i32 = VALUE_LANE;
    var consts = [_]Value{Value.int(1)};
    // r0=table, r1=index, r2=acc. `acc = acc + t[index]` over the .value lane.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = lane, .ty = .int }, // 7: TAG_INT fused exit
        .{ .op = .guard_int, .a = 7 }, // 8: redundant on native, real on tier-1a
        .{ .op = .slot_load, .aux = 2 }, // 9: acc
        .{ .op = .guard_int, .a = 9 }, // 10
        .{ .op = .add, .a = 9, .b = 7, .ty = .int }, // 11
        .{ .op = .konst, .aux = 0 }, // 12: 1
        .{ .op = .add, .a = 3, .b = 12, .ty = .int }, // 13
        .{ .op = .phi, .b = 13, .aux = 1 },
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .loop },
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Start at 2 (slot 1 holds the anchor TABLE): a clean run to the end, then a
    // guard_bounds exit.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(2), Value.int(0) });
    // Start mid-run — a shorter prefix, same exit.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(25), Value.int(0) });
    // Start AT the table element: the fused TAG_INT check fails on iteration 0, so
    // `completed == 0` and the registers are untouched. This is the shape that used
    // to need a `guard_present` — the tag check subsumes it.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(1), Value.int(0) });
    // Start past the dense run: guard_bounds exits first.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(99), Value.int(0) });
}

test "nativegen(doc 32): .value-lane float-element read reduction matches the oracle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const anchor = try table.Table.create(gpa);
    defer anchor.destroy(gpa);
    const t = try buildValueScalarTable(gpa, anchor, 40, floatElem);
    defer t.destroy(gpa);

    const lane: i32 = VALUE_LANE;
    var consts = [_]Value{ Value.int(1), Value.float(0.0) };
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = lane, .ty = .float }, // 7: TAG_FLOAT + movsd
        .{ .op = .guard_float, .a = 7 }, // 8
        .{ .op = .slot_load, .aux = 2 }, // 9: acc (float)
        .{ .op = .guard_float, .a = 9 }, // 10
        .{ .op = .add, .a = 9, .b = 7, .ty = .float }, // 11
        .{ .op = .konst, .aux = 0 }, // 12: 1
        .{ .op = .add, .a = 3, .b = 12, .ty = .int }, // 13
        .{ .op = .phi, .b = 13, .aux = 1 },
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .loop },
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(2), Value.float(0.0) });
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(30), Value.float(0.0) });
    // Tag mismatch on iteration 0 (slot 1 is a table, not a float).
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(1), Value.float(0.0) });
}

test "nativegen(doc 32): .value-lane int element read as a FLOAT tag-exits every iteration" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const anchor = try table.Table.create(gpa);
    defer anchor.destroy(gpa);
    // Elements are INTs, but the trace was recorded expecting floats — the element
    // type drifted between recording and this entry. The fused TAG_FLOAT check must
    // side-exit immediately rather than reinterpret the int payload as a double.
    const t = try buildValueScalarTable(gpa, anchor, 12, intElem);
    defer t.destroy(gpa);

    const lane: i32 = VALUE_LANE;
    var consts = [_]Value{Value.int(1)};
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = lane },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 3 },
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane },
        .{ .op = .guard_bounds, .a = 5 },
        .{ .op = .aload, .a = 5, .aux = lane, .ty = .float },
        .{ .op = .guard_float, .a = 7 },
        .{ .op = .slot_load, .aux = 2 },
        .{ .op = .guard_float, .a = 9 },
        .{ .op = .add, .a = 9, .b = 7, .ty = .float },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 3, .b = 12, .ty = .int },
        .{ .op = .phi, .b = 13, .aux = 1 },
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .loop },
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // Oracle and native must agree that nothing completes and nothing is written.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(2), Value.float(0.0) });
}

// ---------------------------------------------------------------------------
// Task #29 (codex thread 01a09008): per-chain lane binding. Array lanes are
// proven per ROOT (guard_lane / guard_grid+guard_stride bind each root's
// shape) and per ADDRESS CHAIN (each aref/aload/astore must agree with its
// own root/address op) — never per trace. A trace may mix element widths
// across DIFFERENT arrays (the sparse `vx[col[i]] * val[i]` shape); every
// mismatch WITHIN one chain, missing dominating structural guard, root
// shape conflict, or duplicate slot_load fails closed.
// ---------------------------------------------------------------------------

test "nativegen: mixed-lane roots (int index array into f64 array) admit and match" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // idx: i8 lane holding in-bounds indices into data; data: f64 lane.
    const idx = try table.Table.create(gpa);
    defer idx.destroy(gpa);
    const data = try table.Table.create(gpa);
    defer data.destroy(gpa);
    const K: i64 = 32;
    var i: i64 = 1;
    while (i <= K) : (i += 1) {
        try idx.set(gpa, Value.int(i), Value.int(@rem(i * 7, K) + 1));
        try data.set(gpa, Value.int(i), Value.float(@as(f64, @floatFromInt(i)) * 0.5));
    }
    try testing.expectEqual(arr.Lane.u8, idx.array.lane);
    try testing.expectEqual(arr.Lane.f64, data.array.lane);

    const li: i32 = @intFromEnum(arr.Lane.u8);
    const lf: i32 = @intFromEnum(arr.Lane.f64);
    var consts = [_]Value{Value.int(1)};
    // r0=idx table, r1=data table, r2=i, r3=v: v = data[idx[i]]; i += 1.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: idx
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = li }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: data
        .{ .op = .guard_table, .a = 3 }, // 4
        .{ .op = .guard_lane, .a = 3, .aux = lf }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: i
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .aref, .a = 0, .b = 6, .aux = li }, // 8: idx[i]
        .{ .op = .guard_bounds, .a = 8 }, // 9
        .{ .op = .guard_present, .a = 8 }, // 10
        .{ .op = .aload, .a = 8, .aux = li }, // 11: k (int)
        .{ .op = .aref, .a = 3, .b = 11, .aux = lf }, // 12: data[k]
        .{ .op = .guard_bounds, .a = 12 }, // 13
        .{ .op = .guard_present, .a = 12 }, // 14
        .{ .op = .aload, .a = 12, .aux = lf }, // 15: v (float)
        .{ .op = .konst, .aux = 0 }, // 16
        .{ .op = .add, .a = 6, .b = 16 }, // 17: i + 1
        .{ .op = .phi, .b = 17, .aux = 2 },
        .{ .op = .phi, .b = 15, .aux = 3 },
        .{ .op = .loop },
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    // Full scan (bounds-exit past K), immediate bounds-exit, and mid-run start.
    try expectMatch(&tr, &.{ Value.heap(&idx.header), Value.heap(&data.header), Value.int(1), Value.nil() });
    try expectMatch(&tr, &.{ Value.heap(&idx.header), Value.heap(&data.header), Value.int(K + 3), Value.nil() });
    try expectMatch(&tr, &.{ Value.heap(&idx.header), Value.heap(&data.header), Value.int(20), Value.nil() });
}

test "nativegen: per-chain lane binding refuses every mismatched or unguarded shape" {
    const gpa = testing.allocator;
    const bl: i32 = @intFromEnum(arr.Lane.boolean);
    const l8: i32 = @intFromEnum(arr.Lane.i8);
    const l16: i32 = @intFromEnum(arr.Lane.i16);
    _ = gpa;

    // (a) aload lane != its aref's lane.
    var a = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = bl },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 3 },
        .{ .op = .aref, .a = 0, .b = 3, .aux = bl },
        .{ .op = .guard_bounds, .a = 5 },
        .{ .op = .guard_present, .a = 5 },
        .{ .op = .aload, .a = 5, .aux = l8 }, // MISMATCH vs aref's bool lane
        .{ .op = .phi, .b = 8, .aux = 2 },
        .{ .op = .loop },
    };
    var ta = Trace{ .anchor = undefined, .instrs = &a, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&ta);

    // (b) aref lane != its root's guard_lane.
    a[5] = .{ .op = .aref, .a = 0, .b = 3, .aux = l8 }; // root guarded bool
    a[8] = .{ .op = .aload, .a = 5, .aux = l8 }; // chain-consistent with the aref
    var tb = Trace{ .anchor = undefined, .instrs = &a, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&tb);

    // (c) aref with NO dominating guard_lane on its root.
    var c = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 2 },
        .{ .op = .aref, .a = 0, .b = 2, .aux = bl }, // no guard_lane anywhere
        .{ .op = .guard_bounds, .a = 4 },
        .{ .op = .guard_present, .a = 4 },
        .{ .op = .aload, .a = 4, .aux = bl },
        .{ .op = .phi, .b = 7, .aux = 2 },
        .{ .op = .loop },
    };
    var tc = Trace{ .anchor = undefined, .instrs = &c, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&tc);

    // (d) conflicting guard_lane re-guard of one root.
    var d = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = bl },
        .{ .op = .guard_lane, .a = 0, .aux = l8 }, // CONFLICT
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 4 },
        .{ .op = .aref, .a = 0, .b = 4, .aux = bl },
        .{ .op = .guard_bounds, .a = 6 },
        .{ .op = .guard_present, .a = 6 },
        .{ .op = .aload, .a = 6, .aux = bl },
        .{ .op = .phi, .b = 9, .aux = 2 },
        .{ .op = .loop },
    };
    var td = Trace{ .anchor = undefined, .instrs = &d, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&td);

    // (e) duplicate slot_load of one VM slot.
    var e = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .slot_load, .aux = 0 }, // DUP
        .{ .op = .guard_int, .a = 2 },
        .{ .op = .add, .a = 0, .b = 2 },
        .{ .op = .phi, .b = 4, .aux = 1 },
        .{ .op = .loop },
    };
    var te = Trace{ .anchor = undefined, .instrs = &e, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&te);

    // (f) guard_fits proves ONE width; a different-width int store refuses,
    // and the exact-width pairing is what admits (bitset, not last-wins).
    // Value is a non-const int input so konstFitsLane cannot rescue it.
    var f = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // table (i8 lane)
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = l8 },
        .{ .op = .slot_load, .aux = 1 }, // index
        .{ .op = .guard_int, .a = 3 },
        .{ .op = .slot_load, .aux = 2 }, // value
        .{ .op = .guard_int, .a = 5 },
        .{ .op = .guard_fits, .a = 5, .aux = l16 }, // proof for i16, store is i8
        .{ .op = .aref, .a = 0, .b = 3, .aux = l8 },
        .{ .op = .guard_bounds, .a = 8 },
        .{ .op = .astore, .a = 8, .b = 5, .aux = l8 }, // needs the i8 bit
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 3, .b = 11 },
        .{ .op = .phi, .b = 12, .aux = 1 },
        .{ .op = .loop },
    };
    var fconsts = [_]Value{Value.int(1)};
    var tf = Trace{ .anchor = undefined, .instrs = &f, .consts = &fconsts, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&tf);
    // Exact-width proof admits: prove-level check (kinds/slot_of direct).
    f[7] = .{ .op = .guard_fits, .a = 5, .aux = l8 };
    const tg = Trace{ .anchor = undefined, .instrs = &f, .consts = &fconsts, .entry_slots = &.{}, .entry_guards = &.{} };
    const kinds = try testing.allocator.alloc(nativegen.Kind, f.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, f.len);
    defer testing.allocator.free(slot_of);
    try testing.expect(nativegen.proveKinds(testing.allocator, &tg, kinds, slot_of));
}

test "nativegen: grid/scalar root shape conflicts and grid chain mismatches refuse" {
    const l8: i32 = @intFromEnum(arr.Lane.i8);
    const gi: i32 = @intFromEnum(arr.Lane.i64);
    const gf: i32 = @intFromEnum(arr.Lane.f64);

    // Common prefix: r0=grid table (.ptr via guard_table), r1=row, r2=col.
    // Build the variants by editing one op in a canonical valid-shaped chain.
    const proto_len = 14;
    var g: [proto_len]I = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_grid, .a = 0, .aux = gi }, // 2
        .{ .op = .guard_stride, .a = 0, .aux = 8 }, // 3
        .{ .op = .slot_load, .aux = 1 }, // 4: row
        .{ .op = .guard_int, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: col
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .garow, .a = 0, .b = 4, .aux = gi }, // 8
        .{ .op = .guard_bounds, .a = 8 }, // 9
        .{ .op = .gcell, .a = 8, .b = 6, .aux = gi }, // 10
        .{ .op = .guard_gcol, .a = 10, .b = 6 }, // 11
        .{ .op = .gload, .a = 10, .aux = gi }, // 12
        .{ .op = .loop }, // 13
    };
    const base = g;

    const Variant = struct { at: usize, ins: I };
    const variants = [_]Variant{
        // scalar-bound root re-guarded as grid (guard_lane first).
        .{ .at = 2, .ins = .{ .op = .guard_lane, .a = 0, .aux = l8 } }, // then guard_stride on a scalar root refuses
        // conflicting guard_grid elem re-guard.
        .{ .at = 3, .ins = .{ .op = .guard_grid, .a = 0, .aux = gf } },
        // garow without guard_grid (replaced by a second stride guard - same value, harmless).
        .{ .at = 2, .ins = .{ .op = .guard_stride, .a = 0, .aux = 8 } },
        // garow without guard_stride.
        .{ .at = 3, .ins = .{ .op = .guard_grid, .a = 0, .aux = gi } }, // duplicate same-elem guard is fine; now remove stride
        // gcell elem != its garow's elem.
        .{ .at = 10, .ins = .{ .op = .gcell, .a = 8, .b = 6, .aux = gf } },
        // gload elem != its gcell's elem.
        .{ .at = 12, .ins = .{ .op = .gload, .a = 10, .aux = gf } },
        // garow elem != the root's guard_grid elem.
        .{ .at = 8, .ins = .{ .op = .garow, .a = 0, .b = 4, .aux = gf } },
    };
    for (variants, 0..) |v, vi| {
        g = base;
        g[v.at] = v.ins;
        if (vi == 3) g[3] = v.ins; // "without stride": both slots become guard_grid
        var tv = Trace{ .anchor = undefined, .instrs = &g, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
        try expectBail(&tv);
    }

    // Grid root re-guarded as scalar refuses (grid_elem set, then guard_lane).
    g = base;
    g[3] = .{ .op = .guard_lane, .a = 0, .aux = l8 };
    var ts = Trace{ .anchor = undefined, .instrs = &g, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try expectBail(&ts);
}
