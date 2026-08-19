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
    fn seed(ctx: *const trace.NativeSeedCtx, t: *const Trace) u64 {
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
    defer state.cache.clearRetainingCapacity(); // stack/hand-owned traces
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
        .anchor = .{ .proto = &proto, .pc = 10 },
        .instrs = @constCast(&instrs_a),
        .consts = &.{},
        .entry_slots = &entry_a,
        .entry_guards = &.{},
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
        .anchor = .{ .proto = &proto, .pc = 10 }, // same anchor as A
        .instrs = @constCast(&instrs_b),
        .consts = &.{},
        .entry_slots = &entry_b,
        .entry_guards = &.{},
        .inputs = &inputs_b,
    };

    try state.cache.append(gpa, trace_a);
    try state.cache.append(gpa, trace_b);

    // --- 1. Fail closed: no ctx installed (hand-built TraceState) → the walk
    // must skip the seeded candidate WITHOUT consulting any twin, exactly the
    // pre-B-iii `inputs.len != 0` skip.
    var regs = [_]Value{ Value.int(0), Value.int(4) };
    var tr_regs = TestRegs{ .regs = &regs };
    {
        const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false);
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
    state.native_seed_ctx = ctx;

    // --- 2. THE hash-drift pin: the twin seeds slot 2 then reports
    // SEED_HASH_DECLINE — driveChain must STILL run the successor on tier-1a.
    // r0=0, r1=4, seed=2: iter 1 commits r0=2 (2<4); iter 2 computes 4<4 →
    // guard_true fails → completed=1. Both values prove the seed flowed in.
    {
        regs = .{ Value.int(0), Value.int(4) };
        const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false);
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
        const chained = state.driveChain(trace_a, .{ .completed = 0, .exit_instr = 1 }, &proto, tr_regs.view(), .ir, .ordinary_header, &.{trace_a}, false);
        try testing.expectEqual(@as(usize, 2), SeedStub.calls);
        try testing.expect(chained == null);
    }
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
    t: *const Trace,
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
        .id = 60,
        .anchor = .{ .proto = &proto, .pc = 1 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try testing.expect(!state.stubEnterable(&uncompiled, .ordinary, &proto));
    try testing.expect(!state.stubEnterable(&uncompiled, .linked, &proto));

    // (2) Compiled, only the ordinary entry present: kind-selective. Unseeded
    // plan (default) → ordinary passes with NO episode ctx; linked has no stub.
    var ordinary_only: Trace = .{
        .id = 61,
        .anchor = .{ .proto = &proto, .pc = 1 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .gpa = gpa, .ordinary_entry = 0xCAFE } },
    };
    try testing.expect(state.stubEnterable(&ordinary_only, .ordinary, &proto));
    try testing.expect(!state.stubEnterable(&ordinary_only, .linked, &proto));

    // (3) Seeded page (plan non-empty + prologue recorded, the §B.4 invariant
    // holding): fail-closed freshness ladder.
    var seeded: Trace = .{
        .id = 62,
        .anchor = .{ .proto = &proto, .pc = 1 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
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
    state.native_seed_ctx = ctx; // state.deinit() destroys it

    // (3b) Ctx present but never stamped (proto == null) → false.
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    // (3c) Ctx stamped for a DIFFERENT frame proto → false.
    ctx.proto = @ptrCast(&other_proto);
    ctx.call_seq = 7;
    state.region_context = .{ .depth = 0, .call_seq = 7 };
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    // (3d) Ctx matches the live proto but the trace is anchored elsewhere → false.
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &other_proto));

    // (3e) Fully fresh: ctx.proto == proto == anchor.proto, call_seq tokens
    // agree → true, for BOTH entry kinds (the prologue is entry-kind-uniform).
    ctx.proto = @ptrCast(&proto);
    try testing.expect(state.stubEnterable(&seeded, .ordinary, &proto));
    try testing.expect(state.stubEnterable(&seeded, .linked, &proto));

    // (3f) Frame token drift (new activation since the episode was stamped) → false.
    state.region_context = .{ .depth = 0, .call_seq = 8 };
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));

    // (3g) No region context at all (no frame transition observed yet) → false.
    state.region_context = null;
    try testing.expect(!state.stubEnterable(&seeded, .ordinary, &proto));
}
