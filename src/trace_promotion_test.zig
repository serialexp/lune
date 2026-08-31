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
const irinterp = @import("irinterp.zig");
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
        .id = id,
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = entry_slots,
        .entry_guards = entry_guards,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.mcode_arena, t, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.cache.append(gpa, t);
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
        .id = id,
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = entry_slots,
        .entry_guards = entry_guards,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.mcode_arena, t, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.cache.append(gpa, t);
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
        .id = id,
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = entry_slots,
        .entry_guards = entry_guards,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.mcode_arena, t, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.cache.append(gpa, t);
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
        .id = id,
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = entry_slots,
        .entry_guards = entry_guards,
        .exit_prov = exit_prov,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.mcode_arena, t, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.cache.append(gpa, t);
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
        .id = id,
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = entry_slots,
        .entry_guards = entry_guards,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.mcode_arena, t, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.cache.append(gpa, t);
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
        .id = id,
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = instrs,
        .consts = consts,
        .entry_slots = entry_slots,
        .entry_guards = entry_guards,
    };
    t.native = .{ .compiled = nativegen.compileInto(gpa, &state.mcode_arena, t, null, null) orelse
        return error.NativeBailedUnexpectedly };
    errdefer t.native.deinit();
    try state.cache.append(gpa, t);
    return t;
}

fn expectB3Patched(edge: PromotedEdge, promoted: bool) !void {
    const compiled = &edge.parent.native.compiled;
    const patch = TraceState.exitPatchFor(compiled, edge.exit).?;
    const bytes = compiled.page.code[patch.patch_off..][0..5];
    if (!promoted) {
        try testing.expectEqualSlices(u8, &patch.original, bytes);
        try testing.expectEqual(@as(usize, 0), compiled.metadata_cells[edge.exit]);
        return;
    }
    try testing.expectEqual(@as(u8, 0xE9), bytes[0]);
    const bits: u32 = @as(u32, bytes[1]) | (@as(u32, bytes[2]) << 8) |
        (@as(u32, bytes[3]) << 16) | (@as(u32, bytes[4]) << 24);
    const disp: i32 = @bitCast(bits);
    const target: usize = @intCast(@as(i128, @intCast(@intFromPtr(bytes.ptr) + 5)) + disp);
    try testing.expectEqual(@intFromPtr(compiled.page.code.ptr) + patch.epilogue_off, target);
    const cell = compiled.metadata_cells[edge.exit];
    try testing.expect(cell != 0);
    const metadata: *nativegen.SilentExitMetadata = @ptrFromInt(cell);
    try testing.expectEqual(&compiled.slots[edge.exit], metadata.slot);
}

fn b3ObservedRow(t: *Trace, exit: u32, kind: irinterp.LedgerKind) irinterp.LedgerEntry {
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
        const point = ProgramPoint{ .proto_id = t.anchor.proto.id, .source_pc = t.anchor.pc };
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
    try state.region_defs.put(gpa, key.region_id, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.dupe(ProgramPoint, scratch[0..n]),
        .owner = traces[0].anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = @intCast(traces.len) },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    try state.region_profit.put(gpa, key, .{
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
    const observed_a = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const observed_b = [_]irinterp.LedgerEntry{
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
    a.instrs[0].aux = 2;
    b.instrs[0].aux = 3;
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try testing.expect(try state.armNativeLink(b, 0, c, .link_terminal));
    try testing.expect(try state.armNativeLink(c, 0, a, .link_terminal));
    const region_key: RegionKey = .{ .region_id = @enumFromInt(1701), .activation = 33 };
    try installB3PromotionRegion(&state, region_key, &.{ a, b, c });
    const observed_three_a = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const observed_three_c = [_]irinterp.LedgerEntry{
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
    try state.armed_links.append(gpa, .{
        .parent = a,
        .slot_index = 1,
        .child = c,
        .kind = .ordinary_guard,
    });
    const multi_armed = state.detectPromotableSet(&observed_three_a, region_key).?;
    try testing.expectEqual(@as(usize, 3), multi_armed.len);
    gpa.free(multi_armed);
    _ = state.armed_links.pop();

    // Promotion belongs to one exact live frozen region. Shrinking the
    // region's footprint excludes a member edge from the candidate, so its
    // observed rows no longer match (open_chain); a missing/foreign region is
    // its own reject; an unfrozen accumulator still refuses publication.
    const def = state.region_defs.getPtr(region_key.region_id).?;
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
    state.region_profit.getPtr(region_key).?.frozen = false;
    try testing.expectError(error.InvalidPromotionRegion, state.promoteSet(three_a, region_key));
    state.region_profit.getPtr(region_key).?.frozen = true;
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
    const forward = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
    };
    const forward_edges = state.detectPromotableSet(&forward, key).?;
    try testing.expectEqual(@as(usize, 2), forward_edges.len);
    gpa.free(forward_edges);

    const closed = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    // An invalidated bridge kind fails `promotedEdgeFromLink`, dropping the
    // edge from the candidate — its observed rows no longer match any member.
    state.armed_links.items[0].kind = .region_bridge;
    try testing.expect(state.detectPromotableSet(&closed, key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.open_chain);
    state.armed_links.items[0].kind = .link_terminal;
    // Same exclusion when the parent has no patch table.
    const saved_patches = a.native.compiled.exit_patches;
    a.native.compiled.exit_patches = &.{};
    try testing.expect(state.detectPromotableSet(&closed, key) == null);
    try testing.expectEqual(@as(u64, 2), state.silent_rejects.open_chain);
    a.native.compiled.exit_patches = saved_patches;
    // A row whose observed patch kind disagrees with the armed edge's kind.
    const kind_mismatch = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .deopt),
        b3ObservedRow(b, 0, .link_terminal),
    };
    try testing.expect(state.detectPromotableSet(&kind_mismatch, key) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.no_patch_point);
    // Per-adjacent-pair child-match: row i's armed child must own row i+1.
    const pair_break = [_]irinterp.LedgerEntry{
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
    const one_row = [_]irinterp.LedgerEntry{b3ObservedRow(long[0], 0, .link_terminal)};
    try testing.expect(state.detectPromotableSet(&one_row, key_cap) == null);
    try testing.expectEqual(@as(u64, 1), state.silent_rejects.cap);
    try testing.expectEqual(@as(u64, 0), state.silent_rejects.bridge_member);
    try testing.expectEqual(@as(u64, 0), state.silent_rejects.region_mismatch);
}

test "B-3b.2 promotion publishes metadata and patches mixed deopt/NOP exits; demotion restores exact bytes" {
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
    const observed = [_]irinterp.LedgerEntry{
        b3ObservedRow(guard, 5, .deopt),
        b3ObservedRow(done, 5, .loop_done_linked),
        b3ObservedRow(link, 0, .link_terminal),
        b3ObservedRow(guard, 5, .deopt),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(2), .activation = 11 };
    try installB3PromotionRegion(&state, key, &.{ guard, done, link });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    try testing.expectEqual(@as(usize, 1), state.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, true);
    try testing.expectEqual(@as(u64, 1), state.silent_promotions);
    state.demoteAllSets();
    for (edges) |edge| try expectB3Patched(edge, false);
    try testing.expectEqual(@as(u64, 1), state.silent_demotions);
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
    try testing.expect(nativegen.isCompositeBridgeCandidate(bridge, 11));
    const patch = TraceState.exitPatchFor(&bridge.native.compiled, 11).?;
    try testing.expectEqual(nativegen.ExitPatchKind.region_bridge, patch.kind);
    try testing.expectEqualSlices(u8, &nativegen.EXIT_NOP5, &patch.original);

    const rid: RegionId = @enumFromInt(1714);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = bridge.anchor.pc,
            .exit = bridge.exit_prov[1].prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = succ.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = proto.id, .source_pc = bridge.anchor.pc },
            .{ .proto_id = proto.id, .source_pc = succ.anchor.pc },
        }),
        .owner = bridge.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    try testing.expect(try state.armNativeLink(bridge, 11, succ, .region_bridge));
    try testing.expect(try state.armNativeLink(succ, 0, bridge, .link_terminal));
    for (state.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = rid;
        link.armed_gen = state.region_defs_gen;
    };
    const observed = [_]irinterp.LedgerEntry{
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
    try testing.expectEqual(succ.anchor.pc, bridge_edge.?.resume_pc);
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
    try state.region_profit.put(gpa, key, initial);
    for (state.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = @enumFromInt(9999);
    };
    try testing.expect(!state.promotionBelongsToRegion(edges, key));
    for (state.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = rid;
    };
    try state.promoteSet(edges, key);
    try expectB3Patched(bridge_edge.?, true);

    // Reporting-mode oracle for one bridge firing followed by the structural
    // link back into the ring.
    state.region_context = .{ .depth = 1, .call_seq = key.activation };
    const reporting = [_]irinterp.LedgerEntry{
        .{ .cum = 3, .id = bridge.id, .exit = 11, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
        .{ .cum = 3, .id = succ.id, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
    };
    var reporting_completed: usize = 0;
    var reporting_resume: u32 = bridge.anchor.pc;
    var reporting_hops: usize = 0;
    _ = state.replayLedger(&reporting, bridge, succ.anchor.pc, &proto, &reporting_completed, &reporting_resume, &reporting_hops, 8, .continuation_call, true, null);
    const oracle_accum = state.region_profit.get(key).?;
    const oracle_bridge_hits = bridge.hit_count;
    const oracle_bridge_fused = state.native_region_bridge_fused;
    const oracle_link_exits = state.native_link_exits;

    state.region_profit.getPtr(key).?.* = initial;
    bridge.hit_count = 0;
    state.native_region_bridge_fused = 0;
    state.native_link_exits = 0;
    const set = &state.promoted_sets.items[0];
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
    const silent_accum = state.region_profit.get(key).?;
    try testing.expectEqual(oracle_bridge_hits, bridge.hit_count);
    try testing.expectEqual(oracle_bridge_fused, state.native_region_bridge_fused);
    try testing.expectEqual(oracle_link_exits, state.native_link_exits);
    try testing.expectEqual(oracle_accum.barren_run, silent_accum.barren_run);
    try testing.expectEqual(oracle_accum.outer_traversals, silent_accum.outer_traversals);

    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
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
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = bridge.anchor.pc,
            .exit = bridge.exit_prov[1].prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = child.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = proto.id, .source_pc = bridge.anchor.pc },
            .{ .proto_id = proto.id, .source_pc = child.anchor.pc },
        }),
        .owner = bridge.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(RegionBridgeDef, 0),
    });
    try testing.expect(try state.armNativeLink(bridge, 11, child, .region_bridge));
    try testing.expect(try state.armNativeLink(child, 7, bridge, .ordinary_guard));
    for (state.armed_links.items) |*link| if (link.kind == .region_bridge) {
        link.region_id = rid;
        link.armed_gen = state.region_defs_gen;
    };

    const key: RegionKey = .{ .region_id = rid, .activation = 101 };
    const initial = RegionAccum{
        .root_frame_depth = 1,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
        .useful_streak = state.config.freeze_windows,
        .frozen = true,
    };
    try state.region_profit.put(gpa, key, initial);
    state.region_context = .{ .depth = 1, .call_seq = key.activation };
    const observed = [_]irinterp.LedgerEntry{
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
    try testing.expectEqual(irinterp.LedgerKind.deopt, state.ledger_scratch[0].kind);
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
    try testing.expectEqual(child.anchor.pc, deopt_result.resume_pc);
    try testing.expectEqual(child.anchor.pc, resume_pc_value);
    try testing.expectEqual(@as(u32, 2), state.region_profit.get(key).?.barren_run);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(child.anchor));

    state.region_profit.getPtr(key).?.* = initial;
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
    try testing.expectEqual(irinterp.LedgerKind.prologue_fail, state.ledger_scratch[0].kind);
    completed = 0;
    resume_pc_value = 0;
    hops = 0;
    const prologue_dir = state.drainSilentResult(prologue, .continuation_call, &proto, &completed, &resume_pc_value, &hops, 8, true, null) orelse
        return error.TestUnexpectedResult;
    const prologue_result = switch (prologue_dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(child.anchor.pc, prologue_result.resume_pc);
    try testing.expectEqual(child.anchor.pc, resume_pc_value);
    try testing.expectEqual(@as(u32, 1), state.region_profit.get(key).?.barren_run);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(child.anchor));
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

    const observed = [_]irinterp.LedgerEntry{
        b3ObservedRow(source, 5, .deopt),
        b3ObservedRow(ramp, 6, .link_terminal),
        b3ObservedRow(source, 5, .deopt),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(1716), .activation = 102 };
    try installB3PromotionRegion(&state, key, &.{ source, ramp });
    const physical = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(physical);
    state.region_context = .{ .depth = 1, .call_seq = key.activation };
    const initial_accum = state.region_profit.get(key).?;

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
        source.anchor.pc,
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
    const oracle_deopt_penalty = state.penalty.get(ramp.anchor);
    const oracle_source_hits = source.hit_count;
    const oracle_deopt_accum = state.region_profit.get(key).?;

    state.penalty.clearRetainingCapacity();
    source.hit_count = 0;
    ramp.hit_count = 0;
    state.region_profit.getPtr(key).?.* = initial_accum;
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
    try testing.expectEqual(source.anchor.pc, silent_deopt_result.resume_pc);
    try testing.expectEqual(oracle_deopt_penalty, state.penalty.get(ramp.anchor));
    try testing.expectEqual(oracle_source_hits, source.hit_count);
    try expectRegionAccumEqual(oracle_deopt_accum, state.region_profit.get(key).?);

    // Repeat with a hoisted ramp entry failure. The source's silent M1 state
    // must still drive the zero-progress charge and source-anchor resume.
    state.penalty.clearRetainingCapacity();
    source.hit_count = 0;
    ramp.hit_count = 0;
    state.region_profit.getPtr(key).?.* = initial_accum;
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
        source.anchor.pc,
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
    const oracle_prologue_penalty = state.penalty.get(ramp.anchor);
    const oracle_prologue_hits = source.hit_count;
    const oracle_prologue_accum = state.region_profit.get(key).?;

    state.penalty.clearRetainingCapacity();
    source.hit_count = 0;
    ramp.hit_count = 0;
    state.region_profit.getPtr(key).?.* = initial_accum;
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
    try testing.expectEqual(source.anchor.pc, silent_prologue_result.resume_pc);
    try testing.expectEqual(oracle_prologue_penalty, state.penalty.get(ramp.anchor));
    try testing.expectEqual(oracle_prologue_hits, source.hit_count);
    try expectRegionAccumEqual(oracle_prologue_accum, state.region_profit.get(key).?);

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
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 1), state.silent_demotion_reasons.membership_growth);
    try state.promoteSet(physical, key);
    const set = &state.promoted_sets.items[0];
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
    const ramp_handoff_suffix = irinterp.ExecResult{
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
    const ramp_link_suffix = irinterp.ExecResult{
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
    const observed = [_]irinterp.LedgerEntry{
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
    try testing.expectEqual(@as(usize, 1), state.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, true);
    // A CHANGED relation (different child) still demotes via prepareSlotMutation.
    const c2 = try makeB3LinkTrace(gpa, &state, &proto, 3, 2, 1);
    try testing.expect(try state.armNativeLink(a, 0, c2, .link_terminal));
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
    for (edges) |edge| try expectB3Patched(edge, false);

    // Restore the ring relation (changed again: c2 -> b) for the closeRegion leg.
    try testing.expect(try state.armNativeLink(a, 0, b, .link_terminal));
    try state.promoteSet(edges, key);
    try state.region_profit.put(gpa, key, .{ .root_frame_depth = 1, .root_call_seq = key.activation });
    state.closeRegion(key);
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
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
    const observed = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const same: RegionKey = .{ .region_id = @enumFromInt(4), .activation = 20 };
    const other: RegionKey = .{ .region_id = @enumFromInt(5), .activation = 21 };
    try installB3PromotionRegion(&state, same, &.{ a, b });
    const edges = state.detectPromotableSet(&observed, same).?;
    defer gpa.free(edges);
    state.region_context = .{ .depth = 1, .call_seq = same.activation };
    try state.promoteSet(edges, same);
    state.prepareNativeEntry();
    try testing.expectEqual(@as(usize, 1), state.promoted_sets.items.len);
    _ = state.region_profit.remove(same);
    try state.region_profit.put(gpa, other, .{ .root_frame_depth = 1, .root_call_seq = other.activation });
    state.region_context = .{ .depth = 1, .call_seq = other.activation };
    state.prepareNativeEntry();
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
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
    const observed = [_]irinterp.LedgerEntry{
        b3ObservedRow(a, 0, .link_terminal),
        b3ObservedRow(b, 0, .link_terminal),
        b3ObservedRow(a, 0, .link_terminal),
    };
    const key: RegionKey = .{ .region_id = @enumFromInt(6), .activation = 30 };
    try installB3PromotionRegion(&state, key, &.{ a, b });
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try state.promoteSet(edges, key);
    state.replay_walk_depth = 1;
    state.demoteSetsTouching(a, 0);
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 1), state.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 1), state.pending_demote.items.len);
    try testing.expect(state.pending_disarm_all);
    state.replay_walk_depth = 0;
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
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
    const observed = [_]irinterp.LedgerEntry{
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
    try testing.expect(!state.region_profit.get(key).?.frozen);
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 1), state.silent_demotion_reasons.unfreeze);
    for (edges) |edge| try expectB3Patched(edge, false);

    // Mid-walk: the same verdict QUEUES the demotion; the walk applies it at
    // its exit, exactly like every other deferred demotion source.
    {
        const accum = state.region_profit.getPtr(key).?;
        accum.frozen = true;
        accum.useful_streak = state.config.freeze_windows;
    }
    try state.promoteSet(edges, key);
    state.replay_walk_depth = 1;
    state.flushRegionWindow(key, 1);
    try testing.expectEqual(@as(usize, 1), state.promoted_sets.items.len);
    try testing.expectEqual(@as(usize, 1), state.pending_demote.items.len);
    state.replay_walk_depth = 0;
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 2), state.silent_demotion_reasons.unfreeze);
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
        .{ .parent = p, .exit = 0, .kind = .deopt, .child = c, .arm_kind = .loop_done_linked, .resume_pc = c.anchor.pc },
        .{ .parent = p, .exit = 1, .kind = .deopt, .child = d, .arm_kind = .loop_done_linked, .resume_pc = d.anchor.pc },
        .{ .parent = c, .exit = 0, .kind = .deopt, .child = p, .arm_kind = .loop_done_linked, .resume_pc = p.anchor.pc },
        .{ .parent = d, .exit = 0, .kind = .deopt, .child = p, .arm_kind = .loop_done_linked, .resume_pc = p.anchor.pc },
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
    try testing.expectEqual(c.anchor.pc, set[terminal.?].resume_pc);
}

test "B-3b.3 promoted native cycle drains exact accounting and off-cycle suffix" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.min_useful = 1;
    state.config.silent_budget = irinterp.LEDGER_CAP;
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
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = proto.id, .source_pc = inner.anchor.pc },
            .{ .proto_id = proto.id, .source_pc = cont.anchor.pc },
        }),
        .owner = cont.anchor,
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
    try state.region_profit.put(gpa, key, initial_accum);
    state.region_context = .{ .depth = 1, .call_seq = key.activation };

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
    try testing.expectEqual(@as(usize, irinterp.LEDGER_CAP), ordinary.ledger_len);
    try testing.expectEqual(irinterp.LedgerOutcome.yielded, state.ledger_scratch[ordinary.ledger_len - 1].outcome);
    const evidence = state.ledger_scratch;
    var ordinary_completed: usize = 0;
    var ordinary_resume: u32 = cont.anchor.pc;
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
    const ordinary_accum = state.region_profit.get(key).?;
    const ordinary_cont_hits = cont.hit_count;
    const ordinary_inner_hits = inner.hit_count;
    const ordinary_link_exits = state.native_link_exits;
    const ordinary_link_follows = state.native_link_follow_count;
    const ordinary_all_follows = state.link_follow_count;
    const ordinary_loopdone_fused = state.native_loopdone_link_fused;
    const ordinary_flushes = state.region_profit_flushes;
    const ordinary_flushed_work = state.region_profit_flushed_work;

    // Reset only fields the oracle replay moved, then require two identical
    // successful detections before the production promotion gate publishes.
    state.region_profit.getPtr(key).?.* = initial_accum;
    cont.hit_count = 0;
    inner.hit_count = 0;
    state.native_link_exits = 0;
    state.native_link_follow_count = 0;
    state.link_follow_count = 0;
    state.native_loopdone_link_fused = 0;
    state.region_profit_flushes = 0;
    state.region_profit_flushed_work = 0;
    state.config.silent_promotion_enabled = true;
    _ = state.driveDispatcherLedger(cont, &evidence, &proto, regs, true);
    try testing.expectEqual(@as(usize, 0), state.promoted_sets.items.len);
    _ = state.driveDispatcherLedger(cont, &evidence, &proto, regs, true);
    try testing.expectEqual(@as(usize, 1), state.promoted_sets.items.len);
    try testing.expectEqual(@as(u64, 2), state.silent_promotion_candidates);

    // Detection replays are evidence, not part of the differential workload.
    // Reset the fields they moved before executing the promoted comparison span.
    state.region_profit.getPtr(key).?.* = initial_accum;
    cont.hit_count = 0;
    inner.hit_count = 0;
    state.native_link_exits = 0;
    state.native_link_follow_count = 0;
    state.link_follow_count = 0;
    state.native_loopdone_link_fused = 0;
    state.region_profit_flushes = 0;
    state.region_profit_flushed_work = 0;

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
    var silent_resume: u32 = cont.anchor.pc;
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
    const silent_accum = state.region_profit.get(key).?;
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
    try testing.expectEqual(ordinary_flushes, state.region_profit_flushes);
    try testing.expectEqual(ordinary_flushed_work, state.region_profit_flushed_work);

    // Synthetic off-cycle reporting suffix: one silent C.link transition enters
    // inner, then inner reports an ordinary guard with cumulative rbx advanced by
    // two. The suffix must subtract silent_cum=7 and account exactly local=2.
    const set = &state.promoted_sets.items[0];
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
    const suffix_result = irinterp.ExecResult{
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
    const loop_done_suffix = irinterp.ExecResult{
        .completed = 7,
        .exit_instr = 5,
        .final_trace_id = inner.id,
        .ledger_len = 1,
        .silent_active = 1,
        .silent_transitions = 1,
        .silent_budget = state.config.silent_budget,
        .barren_budget = state.config.max_barren_run,
        .silent_cell = @intFromPtr(&set.metadata[cont_phase]),
        .cur_zero_run = state.region_profit.get(key).?.barren_run,
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
    try testing.expectEqual(cont.anchor.pc, suffix_resume);
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
    state.region_context = .{ .depth = 1, .call_seq = key.activation };

    // Evidence touches only the P.e5/C edges; the P.e7 and D edges promote on
    // registry proof alone (§B3.18 R5(c): zero-evidence candidate edges are an
    // accepted trade — firing evidence arrives later via summary cells).
    const observed = [_]irinterp.LedgerEntry{
        b3ObservedRow(p, 5, .deopt),
        b3ObservedRow(c, 0, .link_terminal),
        b3ObservedRow(p, 5, .deopt),
    };
    const edges = state.detectPromotableSet(&observed, key).?;
    defer gpa.free(edges);
    try testing.expectEqual(@as(usize, 4), edges.len);
    try state.promoteSet(edges, key);
    const set = &state.promoted_sets.items[0];
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
    try testing.expectEqual(p.anchor.pc, result.resume_pc);
    try testing.expectEqual(@as(usize, 6), result.completed);
    try testing.expectEqual(@as(u64, 1), state.silent_budget_exhaustions);
    state.demoteAllSets();
}
