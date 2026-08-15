//! Tests for `nativegen.zig` — arraywrite.
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

const compile = nativegen.compile;
const is_x64_linux = nativegen.is_x64_linux;

const util = @import("nativegen_testutil.zig");
const expectMatch = util.expectMatch;
const expectTablesEqual = util.expectTablesEqual;
const runNative = util.runNative;

// --- B3 write-path helpers + tests -------------------------------------------

/// Build nsieve's sieve shape: a bool-lane table with `p[2..K] = true` (key 1 a
/// hole). Caller owns the returned table.
fn buildBoolTable(gpa: std.mem.Allocator, K: i64) !*table.Table {
    const t = try table.Table.create(gpa);
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    std.debug.assert(t.array.lane == arr.Lane.boolean);
    return t;
}

/// The shared write trace: `while (k in array) { t[k] = false; k += 1 }` over a
/// bool lane. r0 = table (invariant .ptr), r1 = index (carried int). This is
/// exactly nsieve's sieve-clearing inner loop — a pure write of a constant, so
/// there is no `aload` and the C1 rule is trivially satisfied.
fn boolWriteTrace(full: *[13]I, consts: *[2]Value, es: *[0]u16) Trace {
    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    consts.* = .{ Value.boolean(false), Value.int(1) };
    full.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .konst, .aux = 0 }, // 7: false
        .{ .op = .astore, .a = 5, .b = 7, .aux = lane }, // 8: t[index] = false
        .{ .op = .konst, .aux = 1 }, // 9: 1
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index + 1
        .{ .op = .phi, .b = 10, .aux = 1 }, // 11: index carry (was exit_stores)
        .{ .op = .loop }, // 12
    };
    return Trace{ .anchor = undefined, .instrs = full, .consts = consts, .entry_slots = es, .entry_guards = &.{} };
}

test "nativegen: bool-lane t[k]=false write matches the interpreter (heap + regs)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;
    var full: [13]I = undefined;
    var consts: [2]Value = undefined;
    var es: [0]u16 = undefined;
    const tr = boolWriteTrace(&full, &consts, &es);

    // Oracle (tier-1a) and native run on SEPARATE tables — the trace mutates the
    // heap, so a shared table would double-apply. The final heaps must match.
    const t_o = try buildBoolTable(gpa, K);
    defer t_o.destroy(gpa);
    var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
    const ovals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(ovals);
    const oresult = irinterp.executeValues(&tr, &oregs, ovals);

    const t_n = try buildBoolTable(gpa, K);
    defer t_n.destroy(gpa);
    var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
    var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const ncomp = try runNative(ct, &nregs);

    try testing.expectEqual(oresult.completed, ncomp.completed);
    // Only the carried index slot (r1) is comparable — r0 holds each run's distinct
    // table pointer (an invariant slot, never flushed), so it differs by construction.
    try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
    try expectTablesEqual(t_o, t_n, K);
    // Sanity: the sieve really was cleared (every present slot now reads false).
    var k: i64 = 2;
    while (k <= K) : (k += 1) try testing.expect(!t_n.getInt(k).asBool());
}

test "nativegen: astore deopt-replay leaves a deterministic heap (idempotent re-run)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // The real C1 oracle: not native-vs-tier1a (they leave the SAME partial heap on
    // a side-exit, so that comparison can't catch a double-apply), but heap
    // determinism under replay. Model a native run whose iteration is later
    // re-executed by tier-0 against the already-mutated heap: apply the native
    // trace, then apply the oracle trace AGAIN from the same start, on the SAME
    // table. The result must equal a single clean run on a DISTINCT table object.
    const gpa = testing.allocator;
    const K: i64 = 40;
    var full: [13]I = undefined;
    var consts: [2]Value = undefined;
    var es: [0]u16 = undefined;
    const tr = boolWriteTrace(&full, &consts, &es);

    // t_replay: native pass, then a full oracle re-run over the same heap.
    const t_replay = try buildBoolTable(gpa, K);
    defer t_replay.destroy(gpa);
    var r_native = [_]Value{ Value.heap(&t_replay.header), Value.int(2) };
    var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    _ = try runNative(ct, &r_native);
    var r_replay = [_]Value{ Value.heap(&t_replay.header), Value.int(2) };
    const vals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(vals);
    _ = irinterp.executeValues(&tr, &r_replay, vals);

    // t_once: a single clean oracle pass on a fresh, unrelated table.
    const t_once = try buildBoolTable(gpa, K);
    defer t_once.destroy(gpa);
    var r_once = [_]Value{ Value.heap(&t_once.header), Value.int(2) };
    const vals2 = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(vals2);
    _ = irinterp.executeValues(&tr, &r_once, vals2);

    // Double-apply (native then tier-0 replay) == single-apply: the write is
    // idempotent, so re-running an iteration after a deopt reproduces the heap.
    try expectTablesEqual(t_replay, t_once, K);
}

// --- B4b int-lane write-path helpers + tests ---------------------------------

/// Build a narrow int-lane table: keys `2..K` hold `±i` (alternating sign), then
/// key `K` is pinned to `bump` so the monotonic rehash widening lands the array
/// on exactly the lane that `bump` forces. Caller owns the returned table.
fn buildIntTable(gpa: std.mem.Allocator, K: i64, bump: i64) !*table.Table {
    const t = try table.Table.create(gpa);
    var i: i64 = 2;
    while (i <= K) : (i += 1) {
        const v: i64 = if (@rem(i, 2) == 0) i else -i;
        try t.set(gpa, Value.int(i), Value.int(v));
    }
    try t.set(gpa, Value.int(K), Value.int(bump));
    return t;
}

/// `while (k in array) { t[k] = C; k += 1 }` over an int lane, with the mandatory
/// guard_fits ahead of the store. r0 = table (invariant .ptr), r1 = index (carried
/// int). A pure constant write → no `aload`, so C1 is trivially satisfied.
fn intWriteTrace(full: *[14]I, consts: *[2]Value, es: *[0]u16, lane: i32, store_const: i64) Trace {
    consts.* = .{ Value.int(store_const), Value.int(1) };
    full.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .konst, .aux = 0 }, // 7: C
        .{ .op = .guard_fits, .a = 7, .aux = lane }, // 8: C fits the lane
        .{ .op = .astore, .a = 5, .b = 7, .aux = lane }, // 9: t[index] = C
        .{ .op = .konst, .aux = 1 }, // 10: 1
        .{ .op = .add, .a = 3, .b = 10 }, // 11: index + 1
        .{ .op = .phi, .b = 11, .aux = 1 }, // 12: index carry (was exit_stores)
        .{ .op = .loop }, // 13
    };
    return Trace{ .anchor = undefined, .instrs = full, .consts = consts, .entry_slots = es, .entry_guards = &.{} };
}

test "nativegen: int-lane t[k]=C write matches the interpreter (i8/i16/i32/i64)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;

    const Cfg = struct { lane: arr.Lane, bump: i64 };
    const cfgs = [_]Cfg{
        .{ .lane = .i8, .bump = 100 }, // all |v| <= 127
        .{ .lane = .i16, .bump = 1000 }, // exceeds i8
        .{ .lane = .i32, .bump = 100_000 }, // exceeds i16
        .{ .lane = .i64, .bump = 5_000_000_000 }, // exceeds i32
    };

    for (cfgs) |cfg| {
        const lane: i32 = @intFromEnum(cfg.lane);
        // A small negative constant exercises a width-truncating store of a
        // sign-extended value (the low w bytes are the two's-complement encoding).
        const C: i64 = -7;
        var full: [14]I = undefined;
        var consts: [2]Value = undefined;
        var es: [0]u16 = undefined;
        const tr = intWriteTrace(&full, &consts, &es, lane, C);

        // Separate tables: the trace mutates the heap, so a shared table would
        // double-apply. The final heaps (and carried index) must match.
        const t_o = try buildIntTable(gpa, K, cfg.bump);
        defer t_o.destroy(gpa);
        try testing.expectEqual(cfg.lane, t_o.array.lane);
        var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
        const ovals = try gpa.alloc(Value, tr.instrs.len);
        defer gpa.free(ovals);
        const oresult = irinterp.executeValues(&tr, &oregs, ovals);

        const t_n = try buildIntTable(gpa, K, cfg.bump);
        defer t_n.destroy(gpa);
        var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
        var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        const ncomp = try runNative(ct, &nregs);

        try testing.expectEqual(oresult.completed, ncomp.completed);
        try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
        try expectTablesEqual(t_o, t_n, K);
        // Sanity: every present slot 2..K now reads the stored constant.
        var k: i64 = 2;
        while (k <= K) : (k += 1) try testing.expectEqual(C, t_n.getInt(k).asInt());
    }
}

/// Like `intWriteTrace` but with NO `guard_fits` on the stored constant — exactly
/// the IR tropt hands native after it proves the (constant) store value fits the
/// lane and DCEs the always-pass guard. Native must re-derive the static fit
/// (`konstFitsLane`) and compile rather than bail to tier-1a.
fn intWriteTraceNoFits(full: *[13]I, consts: *[2]Value, es: *[0]u16, lane: i32, store_const: i64) Trace {
    consts.* = .{ Value.int(store_const), Value.int(1) };
    full.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .konst, .aux = 0 }, // 7: C  (guard_fits folded away by tropt)
        .{ .op = .astore, .a = 5, .b = 7, .aux = lane }, // 8: t[index] = C
        .{ .op = .konst, .aux = 1 }, // 9: 1
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index + 1
        .{ .op = .phi, .b = 10, .aux = 1 }, // 11: index carry
        .{ .op = .loop }, // 12
    };
    return Trace{ .anchor = undefined, .instrs = full, .consts = consts, .entry_slots = es, .entry_guards = &.{} };
}

test "nativegen: const int-lane t[k]=C write compiles WITHOUT a guard_fits (tropt-DCE'd) and matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;

    const Cfg = struct { lane: arr.Lane, bump: i64 };
    const cfgs = [_]Cfg{
        .{ .lane = .i8, .bump = 100 }, // narrow: konstFitsLane range-checks
        .{ .lane = .i16, .bump = 1000 },
        .{ .lane = .i32, .bump = 100_000 },
        .{ .lane = .i64, .bump = 5_000_000_000 }, // wide: every int fits
    };

    for (cfgs) |cfg| {
        const lane: i32 = @intFromEnum(cfg.lane);
        const C: i64 = -7; // fits every lane above
        var full: [13]I = undefined;
        var consts: [2]Value = undefined;
        var es: [0]u16 = undefined;
        const tr = intWriteTraceNoFits(&full, &consts, &es, lane, C);

        const t_o = try buildIntTable(gpa, K, cfg.bump);
        defer t_o.destroy(gpa);
        try testing.expectEqual(cfg.lane, t_o.array.lane);
        var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
        const ovals = try gpa.alloc(Value, tr.instrs.len);
        defer gpa.free(ovals);
        const oresult = irinterp.executeValues(&tr, &oregs, ovals);

        const t_n = try buildIntTable(gpa, K, cfg.bump);
        defer t_n.destroy(gpa);
        var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
        // The whole point: compile() must NOT bail just because guard_fits is absent.
        var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        const ncomp = try runNative(ct, &nregs);

        try testing.expectEqual(oresult.completed, ncomp.completed);
        try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
        try expectTablesEqual(t_o, t_n, K);
        var k: i64 = 2;
        while (k <= K) : (k += 1) try testing.expectEqual(C, t_n.getInt(k).asInt());
    }
}

test "nativegen: int-lane astore guard_fits side-exits when the value overflows the lane" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // An i8-lane table long enough that the stored index value (`t[k] = k`)
    // outgrows the lane mid-loop: keys run well past 127 while every *initial*
    // value stays in i8 range (fill = -1, a negative → the *signed* i8 lane, not
    // the unsigned-byte u8 lane), so the lane is i8 but the WRITTEN value overflows
    // at k == 128 → guard_fits side-exits there. Native and oracle must stop at the
    // same iteration and leave identical heaps. (The u8 lane's own [0,255]
    // guard_fits boundaries are covered by the dedicated u8 test below.)
    const gpa = testing.allocator;
    const K: i64 = 160;
    const lane: i32 = @intFromEnum(arr.Lane.i8);

    // Build an i8 table of length K with all-small NEGATIVE values (lane stays i8;
    // a non-negative fill would commit the u8 byte lane instead).
    const makeT = struct {
        fn f(g: std.mem.Allocator, n: i64) !*table.Table {
            const t = try table.Table.create(g);
            var i: i64 = 2;
            while (i <= n) : (i += 1) try t.set(g, Value.int(i), Value.int(-1));
            std.debug.assert(t.array.lane == arr.Lane.i8);
            return t;
        }
    }.f;

    // `t[k] = k` (value = the carried index slot, not a constant). guard_fits on
    // the index makes the loop side-exit once k no longer fits i8.
    var consts = [_]Value{Value.int(1)};
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_fits, .a = 3, .aux = lane }, // 7: index fits i8?
        .{ .op = .astore, .a = 5, .b = 3, .aux = lane }, // 8: t[index] = index
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index + 1
        .{ .op = .phi, .b = 10, .aux = 1 },
        .{ .op = .loop }, // 11
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    const start: i64 = 120; // 120..127 fit i8; 128 does not → exit on the 9th key
    const t_o = try makeT(gpa, K);
    defer t_o.destroy(gpa);
    var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(start) };
    const ovals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(ovals);
    const oresult = irinterp.executeValues(&tr, &oregs, ovals);

    const t_n = try makeT(gpa, K);
    defer t_n.destroy(gpa);
    var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(start) };
    var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const ncomp = try runNative(ct, &nregs);

    try testing.expectEqual(@as(usize, 8), oresult.completed); // k = 120..127 committed, 128 exits
    try testing.expectEqual(oresult.completed, ncomp.completed);
    try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
    try expectTablesEqual(t_o, t_n, K);
}

// --- S-E u8-lane (unsigned byte) read/write/guard tests -----------------------

/// Build a u8-lane table: keys `2..K` hold bytes in `[0,255]`, with the last key
/// pinned to a *high* byte (200) so a scan's final load exercises the
/// zero-extension that distinguishes u8 from the signed i8 lane. Caller owns it.
fn buildByteTable(gpa: std.mem.Allocator, K: i64) !*table.Table {
    const t = try table.Table.create(gpa);
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.int(@mod(i * 7, 256)));
    try t.set(gpa, Value.int(K), Value.int(200)); // high byte: 200 zero-extends, ≠ -56
    return t;
}

test "nativegen: u8-lane t[k] read scan zero-extends (high bytes read as 0..255, not sign-extended)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;
    const t = try buildByteTable(gpa, K);
    defer t.destroy(gpa);
    try testing.expectEqual(arr.Lane.u8, t.array.lane);

    const lane: i32 = @intFromEnum(arr.Lane.u8);
    var consts = [_]Value{Value.int(1)};
    // r0=table, r1=index, r2=last load. The aload must `movzx` (zero-extend): a byte
    // 200 reads 200, where a wrong `movsx` would carry -56 and mismatch the oracle
    // (which decodes via array.decode's zero-extend). expectMatch catches the split.
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
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(K), Value.nil() }); // last load = byte 200
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(K + 3), Value.nil() }); // OOB
}

test "nativegen: u8-lane t[k]=C write matches the interpreter (in-range byte)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;
    const lane: i32 = @intFromEnum(arr.Lane.u8);
    const C: i64 = 200; // a high byte: truncating store of 0xC8, read back via zero-extend
    var full: [14]I = undefined;
    var consts: [2]Value = undefined;
    var es: [0]u16 = undefined;
    const tr = intWriteTrace(&full, &consts, &es, lane, C);

    const t_o = try buildByteTable(gpa, K);
    defer t_o.destroy(gpa);
    try testing.expectEqual(arr.Lane.u8, t_o.array.lane);
    var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
    const ovals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(ovals);
    const oresult = irinterp.executeValues(&tr, &oregs, ovals);

    const t_n = try buildByteTable(gpa, K);
    defer t_n.destroy(gpa);
    var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
    var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const ncomp = try runNative(ct, &nregs);

    try testing.expectEqual(oresult.completed, ncomp.completed);
    try testing.expectEqual(oregs[1].payload.bits, nregs[1].payload.bits);
    try expectTablesEqual(t_o, t_n, K);
    var k: i64 = 2;
    while (k <= K) : (k += 1) try testing.expectEqual(C, t_n.getInt(k).asInt()); // every slot = 200
}

test "nativegen: u8-lane astore guard_fits side-exits at the [0,255] boundaries (256 and -1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const K: i64 = 48;
    const lane: i32 = @intFromEnum(arr.Lane.u8);

    // Each out-of-byte constant must side-exit on the FIRST store (k=2, before any
    // mutation): native and oracle both stop with completed==0, heaps untouched.
    for ([_]i64{ 256, -1 }) |C| {
        var full: [14]I = undefined;
        var consts: [2]Value = undefined;
        var es: [0]u16 = undefined;
        const tr = intWriteTrace(&full, &consts, &es, lane, C);

        const t_o = try buildByteTable(gpa, K);
        defer t_o.destroy(gpa);
        try testing.expectEqual(arr.Lane.u8, t_o.array.lane);
        var oregs = [_]Value{ Value.heap(&t_o.header), Value.int(2) };
        const ovals = try gpa.alloc(Value, tr.instrs.len);
        defer gpa.free(ovals);
        const oresult = irinterp.executeValues(&tr, &oregs, ovals);

        const t_n = try buildByteTable(gpa, K);
        defer t_n.destroy(gpa);
        var nregs = [_]Value{ Value.heap(&t_n.header), Value.int(2) };
        var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
        defer ct.deinit();
        const ncomp = try runNative(ct, &nregs);

        try testing.expectEqual(@as(usize, 0), oresult.completed); // guard_fits exits immediately
        try testing.expectEqual(oresult.completed, ncomp.completed);
        try expectTablesEqual(t_o, t_n, K); // both heaps pristine (no store happened)
    }
}

test "nativegen: int-lane astore deopt-replay leaves a deterministic heap (idempotent re-run)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // Same C1 oracle as the bool case, on an i32 lane: native pass then a full
    // tier-0 re-run over the SAME heap must equal a single clean run on a DISTINCT
    // table. The constant write is idempotent, so the replayed iteration is safe.
    const gpa = testing.allocator;
    const K: i64 = 40;
    const lane: i32 = @intFromEnum(arr.Lane.i32);
    const C: i64 = 70_000; // forces i32 nothing here; just a representative i32 value
    var full: [14]I = undefined;
    var consts: [2]Value = undefined;
    var es: [0]u16 = undefined;
    const tr = intWriteTrace(&full, &consts, &es, lane, C);

    const t_replay = try buildIntTable(gpa, K, 100_000); // i32 lane
    defer t_replay.destroy(gpa);
    try testing.expectEqual(arr.Lane.i32, t_replay.array.lane);
    var r_native = [_]Value{ Value.heap(&t_replay.header), Value.int(2) };
    var ct = compile(gpa, &tr) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    _ = try runNative(ct, &r_native);
    var r_replay = [_]Value{ Value.heap(&t_replay.header), Value.int(2) };
    const vals = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(vals);
    _ = irinterp.executeValues(&tr, &r_replay, vals);

    const t_once = try buildIntTable(gpa, K, 100_000);
    defer t_once.destroy(gpa);
    var r_once = [_]Value{ Value.heap(&t_once.header), Value.int(2) };
    const vals2 = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(vals2);
    _ = irinterp.executeValues(&tr, &r_once, vals2);

    try expectTablesEqual(t_replay, t_once, K);
}
