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
        .code = .{
            .anchor = .{ .proto = undefined, .pc = 10 },
            .instrs = @constCast(&instrs_a),
            .consts = @constCast(&consts_a),
            .entry_slots = &entry_a,
            .entry_guards = &.{},
        },
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
        .code = .{
            .anchor = .{ .proto = undefined, .pc = 10 }, // same anchor as A
            .instrs = @constCast(&instrs_b),
            .consts = @constCast(&consts_b),
            .entry_slots = &entry_b,
            .entry_guards = &.{},
        },
    };

    // Put both traces in the cache.
    try state.registry.cache.append(gpa, trace_a);
    try state.registry.cache.append(gpa, trace_b);

    // Set proto on anchors (needed for findTrace lookup).
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    trace_a.code.anchor.proto = &proto;
    trace_b.code.anchor.proto = &proto;

    // Regs: r0=0, r1=4 → Trace B should run 3 iterations (0,1,2;
    // iteration 3 computes 3<4 which is true, runs, then 4<4 fails).
    var regs = [_]Value{ Value.int(0), Value.int(4) };

    // Fake a guard failure in Trace A at instr index 1 (the guard_int), and
    // exclude A (the dispatcher's `visited` set) so the driver walks to B.
    var tr_regs = TestRegs{ .regs = &regs };
    const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false, false);
    tr_regs.commit(); // the chained side trace mutated the window — reflect it back
    try testing.expect(chained != null);
    try testing.expectEqual(@as(usize, 3), chained.?.completed); // Trace B ran 3 iters
    try testing.expect(chained.?.resume_pc == null);
    try testing.expectEqual(@as(i64, 3), regs[0].asInt()); // r0 carried to 3

    // Remove traces from cache before deinit — they have stack-allocated
    // arrays that must not be freed by destroy().
    state.registry.cache.clearRetainingCapacity();
    // Free the Trace heap allocations ourselves (instrs/consts/entry_slots
    // are stack memory, so skip those fields by not calling destroy).
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "driveChain (doc 44 D1): a head-anchored trace never chains — kind check fires before the sentinel becomes a walk pc" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A head-anchored trace with a same-anchor sibling in the cache. Without
    // the D1 kind check `.ordinary_header` would hand FUNC_HEAD_PC out as the
    // walk pc and chain to the sibling; with it, driveChain returns null
    // before touching the window or the proto.
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_int, .a = 0, .aux = 20 },
        .{ .op = .terminal, .aux = 5 },
    };
    const consts_a = [_]Value{};
    var trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .code = .{
            .anchor = .{ .proto = undefined, .pc = trace.FUNC_HEAD_PC },
            .instrs = @constCast(&instrs_a),
            .consts = @constCast(&consts_a),
            .entry_slots = &entry_a,
            .entry_guards = &.{},
        },
    };
    var trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .code = .{
            .anchor = .{ .proto = undefined, .pc = trace.FUNC_HEAD_PC },
            .instrs = @constCast(&instrs_a),
            .consts = @constCast(&consts_a),
            .entry_slots = &entry_a,
            .entry_guards = &.{},
        },
    };
    try state.registry.cache.append(gpa, trace_a);
    try state.registry.cache.append(gpa, trace_b);
    const proto = Proto{ .code = &.{}, .name = "head", .num_registers = 1 };
    trace_a.code.anchor.proto = &proto;
    trace_b.code.anchor.proto = &proto;

    var regs = [_]Value{Value.int(0)};
    var tr_regs = TestRegs{ .regs = &regs };
    // Exclude only A (the failed trace itself) — B stays a reachable sibling,
    // proving it's the kind check (not the exclusion set) that refuses.
    const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false, false);
    try testing.expect(chained == null);

    state.registry.cache.clearRetainingCapacity();
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "tryArmSiblingHandoff publishes complete Part-S bookkeeping" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces

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
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(parent_slots, 0);

    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&parent_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 41,
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
        .sibling_watch_exit = 0,
        .sibling_watch_count = 9,
    };
    var child: Trace = .{
        .code = .{
            .anchor = parent.code.anchor,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 42,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .ordinary_entry = 0xCAFE,
        } },
    };
    try state.registry.cache.append(gpa, &parent);
    try state.registry.cache.append(gpa, &child);
    state.pending_sibling_arm = .{ .trace_id = parent.id, .exit_instr = 0 };

    state.tryArmSiblingHandoff(&child, true);

    try testing.expectEqual(@as(?ExitKey, null), state.pending_sibling_arm);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    const link = state.registry.native_physical.armed_links.items[0];
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

test "arm validator (doc 44 D10): head-anchored parents carry ONLY .sibling_handoff arms, and head arms refuse hash-seeded children" {
    // The durable invariant, enforced at the single arm funnel: a head slot's
    // fused ledger grammar is the closed sibling-handoff burst — any other
    // arm kind on a head parent would smuggle a row shape `consumeHeadBurst`
    // cannot replay. The `.sibling_handoff` positive case proves the head
    // rejections are the kind checks, not some other validator line; the
    // hash-seeded child refusal keeps `seed_hash_decline` (whose consumer
    // needs the tier-1a rerun machinery) out of the burst grammar at ARM time.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "head-arm-validator",
        .num_registers = 1,
    };
    const parent_instrs = [_]IrInstr{
        .{ .op = .guard_true, .aux = 1 },
        .{ .op = .terminal },
    };
    const parent_slots = try gpa.alloc(usize, parent_instrs.len);
    defer gpa.free(parent_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(parent_slots, 0);

    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = trace.FUNC_HEAD_PC },
            .instrs = @constCast(&parent_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 51,
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .code = .{
            .anchor = parent.code.anchor,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 52,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .ordinary_entry = 0xBEEF,
        } },
    };
    try state.registry.cache.append(gpa, &parent);
    try state.registry.cache.append(gpa, &child);

    // Every non-handoff kind is refused on a head parent. (`.loop_done_linked`
    // is untestable here: its shape assert fires first in debug — a head
    // guard is never loop-done by D1 — and the release path fails closed on
    // the same check.)
    try testing.expect(!(try state.armNativeLink(&parent, 0, &child, .ordinary_guard)));
    try testing.expect(!(try state.armNativeLink(&parent, 0, &child, .link_terminal)));
    try testing.expect(!(try state.armNativeLink(&parent, 0, &child, .region_bridge)));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);

    // A hash-seeded child is refused for a HEAD handoff arm specifically.
    child.native.compiled.has_hash_seed = true;
    try testing.expect(!(try state.armNativeLink(&parent, 0, &child, .sibling_handoff)));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);

    // With the hash seed gone the same head arm publishes — proving the
    // rejections above were the D10 checks, not an unrelated validator line.
    child.native.compiled.has_hash_seed = false;
    try testing.expect(try state.armNativeLink(&parent, 0, &child, .sibling_handoff));
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    const link = state.registry.native_physical.armed_links.items[0];
    try testing.expectEqual(ArmKind.sibling_handoff, link.kind);
    try testing.expect(link.parent == &parent);
    try testing.expect(link.child == &child);
    try testing.expectEqual(@as(usize, 0xBEEF), parent_slots[0]);
}

// ---------------------------------------------------------------------------
// Doc 22 §B.3 / §B.6 (Phase B-iii): driveChain's TIER-1A walk seeds a seeded
// successor through the episode ctx's seeding twin before `irinterp.execute`.
// The chained hash-drift pin: a hash seed that fails validation
// (SEED_HASH_DECLINE) still executes on tier-1a — tier-1a re-derives hash
// cells from `href` operands and side-exits at the same guard — while a
// capacity decline (SEED_CAPACITY_DECLINE), or a missing ctx/twin (hand-built
// TraceStates), declines the candidate exactly like the pre-B-iii skip.
// ---------------------------------------------------------------------------

/// Test double for the tier-1a seeding twin (`interp.nativeSeedTier1aFn`).
/// Mirrors the production aliasing: the twin writes the seeded slot into the
/// SAME backing lanes the chain's `RegWindow` views (here: the `TestRegs`
/// arrays smuggled through `ctx.vm`), then answers the scripted disposition.
/// Slot 2 is the synthetic input slot above the 2-register frame; the seeded
/// value (int 2) is chosen so the chained loop's result is only reachable
/// through the seed — proving the write happened before execution.
const SeedStub = struct {
    var calls: usize = 0;
    var rc: u64 = trace.NativeSeedCtx.SEED_HASH_DECLINE;
    fn seed(ctx: *const trace.NativeSeedCtx, t: *const trace.TraceCode) u64 {
        _ = t;
        const tr: *TestRegs = @ptrCast(@alignCast(ctx.vm));
        const v = Value.int(2);
        tr.tags[2] = @intFromEnum(v.tag);
        tr.pays[2] = v.payload.bits;
        calls += 1;
        return rc;
    }
};

test "B-iii chained hash-drift (doc 22 §B.6): SEED_HASH_DECLINE still chains on tier-1a; capacity decline and missing ctx fail closed" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack/hand-owned traces
    SeedStub.calls = 0;
    SeedStub.rc = trace.NativeSeedCtx.SEED_HASH_DECLINE;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };

    // Trace A at PC 10: the trace whose guard "fails" (faked by calling
    // driveChain directly) — the ordinary_header same-anchor walk shape.
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .guard_int, .a = 0, .aux = 20 }, // %1: the "failing" guard
        .{ .op = .loop }, // %2
    };
    const trace_a = try gpa.create(Trace);
    defer gpa.destroy(trace_a);
    trace_a.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&instrs_a),
            .consts = &.{},
            .entry_slots = &entry_a,
            .entry_guards = &.{},
        },
    };

    // Trace B: a SEEDED same-anchor sibling — the counting loop's increment is
    // the synthetic slot 2 (r0 += r2 while r0+r2 < r1), so the loop only
    // produces r0 == 2 / completed == 1 if the twin's seed write landed.
    var entry_b = [_]u16{ 0, 1, 2 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 counter
        .{ .op = .slot_load, .aux = 1 }, // %1: r1 limit
        .{ .op = .slot_load, .aux = 2 }, // %2: the SEEDED synthetic slot
        .{ .op = .guard_int, .a = 0, .aux = 10 }, // %3
        .{ .op = .guard_int, .a = 1, .aux = 10 }, // %4
        .{ .op = .guard_int, .a = 2, .aux = 10 }, // %5
        .{ .op = .add, .a = 0, .b = 2 }, // %6: r0 + seed
        .{ .op = .lt, .a = 6, .b = 1 }, // %7: (r0+seed) < limit
        .{ .op = .guard_true, .a = 7, .aux = 10 }, // %8
        .{ .op = .phi, .a = 0, .b = 6, .aux = 0, .ty = .int }, // %9: r0 ← r0+seed
        .{ .op = .loop }, // %10
    };
    var inputs_b = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 2, .table_reg = 0, .expected_count = 1 },
    };
    const trace_b = try gpa.create(Trace);
    defer gpa.destroy(trace_b);
    trace_b.* = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 }, // same anchor as A
            .instrs = @constCast(&instrs_b),
            .consts = &.{},
            .entry_slots = &entry_b,
            .entry_guards = &.{},
            .inputs = &inputs_b,
        },
    };

    try state.registry.cache.append(gpa, trace_a);
    try state.registry.cache.append(gpa, trace_b);

    // --- 1. Fail closed: no ctx installed (hand-built TraceState) → the walk
    // must skip the seeded candidate WITHOUT consulting any twin, exactly the
    // pre-B-iii `inputs.len != 0` skip.
    var regs = [_]Value{ Value.int(0), Value.int(4) };
    var tr_regs = TestRegs{ .regs = &regs };
    {
        const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false, false);
        try testing.expect(chained == null);
        try testing.expectEqual(@as(usize, 0), SeedStub.calls);
    }

    // Install the episode ctx (heap-allocated: TraceState.deinit owns it).
    const ctx = try gpa.create(trace.NativeSeedCtx);
    ctx.* = .{
        .vm = @ptrCast(&tr_regs), // the twin's write target (production: the VM slab)
        .base = 0,
        .reg_capacity = 64,
        .proto = @ptrCast(&proto), // freshness stamp asserted by seedForTier1a
        .seed_fn = undefined, // C-ABI prologue twin — never called on the tier-1a walk
        .seed_tier1a_fn = &SeedStub.seed,
    };
    state.registry.native_seed_ctx = ctx;

    // --- 2. THE hash-drift pin: the twin seeds slot 2 then reports
    // SEED_HASH_DECLINE — driveChain must STILL run the successor on tier-1a.
    // r0=0, r1=4, seed=2: iter 1 commits r0=2 (2<4); iter 2 computes 4<4 →
    // guard_true fails → completed=1. Both values prove the seed flowed in.
    {
        regs = .{ Value.int(0), Value.int(4) };
        const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false, false);
        tr_regs.commit();
        try testing.expectEqual(@as(usize, 1), SeedStub.calls);
        try testing.expect(chained != null);
        try testing.expectEqual(@as(usize, 1), chained.?.completed);
        try testing.expect(chained.?.resume_pc == null);
        try testing.expectEqual(@as(i64, 2), regs[0].asInt());
    }

    // --- 3. Capacity decline: the twin is consulted but the candidate is
    // declined (unenterable child) — no execution, no other candidate → null.
    {
        SeedStub.rc = trace.NativeSeedCtx.SEED_CAPACITY_DECLINE;
        regs = .{ Value.int(0), Value.int(4) };
        const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false, false);
        try testing.expectEqual(@as(usize, 2), SeedStub.calls);
        try testing.expect(chained == null);
    }
}

test "in-place re-arm releases the displaced sibling latch (sibling -> ordinary -> sibling -> disarm)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces

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
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(parent_slots, 0);
    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&parent_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 45,
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    var child: Trace = .{
        .code = .{
            .anchor = parent.code.anchor,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 46,
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xD00D } },
    };
    try state.registry.cache.append(gpa, &parent);
    try state.registry.cache.append(gpa, &child);

    // sibling: latch counts 1.
    try testing.expect(state.publishSiblingArm(&parent, 0, &child));
    try testing.expectEqual(@as(u32, 1), parent.sibling_arms);
    // ordinary displaces the sibling arm in place: latch must drop to 0
    // (codex post-landing blocker: without clearSiblingLatch here the count
    // leaks +1 per displace→republish cycle).
    try testing.expect(try state.armNativeLink(&parent, 0, &child, .ordinary_guard));
    try testing.expectEqual(@as(u32, 0), parent.sibling_arms);
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
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
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
}

// ---------------------------------------------------------------------------
// Doc 22 §B.4 (Phase B-iv.1): `stubEnterable` — THE gate every arm/link site
// consults instead of scalar `inputs.len == 0` filters. Pins the full decision
// table: page/entry presence, the unseeded unconditional-true arm (hand-built
// test pages stay armable with no episode ctx), and the seeded fail-closed
// freshness ladder (ctx present → ctx.proto matches → anchor.proto matches →
// region_context present → call_seq tokens agree).
// ---------------------------------------------------------------------------

fn stubEnterableDummySeed(
    ctx: *const trace.NativeSeedCtx,
    t: *const trace.TraceCode,
    plan_bits: u64,
) callconv(.c) u64 {
    _ = ctx;
    _ = t;
    _ = plan_bits;
    return trace.NativeSeedCtx.SEED_OK;
}

test "B-iv.1 stubEnterable (doc 22 §B.4): entry presence, unseeded pass, seeded freshness ladder" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "stub-enterable",
        .num_registers = 1,
    };
    const other_proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "stub-enterable-other",
        .num_registers = 1,
    };

    // (1) Not compiled → false for both kinds (never compiles lazily).
    var uncompiled: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 1 },
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 60,
    };
    try testing.expect(!state.stubEnterable(&uncompiled, .ordinary, &proto));
    try testing.expect(!state.stubEnterable(&uncompiled, .linked, &proto));

    // (2) Compiled, only the ordinary entry present: kind-selective. Unseeded
    // plan (default) → ordinary passes with NO episode ctx; linked has no stub.
    var ordinary_only: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 1 },
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 61,
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xCAFE } },
    };
    try testing.expect(state.stubEnterable(&ordinary_only, .ordinary, &proto));
    try testing.expect(!state.stubEnterable(&ordinary_only, .linked, &proto));

    // (3) Seeded page (plan non-empty + prologue recorded, the §B.4 invariant
    // holding): fail-closed freshness ladder.
    var seeded: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 1 },
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 62,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .linked_entry = 0xBEEF,
            .ordinary_entry = 0xCAFE,
            .seed_plan = .{ .bits = 1 },
            .seed_prologue = true,
        } },
    };
    // (3a) No episode ctx at all → false.
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    const ctx = try gpa.create(trace.NativeSeedCtx);
    ctx.* = .{ .seed_fn = stubEnterableDummySeed };
    state.registry.native_seed_ctx = ctx; // state.deinit() destroys it

    // (3b) Ctx present but never stamped (proto == null) → false.
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    // (3c) Ctx stamped for a DIFFERENT frame proto → false.
    ctx.proto = @ptrCast(&other_proto);
    ctx.call_seq = 7;
    state.region_policy.setContext(0, 7);
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    // (3d) Ctx matches the live proto but the trace is anchored elsewhere → false.
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &other_proto));

    // (3e) Fully fresh: ctx.proto == proto == anchor.proto, call_seq tokens
    // agree → true, for BOTH entry kinds (the prologue is entry-kind-uniform).
    ctx.proto = @ptrCast(&proto);
    try testing.expect(state.stubEnterable(&seeded, .ordinary, &proto));
    try testing.expect(state.stubEnterable(&seeded, .linked, &proto));

    // (3f) Frame token drift (new activation since the episode was stamped) → false.
    state.region_policy.setContext(0, 8);
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    // (3g) No region context at all (no frame transition observed yet) → false.
    state.region_policy.clearContext();
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));
}

// ---------------------------------------------------------------------------
// Doc 22 §B.5 (Phase B-iv.3): the seeded-entry gate flips. Selection sites
// (findLinkTrace / resolveLoopDoneCont) admit seeded candidates outright —
// enterability is probed downstream — and the arm/validator sites consult
// `stubEnterable` with the entry kind they target instead of the pre-B-iv
// blanket `inputs.len == 0` bar. Each test here is the regression net for a
// §B.5 table row; the driveChain-internal seams (side-walk seed-accept,
// call-A follow, armLinkTerminal/armLoopDoneLinkTo, promotedEdgeFromLink)
// are covered end-to-end by the §B.6 battery.
// ---------------------------------------------------------------------------

test "B-iv.3 (doc 22 §B.5): findLinkTrace + resolveLoopDoneCont admit a seeded continuation" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "biv3-select",
        .num_registers = 1,
    };
    // A SEEDED `.link` continuation at the post-loop pc 2: dispatcher inputs
    // non-empty AND a compiled page whose §B.4 plan/prologue agree. Pre-B-iv.3
    // both selectors skipped it on `inputs.len != 0`.
    var seed_inputs = [_]trace.InputSeed{undefined};
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
            .inputs = &seed_inputs,
        },
        .id = 71,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .ordinary_entry = 0xCAFE,
            .seed_plan = .{ .bits = 1 },
            .seed_prologue = true,
        } },
    };
    try state.registry.cache.append(gpa, &cont);

    // Pure selection: seeded is selectable, no episode ctx required.
    try testing.expect(state.findLinkTrace(&proto, 2) == &cont);

    // The canonical loop-done continuation selector: the positional buffer
    // admits the seeded candidate and the arm probe (nativeFor, already
    // compiled here) resolves it as both the arm and run target.
    const sel = state.resolveLoopDoneCont(&proto, 2, null);
    try testing.expect(sel.arm == &cont);
    try testing.expect(sel.run == &cont);
}

test "B-iv.3 (doc 22 §B.5): armNativeLink .sibling_handoff arms a seeded child only under a fresh episode ctx" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.cache.clearRetainingCapacity(); // stack-backed traces

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "biv3-sibling",
        .num_registers = 1,
    };
    const parent_instrs = [_]IrInstr{
        .{ .op = .guard_true, .aux = 1 },
        .{ .op = .loop },
    };
    const parent_slots = try gpa.alloc(usize, parent_instrs.len);
    defer gpa.free(parent_slots);
    defer state.disarmAllLinks(); // registry borrows fixture slot storage
    @memset(parent_slots, 0);
    var parent: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 7 },
            .instrs = @constCast(&parent_instrs),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 81,
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa } },
    };
    // The SEEDED same-anchor sibling: pre-B-iv.3 the `.sibling_handoff` arm
    // refused it unconditionally on `inputs.len != 0`.
    var seed_inputs = [_]trace.InputSeed{undefined};
    var child: Trace = .{
        .code = .{
            .anchor = parent.code.anchor,
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .inputs = &seed_inputs,
        },
        .id = 82,
        .native = .{ .compiled = .{
            .page = undefined,
            .gpa = gpa,
            .ordinary_entry = 0xCAFE,
            .seed_plan = .{ .bits = 1 },
            .seed_prologue = true,
        } },
    };
    try state.registry.cache.append(gpa, &parent);
    try state.registry.cache.append(gpa, &child);

    // (1) No episode ctx at all → stubEnterable fail-closed → arm refused,
    // slot untouched (the pre-B-iv disposition).
    try testing.expect(!try state.armNativeLink(&parent, 0, &child, .sibling_handoff));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[0]);

    // (2) Stale ctx (frame token drifted since the episode stamp) → refused.
    const ctx = try gpa.create(trace.NativeSeedCtx);
    ctx.* = .{ .seed_fn = stubEnterableDummySeed };
    state.registry.native_seed_ctx = ctx; // state.deinit() destroys it
    ctx.proto = @ptrCast(&proto);
    ctx.call_seq = 7;
    state.region_policy.setContext(0, 8);
    try testing.expect(!try state.armNativeLink(&parent, 0, &child, .sibling_handoff));
    try testing.expectEqual(@as(usize, 0), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(@as(usize, 0), parent_slots[0]);

    // (3) Fresh ctx (tokens agree) → the seeded child ARMS: the page prologue
    // owns the seeding at entry (§B.4), so the bare jump is safe.
    state.region_policy.setContext(0, 7);
    try testing.expect(try state.armNativeLink(&parent, 0, &child, .sibling_handoff));
    try testing.expectEqual(@as(usize, 1), state.registry.native_physical.armed_links.items.len);
    try testing.expectEqual(ArmKind.sibling_handoff, state.registry.native_physical.armed_links.items[0].kind);
    try testing.expect(state.registry.native_physical.armed_links.items[0].child == &child);
    try testing.expectEqual(@as(usize, 0xCAFE), parent_slots[0]);
}

// ---------------------------------------------------------------------------
// Executor value-scratch frame stability.
//
// The tier-1a executor's `values` array is carved from a per-VM scratch stack
// (`TraceState.values_chunks`). Trace execution nests — the dispatcher holds a
// frame for the trace it entered while `driveChain` runs a candidate under it,
// and `runLinkedBurst` runs hops under that — so an inner push MUST NOT move the
// memory an outer frame points at.
//
// It used to. The scratch was one flat `ArrayListUnmanaged(Value)` grown with
// `resize`, and a candidate longer than the entering trace reallocated it: the
// dispatcher's slice, handed down as `driveChain`'s `.ir_numeric_for_done`
// payload, became a dangling pointer, and `flushNumericForLoopDone` read the
// freed block. Live on two corpus programs (`--trace nsieve-bit.lua 6`, 38-instr
// entry vs 59-instr candidate; `--trace scimark-sparse.lua 3000`, 44 vs 57), in
// ReleaseFast as well as Debug.
// ---------------------------------------------------------------------------

fn slicesOverlap(a: []const Value, b: []const Value) bool {
    const a0 = @intFromPtr(a.ptr);
    const b0 = @intFromPtr(b.ptr);
    return a0 < b0 + b.len * @sizeOf(Value) and b0 < a0 + a.len * @sizeOf(Value);
}

test "valuesPush: a nested oversized frame leaves the frame below it intact" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const outer_mark = state.valuesMark();
    defer state.valuesRelease(outer_mark);

    // The dispatcher's frame for the trace it entered.
    const outer = try state.valuesPush(38);
    for (outer, 0..) |*v, i| v.* = Value.int(@intCast(1000 + i));

    // A nested frame that cannot fit beside it — the shape that used to
    // reallocate a flat buffer out from under `outer`. Deliberately larger than
    // one chunk so the "grow the backing" path is the one under test, not just
    // "carve further along the same chunk".
    const inner_mark = state.valuesMark();
    const inner = try state.valuesPush(9000);
    for (inner) |*v| v.* = Value.int(-1);

    try testing.expect(!slicesOverlap(outer, inner));
    for (outer, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(1000 + i)), v.asInt());

    // Releasing the nested frame leaves the outer one addressable and unchanged.
    state.valuesRelease(inner_mark);
    for (outer, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(1000 + i)), v.asInt());

    // ...and the released space is handed straight back out rather than growing
    // the stack again (a burst re-pushes a frame per hop).
    const chunks_before = state.values_chunks.items.len;
    const reused = try state.valuesPush(9000);
    try testing.expectEqual(inner.ptr, reused.ptr);
    try testing.expectEqual(chunks_before, state.values_chunks.items.len);
    try testing.expect(!slicesOverlap(outer, reused));
}

test "valuesPush: repeated mark/push/release from the base state reuses one chunk" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // The dispatcher's shape: mark, push the entering trace's frame, release,
    // once per trace entry, always from an empty stack. Every cycle after the
    // first must be a pure fast-path carve out of the chunk already allocated.
    // Getting this wrong is not a correctness bug — it is a silent perf cliff,
    // and it cost ~1% of scimark-fft before the mark stored an offset instead
    // of the free slice (the base mark's slice predates chunk 0, so releasing
    // to it left the fast path permanently unreachable).
    var seen: ?[*]Value = null;
    for (0..64) |i| {
        const mark = state.valuesMark();
        const buf = try state.valuesPush(60);
        if (i == 0) seen = buf.ptr else try testing.expectEqual(seen.?, buf.ptr);
        state.valuesRelease(mark);
    }
    try testing.expectEqual(@as(usize, 1), state.values_chunks.items.len);
}

test "valuesPush: sibling frames that fit share a chunk and stay disjoint" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const mark = state.valuesMark();
    defer state.valuesRelease(mark);

    const a = try state.valuesPush(38);
    const b = try state.valuesPush(59);
    const c = try state.valuesPush(44);
    try testing.expectEqual(@as(usize, 1), state.values_chunks.items.len);
    try testing.expect(!slicesOverlap(a, b));
    try testing.expect(!slicesOverlap(b, c));
    try testing.expect(!slicesOverlap(a, c));

    // A zero-length frame is legal (a trace with no instructions) and consumes
    // nothing, so it can never push a sibling into a fresh chunk.
    const free_before = state.values_free;
    const empty = try state.valuesPush(0);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectEqual(free_before.len, state.values_free.len);
    try testing.expectEqual(free_before.ptr, state.values_free.ptr);
}

test "driveChain ir_numeric_for_done: a longer candidate cannot invalidate the caller's values" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Bytecode: pc 0 is the `for_loop` that owns the loop-done guard, so the
    // guard's recorded `aux` (its post-increment exit PC) is 1 — which is also
    // where the `.link` continuation is anchored. `flushNumericForLoopDone`
    // validates exactly this shape before it commits anything.
    const code = [_]Instr{
        .{ .op = .for_loop, .a = 0, .b = 0, .c = 0 },
        .{ .op = .ret, .a = 0, .b = 0, .c = 0 },
    };
    const proto = Proto{ .code = @constCast(&code), .name = "t", .num_registers = 4 };

    // The trace that side-exited: anchored away from the exit PC so the walk
    // looks at pc 1, with a loop-done `guard_true` at index 1 and a φ that
    // writes back to r2. That φ writeback is the observable: it reads
    // `values[0]` out of the caller-owned frame, which is precisely the slice
    // the old flat scratch used to free.
    var entry_f = [_]u16{0};
    const instrs_f = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0
        .{ .op = .guard_true, .a = 0, .aux = 1 }, // %1: loop-done guard, exit pc 1
        .{ .op = .phi, .a = 0, .b = 0, .aux = 2, .ty = .int }, // %2: r2 ← %0
        .{ .op = .loop }, // %3
    };
    var failed = Trace{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 10 },
            .instrs = @constCast(&instrs_f),
            .consts = &.{},
            .entry_slots = &entry_f,
            .entry_guards = &.{},
        },
    };

    // The continuation at pc 1: `.link`-terminated (the only shape a loop-done
    // chain will follow) and far longer than `failed`, so serving it forces the
    // scratch to grow. Its first guard fails immediately, so nothing downstream
    // of the flush runs and the drive returns the flushed resume PC.
    var entry_c = [_]u16{1};
    var instrs_c: [200]IrInstr = undefined;
    instrs_c[0] = .{ .op = .slot_load, .aux = 1 }; // %0: r1, which holds nil
    instrs_c[1] = .{ .op = .guard_int, .a = 0, .aux = 1 }; // %1: fails at once
    for (instrs_c[2 .. instrs_c.len - 1]) |*p| p.* = .{ .op = .loop }; // never reached
    instrs_c[instrs_c.len - 1] = .{ .op = .link, .aux = 1 };
    var cont = Trace{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 1 },
            .instrs = &instrs_c,
            .consts = &.{},
            .entry_slots = &entry_c,
            .entry_guards = &.{},
        },
    };
    try testing.expect(cont.code.instrs.len > failed.code.instrs.len);

    try state.registry.cache.append(gpa, &failed);
    try state.registry.cache.append(gpa, &cont);

    // The caller's frame, exactly as `enterSelectedTrace` takes it: sized for
    // the trace that ran, and still live while the chain drive runs beneath it.
    const mark = state.valuesMark();
    defer state.valuesRelease(mark);
    const vals = try state.valuesPush(failed.code.instrs.len);
    const sentinel: i64 = 0x5EED_5EED;
    for (vals) |*v| v.* = Value.int(sentinel);

    var regs = [_]Value{ Value.int(0), Value.nil(), Value.int(0), Value.int(0) };
    var tr_regs = TestRegs{ .regs = &regs };
    const chained = state.driveChain(
        &failed,
        .{ .completed = 0, .exit_instr = 1 },
        &proto,
        tr_regs.view(),
        .ir,
        .{ .ir_numeric_for_done = vals },
        &.{},
        false,
        false,
    );

    // The flush ran (that is what a non-null result with the continuation's PC
    // means) and wrote `values[0]` into r2. Read the raw lanes rather than
    // decoding a `Value`: when this regression is live the slot holds freed
    // memory, and asserting on a decoded tag would panic instead of failing.
    try testing.expect(chained != null);
    try testing.expectEqual(@as(?u32, 1), chained.?.resume_pc);
    try testing.expectEqual(@intFromEnum(value.Tag.int), tr_regs.tags[2]);
    try testing.expectEqual(@as(u64, @bitCast(sentinel)), tr_regs.pays[2]);

    // And the caller's frame is still its own memory afterwards.
    for (vals) |v| try testing.expectEqual(sentinel, v.asInt());

    state.registry.cache.clearRetainingCapacity();
}

test "noteRetContTransition (B1', task 27): a hot owner displaces a stale request under a different key" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.hotguard = 2;

    const proto = Proto{
        .code = &.{Instr.op0(.ret)},
        .name = "b1-displace",
        .num_registers = 1,
    };
    var owner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = trace.contAnchorPc(0) },
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 7,
    };
    // A stale request from another (retired/unsatisfiable) parent occupies
    // the single slot. Pre-B1' the early `!= null` return froze it forever.
    state.setPendingRetContArm(.{ .trace_id = 99, .exit_instr = 3 });

    // The owner's per-pc watch accumulates INDEPENDENTLY of the slot...
    state.noteRetContTransition(&owner, 5);
    try testing.expectEqual(@as(u32, 99), state.pending_ret_cont_arm.?.trace_id);
    // ...and its own hotguard crossing displaces the stale key.
    state.noteRetContTransition(&owner, 5);
    try testing.expectEqual(@as(u32, 7), state.pending_ret_cont_arm.?.trace_id);
    try testing.expectEqual(@as(u32, 5), state.pending_ret_cont_arm.?.exit_instr);

    // A same-key re-crossing is a no-op (the request is already filed) —
    // no ping-pong against itself, deterministic bounded churn.
    state.noteRetContTransition(&owner, 5);
    state.noteRetContTransition(&owner, 5);
    try testing.expectEqual(@as(u32, 7), state.pending_ret_cont_arm.?.trace_id);
    try testing.expectEqual(@as(u32, 5), state.pending_ret_cont_arm.?.exit_instr);
}

test "clearCache (B1', task 27): pending frame-link arm requests do not survive the epoch" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.setPendingRetContArm(.{ .trace_id = 1, .exit_instr = 2 });
    state.setPendingCallHeadArm(.{ .trace_id = 3, .exit_instr = 4 });
    state.clearCache();
    try testing.expectEqual(@as(?ExitKey, null), state.pending_ret_cont_arm);
    try testing.expectEqual(@as(?ExitKey, null), state.pending_call_head_arm);
}
