//! Tests for `trace.zig` — widen-eviction (`laneWidenedPast`).
//!
//! The predicate's premise is lane monotonicity, and monotonicity begins only
//! at the one-shot lane commitment (`ArrayPart.frozen`, set by
//! `commitFreshLane`). A fresh, unfrozen `.value` array is lane-UNDECIDED: its
//! first real store will commit it to a narrow lane, so a narrow `guard_lane`
//! can absolutely pass on a later entry. Treating that state as "widened past"
//! caused a per-outer-iteration mint→retire→re-record churn on every
//! fill-a-fresh-table loop (`local r = {}; for j=1,n do r[j]=v end` — ~600
//! full record+compile+retire rounds per grid_matmul run, doc 47 increment D).

const trace = @import("trace.zig");
const std = @import("std");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

const Value = value.Value;
const RegWindow = regwindow.RegWindow;
const IrInstr = trace.IrInstr;
const Trace = trace.Trace;
const TraceState = trace.TraceState;
const EntryGuard = trace.EntryGuard;
const ExitProvEntry = trace.ExitProvEntry;

/// A minimal trace whose IR pins `guard_lane(lane)` on the table in tier-0
/// register 0: `%0 slot_load r0; %1 guard_lane %0 aux=lane`. Exactly the shape
/// `laneWidenedPast` walks (guard_lane.a → slot_load → .aux register).
fn laneGuardTrace(gpa: std.mem.Allocator, lane: arr.Lane) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.alloc(IrInstr, 2);
    instrs[0] = .{ .op = .slot_load, .aux = 0 };
    instrs[1] = .{ .op = .guard_lane, .a = 0, .aux = @intFromEnum(lane) };
    t.* = .{
        .code = .{
            .anchor = .{ .proto = undefined, .pc = 0 },
            .instrs = instrs,
            .consts = try gpa.alloc(Value, 0),
            .entry_slots = try gpa.alloc(u16, 0),
            .entry_guards = try gpa.alloc(EntryGuard, 0),
            .exit_prov = try gpa.alloc(ExitProvEntry, 0),
        },
        .id = 1,
    };
    return t;
}

fn destroyLaneGuardTrace(gpa: std.mem.Allocator, t: *Trace) void {
    t.code.deinit(gpa);
    gpa.destroy(t);
}

test "widen-eviction predicate: unfrozen .value array never evicts (lane-undecided), frozen .value does" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const t = try laneGuardTrace(gpa, .f64);
    defer destroyLaneGuardTrace(gpa, t);

    const tbl = try table_mod.Table.create(gpa);
    defer tbl.destroy(gpa);

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.heap(&tbl.header));

    // Fresh `{}`: `.value`, unfrozen — the state every next-outer-iteration
    // fill table is in when the dispatcher first enters the fill trace. The
    // first real store will commit it to `.f64`, so the guard can still pass:
    // NOT widened past (the doc 47 increment D fix).
    try testing.expectEqual(arr.Lane.value, tbl.array.lane);
    try testing.expect(!tbl.array.frozen);
    try testing.expect(!state.laneWidenedPast(t, regs));

    // The same `.value` lane FROZEN (a table demoted to `.value` by a
    // type-incompatible store keeps its commitment): `.value` is the lattice
    // top and reaches nothing, so an f64 pin is permanently dead → evict.
    tbl.array.frozen = true;
    try testing.expect(state.laneWidenedPast(t, regs));
}

test "widen-eviction predicate: frozen lanes follow canWidenTo reachability" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const tbl = try table_mod.Table.create(gpa);
    defer tbl.destroy(gpa);
    tbl.array.frozen = true;

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.heap(&tbl.header));

    // Same lane as the pin: guard passes today → no eviction.
    {
        const t = try laneGuardTrace(gpa, .f64);
        defer destroyLaneGuardTrace(gpa, t);
        tbl.array.lane = .f64;
        try testing.expect(!state.laneWidenedPast(t, regs));
    }
    // Live `.i8` vs an `.i16` pin: not equal, but `i8.canWidenTo(i16)` — the
    // array can still reach the pinned lane → no eviction.
    {
        const t = try laneGuardTrace(gpa, .i16);
        defer destroyLaneGuardTrace(gpa, t);
        tbl.array.lane = .i8;
        try testing.expect(!state.laneWidenedPast(t, regs));
    }
    // Live `.i64` vs an `.i16` pin: ints never re-narrow → permanently dead →
    // evict (the original, still-correct eviction case).
    {
        const t = try laneGuardTrace(gpa, .i16);
        defer destroyLaneGuardTrace(gpa, t);
        tbl.array.lane = .i64;
        try testing.expect(state.laneWidenedPast(t, regs));
    }
}
