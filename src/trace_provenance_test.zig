//! Tests for `trace.zig` — provenance.
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

const AnchorKey = trace.AnchorKey;
const ArmKind = trace.ArmKind;
const ExitKey = trace.ExitKey;
const ExitProvEntry = trace.ExitProvEntry;
const ExitProvenance = trace.ExitProvenance;
const IrInstr = trace.IrInstr;
const ProgramPoint = trace.ProgramPoint;
const PromotedEdge = trace.PromotedEdge;
const ProvenanceVerdict = trace.ProvenanceVerdict;
const RegionBridgeDef = trace.RegionBridgeDef;
const RegionId = trace.RegionId;
const StructuralEdgeId = trace.StructuralEdgeId;
const Trace = trace.Trace;
const TraceState = trace.TraceState;
const isLoopDoneGuardIndex = trace.isLoopDoneGuardIndex;

const util = @import("trace_testutil.zig");
const TestRegs = util.TestRegs;

test "B-2a provenance edge storage retires endpoints, condemns parents, and clears" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity(); // stack-backed traces

    try state.provenance_edges.append(gpa, .{ .parent_id = 1, .exit_instr = 10, .child_id = 2 });
    try state.provenance_edges.append(gpa, .{ .parent_id = 3, .exit_instr = 11, .child_id = 1, .strikes = 2 });
    try state.provenance_edges.append(gpa, .{ .parent_id = 4, .exit_instr = 12, .child_id = 5 });

    state.retireProvenanceEdgesTouching(1);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(@as(u32, 4), state.provenance_edges.items[0].parent_id);

    try state.provenance_edges.append(gpa, .{ .parent_id = 6, .exit_instr = 13, .child_id = 5 });
    state.retireProvenanceEdgesTouching(5);
    try testing.expectEqual(@as(usize, 0), state.provenance_edges.items.len);

    const proto = Proto{ .code = &.{}, .name = "provenance-lifecycle", .num_registers = 0 };
    var condemned_parent: Trace = .{
        .id = 7,
        .anchor = .{ .proto = &proto, .pc = 20 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    var surviving_parent: Trace = .{
        .id = 9,
        .anchor = .{ .proto = &proto, .pc = 30 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try state.cache.append(gpa, &condemned_parent);
    try state.cache.append(gpa, &surviving_parent);
    try state.provenance_edges.append(gpa, .{ .parent_id = 7, .exit_instr = 14, .child_id = 8 });
    try state.provenance_edges.append(gpa, .{ .parent_id = 9, .exit_instr = 15, .child_id = 10 });

    state.condemnProvenanceEdgesAt(condemned_parent.anchor);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(@as(u32, 9), state.provenance_edges.items[0].parent_id);

    state.clearProvenanceEdges();
    try testing.expectEqual(@as(usize, 0), state.provenance_edges.items.len);
}

test "B-2b commit provenance creates same-anchor edge, skips null/cross-anchor, and latches DONE" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "commit-provenance", .num_registers = 1 };
    var parent_instrs = [_]IrInstr{ .{ .op = .guard_true, .aux = 1 }, .{ .op = .loop } };
    var counts = [_]u8{ 7, 0 };
    var parent: Trace = .{
        .id = 51,
        .anchor = .{ .proto = &proto, .pc = 4 },
        .instrs = &parent_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_counts = &counts,
    };
    var child: Trace = .{
        .id = 52,
        .anchor = parent.anchor,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    var cross: Trace = .{
        .id = 53,
        .anchor = .{ .proto = &proto, .pc = 9 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    for ([_]*Trace{ &parent, &child, &cross }) |t| try state.cache.append(gpa, t);

    state.rec.side_src = .{ .trace_id = parent.id, .exit_instr = 0 };
    state.finishSideTraceProvenance(&child);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(parent.id, state.provenance_edges.items[0].parent_id);
    try testing.expectEqual(child.id, state.provenance_edges.items[0].child_id);
    try testing.expectEqual(Trace.EXIT_COUNT_DONE, counts[0]);
    try testing.expectEqual(@as(?ExitKey, null), state.rec.side_src);

    // No source is a strict no-op.
    state.finishSideTraceProvenance(&child);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);

    // Cross-anchor side traces keep Pall's historical DONE latch but never arm.
    counts[0] = 8;
    state.rec.side_src = .{ .trace_id = parent.id, .exit_instr = 0 };
    state.finishSideTraceProvenance(&cross);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(Trace.EXIT_COUNT_DONE, counts[0]);
}

test "B-2b commit provenance OOM does not latch DONE" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = fa.allocator();
    var state = TraceState.init(gpa);
    defer {
        fa.fail_index = std.math.maxInt(usize);
        fa.resize_fail_index = std.math.maxInt(usize);
        state.cache.clearRetainingCapacity();
        state.deinit();
    }

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "commit-provenance-oom", .num_registers = 1 };
    var parent_instrs = [_]IrInstr{ .{ .op = .guard_true, .aux = 1 }, .{ .op = .loop } };
    var counts = [_]u8{ 9, 0 };
    var parent: Trace = .{ .id = 61, .anchor = .{ .proto = &proto, .pc = 4 }, .instrs = &parent_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_counts = &counts };
    var child: Trace = .{ .id = 62, .anchor = parent.anchor, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &parent);
    try state.cache.append(gpa, &child);
    state.rec.side_src = .{ .trace_id = parent.id, .exit_instr = 0 };
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;

    state.finishSideTraceProvenance(&child);
    try testing.expectEqual(@as(usize, 0), state.provenance_edges.items.len);
    try testing.expectEqual(@as(u8, 9), counts[0]);
    try testing.expectEqual(@as(?ExitKey, null), state.rec.side_src);
}

test "B-2b provenance drain arms compiled children, deletes unsupported edges, preserves observation edges, drops unresolved ids" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "provenance-drain", .num_registers = 1 };
    var parent_instrs = [_]IrInstr{ .{ .op = .guard_true, .aux = 1 }, .{ .op = .loop } };
    const slots = try gpa.alloc(usize, parent_instrs.len);
    defer gpa.free(slots);
    @memset(slots, 0);
    var parent: Trace = .{
        .id = 71,
        .anchor = .{ .proto = &proto, .pc = 4 },
        .instrs = &parent_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = slots, .gpa = gpa } },
        .sibling_watch_exit = 0,
        .sibling_watch_count = 4,
    };
    // Child arrives pre-compiled: the drain's on-demand `nativeFor` returns the
    // cached entry without attempting compilation (a real provenance child is
    // compiled by the drain itself the first safe time it's seen; a child whose
    // compilation fails caches `.unsupported` and the edge is deleted per
    // §B.6(5) — covered below via `child_bad`).
    var child: Trace = .{ .id = 72, .anchor = parent.anchor, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xB2B2 } } };
    var child_bad: Trace = .{ .id = 73, .anchor = parent.anchor, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .native = .unsupported };
    try state.cache.append(gpa, &parent);
    try state.cache.append(gpa, &child);
    try state.cache.append(gpa, &child_bad);
    try state.provenance_edges.append(gpa, .{ .parent_id = parent.id, .exit_instr = 0, .child_id = child.id });
    try state.provenance_edges.append(gpa, .{ .parent_id = parent.id, .exit_instr = 0, .child_id = child_bad.id });
    state.provenance_arms_pending = true; // finishSideTraceProvenance sets this on append

    state.drainProvenanceArms(false);
    try testing.expectEqual(@as(usize, 2), state.provenance_edges.items.len);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Safe drain: the compiled child arms; the unsupported child's edge is
    // deleted (never rescan a permanently-unsupported child) while the armed
    // child's edge is PRESERVED as the observation record.
    state.drainProvenanceArms(true);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(child.id, state.provenance_edges.items[0].child_id);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    try testing.expectEqual(ArmKind.sibling_handoff, state.armed_links.items[0].kind);
    try testing.expectEqual(@as(usize, 0xB2B2), slots[0]);
    try testing.expectEqual(@as(u32, 1), parent.sibling_arms);
    try testing.expectEqual(std.math.maxInt(u32), parent.sibling_watch_exit);
    try testing.expectEqual(@as(u64, 1), state.sibling_handoff_arms);

    try state.provenance_edges.append(gpa, .{ .parent_id = parent.id, .exit_instr = 0, .child_id = 9999 });
    state.provenance_arms_pending = true;
    state.drainProvenanceArms(true);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(child.id, state.provenance_edges.items[0].child_id);
}

test "B-2b region low-yield condemnation deletes only the owner provenance" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();
    state.config.max_penalty = 1;

    const proto = Proto{ .code = &.{}, .name = "provenance-condemn", .num_registers = 0 };
    const owner = AnchorKey{ .proto = &proto, .pc = 10 };
    var p1: Trace = .{ .id = 81, .anchor = owner, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var p2: Trace = .{ .id = 82, .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &p1);
    try state.cache.append(gpa, &p2);
    try state.provenance_edges.append(gpa, .{ .parent_id = p1.id, .exit_instr = 0, .child_id = 91 });
    try state.provenance_edges.append(gpa, .{ .parent_id = p2.id, .exit_instr = 0, .child_id = 92 });

    const rid: RegionId = @enumFromInt(700);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.alloc(ProgramPoint, 0),
        .owner = owner,
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    state.flushRegionWindow(.{ .region_id = rid, .activation = 1 }, 1);
    try testing.expectEqual(@as(usize, 1), state.provenance_edges.items.len);
    try testing.expectEqual(p2.id, state.provenance_edges.items[0].parent_id);
}

test "B-2b complete-ledger cycle strikes retire at three, while prologue-fail is neutral and progress resets" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "provenance-cycle", .num_registers = 1 };
    var p_instrs = [_]IrInstr{ .{ .op = .guard_true, .aux = 1 }, .{ .op = .loop } };
    var c_instrs = [_]IrInstr{ .{ .op = .guard_false, .aux = 1 }, .{ .op = .loop } };
    const p_slots = try gpa.alloc(usize, p_instrs.len);
    defer gpa.free(p_slots);
    @memset(p_slots, 0);
    const c_slots = try gpa.alloc(usize, c_instrs.len);
    defer gpa.free(c_slots);
    @memset(c_slots, 0);
    var parent: Trace = .{
        .id = 101,
        .anchor = .{ .proto = &proto, .pc = 4 },
        .instrs = &p_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = p_slots, .gpa = gpa, .ordinary_entry = 0xA101 } },
    };
    var child: Trace = .{
        .id = 102,
        .anchor = parent.anchor,
        .instrs = &c_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = c_slots, .gpa = gpa, .ordinary_entry = 0xA102 } },
    };
    try state.cache.append(gpa, &parent);
    try state.cache.append(gpa, &child);
    try state.provenance_edges.append(gpa, .{ .parent_id = parent.id, .exit_instr = 0, .child_id = child.id, .strikes = 1 });
    try testing.expect(state.publishSiblingArm(&parent, 0, &child));
    try testing.expect(state.publishSiblingArm(&child, 0, &parent));
    var regs_buf = [_]Value{Value.int(0)};
    var regs = TestRegs{ .regs = &regs_buf };

    // One-way prologue failure proves no completed alternation: no strike/reset.
    const prologue = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = child.id, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    _ = state.driveDispatcherLedger(&parent, &prologue, &proto, regs.view(), true);
    try testing.expectEqual(@as(u8, 1), state.provenance_edges.items[0].strikes);

    // The relation fired and later service advanced cum: reset strikes to zero.
    const productive = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    _ = state.driveDispatcherLedger(&parent, &productive, &proto, regs.view(), true);
    try testing.expectEqual(@as(u8, 0), state.provenance_edges.items[0].strikes);

    // A reporting suffix begins after the suppressed prefix's cumulative count,
    // not at zero. With cum already at one this closed zero-progress alternation
    // is a strike; a zero baseline would misclassify row 0 as productive.
    const suffix_zero_cycle = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var suffix_verdicts: [irinterp.LEDGER_CAP]ProvenanceVerdict = undefined;
    try testing.expectEqual(@as(usize, 1), state.captureProvenanceVerdicts(&suffix_zero_cycle, 1, &suffix_verdicts));
    try testing.expectEqual(.strike, suffix_verdicts[0].action);
    try testing.expectEqual(@as(usize, 1), state.captureProvenanceVerdicts(&suffix_zero_cycle, 0, &suffix_verdicts));
    try testing.expectEqual(.reset, suffix_verdicts[0].action);

    const silent_edge = PromotedEdge{
        .parent = &parent,
        .exit = 0,
        .kind = .deopt,
        .child = &child,
        .arm_kind = .sibling_handoff,
        .resume_pc = child.anchor.pc,
    };

    // Every internal native origin uses the same ordinary-vs-silent capture
    // transaction. Pin both verdict directions at each origin: productive
    // service resets, while a completed zero-progress revolution strikes.
    const native_origins = [_]TraceState.NativeCallOrigin{
        .dispatcher_root,
        .drive_chain_seed,
        .inner_call,
        .continuation_call,
    };
    const origin_productive = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    const origin_zero = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    for (native_origins) |native_origin| {
        state.provenance_edges.items[0].strikes = 2;
        const ordinary_productive = state.captureNativeCallProvenance(native_origin, .{
            .completed = 1,
            .exit_instr = 0,
            .ledger_len = origin_productive.len,
        }, &origin_productive);
        state.settleNativeCallProvenance(&ordinary_productive, false);
        const ordinary_reset_strikes = state.provenance_edges.items[0].strikes;
        try testing.expectEqual(@as(u8, 0), ordinary_reset_strikes);

        state.provenance_edges.items[0].strikes = 2;
        state.stageSilentSiblingProvenance(silent_edge, 1, true, false);
        const silent_productive = state.captureNativeCallProvenance(native_origin, .{
            .completed = 1,
            .exit_instr = 0,
            .silent_active = 1,
        }, &.{});
        state.settleNativeCallProvenance(&silent_productive, false);
        try testing.expectEqual(ordinary_reset_strikes, state.provenance_edges.items[0].strikes);

        state.provenance_edges.items[0].strikes = 0;
        const ordinary_zero = state.captureNativeCallProvenance(native_origin, .{
            .completed = 0,
            .exit_instr = 0,
            .ledger_len = origin_zero.len,
        }, &origin_zero);
        state.settleNativeCallProvenance(&ordinary_zero, false);
        const ordinary_strike_count = state.provenance_edges.items[0].strikes;
        try testing.expectEqual(@as(u8, 1), ordinary_strike_count);

        state.provenance_edges.items[0].strikes = 0;
        state.stageSilentSiblingProvenance(silent_edge, 1, false, true);
        const silent_zero = state.captureNativeCallProvenance(native_origin, .{
            .completed = 0,
            .exit_instr = 0,
            .silent_active = 1,
        }, &.{});
        state.settleNativeCallProvenance(&silent_zero, false);
        try testing.expectEqual(ordinary_strike_count, state.provenance_edges.items[0].strikes);
    }

    // (i) Followed, then child exits without progress or return: both streams
    // produce no verdict and preserve the old strikes.
    const incomplete = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    state.provenance_edges.items[0].strikes = 2;
    var reporting_verdicts: [irinterp.LEDGER_CAP]ProvenanceVerdict = undefined;
    const reporting_incomplete_len = state.captureProvenanceVerdicts(&incomplete, 0, &reporting_verdicts);
    state.applyProvenanceVerdicts(reporting_verdicts[0..reporting_incomplete_len]);
    const reporting_incomplete_strikes = state.provenance_edges.items[0].strikes;
    state.provenance_edges.items[0].strikes = 2;
    state.stageSilentSiblingProvenance(silent_edge, 1, false, false);
    state.ledger_scratch[0] = incomplete[1];
    var merged: [TraceState.PROVENANCE_VERDICT_CAP]ProvenanceVerdict = undefined;
    try testing.expectEqual(
        TraceState.PROMOTED_SET_CAP + irinterp.LEDGER_CAP,
        state.silent_provenance.len,
    );
    var merged_len = state.captureSilentSuffixProvenance(.{
        .completed = 0,
        .exit_instr = 0,
        .silent_active = 1,
        .ledger_len = 1,
        .silent_cum = 0,
    }, &merged);
    state.applyProvenanceVerdicts(merged[0..merged_len]);
    try testing.expectEqual(reporting_incomplete_strikes, state.provenance_edges.items[0].strikes);

    // Productivity before the sibling firing is unrelated: reporting starts
    // this edge's progress interval at P→C and remains neutral when C exits
    // without progress or a return to P.
    const earlier_productive = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    state.provenance_edges.items[0].strikes = 2;
    const earlier_len = state.captureProvenanceVerdicts(&earlier_productive, 0, &reporting_verdicts);
    state.applyProvenanceVerdicts(reporting_verdicts[0..earlier_len]);
    const earlier_reporting_strikes = state.provenance_edges.items[0].strikes;
    state.provenance_edges.items[0].strikes = 2;
    // Native ordering image: ordinal 1 was productive, P→C first fired at 2.
    // The third transition materialized but was not followed when the rowless
    // budget stop landed on it, so the sibling neither saw later productivity
    // nor completed a revolution back to its parent.
    // Round-6: the cell IS the ordering image — this edge fired once, at ordinal 2,
    // never productively; the call's only productive transition was ordinal 1.
    // B-3d (D3): `returned_to_parent` is measured — with no live cell firing out
    // of P after ordinal 2 and no suffix arrival at P, no return happened.
    const earlier_evidence = state.silentSiblingEvidence(
        .{
            .region_work = 0,
            .selection_work = 0,
            .qualifying_rows = 0,
            .productive_firings = 0,
            .last_local = 0,
            .last_productive_ordinal = 0,
            .firings = 1,
            .last_ordinal = 2,
        },
        1, // followed
        1, // call-global last productive ordinal
        parent.id,
        &.{}, // no reporting suffix
    );
    try testing.expect(!earlier_evidence.productive);
    try testing.expect(!earlier_evidence.returned_to_parent);
    state.stageSilentSiblingProvenance(
        silent_edge,
        1,
        earlier_evidence.productive,
        earlier_evidence.returned_to_parent,
    );
    merged_len = state.captureSilentSuffixProvenance(.{ .completed = 1, .exit_instr = 0, .silent_active = 1 }, &merged);
    state.applyProvenanceVerdicts(merged[0..merged_len]);
    try testing.expectEqual(earlier_reporting_strikes, state.provenance_edges.items[0].strikes);

    // A trace may own multiple physical-exit phases in one promoted ring.
    // Reporting considers the later P.exit_b row a return to P.exit_a even
    // though the four-edge revolution has not completed. The frozen phase
    // distance must reproduce that weaker trace-id return condition.
    var x: Trace = .{
        .id = 103,
        .anchor = .{ .proto = &proto, .pc = 8 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    const repeated_parent_rows = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = parent.id, .exit = 1, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    state.provenance_edges.items[0].strikes = 0;
    const repeated_reporting_len = state.captureProvenanceVerdicts(
        &repeated_parent_rows,
        0,
        &reporting_verdicts,
    );
    state.applyProvenanceVerdicts(reporting_verdicts[0..repeated_reporting_len]);
    const repeated_reporting_strikes = state.provenance_edges.items[0].strikes;
    try testing.expectEqual(@as(u8, 1), repeated_reporting_strikes);

    // B-3d (D3, §B3.17 R3): a return to P is MEASURED — either some live cell
    // whose edge fires OUT of P recorded a strictly later ordinal (a repeated
    // parent counts even via a different physical exit), or the reporting
    // suffix contains a row owned by P. Fabricate the summary image the
    // epilogues would have written for a repeated-parent set: P→C fired at
    // ordinal 1, P.exit1→X fired at ordinal 3 — that later firing out of P IS
    // the arrival evidence the ring's return distance used to reconstruct.
    var fab_edges = [_]PromotedEdge{
        silent_edge,
        .{ .parent = &parent, .exit = 1, .kind = .deopt, .child = &x, .arm_kind = .ordinary_guard, .resume_pc = x.anchor.pc },
    };
    var fab_summary = [_]nativegen.SilentSummaryCell{
        .{ .region_work = 0, .selection_work = 0, .qualifying_rows = 0, .productive_firings = 0, .last_local = 0, .last_productive_ordinal = 0, .firings = 1, .last_ordinal = 1 },
        .{ .region_work = 0, .selection_work = 0, .qualifying_rows = 0, .productive_firings = 0, .last_local = 0, .last_productive_ordinal = 0, .firings = 1, .last_ordinal = 3 },
    };
    var fab_metadata: [2]nativegen.SilentExitMetadata = undefined;
    try state.promoted_sets.append(gpa, .{
        .edges = &fab_edges,
        .summary = &fab_summary,
        .metadata = &fab_metadata,
        .region_key = .{ .region_id = @enumFromInt(0), .activation = 0 },
        .id = 999,
    });
    const repeated_evidence = state.silentSiblingEvidence(
        fab_summary[0],
        1, // followed
        0, // no productive transition anywhere in the call
        parent.id,
        &.{},
    );
    try testing.expect(repeated_evidence.returned_to_parent);
    // Self-semantics (R3): the firing under judgment is never its own return
    // evidence — the LATEST firing out of P (ordinal 3) has no later arrival.
    const latest_evidence = state.silentSiblingEvidence(fab_summary[1], 1, 0, parent.id, &.{});
    try testing.expect(!latest_evidence.returned_to_parent);
    // Suffix disjunct + R4 arrival ownership: a suffix row owned by P counts as
    // a return, and a `.prologue_fail` row's owner is `row.id` — the trace whose
    // prologue failed — exactly as `captureProvenanceVerdicts` scans it.
    const suffix_arrival = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .prologue_fail, .outcome = .normal },
    };
    const suffix_evidence = state.silentSiblingEvidence(fab_summary[1], 1, 0, parent.id, &suffix_arrival);
    try testing.expect(suffix_evidence.returned_to_parent);
    _ = state.promoted_sets.pop();
    state.provenance_edges.items[0].strikes = 0;
    state.stageSilentSiblingProvenance(
        silent_edge,
        1,
        repeated_evidence.productive,
        repeated_evidence.returned_to_parent,
    );
    merged_len = state.captureSilentSuffixProvenance(
        .{ .completed = 0, .exit_instr = 0, .silent_active = 1 },
        &merged,
    );
    state.applyProvenanceVerdicts(merged[0..merged_len]);
    try testing.expectEqual(repeated_reporting_strikes, state.provenance_edges.items[0].strikes);

    // (ii) Budget truncation before returning to P is likewise neutral.
    state.provenance_edges.items[0].strikes = 2;
    state.stageSilentSiblingProvenance(silent_edge, 1, false, false);
    merged_len = state.captureSilentSuffixProvenance(.{ .completed = 0, .exit_instr = 0, .silent_active = 1 }, &merged);
    state.applyProvenanceVerdicts(merged[0..merged_len]);
    try testing.expectEqual(reporting_incomplete_strikes, state.provenance_edges.items[0].strikes);

    // (iii) A complete zero-progress revolution returns to P and strikes once.
    const zero_revolution = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    state.provenance_edges.items[0].strikes = 0;
    const reporting_zero_len = state.captureProvenanceVerdicts(&zero_revolution, 0, &reporting_verdicts);
    state.applyProvenanceVerdicts(reporting_verdicts[0..reporting_zero_len]);
    const reporting_zero_strikes = state.provenance_edges.items[0].strikes;
    state.provenance_edges.items[0].strikes = 0;
    state.stageSilentSiblingProvenance(silent_edge, 1, false, true);
    merged_len = state.captureSilentSuffixProvenance(.{ .completed = 0, .exit_instr = 0, .silent_active = 1 }, &merged);
    state.applyProvenanceVerdicts(merged[0..merged_len]);
    try testing.expectEqual(reporting_zero_strikes, state.provenance_edges.items[0].strikes);

    // (iv) Productive prefix dominates a suffix-local strike for the same edge.
    const productive_whole_call = [_]irinterp.LedgerEntry{
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 1, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    state.provenance_edges.items[0].strikes = 2;
    const reporting_productive_len = state.captureProvenanceVerdicts(&productive_whole_call, 0, &reporting_verdicts);
    state.applyProvenanceVerdicts(reporting_verdicts[0..reporting_productive_len]);
    const reporting_productive_strikes = state.provenance_edges.items[0].strikes;
    state.provenance_edges.items[0].strikes = 2;
    state.stageSilentSiblingProvenance(silent_edge, 1, true, false);
    @memcpy(state.ledger_scratch[0..suffix_zero_cycle.len], &suffix_zero_cycle);
    state.stageSilentSuffixProvenance(&suffix_zero_cycle, 1);
    merged_len = state.captureSilentSuffixProvenance(.{
        .completed = 1,
        .exit_instr = 0,
        .silent_active = 1,
        .ledger_len = suffix_zero_cycle.len,
        .silent_cum = 1,
    }, &merged);
    state.applyProvenanceVerdicts(merged[0..merged_len]);
    try testing.expectEqual(reporting_productive_strikes, state.provenance_edges.items[0].strikes);
    state.provenance_edges.items[0].strikes = 0;

    // P→C, an intervening child row, then P again at unchanged cum: one strike
    // per complete burst, applied only after replay. The third retires relation
    // and exact physical P→C arm; the reverse Part-S arm remains live.
    const zero_cycle = [_]irinterp.LedgerEntry{
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 0, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    _ = state.driveDispatcherLedger(&parent, &zero_cycle, &proto, regs.view(), true);
    try testing.expectEqual(@as(u8, 1), state.provenance_edges.items[0].strikes);
    _ = state.driveDispatcherLedger(&parent, &zero_cycle, &proto, regs.view(), true);
    try testing.expectEqual(@as(u8, 2), state.provenance_edges.items[0].strikes);
    _ = state.driveDispatcherLedger(&parent, &zero_cycle, &proto, regs.view(), true);
    try testing.expectEqual(@as(usize, 0), state.provenance_edges.items.len);
    try testing.expect(!state.hasArmedSiblingHandoff(&parent, 0, &child));
    try testing.expect(state.hasArmedSiblingHandoff(&child, 0, &parent));
}

test "B-2b local-positive provenance handoff replays child-only cursor and charges parent work" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.cache.clearRetainingCapacity();
    state.config.min_useful = 5;

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "provenance-local", .num_registers = 1 };
    var p_instrs = [_]IrInstr{ .{ .op = .guard_true, .aux = 1 }, .{ .op = .loop } };
    var c_instrs = [_]IrInstr{ .{ .op = .guard_false, .aux = 1 }, .{ .op = .loop } };
    const p_slots = try gpa.alloc(usize, p_instrs.len);
    defer gpa.free(p_slots);
    @memset(p_slots, 0);
    var parent: Trace = .{ .id = 111, .anchor = .{ .proto = &proto, .pc = 4 }, .instrs = &p_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .native = .{ .compiled = .{ .page = undefined, .slots = p_slots, .gpa = gpa, .ordinary_entry = 0xB111 } } };
    var child: Trace = .{ .id = 112, .anchor = parent.anchor, .instrs = &c_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xB112 } } };
    try state.cache.append(gpa, &parent);
    try state.cache.append(gpa, &child);
    try state.provenance_edges.append(gpa, .{ .parent_id = parent.id, .exit_instr = 0, .child_id = child.id });
    try testing.expect(state.publishSiblingArm(&parent, 0, &child));
    var regs_buf = [_]Value{Value.int(0)};
    var regs = TestRegs{ .regs = &regs_buf };

    const prologue = [_]irinterp.LedgerEntry{
        .{ .cum = 5, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 5, .id = child.id, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    const r1 = state.driveDispatcherLedger(&parent, &prologue, &proto, regs.view(), true);
    try testing.expectEqual(@as(usize, 0), r1.completed);
    try testing.expectEqual(@as(?u32, parent.anchor.pc), r1.resume_pc);
    try testing.expectEqual(@as(u64, 1), parent.hit_count); // parent's local=5 charged

    const child_deopt = [_]irinterp.LedgerEntry{
        .{ .cum = 5, .id = parent.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 5, .id = child.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    const r2 = state.driveDispatcherLedger(&parent, &child_deopt, &proto, regs.view(), true);
    try testing.expectEqual(@as(usize, 0), r2.completed);
    try testing.expectEqual(@as(?u32, parent.anchor.pc), r2.resume_pc);
    try testing.expectEqual(@as(u64, 2), parent.hit_count);
}

test "armNativeLink / resetLinksTouching: P-E registry directionality" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // No trampoline is built in this unit test, so the value a reset restores
    // (the "unarmed" slot) is `trampoline_exit orelse 0` == 0.
    const SHARED_EXIT: usize = 0;
    try testing.expectEqual(@as(?usize, null), state.mcode_arena.trampoline_exit);

    // Two compiled-trace stubs. Only `.slots` is touched by the registry, so the
    // `.page` may stay undefined and we never call `destroy` on these.
    const parent_slots = try gpa.alloc(usize, 3);
    defer gpa.free(parent_slots);
    @memset(parent_slots, SHARED_EXIT);
    const child_slots = try gpa.alloc(usize, 1);
    defer gpa.free(child_slots);
    @memset(child_slots, SHARED_EXIT);

    var parent: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = child_slots, .gpa = gpa, .linked_entry = 0xDEAD_BEEF } },
    };
    const CHILD_BODY: usize = 0xDEAD_BEEF;
    const CHILD_BODY2: usize = 0xF00D;
    var child2: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .linked_entry = CHILD_BODY2 } },
    };

    // Arm: slot 1 of parent points at the child body; exactly one record tracked.
    try testing.expect(try state.armNativeLink(&parent, 1, &child, .link_terminal));
    try testing.expectEqual(CHILD_BODY, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    // Re-arming the SAME slot supersedes the prior record IN PLACE (no duplicate,
    // no realloc — the record count stays 1 and the new target is written).
    try testing.expect(try state.armNativeLink(&parent, 1, &child2, .link_terminal));
    try testing.expectEqual(CHILD_BODY2, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    // Retiring the superseded child does not touch the re-armed slot.
    state.resetLinksTouching(&child);
    try testing.expectEqual(CHILD_BODY2, parent_slots[1]);
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);
    // Current child retires (target side): parent resets and the record is dropped.
    state.resetLinksTouching(&child2);
    try testing.expectEqual(SHARED_EXIT, parent_slots[1]);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Out-of-range slot index is a no-op → returns false, no OOB write, no record.
    try testing.expect(!try state.armNativeLink(&parent, 99, &child, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // A non-compiled parent is a no-op → returns false.
    var unsup: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .unsupported,
    };
    try testing.expect(!try state.armNativeLink(&unsup, 0, &child, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);

    // Parent-retire direction: re-arm, then reset touching the PARENT (source).
    // The record is dropped WITHOUT writing through the (about-to-be-freed) slot,
    // and a subsequent child-retire must find no record — no write, no crash.
    try testing.expect(try state.armNativeLink(&parent, 2, &child, .link_terminal));
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
    state.resetLinksTouching(&parent);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    // A parent-side reset leaves the slot value untouched (its array is freed anyway).
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
    // Later child-retire is a clean no-op now that the record is gone.
    state.resetLinksTouching(&child);
    try testing.expectEqual(CHILD_BODY, parent_slots[2]);
}

test "disarmAllLinks (2c-E / 2.3c-0e): resets EVERY armed slot on entering the observation blackout" {
    // The disarm-on-unsafe path (dispatcher calls `disarmAllLinks` when
    // `!safe_to_arm` — suspend / replay-line recording / exec-log active). Unlike
    // `resetLinksTouching` (one retiring trace), this resets the WHOLE registry so
    // no armed cycle widens the observation blackout. Arm a full C↔I cycle (two
    // links), then one `disarmAllLinks` must return BOTH slots to shared_exit and
    // empty the registry — and be idempotent (a second call is a no-op).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const SHARED_EXIT: usize = 0; // no trampoline in this unit test
    try testing.expectEqual(@as(?usize, null), state.mcode_arena.trampoline_exit);

    const inner_slots = try gpa.alloc(usize, 1);
    defer gpa.free(inner_slots);
    @memset(inner_slots, SHARED_EXIT);
    const cont_slots = try gpa.alloc(usize, 1);
    defer gpa.free(cont_slots);
    @memset(cont_slots, SHARED_EXIT);

    var inner: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = inner_slots, .gpa = gpa, .linked_entry = 0xBBBB } },
    };
    var cont: Trace = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = cont_slots, .gpa = gpa, .linked_entry = 0xAAAA } },
    };

    const I_TO_C: usize = 0xAAAA;
    const C_TO_I: usize = 0xBBBB;
    // Arm both edges of the cycle (kinds are `.link_terminal` here — the guard-shape
    // invariant is exercised elsewhere; these stubs have empty instrs so no slot is
    // a loop-done). inner.slot[0] → C, cont.slot[0] → I.
    try testing.expect(try state.armNativeLink(&inner, 0, &cont, .link_terminal));
    try testing.expect(try state.armNativeLink(&cont, 0, &inner, .link_terminal));
    try testing.expectEqual(I_TO_C, inner_slots[0]);
    try testing.expectEqual(C_TO_I, cont_slots[0]);
    try testing.expectEqual(@as(usize, 2), state.armed_links.items.len);

    // One disarm resets BOTH slots and empties the registry, and the tear-down
    // counter reflects exactly the two slots reset.
    state.disarmAllLinks();
    try testing.expectEqual(SHARED_EXIT, inner_slots[0]);
    try testing.expectEqual(SHARED_EXIT, cont_slots[0]);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(u64, 2), state.native_link_disarms);

    // Idempotent: a second call on the now-empty registry is a clean no-op — and
    // the counter does NOT advance (the early `len == 0` return fires first).
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(u64, 2), state.native_link_disarms);
}

test "A-viii (doc 17 §A8 step 8): one disarm tears down the whole OUTER cycle — all four production edge kinds" {
    // The teardown half of §A8 step 8's oracle, at the unit level: EVERY handoff
    // slot of the outer cycle returns to its default. The 2c-E test above covers
    // the inner `C↔I` pair as two `.link_terminal` stand-ins; this reproduces the
    // MEASURED production topology of the outer cycle instead (nsieve 9 under
    // `--jit-debug`, anchors inner=24 / cont=29 / skip=14):
    //
    //   inner --loop_done_linked--> cont      (slot is a real numeric-for loop-done guard)
    //   cont  --link_terminal-----> inner     (the C⇄I back edge)
    //   cont  --region_bridge-----> skip      (A-vii edge 4 — the outer closing edge)
    //   skip  --ordinary_guard----> inner     (the source-branch ramp back in)
    //
    // All four `ArmKind`s appear, including `.loop_done_linked`, whose slot is
    // subject to the P-C option-(b) invariant and is therefore the one an
    // index-shape bug is most likely to mis-handle. `.region_bridge` is the kind
    // that POSTDATES the disarm path: a kind-sensitive teardown — e.g. one that
    // skipped bridge links because they carry a `region_id`, the way the
    // deliberately-*selective* `disarmStaleRegionBridgeLinks` sweep does — would
    // strand a live native→native handoff after the dispatcher declared the
    // blackout. `disarmAllLinks` is the blackout hammer and must be exhaustive.
    // Each parent gets its OWN IR array whose armed slot carries the physical
    // shape that kind really has in production — a genuine numeric-for loop-done
    // guard for `inner`, a terminal `.link` op for the C⇄I back edge, a real
    // `isCompositeBridgeCandidate` guard for edge 4, and a plain non-composite
    // guard for the source-branch ramp. All four are armed through
    // `armNativeLink` itself, so every kind's validator (the P-C option-(b)
    // shape check, the `.ordinary_guard` composite-exclusion, the
    // `.region_bridge` entry requirement) runs for real; nothing is hand-poked
    // into `armed_links`.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const SHARED_EXIT: usize = 0;
    try testing.expectEqual(@as(?usize, null), state.mcode_arena.trampoline_exit);

    // pc 5 = `jmp_if_true` (the composite branch's source), pc 6 = `for_loop`
    // (the numeric-for whose loop-done guard the P-C invariant governs); the
    // continue edge lands at 6+1+2 = 9, where `skip` is anchored.
    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 10);
    code[6] = Instr.opAx(.for_loop, 0, 2);
    const proto = Proto{ .id = 88, .code = &code, .name = "aviii-outer", .num_registers = 8 };

    const branch_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = 88,
        .source_pc = 5,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    const loopdone_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = 88,
        .source_pc = 6,
        .role = .loop_done,
        .operand = .a,
        .polarity = .neutral,
    } };
    var prov = [_]ExitProvEntry{
        .{ .index = 4, .prov = loopdone_prov },
        .{ .index = 7, .prov = branch_prov },
    };

    // The `recForLoop` shape a composite bridge candidate must present: a
    // dominating loop-continue guard consuming the stepped index `R = %2`, and
    // slot-bound phis for both `for_loop`-written slots sharing `R`. %4 is the
    // loop-done guard, %7 the composite branch guard, %8 the `.link` terminal.
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0
        .{ .op = .konst, .aux = 0 }, // %1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = R
        .{ .op = .le, .a = 2, .b = 1 }, // %3 consumes R
        .{ .op = .guard_true, .a = 3, .aux = 7 }, // %4 loop-done (source pc 6)
        .{ .op = .phi, .b = 2, .aux = 0 }, // idx slot
        .{ .op = .phi, .b = 2, .aux = 3 }, // var slot, same R
        .{ .op = .guard_true, .a = 0, .aux = 6 }, // %7 composite (source pc 5)
        .{ .op = .link, .aux = 9 }, // %8 terminal
    };
    var inner_instrs = cont_instrs; // same shape, distinct storage
    var skip_instrs = [_]IrInstr{
        .{ .op = .guard_int, .a = 0 }, // %0 a plain guard: not loop-done, not composite
        .{ .op = .loop },
    };

    const skip_slots = try gpa.alloc(usize, skip_instrs.len);
    defer gpa.free(skip_slots);
    @memset(skip_slots, SHARED_EXIT);
    const inner_slots = try gpa.alloc(usize, inner_instrs.len);
    defer gpa.free(inner_slots);
    @memset(inner_slots, SHARED_EXIT);
    const cont_slots = try gpa.alloc(usize, cont_instrs.len);
    defer gpa.free(cont_slots);
    @memset(cont_slots, SHARED_EXIT);

    var skip: Trace = .{
        .id = 1,
        .anchor = .{ .proto = &proto, .pc = 9 },
        .instrs = &skip_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = skip_slots, .gpa = gpa, .linked_entry = 0x5111, .ordinary_entry = 0x6111 } },
    };
    var inner: Trace = .{
        .id = 2,
        .anchor = .{ .proto = &proto, .pc = 20 },
        .instrs = &inner_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_prov = &prov,
        .native = .{ .compiled = .{ .page = undefined, .slots = inner_slots, .gpa = gpa, .linked_entry = 0x5222, .ordinary_entry = 0x6222 } },
    };
    var cont: Trace = .{
        .id = 3,
        .anchor = .{ .proto = &proto, .pc = 20 },
        .instrs = &cont_instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .exit_prov = &prov,
        .native = .{ .compiled = .{ .page = undefined, .slots = cont_slots, .gpa = gpa, .linked_entry = 0x5333, .ordinary_entry = 0x6333 } },
    };
    // The three distinct shapes, as the arm path's validators will classify them.
    try testing.expect(isLoopDoneGuardIndex(&inner, 4)); // loop-done slot
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont, 7)); // bridge slot
    try testing.expect(!isLoopDoneGuardIndex(&skip, 0)); // plain ordinary slot
    try testing.expect(!nativegen.isCompositeBridgeCandidate(&skip, 0));

    // Arm the cycle. `armNativeLink` derives every target from `child` + `kind`,
    // never from the caller: a loop-done / ordinary / bridge handoff enters the
    // child's `ordinary_entry`, a `.link` terminal its `linked_entry`.
    try testing.expect(try state.armNativeLink(&inner, 4, &cont, .loop_done_linked));
    try testing.expect(try state.armNativeLink(&cont, 8, &inner, .link_terminal));
    try testing.expect(try state.armNativeLink(&cont, 7, &skip, .region_bridge));
    try testing.expect(try state.armNativeLink(&skip, 0, &inner, .ordinary_guard));
    // The A-vii arm site re-stamps the proven region onto the record right after
    // arming (`armNativeLink` deliberately clears it); mirror that here so the
    // teardown walks a record shaped exactly like the production one.
    for (state.armed_links.items) |*l| {
        if (l.kind == .region_bridge) l.region_id = @enumFromInt(4);
    }

    // The cycle stands closed: every slot points at its successor's entry.
    try testing.expectEqual(@as(usize, 0x6333), inner_slots[4]); // loop-done → cont.ordinary
    try testing.expectEqual(@as(usize, 0x5222), cont_slots[8]); // terminal  → inner.linked
    try testing.expectEqual(@as(usize, 0x6111), cont_slots[7]); // bridge    → skip.ordinary
    try testing.expectEqual(@as(usize, 0x6222), skip_slots[0]); // ordinary  → inner.ordinary
    try testing.expectEqual(@as(usize, 4), state.armed_links.items.len);

    // One blackout tears down the WHOLE cycle — every kind, every slot.
    state.disarmAllLinks();
    try testing.expectEqual(SHARED_EXIT, inner_slots[4]);
    try testing.expectEqual(SHARED_EXIT, cont_slots[8]);
    try testing.expectEqual(SHARED_EXIT, cont_slots[7]); // the A-vii edge, reset too
    try testing.expectEqual(SHARED_EXIT, skip_slots[0]);
    // Nothing else was touched: every non-armed slot is still at its default.
    for (skip_slots) |s| try testing.expectEqual(SHARED_EXIT, s);
    for (inner_slots) |s| try testing.expectEqual(SHARED_EXIT, s);
    for (cont_slots) |s| try testing.expectEqual(SHARED_EXIT, s);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(@as(u64, 4), state.native_link_disarms);
}
