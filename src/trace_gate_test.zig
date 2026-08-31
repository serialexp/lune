//! Tests for `trace.zig` — gate.
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
const ExitKey = trace.ExitKey;
const IrInstr = trace.IrInstr;
const ProgramPoint = trace.ProgramPoint;
const RegionContext = trace.RegionContext;
const RegionId = trace.RegionId;
const RegionKey = trace.RegionKey;
const StructuralEdgeId = trace.StructuralEdgeId;
const Trace = trace.Trace;
const TraceState = trace.TraceState;

test "A-vii-c split: regionless onSideExit keeps the legacy gate; bare accountTraceRun is selection-only" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    // The A-vii-c ownership boundary (replacing the pre-flip A-ii.1 equivalence
    // pin): the `onSideExit` wrapper on a REGIONLESS trace reproduces the full
    // pre-flip behavior via `accountLegacyThrash` (strikes → gate at max_penalty;
    // a useful segment clears both), while bare `accountTraceRun` now touches
    // ONLY coverage + `hit_count` — never `penalty`/`gate`.
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 1 };
    var t_wrap: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var t_bare: Trace = .{ .id = 2, .anchor = .{ .proto = &proto, .pc = 1 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    // Feed exactly max_penalty low-yield events through both entry points.
    var i: u32 = 0;
    while (i < state.config.max_penalty) : (i += 1) {
        state.onSideExit(&t_wrap, 0, .entered);
        state.accountTraceRun(&t_bare, 0);
    }
    // The regionless wrapper gates exactly like the pre-flip machine; the bare
    // selection half no longer strikes at all.
    try testing.expect(state.isGated(t_wrap.anchor));
    try testing.expect(!state.isGated(t_bare.anchor));
    try testing.expectEqual(@as(u32, state.config.max_penalty), state.penalty.get(t_wrap.anchor).?);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(t_bare.anchor));
    try testing.expectEqual(@as(u64, 0), t_wrap.hit_count);
    try testing.expectEqual(@as(u64, 0), t_bare.hit_count);

    // A useful exit bumps hit_count through BOTH entry points, and clears the
    // wrapper anchor's penalty AND gate (legacy recovery semantics).
    state.onSideExit(&t_wrap, state.config.min_useful, .entered);
    state.accountTraceRun(&t_bare, state.config.min_useful);
    try testing.expectEqual(@as(u64, 1), t_wrap.hit_count);
    try testing.expectEqual(@as(u64, 1), t_bare.hit_count);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(t_wrap.anchor));
    try testing.expect(!state.isGated(t_wrap.anchor));
    try testing.expectEqual(@as(usize, 0), state.penalty.count());
    try testing.expectEqual(@as(usize, 0), state.gate.count());
}

test "A-vii-c gate machine: N=8 windows qualify+clear the owner, sub-N remainders strike, max_penalty gates and disarms" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A live self-loop region with a real owner anchor (the A-iv harness idiom).
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .id = 61, .code = &code, .name = "gate", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(3);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{.{ .proto_id = 61, .source_pc = 0 }}),
        .owner = .{ .proto = &proto, .pc = 0 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    const owner: AnchorKey = .{ .proto = &proto, .pc = 0 };
    const exit: ExitKey = .{ .trace_id = 9, .exit_instr = 0 };
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };
    // This test pins the design constant N = min_useful = 8 (doc 17 §A8-iii test 4).
    try testing.expectEqual(@as(u32, 8), state.config.min_useful);

    // (1) Seven traversals: no complete window — no flush, no qualification, no strike.
    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 7, .deferred);
    try testing.expect(!state.region_profit.get(key).?.useful_window_seen);
    try testing.expectEqual(@as(u64, 0), state.region_profit_flushes);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));

    // Pre-seed a penalty AND an active gate on the owner: the full window must clear BOTH.
    try state.penalty.put(gpa, owner, 3);
    state.gateAnchor(owner, .legacy_thrash);
    try testing.expect(state.isGated(owner));

    // (2) The eighth traversal completes exactly one N window: one useful flush,
    // qualification latched, owner penalty and gate both removed.
    _ = state.accountRegionProfit(exit, 1, .deferred);
    try testing.expect(state.region_profit.get(key).?.useful_window_seen);
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));
    try testing.expect(!state.isGated(owner));

    // (3) Exact-N exit: the observer-driven close right after a full window emits
    // NO zero-remainder flush (R2-1) and no spurious strike.
    state.observeRegionProgramPoint(61, 1, 1, 5);
    try testing.expectEqual(@as(usize, 0), state.regionProfitCount());
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));

    // (4) Arm a link, then repeated 1-traversal open/exit cycles each flush an
    // r=1 low-yield remainder striking the OWNER; at max_penalty the owner gates
    // and the gate install conservatively disarms EVERY armed link.
    const SHARED_EXIT: usize = 0;
    const parent_slots = try gpa.alloc(usize, 1);
    defer gpa.free(parent_slots);
    @memset(parent_slots, SHARED_EXIT);
    var link_parent: Trace = .{
        .id = 71,
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = parent_slots, .gpa = gpa, .linked_entry = 0xAAAA } },
    };
    var link_child: Trace = .{
        .id = 72,
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
        .native = .{ .compiled = .{ .page = undefined, .slots = &.{}, .gpa = gpa, .linked_entry = 0xBBBB } },
    };
    try testing.expect(try state.armNativeLink(&link_parent, 0, &link_child, .link_terminal));
    try testing.expectEqual(@as(usize, 1), state.armed_links.items.len);

    var j: u32 = 0;
    while (j < state.config.max_penalty) : (j += 1) {
        state.setRegionContext(1, 5);
        _ = state.accountRegionProfit(exit, 1, .deferred);
        state.observeRegionProgramPoint(61, 1, 1, 5); // departure → r=1 remainder strike
    }
    try testing.expectEqual(@as(u32, state.config.max_penalty), state.penalty.get(owner).?);
    try testing.expect(state.isGated(owner));
    try testing.expectEqual(@as(usize, 0), state.armed_links.items.len);
    try testing.expectEqual(SHARED_EXIT, parent_slots[0]);

    // (5) A-vii-c.1: the accounting boundary is CONSUMPTION, not membership. This
    // is the contract the A-vii-c review blocker turned on — physical membership
    // in a live region does NOT imply the region machine can gate a given receipt,
    // so suppressing the legacy machine on membership left a member's zero-work
    // and unclassified exits ungated by BOTH machines (measured shape: the
    // dispatcher's zero-iteration path at interp.zig, whose own comment reads
    // "apply the penalty"). Exactly one machine must account every receipt.
    var member_instrs = [_]IrInstr{ .{ .op = .slot_load, .aux = 0 }, .{ .op = .loop } };
    var member: Trace = .{ .id = 9, .anchor = .{ .proto = &proto, .pc = 1 }, .instrs = &member_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.dest_entry_regions.put(gpa, 9, try gpa.dupe(RegionId, &.{rid}));
    state.penalty.clearRetainingCapacity();
    state.gate.clearRetainingCapacity();

    // (5a) CONSUMED — exit 0 is classified into the live region and carries nonzero
    // work, so the region window owns the verdict and the member anchor is untouched
    // even though the segment itself was low-yield.
    state.setRegionContext(1, 5);
    state.onSideExitReceipt(&member, 0, 0, 1, .deferred, .entered);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));
    try testing.expectEqual(@as(u64, 1), state.region_profit.get(key).?.outer_traversals);

    // (5b) NOT consumed — same classified exit of the same live member, but zero
    // structural work. R2-1 keeps zero-work flushes silent, so if this did not fall
    // through to the legacy machine nothing would ever gate it: it must strike.
    state.onSideExitReceipt(&member, 0, 0, 0, .deferred, .entered);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(member.anchor).?);

    // (5c) NOT consumed — nonzero work, but exit 1 is absent from the edge cache,
    // so no accumulator receives it. Also a strike.
    state.onSideExitReceipt(&member, 0, 1, 4, .deferred, .entered);
    try testing.expectEqual(@as(u32, 2), state.penalty.get(member.anchor).?);

    // (5d) An unconsumed USEFUL segment still recovers the anchor the legacy way,
    // and the selection half bumps hit_count on every useful receipt regardless of
    // which machine took the profitability verdict.
    state.onSideExitReceipt(&member, state.config.min_useful, 1, 0, .deferred, .entered);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));
    try testing.expectEqual(@as(u64, 1), member.hit_count);

    // (5e) Tombstoning the region makes even a nonzero-work classified exit
    // unconsumable (`openRegion` refuses a non-armable def) — so the member reverts
    // to the legacy machine immediately, without waiting for a physical rebuild.
    state.region_defs.getPtr(rid).?.armable = false;
    state.setRegionContext(1, 5);
    state.onSideExitReceipt(&member, 0, 0, 1, .deferred, .entered);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(member.anchor).?);
}

test "gate-fix consumption boundary: qualified activations own member barren receipts, unclassified member work credits, synthetic charges region-owned" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A live region whose membership footprint covers pcs {0, 1} of proto 62.
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .id = 62, .code = &code, .name = "boundary", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(4);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = 62, .source_pc = 0 },
            .{ .proto_id = 62, .source_pc = 1 },
        }),
        .owner = .{ .proto = &proto, .pc = 0 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    var member_instrs = [_]IrInstr{ .{ .op = .slot_load, .aux = 0 }, .{ .op = .loop } };
    var member: Trace = .{ .id = 9, .anchor = .{ .proto = &proto, .pc = 1 }, .instrs = &member_instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try state.cache.append(gpa, &member); // traceById must resolve it (membership test)
    defer state.cache.clearRetainingCapacity(); // stack-backed traces: never destroy()
    var nonmember: Trace = .{ .id = 10, .anchor = .{ .proto = &proto, .pc = 5 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    const key: RegionKey = .{ .region_id = rid, .activation = 7 };

    // (a) UNQUALIFIED: classified zero-work receipt of the live member still
    // strikes legacy — an activation that never proves a useful window keeps
    // full pre-flip gating on its barren receipts (the A-vii-c blocker shape).
    state.setRegionContext(1, 7);
    _ = state.accountRegionProfit(.{ .trace_id = 9, .exit_instr = 0 }, 1, .deferred); // open, 1 traversal
    try testing.expect(!state.region_profit.get(key).?.useful_window_seen);
    state.onSideExitReceipt(&member, 0, 0, 0, .deferred, .entered);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(member.anchor).?);

    // (a') UNQUALIFIED: a synthetic zero charge on the member anchor strikes too.
    state.onSideExit(&member, 0, .entered);
    try testing.expectEqual(@as(u32, 2), state.penalty.get(member.anchor).?);

    // (b) Unclassified NONZERO-work member receipt (exit 1 absent from the edge
    // cache): credited to the LIVE accumulator instead of being dropped + struck.
    state.onSideExitReceipt(&member, 0, 1, 3, .deferred, .entered);
    try testing.expectEqual(@as(u64, 4), state.region_profit.get(key).?.outer_traversals);
    try testing.expectEqual(@as(u32, 2), state.penalty.get(member.anchor).?); // no new strike

    // (c) Qualify: enough credited work to flush a full window clears the owner's
    // penalty (owner == (proto,0)) and latches the bit — AND the qualification
    // amnesty (codex MAJOR 1) clears the stale pre-qualification penalty on
    // EVERY member anchor, since the region machine owns those receipts from
    // here on and legacy clears can no longer reach them.
    _ = state.accountRegionProfit(.{ .trace_id = 9, .exit_instr = 0 }, state.config.min_useful, .deferred);
    try testing.expect(state.region_profit.get(key).?.useful_window_seen);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));

    // (d) QUALIFIED: classified zero-work member receipt is now CONSUMED — an
    // intra-complex transition priced by the window/close verdicts, not legacy.
    state.onSideExitReceipt(&member, 0, 0, 0, .deferred, .entered);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor)); // no strike

    // (d') QUALIFIED: unclassified zero-work member receipt likewise consumed.
    state.onSideExitReceipt(&member, 0, 1, 0, .deferred, .entered);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));

    // (e) QUALIFIED: the synthetic steering charge (`onSideExit(member, 0)`) is
    // region-owned — no legacy strike, no legacy clear.
    state.onSideExit(&member, 0, .entered);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(member.anchor));

    // (e') Consumed barren receipts are COUNTED (codex BLOCKER 2): the streak so
    // far is 3 — (d), (d'), (e) — and a sustained barren-only run flushes one
    // synthetic low-yield strike at max_barren_run, restarting the streak.
    try testing.expectEqual(@as(u32, 3), state.region_profit.get(key).?.barren_run);
    const owner: AnchorKey = .{ .proto = &proto, .pc = 0 };
    var spins: u32 = 0;
    while (spins < state.config.max_barren_run - 3) : (spins += 1) state.onSideExit(&member, 0, .entered);
    try testing.expectEqual(@as(u32, 0), state.region_profit.get(key).?.barren_run);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(owner).?); // one decay strike on the OWNER
    // ...and credited work resets the streak AND (via a full window) the penalty.
    state.onSideExitReceipt(&member, 0, 1, state.config.min_useful, .deferred, .entered);
    try testing.expectEqual(@as(u32, 0), state.region_profit.get(key).?.barren_run);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(owner));

    // (f) A trace anchored OUTSIDE the footprint stays legacy-gated even while
    // the qualified activation is live.
    state.onSideExit(&nonmember, 0, .entered);
    try testing.expectEqual(@as(u32, 1), state.penalty.get(nonmember.anchor).?);

    // (g) Departure close still prices the remainder against the owner.
    const flushes_before = state.region_profit_flushes;
    state.observeRegionProgramPoint(62, 5, 1, 7); // pc 5 ∉ footprint → close
    try testing.expectEqual(@as(usize, 0), state.regionProfitCount());
    try testing.expect(state.region_profit_flushes > flushes_before);
}

test "A-vii-e.1 observer fast path: built on open, survive verdicts match the slow predicate, cleared on close" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A live region spanning two member points; open it via the canonical path
    // (accountRegionProfit → openRegion) so refreshObserverFast runs.
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .id = 83, .code = &code, .name = "fastpath", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(11);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = 83, .source_pc = 2 },
            .{ .proto_id = 83, .source_pc = 5 },
        }),
        .owner = .{ .proto = &proto, .pc = 2 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    const exit: ExitKey = .{ .trace_id = 9, .exit_instr = 0 };
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };

    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expect(state.region_profit.contains(key));

    // (1) The cache is live and mirrors the accumulator's root context, with the
    // membership bitset holding exactly {2, 5} of the [2, 6) span.
    const f = state.observer_fast orelse return error.MissingObserverFast;
    try testing.expectEqual(key, f.key);
    try testing.expectEqual(@as(u32, 1), f.root_frame_depth);
    try testing.expectEqual(@as(u64, 5), f.root_call_seq);
    try testing.expectEqual(@as(usize, 1), f.spans.len);
    try testing.expectEqual(@as(u32, 83), f.spans[0].proto_id);
    try testing.expectEqual(@as(u32, 2), f.spans[0].base_pc);
    try testing.expectEqual(@as(u32, 6), f.spans[0].limit_pc);
    try testing.expectEqual(@as(u64, 0b1001), f.spans[0].words[0]);

    // (2) Survive verdicts, all through the fast path: a member point at the root
    // frame, a member point again (idempotent), and ANY point in a deeper frame.
    state.observeRegionProgramPoint(83, 2, 1, 5);
    state.observeRegionProgramPoint(83, 5, 1, 5);
    state.observeRegionProgramPoint(99, 1234, 2, 77); // deeper frame: never a departure
    try testing.expect(state.region_profit.contains(key));
    try testing.expectEqual(@as(u64, 0), state.region_profit_flushes);

    // (3) A non-member pc closes even INSIDE the span bounds: pc 3 is in [2, 6)
    // but its bit is clear — remainder flush, cache cleared.
    state.observeRegionProgramPoint(83, 3, 1, 5);
    try testing.expect(!state.region_profit.contains(key));
    try testing.expect(state.observer_fast == null);
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);

    // (4) Re-open, then a sibling activation at the root depth (same depth,
    // different call_seq) closes even AT a member point — the activation-identity
    // half of the predicate.
    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expect(state.observer_fast != null);
    state.observeRegionProgramPoint(83, 2, 1, 6);
    try testing.expect(!state.region_profit.contains(key));
    try testing.expect(state.observer_fast == null);
    try testing.expectEqual(@as(u64, 2), state.region_profit_flushes);

    // (5) Shallower frames (codex e.1 review, MINOR): the accumulator opened at
    // depth 3 — a MEMBER point in a shallower frame survives (call_seq may
    // differ below the root; only equal-depth activations compete), while a
    // shallower NON-member point is a departure and closes.
    state.setRegionContext(3, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expect(state.observer_fast != null);
    state.observeRegionProgramPoint(83, 5, 2, 999); // member, depth 2 < 3: survives
    try testing.expect(state.region_profit.contains(.{ .region_id = rid, .activation = 5 }));
    state.observeRegionProgramPoint(83, 4, 2, 999); // non-member, depth 2 < 3: closes
    try testing.expect(!state.region_profit.contains(.{ .region_id = rid, .activation = 5 }));
    try testing.expectEqual(@as(u64, 3), state.region_profit_flushes);

    // (6) Multi-accumulator disables the fast path AT the funnel: opening a
    // second activation through openRegion takes count 1→2 and the refresh
    // there must NULL the cache (the slow loop owns multi-victim ordering);
    // a funnel close back to one rebuilds it for the SURVIVOR.
    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expect(state.observer_fast != null);
    state.setRegionContext(1, 78);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expectEqual(@as(usize, 2), state.regionProfitCount());
    try testing.expect(state.observer_fast == null);
    state.closeRegion(.{ .region_id = rid, .activation = 5 }); // count 2→1: rebuilds for 78
    const f2 = state.observer_fast orelse return error.MissingObserverFast;
    try testing.expectEqual(@as(u64, 78), f2.key.activation);
    state.closeRegion(.{ .region_id = rid, .activation = 78 });
    try testing.expect(state.observer_fast == null);
}

test "A-vii-e.2 observer inline cache: only survive verdicts answer inline, and the key is the whole query" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Same shape as the e.1 test: members {2, 5} of proto 83, root activation
    // (depth 1, call_seq 5). e.2 adds the INLINE probe over that cache, so what
    // this pins is the boundary between "answered without a call" and "deferred
    // to the real observer" — a false is always safe, a true never is.
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .id = 83, .code = &code, .name = "inline-fastpath", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(11);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = 83, .source_pc = 2 },
            .{ .proto_id = 83, .source_pc = 5 },
        }),
        .owner = .{ .proto = &proto, .pc = 2 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    const exit: ExitKey = .{ .trace_id = 9, .exit_instr = 0 };
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };

    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expect(state.region_profit.contains(key));

    // (1) A freshly built `observer_fast` leaves the inline cache COLD — it is
    // warmed by a survive verdict, never by the rebuild, so the first instruction
    // after any refresh always goes through the real observer.
    try testing.expect(state.observer_fast != null);
    try testing.expect(state.observer_hot.words == null);
    try testing.expect(!state.observeFast(83, 2, 1, 5));

    // (2) One slow survive verdict warms it; the identical query then answers
    // inline, as does the region's OTHER member point (same span, same key).
    state.observeRegionProgramPoint(83, 2, 1, 5);
    try testing.expect(state.observer_hot.words != null);
    try testing.expect(state.observeFast(83, 2, 1, 5));
    try testing.expect(state.observeFast(83, 5, 1, 5));

    // (3) Everything the slow predicate would answer differently is DECLINED
    // inline, so the real observer keeps ownership of every close decision:
    //   - a non-member pc inside the span bounds (pc 3 ∈ [2,6), bit clear),
    //   - a pc outside the span, on both sides (the `-%` wrap must not alias),
    //   - a different proto, a sibling activation, a different depth.
    try testing.expect(!state.observeFast(83, 3, 1, 5));
    try testing.expect(!state.observeFast(83, 9, 1, 5));
    try testing.expect(!state.observeFast(83, 0, 1, 5));
    try testing.expect(!state.observeFast(84, 2, 1, 5));
    try testing.expect(!state.observeFast(83, 2, 1, 6));
    try testing.expect(!state.observeFast(83, 2, 2, 5));
    // None of those declines touched the accumulator — declining is not closing.
    try testing.expect(state.region_profit.contains(key));
    try testing.expectEqual(@as(u64, 0), state.region_profit_flushes);

    // (4) A survive verdict answered inline must still refresh the activation
    // context, exactly as the observer's own member-hit branch does.
    state.region_context = null;
    try testing.expect(state.observeFast(83, 5, 1, 5));
    try testing.expectEqual(@as(u32, 1), state.region_context.?.depth);
    try testing.expectEqual(@as(u64, 5), state.region_context.?.call_seq);

    // (5) The hot entry borrows the owning span's bitset, so it must die with it.
    // Closing the region frees those words; a stale `words` pointer here would be
    // a use-after-free on the very next instruction.
    state.observeRegionProgramPoint(83, 3, 1, 5); // non-member → close
    try testing.expect(!state.region_profit.contains(key));
    try testing.expect(state.observer_fast == null);
    try testing.expect(state.observer_hot.words == null);
    try testing.expect(!state.observeFast(83, 2, 1, 5));

    // (6) …and so must the multi-accumulator disable: with two live accumulators
    // the slow loop owns victim ordering, so the inline cache may not answer.
    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    state.observeRegionProgramPoint(83, 2, 1, 5); // warm
    try testing.expect(state.observeFast(83, 2, 1, 5));
    state.setRegionContext(1, 78);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expectEqual(@as(usize, 2), state.regionProfitCount());
    try testing.expect(state.observer_hot.words == null);
    try testing.expect(!state.observeFast(83, 2, 1, 5));
    state.closeRegion(.{ .region_id = rid, .activation = 5 });
    state.closeRegion(.{ .region_id = rid, .activation = 78 });
}

test "A-vii-e.2 observer inline cache: differential — the accelerated call site is state-identical to the bare observer" {
    const gpa = testing.allocator;
    // The accelerator's whole contract is "the interpreter's call site behaves
    // exactly as it did before". Prove it differentially: two identically-built
    // states driven by the same query stream, one through the interp.zig call
    // site (`observeFast` first, real observer on a decline) and one through the
    // bare observer, must end in the same accumulator state with the same flush
    // history. A cache that answered even one verdict wrongly diverges here.
    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .id = 83, .code = &code, .name = "differential", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(11);
    const exit: ExitKey = .{ .trace_id = 9, .exit_instr = 0 };

    // {proto_id, pc, depth, call_seq}; a null entry re-opens the region instead.
    const Query = ?struct { u32, u32, u32, u64 };
    const stream = [_]Query{
        .{ 83, 2, 1, 5 }, // member at the root activation — the warm case
        .{ 83, 5, 1, 5 }, // the span's other member
        .{ 83, 2, 1, 5 },
        .{ 99, 1234, 2, 77 }, // deeper frame: survives whatever the pc
        .{ 83, 5, 1, 5 },
        .{ 83, 5, 2, 5 }, // deeper frame at a member pc
        .{ 83, 3, 1, 5 }, // non-member INSIDE the span bounds → close
        .{ 83, 2, 1, 5 }, // nothing live: both are no-ops
        null, // re-open
        .{ 83, 5, 1, 5 },
        .{ 84, 5, 1, 5 }, // member pc, wrong proto → close
        null,
        .{ 83, 2, 1, 5 },
        .{ 83, 2, 1, 6 }, // sibling activation at the root depth → close
        null,
        .{ 83, 5, 1, 5 },
        .{ 83, 0, 1, 5 }, // below the span base (the `-%` wrap case) → close
        null,
        .{ 83, 2, 1, 5 },
        .{ 83, 9, 1, 5 }, // past the span limit → close
    };

    var states: [2]TraceState = .{ TraceState.init(gpa), TraceState.init(gpa) };
    defer for (&states) |*s| s.deinit();
    for (&states, 0..) |*state, which| {
        try state.region_defs.put(gpa, rid, .{
            .members = try gpa.dupe(StructuralEdgeId, &.{}),
            .member_points = try gpa.dupe(ProgramPoint, &.{
                .{ .proto_id = 83, .source_pc = 2 },
                .{ .proto_id = 83, .source_pc = 5 },
            }),
            .owner = .{ .proto = &proto, .pc = 2 },
            .classifier = .{ .kind = .self_loop, .member_count = 1 },
            .armable = true,
        });
        try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
        state.setRegionContext(1, 5);
        _ = state.accountRegionProfit(exit, 3, .deferred);

        for (stream) |maybe_q| {
            const q = maybe_q orelse {
                state.setRegionContext(1, 5);
                _ = state.accountRegionProfit(exit, 3, .deferred);
                continue;
            };
            // which == 0: the interp.zig call site, verbatim. which == 1: bare.
            if (which == 0) {
                if (state.regionProfitCount() != 0 and !state.observeFast(q[0], q[1], q[2], q[3]))
                    state.observeRegionProgramPoint(q[0], q[1], q[2], q[3]);
            } else {
                if (state.regionProfitCount() != 0)
                    state.observeRegionProgramPoint(q[0], q[1], q[2], q[3]);
            }
        }
    }

    try testing.expectEqual(states[1].regionProfitCount(), states[0].regionProfitCount());
    try testing.expectEqual(states[1].region_profit_flushes, states[0].region_profit_flushes);
    try testing.expectEqual(states[1].region_profit_flushed_work, states[0].region_profit_flushed_work);
    try testing.expectEqual(states[1].region_context.?.depth, states[0].region_context.?.depth);
    try testing.expectEqual(states[1].region_context.?.call_seq, states[0].region_context.?.call_seq);
    // The stream ends on a close, and it must be the same close on both sides.
    try testing.expectEqual(@as(usize, 0), states[0].regionProfitCount());
    try testing.expect(states[1].region_profit_flushes > 0);
}

test "A-vii-e.1 observer fast path: an over-cap pc range declines the cache; the slow path still closes" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Member pcs 4M+ apart: the per-proto span exceeds the bitset range cap, so
    // refreshObserverFast must decline (no giant allocation, no u32 overflow) and
    // the slow scan must still deliver both verdicts.
    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .id = 84, .code = &code, .name = "sparse", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(12);
    try state.region_defs.put(gpa, rid, .{
        .members = try gpa.dupe(StructuralEdgeId, &.{}),
        .member_points = try gpa.dupe(ProgramPoint, &.{
            .{ .proto_id = 84, .source_pc = 0 },
            .{ .proto_id = 84, .source_pc = (1 << 22) + 1 },
        }),
        .owner = .{ .proto = &proto, .pc = 0 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, try gpa.dupe(RegionId, &.{rid}));
    const exit: ExitKey = .{ .trace_id = 9, .exit_instr = 0 };
    const key: RegionKey = .{ .region_id = rid, .activation = 5 };

    state.setRegionContext(1, 5);
    _ = state.accountRegionProfit(exit, 3, .deferred);
    try testing.expect(state.region_profit.contains(key));
    try testing.expect(state.observer_fast == null); // declined, not mis-built

    state.observeRegionProgramPoint(84, (1 << 22) + 1, 1, 5); // member via slow path: survives
    try testing.expect(state.region_profit.contains(key));
    state.observeRegionProgramPoint(84, 1, 1, 5); // non-member via slow path: closes
    try testing.expect(!state.region_profit.contains(key));
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
}

test "A-iv region_profit: windows persist across physical re-entry and observer closes only on departure" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .id = 41, .code = &code, .name = "region", .num_registers = 1 };
    const rid: RegionId = @enumFromInt(7);
    const points = try gpa.dupe(ProgramPoint, &.{.{ .proto_id = 41, .source_pc = 0 }});
    const members = try gpa.dupe(StructuralEdgeId, &.{});
    try state.region_defs.put(gpa, rid, .{
        .members = members,
        .member_points = points,
        .owner = .{ .proto = &proto, .pc = 0 },
        .classifier = .{ .kind = .self_loop, .member_count = 1 },
        .armable = true,
    });
    const source_set = try gpa.dupe(RegionId, &.{rid});
    try state.source_exit_regions.put(gpa, .{ .trace_id = 9, .exit_instr = 0 }, source_set);

    state.setRegionContext(1, 99);
    _ = state.accountRegionProfit(.{ .trace_id = 9, .exit_instr = 0 }, 3, .deferred);
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    const key: RegionKey = .{ .region_id = rid, .activation = 99 };
    try testing.expectEqual(@as(u64, 3), state.region_profit.get(key).?.outer_traversals);

    // Physical retirement/re-arm does not touch region_profit: another receipt for
    // the same logical id resumes the same window and crosses N=8 exactly once.
    _ = state.accountRegionProfit(.{ .trace_id = 9, .exit_instr = 0 }, 5, .deferred);
    try testing.expectEqual(@as(u64, 8), state.region_profit.get(key).?.outer_traversals);
    try testing.expectEqual(@as(u64, 8), state.region_profit.get(key).?.window_base);
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    state.observeRegionProgramPoint(41, 0, 1, 99);
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    state.observeRegionProgramPoint(41, 1, 1, 99);
    try testing.expectEqual(@as(usize, 0), state.regionProfitCount());
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes); // exact-N exit: no zero remainder
}

test "A-iv region_profit: activation cleanup drops only the dying activation" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    const a: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 10 };
    const b: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 11 };
    try state.region_profit.put(gpa, a, .{ .outer_traversals = 2, .root_frame_depth = 1, .root_call_seq = 10 });
    try state.region_profit.put(gpa, b, .{ .outer_traversals = 4, .root_frame_depth = 2, .root_call_seq = 11 });
    state.dropRegionActivation(11);
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    try testing.expect(state.region_profit.contains(a));
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(u64, 4), state.region_profit_flushed_work);
}

test "A-iv region_profit: same-activation owner collision flushes old before replacement" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .id = 55, .code = &code, .name = "cardinality", .num_registers = 1 };
    const r1: RegionId = @enumFromInt(1);
    const r2: RegionId = @enumFromInt(2);
    inline for (.{ r1, r2 }) |rid| {
        try state.region_defs.put(gpa, rid, .{
            .members = try gpa.dupe(StructuralEdgeId, &.{}),
            .member_points = try gpa.dupe(ProgramPoint, &.{.{ .proto_id = 55, .source_pc = 0 }}),
            .owner = .{ .proto = &proto, .pc = 0 },
            .classifier = .{ .kind = .self_loop, .member_count = 1 },
            .armable = true,
        });
    }
    const ctx: RegionContext = .{ .depth = 1, .call_seq = 77 };
    const old = state.openRegion(r1, ctx).?;
    state.region_profit.getPtr(old).?.outer_traversals = 3;
    _ = state.openRegion(r2, ctx).?; // direct H-3 collision/replacement path
    try testing.expectEqual(@as(usize, 1), state.regionProfitCount());
    try testing.expect(state.region_profit.contains(.{ .region_id = r2, .activation = 77 }));
    try testing.expectEqual(@as(u64, 1), state.region_profit_flushes);
    try testing.expectEqual(@as(u64, 3), state.region_profit_flushed_work);
}

// ---------------------------------------------------------------------------
// Doc 33 — entry refusal is candidate evidence, not anchor thrash.
// ---------------------------------------------------------------------------

test "doc 33: entry refusals neither strike nor gate the anchor" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .code = &code, .name = "refusal", .num_registers = 1 };
    var t: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    var i: u32 = 0;
    while (i < state.config.max_entry_refusals) : (i += 1)
        state.onSideExit(&t, 0, .entry_refusal);

    try testing.expectEqual(state.config.max_entry_refusals, t.consec_refusals);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(t.anchor));
    try testing.expect(!state.isGated(t.anchor));
}

test "doc 33: an entry refusal does not clear an existing strike" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .code = &code, .name = "no-clear", .num_registers = 1 };
    var t: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    state.onSideExit(&t, 0, .entered);
    state.onSideExit(&t, 0, .entered);
    const before = state.penalty.get(t.anchor).?;
    state.onSideExit(&t, 0, .entry_refusal);

    try testing.expectEqual(@as(u32, 2), before);
    try testing.expectEqual(before, state.penalty.get(t.anchor).?);
    try testing.expectEqual(@as(u32, 1), t.consec_refusals);
}

test "doc 33: alternating deopts and refusals gate on deopts alone" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .code = &code, .name = "alternate", .num_registers = 1 };
    var t: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    var i: u32 = 0;
    while (i < state.config.max_penalty) : (i += 1) {
        state.onSideExit(&t, 0, .entered);
        state.onSideExit(&t, 0, .entry_refusal);
    }

    try testing.expectEqual(state.config.max_penalty, state.penalty.get(t.anchor).?);
    try testing.expect(state.isGated(t.anchor));
}

test "doc 33: max consecutive refusals are tracked but do not suppress selection" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .code = &code, .name = "suppress", .num_registers = 1 };
    var refused: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .hit_count = 10 };
    try state.cache.append(gpa, &refused);
    defer state.cache.clearRetainingCapacity();

    var i: u32 = 0;
    while (i < state.config.max_entry_refusals) : (i += 1)
        state.onSideExit(&refused, 0, .entry_refusal);

    // The counter saturates but the trace remains selectable — suppression
    // would deadlock (a skipped trace can never reset its counter).
    try testing.expect(refused.consec_refusals >= state.config.max_entry_refusals);
    try testing.expectEqual(&refused, state.findTrace(&proto, 0).?);
    try testing.expect(!state.isGated(refused.anchor));
}

test "doc 33: a body entry resets the refusal streak" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .code = &code, .name = "reset", .num_registers = 1 };
    var t: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };

    var i: u32 = 0;
    while (i < state.config.max_entry_refusals - 1) : (i += 1)
        state.onSideExit(&t, 0, .entry_refusal);
    state.onSideExit(&t, 0, .entered);

    try testing.expectEqual(@as(u32, 0), t.consec_refusals);
}

test "doc 33: a maxed refusal counter does not suppress the candidate from selection" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{Instr.op0(.load_nil)};
    const proto = Proto{ .code = &code, .name = "siblings", .num_registers = 1 };
    const anchor: AnchorKey = .{ .proto = &proto, .pc = 0 };
    // A trace with a maxed refusal counter is still selectable — suppression
    // deadlocks (a skipped trace can never be entered, so the counter can
    // never reset). The counter is observational, not a gate.
    var refused: Trace = .{ .id = 1, .anchor = anchor, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .hit_count = 100, .consec_refusals = state.config.max_entry_refusals };
    var sibling: Trace = .{ .id = 2, .anchor = anchor, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .hit_count = 1 };
    try state.cache.append(gpa, &refused);
    try state.cache.append(gpa, &sibling);
    defer state.cache.clearRetainingCapacity();

    // findTrace returns the highest-hit candidate; the maxed counter does not
    // exclude it. Both candidates remain eligible, and the anchor is not gated.
    try testing.expectEqual(&refused, state.findTrace(&proto, 0).?);
    try testing.expect(!state.isGated(anchor));
}

// ---------------------------------------------------------------------------
// Doc 31 — record vs dispatch gate split (D1) + clear-on-productive (D2).
// The unit half of the §6 matrix; the e2e ratchet regression lives in
// interp_native_test.zig, the entry-patch interactions in
// trace_entrypatch_test.zig.
// ---------------------------------------------------------------------------

test "doc 31 D2: any productive receipt clears the strike; only consecutive zeros gate" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 1 };
    var t: Trace = .{ .id = 1, .anchor = .{ .proto = &proto, .pc = 0 }, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    const key = t.anchor;

    // The str_gmatch ratchet shape: productive receipts BELOW min_useful
    // (7-token instances) with an isolated designed-exit zero (exhaustion,
    // guard_gc admission) per instance. Under the old `completed >=
    // min_useful` clear the zeros ratcheted the penalty monotonically —
    // the productive receipts could never un-earn them (measured: 2.6%
    // native residency on a healthy trace). Now each productive receipt
    // resets the strike, so this alternation runs forever without gating.
    var i: u32 = 0;
    while (i < state.config.max_penalty * 4) : (i += 1) {
        state.onSideExit(&t, state.config.min_useful - 1, .entered); // productive, below min_useful
        state.onSideExit(&t, 0, .entered); // designed-exit zero
        try testing.expect(!state.isGated(key));
        try testing.expect((state.penalty.get(key) orelse 0) <= 1);
    }
    try testing.expectEqual(@as(usize, 0), state.gate.count());

    // Turnstile preserved: consecutive zeros with NO productive receipt in
    // between (gc_stress-shaped anchors, corrupted iterator state) still
    // reach max_penalty and gate exactly as before.
    var j: u32 = 0;
    while (j < state.config.max_penalty) : (j += 1) state.onSideExit(&t, 0, .entered);
    try testing.expect(state.isGated(key));

    // The clear is dispatch-only: pre-seed a record gate, then a single
    // productive receipt (even completed=1) clears penalty AND the dispatch
    // gate but never the record gate — productive dispatch is not evidence
    // about recording.
    state.gateRecordAnchor(key, .record_abort);
    state.onSideExit(&t, 1, .entered);
    try testing.expectEqual(@as(?u32, null), state.penalty.get(key));
    try testing.expect(!state.isGated(key));
    try testing.expectEqual(@as(usize, 0), state.gate.count());
    try testing.expect(state.record_gate.contains(key));
}

test "doc 31 D1: record and dispatch gates escalate and expire independently" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = [_]Instr{ Instr.op0(.load_nil), Instr.op0(.load_nil) };
    const proto = Proto{ .code = &code, .name = "t", .num_registers = 1 };
    const key: AnchorKey = .{ .proto = &proto, .pc = 0 };

    // One record strike: recording is barred through the cooldown; dispatch
    // never is.
    state.gateRecordAnchor(key, .record_abort);
    try testing.expect(state.isRecordGated(key));
    try testing.expect(!state.isGated(key));
    try testing.expect(state.recordingBarred(key));

    // Cooldown elapses: recording eligible again, but the map entry remains
    // (the onBackEdge retry probe depends on `contains`).
    state.tick = state.record_gate.get(key).?.retry_at;
    try testing.expect(!state.isRecordGated(key));
    try testing.expect(!state.recordingBarred(key));
    try testing.expect(state.record_gate.contains(key));

    // Record-map permanence (max_strikes) bars recording forever but never
    // dispatch: the committed traces keep running.
    var i: u32 = 0;
    while (i < state.config.max_strikes) : (i += 1) state.gateRecordAnchor(key, .record_abort);
    state.tick = std.math.maxInt(u64); // no cooldown can save it
    try testing.expect(state.isRecordGated(key));
    try testing.expect(!state.isGated(key));
    try testing.expect(state.recordingBarred(key));

    // Dispatch-map permanence bars BOTH (recordingBarred consults both
    // maps), and `gateNativeUnsupported` still writes the dispatch map —
    // the tier-1a-slower protection is intact.
    const key2: AnchorKey = .{ .proto = &proto, .pc = 1 };
    state.gateNativeUnsupported(key2);
    try testing.expect(state.gate.contains(key2));
    var k: u32 = 0;
    while (k < state.config.max_strikes) : (k += 1) state.gateAnchor(key2, .native_unsupported);
    try testing.expect(state.isGated(key2));
    try testing.expect(state.recordingBarred(key2));
    try testing.expect(!state.isRecordGated(key2)); // record map untouched
}

test "doc 31: an aborted root recording retries after the record cooldown despite a stale hot counter" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();
    state.config.hotloop = 3;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    const key: AnchorKey = .{ .proto = &proto, .pc = 7 };

    // Warm to hot: the third back-edge arms (the one-shot `== hotloop`
    // crossing).
    state.onBackEdge(&proto, 7, RegWindow.empty);
    state.onBackEdge(&proto, 7, RegWindow.empty);
    state.onBackEdge(&proto, 7, RegWindow.empty);
    try testing.expect(state.isRecording());

    // Simulate the abort's observable effect: the recording dies and the
    // anchor is record-gated (`abort()` → `gateRecordAnchor(.record_abort)`).
    state.rec.active = false;
    state.gateRecordAnchor(key, .record_abort);

    // While the record cooldown runs, back-edges do NOT re-arm...
    state.onBackEdge(&proto, 7, RegWindow.empty);
    try testing.expect(!state.isRecording());

    // ...but once it elapses, the `contains` probe grants the one retry even
    // though the warming counter (now 5) is far past the `== hotloop`
    // crossing. Without record_gate in that probe an aborted ROOT recording
    // could never retry (doc 31 §3, review B3).
    state.tick = state.record_gate.get(key).?.retry_at;
    state.onBackEdge(&proto, 7, RegWindow.empty);
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(u32, 7), state.rec.anchor.pc);
}

test "doc 31: a pending continuation/replay-side request gated after creation is declined at start" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    const key: AnchorKey = .{ .proto = &proto, .pc = 4 };

    // Continuation request created, then the anchor is gated before tier-0
    // reaches it: the request is consumed but no recording starts (doc 31
    // §3, review B3 — final eligibility check at `rec.reset` time).
    state.pending_exit_anchor = key;
    state.gateAnchor(key, .legacy_thrash);
    state.maybeStartContinuation(&proto, 4);
    try testing.expect(!state.isRecording());
    try testing.expectEqual(@as(?AnchorKey, null), state.pending_exit_anchor);

    // Same for the replay-side path, with a RECORD gate this time — both
    // maps bar recording starts.
    _ = state.gate.remove(key);
    state.pending_replay_anchor = key;
    state.gateRecordAnchor(key, .record_abort);
    state.maybeStartReplaySide(&proto, 4);
    try testing.expect(!state.isRecording());
    try testing.expectEqual(@as(?AnchorKey, null), state.pending_replay_anchor);

    // Control: with both gates clear the same request DOES start a recording
    // — the decline above was the gate, not the plumbing.
    _ = state.record_gate.remove(key);
    state.pending_exit_anchor = key;
    state.maybeStartContinuation(&proto, 4);
    try testing.expect(state.isRecording());
}

test "doc 31 D1: clearCache drops the record gate (epoch boundary, leak-checked)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t" };
    state.gateRecordAnchor(.{ .proto = &proto, .pc = 0 }, .record_abort);
    state.gateRecordAnchor(.{ .proto = &proto, .pc = 1 }, .commit_failure);
    try testing.expectEqual(@as(usize, 2), state.record_gate.count());
    state.clearCache();
    try testing.expectEqual(@as(usize, 0), state.record_gate.count());
    // `deinit` under std.testing.allocator leak-checks the map allocation
    // itself (doc 31 §6 test 9).
}
