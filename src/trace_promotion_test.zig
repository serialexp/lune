//! Tests for `trace.zig` — promotion.
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
const nativegen_testutil = @import("nativegen_testutil.zig");
const irinterp = @import("irinterp.zig");
const trace_exec = @import("trace_exec.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

const EntryGuard = trace.EntryGuard;
const ExitProvEntry = trace.ExitProvEntry;
const IrInstr = trace.IrInstr;
const ProgramPoint = trace.ProgramPoint;
const PromotedEdge = trace.PromotedEdge;
const RegionAccum = trace.RegionAccum;
const RegionBridgeDef = trace.RegionBridgeDef;
const RegionId = trace.RegionId;
const RegionKey = trace.RegionKey;
const StructuralEdgeId = trace.StructuralEdgeId;
const Trace = trace.Trace;
const TraceState = trace.TraceState;

fn makeB3LinkTrace(
    gpa: std.mem.Allocator,
    state: *TraceState,
    proto: *const Proto,
    id: u32,
    pc: u32,
    next_pc: u32,
) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.alloc(IrInstr, 1);
    errdefer gpa.free(instrs);
    instrs[0] = .{ .op = .link, .aux = @intCast(next_pc) };
    const consts = try gpa.alloc(Value, 0);
    errdefer gpa.free(consts);
    const entry_slots = try gpa.alloc(u16, 0);
    errdefer gpa.free(entry_slots);
    const entry_guards = try gpa.alloc(EntryGuard, 0);
    errdefer gpa.free(entry_guards);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
        },
        .id = id,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.registry.mcode_arena, &(t).code, (t).id, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.registry.cache.append(gpa, t);
    return t;
}

fn makeB3GuardTrace(
    gpa: std.mem.Allocator,
    state: *TraceState,
    proto: *const Proto,
    id: u32,
    pc: u32,
) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.alloc(IrInstr, 7);
    errdefer gpa.free(instrs);
    instrs[0] = .{ .op = .slot_load, .aux = 0 };
    instrs[1] = .{ .op = .slot_load, .aux = 1 };
    instrs[2] = .{ .op = .guard_int, .a = 0 };
    instrs[3] = .{ .op = .guard_int, .a = 1 };
    instrs[4] = .{ .op = .lt, .a = 0, .b = 1 };
    instrs[5] = .{ .op = .guard_true, .a = 4, .aux = 1 };
    instrs[6] = .{ .op = .loop };
    const consts = try gpa.alloc(Value, 0);
    errdefer gpa.free(consts);
    const entry_slots = try gpa.alloc(u16, 0);
    errdefer gpa.free(entry_slots);
    const entry_guards = try gpa.alloc(EntryGuard, 0);
    errdefer gpa.free(entry_guards);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
        },
        .id = id,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.registry.mcode_arena, &(t).code, (t).id, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.registry.cache.append(gpa, t);
    return t;
}

fn makeB3LoopDoneTrace(
    gpa: std.mem.Allocator,
    state: *TraceState,
    proto: *const Proto,
    id: u32,
    pc: u32,
) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.alloc(IrInstr, 7);
    errdefer gpa.free(instrs);
    instrs[0] = .{ .op = .slot_load, .aux = 0 };
    instrs[1] = .{ .op = .slot_load, .aux = 1 };
    instrs[2] = .{ .op = .guard_int, .a = 0 };
    instrs[3] = .{ .op = .guard_int, .a = 1 };
    instrs[4] = .{ .op = .lt, .a = 0, .b = 1 };
    instrs[5] = .{ .op = .guard_true, .a = 4, .aux = 2 };
    instrs[6] = .{ .op = .loop };
    const consts = try gpa.alloc(Value, 0);
    errdefer gpa.free(consts);
    const entry_slots = try gpa.alloc(u16, 0);
    errdefer gpa.free(entry_slots);
    const entry_guards = try gpa.alloc(EntryGuard, 0);
    errdefer gpa.free(entry_guards);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
        },
        .id = id,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.registry.mcode_arena, &(t).code, (t).id, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.registry.cache.append(gpa, t);
    return t;
}

fn makeB3BridgeTrace(
    gpa: std.mem.Allocator,
    state: *TraceState,
    proto: *const Proto,
    id: u32,
    pc: u32,
    succ_pc: u32,
) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.dupe(IrInstr, &.{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .add, .a = 0, .b = 2, .ty = .int },
        .{ .op = .le, .a = 5, .b = 2 },
        .{ .op = .guard_true, .a = 6, .aux = 7 },
        .{ .op = .phi, .b = 5, .aux = 0 },
        .{ .op = .phi, .b = 5, .aux = 3 },
        .{ .op = .lt, .a = 1, .b = 2 },
        .{ .op = .guard_true, .a = 10, .aux = 6 },
        .{ .op = .link, .aux = @intCast(succ_pc) },
    });
    errdefer gpa.free(instrs);
    const consts = try gpa.dupe(Value, &.{Value.int(1)});
    errdefer gpa.free(consts);
    const entry_slots = try gpa.alloc(u16, 0);
    errdefer gpa.free(entry_slots);
    const entry_guards = try gpa.alloc(EntryGuard, 0);
    errdefer gpa.free(entry_guards);
    const exit_prov = try gpa.dupe(ExitProvEntry, &.{
        .{ .index = 7, .prov = .{ .guard = .{ .source_proto_id = proto.id, .source_pc = 6, .role = .loop_done, .operand = .a, .polarity = .neutral } } },
        .{ .index = 11, .prov = .{ .guard = .{ .source_proto_id = proto.id, .source_pc = 5, .role = .branch_cond, .operand = .a, .polarity = .taken } } },
    });
    errdefer gpa.free(exit_prov);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
            .exit_prov = exit_prov,
        },
        .id = id,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.registry.mcode_arena, &(t).code, (t).id, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.registry.cache.append(gpa, t);
    return t;
}

fn makeB3BridgeSuccessorTrace(
    gpa: std.mem.Allocator,
    state: *TraceState,
    proto: *const Proto,
    id: u32,
    pc: u32,
    next_pc: u32,
) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.dupe(IrInstr, &.{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 2 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .lt, .a = 0, .b = 1 },
        .{ .op = .guard_true, .a = 4, .aux = @intCast(pc) },
        .{ .op = .le, .a = 0, .b = 1 },
        .{ .op = .guard_true, .a = 6, .aux = @intCast(next_pc) },
        .{ .op = .loop },
    });
    errdefer gpa.free(instrs);
    const consts = try gpa.alloc(Value, 0);
    errdefer gpa.free(consts);
    const entry_slots = try gpa.alloc(u16, 0);
    errdefer gpa.free(entry_slots);
    const entry_guards = try gpa.dupe(EntryGuard, &.{.{ .slot = 2, .ty = .int }});
    errdefer gpa.free(entry_guards);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
        },
        .id = id,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.registry.mcode_arena, &(t).code, (t).id, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.registry.cache.append(gpa, t);
    return t;
}

fn makeB3M1RampTrace(
    gpa: std.mem.Allocator,
    state: *TraceState,
    proto: *const Proto,
    id: u32,
    pc: u32,
) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.dupe(IrInstr, &.{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 2 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .lt, .a = 0, .b = 1 },
        .{ .op = .guard_true, .a = 4, .aux = 2 },
        .{ .op = .link, .aux = @intCast(pc) },
    });
    errdefer gpa.free(instrs);
    const consts = try gpa.alloc(Value, 0);
    errdefer gpa.free(consts);
    const entry_slots = try gpa.alloc(u16, 0);
    errdefer gpa.free(entry_slots);
    const entry_guards = try gpa.dupe(EntryGuard, &.{.{ .slot = 2, .ty = .int }});
    errdefer gpa.free(entry_guards);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
        },
        .id = id,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.registry.mcode_arena, &(t).code, (t).id, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.registry.cache.append(gpa, t);
    return t;
}

/// Doc 55 §2d: an edge is promoted iff its exit's data cell is published. The
/// compiled silent check is identical in both states (code is never rewritten).
fn expectB3Patched(edge: PromotedEdge, promoted: bool) !void {
    const compiled = &edge.parent.native.compiled;
    const patch = TraceState.exitPatchFor(compiled, edge.exit).?;
    try nativegen_testutil.expectSilentCheck(compiled, patch.*);
    const cell = compiled.metadata_cells[edge.exit];
    if (!promoted) {
        try testing.expectEqual(@as(usize, 0), cell);
        return;
    }
    try testing.expect(cell != 0);
    const metadata: *nativegen.SilentExitMetadata = @ptrFromInt(cell);
    try testing.expectEqual(&compiled.slots[edge.exit], metadata.slot);
    try testing.expectEqual(@intFromPtr(compiled.page.code.ptr) + patch.resume_off, metadata.reporting_target);
}

fn b3ObservedRow(t: *Trace, exit: u32, kind: trace_exec.LedgerKind) trace_exec.LedgerEntry {
    return .{ .cum = 0, .id = t.id, .exit = exit, .reason = .normal, .kind = kind, .outcome = .normal };
}

/// B-3d: set candidacy reads the region BEFORE any detection can run (the
/// candidate IS the region's armed-edge population), so tests install the
/// region from the participating traces' anchors rather than from a
/// previously-detected edge list.
fn installB3PromotionRegion(state: *TraceState, key: RegionKey, traces: []const *Trace) !void {
    const gpa = state.gpa;
    var scratch: [TraceState.PROMOTED_SET_CAP * 2]ProgramPoint = undefined;
    var n: usize = 0;
    for (traces) |t| {
        const point = ProgramPoint{ .proto_id = t.code.anchor.proto.id, .source_pc = t.code.anchor.pc };
        var exists = false;
        for (scratch[0..n]) |prior| {
            if (prior.proto_id == point.proto_id and prior.source_pc == point.source_pc) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            scratch[n] = point;
            n += 1;
        }
    }
    try state.region_policy.region_defs.put(gpa, key.region_id, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.dupe(ProgramPoint, scratch[0..n]),
        .owner = traces[0].code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = @intCast(traces.len) },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    try state.region_policy.region_profit.put(gpa, key, .{
        .root_frame_depth = 1,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
        .useful_streak = state.config.freeze_windows,
        .frozen = true,
    });
}

fn expectRegionAccumEqual(expected: RegionAccum, actual: RegionAccum) !void {
    try testing.expectEqual(expected.outer_traversals, actual.outer_traversals);
    try testing.expectEqual(expected.window_base, actual.window_base);
    try testing.expectEqual(expected.root_frame_depth, actual.root_frame_depth);
    try testing.expectEqual(expected.root_call_seq, actual.root_call_seq);
    try testing.expectEqual(expected.useful_window_seen, actual.useful_window_seen);
    try testing.expectEqual(expected.barren_run, actual.barren_run);
    try testing.expectEqual(expected.useful_streak, actual.useful_streak);
    try testing.expectEqual(expected.frozen, actual.frozen);
}

test "B-3d.2 set candidacy accepts 2/3-edge automata in canonical order from any observation rotation" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [8]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1701, .code = &code, .name = "b3-detector", .num_registers = 2 };

    const a = try makeB3LinkTrace(gpa, &state, &proto, 30, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 10, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const two_key: RegionKey = .{ .region_id = @enumFromInt(1700), .activation = 32 };
    try installB3PromotionRegion(&state, two_key, &.{ a, b });
    const observed_a = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const observed_b = [_]trace_exec.LedgerEntry{
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
    };
    // The candidate is the region-total armed-edge set, so BOTH observation
    // rotations resolve to the same canonical (parent id, exit) list — there
    // is no entry phase to canonicalize away.
    const from_a = state.detectPromotableSet(&observed_a, two_key).?;
    defer gpa.free(from_a);
    const from_b = state.detectPromotableSet(&observed_b, two_key).?;
    defer gpa.free(from_b);
    try testing.expectEqual(@as(usize, 2), from_a.len);
    try testing.expectEqual(@as(u32, 10), from_a[0].parent.id);
    for (from_a, from_b) |ea, eb| {
        try testing.expectEqual(ea.parent, eb.parent);
        try testing.expectEqual(ea.exit, eb.exit);
    }

    state.disarmAllLinks();
    const c = try makeB3LinkTrace(gpa, &state, &proto, 20, 3, 1);
    a.code.instrs[0].aux = 2;
    b.code.instrs[0].aux = 3;
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, c, .link_terminal));
    try testing.expect(try state.armNativeLink(c, 0, a, .link_terminal));
    const region_key: RegionKey = .{ .region_id = @enumFromInt(1701), .activation = 33 };
    try installB3PromotionRegion(&state, region_key, &.{ a, b, c });
    const observed_three_a = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const observed_three_c = [_]trace_exec.LedgerEntry{
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(c, 0, .link_terminal),
    };
    const three_a = state.detectPromotableSet(&observed_three_a, region_key).?;
    defer gpa.free(three_a);
    const three_c = state.detectPromotableSet(&observed_three_c, region_key).?;
    defer gpa.free(three_c);
    try testing.expectEqual(@as(usize, 3), three_a.len);
    try testing.expectEqual(@as(u32, 10), three_a[0].parent.id);
    for (three_a, three_c) |ea, ec| try testing.expectEqual(ea.parent, ec.parent);

    // A second armed outgoing exit that is NOT patch-pointed (out-of-range
    // slot on a one-instruction link trace) is excluded from the candidate —
    // the set grammar admits only edges `promotedEdgeFromLink` validates.
    try state.registry.native_physical.armed_links.append(gpa, .{
        .parent = a,
        .slot_index = 1,
        .child = c,
        .kind = .ordinary_guard,
    });
    const multi_armed = state.detectPromotableSet(&observed_three_a, region_key).?;
    try testing.expectEqual(@as(usize, 3), multi_armed.len);
    gpa.free(multi_armed);
    _ = state.registry.native_physical.armed_links.pop();

    // Promotion belongs to one exact live frozen region. Shrinking the
    // region's footprint excludes a member edge from the candidate, so its
    // observed rows no longer match (open_chain); a missing/foreign region is
    // its own reject; an unfrozen accumulator still refuses publication.
    const def = state.region_policy.region_defs.getPtr(region_key.region_id).?;
    const complete_points = def.member_points;
    def.member_points = complete_points[0 .. complete_points.len - 1];
    try testing.expect(state.detectPromotableSet(&observed_three_a, region_key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.open_chain);
    def.member_points = complete_points;
    try testing.expect(state.detectPromotableSet(
        &observed_three_a,
        .{ .region_id = @enumFromInt(4242), .activation = 33 },
    ) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.region_mismatch);
    state.region_policy.region_profit.getPtr(region_key).?.frozen = false;
    try testing.expectError(error.InvalidPromotionRegion, state.promoteSet(three_a, region_key));
    state.region_policy.region_profit.getPtr(region_key).?.frozen = true;
}

test "B-3d.2 set candidacy rejects non-member rows, kind mismatch, adjacent-pair break, over-cap; one set per region enforced" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1702, .code = &code, .name = "b3-reject", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 9 };
    try installB3PromotionRegion(&state, key, &.{ a, b });

    // The set grammar has no repetition requirement: a forward-only ledger
    // whose every adjacent pair follows an armed edge is valid evidence.
    const forward = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
    };
    const forward_edges = state.detectPromotableSet(&forward, key).?;
    try testing.expectEqual(@as(usize, 2), forward_edges.len);
    gpa.free(forward_edges);

    const closed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    // An invalidated bridge kind fails `promotedEdgeFromLink`, dropping the
    // edge from the candidate — its observed rows no longer match any member.
    state.registry.native_physical.armed_links.items[0].kind = .region_bridge;
    try testing.expect(state.detectPromotableSet(&closed, key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.open_chain);
    state.registry.native_physical.armed_links.items[0].kind = .link_terminal;
    // Same exclusion when the parent has no patch table.
    const saved_patches = a.native.compiled.exit_patches;
    a.native.compiled.exit_patches = &.{};
    try testing.expect(state.detectPromotableSet(&closed, key) == null);
    try testing.expectEqual(@as(u64, 2), state.silent_rejects.open_chain);
    a.native.compiled.exit_patches = saved_patches;
    // A row whose observed patch kind disagrees with the armed edge's kind.
    const kind_mismatch = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .deopt),
        b3ObservedRow(b, 0, .link_terminal),
    };
    try testing.expect(state.detectPromotableSet(&kind_mismatch, key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.no_patch_point);
    // Per-adjacent-pair child-match: row i's armed child must own row i+1.
    const pair_break = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
    };
    try testing.expect(state.detectPromotableSet(&pair_break, key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.child_mismatch);

    // One set per region is ENFORCED (§B3.17 R1): a second promotion attempt
    // against an owning region is refused, and owned edges are excluded from
    // candidacy so their rows cannot re-qualify.
    const edges = state.detectPromotableSet(&closed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    try testing.expectError(error.PromotionRegionOwned, state.promoteSet(edges, key));
    try testing.expect(state.detectPromotableSet(&closed, key) == null); // owned → excluded
    try testing.expectEqual(@as(u64, 3), state.silent_rejects.open_chain);
    state.demoteAllSets();
    state.disarmAllLinks();

    // Candidate over the cap: 17 armed member edges in one region.
    var long: [TraceState.PROMOTED_SET_CAP + 1]*Trace = undefined;
    for (&long, 0..) |*slot, i| slot.* = try makeB3LinkTrace(
        gpa,
        &state,
        &proto,
        @intCast(100 + i),
        @intCast(10 + i),
        @intCast(10 + ((i + 1) % long.len)),
    );
    for (long, 0..) |parent, i| try testing.expect(try state.armNativeLink(
        parent,
        0,
        long[(i + 1) % long.len],
        .link_terminal,
    ));
    const key_cap: RegionKey = .{ .region_id = @enumFromInt(2), .activation = 10 };
    try installB3PromotionRegion(&state, key_cap, &long);
    const one_row = [_]trace_exec.LedgerEntry{b3ObservedRow(long[0], 0, .link_terminal)};
    try testing.expect(state.detectPromotableSet(&one_row, key_cap) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.cap);
    try testing.expectEqual(@as(u64, 0), state.silent_rejects.bridge_member);
    try testing.expectEqual(@as(u64, 0), state.silent_rejects.region_mismatch);
}

test "B-3b.2 promotion publishes mixed deopt/link/loop-done cells; demotion zeroes them (code never rewritten)" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    code[1] = Instr.op0(.for_loop);
    const proto = Proto{ .id = 1703, .code = &code, .name = "b3-patch", .num_registers = 2 };
    const guard = try makeB3GuardTrace(gpa, &state, &proto, 2, 0);
    const done = try makeB3LoopDoneTrace(gpa, &state, &proto, 3, 1);
    const link = try makeB3LinkTrace(gpa, &state, &proto, 1, 2, 0);
    try testing.expect(try state.armNativeLink(guard, 5, done, .ordinary_guard));
    try testing.expect(try state.armNativeLink(done, 5, link, .loop_done_linked));
    try testing.expect(try state.armNativeLink(link, 0, guard, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(guard, 5, .deopt),
        b3ObservedRow(done, 5, .loop_done_linked),
        b3ObservedRow(link, 0, .link_terminal),
        b3ObservedRow(guard, 5, .deopt),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(2), .activation = 11 };
    try installB3PromotionRegion(&state, key, &.{ guard, done, link });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    // Doc 55 §2d: a set naming one exit twice is refused before anything is
    // published (it would double-publish the cell and double-insert the owner).
    const dup = [_]PromotedEdge{ edges[0], edges[0] };
    try testing.expectError(error.InvalidPromotionSet, state.registry.native_physical.promoteSet(&dup, key, state.config.min_useful));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, false);
    try state.promoteSet(edges, key);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, true);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.silent_promotions);
    state.demoteAllSets();
    for (edges) |edge| try expectB3Patched(edge, false);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.silent_demotions);
}

test "B-3b.4 region bridge promotes with frozen structural resume and rebuild demotes" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [32]Instr = @splat(Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 10);
    code[6] = Instr.opAx(.for_loop, 0, 2);
    const proto = Proto{ .id = 1714, .code = &code, .name = "b3-bridge", .num_registers = 4 };
    const bridge = try makeB3BridgeTrace(gpa, &state, &proto, 41, 20, 9);
    const succ = try makeB3LinkTrace(gpa, &state, &proto, 42, 9, 20);
    try testing.expect(nativegen.isCompositeBridgeCandidate(&bridge.code, 11));
    const patch = TraceState.exitPatchFor(&bridge.native.compiled, 11).?;
    try testing.expectEqual(nativegen.ExitPatchKind.region_bridge, patch.kind);
    try nativegen_testutil.expectSilentCheck(&bridge.native.compiled, patch.*);

    const rid: RegionId = @enumFromInt(1714);
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = bridge.code.anchor.pc,
            .exit = bridge.code.exit_prov[1].prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = succ.code.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = proto.id, .source_pc = bridge.code.anchor.pc },
            .{ .proto_id = proto.id, .source_pc = succ.code.anchor.pc },
        }),
        .owner = bridge.code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    try testing.expect(try state.armNativeLink(bridge, 11, succ, .region_bridge));
    try testing.expect(try state.armNativeLink(succ, 0, bridge, .link_terminal));
    for (state.registry.native_physical.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = rid;
        link.armed_gen = state.region_policy.region_defs_gen;
    };
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(bridge, 11, .region_bridge),
        b3ObservedRow(succ, 0, .link_terminal),
        b3ObservedRow(bridge, 11, .region_bridge),
    };
    const edges = state.detectPromotableSet(&observed, .{ .region_id = rid, .activation = 99 }).?;
    defer gpa.free(edges);
    var bridge_edge: ?PromotedEdge = null;
    for (edges) |edge| {
        if (edge.arm_kind == .region_bridge) bridge_edge = edge;
    }
    try testing.expectEqual(succ.code.anchor.pc, bridge_edge.?.resume_pc);
    const key: RegionKey = .{ .region_id = rid, .activation = 99 };
    state.config.min_useful = 3;
    state.config.max_barren_run = 64;
    const initial = RegionAccum{
        .root_frame_depth = 1,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
        .useful_streak = state.config.freeze_windows,
        .frozen = true,
    };
    try state.region_policy.region_profit.put(gpa, key, initial);
    for (state.registry.native_physical.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = @enumFromInt(9999);
    };
    try testing.expect(!state.promotionBelongsToRegion(edges, key));
    for (state.registry.native_physical.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = rid;
    };
    try state.promoteSet(edges, key);
    try expectB3Patched(bridge_edge.?, true);

    // Reporting-mode oracle for one bridge firing followed by the structural
    // link back into the ring.
    state.region_policy.setContext(1, key.activation);
    const reporting = [_]trace_exec.LedgerEntry{
        .{ .cum = 3, .id = bridge.id, .exit = 11, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
        .{ .cum = 3, .id = succ.id, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
    };
    var reporting_completed: usize = 0;
    var reporting_resume: u32 = bridge.code.anchor.pc;
    var reporting_hops: usize = 0;
    _ = state.replayLedger(&reporting, bridge, succ.code.anchor.pc, &proto, &reporting_completed, &reporting_resume, &reporting_hops, 8, .continuation_call, true, null);
    const oracle_accum = state.region_policy.region_profit.get(key).?;
    const oracle_bridge_hits = bridge.hit_count;
    const oracle_bridge_fused = state.native_region_bridge_fused;
    const oracle_link_exits = state.native_link_exits;

    state.region_policy.region_profit.getPtr(key).?.* = initial;
    bridge.hit_count = 0;
    state.native_region_bridge_fused = 0;
    state.native_link_exits = 0;
    const set = &state.registry.native_physical.promoted_sets.items[0];
    var bridge_phase: usize = 0;
    for (set.edges, 0..) |edge, phase| {
        if (edge.arm_kind == .region_bridge) bridge_phase = phase;
    }
    var link_phase: usize = 0;
    for (set.edges, 0..) |edge, phase| {
        if (edge.arm_kind == .link_terminal) link_phase = phase;
    }
    // The native image the epilogues would have written: the bridge fired first
    // (ordinal 1, local 3), then the structural link back into the ring (ordinal
    // 2, no work). Both `firings` are explicit — the drain no longer infers them.
    set.summary[bridge_phase] = .{
        .region_work = 0,
        .selection_work = 3,
        .qualifying_rows = 1,
        .productive_firings = 1,
        .last_local = 3,
        .last_productive_ordinal = 1,
        .firings = 1,
        .last_ordinal = 1,
    };
    set.summary[link_phase] = .{
        .region_work = 0,
        .selection_work = 0,
        .qualifying_rows = 0,
        .productive_firings = 0,
        .last_local = 0,
        .last_productive_ordinal = 0,
        .firings = 1,
        .last_ordinal = 2,
    };
    var silent_completed: usize = 0;
    var silent_resume: u32 = 0;
    var silent_hops: usize = 0;
    _ = state.driveSilentBurst(.{
        .completed = 3,
        .exit_instr = 0,
        .silent_active = 1,
        .silent_transitions = 2,
        .silent_budget = 2,
        .barren_budget = 64,
        .silent_cell = @intFromPtr(&set.metadata[bridge_phase]),
        .cur_zero_run = oracle_accum.barren_run,
        .silent_cum = 3,
        .silent_last_cell = @intFromPtr(&set.metadata[link_phase]),
    }, &proto, &silent_completed, &silent_resume, &silent_hops, 8, .continuation_call, true, null);
    const silent_accum = state.region_policy.region_profit.get(key).?;
    try testing.expectEqual(oracle_bridge_hits, bridge.hit_count);
    try testing.expectEqual(oracle_bridge_fused, state.native_region_bridge_fused);
    try testing.expectEqual(oracle_link_exits, state.native_link_exits);
    try testing.expectEqual(oracle_accum.barren_run, silent_accum.barren_run);
    try testing.expectEqual(oracle_accum.outer_traversals, silent_accum.outer_traversals);

    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try expectB3Patched(bridge_edge.?, false);
}

test "B-3b suffix preserves bridge materialization for child deopt and prologue fail" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.min_useful = 3;
    state.config.max_barren_run = 64;

    var code: [32]Instr = @splat(Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 10);
    code[6] = Instr.opAx(.for_loop, 0, 2);
    const proto = Proto{ .id = 1715, .code = &code, .name = "b3-bridge-suffix", .num_registers = 4 };
    const bridge = try makeB3BridgeTrace(gpa, &state, &proto, 51, 20, 9);
    const child = try makeB3BridgeSuccessorTrace(gpa, &state, &proto, 52, 9, 20);

    const rid: RegionId = @enumFromInt(1715);
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = bridge.code.anchor.pc,
            .exit = bridge.code.exit_prov[1].prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = child.code.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = proto.id, .source_pc = bridge.code.anchor.pc },
            .{ .proto_id = proto.id, .source_pc = child.code.anchor.pc },
        }),
        .owner = bridge.code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    try testing.expect(try state.armNativeLink(bridge, 11, child, .region_bridge));
    try testing.expect(try state.armNativeLink(child, 7, bridge, .ordinary_guard));
    for (state.registry.native_physical.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = rid;
        link.armed_gen = state.region_policy.region_defs_gen;
    };

    const key: RegionKey = .{ .region_id = rid, .activation = 101 };
    const initial = RegionAccum{
        .root_frame_depth = 1,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
        .useful_streak = state.config.freeze_windows,
        .frozen = true,
    };
    try state.region_policy.region_profit.put(gpa, key, initial);
    state.region_policy.setContext(1, key.activation);
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(bridge, 11, .region_bridge),
        b3ObservedRow(child, 7, .deopt),
        b3ObservedRow(bridge, 11, .region_bridge),
    };
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);

    var tags = [_]u8{
        @intFromEnum(value.Tag.int),
        @intFromEnum(value.Tag.int),
        @intFromEnum(value.Tag.int),
        @intFromEnum(value.Tag.int),
    };
    var payloads = [_]u64{
        @bitCast(@as(i64, 0)),
        @bitCast(@as(i64, 2)),
        @bitCast(@as(i64, 0)),
        @bitCast(@as(i64, 0)),
    };
    const regs = RegWindow.of(&tags, &payloads);

    state.prepareNativeEntry();
    const deopt = bridge.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(u64, 1), deopt.silent_active);
    try testing.expectEqual(@as(u64, 1), deopt.silent_transitions);
    try testing.expectEqual(@as(usize, 1), deopt.ledger_len);
    try testing.expectEqual(child.id, state.ledger_scratch[0].id);
    try testing.expectEqual(trace_exec.LedgerKind.deopt, state.ledger_scratch[0].kind);
    try testing.expectEqual(@as(u32, 5), state.ledger_scratch[0].exit);
    var completed: usize = 0;
    var resume_pc_value: u32 = 0;
    var hops: usize = 0;
    const deopt_dir = state.drainSilentResult(deopt, .continuation_call, &proto, &completed, &resume_pc_value, &hops, 8, true, null) orelse
        return error.TestUnexpectedResult;
    const deopt_result = switch (deopt_dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(child.code.anchor.pc, deopt_result.resume_pc);
    try testing.expectEqual(child.code.anchor.pc, resume_pc_value);
    try testing.expectEqual(@as(u32, 2), state.region_policy.region_profit.get(key).?.barren_run);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(child.code.anchor));

    state.region_policy.region_profit.getPtr(key).?.* = initial;
    payloads = .{
        @bitCast(@as(i64, 0)),
        @bitCast(@as(i64, 2)),
        @bitCast(@as(f64, 0.5)),
        @bitCast(@as(i64, 0)),
    };
    tags[2] = @intFromEnum(value.Tag.float);
    state.prepareNativeEntry();
    const prologue = bridge.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(u64, 1), prologue.silent_active);
    try testing.expectEqual(@as(u64, 1), prologue.silent_transitions);
    try testing.expectEqual(@as(usize, 1), prologue.ledger_len);
    try testing.expectEqual(child.id, state.ledger_scratch[0].id);
    try testing.expectEqual(trace_exec.LedgerKind.prologue_fail, state.ledger_scratch[0].kind);
    completed = 0;
    resume_pc_value = 0;
    hops = 0;
    const prologue_dir = state.drainSilentResult(prologue, .continuation_call, &proto, &completed, &resume_pc_value, &hops, 8, true, null) orelse
        return error.TestUnexpectedResult;
    const prologue_result = switch (prologue_dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(child.code.anchor.pc, prologue_result.resume_pc);
    try testing.expectEqual(child.code.anchor.pc, resume_pc_value);
    try testing.expectEqual(@as(u32, 1), state.region_policy.region_profit.get(key).?.barren_run);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(child.code.anchor));
    try testing.expectEqual(@as(u32, 1), child.consec_refusals);
    try testing.expectEqual(@as(u64, 2), state.silent_suffix_drains);
}

test "B-3b silent ordinary guard preserves M1 ramp deopt and prologue contracts" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.max_barren_run = 64;

    var code: [16]Instr = @splat(Instr.op0(.halt));
    code[0] = Instr.opAx(.jmp_if_true, 0, 2);
    const proto = Proto{ .id = 1716, .code = &code, .name = "b3-m1-suffix", .num_registers = 3 };
    const source = try makeB3GuardTrace(gpa, &state, &proto, 61, 10);
    const ramp = try makeB3M1RampTrace(gpa, &state, &proto, 62, 10);
    try testing.expect(try state.armNativeLink(source, 5, ramp, .ordinary_guard));
    try testing.expect(try state.armNativeLink(ramp, 6, source, .link_terminal));

    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(source, 5, .deopt),
        b3ObservedRow(ramp, 6, .link_terminal),
        b3ObservedRow(source, 5, .deopt),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(1716), .activation = 102 };
    try installB3PromotionRegion(&state, key, &.{ source, ramp });
    const physical = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(physical);
    state.region_policy.setContext(1, key.activation);
    const initial_accum = state.region_policy.region_profit.get(key).?;

    var tags = [_]u8{
        @intFromEnum(value.Tag.int),
        @intFromEnum(value.Tag.int),
        @intFromEnum(value.Tag.int),
    };
    var payloads = [_]u64{
        @bitCast(@as(i64, 2)),
        @bitCast(@as(i64, 1)),
        @bitCast(@as(i64, 1)),
    };
    const regs = RegWindow.of(&tags, &payloads);

    // Promotion-disabled oracle: reporting source row followed by ramp deopt.
    const ordinary_deopt = source.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(usize, 2), ordinary_deopt.ledger_len);
    var oracle_completed: usize = 0;
    var oracle_resume: u32 = 0;
    var oracle_hops: usize = 0;
    const oracle_deopt = state.replayLedger(
        state.ledger_scratch[0..ordinary_deopt.ledger_len],
        source,
        source.code.anchor.pc,
        &proto,
        &oracle_completed,
        &oracle_resume,
        &oracle_hops,
        8,
        .dispatcher_root,
        true,
        null,
    );
    const oracle_deopt_result = switch (oracle_deopt) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    const oracle_deopt_penalty = state.penalty.get(ramp.code.anchor);
    const oracle_source_hits = source.hit_count;
    const oracle_deopt_accum = state.region_policy.region_profit.get(key).?;

    state.penalty.clearRetainingCapacity();
    source.hit_count = 0;
    ramp.hit_count = 0;
    state.region_policy.region_profit.getPtr(key).?.* = initial_accum;
    try state.promoteSet(physical, key);
    state.prepareNativeEntry();
    const silent_deopt = source.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(u64, 1), silent_deopt.silent_transitions);
    try testing.expectEqual(@as(usize, 1), silent_deopt.ledger_len);
    var completed: usize = 0;
    var resume_pc_value: u32 = 0;
    var hops: usize = 0;
    const silent_deopt_dir = state.drainSilentResult(
        silent_deopt,
        .dispatcher_root,
        &proto,
        &completed,
        &resume_pc_value,
        &hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    const silent_deopt_result = switch (silent_deopt_dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(oracle_deopt_result.resume_pc, silent_deopt_result.resume_pc);
    try testing.expectEqual(source.code.anchor.pc, silent_deopt_result.resume_pc);
    try testing.expectEqual(oracle_deopt_penalty, state.penalty.get(ramp.code.anchor));
    try testing.expectEqual(oracle_source_hits, source.hit_count);
    try expectRegionAccumEqual(oracle_deopt_accum, state.region_policy.region_profit.get(key).?);

    // Repeat with a hoisted ramp entry failure. The source's silent M1 state
    // must still drive the zero-progress charge and source-anchor resume.
    state.penalty.clearRetainingCapacity();
    source.hit_count = 0;
    ramp.hit_count = 0;
    state.region_policy.region_profit.getPtr(key).?.* = initial_accum;
    tags[2] = @intFromEnum(value.Tag.float);
    payloads[2] = @bitCast(@as(f64, 0.5));
    state.demoteAllSets();
    const ordinary_prologue = source.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(usize, 2), ordinary_prologue.ledger_len);
    oracle_completed = 0;
    oracle_resume = 0;
    oracle_hops = 0;
    const oracle_prologue = state.replayLedger(
        state.ledger_scratch[0..ordinary_prologue.ledger_len],
        source,
        source.code.anchor.pc,
        &proto,
        &oracle_completed,
        &oracle_resume,
        &oracle_hops,
        8,
        .dispatcher_root,
        true,
        null,
    );
    const oracle_prologue_result = switch (oracle_prologue) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    const oracle_prologue_penalty = state.penalty.get(ramp.code.anchor);
    const oracle_prologue_hits = source.hit_count;
    const oracle_prologue_accum = state.region_policy.region_profit.get(key).?;

    state.penalty.clearRetainingCapacity();
    source.hit_count = 0;
    ramp.hit_count = 0;
    state.region_policy.region_profit.getPtr(key).?.* = initial_accum;
    try state.promoteSet(physical, key);
    state.prepareNativeEntry();
    const silent_prologue = source.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(u64, 1), silent_prologue.silent_transitions);
    try testing.expectEqual(@as(usize, 1), silent_prologue.ledger_len);
    completed = 0;
    resume_pc_value = 0;
    hops = 0;
    const silent_prologue_dir = state.drainSilentResult(
        silent_prologue,
        .dispatcher_root,
        &proto,
        &completed,
        &resume_pc_value,
        &hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    const silent_prologue_result = switch (silent_prologue_dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(oracle_prologue_result.resume_pc, silent_prologue_result.resume_pc);
    try testing.expectEqual(source.code.anchor.pc, silent_prologue_result.resume_pc);
    try testing.expectEqual(oracle_prologue_penalty, state.penalty.get(ramp.code.anchor));
    try testing.expectEqual(oracle_prologue_hits, source.hit_count);
    try expectRegionAccumEqual(oracle_prologue_accum, state.region_policy.region_profit.get(key).?);

    // Row-0 ramp deopt may itself be an armed Part-S handoff source. Rebuild
    // the suppressed source row with local=9: the ramp sibling production must
    // inherit that delta, continue normally, and never take the terminal-M1 arm.
    tags[2] = @intFromEnum(value.Tag.int);
    payloads[2] = @bitCast(@as(i64, 1));
    const sibling = try makeB3LinkTrace(gpa, &state, &proto, 63, 10, 10);
    try testing.expect(state.publishSiblingArm(ramp, 5, sibling));
    // B-3d membership growth (§B3.17 R1): publishing the sibling arm created a
    // NEW armable member edge of the owning region, so the live set demoted at
    // the `armNativeLink` funnel — its coverage of the region's armed-edge
    // population is stale. Production candidacy would regrow the region-total
    // set; this leg instead re-promotes the original pair directly so the
    // sibling edge stays UN-owned and its suffix row still exercises the
    // Part-S handoff production below.
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.silent_demotion_reasons.membership_growth);
    try state.promoteSet(physical, key);
    const set = &state.registry.native_physical.promoted_sets.items[0];
    var source_phase: usize = 0;
    for (set.edges, 0..) |edge, phase| if (edge.parent == source) {
        source_phase = phase;
        break;
    };
    set.summary[source_phase] = .{
        .region_work = 9,
        .selection_work = 9,
        .qualifying_rows = 1,
        .productive_firings = 1,
        .last_local = 9,
        .last_productive_ordinal = 1,
        .firings = 1,
        .last_ordinal = 1,
    };
    state.ledger_scratch[0] = .{
        .cum = 9,
        .id = ramp.id,
        .exit = 5,
        .reason = .normal,
        .kind = .deopt,
        .outcome = .normal,
    };
    state.ledger_scratch[1] = .{
        .cum = 9,
        .id = sibling.id,
        .exit = 0,
        .reason = .normal,
        .kind = .link_terminal,
        .outcome = .normal,
    };
    const ramp_handoff_suffix = trace_exec.ExecResult{
        .completed = 9,
        .exit_instr = 0,
        .ledger_len = 2,
        .silent_active = 1,
        .silent_transitions = 1,
        .silent_budget = state.config.silent_budget,
        .barren_budget = state.config.max_barren_run,
        .silent_cell = @intFromPtr(&set.metadata[source_phase]),
        .silent_cum = 9,
        .silent_last_cell = @intFromPtr(&set.metadata[source_phase]),
    };
    const ramp_hits_before = ramp.hit_count;
    completed = 0;
    resume_pc_value = 0;
    hops = 0;
    const handoff_dir = state.drainSilentResult(
        ramp_handoff_suffix,
        .dispatcher_root,
        &proto,
        &completed,
        &resume_pc_value,
        &hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    const handoff_driver = switch (handoff_dir) {
        .run_inner_from => |t| t,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(sibling, handoff_driver);
    try testing.expectEqual(ramp_hits_before + 1, ramp.hit_count);

    // A ramp `.link_terminal` is the other non-terminal M1 successor shape.
    // It keeps its ordinary row receipt and link/follow steering while consuming
    // the carried materialization without inventing ramp-local progress.
    set.summary[source_phase] = .{
        .region_work = 9,
        .selection_work = 9,
        .qualifying_rows = 1,
        .productive_firings = 1,
        .last_local = 9,
        .last_productive_ordinal = 1,
        .firings = 1,
        .last_ordinal = 1,
    };
    state.ledger_scratch[0] = .{
        .cum = 9,
        .id = ramp.id,
        .exit = 6,
        .reason = .normal,
        .kind = .link_terminal,
        .outcome = .normal,
    };
    const ramp_link_suffix = trace_exec.ExecResult{
        .completed = 9,
        .exit_instr = 6,
        .ledger_len = 1,
        .silent_active = 1,
        .silent_transitions = 1,
        .silent_budget = state.config.silent_budget,
        .barren_budget = state.config.max_barren_run,
        .silent_cell = @intFromPtr(&set.metadata[source_phase]),
        .silent_cum = 9,
        .silent_last_cell = @intFromPtr(&set.metadata[source_phase]),
    };
    const prime_follows_before = state.prime_side_chain_follows;
    completed = 0;
    resume_pc_value = 0;
    hops = 0;
    const link_dir = state.drainSilentResult(
        ramp_link_suffix,
        .dispatcher_root,
        &proto,
        &completed,
        &resume_pc_value,
        &hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    const link_driver = switch (link_dir) {
        .run_inner_from => |t| t,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(ramp, link_driver);
    try testing.expectEqual(prime_follows_before + 1, state.prime_side_chain_follows);
    state.applyPendingDisarms();
}

test "B-3b.2 slot mutation and closeRegion demote before invalidation" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1704, .code = &code, .name = "b3-lifetime", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(3), .activation = 12 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    // B-3d.1 R6 (§B3.18): an IDENTICAL re-arm — same child, kind, and slot
    // target, exactly what the forced-yield convergence sites re-publish —
    // short-circuits at the funnel and demotes NOTHING.
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, true);
    // A CHANGED relation (different child) still demotes via prepareSlotMutation.
    const c2 = try makeB3LinkTrace(gpa, &state, &proto, 3, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, c2, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, false);

    // Restore the ring relation (changed again: c2 -> b) for the closeRegion leg.
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try state.promoteSet(edges, key);
    try state.region_policy.region_profit.put(gpa, key, .{ .root_frame_depth = 1, .root_call_seq = key.activation });
    state.closeRegion(key);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
}

test "B-3b.2 prepareNativeEntry retains same activation and demotes a different activation" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1705, .code = &code, .name = "b3-entry", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const same: RegionKey = .{ .region_id = @enumFromInt(4), .activation = 20 };
    const other: RegionKey = .{ .region_id = @enumFromInt(5), .activation = 21 };
    try installB3PromotionRegion(&state, same, &.{ a, b });
    const edges = state.detectPromotableSet(&observed, same).?;
    defer gpa.free(edges);
    state.region_policy.setContext(1, same.activation);
    try state.promoteSet(edges, same);
    state.prepareNativeEntry();
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    _ = state.region_policy.region_profit.remove(same);
    try state.region_policy.region_profit.put(gpa, other, .{ .root_frame_depth = 1, .root_call_seq = other.activation });
    state.region_policy.setContext(1, other.activation);
    state.prepareNativeEntry();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
}

test "B-3b.2 replay walk queues demotion and applies it before pending disarms" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1706, .code = &code, .name = "b3-deferred", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(6), .activation = 30 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    state.registry.native_physical.enterReplayWalk();
    state.demoteSetsTouching(a, 0);
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.pending_demote.items.len);
    try testing.expect(state.registry.native_physical.pending_disarm_all);
    state.registry.native_physical.exitReplayWalk();
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    for (edges) |edge| try expectB3Patched(edge, false);
}

test "B-3d.1 low-yield unfreeze demotes the region's promotion in the same act" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1707, .code = &code, .name = "b3d-unfreeze", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(7), .activation = 40 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    state.config.min_useful = 8;

    // Depth 0: the low-yield verdict unfreezes AND demotes immediately —
    // patches never outlive the frozen state that justified them (§B3.17 R2;
    // pre-existing hole: the barren-exhaustion path could unfreeze with the
    // patches live and panic the next drain on the frozen check).
    state.flushRegionWindow(key, 1);
    try testing.expect(!state.region_policy.region_profit.get(key).?.frozen);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.silent_demotion_reasons.unfreeze);
    for (edges) |edge| try expectB3Patched(edge, false);

    // Mid-walk: the same verdict QUEUES the demotion; the walk applies it at
    // its exit, exactly like every other deferred demotion source.
    {
        const accum = state.region_policy.region_profit.getPtr(key).?;
        accum.frozen = true;
        accum.useful_streak = state.config.freeze_windows;
    }
    try state.promoteSet(edges, key);
    state.registry.native_physical.enterReplayWalk();
    state.flushRegionWindow(key, 1);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.pending_demote.items.len);
    state.registry.native_physical.exitReplayWalk();
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 2), state.registry.native_physical.silent_demotion_reasons.unfreeze);
    for (edges) |edge| try expectB3Patched(edge, false);
}

test "B-3d round-6: a repeated-parent SET firing out of order resolves its terminal by measurement" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [16]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1799, .code = &code, .name = "b3-round6", .num_registers = 2 };
    // Set {P.e0→C, C.e0→P, P.e1→D, D.e0→P}: P owns TWO member edges and the
    // exits are data-dependent guards, so nothing makes P alternate between
    // them — the burst below fires P.e0/C.e0 repeatedly and never reaches P.e1
    // or D at all. No ring order exists; canonical storage order is
    // (parent id, exit) and carries no firing information.
    const p = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const c = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    const d = try makeB3LinkTrace(gpa, &state, &proto, 3, 3, 1);
    const set = [_]PromotedEdge{
        .{ .parent = p, .exit = 0, .kind = .deopt, .child = c, .arm_kind = .loop_done_linked, .resume_pc = c.code.anchor.pc },
        .{ .parent = p, .exit = 1, .kind = .deopt, .child = d, .arm_kind = .loop_done_linked, .resume_pc = d.code.anchor.pc },
        .{ .parent = c, .exit = 0, .kind = .deopt, .child = p, .arm_kind = .loop_done_linked, .resume_pc = p.code.anchor.pc },
        .{ .parent = d, .exit = 0, .kind = .deopt, .child = p, .arm_kind = .loop_done_linked, .resume_pc = p.code.anchor.pc },
    };

    // Three transitions, all on edges 0 and 2: P.e0, C.e0, P.e0. Round-robin
    // phase arithmetic over a 4-ring would have called the terminal edge
    // "entry + 3 - 1" — P.e1→D — and resumed at D's anchor, which the burst
    // never entered. The measured image identifies the terminal cell as the
    // ONE cell whose `last_ordinal` equals the transition count (the D4
    // assert `driveSilentBurst` enforces before handing back a resume
    // contract), for ANY interleaving.
    var summary: [set.len]nativegen.SilentSummaryCell = @splat(std.mem.zeroes(nativegen.SilentSummaryCell));
    summary[0] = .{
        .region_work = 2,
        .selection_work = 2,
        .qualifying_rows = 0,
        .productive_firings = 2,
        .last_local = 1,
        .last_productive_ordinal = 3,
        .firings = 2,
        .last_ordinal = 3,
    };
    summary[2] = .{
        .region_work = 1,
        .selection_work = 1,
        .qualifying_rows = 0,
        .productive_firings = 1,
        .last_local = 1,
        .last_productive_ordinal = 2,
        .firings = 1,
        .last_ordinal = 2,
    };
    const transitions: u64 = 3;
    var total: u64 = 0;
    for (summary) |cell| total += cell.firings;
    try testing.expectEqual(transitions, total);
    // Unfired cells contribute nothing.
    try testing.expectEqual(@as(u64, 0), summary[1].firings);
    try testing.expectEqual(@as(u64, 0), summary[3].firings);
    // Exactly one cell owns the final ordinal, and it is P.e0→C — not the
    // edge any positional reconstruction would have produced.
    var terminal: ?usize = null;
    for (summary, 0..) |cell, i| {
        if (cell.last_ordinal == transitions) {
            try testing.expectEqual(@as(?usize, null), terminal);
            terminal = i;
        }
    }
    try testing.expectEqual(@as(?usize, 0), terminal);
    try testing.expectEqual(c, set[terminal.?].child);
    try testing.expectEqual(c.code.anchor.pc, set[terminal.?].resume_pc);
}

test "B-3b.3 promoted native cycle drains exact accounting and off-cycle suffix" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.min_useful = 1;
    state.config.silent_budget = trace_exec.LEDGER_CAP;
    state.config.max_barren_run = 64;
    state.config.promote_after = 2;

    var code: [4]Instr = @splat(Instr.op0(.halt));
    code[1] = Instr.op0(.for_loop);
    const proto = Proto{ .id = 1710, .code = &code, .name = "b3-silent-e2e", .num_registers = 2 };
    const cont = try makeB3LinkTrace(gpa, &state, &proto, 1, 2, 1);
    const inner = try makeB3LoopDoneTrace(gpa, &state, &proto, 2, 1);
    try testing.expect(try state.armNativeLink(cont, 0, inner, .link_terminal));
    try testing.expect(try state.armNativeLink(inner, 5, cont, .loop_done_linked));

    const rid: RegionId = @enumFromInt(1710);
    const key: RegionKey = .{ .region_id = rid, .activation = 77 };
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = proto.id, .source_pc = inner.code.anchor.pc },
            .{ .proto_id = proto.id, .source_pc = cont.code.anchor.pc },
        }),
        .owner = cont.code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    const initial_accum = RegionAccum{
        .root_frame_depth = 1,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
        .useful_streak = state.config.freeze_windows,
        .frozen = true,
    };
    try state.region_policy.region_profit.put(gpa, key, initial_accum);
    state.region_policy.setContext(1, key.activation);

    // The unpromoted oracle executes the same armed C↔I workload until the
    // reporting ledger cap forces a yield, then replays every row normally.
    var tags = [_]u8{ @intFromEnum(value.Tag.int), @intFromEnum(value.Tag.int) };
    var payloads = [_]u64{ @bitCast(@as(i64, 2)), @bitCast(@as(i64, 1)) };
    const regs = RegWindow.of(&tags, &payloads);
    const ordinary = cont.native.compiled.runCapturingLedger(
        regs,
        &state.ledger_scratch,
        state.silentStaging(),
    );
    try testing.expectEqual(@as(usize, trace_exec.LEDGER_CAP), ordinary.ledger_len);
    try testing.expectEqual(trace_exec.LedgerOutcome.yielded, state.ledger_scratch[ordinary.ledger_len - 1].outcome);
    const evidence = state.ledger_scratch;
    var ordinary_completed: usize = 0;
    var ordinary_resume: u32 = cont.code.anchor.pc;
    var ordinary_hops: usize = 0;
    _ = state.replayLedger(
        state.ledger_scratch[0..ordinary.ledger_len],
        cont,
        1,
        &proto,
        &ordinary_completed,
        &ordinary_resume,
        &ordinary_hops,
        8,
        .continuation_call,
        true,
        null,
    );
    state.applyPendingDisarms();
    state.drainPendingBridgeArm(true);
    state.drainProvenanceArms(true);
    const ordinary_accum = state.region_policy.region_profit.get(key).?;
    const ordinary_cont_hits = cont.hit_count;
    const ordinary_inner_hits = inner.hit_count;
    const ordinary_link_exits = state.native_link_exits;
    const ordinary_link_follows = state.native_link_follow_count;
    const ordinary_all_follows = state.link_follow_count;
    const ordinary_loopdone_fused = state.native_loopdone_link_fused;
    const ordinary_flushes = state.region_policy.region_profit_flushes;
    const ordinary_flushed_work = state.region_policy.region_profit_flushed_work;

    // Reset only fields the oracle replay moved, then require two identical
    // successful detections before the production promotion gate publishes.
    state.region_policy.region_profit.getPtr(key).?.* = initial_accum;
    cont.hit_count = 0;
    inner.hit_count = 0;
    state.native_link_exits = 0;
    state.native_link_follow_count = 0;
    state.link_follow_count = 0;
    state.native_loopdone_link_fused = 0;
    state.region_policy.region_profit_flushes = 0;
    state.region_policy.region_profit_flushed_work = 0;
    state.config.silent_promotion_enabled = true;
    _ = state.driveDispatcherLedger(cont, &evidence, &proto, regs, true);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    _ = state.driveDispatcherLedger(cont, &evidence, &proto, regs, true);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 2), state.silent_promotion_candidates);

    // Detection replays are evidence, not part of the differential workload.
    // Reset the fields they moved before executing the promoted comparison span.
    state.region_policy.region_profit.getPtr(key).?.* = initial_accum;
    cont.hit_count = 0;
    inner.hit_count = 0;
    state.native_link_exits = 0;
    state.native_link_follow_count = 0;
    state.link_follow_count = 0;
    state.native_loopdone_link_fused = 0;
    state.region_policy.region_profit_flushes = 0;
    state.region_policy.region_profit_flushed_work = 0;

    state.prepareNativeEntry();
    const silent = cont.native.compiled.runCapturingLedger(
        regs,
        &state.ledger_scratch,
        state.silentStaging(),
    );
    try testing.expectEqual(@as(u64, 1), silent.silent_active);
    try testing.expect(silent.silent_transitions > 1);
    try testing.expectEqual(@as(usize, 0), silent.ledger_len);
    var silent_completed: usize = 0;
    var silent_resume: u32 = cont.code.anchor.pc;
    var silent_hops: usize = 0;
    const silent_dir = state.drainSilentResult(
        silent,
        .continuation_call,
        &proto,
        &silent_completed,
        &silent_resume,
        &silent_hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(silent_dir == .return_result);

    // Differential equivalence over every deterministic field replayLedger's
    // row accounting moved. Coverage/TSC is deliberately disabled here: one
    // native span cannot be attributed per member in the promoted mode.
    const silent_accum = state.region_policy.region_profit.get(key).?;
    try testing.expectEqual(ordinary_accum.outer_traversals, silent_accum.outer_traversals);
    try testing.expectEqual(ordinary_accum.window_base, silent_accum.window_base);
    try testing.expectEqual(ordinary_accum.useful_window_seen, silent_accum.useful_window_seen);
    try testing.expectEqual(ordinary_accum.barren_run, silent_accum.barren_run);
    try testing.expectEqual(ordinary_accum.useful_streak, silent_accum.useful_streak);
    try testing.expectEqual(ordinary_accum.frozen, silent_accum.frozen);
    try testing.expectEqual(ordinary_cont_hits, cont.hit_count);
    try testing.expectEqual(ordinary_inner_hits, inner.hit_count);
    try testing.expectEqual(ordinary_link_exits, state.native_link_exits);
    try testing.expectEqual(ordinary_link_follows, state.native_link_follow_count);
    try testing.expectEqual(ordinary_all_follows, state.link_follow_count);
    try testing.expectEqual(ordinary_loopdone_fused, state.native_loopdone_link_fused);
    try testing.expectEqual(ordinary_flushes, state.region_policy.region_profit_flushes);
    try testing.expectEqual(ordinary_flushed_work, state.region_policy.region_profit_flushed_work);

    // Synthetic off-cycle reporting suffix: one silent C.link transition enters
    // inner, then inner reports an ordinary guard with cumulative rbx advanced by
    // two. The suffix must subtract silent_cum=7 and account exactly local=2.
    const set = &state.registry.native_physical.promoted_sets.items[0];
    const suffix_drains_before = state.silent_suffix_drains;
    var cont_phase: usize = 0;
    for (set.edges, 0..) |edge, phase| if (edge.parent == cont) {
        cont_phase = phase;
        break;
    };
    // One silent transition on cont's edge — the cell image its epilogue would
    // have written. The drain cross-checks summed `firings` against
    // `silent_transitions`, so a synthetic result must stage both.
    set.summary[cont_phase].firings = 1;
    set.summary[cont_phase].last_ordinal = 1;
    state.ledger_scratch[0] = .{
        .cum = 9,
        .id = inner.id,
        .exit = 2,
        .reason = .normal,
        .kind = .deopt,
        .outcome = .normal,
    };
    const suffix_result = trace_exec.ExecResult{
        .completed = 9,
        .exit_instr = 2,
        .final_trace_id = inner.id,
        .local_completed = 2,
        .ledger_len = 1,
        .silent_active = 1,
        .silent_transitions = 1,
        .silent_budget = state.config.silent_budget,
        .barren_budget = state.config.max_barren_run,
        .silent_cell = @intFromPtr(&set.metadata[cont_phase]),
        .cur_zero_run = 1,
        .silent_cum = 7,
        .silent_last_cell = @intFromPtr(&set.metadata[cont_phase]),
    };
    var suffix_completed: usize = 0;
    var suffix_resume: u32 = 0;
    var suffix_hops: usize = 0;
    const suffix_dir = state.drainSilentResult(
        suffix_result,
        .continuation_call,
        &proto,
        &suffix_completed,
        &suffix_resume,
        &suffix_hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    const suffix_chain = switch (suffix_dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), suffix_chain.completed);
    try testing.expectEqual(@as(u32, 1), suffix_chain.resume_pc);
    try testing.expectEqual(suffix_drains_before + 1, state.silent_suffix_drains);

    // The same suppressed C.link transition followed by a terminal inner
    // loop-done must reconstruct C as the continuation cursor. Using the child
    // as `cont` here would fail the post-PC contract and incorrectly break.
    // The previous drain consumed and cleared the mailbox; stage this call's own
    // single firing.
    set.summary[cont_phase].firings = 1;
    set.summary[cont_phase].last_ordinal = 1;
    state.ledger_scratch[0] = .{
        .cum = 7,
        .id = inner.id,
        .exit = 5,
        .reason = .normal,
        .kind = .loop_done_linked,
        .outcome = .normal,
    };
    const loop_done_suffix = trace_exec.ExecResult{
        .completed = 7,
        .exit_instr = 5,
        .final_trace_id = inner.id,
        .ledger_len = 1,
        .silent_active = 1,
        .silent_transitions = 1,
        .silent_budget = state.config.silent_budget,
        .barren_budget = state.config.max_barren_run,
        .silent_cell = @intFromPtr(&set.metadata[cont_phase]),
        .cur_zero_run = state.region_policy.region_profit.get(key).?.barren_run,
        .silent_cum = 7,
        .silent_last_cell = @intFromPtr(&set.metadata[cont_phase]),
    };
    suffix_completed = 0;
    suffix_resume = 0;
    suffix_hops = 0;
    const loop_done_dir = state.drainSilentResult(
        loop_done_suffix,
        .continuation_call,
        &proto,
        &suffix_completed,
        &suffix_resume,
        &suffix_hops,
        8,
        true,
        null,
    ) orelse return error.TestUnexpectedResult;
    const loop_done_cont = switch (loop_done_dir) {
        .run_continuation => |t| t,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(cont, loop_done_cont);
    try testing.expectEqual(@as(usize, 1), suffix_completed);
    try testing.expectEqual(cont.code.anchor.pc, suffix_resume);
    try testing.expectEqual(@as(usize, 1), suffix_hops);
    try testing.expectEqual(suffix_drains_before + 2, state.silent_suffix_drains);
    state.applyPendingDisarms();
}

test "B-3d.2 repeated-parent set promotes, zero-evidence edges included, and an out-of-order burst drains by measurement" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.max_barren_run = 64;
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1720, .code = &code, .name = "b3d-set", .num_registers = 4 };
    // P has TWO armable exits (5 and 7) — the sibling-automaton shape the ring
    // grammar structurally could not promote: nothing makes P alternate
    // between its exits, so no fixed rotation exists.
    const p = try makeB3BridgeSuccessorTrace(gpa, &state, &proto, 71, 4, 8);
    const c = try makeB3LinkTrace(gpa, &state, &proto, 72, 5, 4);
    const d = try makeB3LinkTrace(gpa, &state, &proto, 73, 6, 4);
    try testing.expect(try state.armNativeLink(p, 5, c, .ordinary_guard));
    try testing.expect(try state.armNativeLink(p, 7, d, .ordinary_guard));
    try testing.expect(try state.armNativeLink(c, 0, p, .link_terminal));
    try testing.expect(try state.armNativeLink(d, 0, p, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(1720), .activation = 55 };
    try installB3PromotionRegion(&state, key, &.{ p, c, d });
    state.region_policy.setContext(1, key.activation);

    // Evidence touches only the P.e5/C edges; the P.e7 and D edges promote on
    // registry proof alone (§B3.18 R5(c): zero-evidence candidate edges are an
    // accepted trade — firing evidence arrives later via summary cells).
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(p, 5, .deopt),
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(p, 5, .deopt),
    };
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try testing.expectEqual(@as(usize, 4), edges.len);
    try state.promoteSet(edges, key);
    const set = &state.registry.native_physical.promoted_sets.items[0];
    var p5_phase: usize = 0;
    var c0_phase: usize = 0;
    for (set.edges, 0..) |edge, phase| {
        if (edge.parent == p and edge.exit == 5) p5_phase = phase;
        if (edge.parent == c) c0_phase = phase;
    }

    // Rowless burst image P.e5 → C → P.e5 (ordinals 1..3): the terminal is the
    // MEASURED owner of the final ordinal (P.e5, firings=2), while any
    // positional reconstruction over the 4-edge storage order would walk off
    // through the never-fired P.e7/D edges. Budget exhaustion ends the burst.
    set.summary[p5_phase] = .{
        .region_work = 0,
        .selection_work = 2,
        .qualifying_rows = 0,
        .productive_firings = 0,
        .last_local = 0,
        .last_productive_ordinal = 0,
        .firings = 2,
        .last_ordinal = 3,
    };
    set.summary[c0_phase] = .{
        .region_work = 0,
        .selection_work = 0,
        .qualifying_rows = 0,
        .productive_firings = 0,
        .last_local = 0,
        .last_productive_ordinal = 0,
        .firings = 1,
        .last_ordinal = 2,
    };
    var completed: usize = 0;
    var resume_pc_value: u32 = 0;
    var hops: usize = 0;
    const dir = state.drainSilentResult(.{
        .completed = 6,
        .exit_instr = 5,
        .ledger_len = 0,
        .silent_active = 1,
        .silent_transitions = 3,
        .silent_budget = 3,
        .barren_budget = 64,
        .silent_cell = @intFromPtr(&set.metadata[p5_phase]),
        .cur_zero_run = 3,
        .silent_cum = 6,
        .silent_last_cell = @intFromPtr(&set.metadata[p5_phase]),
    }, .continuation_call, &proto, &completed, &resume_pc_value, &hops, 8, true, null) orelse
        return error.TestUnexpectedResult;
    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    // The resume contract belongs to the measured terminal edge: an ordinary
    // guard resumes at its SOURCE header (P's anchor), not at any successor a
    // ring order would have predicted.
    try testing.expectEqual(p.code.anchor.pc, result.resume_pc);
    try testing.expectEqual(@as(usize, 6), result.completed);
    try testing.expectEqual(@as(u64, 1), state.silent_budget_exhaustions);
    state.demoteAllSets();
}

// ── C′ parked promotion proofs (doc 47 Increment B follow-up) ────────────────

/// Full-cap forced-yield ledger over the a/b ring — the evidence class
/// `considerSilentPromotion` requires before it will consult a parked proof.
fn b3FullYieldedLedger(a: *Trace, b: *Trace, buf: *[trace_exec.LEDGER_CAP]trace_exec.LedgerEntry) []const trace_exec.LedgerEntry {
    for (buf, 0..) |*row, i| {
        row.* = b3ObservedRow(if (i % 2 == 0) a else b, 0, .link_terminal);
    }
    buf[buf.len - 1].outcome = .yielded;
    return buf;
}

test "C' parked proof: clean region_close parks; next activation re-promotes without detection or streak" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1720, .code = &code, .name = "b3-parked", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key1: RegionKey = .{ .region_id = @enumFromInt(7), .activation = 40 };
    try installB3PromotionRegion(&state, key1, &.{ a, b });
    state.region_policy.region_defs.getPtr(key1.region_id).?.fallback_owner = true;
    const edges = state.detectPromotableSet(&observed, key1).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key1);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);

    // Clean close: promotion demotes with `.region_close`, and the proof parks.
    state.closeRegion(key1);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.parked_proofs.items.len);
    try testing.expectEqual(key1.region_id, state.registry.native_physical.parked_proofs.items[0].region_id);
    for (edges) |edge| try expectB3Patched(edge, false);

    // A NEW activation of the same region: one full-cap yielded ledger with a
    // frozen accumulator re-promotes from the parked proof — no
    // `detectPromotableSet` candidacy (candidates counter stays 0), no
    // `promote_after` streak.
    const key2: RegionKey = .{ .region_id = key1.region_id, .activation = 41 };
    try state.region_policy.region_profit.put(gpa, key2, .{
        .root_frame_depth = 1,
        .root_call_seq = key2.activation,
        .useful_window_seen = true,
        .useful_streak = state.config.freeze_windows,
        .frozen = true,
    });
    state.region_policy.setContext(1, key2.activation);
    var buf: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    try testing.expectEqual(@as(u64, 1), state.silent_parked_reuses);
    try testing.expectEqual(@as(u64, 0), state.silent_promotion_candidates);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    try testing.expect(std.meta.eql(key2, state.registry.native_physical.promoted_sets.items[0].region_key));
    // Take semantics: the proof was consumed by the reuse.
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
    for (edges) |edge| try expectB3Patched(edge, true);
    state.demoteAllSets();
}

test "C' parked proof: .unfreeze never parks; a non-fallback (primary) region_close never parks" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1721, .code = &code, .name = "b3-nopark", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(8), .activation = 50 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    state.region_policy.region_defs.getPtr(key.region_id).?.fallback_owner = true;
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);

    // `.unfreeze` is negative evidence — no park.
    try state.promoteSet(edges, key);
    _ = state.demotePromotionsForRegionReason(key, .unfreeze);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);

    // A primary-elected owner (fallback_owner=false) parks nothing either:
    // its promotion lifecycle predates Increment B and stays untouched.
    state.region_policy.region_defs.getPtr(key.region_id).?.fallback_owner = false;
    try state.promoteSet(edges, key);
    _ = state.demotePromotionsForRegionReason(key, .region_close);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
}

test "C' parked proof: trace retire and defs mutation drop proofs; a stale proof fails closed into detection" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1722, .code = &code, .name = "b3-drop", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(9), .activation = 60 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    state.region_policy.region_defs.getPtr(key.region_id).?.fallback_owner = true;

    // Leg 1: a retiring member trace drops the proof (its pointers dangle).
    {
        const edges = state.detectPromotableSet(&observed, key).?;
        defer gpa.free(edges);
        try state.promoteSet(edges, key);
        _ = state.demotePromotionsForRegionReason(key, .region_close);
        try testing.expectEqual(@as(usize, 1), state.registry.native_physical.parked_proofs.items.len);
        state.registry.native_physical.resetLinksTouching(&state.registry.mcode_arena, b);
        try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
    }

    // Leg 2: a region-defs mutation drops the proof (membership is part of it).
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    {
        const edges = state.detectPromotableSet(&observed, key).?;
        defer gpa.free(edges);
        try state.promoteSet(edges, key);
        _ = state.demotePromotionsForRegionReason(key, .region_close);
        try testing.expectEqual(@as(usize, 1), state.registry.native_physical.parked_proofs.items.len);
        state.registry.native_physical.demoteSetsForRegionDefsMutation();
        try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
    }

    // Leg 3: a proof made stale by a RELATION change (same slot re-armed to a
    // different child — a funnel that does not drop proofs) fails the
    // `promoteSet` re-validation, is discarded (take semantics), and the call
    // falls through to ordinary detection of the CURRENT armed population.
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    {
        const edges = state.detectPromotableSet(&observed, key).?;
        defer gpa.free(edges);
        try state.promoteSet(edges, key);
        _ = state.demotePromotionsForRegionReason(key, .region_close);
        try testing.expectEqual(@as(usize, 1), state.registry.native_physical.parked_proofs.items.len);
    }
    const c2 = try makeB3LinkTrace(gpa, &state, &proto, 3, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, c2, .link_terminal));
    state.region_policy.setContext(1, key.activation);
    var buf: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    try testing.expectEqual(@as(u64, 0), state.silent_parked_reuses);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
    // Detection DID run against the live registry — and correctly rejected
    // the a→b evidence rows against the re-armed a→c2 relation, promoting
    // nothing (the stale proof could not smuggle the old relation through).
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.child_mismatch);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    state.demoteAllSets();
}

// ── inc-B follow-up: dormant admission, no-candidate settlement, instability ─

test "inc-B dormant admission: min-RegionId of the matching dormant regions admits; non-matching eligibles are charged; saturated failures are terminal" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1730, .code = &code, .name = "b3-admit", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));

    // Two MATCHING dormant fallback regions (same membership) + one that can
    // never match (empty membership). Admission must pick the minimum
    // matching RegionId, leave the other matcher dormant and uncharged, and
    // charge the non-matcher one failure.
    const k20: RegionKey = .{ .region_id = @enumFromInt(20), .activation = 70 };
    const k21: RegionKey = .{ .region_id = @enumFromInt(21), .activation = 71 };
    try installB3PromotionRegion(&state, k20, &.{ a, b });
    try installB3PromotionRegion(&state, k21, &.{ a, b });
    const rid22: RegionId = @enumFromInt(22);
    try state.region_policy.region_defs.put(gpa, rid22, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.alloc(ProgramPoint, 0),
        .owner = .{ .proto = &proto, .pc = 3 },
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 0 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    for ([_]RegionId{ k20.region_id, k21.region_id, rid22 }) |rid| {
        const d = state.region_policy.region_defs.getPtr(rid).?;
        d.fallback_owner = true;
        d.dormant = true;
    }

    var buf: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    // NOTE: admission triggers `rebuildRegions`, which tombstones these
    // hand-installed defs (their edges aren't in the topology view) — but the
    // defs and their learning fields persist, so the admission outcome stays
    // assertable.
    try testing.expect(!state.region_policy.region_defs.get(k20.region_id).?.dormant);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(k20.region_id).?.admission_failures);
    try testing.expect(state.region_policy.region_defs.get(k21.region_id).?.dormant);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(k21.region_id).?.admission_failures);
    try testing.expect(state.region_policy.region_defs.get(rid22).?.dormant);
    try testing.expectEqual(@as(u8, 1), state.region_policy.region_defs.get(rid22).?.admission_failures);
}

test "inc-B dormant admission: saturated admission_failures is terminal even for a ledger the region would match" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1731, .code = &code, .name = "b3-terminal", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(23), .activation = 72 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    {
        const d = state.region_policy.region_defs.getPtr(key.region_id).?;
        d.fallback_owner = true;
        d.dormant = true;
        d.admission_failures = state.config.region_admission_probe_cap;
    }
    var buf: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    const d = state.region_policy.region_defs.get(key.region_id).?;
    try testing.expect(d.dormant);
    try testing.expectEqual(state.config.region_admission_probe_cap, d.admission_failures);
}

test "inc-B no-candidate settlement: consecutive dry full-cap ledgers saturate and invalidate; a successful (parked) promotion resets the count" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1732, .code = &code, .name = "b3-dry", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    // NO armed links: the region is active + frozen but detection can never
    // produce a candidate — the failed-opportunity shape.
    const key: RegionKey = .{ .region_id = @enumFromInt(24), .activation = 80 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    state.region_policy.region_defs.getPtr(key.region_id).?.fallback_owner = true;
    state.region_policy.setContext(1, key.activation);
    var buf: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    const threshold = state.config.region_no_candidate_tombstone;
    var i: u8 = 0;
    while (i < threshold - 1) : (i += 1) state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(threshold - 1, d.no_candidate_runs);
        try testing.expect(!d.tombstoned);
    }
    // A successful promotion resets the CONSECUTIVE count: reuse a parked
    // proof (park it directly from a real detection with the links armed).
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    // (streak 1 of promote_after — no promotion yet, but detection succeeded,
    //  so the dry-run count must NOT have advanced.)
    var j: u32 = 1;
    while (j < state.config.promote_after) : (j += 1) state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promoted_sets.items.len);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 0), d.no_candidate_runs);
        try testing.expect(!d.tombstoned);
    }
    state.demoteAllSets();

    // Saturation: from a clean count, dry ledgers to the threshold invalidate
    // one-shot and request the deferred maps rebuild.
    state.disarmAllLinks();
    state.region_policy.region_defs.getPtr(key.region_id).?.no_candidate_runs = 0;
    i = 0;
    while (i < threshold) : (i += 1) state.considerSilentPromotion(b3FullYieldedLedger(a, b, &buf));
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expect(d.tombstoned);
        try testing.expect(!d.armable);
    }
    try testing.expect(state.pending_region_rebuild);
}

test "inc-B instability: an .unfreeze strike on a LIVE promotion charges; a strike without one does not; clean region_close survival recovers; saturation tombstones" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1733, .code = &code, .name = "b3-instab", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(25), .activation = 90 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    state.region_policy.region_defs.getPtr(key.region_id).?.fallback_owner = true;

    // Strike with NO live promotion: no instability charge.
    state.flushRegionWindow(key, 1);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(key.region_id).?.instability);

    // Strike with a LIVE promotion: `.unfreeze` demotion + instability 1.
    // (The promotion-free strike above unfroze the accumulator; re-freeze.)
    try state.region_policy.region_profit.put(gpa, key, .{ .root_frame_depth = 1, .root_call_seq = key.activation, .useful_window_seen = true, .frozen = true });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    state.flushRegionWindow(key, 1);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.silent_demotion_reasons.unfreeze);
    try testing.expectEqual(@as(u8, 1), state.region_policy.region_defs.get(key.region_id).?.instability);
    // An `.unfreeze` demotion parks nothing.
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);

    // Clean region_close survival decrements. (Re-freeze the accumulator
    // first — the strike above unfroze it, and promotion requires frozen.)
    try state.region_policy.region_profit.put(gpa, key, .{ .root_frame_depth = 1, .root_call_seq = key.activation, .useful_window_seen = true, .frozen = true });
    try state.promoteSet(edges, key);
    state.closeRegion(key);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(key.region_id).?.instability);
    // ... and DID park (clean close of a fallback-owned live set).
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.parked_proofs.items.len);
    state.registry.native_physical.dropAllParkedProofs();

    // Saturation: with the counter one below the threshold, one more
    // unfreeze-of-a-live-promotion tombstones one-shot.
    state.region_policy.region_defs.getPtr(key.region_id).?.instability = state.config.region_instability_tombstone - 1;
    try state.region_policy.region_profit.put(gpa, key, .{ .root_frame_depth = 1, .root_call_seq = key.activation, .useful_window_seen = true, .frozen = true });
    try state.promoteSet(edges, key);
    state.flushRegionWindow(key, 1);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expect(d.tombstoned);
        try testing.expect(!d.armable);
    }
    try testing.expect(state.pending_region_rebuild);
}

test "C' parked proof invalidation (codex round 4): membership growth, exit mutation, and empty-links global disarm all drop proofs" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [4]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1734, .code = &code, .name = "b3-inval", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(26), .activation = 100 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    state.region_policy.region_defs.getPtr(key.region_id).?.fallback_owner = true;

    const park = struct {
        fn park(s: *TraceState, k: RegionKey, obs: []const trace_exec.LedgerEntry) !void {
            const edges = s.detectPromotableSet(obs, k).?;
            defer s.gpa.free(edges);
            try s.promoteSet(edges, k);
            _ = s.demotePromotionsForRegionReason(k, .region_close);
            try testing.expectEqual(@as(usize, 1), s.registry.native_physical.parked_proofs.items.len);
        }
    }.park;

    // Leg 1 — membership growth: a NEW armed region-member edge (fresh
    // parent `c` at a member anchor, never part of the parked set) falsifies
    // the parked proof's region-total claim and drops it, even with ZERO
    // live promoted sets.
    try park(&state, key, &observed);
    const c = try makeB3LinkTrace(gpa, &state, &proto, 3, 2, 1);
    try testing.expect(try state.armNativeLink(c, 0, a, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
    // Drop c's arm again so later legs re-detect the two-edge set.
    state.registry.native_physical.resetLinksTouching(&state.registry.mcode_arena, c);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));

    // Leg 2 — exit mutation: re-arming a RELATION named by the proof (a,0 →
    // different child) drops it at the physical funnel, so a later identical
    // re-arm cannot resurrect the invalidated evidence.
    try park(&state, key, &observed);
    const c2 = try makeB3LinkTrace(gpa, &state, &proto, 4, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, c2, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));

    // Leg 3 — global disarm with ZERO armed links (the TraceRegistry.clear
    // shape: links already gone, traces about to be destroyed) still drops
    // every proof — the drop happens before the empty-links early return.
    try park(&state, key, &observed);
    state.registry.native_physical.armed_links.clearRetainingCapacity();
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.parked_proofs.items.len);
}

test "doc 52 P0: recurrence evidence — owner resolution, streak build, resets" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    // Pin this test to the EVIDENCE machinery: with the P1 resident promotion
    // live, a reachable threshold would promote mid-test and change every
    // downstream expectation. Threshold behavior has its own doc 52 P1 tests.
    state.config.recurrence_promote_after = 100;
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1801, .code = &code, .name = "doc52-p0", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(7), .activation = 0 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    {
        const d = state.region_policy.region_defs.getPtr(key.region_id).?;
        d.fallback_owner = true;
        d.dormant = true;
    }

    // Qualifying recurrent pure burst: members a→b→a chained through armed
    // children, natural terminal (deopt/normal/normal) owned by the last
    // member's armed child (b) at an exit that is NOT a candidate edge.
    const burst = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 1, .deopt),
    };

    // First observation: owner resolution — one expensive probe charged,
    // signature stored, streak 1.
    state.considerSilentPromotion(&burst);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 1), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 1), d.recurrence_probe_charges);
        try testing.expectEqual(@as(u8, 4), d.recurrence_len);
    }

    // Identical observations ride the cheap signature path: streak builds
    // with no further charges, saturates past the threshold (held), and P0
    // promotes nothing.
    state.considerSilentPromotion(&burst);
    state.considerSilentPromotion(&burst);
    state.considerSilentPromotion(&burst);
    state.considerSilentPromotion(&burst);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 5), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 1), d.recurrence_probe_charges);
    }
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promotedSets().len);

    // A different qualifying shape re-resolves ownership: second charge, new
    // signature, streak restarts at 1.
    const burst_b = [_]trace_exec.LedgerEntry{
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 1, .deopt),
    };
    state.considerSilentPromotion(&burst_b);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 1), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 2), d.recurrence_probe_charges);
        try testing.expectEqual(@as(u8, 3), d.recurrence_len);
    }

    // A short forced-yield ledger is non-qualifying: streak resets, stored
    // signature survives (cheap re-match rebuilds the streak without a new
    // charge).
    const short_yield = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        .{ .cum = 0, .id = b.id, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .yielded },
    };
    state.considerSilentPromotion(&short_yield);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(key.region_id).?.recurrence_streak);
    state.considerSilentPromotion(&burst_b);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 1), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 2), d.recurrence_probe_charges);
    }

    // A full-cap forced-yield ledger resets the streak at the top of the
    // full-cap branch (before dormant admission, which here fails on
    // non-member rows and leaves the region dormant).
    var full: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    for (&full) |*r| r.* = .{ .cum = 0, .id = 999, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal };
    full[full.len - 1].outcome = .yielded;
    state.considerSilentPromotion(&full);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 0), d.recurrence_streak);
        try testing.expect(d.dormant);
    }

    // A terminal that IS a live candidate edge is rejected (grammar 3): the
    // probe is charged, no def wins, and the qualifying-but-unowned ledger
    // breaks every in-progress streak.
    state.considerSilentPromotion(&burst_b); // rebuild streak to 1 (cheap)
    const armed_terminal = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .deopt),
    };
    state.considerSilentPromotion(&armed_terminal);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 0), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 3), d.recurrence_probe_charges);
    }

    // Last-member→terminal child adjacency is enforced through the FULL
    // ledger: the last member row (b, child a) does not own a terminal
    // carried by b.
    const child_break = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(b, 1, .deopt),
    };
    const probe_key: RegionKey = .{ .region_id = key.region_id, .activation = 0 };
    try testing.expect(state.detectPromotableSetMembers(&child_break, probe_key, child_break.len - 1) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.child_mismatch);

    // The 2-arg delegate keeps the full-cap grammar: EVERY row is
    // membership-checked, so the non-member natural terminal fails it.
    try testing.expect(state.detectPromotableSet(&burst, probe_key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.open_chain);
}

test "doc 52 P0: recurrence owner resolution and cheap match pick the minimum RegionId" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1802, .code = &code, .name = "doc52-minid", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    // Two eligible defs with identical membership; rid 3 < rid 9.
    const key_lo: RegionKey = .{ .region_id = @enumFromInt(3), .activation = 0 };
    const key_hi: RegionKey = .{ .region_id = @enumFromInt(9), .activation = 1 };
    try installB3PromotionRegion(&state, key_lo, &.{ a, b });
    try installB3PromotionRegion(&state, key_hi, &.{ a, b });
    for ([_]RegionKey{ key_lo, key_hi }) |k| {
        const d = state.region_policy.region_defs.getPtr(k.region_id).?;
        d.fallback_owner = true;
        d.dormant = true;
    }

    const burst = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 1, .deopt),
    };

    // Owner resolution: BOTH eligible defs are probed and charged (win or
    // lose); the minimum RegionId wins the signature.
    state.considerSilentPromotion(&burst);
    {
        const lo = state.region_policy.region_defs.get(key_lo.region_id).?;
        const hi = state.region_policy.region_defs.get(key_hi.region_id).?;
        try testing.expectEqual(@as(u8, 1), lo.recurrence_streak);
        try testing.expectEqual(@as(u8, 1), lo.recurrence_probe_charges);
        try testing.expectEqual(@as(u8, 4), lo.recurrence_len);
        try testing.expectEqual(@as(u8, 0), hi.recurrence_streak);
        try testing.expectEqual(@as(u8, 1), hi.recurrence_probe_charges);
        try testing.expectEqual(@as(u8, 0), hi.recurrence_len);
    }

    // Cheap match with DUPLICATE signatures must also pick the minimum
    // RegionId — never hashmap iteration order — and reset the loser.
    {
        const lo = state.region_policy.region_defs.get(key_lo.region_id).?;
        const hi = state.region_policy.region_defs.getPtr(key_hi.region_id).?;
        hi.recurrence_len = lo.recurrence_len;
        hi.recurrence_ids = lo.recurrence_ids;
        hi.recurrence_exits = lo.recurrence_exits;
        hi.recurrence_kinds = lo.recurrence_kinds;
        hi.recurrence_streak = 7;
    }
    state.considerSilentPromotion(&burst);
    {
        const lo = state.region_policy.region_defs.get(key_lo.region_id).?;
        const hi = state.region_policy.region_defs.get(key_hi.region_id).?;
        try testing.expectEqual(@as(u8, 2), lo.recurrence_streak);
        try testing.expectEqual(@as(u8, 0), hi.recurrence_streak);
        try testing.expectEqual(@as(u8, 1), lo.recurrence_probe_charges);
        try testing.expectEqual(@as(u8, 1), hi.recurrence_probe_charges);
    }
}

test "doc 52 P1: threshold promotes a RESIDENT set — dormant region, exempt metadata, occupied hold, demotion notice" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1803, .code = &code, .name = "doc52-p1-resident", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 1, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 2, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(7), .activation = 0 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    {
        const d = state.region_policy.region_defs.getPtr(key.region_id).?;
        d.fallback_owner = true;
        d.dormant = true;
    }

    const burst = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 1, .deopt),
    };

    // Three observations: streak 3 < recurrence_promote_after (4) — nothing
    // promotes yet.
    state.considerSilentPromotion(&burst);
    state.considerSilentPromotion(&burst);
    state.considerSilentPromotion(&burst);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promotedSets().len);

    // Fourth: threshold → probe → resident promotion. The region STAYS
    // dormant; the set carries the sentinel key; every edge's metadata is
    // barren-exempt; the probe budget resets on success (per-promotion-
    // lifetime allowance).
    state.considerSilentPromotion(&burst);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promotedSets().len);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.resident_set_count);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.activation_set_count);
    const set = &state.registry.native_physical.promoted_sets.items[0];
    try testing.expect(set.isResident());
    try testing.expectEqual(key.region_id, set.region_key.region_id);
    try testing.expectEqual(trace.RESIDENT_ACTIVATION, set.region_key.activation);
    for (set.edges, 0..) |edge, i| {
        try expectB3Patched(edge, true);
        try testing.expectEqual(@as(u64, 1), set.metadata[i].barren_exempt);
    }
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expect(d.dormant);
        try testing.expectEqual(@as(u8, 4), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 0), d.recurrence_probe_charges);
    }

    // The resident set survives native-entry preparation with NO activation
    // open (the count-gated sweep exemption), and staging returns the budgets
    // with a zero run without resolving any activation.
    state.prepareNativeEntry();
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promotedSets().len);
    const staging = state.silentStaging();
    try testing.expectEqual(@as(u64, state.config.silent_budget), staging.silent_budget);
    try testing.expectEqual(@as(u64, state.config.max_barren_run), staging.barren_budget);
    try testing.expectEqual(@as(u64, 0), staging.cur_zero_run);

    // A further qualifying drain holds at the occupied resident slot — cheap
    // path only, streak saturates, no second set, distinct reject counter.
    state.considerSilentPromotion(&burst);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promotedSets().len);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.resident_occupied);
    try testing.expectEqual(@as(u8, 5), state.region_policy.region_defs.get(key.region_id).?.recurrence_streak);

    // Any demotion funnel resets the proof through the notice channel: a
    // retiring member trace tears the set down and zeroes streak+signature.
    state.resetLinksTouching(a);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promotedSets().len);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.resident_set_count);
    {
        const d = state.region_policy.region_defs.get(key.region_id).?;
        try testing.expectEqual(@as(u8, 0), d.recurrence_streak);
        try testing.expectEqual(@as(u8, 0), d.recurrence_len);
    }
}

test "doc 52 P1: one resident slot globally; per-RegionId dual-key backstop; mixed activation+resident drain splits credit and re-targets barren" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1804, .code = &code, .name = "doc52-p1-mixed", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 21, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 22, 2, 1);
    const c = try makeB3LinkTrace(gpa, &state, &proto, 23, 3, 4);
    const d_t = try makeB3LinkTrace(gpa, &state, &proto, 24, 4, 3);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    try testing.expect(try state.armNativeLink(c, 0, d_t, .link_terminal));
    try testing.expect(try state.armNativeLink(d_t, 0, c, .link_terminal));
    const key3: RegionKey = .{ .region_id = @enumFromInt(3), .activation = 0 };
    const key9: RegionKey = .{ .region_id = @enumFromInt(9), .activation = 1 };
    try installB3PromotionRegion(&state, key3, &.{ c, d_t });
    try installB3PromotionRegion(&state, key9, &.{ a, b });
    for ([_]RegionKey{ key3, key9 }) |k| {
        const dd = state.region_policy.region_defs.getPtr(k.region_id).?;
        dd.fallback_owner = true;
    }
    state.region_policy.region_defs.getPtr(key3.region_id).?.dormant = true;

    // rid 3 promotes RESIDENT via the recurrence funnel (c/d cycle).
    const burst3 = [_]trace_exec.LedgerEntry{
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(d_t, 0, .link_terminal),
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(d_t, 1, .deopt),
    };
    state.considerSilentPromotion(&burst3);
    state.considerSilentPromotion(&burst3);
    state.considerSilentPromotion(&burst3);
    state.considerSilentPromotion(&burst3);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.resident_set_count);

    // rid 9 promotes an ACTIVATION set (a/b cycle) — mixed support: a live
    // resident set does NOT block activation promotion.
    const observed9 = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const edges9 = state.detectPromotableSet(&observed9, key9).?;
    defer gpa.free(edges9);
    try state.promoteSet(edges9, key9);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.activation_set_count);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.resident_set_count);
    try testing.expectEqual(@as(usize, 2), state.registry.native_physical.promotedSets().len);

    // Activation edges are NOT barren-exempt; resident edges are.
    var res_set: *const trace.PromotedSet = undefined;
    var act_set: *const trace.PromotedSet = undefined;
    for (state.registry.native_physical.promoted_sets.items) |*s| {
        if (s.isResident()) res_set = s else act_set = s;
    }
    for (res_set.metadata) |m| try testing.expectEqual(@as(u64, 1), m.barren_exempt);
    for (act_set.metadata) |m| try testing.expectEqual(@as(u64, 0), m.barren_exempt);

    // Per-RegionId dual-key backstop: an ACTIVATION key for resident-owned
    // rid 3 is rejected across keyings; a RESIDENT key for a third region is
    // rejected by the occupied slot.
    try testing.expectError(error.PromotionRegionIdOwned, state.registry.native_physical.checkPromotable(
        edges9,
        .{ .region_id = key3.region_id, .activation = 42 },
    ));
    try testing.expectError(error.PromotionResidentOccupied, state.registry.native_physical.checkPromotable(
        edges9,
        .{ .region_id = @enumFromInt(11), .activation = trace.RESIDENT_ACTIVATION },
    ));

    // Mixed burst: resident edges fired ordinals 1–2, activation edges 3–4.
    // Entry cell is RESIDENT (barren must still settle into the ACTIVATION
    // accumulator); terminal cell is the activation set's last-fired edge.
    for (res_set.summary, 0..) |*cell, phase| {
        cell.* = std.mem.zeroes(nativegen.SilentSummaryCell);
        cell.firings = 1;
        cell.last_ordinal = @intCast(phase + 1);
        cell.last_local = 0;
    }
    for (act_set.summary, 0..) |*cell, phase| {
        cell.* = std.mem.zeroes(nativegen.SilentSummaryCell);
        cell.firings = 1;
        cell.last_ordinal = @intCast(phase + 3);
        cell.last_local = 0;
    }
    state.region_policy.setContext(1, key9.activation);
    var completed: usize = 0;
    var resume_pc_value: u32 = 0;
    var hops: usize = 0;
    const dir = state.driveSilentBurst(.{
        .completed = 0,
        .exit_instr = 0,
        .silent_active = 1,
        .silent_transitions = 4,
        .silent_budget = 4,
        .barren_budget = 64,
        .silent_cell = @intFromPtr(&res_set.metadata[0]),
        .cur_zero_run = 3,
        .silent_cum = 0,
        .silent_last_cell = @intFromPtr(&act_set.metadata[act_set.metadata.len - 1]),
    }, &proto, &completed, &resume_pc_value, &hops, 8, .continuation_call, true, null);
    switch (dir) {
        .return_result => {},
        else => return error.TestUnexpectedResult,
    }
    // Credit split — both keyings, per fired set, in suppressed-transition
    // units; NOT four call-global transitions attributed to the entry set.
    try testing.expectEqual(@as(u64, 2), state.region_policy.region_defs.get(key3.region_id).?.transitions_credit);
    try testing.expectEqual(@as(u64, 2), state.region_policy.region_defs.get(key9.region_id).?.transitions_credit);
    // Barren purity: settlement targets the fired ACTIVATION set's
    // accumulator even though the entry set was resident.
    try testing.expectEqual(@as(u32, 3), state.region_policy.region_profit.get(key9).?.barren_run);
}

test "doc 52 P1: resident-only native cycle — epilogue barren exemption end to end, drain with no activation open" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.silent_budget = 6;
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1805, .code = &code, .name = "doc52-p1-native", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 31, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 32, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(6), .activation = 0 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    {
        const d = state.region_policy.region_defs.getPtr(key.region_id).?;
        d.fallback_owner = true;
        d.dormant = true;
    }
    // Direct resident promotion (the funnel path is covered above).
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const edges = state.detectPromotableSet(&observed, .{ .region_id = key.region_id, .activation = 0 }).?;
    defer gpa.free(edges);
    try state.promoteResidentSet(edges, key.region_id);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.resident_set_count);

    // Run the REAL patched cycle with no activation open. The armed a→b→a
    // ring spins silently until the budget exhausts. Without the epilogue
    // exemption, six link-terminal firings would leave cur_zero_run == 6;
    // the exemption keeps the run untouched at its staged zero.
    var tags = [_]u8{ @intFromEnum(value.Tag.int), @intFromEnum(value.Tag.int) };
    var payloads = [_]u64{ 0, 0 };
    const regs = RegWindow.of(&tags, &payloads);
    state.prepareNativeEntry();
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promotedSets().len);
    const result = a.native.compiled.runCapturingLedger(regs, &state.ledger_scratch, state.silentStaging());
    try testing.expectEqual(@as(u64, 1), result.silent_active);
    try testing.expectEqual(@as(u64, 6), result.silent_transitions);
    try testing.expectEqual(@as(u64, 0), result.cur_zero_run);
    try testing.expectEqual(@as(usize, 0), result.ledger_len);

    // Drain with active == null: the resident-only burst needs no
    // activation, credits its own def, and settles no barren state.
    var completed: usize = 0;
    var resume_pc_value: u32 = 0;
    var hops: usize = 0;
    const dir = state.drainSilentResult(result, .continuation_call, &proto, &completed, &resume_pc_value, &hops, 8, true, null) orelse
        return error.TestUnexpectedResult;
    switch (dir) {
        .return_result => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u64, 6), state.region_policy.region_defs.get(key.region_id).?.transitions_credit);
    try testing.expectEqual(@as(u64, 1), state.silent_budget_exhaustions);
    try testing.expectEqual(@as(u64, 0), state.silent_barren_exhaustions);
}

test "doc 52 P1: demotion funnels — activation close skips residents; deferred demotion moves counts only at physical removal; defs mutation demotes" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code: [32]Instr = @splat(Instr.op0(.halt));
    const proto = Proto{ .id = 1806, .code = &code, .name = "doc52-p1-funnels", .num_registers = 2 };
    const a = try makeB3LinkTrace(gpa, &state, &proto, 41, 1, 2);
    const b = try makeB3LinkTrace(gpa, &state, &proto, 42, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, a, .link_terminal));
    const key: RegionKey = .{ .region_id = @enumFromInt(4), .activation = 0 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    {
        const d = state.region_policy.region_defs.getPtr(key.region_id).?;
        d.fallback_owner = true;
        d.dormant = true;
    }
    const observed = [_]trace_exec.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const edges = state.detectPromotableSet(&observed, .{ .region_id = key.region_id, .activation = 0 }).?;
    defer gpa.free(edges);
    try state.promoteResidentSet(edges, key.region_id);
    state.region_policy.region_defs.getPtr(key.region_id).?.recurrence_streak = 4;

    // An activation-lifecycle close for the SAME region (any real activation
    // key) must not touch the resident set — full-key match skips the
    // sentinel naturally.
    try testing.expectEqual(@as(usize, 0), state.demotePromotionsForRegion(.{ .region_id = key.region_id, .activation = 5 }));
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.resident_set_count);
    try testing.expectEqual(@as(u8, 4), state.region_policy.region_defs.get(key.region_id).?.recurrence_streak);

    // A demotion queued mid-walk leaves the patched reality — and therefore
    // the count caches and the recurrence proof — untouched until
    // drainBarrier applies it at depth 0.
    state.registry.native_physical.enterReplayWalk();
    state.demoteSet(0);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.resident_set_count);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.promotedSets().len);
    state.registry.native_physical.exitReplayWalk();
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.promotedSets().len);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.resident_set_count);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(key.region_id).?.recurrence_streak);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(key.region_id).?.recurrence_len);

    // Re-promote, then a region-defs mutation demotes wholesale and the
    // notice drains through the wrapper's sync.
    const edges2 = state.detectPromotableSet(&observed, .{ .region_id = key.region_id, .activation = 0 }).?;
    defer gpa.free(edges2);
    try state.promoteResidentSet(edges2, key.region_id);
    state.region_policy.region_defs.getPtr(key.region_id).?.recurrence_streak = 4;
    state.demoteSetsForRegionDefsMutation();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.resident_set_count);
    try testing.expectEqual(@as(u8, 0), state.region_policy.region_defs.get(key.region_id).?.recurrence_streak);
}
