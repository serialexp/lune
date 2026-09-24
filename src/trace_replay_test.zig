//! Tests for `trace.zig` — replay.
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
const trace_exec = @import("trace_exec.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

const AnchorKey = trace.AnchorKey;
const EntryGuard = trace.EntryGuard;
const ExitKey = trace.ExitKey;
const ExitProvEntry = trace.ExitProvEntry;
const ExitProvenance = trace.ExitProvenance;
const IrInstr = trace.IrInstr;
const Polarity = trace.Polarity;
const ProgramPoint = trace.ProgramPoint;
const RegionId = trace.RegionId;
const RegionKey = trace.RegionKey;
const StructuralEdgeId = trace.StructuralEdgeId;
const Trace = trace.Trace;
const TraceState = trace.TraceState;
const isLoopDoneGuardIndex = trace.isLoopDoneGuardIndex;
const readCycles = trace.readCycles;

const util = @import("trace_testutil.zig");
const TestRegs = util.TestRegs;

test "armNativeLink: P-C option (b) invariant — arm kind matches slot guard shape" {
    // 2.3c-0a: a numeric-for loop-done guard's slot is EXCLUSIVELY its linked-
    // materialized exit. `armNativeLink` enforces that the caller's declared `ArmKind`
    // matches the slot's guard shape: only `.loop_done_linked` may target a loop-done
    // slot, and `.ordinary_guard`/`.link_terminal` may target a non-loop-done one.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A proto whose code[0] is a `for_loop` and code[1] is not: a `guard_true` deopting
    // to pc 1 (== the instruction AFTER the for_loop) is a numeric-for loop-done guard,
    // while one deopting to pc 2 (after a non-for_loop) is an ordinary guard.
    const proto = Proto{ .code = &.{ Instr.op0(.for_loop), Instr.op0(.ret) }, .name = "t", .num_registers = 2 };

    // Production shape: exactly one slot per IR instr (no reserved trailing cell — the
    // loop-done ordinary deopt reaches `shared_exit` via `NativeResult.exit_target`, not
    // a slot). instr 0 = loop-done guard (exit_pc 1); instr 1 = ordinary guard (exit_pc 2).
    const pinstrs = try gpa.alloc(IrInstr, 2);
    defer gpa.free(pinstrs);
    pinstrs[0] = .{ .op = .guard_true, .aux = 1 };
    pinstrs[1] = .{ .op = .guard_true, .aux = 2 };
    const parent_slots = try gpa.alloc(usize, pinstrs.len);
    defer gpa.free(parent_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(parent_slots, 0);
    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 0 },
            .instrs = pinstrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .code = .{
            .anchor = undefined,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .native = .{ .compiled = .{ .page = undefined, .slots = &.{}, .gpa = gpa, .linked_entry = 0x5678, .ordinary_entry = 0x1234 } },
    };

    // Classifier: slot 0 IS a loop-done guard; slot 1 (ordinary guard) is not.
    try testing.expect(isLoopDoneGuardIndex(&parent, 0));
    try testing.expect(!isLoopDoneGuardIndex(&parent, 1));

    // The loop-done slot accepts only a `.loop_done_linked` arm.
    const ORDINARY_ENTRY: usize = 0x1234;
    try testing.expect(try state.armNativeLink(&parent, 0, &child, .loop_done_linked));
    try testing.expectEqual(ORDINARY_ENTRY, parent_slots[0]);

    // The non-loop-done slot accepts an ordinary-guard arm (and never a loop-done one).
    try testing.expect(try state.armNativeLink(&parent, 1, &child, .ordinary_guard));
    try testing.expectEqual(ORDINARY_ENTRY, parent_slots[1]);

    // An index at/past `slots.len` (== instrs.len) is out of range for EVERY arm kind —
    // there is no reserved off-table cell to accidentally address (blocker-2 fix).
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, .ordinary_guard));
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, .link_terminal));
    try testing.expect(!try state.armNativeLink(&parent, 2, &child, .loop_done_linked));

    // Complete region proof publication and identical re-arm refresh both stay
    // inside the arm owner; policy never edits an already-published row.
    const links = @import("trace_link.zig");
    const rid: trace.RegionId = @enumFromInt(71);
    try testing.expect(try links.arm(&state, .{
        .parent = &parent,
        .slot_index = 1,
        .child = &child,
        .kind = .region_bridge,
        .region = .{ .id = rid, .generation = 4 },
    }));
    try testing.expectEqual(@as(?trace.RegionId, rid), state.registry.native_physical.armed_links.items[1].region_id);
    try testing.expectEqual(@as(u32, 4), state.registry.native_physical.armed_links.items[1].armed_gen);
    try testing.expect(try links.arm(&state, .{
        .parent = &parent,
        .slot_index = 1,
        .child = &child,
        .kind = .region_bridge,
        .region = .{ .id = rid, .generation = 5 },
    }));
    try testing.expectEqual(@as(usize, 2), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(u32, 5), state.registry.native_physical.armed_links.items[1].armed_gen);
    try testing.expectEqual(ORDINARY_ENTRY, parent_slots[1]);
    // Same generation, different proof: never retain a memo stamped for the
    // previous region merely because the executable target is unchanged.
    state.registry.native_physical.armed_links.items[1].bridge_edge_gen = 5;
    try testing.expect(try links.arm(&state, .{
        .parent = &parent,
        .slot_index = 1,
        .child = &child,
        .kind = .region_bridge,
        .region = .{ .id = @enumFromInt(72), .generation = 5 },
    }));
    try testing.expectEqual(@as(u32, 0), state.registry.native_physical.armed_links.items[1].bridge_edge_gen);
    try testing.expectEqual(@as(usize, 2), state.registry.native_physical.armed_links.items.len);
    try testing.expect(!try links.arm(&state, .{
        .parent = &parent,
        .slot_index = 1,
        .child = &child,
        .kind = .ordinary_guard,
        .region = .{ .id = rid, .generation = 6 },
    }));
    try testing.expectEqual(@as(u32, 5), state.registry.native_physical.armed_links.items[1].armed_gen);

    // Reset so the leak-checked registry is empty at deinit.
    state.resetLinksTouching(&child);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
}

test "replayLedger M1 sub-case (c): fused [skip.deopt, ramp.prologue_fail] replays the unarmed steering" {
    // 2c-E: an M1-armed source-branch guard jumped skip → ramp, and the ramp's
    // HOISTED entry-type prologue failed pre-commit. `replayLedger` must replay the
    // unarmed native steering exactly: charge the skip's own committed count
    // (onSideExit(skip, local)), charge the ramp's zero-progress entry
    // (onSideExit(ramp, 0)), and resume at the skip's anchor header — WITHOUT
    // retrying further candidates (the native tier's flushed_resume_pc short-circuit;
    // codex 2c-E ruling: sub-case (c) is a (b)-analog).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces: never destroy()

    // proto.code[1] is NOT a for_loop, so skip's guard_true (exit_pc 2) classifies as
    // a source-branch guard, never a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.ret) }, .name = "t", .num_registers = 1 };

    // The skip trace: a directly-dispatched loop trace at the outer header (pc 10)
    // whose instr 0 is the armed source-branch guard. Compiled stub so the M1 arm's
    // provenance record can exist (`armNativeLink` requires a slot table).
    const skip_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // source-branch guard, exit_pc 2
        .{ .op = .loop },
    };
    const skip_slots = try gpa.alloc(usize, skip_instrs.len);
    defer gpa.free(skip_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(skip_slots, 0);
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&skip_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 101,
        .native = .{ .compiled = .{ .page = undefined, .slots = skip_slots, .gpa = gpa } },
    };
    // The prime-side entry ramp: same anchor (skip + ramp coexist at the outer
    // header), ends in `.link` (sub-case (c) validates the ramp shape).
    const ramp_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&ramp_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 102,
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xBEEF } },
    };
    try state.registry.cache.append(gpa, &skip);
    try state.registry.cache.append(gpa, &ramp);

    // Establish the M1 armed-edge provenance the fused `.deopt` validation demands.
    try testing.expect(try state.armNativeLink(&skip, 0, &ramp, .ordinary_guard));

    // The fused receipt: skip committed 9 iterations then its armed guard fired
    // (`.deopt`, non-last), the ramp's prologue failed pre-commit (cum unchanged).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 9, .id = 101, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 9, .id = 102, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&skip, &entries, &proto, tr_regs.view(), false);

    // Terminal receipt: nothing chain-committed, resume at the skip's own header.
    try testing.expectEqual(@as(usize, 0), r.completed);
    try testing.expectEqual(@as(?u32, 10), r.resume_pc);
    // onSideExit(skip, 9): 9 >= min_useful(8) → useful entry, hit_count bumped.
    try testing.expectEqual(@as(u64, 1), skip.hit_count);
    // The ramp refused before entering its body: candidate-local evidence only,
    // so the shared outer-header anchor remains unpenalized.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 10 }));
    try testing.expectEqual(@as(u32, 1), ramp.consec_refusals);
    // The fused M1 recognition fired exactly once; no `.link` marker was replayed.
    try testing.expectEqual(@as(u64, 1), state.native_source_link_fused);
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
}

test "replayLedger dispatcher grammar: [I.loop_done_linked, C.prologue_fail] commits the loop-done, breaks the burst" {
    // 2c-E (dispatcher gate widening): once I.loopdone → C.ordinary_entry is armed,
    // a dispatcher-rooted native run of the inner can fuse into a continuation whose
    // hoisted prologue then fails. The loop-done COMMITTED (linked materialization),
    // so the receipt must carry completed == 1 and resume at the continuation anchor;
    // the continuation's pre-commit prologue-fail terminates the burst with no
    // phantom charge on the continuation.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The inner root at pc 5: ends `.loop`, instr 0 is the loop-done guard.
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 201,
    };
    // The continuation at the post-loop pc 2: zero-input, ends `.link` back to pc 5.
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 202,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // One committed enclosing iteration (cum 0→1), then the fused continuation's
    // prologue failed pre-commit (cum unchanged).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 201, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 202, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);

    // The loop-done committed: one enclosing iteration, coherent at the continuation
    // anchor (pc 2) — the prologue-fail must NOT erase that progress.
    try testing.expectEqual(@as(usize, 1), r.completed);
    try testing.expectEqual(@as(?u32, 2), r.resume_pc);
    // onSideExit(inner, 1): PRODUCTIVE (completed=1) — under the Pall hotexit
    // model a productive segment is never a strike, however short (only
    // zero-progress entries strike; hot exits spawn side traces instead).
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 5 }));
    // The continuation's pre-commit fail takes NO onSideExit (break_burst tail).
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    // No `.link` marker in this grammar.
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
}

test "replayLedger M1 sub-case (d): fused [skip.deopt, ramp.seed_capacity_decline] resumes with NO strike" {
    // Doc 22 §B.2 (B-iv.2, codex Q2): the same fused M1 shape as sub-case (c)
    // above, but the ramp is a SEEDED page whose entry seeding DECLINED
    // (capacity) after the armed jump — pre-commit, cum unchanged. The contract
    // is "resume deterministic selection at the source's anchor" with NO
    // receipt, strike, side-exit accounting, or chain source for the decline.
    // The decisive difference from (c): its `onSideExit(ramp, 0)` puts one
    // penalty on the shared anchor; a decline must leave the penalty map EMPTY.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces: never destroy()

    // proto.code[1] is NOT a for_loop → skip's guard_true (exit_pc 2) is a
    // source-branch guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.ret) }, .name = "t", .num_registers = 1 };

    const skip_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // source-branch guard, exit_pc 2
        .{ .op = .loop },
    };
    const skip_slots = try gpa.alloc(usize, skip_instrs.len);
    defer gpa.free(skip_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(skip_slots, 0);
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&skip_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 111,
        .native = .{ .compiled = .{ .page = undefined, .slots = skip_slots, .gpa = gpa } },
    };
    const ramp_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var ramp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&ramp_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 112,
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xBEEF } },
    };
    try state.registry.cache.append(gpa, &skip);
    try state.registry.cache.append(gpa, &ramp);

    try testing.expect(try state.armNativeLink(&skip, 0, &ramp, .ordinary_guard));

    // skip committed 9 iterations, its armed guard fired, the ramp's SEEDED
    // entry declined pre-commit (cum unchanged, exit == maxInt sentinel).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 9, .id = 111, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        .{ .cum = 9, .id = 112, .exit = std.math.maxInt(u32), .reason = .seed_capacity_decline, .kind = .seed_capacity_decline, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&skip, &entries, &proto, tr_regs.view(), false);

    // Terminal receipt: nothing chain-committed, resume at the skip's own header.
    try testing.expectEqual(@as(usize, 0), r.completed);
    try testing.expectEqual(@as(?u32, 10), r.resume_pc);
    // The skip's OWN 9 committed iterations still account (accountLedgerRow):
    // 9 >= min_useful(8) → useful entry, hit_count bumped.
    try testing.expectEqual(@as(u64, 1), skip.hit_count);
    // NO strike anywhere: the decline suppresses (c)'s `onSideExit(ramp, 0)`.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 10 }));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    // The fused M1 recognition fired exactly once; no `.link` marker replayed.
    try testing.expectEqual(@as(u64, 1), state.native_source_link_fused);
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
}

test "replayLedger dispatcher grammar: [I.loop_done_linked, C.seed_hash_decline] commits the loop-done, breaks the burst chargeless" {
    // Doc 22 §B.2 (B-iv.2): the seeded continuation analog of the
    // `[I.loop_done_linked, C.prologue_fail]` grammar above — the fused
    // continuation's SEEDED entry declined (hash mismatch) pre-commit. The
    // committed loop-done must survive (completed == 1, coherent at the
    // continuation anchor) and the decline must charge NOTHING (the
    // prologue-fail variant is also chargeless via break_burst; here the
    // chargelessness is the decline arm's own contract).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 211,
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 212,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // One committed enclosing iteration (cum 0→1), then the fused continuation's
    // seeded entry declined pre-commit (cum unchanged).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 211, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 212, .exit = std.math.maxInt(u32), .reason = .seed_hash_decline, .kind = .seed_hash_decline, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);

    // The loop-done committed; the decline must not erase that progress.
    try testing.expectEqual(@as(usize, 1), r.completed);
    try testing.expectEqual(@as(?u32, 2), r.resume_pc);
    // Chargeless end to end: no strike on either anchor.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 5 }));
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    // The fused `I.loopdone → C` edge still drained through the non-last arm.
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_fused);
    // No `.link` marker in this grammar.
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
}

test "B-iii: a tier-1a seed decline ends the burst chargeless (no strike on the burst seed)" {
    // The DRIVER-level half of the same contract the directive test below pins.
    // `replayLedger` is the native leg's decline path; the tier-1a leg declines
    // at `driveBurstCore`'s call-A seeding seam instead, and that seam used a
    // bare `break` — which falls into the zero-progress tail's
    // `onSideExit(seed, 0)` and strikes the burst SEED.
    //
    // Two things wrong with that, both invisible to the stdout oracle:
    //   1. It contradicts B-iv.2's "a decline gets no receipt, no strike" — the
    //      inner never ran, so nothing about `S` was disproved.
    //   2. It is a native-vs-tier-1a DIVERGENCE in the penalty map. The native
    //      twin returns chargeless for the identical event, so the
    //      `record_execute` and `record_execute_native` legs made different
    //      tiering decisions from the same input — exactly what the tail's own
    //      "Mode-invariant: ... no mode records a different penalty here"
    //      comment claims cannot happen.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // `code[1]` is the `for_loop`; the inner root is anchored at pc 7.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The burst seed: an UNSEEDED continuation, so nothing about `S` itself can
    // decline. Any strike observed therefore came from the inner's decline.
    const seed_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 7 },
    };
    var seed_trace: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&seed_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 231,
    };
    // The inner root the `.link` names — SEEDED, so call A must seed it before
    // entry. `native_seed_ctx` is left null, so `seedForTier1a` fails closed.
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 },
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 232,
    };
    inner.code.inputs = @constCast(&[_]trace.InputSeed{undefined});
    try state.registry.cache.append(gpa, &seed_trace);
    try state.registry.cache.append(gpa, &inner);
    try testing.expect(state.registry.native_seed_ctx == null);

    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    // `.ir` tier never dereferences the compiled-trace argument, and
    // `sresult_fused = false` means `sresult` is dropped on the floor
    // (fusion is native-only).
    const unused_ct: *const nativegen.CompiledTrace = undefined;
    const r = state.runLinkedBurst(
        &seed_trace,
        undefined,
        false,
        unused_ct,
        .ir,
        .ordinary_header,
        &proto,
        tr_regs.view(),
        false,
    );

    // Zero progress (the inner never entered), resuming coherently at the
    // inner-root PC the `.link` names — same as the pre-fix `break` produced.
    try testing.expectEqual(@as(usize, 0), r.completed);
    try testing.expectEqual(@as(?u32, 7), r.resume_pc);
    // The whole point: NO strike anywhere. Pre-fix this was one strike on the
    // seed's anchor at pc 2.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
}

test "replayLedger terminal seed-decline: a CONTINUATION decline is a chargeless directive, not .break_burst" {
    // The directive-level twin of the dispatcher-grammar test above. That one
    // goes through `driveDispatcherLedger`, which happens to reach the SAME
    // observable end state via `.break_burst` + the hop-0 tail, so it cannot
    // distinguish the two directives. This one asserts the directive itself.
    //
    // Why it matters: `.break_burst` is the zero-progress GUARD signal, and
    // three of its five consumers end in `onSideExit(seed, 0)` — a strike on
    // the burst SEED. When the seed IS the decliner (as in the single-hop
    // dispatcher shape above) that strike is merely misattributed-but-local;
    // in a `C1 → I → C2` span the decliner is C2 and the seed is C1, so an
    // innocent trace takes it. A decline is an entry-condition mismatch, not a
    // guard failure: B-iv.2's contract is "no receipt, no strike".
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 221,
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 222,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // One committed enclosing iteration, then the fused continuation's seeded
    // entry declined pre-commit (cum unchanged → local == 0, `ends_link`).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 221, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 222, .exit = std.math.maxInt(u32), .reason = .seed_hash_decline, .kind = .seed_hash_decline, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(
        &entries,
        &inner,
        5,
        &proto,
        &linked_completed,
        &resume_pc,
        &hops,
        8,
        .dispatcher_root,
        false,
        null,
    );

    // The directive itself: a terminal result, NOT `.break_burst`.
    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    // The committed loop-done survives, coherent at the decliner's own anchor.
    try testing.expectEqual(@as(usize, 1), result.completed);
    try testing.expectEqual(cont.code.anchor.pc, result.resume_pc);
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
}

test "replayLedger terminal seed-decline: [C.link_terminal, I.seed_hash_decline] resumes at the decliner's own anchor" {
    // Doc 22 §B.2 (B-iv.2): a hop-0 fused span — C reached its `.link` terminal
    // (fused into the inner root), and the SEEDED inner's entry declined
    // pre-commit. The linked-inner decline arm resumes tier-0 at the decliner's
    // OWN anchor (== the `.link` target the cursor carries; the arm
    // release-asserts the two agree), zero progress, no strike on either anchor.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The seed continuation at pc 2: a bare `.link` terminal to the inner root
    // at pc 7 (exit index 0 == instrs.len - 1, the link_terminal contract).
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 311,
    };
    // The inner root at pc 7: zero inputs, ends `.loop` (isInnerLoopRoot).
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 312,
    };
    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &inner);

    // C's `.link` fused into I (cum 0), whose seeded entry then declined
    // pre-commit (cum unchanged).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 0, .id = 311, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 0, .id = 312, .exit = std.math.maxInt(u32), .reason = .seed_hash_decline, .kind = .seed_hash_decline, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(
        &entries,
        &cont,
        7,
        &proto,
        &linked_completed,
        &resume_pc,
        &hops,
        8,
        .dispatcher_root,
        false,
        null,
    );

    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    // Zero progress, coherent at the decliner's own anchor (the inner root).
    try testing.expectEqual(@as(usize, 0), result.completed);
    try testing.expectEqual(@as(u32, 7), result.resume_pc);
    // Exactly one `.link` marker (the link_terminal arm's bump) and one fused
    // C→I follow — the walk itself stays accounting-exact.
    try testing.expectEqual(@as(u64, 1), state.native_link_exits);
    try testing.expectEqual(@as(u64, 1), state.native_link_follow_count);
    // The decline itself charges nothing on either anchor.
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
}

test "replayLedger A-vii-c.1: rows a live region CONSUMES take no legacy strike (no double charge)" {
    // The A-vii-c.1 re-review blocker: `replayLedger` accounts a region receipt per
    // row and then, in the kind arms, took a per-trace selection receipt through
    // `onSideExit` — which unconditionally applies the legacy verdict. Once an
    // armable region exists, a consumed row would be charged by BOTH machines. The
    // arms now go through `accountLedgerRow`, which honours the row's own
    // `region_consumed`. This is the positive control; the
    // `[I.loop_done_linked, C.prologue_fail]` grammar test above is the negative one
    // (no region ⇒ the identical shape still strikes).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .id = 77, .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 201,
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 9 }, // an own guard: the `.deopt` exit
        .{ .op = .link, .aux = 5 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 202,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // A live ARMABLE region owning both anchors' exits. Both rows must classify to
    // the SAME region (a different one would close the active accumulator), and the
    // first row's destination (202) must be indexed too or `applyDestination` closes
    // the region as a departure.
    const owner: AnchorKey = .{ .proto = &proto, .pc = 5 };
    const rid: RegionId = @enumFromInt(11);
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{ .{ .proto_id = 77, .source_pc = 5 }, .{ .proto_id = 77, .source_pc = 2 } }),
        .owner = owner,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });
    try state.region_policy.source_exit_regions.put(gpa, .{ .trace_id = 201, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    try state.region_policy.source_exit_regions.put(gpa, .{ .trace_id = 202, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    try state.region_policy.dest_entry_regions.put(gpa, 202, try gpa.dupe(RegionId, &.{rid}));
    // Doc 55 §2 invariant: arrival ⊇ dest (the destination step reads arrival).
    try state.region_policy.arrival_entry_regions.put(gpa, 202, try gpa.dupe(RegionId, &.{rid}));
    state.setRegionContext(1, 5);

    // [I.loop_done_linked (work 1), C.deopt local=3 (work 3)] — both sub-min_useful,
    // so the PRE-flip machine would have struck both anchors.
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 201, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 4, .id = 202, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);
    try testing.expectEqual(@as(usize, 4), r.completed);

    // Both rows were consumed by the region window machine, so NEITHER anchor took a
    // legacy strike — the double-charge the re-review caught.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    // ...and the work really landed on the region: 1 + 3 traversals, still short of
    // the N=8 window, so no flush yet.
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };
    try testing.expectEqual(@as(u64, 4), state.region_policy.region_profit.get(key).?.outer_traversals);
    try testing.expectEqual(@as(u64, 0), state.region_policy.region_profit_flushes);
    // Selection still moved per segment on both traces.
    try testing.expectEqual(@as(u64, 0), inner.hit_count); // 1 < min_useful
    try testing.expectEqual(@as(u64, 0), cont.hit_count); // 3 < min_useful
}

test "driveSeedLedger: a deep hop-0 ledger [C.link, I.done, C.deopt] charges each transition exactly once" {
    // 2c-E (hop-0 >2 split): a chain candidate's FIRST run fused `.link → inner →
    // continuation-deopt` in one native call. `driveSeedLedger` must hand the whole
    // span to `replayLedger` with NO wrapper `native_link_exits` precharge — the
    // `.link_terminal` arm owns exactly one bump per marker — and the terminal
    // continuation deopt must roll its own local count into the receipt.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The seed continuation at pc 2: an own guard (the k=2 terminal deopt names it)
    // then the `.link` terminal to the inner root at pc 7.
    const cont_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 9 }, // C's own source-branch guard
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 301,
    };
    // The inner root at pc 7: ends `.loop`, loop-done guard exits to pc 2 (== C's anchor).
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 302,
    };
    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &inner);

    // C reached `.link` (cum 0), the fused inner committed one enclosing iteration
    // (cum 1), the re-entered C advanced twice more then deopted at its own guard
    // (cum 3, local 2).
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 0, .id = 301, .exit = 1, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 1, .id = 302, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 3, .id = 301, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveSeedLedger(&cont, &entries, &proto, tr_regs.view(), false, .native_numeric_for_done);

    // Terminal continuation deopt with local 2: completed = linked_completed(1) + 2,
    // resume at the loop-done's post-loop pc (the continuation anchor, 2).
    try testing.expectEqual(@as(usize, 3), r.completed);
    try testing.expectEqual(@as(?u32, 2), r.resume_pc);
    // EXACTLY one `native_link_exits` — the seed's own `.link` marker, charged by the
    // replay's `.link_terminal` arm. A wrapper precharge would make this 2.
    try testing.expectEqual(@as(u64, 1), state.native_link_exits);
    // Not a coherent-anchor (prime-side) entry: no chain-follow firing signal.
    try testing.expectEqual(@as(u64, 0), state.prime_side_chain_follows);
    // onSideExit(inner, 1) and onSideExit(cont, 2): both PRODUCTIVE — under the
    // Pall hotexit model neither strikes (only zero-progress entries do).
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 7 }));
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
}

test "jit coverage: per-hop cycles bill each hop's own anchor, never the entry anchor" {
    // The load-bearing anti-misattribution guarantee. A chain runs several hops
    // through `onSideExit`, each with its OWN anchor. Before the per-hop fix the
    // whole trace-exec span was charged to the *entry* anchor, so inner/continuation
    // anchors got iterations but zero cycles — the time split was untrustworthy.
    // This drives two hops at DISTINCT anchors with a cycle-burning spin *between*
    // them and asserts each anchor is billed its own span (both strictly > 0) and
    // the aggregate is exactly the sum — proving hop B's cycles land on anchor B,
    // not lumped onto entry anchor A.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.coverage = true;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 1 };

    // Minimal traces: `onSideExit` touches only `t.code.anchor` and `t.hit_count`.
    var entry = [_]u16{0};
    const instrs = [_]IrInstr{.{ .op = .loop }};
    const consts = [_]Value{};
    const trace_a = try gpa.create(Trace);
    defer gpa.destroy(trace_a);
    trace_a.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&instrs),
            .consts = @constCast(&consts),
            .entry_slots = &entry,
            .entry_guards = &.{},
        },
    };
    const trace_b = try gpa.create(Trace);
    defer gpa.destroy(trace_b);
    trace_b.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 }, // DISTINCT anchor
            .instrs = @constCast(&instrs),
            .consts = @constCast(&consts),
            .entry_slots = &entry,
            .entry_guards = &.{},
        },
    };

    const is_x86 = @import("builtin").target.cpu.arch == .x86_64;
    // Spin until rdtsc has advanced by `min` cycles — guarantees a strictly
    // positive span on x86_64; a no-op elsewhere (readCycles is 0 there).
    const spin = struct {
        fn burn(min: u64) void {
            if (@import("builtin").target.cpu.arch != .x86_64) return;
            const start = readCycles();
            while (readCycles() -% start < min) {}
        }
    }.burn;

    // Establish the hop boundary; the span up to onSideExit(A) bills anchor A.
    state.last_hop_tsc = readCycles();
    spin(4000);
    state.onSideExit(trace_a, 5, .entered);
    // The span between the two commits bills anchor B, not A.
    spin(4000);
    state.onSideExit(trace_b, 3, .entered);

    const cov_a = state.coverage.get(.{ .proto = &proto, .pc = 10 }).?;
    const cov_b = state.coverage.get(.{ .proto = &proto, .pc = 20 }).?;

    // Iterations: each hop bills its OWN committed count to its OWN anchor.
    try testing.expectEqual(@as(u64, 5), cov_a.traced);
    try testing.expectEqual(@as(u64, 3), cov_b.traced);
    try testing.expectEqual(@as(u64, 8), state.iters_traced);

    if (is_x86) {
        // Anti-misattribution: hop B's cycles landed on anchor B, not on entry A.
        // Both anchors carry a strictly positive, independently-earned span.
        try testing.expect(cov_a.traced_cycles > 0);
        try testing.expect(cov_b.traced_cycles > 0);
        // No cycles leaked or double-charged: aggregate == sum of per-anchor.
        try testing.expectEqual(
            state.cycles_traced,
            cov_a.traced_cycles + cov_b.traced_cycles,
        );
    }
}

test "driveBurstCore start_at_continuation: a run_continuation handover does not re-run the inner (real native)" {
    // 2c-E (the dormant double-run fix): a `replayLedger` terminal `run_continuation`
    // means the span's LAST inner loop-done already committed. The handed-over burst
    // must enter at call B (run the continuation) and SKIP call A — entering call A
    // first would try to run the inner again before the continuation. Proven with a
    // REAL native continuation: the correct path runs C exactly once (its register
    // effect is observable) and then breaks at the hop top when the inner has no
    // native code; the buggy call-A-first path would break BEFORE C ever ran.
    const builtin = @import("builtin");
    if (comptime !(builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // code[1] IS a for_loop: the inner's guard_true (exit_pc 2) is a loop-done guard.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    // The inner root at pc 7 — deliberately NATIVE-UNCOMPILABLE (an `add` on an
    // unproven operand bails codegen), so the hop top's `nativeFor(inner) orelse
    // break` ends the burst right after the continuation runs.
    const inner_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 0 }, // no covering guard_int → codegen bails
        .{ .op = .guard_true, .a = 1, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 401,
    };
    // The continuation at pc 2 — genuinely compilable: r0 += 1 then `.link` to pc 7.
    // Its register effect (+1 on r0) is the witness that C ran exactly once.
    const cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .guard_int, .a = 0 }, // %1
        .{ .op = .konst, .aux = 0 }, // %2: 1
        .{ .op = .add, .a = 0, .b = 2 }, // %3: r0 + 1
        .{ .op = .phi, .b = 3, .aux = 0 }, // %4: r0 ← r0+1
        .{ .op = .link, .aux = 7 }, // %5
    };
    const cont_consts = [_]Value{Value.int(1)};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = @constCast(&cont_consts),
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 402,
    };
    defer cont.native.deinit(); // lazily compiled below; free before the arena dies
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // A dispatcher-rooted span ending in a committed-but-unfused inner loop-done:
    // [I.done, C.link, I.done] → replay returns run_continuation(C) with hops=2 and
    // the burst enters at call B.
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 401, .exit = 2, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 402, .exit = 5, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 2, .id = 401, .exit = 2, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(5)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);
    tr_regs.commit();

    // C ran natively EXACTLY once: r0 advanced 5 → 6. The buggy call-A-first path
    // breaks on `nativeFor(inner) == null` before C runs, leaving r0 == 5 (and would
    // report resume_pc == 2 instead of the post-C inner-root pc 7).
    try testing.expectEqual(@as(i64, 6), regs[0].asInt());
    // Replay committed 2 enclosing iterations; C's standalone `.link` then steered
    // `run_inner_from` → hop top → inner has no native code → burst ends at pc 7.
    try testing.expectEqual(@as(usize, 2), r.completed);
    try testing.expectEqual(@as(?u32, 7), r.resume_pc);
    // Two `.link` markers total: the synthetic k=1 entry + C's real native run.
    try testing.expectEqual(@as(u64, 2), state.native_link_exits);
    // Two continuation→inner follows: the fused `C.link → I` edge inside the
    // replayed span (2c-E: the non-last `.link_terminal` arm charges it, mirroring
    // the physical hop top) + the hop top resolving the inner once (the post-C hop).
    try testing.expectEqual(@as(u64, 2), state.native_link_follow_count);
    // The fused `I.loopdone → C` edge (entry 0 → 1) drained through the non-last
    // `.loop_done_linked` arm — the consumer-side counter fires even though nothing
    // was armed by THIS test (the ledger is synthetic).
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_fused);
    // The inner's codegen verdict memoized as unsupported (that's what ended the burst).
    try testing.expect(inner.native == .unsupported);
    // Both inner loop-dones were PRODUCTIVE receipts — under the Pall hotexit
    // model neither strikes the inner anchor.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 7 }));
}

test "replayLedger A-vii-a: region_bridge validates registered cross-anchor edge and accounts selection" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // traces are stack-owned
    state.config.min_useful = 3;

    // The composite guard names bytecode exit PC 14, deliberately distinct from
    // the registered skip anchor PC 20. A successful result at 20 therefore proves
    // replay derived its coherent cursor from RegionDef, not guardExitPc.
    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    const proto = Proto{ .id = 41, .code = &code, .name = "region-bridge-replay", .num_registers = 1 };
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
        .id = 601,
    };
    var skip_instrs = [_]IrInstr{
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &skip_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 602,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont.code, 3));
    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &skip);

    // Synthesize the otherwise-unreachable A-vii-a inputs directly: the physical
    // backlink and the persistent registered edge. Missing, duplicate, tombstoned,
    // or successor-mismatched variants are explicit release-@panic branches in the
    // replay arm; this Zig stdlib has no in-process panic-expectation test helper.
    const rid: RegionId = @enumFromInt(91);
    try state.registry.native_physical.armed_links.append(gpa, .{ .parent = &cont, .slot_index = 3, .child = &skip, .kind = .region_bridge, .region_id = rid });
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = cont.code.anchor.pc,
            .exit = guard_prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = skip.code.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{}),
        .owner = cont.code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });

    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
        .{ .cum = 5, .id = skip.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(
        &entries,
        &cont,
        7,
        &proto,
        &linked_completed,
        &resume_pc,
        &hops,
        8,
        .dispatcher_root,
        false,
        null,
    );

    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(u32, 20), result.resume_pc);
    try testing.expectEqual(@as(usize, 2), result.completed);
    try testing.expectEqual(@as(u32, 20), resume_pc);
    // local=3 is nonzero and reaches accountTraceRun(cont, 3): at N=3 it is a
    // useful selection completion, so the owner gains exactly one hit and no
    // low-yield penalty. The terminal skip's own local=2 is short but PRODUCTIVE
    // — under the Pall hotexit model it does not strike either.
    try testing.expectEqual(@as(u64, 1), cont.hit_count);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(cont.code.anchor));
    try testing.expectEqual(@as(?u32, null), state.penalty.get(skip.code.anchor));
}

test "A-vii-d.1 overlay: composite guard resolves the opposite-polarity CFG successor (jmp walk, polarity flip, self-edge decline)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // Static CFG: jmp_if_true at 5 (jump target 6+4=10); fallthrough pc 6 is an
    // unconditional jmp to 8. A recorded-`.taken` composite guard therefore fails
    // onto the FALLTHROUGH edge (6 → jmp → 8); a recorded-`.fallthrough` one onto
    // the JUMP edge (10). No trace is bound at the H-1b exit pc 6, so the
    // ordinary `guardExitPc` rule yields nothing — only the overlay resolves.
    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 4);
    code[6] = Instr.opAx(.jmp, 0, 1);
    const proto = Proto{ .id = 51, .code = &code, .name = "overlay", .num_registers = 1 };

    const mkProv = struct {
        fn f(p: Polarity) ExitProvenance {
            return .{ .guard = .{
                .source_proto_id = 51,
                .source_pc = 5,
                .role = .branch_cond,
                .operand = .a,
                .polarity = p,
            } };
        }
    }.f;
    var taken_prov = [_]ExitProvEntry{.{ .index = 3, .prov = mkProv(.taken) }};
    var ft_prov = [_]ExitProvEntry{.{ .index = 3, .prov = mkProv(.fallthrough) }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 6 }, // exit pc 6 → source jmp_if at 5
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &taken_prov,
        },
        .id = 701,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont.code, 3));

    // No successor trace bound anywhere yet → both polarities decline.
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&cont, cont.code.exit_prov[0]));

    // Bind skip@8 (reached from the fallthrough edge via the jmp at 6).
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .loop } };
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 8 },
            .instrs = &skip_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 702,
    };
    try state.registry.cache.append(gpa, &skip);
    const succ_taken = state.resolveSuccessorAnchor(&cont, cont.code.exit_prov[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 51), succ_taken.proto_id);
    try testing.expectEqual(@as(u32, 8), succ_taken.pc);

    // Recorded `.fallthrough` fails onto the JUMP edge (pc 10) instead.
    var other_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .loop } };
    var other: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = &other_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 703,
    };
    try state.registry.cache.append(gpa, &other);
    cont.code.exit_prov = &ft_prov;
    const succ_ft = state.resolveSuccessorAnchor(&cont, cont.code.exit_prov[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 10), succ_ft.pc);

    // Self-edge decline: the same shape anchored at 8 walks 6 → jmp → 8 == its
    // own anchor — never a cross-anchor handoff.
    var selfy: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 8 },
            .instrs = &cont_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &taken_prov,
        },
        .id = 704,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&selfy.code, 3));
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&selfy, selfy.code.exit_prov[0]));
}

test "A-vii-d.1 overlay: a crossed for_loop is published ONLY under the exact-dataflow continue proof" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // jmp_if_true at 5; the fallthrough pc 6 is a numeric for_loop whose
    // continue edge lands at 6+1+2 = 9, where the successor trace is bound.
    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 10);
    code[6] = Instr.opAx(.for_loop, 0, 2); // base register a=0; continue target 9
    const proto = Proto{ .id = 52, .code = &code, .name = "overlay-forloop", .num_registers = 8 };

    const branch_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = 52,
        .source_pc = 5,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    const loopdone_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = 52,
        .source_pc = 6,
        .role = .loop_done,
        .operand = .a,
        .polarity = .neutral,
    } };

    // The exact recForLoop shape (proof-satisfying): one add (R=2) stepping the
    // index, a dominating loop-continue guard whose `le` consumes R, and
    // slot-bound phis for BOTH for_loop-written slots {a=0, a+3=3} sharing R.
    var good_prov = [_]ExitProvEntry{
        .{ .index = 4, .prov = loopdone_prov },
        .{ .index = 7, .prov = branch_prov },
    };
    var good_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0
        .{ .op = .konst, .aux = 0 }, // %1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = R
        .{ .op = .le, .a = 2, .b = 1 }, // %3 consumes R
        .{ .op = .guard_true, .a = 3, .aux = 7 }, // %4 loop-done (source pc 6)
        .{ .op = .phi, .b = 2, .aux = 0 }, // idx slot
        .{ .op = .phi, .b = 2, .aux = 3 }, // var slot, same R
        .{ .op = .guard_true, .a = 0, .aux = 6 }, // %7 composite (source pc 5)
        .{ .op = .link, .aux = 9 },
    };
    var good: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &good_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &good_prov,
        },
        .id = 711,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&good.code, 7));

    var skip_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .loop } };
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 9 },
            .instrs = &skip_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 712,
    };
    try state.registry.cache.append(gpa, &skip);

    const succ = state.resolveSuccessorAnchor(&good, good.code.exit_prov[1]) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 9), succ.pc);

    // Proof violation 1: the var slot's phi is missing (bound to a different
    // slot) — the crossed op's written set is not fully re-materialized.
    var noval_instrs = good_instrs;
    noval_instrs[6] = .{ .op = .phi, .b = 2, .aux = 4 }; // not base+3
    var noval: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &noval_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &good_prov,
        },
        .id = 713,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&noval.code, 7));
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&noval, noval.code.exit_prov[1]));

    // Proof violation 2: no dominating loop-continue guard consuming R (the
    // le compares a different ref) — the continue edge is unproven.
    var nocmp_instrs = good_instrs;
    nocmp_instrs[3] = .{ .op = .le, .a = 0, .b = 1 }; // consumes %0, not R
    var nocmp: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &nocmp_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &good_prov,
        },
        .id = 714,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&nocmp.code, 7));
    try testing.expectEqual(@as(?TraceState.SuccAnchor, null), state.resolveSuccessorAnchor(&nocmp, nocmp.code.exit_prov[1]));
}

test "A-vii-d.1 bridged successor terminal: a loop-body successor deopt resumes at ITS anchor, ordinary loop-done included" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();
    state.config.min_useful = 3;

    // Same wiring as the A-vii-a replay test, but the bridged successor ends
    // `.loop` — the REAL nsieve shape (an outer-header body trace), not the
    // synthetic `.link` skip. Its terminal deopt must resume at its OWN anchor
    // (the coherent-anchor discipline for ordinary-mode runs), never `link_pc`,
    // and an ordinary-mode loop-done deopt is legitimate (mode 0 bypasses the
    // linked slot).
    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    code[19] = Instr.opAx(.for_loop, 0, 2); // makes skip's guard a loop-done index
    const proto = Proto{ .id = 42, .code = &code, .name = "bridged-loop-succ", .num_registers = 1 };
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
        .id = 621,
    };
    // skip@25 ends `.loop`; its guard's exit pc 20 sits right after the
    // for_loop at 19 → `isLoopDoneGuardIndex` is TRUE for exit 0.
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_true, .a = 0, .aux = 20 }, .{ .op = .loop } };
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 25 },
            .instrs = &skip_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 622,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont.code, 3));
    try testing.expect(isLoopDoneGuardIndex(&skip, 0));
    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &skip);

    const rid: RegionId = @enumFromInt(92);
    try state.registry.native_physical.armed_links.append(gpa, .{ .parent = &cont, .slot_index = 3, .child = &skip, .kind = .region_bridge, .region_id = rid });
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = cont.code.anchor.pc,
            .exit = guard_prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = skip.code.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{}),
        .owner = cont.code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });

    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
        .{ .cum = 5, .id = skip.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false, null);
    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    // Resume at skip's OWN anchor (25) — the bridge row published it — with the
    // successor's committed local rolled up; `link_pc` (7) must never surface.
    try testing.expectEqual(@as(u32, 25), result.resume_pc);
    try testing.expectEqual(@as(usize, 2), result.completed);
    try testing.expectEqual(@as(u64, 1), state.native_region_bridge_fused);
}

test "A-vii-d.1 bridged .link successor (codex blocker): zero-progress deopt and prologue-fail return the bridged contract, never break_burst" {
    // A bridged successor ending `.link` is legal (bridge validation requires
    // zero inputs + ordinary_entry, not a `.loop` terminator). Its
    // zero-progress terminal rows must take the bridged contract — charge the
    // SUCCESSOR and resume at its anchor — never the seed-continuation
    // `break_burst`, whose hop-0 tail would charge the BRIDGE PARENT a second
    // time on top of the `.region_bridge` row's own accounting.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();
    state.config.min_useful = 3;

    var code: [30]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[13] = Instr.opAx(.jmp_if_true, 0, 0);
    const proto = Proto{ .id = 43, .code = &code, .name = "bridged-link-succ", .num_registers = 1 };
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
        .id = 631,
    };
    var skip_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .link, .aux = 7 } };
    var skip: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &skip_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 632,
    };
    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &skip);
    const rid: RegionId = @enumFromInt(93);
    try state.registry.native_physical.armed_links.append(gpa, .{ .parent = &cont, .slot_index = 3, .child = &skip, .kind = .region_bridge, .region_id = rid });
    try state.region_policy.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{.{
            .anchor_proto_id = proto.id,
            .anchor_pc = cont.code.anchor.pc,
            .exit = guard_prov,
            .succ_anchor_proto_id = proto.id,
            .succ_anchor_pc = skip.code.anchor.pc,
        }}),
        .member_points = try gpa.dupe(ProgramPoint, &.{}),
        .owner = cont.code.anchor,
        .classifier = .{ .kind = .cross_trace_cycle, .member_count = 2 },
        .armable = true,
    });

    // (a) Zero-progress deopt (cum unchanged across the successor segment).
    {
        const entries = [_]trace_exec.LedgerEntry{
            .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
            .{ .cum = 3, .id = skip.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
        };
        var linked_completed: usize = 0;
        var resume_pc: u32 = 999;
        var hops: usize = 0;
        const dir = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false, null);
        const result = switch (dir) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult, // break_burst = the bug
        };
        try testing.expectEqual(@as(u32, 20), result.resume_pc);
        try testing.expectEqual(@as(usize, 0), result.completed);
    }
    // (b) Prologue-fail (pre-commit, exit = maxInt, local == 0).
    {
        const entries = [_]trace_exec.LedgerEntry{
            .{ .cum = 3, .id = cont.id, .exit = 3, .reason = .normal, .kind = .region_bridge, .outcome = .normal },
            .{ .cum = 3, .id = skip.id, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
        };
        var linked_completed: usize = 0;
        var resume_pc: u32 = 999;
        var hops: usize = 0;
        const dir = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false, null);
        const result = switch (dir) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult, // break_burst = the bug
        };
        try testing.expectEqual(@as(u32, 20), result.resume_pc);
        try testing.expectEqual(@as(usize, 0), result.completed);
    }
    // The bridge parent was charged ONLY by its `.region_bridge` rows (useful
    // at N=3): no penalty ever lands on the parent anchor from the successor's
    // zero-progress terminals.
    try testing.expectEqual(@as(?u32, null), state.penalty.get(cont.code.anchor));
}

test "A-vii-d.1 disarm deferral: disarmAllLinks defers mid-replay-walk; applyPendingDisarms applies it and drops the pending arm" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "t", .num_registers = 1 };
    var p_i = [_]IrInstr{.{ .op = .loop }};
    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 0 },
            .instrs = &p_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 801,
    };
    var c_i = [_]IrInstr{.{ .op = .loop }};
    var child: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 0 },
            .instrs = &c_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 802,
    };
    try state.registry.native_physical.armed_links.append(gpa, .{ .parent = &parent, .slot_index = 0, .child = &child, .kind = .ordinary_guard });

    // Mid-walk: the registry must stay intact (later rows of the ledger being
    // walked validate against it) and the request must be recorded.
    state.registry.native_physical.enterReplayWalk();
    state.disarmAllLinks();
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    try testing.expect(state.registry.native_physical.pending_disarm_all);
    try testing.expectEqual(@as(u64, 0), state.registry.native_physical.native_link_disarms);

    // Driver-side application: registry cleared, counter charged, and any
    // pending bridge-arm request from the same walk dropped (fail-closed —
    // never disarm-then-re-arm into a complex the gate just condemned).
    state.registry.native_physical.exitReplayWalk();
    state.pending_bridge_arm = .{ .trace_id = 801, .exit_instr = 0 };
    state.applyPendingDisarms();
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expect(!state.registry.native_physical.pending_disarm_all);
    try testing.expectEqual(@as(?ExitKey, null), state.pending_bridge_arm);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.native_link_disarms);

    // Idempotent when nothing is pending.
    state.applyPendingDisarms();
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.native_link_disarms);
}

test "A-vii-d.1 stale-region lifecycle: a rebuild disarms region_bridge links whose region is no longer live-armable; other kinds survive" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "t", .num_registers = 1 };
    var p_i = [_]IrInstr{.{ .op = .loop }};
    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 0 },
            .instrs = &p_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 811,
    };
    var c_i = [_]IrInstr{.{ .op = .loop }};
    var child: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 0 },
            .instrs = &c_i,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 812,
    };

    // One bridge link armed under a region this pass will NOT re-discover
    // (empty cache → empty live-armable set) and one M1 link, which the
    // targeted sweep must never touch.
    try state.registry.native_physical.armed_links.append(gpa, .{ .parent = &parent, .slot_index = 0, .child = &child, .kind = .region_bridge, .region_id = @enumFromInt(9) });
    try state.registry.native_physical.armed_links.append(gpa, .{ .parent = &parent, .slot_index = 1, .child = &child, .kind = .ordinary_guard });

    state.rebuildRegions();
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    try testing.expect(state.registry.native_physical.armed_links.items[0].kind == .ordinary_guard);
    try testing.expectEqual(@as(u64, 1), state.registry.native_physical.native_link_disarms);
}

test "A-vii-d.1 two-phase arming: a terminal composite deopt records ONE pending arm request, never arms mid-walk" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    var code: [32]Instr = undefined;
    @memset(code[0..], Instr.op0(.halt));
    code[5] = Instr.opAx(.jmp_if_true, 0, 4);
    const proto = Proto{ .id = 53, .code = &code, .name = "pending-arm", .num_registers = 1 };
    const guard_prov: ExitProvenance = .{ .guard = .{
        .source_proto_id = proto.id,
        .source_pc = 5,
        .role = .branch_cond,
        .operand = .a,
        .polarity = .taken,
    } };
    var cont_prov = [_]ExitProvEntry{.{ .index = 3, .prov = guard_prov }};
    var cont_instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .guard_true, .a = 0, .aux = 6 },
        .{ .op = .phi, .b = 2, .aux = 0 },
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 20 },
            .instrs = &cont_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &cont_prov,
        },
        .id = 821,
    };
    try testing.expect(nativegen.isCompositeBridgeCandidate(&cont.code, 3));
    try state.registry.cache.append(gpa, &cont);

    // A terminal composite `.deopt` (the seed's OWN guard) must record the
    // pending request and change nothing else — the armed-link registry stays
    // untouched until a DRIVER drains the request after the walk.
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 2, .id = cont.id, .exit = 3, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    _ = state.replayLedger(&entries, &cont, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false, null);
    const pending = state.pending_bridge_arm orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 821), pending.trace_id);
    try testing.expectEqual(@as(u32, 3), pending.exit_instr);
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);

    // A later walk with a non-composite terminal clears the stale request
    // (never inherited across ledgers).
    var plain_prov = [_]ExitProvEntry{.{ .index = 0, .prov = .{ .guard = .{ .source_proto_id = proto.id, .source_pc = 1, .role = .operand_type, .operand = .a } } }};
    var plain_instrs = [_]IrInstr{ .{ .op = .guard_int, .a = 0 }, .{ .op = .link, .aux = 7 } };
    var plain: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 21 },
            .instrs = &plain_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .exit_prov = &plain_prov,
        },
        .id = 822,
    };
    try state.registry.cache.append(gpa, &plain);
    const entries2 = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = plain.id, .exit = 0, .reason = .normal, .kind = .deopt, .outcome = .normal },
    };
    _ = state.replayLedger(&entries2, &plain, 7, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false, null);
    try testing.expectEqual(@as(?ExitKey, null), state.pending_bridge_arm);
}

test "replayLedgerSuffix honors the silent cumulative baseline and off-cycle first owner" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();
    // Put the accounting threshold between the true suffix-local delta (2) and
    // the incorrect zero-based value (7), so a lost baseline changes hit_count.
    state.config.min_useful = 5;

    const proto = Proto{
        .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) },
        .name = "replay-suffix",
        .num_registers = 1,
    };
    var inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 },
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = &inner_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 901,
    };
    var cont_instrs = [_]IrInstr{.{ .op = .link, .aux = 5 }};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = &cont_instrs,
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 902,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // The fresh walk starts from rbx=0. Its first, nonterminal row advances by 2.
    const fresh_entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 2, .id = inner.id, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 2, .id = cont.id, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
    };
    var fresh_completed: usize = 0;
    var fresh_resume_pc: u32 = 0;
    var fresh_hops: usize = 0;
    const fresh_hits = inner.hit_count;
    const fresh_links = state.native_link_exits;
    const fresh_dir = state.replayLedger(&fresh_entries, &inner, 5, &proto, &fresh_completed, &fresh_resume_pc, &fresh_hops, 8, .dispatcher_root, false, null);
    const fresh_hit_delta = inner.hit_count - fresh_hits;
    const fresh_link_delta = state.native_link_exits - fresh_links;

    // The suffix reports the same two rows shifted by a silent rbx baseline of 5.
    // `suffix_init.cont` is deliberately NOT entries[0]'s owner: it is the continuation
    // cursor left by the suppressed prefix. `check_seed = false` permits this
    // off-cycle first owner. The ordinary replay entry still retains its release
    // panic for the analogous mismatched explicit seed; this Zig stdlib has no
    // in-process panic-expectation helper, so only the positive suffix is executed.
    const suffix_entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 7, .id = inner.id, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 7, .id = cont.id, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
    };
    var suffix_completed: usize = 0;
    var suffix_resume_pc: u32 = 0;
    var suffix_hops: usize = 0;
    const suffix_hits = inner.hit_count;
    const suffix_links = state.native_link_exits;
    const suffix_dir = state.replayLedgerSuffix(
        &suffix_entries,
        .{ .cont = &cont, .link_pc = 5, .prev_cum = 5, .next_entry = .ordinary },
        &proto,
        &suffix_completed,
        &suffix_resume_pc,
        &suffix_hops,
        8,
        .dispatcher_root,
        false,
        null,
    );

    try testing.expectEqual(fresh_completed, suffix_completed);
    try testing.expectEqual(fresh_resume_pc, suffix_resume_pc);
    try testing.expectEqual(fresh_hops, suffix_hops);
    try testing.expectEqual(fresh_hit_delta, inner.hit_count - suffix_hits);
    try testing.expectEqual(fresh_link_delta, state.native_link_exits - suffix_links);
    switch (fresh_dir) {
        .run_inner_from => |fresh_owner| switch (suffix_dir) {
            .run_inner_from => |suffix_owner| try testing.expectEqual(fresh_owner, suffix_owner),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "replayLedger forced yield (2c-B/2c-E): a CAP-length ledger ending .yielded replays cleanly" {
    // The forced-yield cap (2c-B): a closed native C↔I cycle keeps appending a
    // per-transition ledger entry; at `LEDGER_CAP` (32) the armed chain source
    // jumps to `shared_exit` instead of its successor and stamps the last entry
    // `.yielded`. `replayLedger` must ACCEPT exactly that shape — a full ledger
    // whose final entry is `.yielded` — without tripping the structural guard
    // (which panics on a `.yielded` that is NOT last-of-full), account every
    // committed enclosing iteration, and hand back a resume directive.
    //
    // Shape: 16 alternating `[I.loop_done_linked(fused), C.link_terminal]` pairs =
    // 32 entries; the terminal (a `.link`) is stamped `.yielded`. No arming
    // happens (the terminal is a `.link`, not a loop-done), so plain non-compiled
    // traces suffice and this runs on every host.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 501,
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 }, // links back to the inner root at pc 5
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 502,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // Build the CAP-length alternating ledger. Even index = I.loop_done_linked
    // (fused into the next C), odd = C.link_terminal (fused back into the next I),
    // except the final C.link which is the forced-yield terminal.
    var entries: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    var iter: usize = 0;
    while (iter < trace_exec.LEDGER_CAP) : (iter += 1) {
        const is_inner = (iter % 2 == 0);
        const enclosing = iter / 2 + 1; // 1,1,2,2,3,3,… — one increment per I.done
        const is_last = iter + 1 == trace_exec.LEDGER_CAP;
        entries[iter] = if (is_inner) .{
            .cum = enclosing,
            .id = 501,
            .exit = 0,
            .reason = .normal,
            .kind = .loop_done_linked,
            .outcome = .normal,
        } else .{
            .cum = enclosing,
            .id = 502,
            .exit = 0,
            .reason = .normal,
            .kind = .link_terminal,
            .outcome = if (is_last) .yielded else .normal,
        };
    }

    var linked_completed: usize = 0;
    var resume_pc: u32 = 0;
    var hops: usize = 0;
    // safe_to_arm = false: the terminal is a `.link` (never arms), and this test
    // isolates the forced-yield ACCEPTANCE, not arming.
    const dir = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, false, null);

    // Every one of the 16 loop-dones committed an enclosing iteration.
    try testing.expectEqual(@as(usize, 16), linked_completed);
    // The forced-yield `.link` terminal resumes by running the inner fresh at the
    // PC it names (pc 5), carrying itself as the `.link` driver.
    switch (dir) {
        .run_inner_from => |owner| try testing.expectEqual(@as(*Trace, &cont), owner),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 5), resume_pc);
    // 16 `.link` markers seen (one per C.link entry).
    try testing.expectEqual(@as(u64, 16), state.native_link_exits);
}

test "replayLedger convergence (2c-E site 3): a TERMINAL loop_done_linked arms the I→C slot" {
    // The convergence arm (trace.zig site 3, the `is_last` branch of
    // `.loop_done_linked`): a sibling inner reached ONLY through replay — never
    // through a scalar arm site (call A / driveChain) — must still converge to
    // armed, so the NEXT occurrence of its loop-done fuses. Here a synthetic
    // TERMINAL `[I.done(fused), C.link, I.done]` ledger drains through
    // `replayLedger` with `safe_to_arm = true`; the terminal `I.done` has no
    // successor to fuse into, so it arms `I.slot[loop-done] → C.ordinary_entry`
    // in place and hands back `run_continuation(C)`.
    //
    // Hand-built `.compiled` stubs (page undefined, heap `slots`) — same pattern
    // as the P-E registry test — so this needs no real codegen and runs on every
    // host: `replayLedger` only READS trace shape and ACCOUNTS/ARMS, it never
    // executes native code. `armLoopDoneLink` needs both halves `.compiled`
    // (inner as the arm's parent, cont for `nativeFor(cont).ordinary_entry`).
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    // Drop the hand-built stubs from the cache before deinit: their `page` is
    // undefined, so `destroy`→`native.deinit`→`page.deinit` would fault. We free
    // the two `slots` arrays ourselves below.
    defer state.registry.cache.clearRetainingCapacity();

    // code[1] is a for_loop, so the inner's guard_true (exit_pc 2) is a loop-done.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // instr 0: loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    const inner_slots = try gpa.alloc(usize, inner_instrs.len);
    defer gpa.free(inner_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(inner_slots, 0); // 0 == "unarmed" (no trampoline in this unit test)
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 301,
        .native = .{ .compiled = .{ .page = undefined, .slots = inner_slots, .gpa = gpa } },
    };
    // The continuation at post-loop pc 2: zero-input, ends `.link` back to pc 5.
    // Its `ordinary_entry` is the exact address the arm must write into the inner's
    // loop-done slot (the fused hop targets ORDINARY mode — 2.3c-0c).
    const CONT_ORDINARY_ENTRY: usize = 0xC0FFEE_1234;
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    const cont_slots = try gpa.alloc(usize, cont_instrs.len);
    defer gpa.free(cont_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(cont_slots, 0);
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 302,
        .native = .{ .compiled = .{ .page = undefined, .slots = cont_slots, .gpa = gpa, .ordinary_entry = CONT_ORDINARY_ENTRY } },
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // [I.done(fused) → C.link → I.done(terminal)]: the first loop-done fuses into
    // C, C links back to the inner root, and the second loop-done is TERMINAL (no
    // successor) — the convergence-arm site.
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 301, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 302, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 2, .id = 301, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
    };

    var linked_completed: usize = 0;
    var resume_pc: u32 = 0;
    var hops: usize = 0;
    const dir = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, true, null);

    // The terminal loop-done armed the convergence edge EXACTLY once, writing the
    // continuation's `ordinary_entry` into the inner's loop-done slot (instr 0).
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_arms);
    try testing.expectEqual(CONT_ORDINARY_ENTRY, inner_slots[0]);
    // One armed-link record: parent = inner, slot = 0 (the loop-done instr), child = cont.
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    const rec = state.registry.native_physical.armed_links.items[0];
    try testing.expectEqual(@as(*Trace, &inner), rec.parent);
    try testing.expectEqual(@as(u32, 0), rec.slot_index);
    try testing.expectEqual(@as(*Trace, &cont), rec.child);
    // The one INTERIOR loop-done (k=0) fused; the terminal one (k=2) did not.
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_fused);
    // The directive runs the continuation (regs coherent at its anchor, pc 2).
    switch (dir) {
        .run_continuation => |c| try testing.expectEqual(@as(*Trace, &cont), c),
        else => return error.TestUnexpectedResult,
    }
    // Two enclosing iterations committed (one per loop-done), resume at pc 2.
    try testing.expectEqual(@as(usize, 2), linked_completed);
    try testing.expectEqual(@as(u32, 2), resume_pc);

    // Manually drop the armed record BEFORE the deferred cache-clear so no dangling
    // record references the stack traces after the test frame unwinds. (Both slots
    // are freed by the earlier `defer gpa.free`; the stubs are never `destroy`d.)
    state.registry.native_physical.armed_links.clearRetainingCapacity();
}

test "B-4: terminal loop-done resolves positionally — unsupported never shadows, arm is canonical, run prefers fingerprint" {
    // §B4.3 D1'–D4' + §B4.7 pins, in one automaton image. The burst's entry
    // path seeds `cursor.cont = inner` (anchored pc 5 — NOT a valid resume
    // candidate at the post-loop pc 2), which before B-4 meant break_burst on
    // every terminal loop-done (27,554/run on nsieve-bit 6). The canonical
    // selector must instead resolve the continuation POSITIONALLY at pc 2:
    //   - cont_unsup: highest hit_count but native `.unsupported` — must be
    //     SKIPPED, not shadow the runnable siblings (§B4.7 BLOCKER pin);
    //   - cont_a / cont_b: equal hit_count → LOWEST id (cont_a) is the ARM
    //     target (stable tie-break pin);
    //   - regs carry a float in slot 0; cont_a's fingerprint demands int,
    //     cont_b has no guards → the RUN target is cont_b (fingerprint
    //     ranking), and the run choice does NOT touch the armed slot.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    // code[1] is a for_loop, so the inner's guard_true (exit_pc 2) is a loop-done.
    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    const inner_slots = try gpa.alloc(usize, inner_instrs.len);
    defer gpa.free(inner_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(inner_slots, 0);
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 401,
        .native = .{ .compiled = .{ .page = undefined, .slots = inner_slots, .gpa = gpa } },
    };
    const link_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    // Highest-hit candidate at pc 2, but not native-runnable.
    var cont_unsup: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&link_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 399,
        .native = .unsupported,
        .hit_count = 100,
    };
    const A_ENTRY: usize = 0xA11CE_0001;
    const a_slots = try gpa.alloc(usize, link_instrs.len);
    defer gpa.free(a_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(a_slots, 0);
    const a_guards = [_]EntryGuard{.{ .slot = 0, .ty = .int }};
    var cont_a: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&link_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = @constCast(&a_guards),
        },
        .id = 402,
        .native = .{ .compiled = .{ .page = undefined, .slots = a_slots, .gpa = gpa, .ordinary_entry = A_ENTRY } },
        .hit_count = 5,
    };
    const B_ENTRY: usize = 0xB0B_0002;
    const b_slots = try gpa.alloc(usize, link_instrs.len);
    defer gpa.free(b_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(b_slots, 0);
    var cont_b: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&link_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 403,
        .native = .{ .compiled = .{ .page = undefined, .slots = b_slots, .gpa = gpa, .ordinary_entry = B_ENTRY } },
        .hit_count = 5,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont_unsup);
    try state.registry.cache.append(gpa, &cont_a);
    try state.registry.cache.append(gpa, &cont_b);

    var tags: [4]u8 = @splat(0);
    var pays: [4]u64 = @splat(0);
    const regs = RegWindow.of(&tags, &pays);
    regs.setFloat(0, 1.5); // cont_a's int fingerprint MISSES, cont_b matches

    // A single TERMINAL loop-done row: `cursor.cont` is the seed (inner) — the
    // stale-cursor shape that used to break the burst unconditionally.
    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 401, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 0;
    var hops: usize = 0;
    const dir = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, true, regs);

    // ARM: canonical target is cont_a (unsup skipped, id tie-break), exactly one
    // record, `ordinary_entry` written into the inner's loop-done slot.
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_arms);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(*Trace, &cont_a), state.registry.native_physical.armed_links.items[0].child);
    try testing.expectEqual(A_ENTRY, inner_slots[0]);
    // RUN: fingerprint-ranked target is cont_b; the run choice left the slot alone.
    switch (dir) {
        .run_continuation => |c| try testing.expectEqual(@as(*Trace, &cont_b), c),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), linked_completed);
    try testing.expectEqual(@as(u32, 2), resume_pc);

    // A/B no-realarm pin (§B4.7 MAJOR-2): a second burst reaching the same
    // funnel re-selects the SAME canonical arm target; the identical re-arm
    // short-circuits (B-3d.1 R6) — no second record, slot value unchanged.
    linked_completed = 0;
    resume_pc = 0;
    hops = 0;
    const dir2 = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, true, regs);
    switch (dir2) {
        .run_continuation => |c| try testing.expectEqual(@as(*Trace, &cont_b), c),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(*Trace, &cont_a), state.registry.native_physical.armed_links.items[0].child);
    try testing.expectEqual(A_ENTRY, inner_slots[0]);

    // No eligible continuation at all → break_burst at post_pc (existing safe
    // directive pinned). Drop every continuation from the cache first; the
    // armed record must be cleared with them (it references stack stubs).
    state.registry.native_physical.armed_links.clearRetainingCapacity();
    inner_slots[0] = 0;
    state.registry.cache.clearRetainingCapacity();
    try state.registry.cache.append(gpa, &inner);
    linked_completed = 0;
    resume_pc = 0;
    hops = 0;
    const dir3 = state.replayLedger(&entries, &inner, 5, &proto, &linked_completed, &resume_pc, &hops, 8, .dispatcher_root, true, regs);
    switch (dir3) {
        .break_burst => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 2), resume_pc);
}

test "driveChain ordinary_header: chains at the anchor, not a guard's lane ordinal" {
    // Regression: ordinary-exit chaining walks the failed trace's ANCHOR (where the
    // registers are coherent), never a guard's `aux`. `guard_lane`/`guard_fits`
    // store a lane ordinal in `aux`, not a bytecode PC — a decoy trace anchored at
    // that ordinal (pc 2) must never be entered. Here A's guard_lane has aux=2; the
    // driver walks A's anchor (pc 10) instead, so the decoy at pc 2 is unreachable.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };

    // Trace A: the failing trace at pc 10. Its instr index 1 is a guard_lane with
    // aux=2 (a lane ordinal that happens to equal the decoy's anchor pc).
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (the table)
        .{ .op = .guard_lane, .a = 0, .aux = 2 }, // %1: lane ordinal 2 — NOT a PC
        .{ .op = .loop }, // %2
    };
    const consts_a = [_]Value{};
    const trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&instrs_a),
            .consts = @constCast(&consts_a),
            .entry_slots = &entry_a,
            .entry_guards = &.{},
        },
    };

    // Decoy trace anchored at pc 2 — a plain counting loop that, if (wrongly)
    // entered, would commit iterations and mutate r0.
    var entry_b = [_]u16{ 0, 1 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .slot_load, .aux = 1 }, // %1: r1
        .{ .op = .konst, .aux = 0 }, // %2: 1
        .{ .op = .add, .a = 0, .b = 2 }, // %3: r0+1
        .{ .op = .lt, .a = 3, .b = 1 }, // %4: (r0+1) < r1
        .{ .op = .guard_true, .a = 4, .aux = 2 }, // %5
        .{ .op = .phi, .a = 0, .b = 3, .aux = 0, .ty = .int }, // %6: r0 ← r0+1
        .{ .op = .loop }, // %7
    };
    const consts_b = [_]Value{Value.int(1)};
    const trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 }, // collides with the lane ordinal
            .instrs = @constCast(&instrs_b),
            .consts = @constCast(&consts_b),
            .entry_slots = &entry_b,
            .entry_guards = &.{},
        },
    };

    try state.registry.cache.append(gpa, trace_a);
    try state.registry.cache.append(gpa, trace_b);

    var regs = [_]Value{ Value.int(0), Value.int(4) };
    // Exclude A (the dispatcher's `visited` set). The driver walks A's anchor
    // (pc 10), finds no other sibling there, and must NOT reach the decoy at pc 2.
    var tr_regs = TestRegs{ .regs = &regs };
    const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false, false);
    tr_regs.commit(); // commit so a (buggy) decoy mutation would surface — keeps the test's teeth
    try testing.expect(chained == null);
    try testing.expectEqual(@as(i64, 0), regs[0].asInt()); // r0 untouched — no decoy ran

    state.registry.cache.clearRetainingCapacity();
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

// ---------------------------------------------------------------------------
// Doc 22 §B.5 (Phase B-iv.3): the widened replayLedger fused-successor asserts,
// POSITIVE paths. Zero-input successors keep the pre-B-iv shape-only contract
// (the grammar tests above); a SEEDED fused successor is newly admitted iff it
// is stub-enterable at drain time — which real fused rows guarantee (the span
// dispatched into the successor's self-seeding entry within this same frame).
// These pin that a seeded, enterable successor drains identically to its
// zero-input twin instead of tripping the widened panic.
// ---------------------------------------------------------------------------

/// Inert seed twin for the seeded-successor fixtures below — `stubEnterable`
/// never calls it, but `NativeSeedCtx.seed_fn` has no default.
fn seededReplayDummySeed(
    ctx: *const trace.NativeSeedCtx,
    t: *const trace.TraceCode,
    plan_bits: u64,
) callconv(.c) u64 {
    _ = ctx;
    _ = t;
    _ = plan_bits;
    return trace.NativeSeedCtx.SEED_OK;
}

test "B-iv.3 (doc 22 §B.5): [I.loop_done_linked, C.prologue_fail] with a SEEDED enterable continuation drains like the zero-input twin" {
    // Mirror of the zero-input `[I.loop_done_linked, C.prologue_fail]` grammar
    // test above, but the fused continuation is a SEEDED page (plan/prologue
    // agreeing, fresh episode ctx). The widened `.ordinary` assert must accept
    // it; every directive/accounting outcome matches the zero-input twin.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 221,
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 5 },
    };
    var seed_inputs = [_]trace.InputSeed{undefined};
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .inputs = &seed_inputs,
        },
        .id = 222,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .ordinary_entry = 0xCAFE,
            .seed_plan = .{ .bits = 1 },
            .seed_prologue = true,
        } },
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    // Fresh episode ctx: the fused span just dispatched into the continuation's
    // self-seeding entry within this frame, so drain-time freshness holds.
    const ctx = try gpa.create(trace.NativeSeedCtx);
    ctx.* = .{ .seed_fn = seededReplayDummySeed };
    state.registry.native_seed_ctx = ctx; // state.deinit() destroys it
    ctx.proto = @ptrCast(&proto);
    ctx.call_seq = 7;
    state.region_policy.setContext(0, 7);

    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 1, .id = 221, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 1, .id = 222, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);

    // Identical to the zero-input twin: the committed loop-done survives,
    // coherent at the continuation anchor, and nothing charges.
    try testing.expectEqual(@as(usize, 1), r.completed);
    try testing.expectEqual(@as(?u32, 2), r.resume_pc);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 5 }));
    try testing.expectEqual(@as(?u32, null), state.penalty.get(.{ .proto = &proto, .pc = 2 }));
    try testing.expectEqual(@as(u64, 0), state.native_link_exits);
    // Nothing declined on this path — the B-v diagnostic counters stay zero.
    try testing.expectEqual(@as(u64, 0), state.seed_hash_declines);
    try testing.expectEqual(@as(u64, 0), state.seed_capacity_declines);
}

test "B-iv.3 (doc 22 §B.5): [C.link_terminal, I.seed_hash_decline] with a SEEDED enterable inner drains like the zero-input twin" {
    // Mirror of the zero-input terminal seed-decline grammar test above, but
    // the fused inner root is genuinely SEEDED — the shape the decline row
    // actually implies in production (a hash decline happens INSIDE a seeded
    // page's entry, with the episode ctx necessarily fresh). Pins both B-iv.3
    // widenings on the `.link_terminal` arm: `isInnerLoopRoot` no longer
    // rejects the seeded successor's shape, and the widened `.linked` assert
    // accepts the enterable page.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 321,
    };
    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var seed_inputs = [_]trace.InputSeed{undefined};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .inputs = &seed_inputs,
        },
        .id = 322,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .linked_entry = 0xBEEF,
            .ordinary_entry = 0xCAFE,
            .seed_plan = .{ .bits = 1 },
            .seed_prologue = true,
        } },
    };
    try state.registry.cache.append(gpa, &cont);
    try state.registry.cache.append(gpa, &inner);

    const ctx = try gpa.create(trace.NativeSeedCtx);
    ctx.* = .{ .seed_fn = seededReplayDummySeed };
    state.registry.native_seed_ctx = ctx; // state.deinit() destroys it
    ctx.proto = @ptrCast(&proto);
    ctx.call_seq = 7;
    state.region_policy.setContext(0, 7);

    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 0, .id = 321, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 0, .id = 322, .exit = std.math.maxInt(u32), .reason = .seed_hash_decline, .kind = .seed_hash_decline, .outcome = .normal },
    };
    var linked_completed: usize = 0;
    var resume_pc: u32 = 999;
    var hops: usize = 0;
    const dir = state.replayLedger(
        &entries,
        &cont,
        7,
        &proto,
        &linked_completed,
        &resume_pc,
        &hops,
        8,
        .dispatcher_root,
        false,
        null,
    );

    const result = switch (dir) {
        .return_result => |r| r,
        else => return error.TestUnexpectedResult,
    };
    // Identical to the zero-input twin: zero progress, coherent at the
    // decliner's own anchor, one `.link` marker + one fused follow, chargeless.
    try testing.expectEqual(@as(usize, 0), result.completed);
    try testing.expectEqual(@as(u32, 7), result.resume_pc);
    try testing.expectEqual(@as(u64, 1), state.native_link_exits);
    try testing.expectEqual(@as(u64, 1), state.native_link_follow_count);
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    // B-v diagnostic witness: the terminal hash-decline row bumped exactly its
    // own counter at the replay seam.
    try testing.expectEqual(@as(u64, 1), state.seed_hash_declines);
    try testing.expectEqual(@as(u64, 0), state.seed_capacity_declines);
}

test "B-v (doc 22 §B.6): terminal seed-decline placement pin — a fused decliner preserves the predecessors' committed rbx" {
    // §B.6 row 8 (`entry_rbx`-ordering pin): a three-row fused span
    //   [I.loop_done_linked cum=5, C.link_terminal cum=5, I.seed_hash_decline cum=5]
    // where the FIRST leg committed a full inner loop (cum 5 region-locally,
    // ONE outer-iteration grant to `linked_completed`), the continuation
    // linked back to the (seeded) inner root, and the re-entry declined at
    // the seed prologue. The pin: the decline row is chargeless AND
    // placement-inert — the returned `completed` is exactly the predecessor's
    // grant (the decliner's `entry_rbx` snapshot ordering never lets the
    // maxInt exit or the 0-local row erode it to 0), resumption is coherent
    // at the decliner's own anchor, and only the hash-decline diagnostic
    // increments.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity();

    const proto = Proto{ .code = &.{ Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = 1 };

    const inner_instrs = [_]IrInstr{
        .{ .op = .guard_true, .a = 0, .aux = 2 }, // loop-done guard, post-loop pc 2
        .{ .op = .loop },
    };
    var seed_inputs = [_]trace.InputSeed{undefined};
    var inner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&inner_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .inputs = &seed_inputs,
        },
        .id = 421,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .linked_entry = 0xBEEF,
            .ordinary_entry = 0xCAFE,
            .seed_plan = .{ .bits = 1 },
            .seed_prologue = true,
        } },
    };
    const cont_instrs = [_]IrInstr{
        .{ .op = .link, .aux = 7 },
    };
    var cont: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 2 },
            .instrs = @constCast(&cont_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 422,
    };
    try state.registry.cache.append(gpa, &inner);
    try state.registry.cache.append(gpa, &cont);

    const ctx = try gpa.create(trace.NativeSeedCtx);
    ctx.* = .{ .seed_fn = seededReplayDummySeed };
    state.registry.native_seed_ctx = ctx; // state.deinit() destroys it
    ctx.proto = @ptrCast(&proto);
    ctx.call_seq = 7;
    state.region_policy.setContext(0, 7);

    const entries = [_]trace_exec.LedgerEntry{
        .{ .cum = 5, .id = 421, .exit = 0, .reason = .normal, .kind = .loop_done_linked, .outcome = .normal },
        .{ .cum = 5, .id = 422, .exit = 0, .reason = .normal, .kind = .link_terminal, .outcome = .normal },
        .{ .cum = 5, .id = 421, .exit = std.math.maxInt(u32), .reason = .seed_hash_decline, .kind = .seed_hash_decline, .outcome = .normal },
    };
    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    const r = state.driveDispatcherLedger(&inner, &entries, &proto, tr_regs.view(), false);

    // The predecessor's committed grant survives the terminal decline
    // untouched (placement pin: 1, not 0 — the decliner's local_completed is
    // 0 and never erodes the grant), resumption is at the decliner's own
    // anchor, and the decline row itself is chargeless.
    try testing.expectEqual(@as(usize, 1), r.completed);
    try testing.expectEqual(@as(?u32, 7), r.resume_pc);
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    try testing.expectEqual(@as(u64, 1), state.native_loopdone_link_fused);
    try testing.expectEqual(@as(u64, 1), state.native_link_follow_count);
    try testing.expectEqual(@as(u64, 1), state.seed_hash_declines);
    try testing.expectEqual(@as(u64, 0), state.seed_capacity_declines);
}
