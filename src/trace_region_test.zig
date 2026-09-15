//! Tests for `trace.zig` — region.
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
const ExitProvenance = trace.ExitProvenance;
const GuardProvenance = trace.GuardProvenance;
const GuardRole = trace.GuardRole;
const InputSeed = trace.InputSeed;
const IrInstr = trace.IrInstr;
const ProgramPoint = trace.ProgramPoint;
const RegionId = trace.RegionId;
const RegionInternMap = trace.RegionInternMap;
const StructuralEdgeId = trace.StructuralEdgeId;
const Trace = trace.Trace;
const TraceState = trace.TraceState;

const util = @import("trace_testutil.zig");
const winRO = util.winRO;

test "A-ii.2 edge_cache: a 2-anchor cont↔inner cycle resolves both structural edges" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // traces are stack-allocated; drop pointers pre-deinit

    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 1 };

    // cont @pc2: a `.link` terminal (instrs[1], aux=7) to the inner root at pc7.
    var cont_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 9 }, .{ .op = .link, .aux = 7 } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 1, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &cont_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_prov,
        },
        .id = 301,
    };

    // inner root @pc7: loop-done guard_true (instrs[0], aux=2 == cont anchor), ends `.loop`.
    var inner_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var inner_prov = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .guard = .{ .source_proto_id = 0, .source_pc = 6, .role = .loop_done, .operand = .none } } }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_prov,
        },
        .id = 302,
    };

    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &inner);
    state.rebuildEdgeCache();

    // Both structural edges present: cont --link--> inner(pc7), inner --loop_done--> cont(pc2).
    try testing.expectEqual(@as(usize, 2), state.region_policy.edge_cache.count());
    const e_link = state.region_policy.edge_cache.get(.{ .trace_id = 301, .exit_instr = 1 }) orelse return error.MissingLinkEdge;
    try testing.expect(e_link.exit == .link_terminal);
    try testing.expectEqual(@as(u32, 2), e_link.anchor_pc);
    try testing.expectEqual(@as(u32, 7), e_link.succ_anchor_pc);
    const e_guard = state.region_policy.edge_cache.get(.{ .trace_id = 302, .exit_instr = 0 }) orelse return error.MissingGuardEdge;
    try testing.expect(e_guard.exit == .guard);
    try testing.expectEqual(@as(u32, 7), e_guard.anchor_pc);
    try testing.expectEqual(@as(u32, 2), e_guard.succ_anchor_pc);

    // Wholesale rebuild from the SURVIVING cache after inner leaves: cont's `.link` now
    // has no inner root bound, and inner's own edge is gone → empty. (Simulate the
    // retirement rebuild path without `destroy` on a stack trace.)
    _ = state.registry.cache.swapRemove(1); // drop &inner
    state.rebuildEdgeCache();
    try testing.expectEqual(@as(usize, 0), state.region_policy.edge_cache.count());
}

test "A-ii.2 canonicalEql/order: field-wise, ignores the dead path tail and the inactive arm" {
    // Two guard edges identical in every LIVE field but with different garbage in
    // path[inline_depth..] must be equal (field-wise, not raw bytes). And the exit-tag
    // orders guard (0) before link_terminal (1), giving a strict total order.
    var g_a: GuardProvenance = .{ .source_proto_id = 0, .source_pc = 6, .role = .loop_done, .operand = .none };
    var g_b: GuardProvenance = .{ .source_proto_id = 0, .source_pc = 6, .role = .loop_done, .operand = .none };
    g_a.path[0] = .{ .caller_proto_id = 111, .call_pc = 222 }; // dead (inline_depth == 0)
    g_b.path[0] = .{ .caller_proto_id = 333, .call_pc = 444 }; // different dead garbage
    const ea: StructuralEdgeId = .{ .anchor_proto_id = 0, .anchor_pc = 7, .exit = .{ .guard = g_a }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 2 };
    const eb: StructuralEdgeId = .{ .anchor_proto_id = 0, .anchor_pc = 7, .exit = .{ .guard = g_b }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 2 };
    try testing.expect(ea.eql(eb));
    try testing.expectEqual(ea.hash(), eb.hash());
    try testing.expect(ea.order(eb) == .eq);

    // A link-terminal edge at the same anchors sorts AFTER a guard edge (tag order),
    // and the order is antisymmetric.
    const el: StructuralEdgeId = .{ .anchor_proto_id = 0, .anchor_pc = 7, .exit = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 6, .inline_depth = 0 } }, .succ_anchor_proto_id = 0, .succ_anchor_pc = 2 };
    try testing.expect(ea.order(el) == .lt);
    try testing.expect(el.order(ea) == .gt);
    try testing.expect(!ea.eql(el));
}

test "A-ii.3 rec_path: recordInstr captures {proto_id, pc−1}; reset clears (re-record stable)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = 42, .name = "t", .num_registers = 2 };
    var regs = [_]Value{ Value.int(0), Value.int(0) };

    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    // Two safe guest ops (load_int: define a reg from an immediate, no guard, no abort)
    // recorded at post-increment pcs 3 and 4 → source_pc 2 and 3.
    state.recordInstr(Instr.opAx(.load_int, 0, 1), winRO(&regs), &proto, 3, Value.nil());
    state.recordInstr(Instr.opAx(.load_int, 1, 2), winRO(&regs), &proto, 4, Value.nil());
    try testing.expect(state.rec.rec_path_ok);
    try testing.expectEqual(@as(usize, 2), state.rec.rec_path.items.len);
    try testing.expectEqual(ProgramPoint{ .proto_id = 42, .source_pc = 2 }, state.rec.rec_path.items[0]);
    try testing.expectEqual(ProgramPoint{ .proto_id = 42, .source_pc = 3 }, state.rec.rec_path.items[1]);

    // Re-record stability: a fresh reset clears the path and re-arms availability.
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    try testing.expectEqual(@as(usize, 0), state.rec.rec_path.items.len);
    try testing.expect(state.rec.rec_path_ok);
}

test "A-ii.3 rec_path: a committed trace carries its recorded path (freed on destroy)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    var committed: ?*Trace = null;
    defer state.deinit();
    defer {
        if (committed) |ct| ct.destroy(gpa);
        state.registry.cache.clearRetainingCapacity();
    }

    // Same recForPrepLink→commit harness as the A-i.4 test: a continuation that
    // re-reaches an inner `for_prep` commits a `.link` trace. Its rec_path captures
    // the single recorded for_prep at source_pc 4 (post-increment pc 5 − 1).
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.load_nil);
    code[7] = Instr.opJ(.for_loop, -3);
    const proto = Proto{ .code = &code, .id = 9, .name = "t", .num_registers = 4 };
    const inner_instrs = [_]IrInstr{.{ .op = .loop }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 900,
    };
    try state.registry.cache.append(gpa, &inner);

    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 2 }, proto.num_registers);
    state.rec.kind = .continuation;
    var regs = [_]Value{ Value.int(1), Value.int(10), Value.int(1), Value.nil() };
    state.recordInstr(Instr.opAx(.for_prep, 0, 2), winRO(&regs), &proto, 5, Value.nil());

    try testing.expect(!state.isRecording());
    const t = state.registry.cache.items[state.registry.cache.items.len - 1];
    committed = t;
    try testing.expect(t.id != 900);
    try testing.expectEqual(@as(usize, 1), t.code.rec_path.len);
    try testing.expectEqual(ProgramPoint{ .proto_id = 9, .source_pc = 4 }, t.code.rec_path[0]);
}

// ---- A-ii.4 region discovery / interning / classification (inert) ----------
//
// Helpers build a synthetic trace graph over one proto with stack-allocated `Trace`s,
// then call `rebuildEdgeCache` + `rebuildRegions` directly (as the commit/retire path
// does) and assert on the discovered regions. `defer state.registry.cache.clearRetainingCapacity`
// drops the (stack) cache pointers before `deinit`, exactly as the A-ii.2 test does; the
// region maps own HEAP copies independent of the stack traces, so `deinit` frees them
// cleanly.

fn guardProv(source_pc: u32, role: GuardRole) ExitProvenance {
    return .{ .guard = .{ .source_proto_id = 0, .source_pc = source_pc, .role = role, .operand = .none } };
}

test "A-ii.4 discovery: skip→ramp→inner→cont→skip cycle — owner==skip@14 ∧ armable, one stable RegionId" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // The 4-node cycle. `skip@14` and `inner@7` end `.loop` (loop-root shape); `cont@20`
    // does not. `extern@30` supplies the incoming boundary edge into skip@14, so skip is
    // the UNIQUE external-entry ∧ loop-root anchor → owner.
    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &skip_p,
        },
        .id = 1,
    };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &ramp_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ramp_p,
        },
        .id = 2,
    };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_p,
        },
        .id = 3,
    };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 4,
    };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 5,
    };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // 5 structural edges (4 internal cycle + 1 incoming boundary), one discovered region.
    try testing.expectEqual(@as(usize, 5), state.region_policy.edge_cache.count());
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());

    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    const def = state.region_policy.region_defs.get(rid).?;
    // Owner predicate (round-13 load-bearing): skip@14, armable.
    try testing.expectEqual(@as(*const Proto, &proto), def.owner.proto);
    try testing.expectEqual(@as(u32, 14), def.owner.pc);
    try testing.expect(def.armable);
    try testing.expect(def.classifier.kind == .cross_trace_cycle);
    try testing.expectEqual(@as(u32, 4), def.classifier.member_count);
    try testing.expectEqual(@as(usize, 4), def.members.len); // 4 internal edges

    // Classification: a member's internal exit is credited to R; the non-member
    // external trace's exit is not (candidate SETS, not A-iv credit).
    const skip_regions = state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 });
    try testing.expectEqual(@as(usize, 1), skip_regions.len);
    try testing.expectEqual(rid, skip_regions[0]);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 5, .exit_instr = 0 }).len);
    // dest_entry: the four cycle members are entries; the external trace is not.
    try testing.expect(state.region_policy.dest_entry_regions.get(1) != null);
    try testing.expect(state.region_policy.dest_entry_regions.get(5) == null);
}

test "A-vii-d.0 armability recovery: first-sight unarmable arms on the rebind that brings the entry edge; tombstone is sticky" {
    // The reason no recorded shape ever armed (A-vii-d.0): the internal cycle is
    // what triggers minting, and its external-entry side trace records LATER (by
    // hotguard), so first sight is always owner-not-unique. Armability must
    // therefore be recomputed per rebind — frozen-at-first-sight can never rise
    // (measured on nsieve: both_count 0→0→1 across rebuilds). Only the tombstone
    // is sticky.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 8;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // The same 4-node cycle as the discovery pin above, but WITHOUT the external
    // trace: skip@14 is a loop-root yet nothing outside the component enters it.
    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &skip_p,
        },
        .id = 1,
    };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &ramp_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ramp_p,
        },
        .id = 2,
    };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_p,
        },
        .id = 3,
    };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 4,
    };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // (1) First sight: cycle discovered, but no external entry yet ⇒ NOT armable,
    // NOT tombstoned, and excluded from the physical indices.
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(!state.region_policy.region_defs.get(rid).?.armable);
    try testing.expect(!state.region_policy.region_defs.get(rid).?.tombstoned);
    try testing.expect(state.region_policy.dest_entry_regions.get(1) == null);

    // (2) The external-entry side trace records (the guard-hot side trace that in
    // real programs always arrives AFTER the cycle): the rebind re-interns the
    // SAME RegionId and armability recovers.
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 5,
    };
    try state.registry.cache.append(gpa, &ext);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count()); // same logical region
    try testing.expect(state.region_policy.region_defs.get(rid).?.armable);
    try testing.expect(!state.region_policy.region_defs.get(rid).?.tombstoned);
    try testing.expect(state.region_policy.dest_entry_regions.get(1) != null); // members indexed again

    // (3) A runtime tombstone is STICKY: the identical graph rebinding afterwards
    // must not re-arm (fail-closed for cause, per invalidateRegion).
    state.invalidateRegion(rid);
    try testing.expect(!state.region_policy.region_defs.get(rid).?.armable);
    try testing.expect(state.region_policy.region_defs.get(rid).?.tombstoned);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expect(!state.region_policy.region_defs.get(rid).?.armable);
    try testing.expect(state.region_policy.region_defs.get(rid).?.tombstoned);
    try testing.expect(state.region_policy.dest_entry_regions.get(1) == null);
}

test "A-ii.4 finding-3: a member with an incomplete recorded path mints the region NON-armable" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // Same owner-bearing 5-trace graph as the armable test above, but one physical member
    // (`skip`) carries a TRUNCATED recorded path (rec_path_complete=false, as a recorder-
    // path OOM or a commit-time dup OOM would leave it). The region must still be
    // discovered — its structural identity is unaffected — but must NOT be armable, and no
    // member exit may be classified (the def's member_points under-describe the footprint).
    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &skip_p,
            .rec_path_complete = false,
        },
        .id = 1,
    };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &ramp_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ramp_p,
        },
        .id = 2,
    };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_p,
        },
        .id = 3,
    };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 4,
    };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 5,
    };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // The region is still discovered (structural identity is unaffected by rec_path).
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const def = state.region_policy.region_defs.get(kit.next().?.*).?;
    // …but incomplete membership forces it CLOSED, and no member exit is classified.
    try testing.expect(!def.armable);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expect(state.region_policy.dest_entry_regions.get(1) == null);
    try testing.expectEqual(@as(u32, 0), state.region_policy.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.region_policy.dest_entry_regions.count());
}

test "A-ii.4 exit_prov fail-soft: an incomplete-exit_prov trace disarms the whole pass, logical defs retained, auto-recovers" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // The armable 5-trace graph again. Phase 1: fully complete → region armed. Phase 2:
    // taint the graph by marking one cached trace's `exit_prov` INCOMPLETE (as a
    // commit-time `buildExitProv` OOM would) — the whole discovery pass must arm nothing
    // (physical indices empty) yet RETAIN the logical def, and mint no new def. Phase 3:
    // clear the taint → the region re-arms (auto-recovery). We flip only the flag (leaving
    // `exit_prov` populated) to exercise the graph-completeness gate in isolation.
    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &skip_p,
        },
        .id = 1,
    };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &ramp_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ramp_p,
        },
        .id = 2,
    };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_p,
        },
        .id = 3,
    };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 4,
    };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 5,
    };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.registry.cache.append(gpa, t);

    // Phase 1 — complete graph: region armed.
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_policy.region_defs.get(rid).?.armable);
    try testing.expectEqual(@as(usize, 1), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);

    // Phase 2 — taint one trace's exit_prov: the pass arms NOTHING, but keeps the def.
    ext.code.exit_prov_complete = false;
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count()); // logical retained
    try testing.expect(state.region_policy.region_defs.get(rid).?.armable); // logical bit intrinsic, untouched
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expectEqual(@as(u32, 0), state.region_policy.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.region_policy.dest_entry_regions.count());

    // Phase 3 — clear the taint: the region re-arms (same id), physical indices repopulate.
    ext.code.exit_prov_complete = true;
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit3 = state.region_policy.region_defs.keyIterator();
    try testing.expectEqual(rid, kit3.next().?.*);
    const regs = state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 });
    try testing.expectEqual(@as(usize, 1), regs.len);
    try testing.expectEqual(rid, regs[0]);
}

test "A-ii.4 finding-5: a boundary edge added on rebind flips both_count 1→2, re-gating armable off (same id)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // Phase 1: the armable skip→ramp→inner→cont→skip cycle with ONE incoming boundary
    // (ext→skip@14) → skip is the unique external-entry ∧ loop-root → both_count==1, armed.
    // Phase 2: add a SECOND incoming boundary (ext2→inner@7) — inner@7 also ends `.loop`,
    // so it too becomes external-entry ∧ loop-root → both_count==2. The INTERNAL edge set
    // is unchanged, so the region re-interns to the SAME id, but the current owner analysis
    // (`cand.armable_owner`) is now false, so the rebind must DISARM it despite the stored
    // armable bit (finding 5). The owner is refreshed to the deterministic placeholder.
    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &skip_p,
        },
        .id = 1,
    };

    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &ramp_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ramp_p,
        },
        .id = 2,
    };

    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_p,
        },
        .id = 3,
    };

    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 4,
    };

    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 5,
    };

    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_policy.region_defs.get(rid).?.armable);
    try testing.expectEqual(@as(u32, 14), state.region_policy.region_defs.get(rid).?.owner.pc); // owner=skip@14
    try testing.expectEqual(@as(usize, 1), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);

    // Phase 2: add ext2 → inner@7 (a second external-entry into a loop-root). both_count→2.
    var ext2_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }};
    var ext2_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(39, .branch_cond) }};
    var ext2: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 40 },
            .instrs = &ext2_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext2_p,
        },
        .id = 6,
    };
    try state.registry.cache.append(gpa, &ext2);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // SAME region id (internal edge set unchanged), but disarmed by the current owner
    // analysis, and no member exit is classified. The stored owner is refreshed away from
    // skip@14 to the deterministic placeholder (canonically-smallest anchor of the SCC).
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit2 = state.region_policy.region_defs.keyIterator();
    try testing.expectEqual(rid, kit2.next().?.*);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expectEqual(@as(u32, 0), state.region_policy.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.region_policy.dest_entry_regions.count());
    try testing.expectEqual(@as(u32, 2), state.region_policy.region_defs.get(rid).?.owner.pc); // placeholder = smallest anchor (ramp@2)
}

test "A-ii.4 finding-6: a region-rebuild OOM fails CLOSED — physical indices emptied, logical defs retained" {
    // A `FailingAllocator` forces `rebuildRegionsFallible` to OOM on a SECOND pass after a
    // good first pass armed a region. The disposition must NOT retain the prior physical
    // snapshot (which a graph-changing commit could have made stale) — it fails CLOSED to
    // EMPTY physical indices, while the LOGICAL defs (untouched by the aborted pass) survive.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = fa.allocator();
    var state = TraceState.init(gpa);
    defer {
        fa.fail_index = std.math.maxInt(usize); // let teardown allocate freely
        state.deinit();
    }
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    var skip_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var skip_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(13, .loop_done) }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &skip_p,
        },
        .id = 1,
    };
    var ramp_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var ramp_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = 0, .source_pc = 1, .inline_depth = 0 } } }};
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &ramp_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ramp_p,
        },
        .id = 2,
    };
    var inner_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var inner_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &inner_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &inner_p,
        },
        .id = 3,
    };
    var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .branch_cond) }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 4,
    };
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 5,
    };
    for ([_]*Trace{ &skip, &ramp, &inner, &cont, &ext }) |t| try state.registry.cache.append(gpa, t);

    // Phase 1 — good pass: region armed, physical indices populated.
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_policy.source_exit_regions.count() > 0);
    try testing.expect(state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len == 1);

    // Phase 2 — arm the allocator to fail the NEXT allocation, then re-discover regions over
    // the (still-valid, phase-1) edge cache. The region rebuild OOMs on its first scratch
    // alloc → fail-closed. (We call ONLY rebuildRegions so the failure is in the region pass,
    // not the edge-cache pass.)
    fa.fail_index = fa.alloc_index; // next alloc returns error.OutOfMemory
    state.rebuildRegions();

    // Physical indices emptied (fail-closed), logical defs retained (untouched).
    try testing.expectEqual(@as(u32, 0), state.region_policy.source_exit_regions.count());
    try testing.expectEqual(@as(u32, 0), state.region_policy.dest_entry_regions.count());
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len);
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit2 = state.region_policy.region_defs.keyIterator();
    try testing.expectEqual(rid, kit2.next().?.*);
}

test "A-ii.4 re-record stability: the same guest-logical graph (new Trace.ids) re-interns to the SAME RegionId" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // A minimal non-armable 2-node cycle A@2 ↔ B@7. Build it twice with DIFFERENT
    // Trace.ids and assert the interned RegionId is unchanged (identity is guest-logical:
    // StructuralEdgeId keys on proto_id/pc/provenance, never Trace.id).
    const buildCycle = struct {
        fn go(st: *TraceState, g: std.mem.Allocator, p: *const Proto, id_a: u32, id_b: u32) !void {
            const a_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }});
            const a_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }});
            const a = try g.create(Trace);
            a.* = .{
                .code = .{
                    .anchor = .{ .proto = p, .pc = 2 },
                    .instrs = a_i,
                    .consts = try g.alloc(Value, 0),
                    .entry_slots = try g.alloc(u16, 0),
                    .entry_guards = try g.alloc(EntryGuard, 0),
                    .exit_prov = a_p,
                },
                .id = id_a,
            };
            const b_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
            const b_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }});
            const b = try g.create(Trace);
            b.* = .{
                .code = .{
                    .anchor = .{ .proto = p, .pc = 7 },
                    .instrs = b_i,
                    .consts = try g.alloc(Value, 0),
                    .entry_slots = try g.alloc(u16, 0),
                    .entry_guards = try g.alloc(EntryGuard, 0),
                    .exit_prov = b_p,
                },
                .id = id_b,
            };
            try st.registry.cache.append(g, a);
            try st.registry.cache.append(g, b);
        }
    }.go;

    try buildCycle(&state, gpa, &proto, 1, 2);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid1 = kit.next().?.*;

    // Retire both (heap traces → real destroy), then re-record with fresh ids.
    while (state.registry.cache.items.len > 0) state.removeTrace(state.registry.cache.items[0]);
    try buildCycle(&state, gpa, &proto, 11, 12);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    // Still ONE region, and the SAME id (not a second def).
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    try testing.expect(state.region_policy.region_defs.get(rid1) != null);

    while (state.registry.cache.items.len > 0) state.removeTrace(state.registry.cache.items[0]);
}

/// B-iv.3: inert seed twin for the seeded-child bridge fixture below —
/// `stubEnterable` never calls it (freshness is ctx-stamp comparison only),
/// but `NativeSeedCtx.seed_fn` has no default.
fn regionBridgeDummySeed(
    ctx: *const trace.NativeSeedCtx,
    t: *const trace.TraceCode,
    plan_bits: u64,
) callconv(.c) u64 {
    _ = ctx;
    _ = t;
    _ = plan_bits;
    return trace.NativeSeedCtx.SEED_OK;
}

test "A-vii-b discovered bridge descriptor validates inertly and rejects incomplete proofs or seeded children (B-iv.3: transiently, no tombstone)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    var code: [41]Instr = undefined;
    for (&code) |*ins| ins.* = Instr.op0(.ret);
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    code[28] = Instr.opAx(.jmp_if_true, 0, 0);
    code[39] = Instr.opAx(.jmp_if_true, 0, 0);
    const proto = Proto{ .code = &code, .id = 77, .name = "a-vii-b", .num_registers = 4 };

    // cont@29 --composite--> skip@14 --ordinary--> cont@29.  skip's direct
    // entry set is {r0,r1}; cont additionally needs r2, so the cycle fixed point
    // makes the bridge descriptor S={r0,r1,r2}. E={r0}, invariants={r1,r2}.
    var cont_i = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .slot_load, .aux = 2 },
        .{ .op = .guard_true, .a = 0, .aux = 14 },
        .{ .op = .phi, .b = 0, .aux = 0 },
        .{ .op = .loop },
    };
    var cont_p = [_]ExitProvEntry{.{ .index = 3, .prov = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 13,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } } }};
    const parent_slots = try gpa.alloc(usize, cont_i.len);
    defer gpa.free(parent_slots);
    @memset(parent_slots, 0); // no trampoline in this unit test: shared_exit == 0
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 29 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = @constCast(&[_]u16{2}),
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 1,
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };

    var skip_i = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_true, .a = 0, .aux = 29 },
        .{ .op = .loop },
    };
    var skip_p = [_]ExitProvEntry{.{ .index = 2, .prov = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 28,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } } }};
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 14 },
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = @constCast(&[_]u16{ 0, 1 }),
            .entry_guards = &.{},
            .exit_prov = &skip_p,
        },
        .id = 2,
        .hit_count = 9,
    };
    // Same-anchor decoy has a higher hit count but is not a physical region member.
    var sibling: Trace = .{
        .code = .{
            .anchor = skip.code.anchor,
            .instrs = &skip_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 3,
        .hit_count = 100,
    };
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 14 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 39,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } } }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 40 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 4,
    };
    for ([_]*Trace{ &cont, &skip, &sibling, &ext }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var ids = state.region_policy.region_defs.keyIterator();
    const rid = ids.next().?.*;
    var def = state.region_policy.region_defs.getPtr(rid).?;
    try testing.expect(def.armable);
    try testing.expectEqual(@as(usize, 1), def.bridges.len);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, def.bridges[0].required_slots);
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, def.bridges[0].invariant_slots);

    const decision = switch (state.validateRegionBridge(rid, &cont, 3)) {
        .ok => |d| d,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(decision.child == &skip); // member filter defeats higher-hit sibling
    try testing.expect(def.armable);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[3]);

    // Re-discovery with fresh physical ids must replace, not retain, descriptor
    // storage. Corrupt the old proof first; the rebuilt same logical RegionId restores it.
    def.bridges[0].invariant_slots[1] = 99;
    cont.id = 11;
    skip.id = 12;
    sibling.id = 13;
    ext.id = 14;
    state.rebuildEdgeCache();
    state.rebuildRegions();
    def = state.region_policy.region_defs.getPtr(rid).?;
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, def.bridges[0].invariant_slots);
    try testing.expect(state.region_policy.dest_entry_regions.get(skip.id) != null);

    // Rejection A: S still contains live-through r2, but neither E nor the
    // (deliberately damaged) invariant proof contains it.
    def.bridges[0].invariant_slots[1] = 99;
    // Structural disproof: tombstones the region, distinct from the transient
    // decline exercised below (the verdict now says which happened).
    try testing.expect(state.validateRegionBridge(rid, &cont, 3) == .invalidated);
    try testing.expect(!def.armable);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[3]);

    // B-iv.3 (doc 22 §B.5) replaces the old "Rejection B" (seeded child ⇒
    // structural disproof ⇒ tombstone). A seeded child is now bridgeable when
    // its page is stub-enterable; a NOT-enterable one declines TRANSIENTLY —
    // null decision, no arm, and the region stays ARMABLE (its compile may be
    // pending / the episode ctx stale; a later probe under a fresh episode may
    // succeed, unlike the S/E disproof above which is a property of the proof).
    def.armable = true;
    def.bridges[0].invariant_slots[1] = 2;
    skip.code.inputs = @constCast(&[_]InputSeed{undefined});
    try testing.expect(state.validateRegionBridge(rid, &cont, 3) == .child_not_enterable);
    try testing.expect(def.armable); // transient decline — NOT invalidated
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[3]);

    // The decline is TRANSIENT but DURABLE-for-this-activation, and those are
    // not the same thing. Transient means "don't tombstone"; durable means
    // "don't re-run the pipeline until something that could change the answer
    // changes". Only the first was implemented: the caller memoized the
    // already-ARMED case alone, so a bridge child that is never dispatcher-
    // selected — and a bridge child frequently isn't, that non-selection being
    // the whole reason the bridge exists — re-ran `classifyExit` + the def and
    // profit probes + the structural proof on EVERY terminal composite deopt,
    // forever. `validateRegionBridge` alone measured 2.4% of nsieve N=5.
    //
    // Drive it through `drainPendingBridgeArm`, the production entry point, so
    // the memo is observed where it actually has to hold.
    state.config.min_useful = 3;
    const akey: trace.RegionKey = .{ .region_id = rid, .activation = 7 };
    try state.region_policy.region_profit.put(gpa, akey, .{
        .root_frame_depth = 0,
        .root_call_seq = akey.activation,
        .useful_window_seen = true, // past the profitability gate
    });
    state.region_policy.region_context = .{ .depth = 0, .call_seq = akey.activation };
    try testing.expect(cont.code.isBridgeCandidate(3));

    state.pending_bridge_arm = .{ .trace_id = cont.id, .exit_instr = 3 };
    state.drainPendingBridgeArm(true);
    try testing.expectEqual(@as(u64, 1), state.native_region_bridge_arm_attempts);
    // Nothing armed, nothing tombstoned — the decline itself is unchanged.
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expect(def.armable);

    // Second identical deopt: the memo must absorb it. Pre-fix this was 2.
    state.pending_bridge_arm = .{ .trace_id = cont.id, .exit_instr = 3 };
    state.drainPendingBridgeArm(true);
    try testing.expectEqual(@as(u64, 1), state.native_region_bridge_arm_attempts);

    // ...but the memo must not WEDGE the arm. Each of the two facts it is keyed
    // on re-opens it independently. (a) a discovery rebuild — the bridges or
    // membership it was proven against may have changed:
    state.region_policy.region_defs_gen +%= 1;
    state.pending_bridge_arm = .{ .trace_id = cont.id, .exit_instr = 3 };
    state.drainPendingBridgeArm(true);
    try testing.expectEqual(@as(u64, 2), state.native_region_bridge_arm_attempts);

    // (b) a new activation — which is what a stale episode ctx needs in order
    // to become fresh, and also the natural bound on a child whose
    // `.unattempted → .compiled` transition bumps no generation at all.
    const akey2: trace.RegionKey = .{ .region_id = rid, .activation = 8 };
    try state.region_policy.region_profit.put(gpa, akey2, .{
        .root_frame_depth = 0,
        .root_call_seq = akey2.activation,
        .useful_window_seen = true,
    });
    _ = state.region_policy.region_profit.remove(akey);
    state.region_policy.region_context = .{ .depth = 0, .call_seq = akey2.activation };
    state.pending_bridge_arm = .{ .trace_id = cont.id, .exit_instr = 3 };
    state.drainPendingBridgeArm(true);
    try testing.expectEqual(@as(u64, 3), state.native_region_bridge_arm_attempts);

    // ...and the positive flip: give the seeded child a stub-enterable page
    // (compiled ordinary entry, §B.4 plan⟺prologue agreeing) under a FRESH
    // episode ctx (ctx.proto == frame proto == anchor proto, call_seq tokens
    // agreeing) — the same bridge decision now validates.
    skip.native = .{ .compiled = .{
        .page = undefined,
        .gpa = gpa,
        .ordinary_entry = 0xCAFE,
        .seed_plan = .{ .bits = 1 },
        .seed_prologue = true,
    } };
    const seed_ctx = try gpa.create(trace.NativeSeedCtx);
    seed_ctx.* = .{ .seed_fn = regionBridgeDummySeed };
    state.registry.native_seed_ctx = seed_ctx; // state.deinit() destroys it
    seed_ctx.proto = @ptrCast(&proto);
    seed_ctx.call_seq = 7;
    state.region_policy.region_context = .{ .depth = 0, .call_seq = 7 };
    const seeded_decision = switch (state.validateRegionBridge(rid, &cont, 3)) {
        .ok => |d| d,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(seeded_decision.child == &skip);
    try testing.expect(def.armable);
}

test "A-ii.4 intern identity is the edge SET (distinct sets → distinct ids; identical set → same id)" {
    // White-box on RegionInternMap: identity is the element-wise-compared sorted set, not
    // object bytes and not merely the 64-bit fold. (A genuine Wyhash fold collision is
    // unforgeable, so the set-equality guard is validated by distinct-set / same-set
    // behaviour: a different set never aliases an existing id, an identical one always does.)
    const gpa = testing.allocator;
    var m: RegionInternMap = .empty;
    defer m.deinit(gpa);

    const setA = [_]StructuralEdgeId{.{ .anchor_proto_id = 0, .anchor_pc = 2, .exit = guardProv(1, .branch_cond), .succ_anchor_proto_id = 0, .succ_anchor_pc = 7 }};
    const setB = [_]StructuralEdgeId{.{ .anchor_proto_id = 0, .anchor_pc = 2, .exit = guardProv(1, .branch_cond), .succ_anchor_proto_id = 0, .succ_anchor_pc = 9 }}; // different succ pc

    try testing.expect(m.lookup(&setA) == null);
    try m.reserve(gpa, 2);
    m.internAssumeCapacity(try gpa.dupe(StructuralEdgeId, &setA), @enumFromInt(100));
    m.internAssumeCapacity(try gpa.dupe(StructuralEdgeId, &setB), @enumFromInt(200));

    try testing.expectEqual(@as(RegionId, @enumFromInt(100)), m.lookup(&setA).?);
    try testing.expectEqual(@as(RegionId, @enumFromInt(200)), m.lookup(&setB).?);
    // A re-presented identical set (fresh slice, same contents) resolves to its id.
    const setA2 = [_]StructuralEdgeId{setA[0]};
    try testing.expectEqual(@as(RegionId, @enumFromInt(100)), m.lookup(&setA2).?);
}

test "A-ii.4 sibling boundary edge: only the physical MEMBER's exits are credited to R" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // Cycle A@2 ↔ B@7 made armable by an external entry X@40→A@2 with A loop-root. A
    // SIBLING A'@2 realizes only a boundary edge A→C@30 (C outside the cycle) — it shares
    // A's anchor but realizes NO internal edge, so it is NOT a physical member.
    var a_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 7 }, .{ .op = .loop } };
    var a_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .loop_done) }};
    var ta: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &a_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &a_p,
        },
        .id = 1,
    };

    var b_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }};
    var b_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }};
    var tb: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &b_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &b_p,
        },
        .id = 2,
    };

    var as_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 30 }}; // sibling at @2 → C@30
    var as_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }};
    var tas: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &as_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &as_p,
        },
        .id = 3,
    };

    var c_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 99 }}; // C@30 resolves to nothing
    var c_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var tc: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &c_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &c_p,
        },
        .id = 4,
    };

    var x_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }}; // X@40 → A@2 (incoming boundary)
    var x_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(39, .branch_cond) }};
    var tx: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 40 },
            .instrs = &x_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &x_p,
        },
        .id = 5,
    };

    for ([_]*Trace{ &ta, &tb, &tas, &tc, &tx }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    const def = state.region_policy.region_defs.get(rid).?;
    try testing.expectEqual(@as(u32, 2), def.owner.pc); // A@2 is external-entry ∧ loop-root
    try testing.expect(def.armable);

    // Member A's internal exit → R; the SIBLING A''s boundary exit at the same anchor → ∅.
    try testing.expectEqual(rid, state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 })[0]);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 3, .exit_instr = 0 }).len);
    // dest_entry: members {A=1, B=2} only — never the sibling A'(3) or the outside X(5)/C(4).
    try testing.expect(state.region_policy.dest_entry_regions.get(1) != null);
    try testing.expect(state.region_policy.dest_entry_regions.get(2) != null);
    try testing.expect(state.region_policy.dest_entry_regions.get(3) == null);
    try testing.expect(state.region_policy.dest_entry_regions.get(5) == null);
}

test "A-ii.4 rebind tombstone: same edge set, incompatible member_points → armable flips false, purged from physical" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // An armable 2-node cycle A@2 ↔ B@7 (X@40→A external entry, A loop-root), where A
    // carries a recorded-path point. Re-record with the SAME edge set but a DIFFERENT
    // A.rec_path → member_points mismatch → def-consistency tombstone.
    const buildArmable = struct {
        fn go(st: *TraceState, g: std.mem.Allocator, p: *const Proto, ids: [3]u32, a_pt: ProgramPoint) !void {
            const a_i = try g.dupe(IrInstr, &[_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 7 }, .{ .op = .loop } });
            const a_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .loop_done) }});
            const a_path = try g.dupe(ProgramPoint, &[_]ProgramPoint{a_pt});
            const a = try g.create(Trace);
            a.* = .{
                .code = .{
                    .anchor = .{ .proto = p, .pc = 2 },
                    .instrs = a_i,
                    .consts = try g.alloc(Value, 0),
                    .entry_slots = try g.alloc(u16, 0),
                    .entry_guards = try g.alloc(EntryGuard, 0),
                    .exit_prov = a_p,
                    .rec_path = a_path,
                },
                .id = ids[0],
            };
            const b_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
            const b_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }});
            const b = try g.create(Trace);
            b.* = .{
                .code = .{
                    .anchor = .{ .proto = p, .pc = 7 },
                    .instrs = b_i,
                    .consts = try g.alloc(Value, 0),
                    .entry_slots = try g.alloc(u16, 0),
                    .entry_guards = try g.alloc(EntryGuard, 0),
                    .exit_prov = b_p,
                },
                .id = ids[1],
            };
            const x_i = try g.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
            const x_p = try g.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(39, .branch_cond) }});
            const x = try g.create(Trace);
            x.* = .{
                .code = .{
                    .anchor = .{ .proto = p, .pc = 40 },
                    .instrs = x_i,
                    .consts = try g.alloc(Value, 0),
                    .entry_slots = try g.alloc(u16, 0),
                    .entry_guards = try g.alloc(EntryGuard, 0),
                    .exit_prov = x_p,
                },
                .id = ids[2],
            };
            for ([_]*Trace{ a, b, x }) |t| try st.registry.cache.append(g, t);
        }
    }.go;

    try buildArmable(&state, gpa, &proto, .{ 1, 2, 3 }, .{ .proto_id = P_ID, .source_pc = 100 });
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    try testing.expect(state.region_policy.region_defs.get(rid).?.armable);
    try testing.expect(state.classifyExit(.{ .trace_id = 1, .exit_instr = 0 }).len == 1); // published

    // Re-record with a DIFFERENT A.rec_path (source_pc 200) → incompatible membership.
    while (state.registry.cache.items.len > 0) state.removeTrace(state.registry.cache.items[0]);
    try buildArmable(&state, gpa, &proto, .{ 11, 12, 13 }, .{ .proto_id = P_ID, .source_pc = 200 });
    state.rebuildEdgeCache();
    state.rebuildRegions();
    // Same id (edge set unchanged), but tombstoned + purged from the physical index.
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    try testing.expect(!state.region_policy.region_defs.get(rid).?.armable);
    try testing.expectEqual(@as(usize, 0), state.classifyExit(.{ .trace_id = 11, .exit_instr = 0 }).len);

    while (state.registry.cache.items.len > 0) state.removeTrace(state.registry.cache.items[0]);
}

test "A-ii.4 lifetime: removeTrace preserves region_defs (logical); clearCache empties it" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const P_ID: u32 = 7;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // A plain (non-armable) 2-node cycle on HEAP traces so removeTrace/clearCache can
    // `destroy` them. region_defs still gets one entry (first-sight always defines).
    const a_i = try gpa.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }});
    const a = try gpa.create(Trace);
    a.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = a_i,
            .consts = try gpa.alloc(Value, 0),
            .entry_slots = try gpa.alloc(u16, 0),
            .entry_guards = try gpa.alloc(EntryGuard, 0),
            .exit_prov = try gpa.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }}),
        },
        .id = 1,
    };
    const b_i = try gpa.dupe(IrInstr, &[_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }});
    const b = try gpa.create(Trace);
    b.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = b_i,
            .consts = try gpa.alloc(Value, 0),
            .entry_slots = try gpa.alloc(u16, 0),
            .entry_guards = try gpa.alloc(EntryGuard, 0),
            .exit_prov = try gpa.dupe(ExitProvEntry, &[_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .branch_cond) }}),
        },
        .id = 2,
    };
    try state.registry.cache.append(gpa, a);
    try state.registry.cache.append(gpa, b);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());

    // removeTrace breaks the cycle but must NOT clean region_defs (logical persistence).
    state.removeTrace(b);
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    // The physical index rebuilt from the surviving graph (cycle gone) → empty.
    try testing.expectEqual(@as(usize, 0), state.region_policy.source_exit_regions.count());

    // clearCache is the ONE place the logical maps are cleared.
    state.clearCache();
    try testing.expectEqual(@as(usize, 0), state.region_policy.region_defs.count());
    try testing.expectEqual(@as(usize, 0), state.region_policy.region_intern.entries.items.len);
}

// ---- doc 47 Increment B: closed-SCC owner election (fallback tier) ----------
//
// A fully-closed cycle (dispatcher-entered — no incoming boundary edge) elects
// the unique loop-root DESTINATION of an internal top-level same-proto
// `.link_terminal` edge from a non-root member. Zero or several qualifying
// roots keep the deterministic placeholder + armable=false. These fixtures use
// CORRECT link provenance (`source_proto_id == proto.id`); the older fixtures
// above carry `source_proto_id = 0` against a nonzero proto id, which the
// same-proto scope check rejects — pinned explicitly in the negative test.

test "inc-B closed SCC: link-fed root elected + armable; boundary edge hands election to the primary tier; removal returns to the fallback (same RegionId)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 21;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // root@7 (loop shape) --loop_done--> cont@2 --link--> root@7. Closed 2-node SCC.
    var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var root: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = &root_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &root_p,
        },
        .id = 1,
    };
    var cont_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 1, .inline_depth = 0 } } }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &cont_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_p,
        },
        .id = 2,
    };
    for ([_]*Trace{ &root, &cont }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();

    // (1) First sight: the fallback elects the link-fed root — armable at once
    // (the sparse shape: primary tier yields both_count==0, `enclosing` cannot
    // span the post-loop continuation).
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expect(def.classifier.kind == .cross_trace_cycle);
        try testing.expectEqual(@as(u32, 2), def.classifier.member_count);
        try testing.expectEqual(@as(*const Proto, &proto), def.owner.proto);
        try testing.expectEqual(@as(u32, 7), def.owner.pc);
    }

    // (2) An external-entry side trace arrives (boundary edge INTO the root):
    // the primary tier now elects — same RegionId (internal edge set is the
    // identity; the boundary edge is not internal), same owner, still armable.
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 30 },
            .instrs = &ext_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &ext_p,
        },
        .id = 3,
    };
    try state.registry.cache.append(gpa, &ext);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expectEqual(@as(u32, 7), def.owner.pc);
    }

    // (3) The boundary edge retires again (codex rebind nuance): the region
    // stays armable through the fallback — owner/armability are recomputed per
    // rebuild and the closed-SCC proof still holds. Same RegionId throughout.
    _ = state.registry.cache.swapRemove(2); // drop &ext
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expectEqual(@as(u32, 7), def.owner.pc);
        try testing.expect(!def.tombstoned);
    }
}

test "inc-B negatives: guard-fed root, foreign-proto link, and inlined link all stay unarmable" {
    const gpa = testing.allocator;

    const P_ID: u32 = 22;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // (a) The cont enters the root through a BRANCH GUARD, not `.link` — the
    // qualification demands `.link_terminal` structural provenance (codex
    // tightening: "source has no root" alone also matches ordinary side
    // anchors), so nothing qualifies.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        defer state.registry.cache.clearRetainingCapacity();
        var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
        var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
        var root: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
            .id = 1,
        };
        var cont_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }};
        var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(1, .branch_cond) }};
        var cont: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p },
            .id = 2,
        };
        for ([_]*Trace{ &root, &cont }) |t| try state.registry.cache.append(gpa, t);
        state.rebuildEdgeCache();
        state.rebuildRegions();
        try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
        var kit = state.region_policy.region_defs.keyIterator();
        try testing.expect(!state.region_policy.region_defs.get(kit.next().?.*).?.armable);
    }

    // (b) Foreign-proto link provenance (`source_proto_id != proto.id`) — an
    // inlined/cross-proto `.link` may not nominate under the v1 same-proto
    // scope. This is also the shape the pre-inc-B fixtures above carry
    // (source_proto_id=0 vs a nonzero proto id), pinned here deliberately.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        defer state.registry.cache.clearRetainingCapacity();
        var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
        var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
        var root: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
            .id = 1,
        };
        var cont_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
        var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID + 1, .source_pc = 1, .inline_depth = 0 } } }};
        var cont: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p },
            .id = 2,
        };
        for ([_]*Trace{ &root, &cont }) |t| try state.registry.cache.append(gpa, t);
        state.rebuildEdgeCache();
        state.rebuildRegions();
        try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
        var kit = state.region_policy.region_defs.keyIterator();
        try testing.expect(!state.region_policy.region_defs.get(kit.next().?.*).?.armable);
    }

    // (c) Inlined link provenance (`inline_depth != 0`) may not nominate.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        defer state.registry.cache.clearRetainingCapacity();
        var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
        var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
        var root: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
            .id = 1,
        };
        var cont_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
        var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 1, .inline_depth = 1 } } }};
        var cont: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p },
            .id = 2,
        };
        for ([_]*Trace{ &root, &cont }) |t| try state.registry.cache.append(gpa, t);
        state.rebuildEdgeCache();
        state.rebuildRegions();
        try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
        var kit = state.region_policy.region_defs.keyIterator();
        try testing.expect(!state.region_policy.region_defs.get(kit.next().?.*).?.armable);
    }
}

test "inc-B ambiguity + node-counting: two link-fed roots stay unarmable; two links into ONE root elect exactly once" {
    const gpa = testing.allocator;

    const P_ID: u32 = 23;
    var code: [40]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // (a) rootA@7 --loop_done--> contA@10 --link--> rootB@20 --loop_done-->
    //     contB@30 --link--> rootA@7: BOTH roots are link-fed — two qualifiers,
    //     "multiple qualifying roots stay unarmable".
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        defer state.registry.cache.clearRetainingCapacity();
        var ra_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 10 }, .{ .op = .loop } };
        var ra_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
        var ra: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &ra_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ra_p },
            .id = 1,
        };
        var ca_i = [_]IrInstr{.{ .op = .link, .aux = 20 }};
        var ca_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 9, .inline_depth = 0 } } }};
        var ca: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 10 }, .instrs = &ca_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ca_p },
            .id = 2,
        };
        var rb_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 30 }, .{ .op = .loop } };
        var rb_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(19, .loop_done) }};
        var rb: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 20 }, .instrs = &rb_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &rb_p },
            .id = 3,
        };
        var cb_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
        var cb_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 29, .inline_depth = 0 } } }};
        var cb: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &cb_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cb_p },
            .id = 4,
        };
        for ([_]*Trace{ &ra, &ca, &rb, &cb }) |t| try state.registry.cache.append(gpa, t);
        state.rebuildEdgeCache();
        state.rebuildRegions();
        try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
        var kit = state.region_policy.region_defs.keyIterator();
        try testing.expect(!state.region_policy.region_defs.get(kit.next().?.*).?.armable);
    }

    // (b) One root fed by TWO physical `.link` continuations: qualification
    // counts destination NODES, not edges — exactly one qualifier, elected.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        defer state.registry.cache.clearRetainingCapacity();
        var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .guard_true, .a = 0, .aux = 10 }, .{ .op = .loop } };
        var root_p = [_]ExitProvEntry{
            .{ .index = 0, .prov = guardProv(6, .loop_done) },
            .{ .index = 1, .prov = guardProv(5, .branch_cond) },
        };
        var root: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
            .id = 1,
        };
        var ca_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
        var ca_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 1, .inline_depth = 0 } } }};
        var ca: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &ca_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ca_p },
            .id = 2,
        };
        var cbb_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
        var cbb_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 9, .inline_depth = 0 } } }};
        var cbb: Trace = .{
            .code = .{ .anchor = .{ .proto = &proto, .pc = 10 }, .instrs = &cbb_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cbb_p },
            .id = 3,
        };
        for ([_]*Trace{ &root, &ca, &cbb }) |t| try state.registry.cache.append(gpa, t);
        state.rebuildEdgeCache();
        state.rebuildRegions();
        try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
        var kit = state.region_policy.region_defs.keyIterator();
        const def = state.region_policy.region_defs.get(kit.next().?.*).?;
        try testing.expect(def.armable);
        try testing.expectEqual(@as(u32, 7), def.owner.pc);
    }
}

test "inc-B open SCC: an incoming boundary edge into a NON-root member disables the fallback (codex closed-proof pin)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 24;
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // The armable T1 shape (root@7 ↔ cont@2, correct link provenance) PLUS a
    // boundary edge into the CONT. The primary tier still elects nobody (the
    // external edge's destination is not a root), and the fallback must refuse:
    // the closed-SCC proof fails, so the region keeps today's unarmable
    // treatment rather than newly arming an open shape.
    var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var root: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
        .id = 1,
    };
    var cont_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 1, .inline_depth = 0 } } }};
    var cont: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p },
        .id = 2,
    };
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 2 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p },
        .id = 3,
    };
    for ([_]*Trace{ &root, &cont, &ext }) |t| try state.registry.cache.append(gpa, t);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    try testing.expect(!state.region_policy.region_defs.get(kit.next().?.*).?.armable);
}

test "inc-B fallback_owner flag: set on fallback mint, cleared when the primary tier takes over (rebind)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 25;
    var code: [40]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // T1 shape: link-fed root@7 ↔ cont@2, fully closed → fallback tier elects.
    var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var root: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
        .id = 1,
    };
    var cont_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 1, .inline_depth = 0 } } }};
    var cont: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p },
        .id = 2,
    };
    try state.registry.cache.append(gpa, &root);
    try state.registry.cache.append(gpa, &cont);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expect(def.fallback_owner);
    }

    // Add an external guard-fed entry INTO THE ROOT: the primary tier now
    // elects (is_ext root), so the rebind must clear `fallback_owner` — the
    // strike-out policy for a primary-elected owner is the gate, not the
    // tombstone.
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p },
        .id = 3,
    };
    try state.registry.cache.append(gpa, &ext);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expect(!def.fallback_owner);
    }

    // Remove the external entry again: the fallback re-elects and the flag
    // comes back — strike-out policy tracks the CURRENT election tier.
    for (state.registry.cache.items, 0..) |t, i| {
        if (t.id == 3) {
            _ = state.registry.cache.swapRemove(i);
            break;
        }
    }
    state.rebuildEdgeCache();
    state.rebuildRegions();
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expect(def.fallback_owner);
    }
}

test "inc-B strike-out policy: fallback-elected owner tombstones (one-shot); primary-elected owner keeps the gate" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = 26, .name = "t", .num_registers = 1 };
    const owner: trace.AnchorKey = .{ .proto = &proto, .pc = 7 };

    // Fallback-elected region: strike-out must tombstone the region and eat
    // the penalty — NOT gate the anchor (the gate branch re-fires on every
    // subsequent strike and tears down every armed link registry-wide, which
    // is the fft regression this policy exists to prevent).
    const rid: RegionId = @enumFromInt(900);
    const key: trace.RegionKey = .{ .region_id = rid, .activation = 1 };
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.alloc(ProgramPoint, 0),
        .owner = owner,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(trace.RegionBridgeDef, 0),
        .fallback_owner = true,
    });
    try state.region_policy.region_profit.put(gpa, key, .{
        .root_frame_depth = 0,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
    });
    try state.penalty.put(gpa, owner, state.config.max_penalty - 1);

    // work=1 < min_useful → strike; penalty saturates → the fallback path.
    state.flushRegionWindow(key, 1);
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.tombstoned);
        try testing.expect(!def.armable);
    }
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));
    try testing.expectEqual(@as(usize, 0), state.gate.count());

    // Re-saturating the penalty later re-takes the same path without
    // re-invalidating (tombstone is sticky) and still never gates.
    try state.penalty.put(gpa, owner, state.config.max_penalty - 1);
    try state.region_policy.region_profit.put(gpa, key, .{
        .root_frame_depth = 0,
        .root_call_seq = key.activation,
        .useful_window_seen = true,
    });
    state.flushRegionWindow(key, 1);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));
    try testing.expectEqual(@as(usize, 0), state.gate.count());

    // Primary-elected region (fallback_owner=false): the same saturation must
    // keep today's behaviour — gate the owner anchor, def NOT tombstoned.
    const rid2: RegionId = @enumFromInt(901);
    const key2: trace.RegionKey = .{ .region_id = rid2, .activation = 2 };
    const owner2: trace.AnchorKey = .{ .proto = &proto, .pc = 3 };
    try state.region_policy.region_defs.put(gpa, rid2, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.alloc(ProgramPoint, 0),
        .owner = owner2,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(trace.RegionBridgeDef, 0),
    });
    try state.region_policy.region_profit.put(gpa, key2, .{
        .root_frame_depth = 0,
        .root_call_seq = key2.activation,
        .useful_window_seen = true,
    });
    try state.penalty.put(gpa, owner2, state.config.max_penalty - 1);
    state.flushRegionWindow(key2, 1);
    {
        const def = state.region_policy.region_defs.get(rid2).?;
        try testing.expect(!def.tombstoned);
    }
    try testing.expect(state.gate.get(owner2) != null);
}

// ── inc-B follow-up: dormancy, net-work balance, receipt attribution ─────────

test "inc-B dormancy: fallback mint is dormant + excluded from receipt maps; tier flips re-arm dormancy and reset ALL learning counters" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const P_ID: u32 = 27;
    var code: [40]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = P_ID, .name = "t", .num_registers = 1 };

    // T1 shape: link-fed root@7 ↔ cont@2, fully closed → fallback tier elects.
    var root_i = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 2 }, .{ .op = .loop } };
    var root_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(6, .loop_done) }};
    var root: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 7 }, .instrs = &root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &root_p },
        .id = 1,
    };
    var cont_i = [_]IrInstr{.{ .op = .link, .aux = 7 }};
    var cont_p = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = P_ID, .source_pc = 1, .inline_depth = 0 } } }};
    var cont: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 2 }, .instrs = &cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &cont_p },
        .id = 2,
    };
    try state.registry.cache.append(gpa, &root);
    try state.registry.cache.append(gpa, &cont);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.region_policy.region_defs.count());
    var kit = state.region_policy.region_defs.keyIterator();
    const rid = kit.next().?.*;
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.armable);
        try testing.expect(def.fallback_owner);
        // Fallback mints DORMANT: no receipt-map entries, so the whole
        // receipt pipeline stays short-circuited until admission.
        try testing.expect(def.dormant);
    }
    try testing.expectEqual(@as(usize, 0), state.region_policy.source_exit_regions.count());
    try testing.expectEqual(@as(usize, 0), state.region_policy.dest_entry_regions.count());
    try testing.expect(state.region_policy.receiptsInert());

    // Seed every learning counter as if the region had lived a while.
    {
        const d = state.region_policy.region_defs.getPtr(rid).?;
        d.dormant = false; // as if admitted
        d.instability = 3;
        d.no_candidate_runs = 2;
        d.admission_failures = 5;
        d.receipts_debit = 1000;
        d.transitions_credit = 500;
    }

    // Tier flip to PRIMARY (external guard-fed entry into the root): the
    // rebind must clear fallback_owner AND zero all fallback learning state.
    var ext_i = [_]IrInstr{.{ .op = .guard_true, .a = 0, .aux = 7 }};
    var ext_p = [_]ExitProvEntry{.{ .index = 0, .prov = guardProv(29, .branch_cond) }};
    var ext: Trace = .{
        .code = .{ .anchor = .{ .proto = &proto, .pc = 30 }, .instrs = &ext_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &ext_p },
        .id = 3,
    };
    try state.registry.cache.append(gpa, &ext);
    state.rebuildEdgeCache();
    state.rebuildRegions();
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(!def.fallback_owner);
        try testing.expect(!def.dormant);
        try testing.expectEqual(@as(u8, 0), def.instability);
        try testing.expectEqual(@as(u8, 0), def.no_candidate_runs);
        try testing.expectEqual(@as(u8, 0), def.admission_failures);
        try testing.expectEqual(@as(u64, 0), def.receipts_debit);
        try testing.expectEqual(@as(u64, 0), def.transitions_credit);
    }
    // Primary tier is NOT dormant → it participates in the receipt maps.
    try testing.expect(!state.region_policy.receiptsInert());

    // Seed again, then flip BACK to fallback: dormancy re-arms (the region
    // must re-qualify through admission) and the counters zero again.
    {
        const d = state.region_policy.region_defs.getPtr(rid).?;
        d.instability = 7;
        d.receipts_debit = 9999;
    }
    for (state.registry.cache.items, 0..) |t, i| {
        if (t.id == 3) {
            _ = state.registry.cache.swapRemove(i);
            break;
        }
    }
    state.rebuildEdgeCache();
    state.rebuildRegions();
    {
        const def = state.region_policy.region_defs.get(rid).?;
        try testing.expect(def.fallback_owner);
        try testing.expect(def.dormant);
        try testing.expectEqual(@as(u8, 0), def.instability);
        try testing.expectEqual(@as(u64, 0), def.receipts_debit);
    }
    try testing.expect(state.region_policy.receiptsInert());
}

test "inc-B net-work balance: below min sample never evicts; repaid balance survives; net-loss tombstones and requests the deferred rebuild" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    const proto = Proto{ .code = &code, .id = 28, .name = "t", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(910);
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.alloc(StructuralEdgeId, 0),
        .member_points = try gpa.alloc(ProgramPoint, 0),
        .owner = .{ .proto = &proto, .pc = 7 },
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
        .bridges = try gpa.alloc(trace.RegionBridgeDef, 0),
        .fallback_owner = true,
    });

    // Below the minimum sample: no credit at all, still no eviction.
    {
        const d = state.region_policy.region_defs.getPtr(rid).?;
        d.receipts_debit = state.config.region_payoff_receipts - 2;
    }
    state.chargePayoffReceipt(rid);
    try testing.expect(!state.region_policy.region_defs.get(rid).?.tombstoned);

    // At the sample boundary with a repaying credit: survives, debit keeps
    // accumulating (promotions never reset it).
    {
        const d = state.region_policy.region_defs.getPtr(rid).?;
        d.transitions_credit = (d.receipts_debit + 1 + state.config.region_profit_weight - 1) / state.config.region_profit_weight;
    }
    state.chargePayoffReceipt(rid);
    {
        const d = state.region_policy.region_defs.get(rid).?;
        try testing.expect(!d.tombstoned);
        try testing.expectEqual(@as(u64, state.config.region_payoff_receipts), d.receipts_debit);
    }

    // Starve the credit below the survival line: the next charge tombstones
    // one-shot and requests the deferred maps rebuild.
    {
        const d = state.region_policy.region_defs.getPtr(rid).?;
        d.transitions_credit = 0;
    }
    try testing.expect(!state.pending_region_rebuild);
    state.chargePayoffReceipt(rid);
    {
        const d = state.region_policy.region_defs.get(rid).?;
        try testing.expect(d.tombstoned);
        try testing.expect(!d.armable);
    }
    try testing.expect(state.pending_region_rebuild);
    // The deferred drain consumes the flag through the common settlement path.
    state.drainPendingRegionRebuild();
    try testing.expect(!state.pending_region_rebuild);

    // Charges against a tombstoned (or dormant, or primary) def are inert.
    state.chargePayoffReceipt(rid);
    try testing.expect(!state.pending_region_rebuild);
}

test "inc-B null-effective receipt attribution: minOpenRegion picks the smallest open region id deterministically" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    try testing.expectEqual(@as(?RegionId, null), state.minOpenRegion());
    try state.region_policy.region_profit.put(gpa, .{ .region_id = @enumFromInt(9), .activation = 1 }, .{ .root_frame_depth = 0, .root_call_seq = 1 });
    try state.region_policy.region_profit.put(gpa, .{ .region_id = @enumFromInt(4), .activation = 2 }, .{ .root_frame_depth = 0, .root_call_seq = 2 });
    try state.region_policy.region_profit.put(gpa, .{ .region_id = @enumFromInt(6), .activation = 3 }, .{ .root_frame_depth = 0, .root_call_seq = 3 });
    try testing.expectEqual(@as(RegionId, @enumFromInt(4)), state.minOpenRegion().?);
}
