//! Doc 56 §4.3 (Phase 2): pure tests for exit attachability and the
//! resume pc. Every rule in `trace_exit_attach` is pinned by a fixture
//! that breaks exactly that rule, and the commit-time memo is pinned
//! equal to the scanning oracle.

const std = @import("std");
const testing = std.testing;
const bytecode = @import("bytecode.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const trace_types = @import("trace_types.zig");
const trace_snapshot = @import("trace_snapshot.zig");
const value = @import("value.zig");
const attach = @import("trace_exit_attach.zig");

const I = trace_ir.IrInstr;
const Instr = bytecode.Instr;
const Value = value.Value;
const Verdict = attach.Verdict;
const ExitProvEntry = trace_types.ExitProvEntry;
const GuardProvenance = trace_types.GuardProvenance;
const TraceCode = trace_code.TraceCode;

const PROTO_ID: u32 = 5602;

/// The guest loop the fixture was "recorded" from:
///
///   0: add               pre-loop
///   1: lt   r2 = r0<r1   loop header (the anchor)
///   2: jmp_if_false r2 → 6
///   3: add  r0 += k
///   4: set_index t[r0] = k
///   5: add
///   6: add               the join
///   7: jmp → 1           back-edge
///   8: ret
fn guestCode() [9]Instr {
    return .{
        Instr.opABC(.add, 3, 3, 3),
        Instr.opABC(.lt, 2, 0, 1),
        Instr.opAx(.jmp_if_false, 2, 3),
        Instr.opABC(.add, 0, 0, 3),
        Instr.opABC(.set_index, 4, 0, 3),
        Instr.opABC(.add, 5, 0, 3),
        Instr.opABC(.add, 5, 5, 3),
        Instr.opJ(.jmp, -7),
        Instr.opAB(.ret, 0, 1),
    };
}

// Exits of the fixture trace (committed instruction indices).
const E_BRANCH = 4; // pc 2's branch: recorded truthy (fell through), exits to 6
const E_ADD = 7; // pc 3's result type
const E_BOUNDS = 9; // pc 4's bounds check
const E_LATE = 11; // pc 5's result type, below pc 4's sunk store

fn traceInstrs() [16]I {
    return .{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: n
        .{ .op = .slot_load, .aux = 2 }, // 2: t
        .{ .op = .lt, .a = 0, .b = 1, .ord = 1 }, // 3        pc 1
        .{ .op = .guard_true, .a = 3, .aux = 3, .ord = 2 }, // 4  pc 2
        .{ .op = .konst, .aux = 0, .ord = 3 }, // 5
        .{ .op = .add, .a = 0, .b = 5, .ord = 3 }, // 6        pc 3
        .{ .op = .guard_int, .a = 6, .aux = 4, .ord = 3 }, // 7
        .{ .op = .aref, .a = 2, .b = 6, .ord = 4 }, // 8       pc 4
        .{ .op = .guard_bounds, .a = 8, .ord = 4 }, // 9
        .{ .op = .add, .a = 6, .b = 5, .ord = 5 }, // 10       pc 5
        .{ .op = .guard_int, .a = 10, .aux = 6, .ord = 5 }, // 11
        .{ .op = .add, .a = 10, .b = 5, .ord = 6 }, // 12      pc 6
        .{ .op = .astore, .a = 8, .b = 6, .ord = 4 }, // 13    pc 4's sunk store
        .{ .op = .phi, .b = 12, .aux = 0 }, // 14
        .{ .op = .loop }, // 15
    };
}

fn guardProv(pc: u32, role: trace_types.GuardRole, pol: trace_types.Polarity) trace_types.ExitProvenance {
    return .{ .guard = .{ .source_proto_id = PROTO_ID, .source_pc = pc, .role = role, .operand = .a, .polarity = pol } };
}

/// Owns every array one fixture trace borrows, so each test can break one
/// rule by editing a field and then ask for `code()`.
const Fixture = struct {
    guest: [9]Instr = guestCode(),
    proto: bytecode.Proto = undefined,
    instrs: [16]I = traceInstrs(),
    consts: [1]Value = .{Value.int(1)},
    snaps: [4]trace_snapshot.Snapshot = .{
        .{ .resume_pc = 2, .slots_begin = 0, .slots_len = 1, .register_count = 6 },
        .{ .resume_pc = 3, .slots_begin = 1, .slots_len = 1, .register_count = 6 },
        .{ .resume_pc = 4, .slots_begin = 2, .slots_len = 1, .register_count = 6 },
        .{ .resume_pc = 5, .slots_begin = 3, .slots_len = 1, .register_count = 6 },
    },
    slots: [4]trace_snapshot.SnapshotSlot = .{
        .{ .slot = 0, .ref = 0 }, .{ .slot = 0, .ref = 0 },
        .{ .slot = 0, .ref = 6 }, .{ .slot = 0, .ref = 6 },
    },
    by_ord: [7]trace_ir.SnapIdx = .{ 0, 0, 1, 2, 3, 4, 0 },
    prov: [4]ExitProvEntry = .{
        .{ .index = E_BRANCH, .prov = guardProv(2, .branch_cond, .fallthrough) },
        .{ .index = E_ADD, .prov = guardProv(3, .operand_type, .neutral) },
        .{ .index = E_BOUNDS, .prov = guardProv(4, .bounds, .neutral) },
        .{ .index = E_LATE, .prov = guardProv(5, .operand_type, .neutral) },
    },

    /// Call once the fixture sits at its final address.
    fn init(self: *Fixture) void {
        self.proto = .{ .code = &self.guest, .name = "exit-attach", .id = PROTO_ID };
    }

    fn code(self: *Fixture) TraceCode {
        return .{
            .anchor = .{ .proto = &self.proto, .pc = 1 },
            .instrs = &self.instrs,
            .consts = &self.consts,
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &self.prov,
            .exit_snapshots = &self.snaps,
            .exit_snapshot_slots = &self.slots,
            .exit_snap_by_ord = &self.by_ord,
        };
    }

    fn guardAt(self: *Fixture, idx: u32) *GuardProvenance {
        for (&self.prov) |*e| {
            if (e.index == idx) return &e.prov.guard;
        }
        unreachable;
    }
};

/// The verdict for `idx`, asserting the memo (built on a copy) agrees with
/// the oracle — every test below therefore also pins memo equivalence.
fn verdict(f: *Fixture, idx: usize) !Verdict {
    const c = f.code();
    const v = attach.classify(&c, idx);
    var memo = f.code();
    attach.buildMemo(testing.allocator, &memo);
    defer if (memo.exit_attach.len != 0) testing.allocator.free(memo.exit_attach);
    try testing.expect(memo.exit_attach_built);
    try testing.expectEqual(v == .attachable, memo.exitAttachable(idx));
    return v;
}

fn expectAllMemoEqual(f: *Fixture) !void {
    const c = f.code();
    var memo = f.code();
    attach.buildMemo(testing.allocator, &memo);
    defer if (memo.exit_attach.len != 0) testing.allocator.free(memo.exit_attach);
    for (0..c.instrs.len + 9) |i| {
        try testing.expectEqual(attach.classify(&c, i) == .attachable, memo.exitAttachable(i));
    }
}

test "doc 56 attach: every exit of the base fixture is attachable, with its resume pc" {
    var f: Fixture = .{};
    f.init();
    const c = f.code();
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_BRANCH));
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_ADD));
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_BOUNDS));
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));
    // The branch resumes at its not-taken successor; the rest re-execute
    // their own bytecode.
    try testing.expectEqual(@as(?u32, 6), c.exitResumePc(E_BRANCH));
    try testing.expectEqual(@as(?u32, 3), c.exitResumePc(E_ADD));
    try testing.expectEqual(@as(?u32, 4), c.exitResumePc(E_BOUNDS));
    try testing.expectEqual(@as(?u32, 5), c.exitResumePc(E_LATE));
    // Non-exits and out-of-range indices.
    try testing.expectEqual(Verdict.no_snapshot, try verdict(&f, 6));
    try testing.expectEqual(Verdict.no_snapshot, try verdict(&f, 13));
    try testing.expectEqual(Verdict.no_snapshot, attach.classify(&c, 99));
    try testing.expectEqual(@as(?u32, null), c.exitResumePc(6));
    try expectAllMemoEqual(&f);
}

test "doc 56 attach: a branch that jumped on the recorded path resumes at its fall-through" {
    var f: Fixture = .{};
    f.init();
    // Recorded falsy: `jmp_if_false` jumped to 6, so the exit falls through to 3.
    f.instrs[E_BRANCH].op = .guard_false;
    f.guardAt(E_BRANCH).polarity = .taken;
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_BRANCH));
    try testing.expectEqual(@as(?u32, 3), f.code().exitResumePc(E_BRANCH));
    // The same through `jmp_if_true`: recorded truthy means it jumped.
    f = .{};
    f.init();
    f.guest[2].op = .jmp_if_true;
    f.guardAt(E_BRANCH).polarity = .taken;
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_BRANCH));
    try testing.expectEqual(@as(?u32, 3), f.code().exitResumePc(E_BRANCH));
}

test "doc 56 attach: a branch without a clean not-taken successor is refused" {
    var f: Fixture = .{};
    f.init();
    f.guardAt(E_BRANCH).polarity = .taken; // disagrees with guard_true + jmp_if_false
    try testing.expectEqual(Verdict.branch_shape, try verdict(&f, E_BRANCH));

    f = .{};
    f.init();
    f.guest[2].op = .jmp_if_not_nil; // not a truthiness branch
    try testing.expectEqual(Verdict.branch_shape, try verdict(&f, E_BRANCH));

    f = .{};
    f.init();
    f.instrs[E_BRANCH].op = .guard_int; // a branch role on a non-branch guard
    try testing.expectEqual(Verdict.branch_shape, try verdict(&f, E_BRANCH));

    f = .{};
    f.init();
    f.guest[2].aux = 40; // target past the end of the proto
    try testing.expectEqual(Verdict.branch_shape, try verdict(&f, E_BRANCH));
}

test "doc 56 attach: the trace shape gates every exit" {
    var f: Fixture = .{};
    f.init();
    var c = f.code();
    c.peeled = true;
    try testing.expectEqual(Verdict.trace_shape, attach.classify(&c, E_ADD));
    c = f.code();
    c.deopt_mode = .precise;
    try testing.expectEqual(Verdict.trace_shape, attach.classify(&c, E_ADD));
    c = f.code();
    c.anchor.pc = trace_code.FUNC_HEAD_PC;
    try testing.expectEqual(Verdict.trace_shape, attach.classify(&c, E_ADD));
    c = f.code();
    c.anchor.pc = trace_code.CONT_PC_BIT | 1;
    try testing.expectEqual(Verdict.trace_shape, attach.classify(&c, E_ADD));
}

test "doc 56 attach: an exit needs a snapshot and complete guard provenance at depth 0" {
    var f: Fixture = .{};
    f.init();
    f.by_ord[3] = 0; // ord 3 (E_ADD) lost its snapshot
    try testing.expectEqual(Verdict.no_snapshot, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    var c = f.code();
    c.exit_prov_complete = false;
    try testing.expectEqual(Verdict.no_provenance, attach.classify(&c, E_ADD));

    f = .{};
    f.init();
    f.prov[1].index = 8; // E_ADD has no entry now
    try testing.expectEqual(Verdict.no_provenance, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    f.prov[1].prov = .{ .link_terminal = .{ .source_proto_id = PROTO_ID, .source_pc = 3 } };
    try testing.expectEqual(Verdict.no_provenance, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    f.guardAt(E_ADD).inline_depth = 1;
    try testing.expectEqual(Verdict.inlined, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    f.guardAt(E_ADD).source_proto_id = PROTO_ID + 1;
    try testing.expectEqual(Verdict.inlined, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    f.guardAt(E_ADD).role = .loop_done;
    try testing.expectEqual(Verdict.loop_done, try verdict(&f, E_ADD));
}

test "doc 56 attach: provenance, guard pc and snapshot must name the same bytecode" {
    var f: Fixture = .{};
    f.init();
    f.snaps[1].resume_pc = 2; // E_ADD's snapshot says pc 2
    try testing.expectEqual(Verdict.resume_mismatch, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    f.instrs[E_ADD].aux = 6; // the guard's own pc says 5
    try testing.expectEqual(Verdict.resume_mismatch, try verdict(&f, E_ADD));

    f = .{};
    f.init();
    f.guardAt(E_BOUNDS).source_pc = 9; // past the proto
    try testing.expectEqual(Verdict.resume_mismatch, try verdict(&f, E_BOUNDS));
}

test "doc 56 attach (Q6): an effect of the guard's own bytecode before it refuses the exit" {
    var f: Fixture = .{};
    f.init();
    // pc 5 stores inline before its own guard.
    f.instrs[10] = .{ .op = .astore, .a = 8, .b = 6, .ord = 5 };
    try testing.expectEqual(Verdict.own_effect, try verdict(&f, E_LATE));
    // The same store from an EARLIER bytecode already ran: fine.
    f.instrs[10].ord = 3;
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));

    // An interning string producer is re-run neutral (doc 24 D2).
    f = .{};
    f.init();
    f.instrs[10] = .{ .op = .tostr_int, .a = 6, .ord = 5 };
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));

    // Every other effect kind refuses too.
    for ([_]trace_ir.IrOp{ .hstore, .gstore, .ustore, .astore_append, .sgm_setpos }) |op| {
        f = .{};
        f.init();
        f.instrs[10] = .{ .op = op, .a = 8, .b = 6, .ord = 5 };
        try testing.expectEqual(Verdict.own_effect, try verdict(&f, E_LATE));
    }
}

test "doc 56 attach: an earlier bytecode's sunk store must be one the flush models" {
    var f: Fixture = .{};
    f.init();
    f.instrs[13].op = .sgm_setpos;
    try testing.expectEqual(Verdict.store_kind, try verdict(&f, E_LATE));
    // Exits at or before the deferring bytecode never apply it.
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_BOUNDS));
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_ADD));

    f.instrs[13].op = .astore_append;
    try testing.expectEqual(Verdict.store_kind, try verdict(&f, E_LATE));

    f = .{};
    f.init();
    f.instrs[13].ord = 0;
    try testing.expectEqual(Verdict.store_unordered, try verdict(&f, E_LATE));

    // The flush kinds all pass.
    for ([_]trace_ir.IrOp{ .hstore, .gstore, .ustore }) |op| {
        f = .{};
        f.init();
        f.instrs[13].op = op;
        try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));
    }
}

test "doc 56 attach: a sunk store's operands must be computed when the guard fails" {
    var f: Fixture = .{};
    f.init();
    f.instrs[13].b = 12; // the value is pc 6's add, after the guard
    try testing.expectEqual(Verdict.store_operand, try verdict(&f, E_LATE));
    // The same position holding a constant is always available.
    f.instrs[12] = .{ .op = .konst, .aux = 0, .ord = 6 };
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));

    // An address token after the guard rebuilds from ready operands.
    f = .{};
    f.init();
    f.instrs[12] = .{ .op = .aref, .a = 2, .b = 10, .ord = 6 };
    f.instrs[13].a = 12;
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));
    // ... but not when the guard's own result is one of them.
    f.instrs[12].b = E_LATE;
    try testing.expectEqual(Verdict.store_operand, try verdict(&f, E_LATE));

    // A `uref` after the guard has no operands: it reloads from its seed
    // slot, so it is always rebuildable.
    f = .{};
    f.init();
    f.instrs[12] = .{ .op = .uref, .aux = 7, .ord = 6 };
    f.instrs[13] = .{ .op = .ustore, .a = 12, .b = 6, .ord = 4 };
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));

    // The deepest real chain, `gstore → gcell → garow`, with both tokens
    // after the guard: walked down to ready operands.
    f = .{};
    f.init();
    f.instrs[12] = .{ .op = .garow, .a = 2, .b = 6, .ord = 6 };
    f.instrs[13] = .{ .op = .gcell, .a = 12, .b = 10, .ord = 6 };
    f.instrs[14] = .{ .op = .gstore, .a = 13, .b = 6, .ord = 4 };
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_LATE));
    // The guard's own result two levels down still refuses.
    f.instrs[12].b = E_LATE;
    try testing.expectEqual(Verdict.store_operand, try verdict(&f, E_LATE));
    try expectAllMemoEqual(&f);
}

test "doc 56 attach: the resume pc must not be a loop header and must reach a back-edge" {
    var f: Fixture = .{};
    f.init();
    // The branch's not-taken target is the loop header itself.
    f.guest[2].aux = -2;
    try testing.expectEqual(Verdict.resume_header, try verdict(&f, E_BRANCH));

    f = .{};
    f.init();
    // It leads to the `ret`: a continuation from there never closes.
    f.guest[2].aux = 5;
    try testing.expectEqual(Verdict.no_back_edge, try verdict(&f, E_BRANCH));

    f = .{};
    f.init();
    // An inner loop headed at pc 5: pc 6 jumps back to it.
    f.guest[6] = Instr.opJ(.jmp, -2);
    try testing.expectEqual(Verdict.resume_header, try verdict(&f, E_LATE));
}

test "doc 56 attach: the resume pc must not be the consumer half of a multret pair" {
    var f: Fixture = .{};
    f.init();
    // The branch resumes at pc 6; make it `f(g())`'s outer call, which
    // reads the transient `reg_top` its producer at pc 5 stamped.
    f.guest[5] = Instr.opABC(.call, 5, 1, bytecode.all_results);
    f.guest[6] = Instr.opABC(.call, 4, bytecode.all_results, 1);
    try testing.expectEqual(Verdict.multret_consumer, try verdict(&f, E_BRANCH));
    // `return g()`'s `ret` consumes the same way.
    f.guest[6] = Instr.opAB(.ret, 5, bytecode.all_results);
    try testing.expectEqual(Verdict.multret_consumer, try verdict(&f, E_BRANCH));
    // A fixed-count call or return at `P` reads no `reg_top`.
    f.guest[6] = Instr.opABC(.call, 4, 1, 1);
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_BRANCH));
    // Resuming AT the producer re-runs it, which stamps `reg_top` afresh.
    f.guest[3] = Instr.opABC(.call, 3, 1, bytecode.all_results);
    try testing.expectEqual(Verdict.attachable, try verdict(&f, E_ADD));
    try expectAllMemoEqual(&f);
}

test "doc 56 attach: the memo build is fail-soft under allocation failure" {
    var f: Fixture = .{};
    f.init();
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var c = f.code();
        attach.buildMemo(failing.allocator(), &c);
        defer if (c.exit_attach.len != 0) failing.allocator().free(c.exit_attach);
        if (!c.exit_attach_built) try testing.expectEqual(@as(usize, 0), c.exit_attach.len);
        // Built or not, the answers are the oracle's.
        for (0..c.instrs.len) |i|
            try testing.expectEqual(attach.classify(&c, i) == .attachable, c.exitAttachable(i));
    }
    // A trace with no exit snapshots is built with no bits at all.
    var c = f.code();
    c.exit_snapshots = &.{};
    attach.buildMemo(testing.allocator, &c);
    try testing.expect(c.exit_attach_built);
    try testing.expectEqual(@as(usize, 0), c.exit_attach.len);
    try testing.expect(!c.exitAttachable(E_ADD));
}

test "doc 56 attach: the resume classes of the ops the rules lean on" {
    try testing.expectEqual(attach.ResumeClass.flush_store, attach.resumeClass(.astore));
    try testing.expectEqual(attach.ResumeClass.flush_store, attach.resumeClass(.ustore));
    try testing.expectEqual(attach.ResumeClass.effect, attach.resumeClass(.sgm_setpos));
    try testing.expectEqual(attach.ResumeClass.effect, attach.resumeClass(.tnew));
    try testing.expectEqual(attach.ResumeClass.structural, attach.resumeClass(.phi));
    try testing.expectEqual(attach.ResumeClass.neutral, attach.resumeClass(.smatch));
    try testing.expectEqual(attach.ResumeClass.neutral, attach.resumeClass(.guard_bounds));
}
