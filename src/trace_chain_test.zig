//! Tests for `trace.zig` — chain.
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

const ArmKind = trace.ArmKind;
const ExitKey = trace.ExitKey;
const IrInstr = trace.IrInstr;
const Trace = trace.Trace;
const TraceState = trace.TraceState;

const util = @import("trace_testutil.zig");
const TestRegs = util.TestRegs;

test "driveChain ordinary_header: chains to a same-anchor sibling" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Trace A at PC 10: the trace whose guard "fails" (faked by calling
    // driveChain directly). After an *ordinary* guard exit the registers are
    // coherent at A's anchor (pc 10), so the driver chains to a same-anchor
    // sibling there — NOT to the guard's exit PC.
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .guard_int, .a = 0, .aux = 20 }, // %1: guard r0 (aux is exit PC, ignored for ordinary chaining)
        .{ .op = .loop }, // %2
    };
    const consts_a = [_]Value{};
    var trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .anchor = .{ .proto = undefined, .pc = 10 },
        .instrs = @constCast(&instrs_a),
        .consts = @constCast(&consts_a),
        .entry_slots = &entry_a,
        .entry_guards = &.{},
    };

    // Trace B: a sibling at the SAME anchor (pc 10) — a simple counting loop
    // (r0 from 0 to 3). Reached only because A is in `initially_excluded`.
    var entry_b = [_]u16{ 0, 1 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (counter)
        .{ .op = .slot_load, .aux = 1 }, // %1: r1 (limit)
        .{ .op = .guard_int, .a = 0, .aux = 10 }, // %2
        .{ .op = .guard_int, .a = 1, .aux = 10 }, // %3
        .{ .op = .konst, .aux = 0 }, // %4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // %5: r0 + 1
        .{ .op = .lt, .a = 5, .b = 1 }, // %6: (r0+1) < limit
        .{ .op = .guard_true, .a = 6, .aux = 10 }, // %7
        .{ .op = .phi, .a = 0, .b = 5, .aux = 0, .ty = .int }, // %8: r0 ← r0+1
        .{ .op = .loop }, // %9
    };
    const consts_b = [_]Value{Value.int(1)};
    var trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .anchor = .{ .proto = undefined, .pc = 10 }, // same anchor as A
        .instrs = @constCast(&instrs_b),
        .consts = @constCast(&consts_b),
        .entry_slots = &entry_b,
        .entry_guards = &.{},
    };

    // Put both traces in the cache.
    try state.cache.append(gpa, trace_a);
    try state.cache.append(gpa, trace_b);

    // Set proto on anchors (needed for findTrace lookup).
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    trace_a.anchor.proto = &proto;
    trace_b.anchor.proto = &proto;

    // Regs: r0=0, r1=4 → Trace B should run 3 iterations (0,1,2;
    // iteration 3 computes 3<4 which is true, runs, then 4<4 fails).
    var regs = [_]Value{ Value.int(0), Value.int(4) };

    // Fake a guard failure in Trace A at instr index 1 (the guard_int), and
    // exclude A (the dispatcher's `visited` set) so the driver walks to B.
    var tr_regs = TestRegs{ .regs = &regs };
    const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false);
    tr_regs.commit(); // the chained side trace mutated the window — reflect it back
    try testing.expect(chained != null);
    try testing.expectEqual(@as(usize, 3), chained.?.completed); // Trace B ran 3 iters
    try testing.expect(chained.?.resume_pc == null);
    try testing.expectEqual(@as(i64, 3), regs[0].asInt()); // r0 carried to 3

    // Remove traces from cache before deinit — they have stack-allocated
    // arrays that must not be freed by destroy().
    state.cache.clearRetainingCapacity();
    // Free the Trace heap allocations ourselves (instrs/consts/entry_slots
    // are stack memory, so skip those fields by not calling destroy).
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "tryArmSiblingHandoff publishes complete Part-S bookkeeping" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity(); // stack-backed traces

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "sibling-publish",
        .num_registers = 1,
    };
    const parent_instrs = [_]IrInstr{
        .{ .op = .guard_true, .aux = 1 },
        .{ .op = .loop },
    };
    const parent_slots = try gpa.alloc(usize, parent_instrs.len);
    defer gpa.free(parent_slots);
    @memset(parent_slots, 0);

    var parent: Trace = .{
        .id = 41,
        .anchor = .{ .proto = &proto, .pc = 7 },
        .instrs = @constCast(&parent_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
        .sibling_watch_exit = 0,
        .sibling_watch_count = 9,
    };
    var child: Trace = .{
        .id = 42,
        .anchor = parent.anchor,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .ordinary_entry = 0xCAFE,
        } },
    };
    try state.cache.append(gpa, &parent);
    try state.cache.append(gpa, &child);
    state.pending_sibling_arm = .{ .trace_id = parent.id, .exit_instr = 0 };

    state.tryArmSiblingHandoff(&child, true);

    try testing.expectEqual(@as(?ExitKey, null), state.pending_sibling_arm);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    const link = state.armed_links.items[0];
    try testing.expectEqual(ArmKind.sibling_handoff, link.kind);
    try testing.expect(link.parent == &parent);
    try testing.expectEqual(@as(u32, 0), link.slot_index);
    try testing.expect(link.child == &child);
    try testing.expectEqual(@as(usize, 0xCAFE), parent_slots[0]);
    try testing.expectEqual(@as(u32, 1), parent.sibling_arms);
    try testing.expectEqual(std.math.maxInt(u32), parent.sibling_watch_exit);
    try testing.expectEqual(@as(u32, 0), parent.sibling_watch_count);
    try testing.expectEqual(@as(u64, 1), state.sibling_handoff_arms);
}

test "in-place re-arm releases the displaced sibling latch (sibling -> ordinary -> sibling -> disarm)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity(); // stack-backed traces

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "sibling-rearm-latch",
        .num_registers = 1,
    };
    const parent_instrs = [_]IrInstr{
        .{ .op = .guard_true, .aux = 1 },
        .{ .op = .loop },
    };
    const parent_slots = try gpa.alloc(usize, parent_instrs.len);
    defer gpa.free(parent_slots);
    @memset(parent_slots, 0);
    var parent: Trace = .{
        .id = 45,
        .anchor = .{ .proto = &proto, .pc = 7 },
        .instrs = @constCast(&parent_instrs),
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .id = 46,
        .anchor = parent.anchor,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xD00D } },
    };
    try state.cache.append(gpa, &parent);
    try state.cache.append(gpa, &child);

    // sibling: latch counts 1.
    try testing.expect(state.publishSiblingArm(&parent, 0, &child));
    try testing.expectEqual(@as(u32, 1), parent.sibling_arms);
    // ordinary displaces the sibling arm in place: latch must drop to 0
    // (codex post-landing blocker: without clearSiblingLatch here the count
    // leaks +1 per displace→republish cycle).
    try testing.expect(try state.armNativeLink(&parent, 0, &child, .ordinary_guard));
    try testing.expectEqual(@as(u32, 0), parent.sibling_arms);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    // sibling republish over the ordinary record: back to 1.
    try testing.expect(state.publishSiblingArm(&parent, 0, &child));
    try testing.expectEqual(@as(u32, 1), parent.sibling_arms);
    // B-3d.1 R6 (§B3.18): `.sibling_handoff` is EXCLUDED from the identical
    // re-arm short-circuit precisely so this stays balanced — an IDENTICAL
    // sibling republish must still route through the re-arm branch, whose
    // clearSiblingLatch (-1) pairs with publishSiblingArm's +1. A
    // short-circuited return would skip the clear and leak the latch to 2.
    try testing.expect(state.publishSiblingArm(&parent, 0, &child));
    try testing.expectEqual(@as(u32, 1), parent.sibling_arms);
    // physical disarm: back to 0, not underflowed.
    state.disarmLinkAt(0);
    try testing.expectEqual(@as(u32, 0), parent.sibling_arms);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
}
