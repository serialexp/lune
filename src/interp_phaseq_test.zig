//! Tests for doc 61 §7.1 (Phase Q): trace constant pools are not GC roots.
//! A collection retires every trace, and cancels the recording, that names a
//! constant the sweep is about to free, so liveness is the same in every tier.
//!
//! Program-level differentials live here alongside the structural tests of
//! the batch retirement (`TraceState.removeTraces`) they rest on.

const std = @import("std");
const interp = @import("interp.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const trace = @import("trace.zig");
const io = @import("io.zig");
const execlog = @import("execlog.zig");
const function = @import("function.zig");
const trace_recorder = @import("trace_recorder.zig");
const testing = std.testing;

const Vm = interp.Vm;
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;

const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;
const expectProgramTuned = util.expectProgramTuned;
const TraceMode = util.TraceMode;

// ---------------------------------------------------------------------------
// Program differentials: identical printed ids in all ten legs. Each prints a
// fresh table after the pooled string has become garbage; a pool that still
// rooted it would skip a re-intern in the JIT legs and print a lower id.
// ---------------------------------------------------------------------------

test "phase Q: a runtime-built find pattern only a trace pins is swept as in tier-0" {
    try expectProgram(
        \\local find = string.find
        \\local function f(p)
        \\  local n = 0
        \\  for i = 1, 2000 do if find("ab12", p) then n = n + 1 end end
        \\  return n
        \\end
        \\print(f("%d" .. "+"))
        \\for k = 1, 5000 do local junk = {} end
        \\local again = "%d" .. "+"
        \\print({})
    , "2000\ntable: 0x1471\n");
}

test "phase Q: a runtime-built gmatch pattern only a trace pins is swept as in tier-0" {
    // `hold` keeps the match results interned for the whole run, so the
    // stress legs (which sweep sooner) don't re-intern them; only the
    // pattern's liveness is under test.
    try expectProgram(
        \\local hold = { "1", "22", "333" }
        \\local function g(p)
        \\  local n = 0
        \\  for r = 1, 300 do for w in string.gmatch("a1 b22 c333", p) do n = n + #w end end
        \\  return n
        \\end
        \\print(g("%d" .. "+"))
        \\for k = 1, 5000 do local junk = {} end
        \\local again = "%d" .. "+"
        \\print({})
    , "1800\ntable: 0x15a0\n");
}

/// A test-only native that runs a full collection from inside a host call,
/// the in-run shape of `mh_collect` (doc 61 F3).
fn collectNative(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    vm.collect();
    return Value.nil();
}

fn installCollect(vm: *Vm) anyerror!void {
    const native = try vm.heap.newNative(collectNative, "collect");
    try vm.globals.set(vm.gpa, try vm.heap.internValue("collect"), Value.heap(&native.header));
}

fn expectRetiredInJitLegs(vm: *Vm, mode: TraceMode) anyerror!void {
    switch (mode) {
        .off => try testing.expectEqual(@as(u64, 0), vm.trace.retired_traces),
        else => try testing.expect(vm.trace.retired_traces >= 1),
    }
}

test "phase Q: a collection from a host call retires a patched trace and re-entry recovers" {
    // `f`'s loop is traced (and entry-patched in the executing legs) over the
    // pinned pattern. `collect()` runs with only the pool naming it, so the
    // trace retires mid-run; the next `f` call re-enters the loop through
    // the patched pc and must recover through the non-live path.
    try expectProgramTuned(
        \\local find = string.find
        \\local function f(p)
        \\  local n = 0
        \\  for i = 1, 2000 do if find("ab12", p) then n = n + 1 end end
        \\  return n
        \\end
        \\print(f("%d" .. "+"))
        \\collect()
        \\print(f("%a" .. "+"))
        \\pcall(function() collect() end)
        \\print(f("%d" .. "+"))
        \\print({})
    , "2000\n2000\n2000\ntable: 0xee\n", .{ .setup = installCollect, .inspect = expectRetiredInJitLegs });
}

/// How many armed links the checking collector has seen survive a teardown,
/// summed over the run (proves the native legs exercised real links).
var checked_links_seen: usize = 0;

/// `collect()` plus the bulk-teardown invariants, asserted immediately after
/// the collection — before any drain can re-arm or re-patch:
/// - every armed link's parent and child are live published traces;
/// - every edge-cache key names a live trace, and the cache equals a fresh
///   rebuild of the surviving cache;
/// - an OOM injected into that rebuild fails closed to an empty cache.
fn collectCheckedNative(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    vm.collect();
    const ts = &vm.trace;
    for (ts.registry.native_physical.armed_links.items) |link| {
        try testing.expect(!link.parent.doomed and !link.child.doomed);
        try testing.expect(ts.traceById(link.parent.id) == link.parent);
        try testing.expect(ts.traceById(link.child.id) == link.child);
    }
    checked_links_seen += ts.registry.native_physical.armed_links.items.len;

    var before = try ts.region_policy.edge_cache.clone(ts.gpa);
    defer before.deinit(ts.gpa);
    var it = before.iterator();
    while (it.next()) |e| try testing.expect(ts.traceById(e.key_ptr.trace_id) != null);
    ts.rebuildEdgeCache();
    try testing.expectEqual(before.count(), ts.region_policy.edge_cache.count());
    it = before.iterator();
    while (it.next()) |e| try testing.expectEqual(e.value_ptr.*, ts.region_policy.edge_cache.get(e.key_ptr.*).?);

    if (before.count() != 0) {
        const real = ts.gpa;
        var failing = std.testing.FailingAllocator.init(real, .{ .fail_index = 0 });
        ts.gpa = failing.allocator();
        ts.rebuildEdgeCache();
        ts.gpa = real;
        try testing.expectEqual(@as(u32, 0), ts.region_policy.edge_cache.count());
        ts.rebuildEdgeCache(); // restore for the rest of the run
    }
    return Value.nil();
}

fn installCollectChecked(vm: *Vm) anyerror!void {
    const native = try vm.heap.newNative(collectCheckedNative, "collect");
    try vm.globals.set(vm.gpa, try vm.heap.internValue("collect"), Value.heap(&native.header));
}

test "phase Q: a mid-run collection over linked nested-loop traces leaves no link or edge naming a retired trace" {
    checked_links_seen = 0;
    try expectProgramTuned(
        \\local find = string.find
        \\local function f(p)
        \\  local n = 0
        \\  for j = 1, 60 do
        \\    for i = 1, 40 do if find("ab12", p) then n = n + 1 end end
        \\    n = n + j
        \\  end
        \\  return n
        \\end
        \\print(f("%d" .. "+"))
        \\collect()
        \\print(f("%a" .. "+"))
        \\collect()
        \\print(f("%d" .. "+"))
        \\collect()
    , "4230\n4230\n4230\n", .{ .setup = installCollectChecked, .inspect = expectRetiredInJitLegs });
    try testing.expect(checked_links_seen > 0);
}

fn expectNoRetirement(vm: *Vm, mode: TraceMode) anyerror!void {
    try testing.expectEqual(@as(u64, 0), vm.trace.retired_traces);
    if (mode != .off) try testing.expect(vm.trace.registry.cache.items.len >= 1);
}

test "phase Q: a trace over a loaded chunk's pinned string constant survives every collection" {
    // Loaded-chunk constants are pinned, never marked: they are white at
    // every sweep but never freed. The predicate is the sweep's own
    // (`Heap.willFree`), so the trace survives; a white-only test would
    // retire it once the chunk's closure is gone. Stress legs collect at
    // every safepoint.
    try expectProgramTuned(
        \\local function run()
        \\  local h = load("local n = 0 for i = 1, 2000 do local s = 'pinned-k' n = n + #s end return n")
        \\  return h()
        \\end
        \\print(run())
        \\for k = 1, 3000 do local junk = {} end
        \\print("done")
    , "16000\ndone\n", .{ .inspect = expectNoRetirement });
}

// ---------------------------------------------------------------------------
// Batch retirement at a collection, over hand-built traces.
// ---------------------------------------------------------------------------

fn publishFake(vm: *Vm, proto: *const Proto, pc: u32, consts: []const Value) !*trace.Trace {
    const gpa = vm.trace.gpa;
    const t = try vm.trace.registry.allocate();
    var n: usize = 0;
    for (consts) |v| n += @intFromBool(v.isHeap());
    const heap_consts = try gpa.alloc(u32, n);
    var k: usize = 0;
    for (consts, 0..) |v, i| {
        if (!v.isHeap()) continue;
        heap_consts[k] = @intCast(i);
        k += 1;
    }
    t.code = .{
        .anchor = .{ .proto = proto, .pc = pc },
        .instrs = try gpa.alloc(trace.IrInstr, 0),
        .consts = try gpa.dupe(Value, consts),
        .heap_consts = heap_consts,
        .entry_slots = try gpa.alloc(u16, 0),
        .entry_guards = try gpa.alloc(trace.EntryGuard, 0),
    };
    try vm.trace.registry.publish(t);
    return t;
}

test "phase Q: a collection retires exactly the traces naming a dying constant, in one batch" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{ Instr.op0(.ret), Instr.op0(.ret), Instr.op0(.ret) };
    const proto = Proto{ .code = &code, .id = 9001, .name = "phaseq", .num_registers = 2 };

    const dead = try vm.heap.internValue("phaseq-dead-const");
    const live = try vm.heap.internValue("phaseq-live-const");
    try vm.globals.set(vm.gpa, try vm.heap.internValue("phaseq_keep"), live);

    // pc 0: only a doomed trace. pc 1: a doomed trace sharing the dying
    // constant, plus a survivor. pc 2: a survivor with no heap constant.
    const t1 = try publishFake(&vm, &proto, 0, &.{dead});
    const t2 = try publishFake(&vm, &proto, 1, &.{ Value.int(3), dead });
    const t3 = try publishFake(&vm, &proto, 1, &.{live});
    const t4 = try publishFake(&vm, &proto, 2, &.{Value.int(1)});
    const id1 = t1.id;
    const id2 = t2.id;
    const id3 = t3.id;
    const id4 = t4.id;

    const a0: trace.AnchorKey = .{ .proto = &proto, .pc = 0 };
    const a1: trace.AnchorKey = .{ .proto = &proto, .pc = 1 };
    try vm.trace.counters.put(gpa, a0, 99);
    try vm.trace.counters.put(gpa, a1, 99);

    // Logical state sourced from the traces.
    try vm.trace.provenance_edges.append(gpa, .{ .parent_id = id1, .exit_instr = 0, .child_id = id3 });
    try vm.trace.provenance_edges.append(gpa, .{ .parent_id = id3, .exit_instr = 0, .child_id = id4 });
    vm.trace.wants_side_trace = a0;
    vm.trace.side_want_src = .{ .trace_id = id1, .exit_instr = 0 };
    vm.trace.setPendingExitAnchor(a1);
    vm.trace.pending_exit_src = .{ .trace_id = id3, .exit_instr = 0 };
    try vm.trace.exec_logs.append(gpa, .{ .trace_id = id2 });
    try vm.trace.exec_logs.append(gpa, .{ .trace_id = id3 });

    const rebuilds0 = vm.trace.region_rebuilds;
    vm.collect();

    try testing.expect(vm.trace.traceById(id1) == null);
    try testing.expect(vm.trace.traceById(id2) == null);
    try testing.expect(vm.trace.traceById(id3) != null);
    try testing.expect(vm.trace.traceById(id4) != null);
    try testing.expectEqual(@as(usize, 2), vm.trace.registry.cache.items.len);
    // Order-preserving compaction.
    try testing.expectEqual(id3, vm.trace.registry.cache.items[0].id);
    try testing.expectEqual(id4, vm.trace.registry.cache.items[1].id);
    try testing.expectEqual(@as(u64, 2), vm.trace.retired_traces);
    try testing.expectEqual(@as(u64, 1), vm.trace.retire_batches);
    try testing.expectEqual(rebuilds0 + 1, vm.trace.region_rebuilds);
    // The constant really was swept.
    try testing.expect(vm.heap.internedLookup("phaseq-dead-const") == null);
    try testing.expect(vm.heap.internedLookup("phaseq-live-const") != null);
    // Anchor reopen only where no trace is left.
    try testing.expectEqual(@as(u32, 0), vm.trace.counters.get(a0).?);
    try testing.expectEqual(@as(u32, 99), vm.trace.counters.get(a1).?);
    // Relations, wants and logs touching a doomed trace are gone; the rest
    // are untouched.
    try testing.expectEqual(@as(usize, 1), vm.trace.provenance_edges.items.len);
    try testing.expectEqual(id3, vm.trace.provenance_edges.items[0].parent_id);
    try testing.expect(vm.trace.wants_side_trace == null);
    try testing.expect(vm.trace.side_want_src == null);
    try testing.expect(vm.trace.pending_exit_anchor != null);
    try testing.expectEqual(id3, vm.trace.pending_exit_src.?.trace_id);
    try testing.expectEqual(@as(usize, 1), vm.trace.exec_logs.items.len);
    try testing.expectEqual(id3, vm.trace.exec_logs.items[0].trace_id);

    // An empty collection retires nothing and rebuilds nothing.
    vm.collect();
    try testing.expectEqual(@as(u64, 1), vm.trace.retire_batches);
    try testing.expectEqual(rebuilds0 + 1, vm.trace.region_rebuilds);
    vm.trace.setPendingExitAnchor(null);
}

test "phase Q: removeTrace is the one-element batch" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{Instr.op0(.ret)};
    const proto = Proto{ .code = &code, .id = 9002, .name = "phaseq1", .num_registers = 1 };
    const t1 = try publishFake(&vm, &proto, 0, &.{Value.int(1)});
    const t2 = try publishFake(&vm, &proto, 0, &.{Value.int(2)});
    const id2 = t2.id;
    const rebuilds0 = vm.trace.region_rebuilds;
    vm.trace.removeTrace(t1);
    try testing.expectEqual(@as(u64, 1), vm.trace.retired_traces);
    try testing.expectEqual(rebuilds0 + 1, vm.trace.region_rebuilds);
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(id2, vm.trace.registry.cache.items[0].id);
}

test "phase Q: the trial walk's dead list retires once — a second retire is a no-op" {
    // The entry routine retires the widen-eviction dead list at its early
    // returns and the walk owner retires it again after the walk. With the
    // batch path that destroys the records, the second submission must see
    // an empty list (codex + antigravity Phase Q review blocker).
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{Instr.op0(.ret)};
    const proto = Proto{ .code = &code, .id = 9008, .name = "phaseq-walk", .num_registers = 1 };
    const t1 = try publishFake(&vm, &proto, 0, &.{Value.int(1)});
    const t2 = try publishFake(&vm, &proto, 0, &.{Value.int(2)});
    const keep = try publishFake(&vm, &proto, 0, &.{Value.int(3)});
    const keep_id = keep.id;

    var dead: Vm.WalkDead = .{};
    dead.add(t1);
    dead.add(t2);
    dead.retire(&vm.trace); // the entry routine's early-return retire
    dead.retire(&vm.trace); // the walk owner's post-walk retire
    try testing.expectEqual(@as(usize, 0), dead.len);
    try testing.expectEqual(@as(u64, 2), vm.trace.retired_traces);
    try testing.expectEqual(@as(u64, 1), vm.trace.retire_batches);
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(keep_id, vm.trace.registry.cache.items[0].id);
}

fn stubTrace(slots: []usize, linked_entry: usize) trace.Trace {
    return .{
        .code = .{
            .anchor = .{ .proto = undefined, .pc = 7 }, // loop-kind pc: the arm funnel reads anchorKind()
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .native = .{ .compiled = .{ .page = undefined, .slots = slots, .gpa = testing.allocator, .linked_entry = linked_entry } },
    };
}

test "phase Q: the bulk link teardown resets surviving parents to shared_exit and keeps the rest in order" {
    // P.slot0 → D (doomed child), P.slot1 → S, D.slot0 → S (doomed parent),
    // S.slot0 → P. One pass over the armed links: P.slot0 is reset to the
    // shared exit, the doomed parent's record is dropped WITHOUT writing
    // through its (about-to-be-freed) slot, and the two untouched links
    // survive in their original order.
    const gpa = testing.allocator;
    var state = trace.TraceState.init(gpa);
    defer state.deinit();
    const SHARED_EXIT: usize = 0; // no trampoline in this unit test
    try testing.expectEqual(@as(?usize, null), state.registry.mcode_arena.trampoline_exit);

    const p_slots = try gpa.alloc(usize, 2);
    defer gpa.free(p_slots);
    const d_slots = try gpa.alloc(usize, 1);
    defer gpa.free(d_slots);
    const s_slots = try gpa.alloc(usize, 1);
    defer gpa.free(s_slots);
    defer state.disarmAllLinks(); // the registry borrows fixture slot storage
    for ([_][]usize{ p_slots, d_slots, s_slots }) |s| @memset(s, SHARED_EXIT);

    const P_BODY: usize = 0xAAAA;
    const D_BODY: usize = 0xBBBB;
    const S_BODY: usize = 0xCCCC;
    var p = stubTrace(p_slots, P_BODY);
    var d = stubTrace(d_slots, D_BODY);
    var s = stubTrace(s_slots, S_BODY);
    p.id = 1;
    d.id = 2;
    s.id = 3;

    try testing.expect(try state.armNativeLink(&p, 0, &d, .link_terminal));
    try testing.expect(try state.armNativeLink(&p, 1, &s, .link_terminal));
    try testing.expect(try state.armNativeLink(&d, 0, &s, .link_terminal));
    try testing.expect(try state.armNativeLink(&s, 0, &p, .link_terminal));
    const native = &state.registry.native_physical;
    try testing.expectEqual(@as(usize, 4), native.armed_links.items.len);
    native.provenance_invalidated = false;

    d.doomed = true;
    native.resetLinksTouchingDoomed(&state.registry.mcode_arena);

    try testing.expectEqual(SHARED_EXIT, p_slots[0]);
    try testing.expectEqual(S_BODY, p_slots[1]);
    try testing.expectEqual(S_BODY, d_slots[0]); // never written through
    try testing.expectEqual(P_BODY, s_slots[0]);
    const links = native.armed_links.items;
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expect(links[0].parent == &p and links[0].child == &s);
    try testing.expect(links[1].parent == &s and links[1].child == &p);
    // A removed arm may be re-publishable from a surviving edge.
    try testing.expect(native.provenance_invalidated);
}

test "phase Q: a side recording whose parent retires mid-recording commits without its provenance edge" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{ Instr.op0(.ret), Instr.op0(.ret) };
    const proto = Proto{ .code = &code, .id = 9007, .name = "phaseq-side", .num_registers = 1 };

    // The parent names a constant that is about to die.
    const parent = try publishFake(&vm, &proto, 0, &.{try vm.heap.internValue("phaseq-side-dead")});
    const parent_id = parent.id;
    const src: trace.ExitKey = .{ .trace_id = parent_id, .exit_instr = 0 };

    // A side recording from the parent's exit is in flight, over live constants
    // only; a further want sourced from the same exit is pending.
    try startFakeRecording(&vm, &proto);
    vm.trace.rec.side_src = src;
    _ = try vm.trace.rec.konst(Value.int(5));
    vm.trace.wants_side_trace = .{ .proto = &proto, .pc = 0 };
    vm.trace.side_want_src = src;

    vm.collect();

    // The parent is gone; the recording keeps going with its (now unresolvable)
    // source, and the want naming the parent was dropped.
    try testing.expect(vm.trace.traceById(parent_id) == null);
    try testing.expect(vm.trace.isRecording());
    try testing.expectEqual(parent_id, vm.trace.rec.side_src.?.trace_id);
    try testing.expect(vm.trace.wants_side_trace == null);
    try testing.expect(vm.trace.side_want_src == null);

    // The child commits at the same anchor: no provenance edge, no crash.
    vm.trace.abort(.nyi_opcode);
    const child = try publishFake(&vm, &proto, 0, &.{Value.int(5)});
    vm.trace.finishSideTraceProvenance(child, src);
    try testing.expectEqual(@as(usize, 0), vm.trace.provenance_edges.items.len);
    try testing.expect(!vm.trace.provenance_arms_pending);
}

// ---------------------------------------------------------------------------
// The recorder.
// ---------------------------------------------------------------------------

fn startFakeRecording(vm: *Vm, proto: *const Proto) !void {
    try vm.trace.rec.reset(vm.trace.gpa, .{ .proto = proto, .pc = 0 }, 1);
    vm.trace.syncRecordingBit();
}

test "phase Q: a collection that sweeps a recording's constant cancels it with const_swept" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.record_aborts = true;
    var code = [_]Instr{Instr.op0(.ret)};
    const proto = Proto{ .code = &code, .id = 9003, .name = "phaseq-rec", .num_registers = 1 };
    try startFakeRecording(&vm, &proto);
    _ = try vm.trace.rec.konst(try vm.heap.internValue("phaseq-rec-dead"));
    vm.collect();
    try testing.expect(!vm.trace.isRecording());
    try testing.expectEqual(trace.AbortReason.const_swept, vm.trace.rec.abort_reason.?);
    try testing.expectEqual(trace.AbortReason.const_swept, vm.trace.abort_log.items[0].reason);
    try testing.expect(vm.heap.internedLookup("phaseq-rec-dead") == null);
}

test "phase Q: a recording whose constants all live survives a collection" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{Instr.op0(.ret)};
    const proto = Proto{ .code = &code, .id = 9004, .name = "phaseq-rec2", .num_registers = 1 };
    const kept = try vm.heap.internValue("phaseq-rec-kept");
    try vm.globals.set(vm.gpa, try vm.heap.internValue("phaseq_rec_keep"), kept);
    try startFakeRecording(&vm, &proto);
    _ = try vm.trace.rec.konst(kept);
    _ = try vm.trace.rec.konst(Value.int(4));
    vm.collect();
    try testing.expect(vm.trace.isRecording());
    vm.trace.abort(.nyi_opcode);
}

test "phase Q: a cancel mid-peel frees the owned link contract and never closes .link" {
    // `abort` would rewind an in-flight link peel into a `.link` close that
    // keeps the pool; `cancel` must not. The contract copy and the saved
    // register map are freed through `clearPendingLinkClose` (the leak
    // checker is the assertion).
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{Instr.op0(.ret)};
    const proto = Proto{ .code = &code, .id = 9005, .name = "phaseq-peel", .num_registers = 1 };
    try startFakeRecording(&vm, &proto);
    _ = try vm.trace.rec.konst(try vm.heap.internValue("phaseq-peel-dead"));
    const contract = try gpa.dupe(trace.EntryGuard, &.{.{ .slot = 0, .ty = .int }});
    const saved = try gpa.alloc(trace_recorder.RegSlot, 1);
    var plc: trace_recorder.PendingLinkClose = undefined;
    plc.contract = contract;
    plc.saved_reg_map = saved;
    plc.phase = .peeling;
    vm.trace.rec.pending_link_close = plc;
    vm.collect();
    try testing.expect(!vm.trace.isRecording());
    try testing.expect(vm.trace.rec.pending_link_close == null);
    try testing.expect(!vm.trace.rec.close_requested);
    try testing.expect(vm.trace.rec.link_target == null);
    try testing.expectEqual(trace.AbortReason.const_swept, vm.trace.rec.abort_reason.?);
}

test "phase Q: the recorder's constant dedup keys on object identity, not address" {
    // Simulate address reuse within one recording: the same header memory
    // later holds a different object (a new id). The pool must not hand back
    // the old ref for it.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var code = [_]Instr{Instr.op0(.ret)};
    const proto = Proto{ .code = &code, .id = 9006, .name = "phaseq-id", .num_registers = 1 };
    try startFakeRecording(&vm, &proto);
    const s = try vm.heap.internValue("phaseq-id-key");
    const r1 = try vm.trace.rec.konst(s);
    try testing.expectEqual(r1, try vm.trace.rec.konst(s));
    const h = s.asHeap();
    const old_id = h.id;
    h.id = old_id + 100_000;
    const r2 = try vm.trace.rec.konst(s);
    h.id = old_id;
    try testing.expect(r1 != r2);
    vm.trace.abort(.nyi_opcode);
}
