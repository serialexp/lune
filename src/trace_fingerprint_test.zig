//! Tests for `trace.zig` — fingerprint.
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
const GuardRole = trace.GuardRole;
const InlineFrame = trace.InlineFrame;
const IrInstr = trace.IrInstr;
const IrOp = trace.IrOp;
const OperandDesig = trace.OperandDesig;
const Polarity = trace.Polarity;
const Ref = trace.Ref;
const Trace = trace.Trace;
const TraceState = trace.TraceState;
const buildBridgeCandMemo = trace.buildBridgeCandMemo;
const buildExitProv = trace.buildExitProv;
const pathFromFrames = trace.pathFromFrames;

const util = @import("trace_testutil.zig");
const winRO = util.winRO;

test "matchesFingerprint: empty fingerprint always matches" {
    const t = Trace{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
    };
    var regs = [_]Value{ Value.int(1), Value.float(3.14), Value.nil() };
    try testing.expect(t.code.matchesFingerprint(winRO(&regs)));
}

test "nextTraceExcluding: visits each anchor trace once, highest-hit first, then null" {
    // The dispatch walk's termination guarantee: with the visited set growing by
    // one each step, `nextTraceExcluding` returns hit-count-descending and never
    // repeats — so two equal-priority traces can't cycle `A→B→A→…`. We pin both
    // the ordering and the terminating `null`.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 0 };
    const loop_only = [_]IrInstr{.{ .op = .loop }};

    // Three traces at the same anchor (pc 10) with distinct hit counts, plus a
    // decoy at a different anchor (pc 99) that must never be returned.
    var traces: [4]*Trace = undefined;
    const specs = [_]struct { pc: u32, hits: u64 }{
        .{ .pc = 10, .hits = 5 },
        .{ .pc = 10, .hits = 1 },
        .{ .pc = 10, .hits = 3 },
        .{ .pc = 99, .hits = 100 },
    };
    for (&traces, specs) |*slot, spec| {
        const tr = try gpa.create(Trace);
        tr.* = .{
            .code = .{
                .anchor = .{ .proto = &proto, .pc = spec.pc },
                .instrs = @constCast(&loop_only),
                .consts = &.{},
                .entry_slots = &.{},
                .entry_guards = &.{},
            },
            .hit_count = spec.hits,
        };
        slot.* = tr;
        try state.registry.cache.append(gpa, tr);
    }
    defer {
        state.registry.cache.clearRetainingCapacity();
        for (traces) |tr| gpa.destroy(tr);
    }

    var visited: [8]*Trace = undefined;
    var n: usize = 0;
    // Expected visit order at pc 10: hits 5, then 3, then 1; pc 99 never appears.
    const expect_hits = [_]u64{ 5, 3, 1 };
    for (expect_hits) |h| {
        const next = state.nextTraceExcluding(&proto, 10, visited[0..n]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(h, next.hit_count);
        visited[n] = next;
        n += 1;
    }
    // All three visited → the walk terminates.
    try testing.expect(state.nextTraceExcluding(&proto, 10, visited[0..n]) == null);
}

test "matchesFingerprint: matching types" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .int },
        .{ .slot = 1, .ty = .float },
    };
    const t = Trace{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = @constCast(&entry_guards),
        },
    };
    var regs = [_]Value{ Value.int(42), Value.float(3.14) };
    try testing.expect(t.code.matchesFingerprint(winRO(&regs)));
}

test "matchesFingerprint: mismatched int/float" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .int },
    };
    const t = Trace{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = @constCast(&entry_guards),
        },
    };
    // Register holds a float, but the trace expects int.
    var regs = [_]Value{Value.float(2.5)};
    try testing.expect(!t.code.matchesFingerprint(winRO(&regs)));
}

test "matchesFingerprint: guard_number accepts both int and float" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .number },
    };
    const t = Trace{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = @constCast(&entry_guards),
        },
    };
    try testing.expect(t.code.matchesFingerprint(winRO(@constCast(&[_]Value{Value.int(1)}))));
    try testing.expect(t.code.matchesFingerprint(winRO(@constCast(&[_]Value{Value.float(1.5)}))));
    try testing.expect(!t.code.matchesFingerprint(winRO(@constCast(&[_]Value{Value.nil()}))));
    try testing.expect(!t.code.matchesFingerprint(winRO(@constCast(&[_]Value{Value.boolean(true)}))));
}

test "matchesFingerprint: guard_table" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .table },
    };
    const t = Trace{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = @constCast(&entry_guards),
        },
    };
    try testing.expect(!t.code.matchesFingerprint(winRO(@constCast(&[_]Value{Value.int(1)}))));
    try testing.expect(!t.code.matchesFingerprint(winRO(@constCast(&[_]Value{Value.float(1.0)}))));
}

fn testGuardProv(pc: u32, role: GuardRole, operand: OperandDesig) ExitProvenance {
    return .{ .guard = .{ .source_proto_id = 7, .source_pc = pc, .role = role, .operand = operand } };
}

test "buildExitProv: remap through a compaction map, drop non-survivors, sort (A-i.1)" {
    const gpa = testing.allocator;
    const a = testGuardProv(10, .operand_type, .b);
    const b = testGuardProv(20, .branch_cond, .a);
    // %0 no prov; %1 = A → committed 1; %2 = B → DROPPED (map null); %3 no prov.
    const rec = [_]?ExitProvenance{ null, a, b, null };
    const map = [_]?Ref{ 0, 1, null, 2 };
    const out = try buildExitProv(gpa, &rec, &map, null);
    defer if (out.len != 0) gpa.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].index);
    try testing.expectEqual(@as(u32, 10), out[0].prov.guard.source_pc);
}

test "buildExitProv: null map is the identity (dupe path), result stays sorted (A-i.1)" {
    const gpa = testing.allocator;
    const a = testGuardProv(10, .operand_type, .b);
    const b = testGuardProv(20, .branch_cond, .a);
    const rec = [_]?ExitProvenance{ null, a, null, b }; // committed == emission (identity)
    const out = try buildExitProv(gpa, &rec, null, null);
    defer if (out.len != 0) gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].index);
    try testing.expectEqual(@as(u32, 3), out[1].index);
    // Sorted ascending → binary search via provAt works.
    const t = Trace{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = @constCast(out),
        },
    };
    try testing.expect(t.code.provAt(0) == null);
    try testing.expectEqual(@as(u32, 10), t.code.provAt(1).?.guard.source_pc);
    try testing.expect(t.code.provAt(2) == null);
    try testing.expectEqual(@as(u32, 20), t.code.provAt(3).?.guard.source_pc);
    try testing.expect(t.code.provAt(4) == null);
}

test "§T.9 bridge-candidate memo: bit-identical to the oracle at every index, unbuilt falls back" {
    // The memo is only legitimate if it is indistinguishable from the pure oracle it
    // replaces. Assert that directly, at EVERY index (including out of bounds), in
    // all three states: unbuilt (fallback), built-with-a-true-bit, built-all-false.
    const gpa = testing.allocator;
    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    code[19] = Instr.opAx(.for_loop, 0, 2);
    const proto = Proto{ .id = 42, .code = &code, .name = "memo", .num_registers = 1 };
    const guard_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 13,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 3, .prov = guard_prov }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 14 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 29 },
            .instrs = &cont_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_prov,
        },
        .id = 900,
    };

    // (a) Unbuilt — hand-built test traces never go through commit; the accessor
    // must BE the oracle.
    try testing.expect(!cont.code.bridge_cand_built);
    for (0..cont_instrs.len + 4) |i|
        try testing.expectEqual(nativegen.isCompositeBridgeCandidate(&cont.code, i), cont.code.isBridgeCandidate(i));
    try testing.expect(cont.code.isBridgeCandidate(3)); // known bridge slot

    // (b) Built — still bit-identical everywhere, in and out of bounds.
    buildBridgeCandMemo(gpa, &cont);
    defer if (cont.code.bridge_cand.len != 0) gpa.free(cont.code.bridge_cand);
    try testing.expect(cont.code.bridge_cand_built);
    for (0..cont_instrs.len + 4) |i|
        try testing.expectEqual(nativegen.isCompositeBridgeCandidate(&cont.code, i), cont.code.isBridgeCandidate(i));
    try testing.expect(cont.code.isBridgeCandidate(3));

    // (c) An all-false trace: a built memo must not invent a candidate.
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 25 },
            .instrs = &skip_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 901,
    };
    buildBridgeCandMemo(gpa, &skip);
    defer if (skip.code.bridge_cand.len != 0) gpa.free(skip.code.bridge_cand);
    try testing.expect(skip.code.bridge_cand_built);
    for (0..skip_instrs.len + 2) |i| {
        try testing.expect(!skip.code.isBridgeCandidate(i));
        try testing.expectEqual(nativegen.isCompositeBridgeCandidate(&skip.code, i), skip.code.isBridgeCandidate(i));
    }

    // (d) Empty trace: marked built, allocates nothing, every index false.
    var empty: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 0 },
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 902,
    };
    buildBridgeCandMemo(gpa, &empty);
    try testing.expect(empty.code.bridge_cand_built);
    try testing.expectEqual(@as(usize, 0), empty.code.bridge_cand.len);
    try testing.expect(!empty.code.isBridgeCandidate(0));
}

test "pathFromFrames: f(a);f(b) at distinct call sites give distinct inline paths (A-i.2)" {
    // Same callee proto inlined at two different `.call` PCs must yield distinct
    // provenance — the collision H-1a fixes. `pathFromFrames` distinguishes them by
    // `call_pc` even though `caller_proto_id` is identical.
    const frames = [_]InlineFrame{
        .{ .base_off = 0, .ret_dest = 0, .ret_count = 0, .caller_proto_id = 3, .call_pc = 11 },
        .{ .base_off = 8, .ret_dest = 0, .ret_count = 0, .caller_proto_id = 3, .call_pc = 42 },
    };
    const p1 = pathFromFrames(&frames, 1);
    try testing.expectEqual(@as(u32, 3), p1[0].caller_proto_id);
    try testing.expectEqual(@as(u32, 11), p1[0].call_pc);
    const p2 = pathFromFrames(&frames, 2);
    try testing.expectEqual(@as(u32, 11), p2[0].call_pc);
    try testing.expectEqual(@as(u32, 42), p2[1].call_pc); // second edge is the distinguisher
    // Depth-0 (anchor frame, no inlining) reads no edges.
    _ = pathFromFrames(&frames, 0);
}

test "buildExitProv: empty when nothing survives → static slice, no alloc (A-i.1)" {
    const gpa = testing.allocator;
    const a = testGuardProv(10, .operand_type, .b);
    const rec = [_]?ExitProvenance{ null, a, null };
    const map = [_]?Ref{ 0, null, 1 }; // the only prov is dropped
    const out = try buildExitProv(gpa, &rec, &map, null);
    try testing.expectEqual(@as(usize, 0), out.len); // static empty; no free needed
}

test "A-i.3 stamp: arith operand guards carry (operand_type, b/c) and source_pc = pc−1" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.int(10), Value.int(20) };
    // add r0,r1,r2 at guest PC 42 → post-increment cur_pc, so source_pc == 41.
    state.recordInstr(Instr.opABC(.add, 0, 1, 2), winRO(&regs), &proto, 42, Value.nil());
    const prov = state.rec.exit_prov.items;
    // instrs: slot_load, slot_load, guard_int(r1)=#2, guard_int(r2)=#3, add → lockstep len 5.
    try testing.expectEqual(state.rec.instrs.items.len, prov.len);
    const g1 = prov[2].?.guard;
    try testing.expectEqual(GuardRole.operand_type, g1.role);
    try testing.expectEqual(OperandDesig.b, g1.operand);
    try testing.expectEqual(@as(u32, 41), g1.source_pc); // cur_pc − 1
    try testing.expectEqual(Polarity.neutral, g1.polarity);
    const g2 = prov[3].?.guard;
    try testing.expectEqual(OperandDesig.c, g2.operand);
    try testing.expectEqual(@as(u32, 41), g2.source_pc);
    // Non-guard nodes (loads, the arith result) carry no provenance.
    try testing.expect(prov[0] == null);
    try testing.expect(prov[1] == null);
    try testing.expect(prov[4] == null);
}

test "A-i.3 stamp: int↔float re-record keeps guard identity (only the IR op differs)" {
    const gpa = testing.allocator;
    // Re-recording the same guest site with a float operand must yield the SAME
    // (role, operand, source_pc) — the identity keys on the guest site, not the
    // observed type. Only the emitted IR op flips guard_int → guard_float.
    inline for (.{ .{ Value.int(10), Value.int(20), IrOp.guard_int }, .{ Value.float(1.5), Value.float(2.5), IrOp.guard_float } }) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), c[0], c[1] };
        state.recordInstr(Instr.opABC(.add, 0, 1, 2), winRO(&regs), &proto, 42, Value.nil());
        try testing.expectEqual(c[2], state.rec.instrs.items[2].op); // op differs by type
        const g = state.rec.exit_prov.items[2].?.guard;
        try testing.expectEqual(GuardRole.operand_type, g.role); // identity does NOT
        try testing.expectEqual(OperandDesig.b, g.operand);
        try testing.expectEqual(@as(u32, 41), g.source_pc);
    }
}

test "A-i.3 stamp: branch polarity keys on the guest jump-taken edge, not raw truthiness" {
    const gpa = testing.allocator;
    // Polarity names which guest CFG edge the recorded path took, keyed on the
    // opcode's *jump-taken* edge — NOT truthiness. `jmp_if_false` jumps when falsy;
    // `jmp_if_true` jumps when truthy. So for one operand value the two opcodes give
    // OPPOSITE polarity, while the guard op (true/false) tracks truthiness alone.
    // { opcode, operand, expected guard op, expected polarity }.
    inline for (.{
        .{ bytecode.OpCode.jmp_if_false, Value.int(1), IrOp.guard_true, Polarity.fallthrough }, // truthy: doesn't jump
        .{ bytecode.OpCode.jmp_if_false, Value.boolean(false), IrOp.guard_false, Polarity.taken }, // falsy: jumps
        .{ bytecode.OpCode.jmp_if_true, Value.int(1), IrOp.guard_true, Polarity.taken }, // truthy: jumps
        .{ bytecode.OpCode.jmp_if_true, Value.boolean(false), IrOp.guard_false, Polarity.fallthrough }, // falsy: doesn't jump
    }) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ c[1], Value.nil() };
        state.recordInstr(Instr.opABC(c[0], 0, 0, 0), winRO(&regs), &proto, 7, Value.nil());
        try testing.expectEqual(c[2], state.rec.instrs.items[1].op);
        const g = state.rec.exit_prov.items[1].?.guard;
        try testing.expectEqual(GuardRole.branch_cond, g.role);
        try testing.expectEqual(OperandDesig.a, g.operand);
        try testing.expectEqual(@as(u32, 6), g.source_pc); // 7 − 1
        try testing.expectEqual(c[3], g.polarity);
    }
}

test "buildExitProv: a .link terminal entry is injected and sorts last (A-i.4)" {
    const gpa = testing.allocator;
    // A guard at emission %1 (survives as committed 1) plus the `.link` terminal at
    // committed index 4 (appended directly at commit — no lockstep slot). The link
    // entry must appear in the output, sorted after the guard.
    const g = testGuardProv(10, .operand_type, .b);
    const rec = [_]?ExitProvenance{ null, g, null };
    const link = ExitProvEntry{ .index = 4, .prov = .{ .link_terminal = .{ .source_proto_id = 7, .source_pc = 41 } } };
    const out = try buildExitProv(gpa, &rec, null, link);
    defer if (out.len != 0) gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].index); // guard first
    try testing.expect(out[0].prov == .guard);
    try testing.expectEqual(@as(u32, 4), out[1].index); // link terminal last
    try testing.expect(out[1].prov == .link_terminal);
    try testing.expectEqual(@as(u32, 41), out[1].prov.link_terminal.source_pc);
}

test "A-i.4 transport: recForPrepLink commits a .link trace carrying .link_terminal provenance" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    // The inner root below is stack-allocated (never heap-freed); the committed link
    // trace IS heap-allocated. Free the committed one explicitly, then drop both cache
    // pointers before `deinit` so it never calls `destroy` on the stack trace.
    var committed: ?*Trace = null;
    defer state.deinit();
    defer {
        if (committed) |ct| ct.destroy(gpa);
        state.registry.cache.clearRetainingCapacity();
    }

    // Bytecode shape: `for_prep` recorded at post-increment pc 5 (its guest opcode is
    // at index 4), jumping +2 to the `for_loop` at index 7, whose back-edge (−3) lands
    // on the inner-root anchor pc 5. Only code[7] is read by recForPrepLink.
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.load_nil);
    code[7] = Instr.opJ(.for_loop, -3);
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 4 };

    // A pre-existing inner `.loop` root at (proto, 5) — LINNER only links if one exists.
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

    // Arm a *continuation* recording (a `.root` recording aborts LINNER at for_prep).
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 2 }, proto.num_registers);
    state.rec.kind = .continuation;

    // for_prep a=0 aux=+2, control regs R[0..2] = init/limit/step (all int).
    var regs = [_]Value{ Value.int(1), Value.int(10), Value.int(1), Value.nil() };
    state.recordInstr(Instr.opAx(.for_prep, 0, 2), winRO(&regs), &proto, 5, Value.nil());

    // Recording closed (committed a `.link` trace). The new trace is last in cache.
    try testing.expect(!state.isRecording());
    const t = state.registry.cache.items[state.registry.cache.items.len - 1];
    committed = t; // hand to the cleanup defer
    try testing.expect(t.id != 900); // not the pre-seeded inner root
    const last = t.code.instrs.len - 1;
    try testing.expectEqual(IrOp.link, t.code.instrs[last].op);
    try testing.expectEqual(@as(i32, 5), t.code.instrs[last].aux); // links to inner anchor pc 5

    // The `.link` terminal's provenance is present at the terminal's committed index.
    const prov = t.code.provAt(@intCast(last)) orelse return error.MissingLinkProvenance;
    try testing.expect(prov == .link_terminal);
    try testing.expectEqual(@as(u32, 4), prov.link_terminal.source_pc); // cur_pc 5 − 1
    try testing.expectEqual(@as(u8, 0), prov.link_terminal.inline_depth); // never inlined
}
