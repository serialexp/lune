//! Tests for `keyframeser.zig` — resume.
//!
//! Extracted verbatim from `keyframeser.zig`; bodies are unchanged.
//! Shared harness lives in `keyframeser_testutil.zig`.

const keyframeser = @import("keyframeser.zig");
const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const interp = @import("interp.zig");
const gc = @import("gc.zig");
const key_order = @import("key_order.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");
const trace = @import("trace.zig");
const Value = value.Value;
const GcHeader = object.GcHeader;
const Proto = bytecode.Proto;
const Vm = interp.Vm;
pub const schema = @import("gen/trace_schema.zig");
const testing = std.testing;
const mahina_parser = @import("parser.zig");
const mahina_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

const NativeRegistry = keyframeser.NativeRegistry;
const encodeSnapshot = keyframeser.encodeSnapshot;
const restore = keyframeser.restore;
const snapshot_format_version = keyframeser.snapshot_format_version;

const util = @import("keyframeser_testutil.zig");
const RefRun = util.RefRun;
const expectRestoreError = util.expectRestoreError;
const referenceRun = util.referenceRun;
const sNil = util.sNil;

// ---------------------------------------------------------------------------
// F2c — mid-execution capture + resume
// ---------------------------------------------------------------------------
//
// The F2b headline (`encodeSnapshot ∘ restore == identity`) was only ever proven
// for a *final-state* snapshot (empty stack/frames). F2c suspends execution at a
// mid-loop / mid-call safepoint, captures the live stack + frame cursors, restores
// into a fresh VM, and **re-executes forward** to the same result. The resumed VM
// borrows the original program image (`chunk.proto`), whose string constants live
// in the *compile-time* heap — a different heap than the restored one. That works
// only because heap identity is by stable `GcHeader.id` (value.zig `eql`), not by
// address: a borrowed proto constant and its restored twin share an id, so a
// resumed `get_global`/table lookup resolves. (Before the id-based `eql` fix this
// test failed with `TypeError`: `print` resolved to `nil`.)

const SuspendCtl = interp.SuspendCtl;

/// Suspend `source` at `ctl`, snapshot mid-execution, restore into a fresh VM,
/// resume to completion, and assert full equivalence to `ref`:
///   (a) the program actually suspended (didn't run straight through);
///   (b) F2b byte-identity holds mid-execution: `encodeSnapshot(restore(mid)) == mid`;
///   (c) `out_before ++ out_after == F`  (output equivalence — the headline);
///   (d) the resumed final-state snapshot `== Sf`  (state equivalence).
/// Returns the mid snapshot bytes (caller owns) so determinism can be cross-checked.
fn expectResume(gpa: std.mem.Allocator, source: [:0]const u8, ctl: SuspendCtl, ref: RefRun) ![]u8 {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // The suspend VM owns the heap the program image's constants are interned
    // into; it must outlive the restored VM that borrows `chunk.proto`.
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    vm.suspend_ctl = ctl;
    try testing.expect((try vm.start(chunk.proto)) == .suspended); // (a)
    const out_before = try gpa.dupe(u8, sink.buffered());
    defer gpa.free(out_before);

    // A-iv: seed transient profit state immediately at the suspended cut. It must
    // not gain a wire field, affect schema v5 bytes, or survive restore.
    const live_activation = vm.frames[vm.depth - 1].call_seq;
    try vm.trace.region_profit.put(gpa, .{
        .region_id = @as(trace.RegionId, @enumFromInt(901)),
        .activation = live_activation,
    }, .{
        .outer_traversals = 3,
        .root_frame_depth = vm.depth,
        .root_call_seq = live_activation,
    });
    const mid = try encodeSnapshot(gpa, &vm);
    errdefer gpa.free(mid);

    // (b) F2b property holds mid-execution.
    const vm_r = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    {
        const mid2 = try encodeSnapshot(gpa, vm_r);
        defer gpa.free(mid2);
        try testing.expectEqualSlices(u8, mid, mid2);
    }

    // Resume the restored VM to completion.
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.suspend_ctl = null;
    try testing.expect((try vm_r.exec()) == .finished);

    // (c) output equivalence: out_before ++ out_after == F.
    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.full_out, combined[0 .. out_before.len + sink_r.buffered().len]);

    // (d) state equivalence: the resumed VM's final snapshot matches the
    // uninterrupted run's. Identical because ids are assigned deterministically
    // and these corpus programs leak no pre-suspend garbage (no heap object is
    // created then dropped before the cut), so the restored id counter resumes
    // exactly where the reference run's did.
    const final_snap_r = try encodeSnapshot(gpa, vm_r);
    defer gpa.free(final_snap_r);
    try testing.expectEqualSlices(u8, ref.final_snap, final_snap_r);

    return mid;
}

// Corpus: nested calls + loops + closures/upvalues + tables. Each is replayed at
// two cuts — one anywhere mid-run (depth gate off), one forced *inside a call*.
const f2c_corpus = [_][:0]const u8{
    // Doc 18 §T: a 0-indexed array fill + pairs walk (slot-0 array part). A
    // mid-fill cut captures an array whose key 0 is array-resident (v7
    // positional serialization incl. the identity slot 0); resume must
    // continue the fill and the 0-first pairs order identically.
    \\local function fill(n)
    \\  local t = {}
    \\  for i = 0, n do t[i] = i * 3 end
    \\  return t
    \\end
    \\local t = fill(40)
    \\local s = 0
    \\for k, v in pairs(t) do s = s + k + v end
    \\print(s)
    \\print(#t)
    ,
    // Loop inside a call, two host calls after it returns.
    \\local function sum(n)
    \\  local s = 0
    \\  for i = 1, n do s = s + i end
    \\  return s
    \\end
    \\print(sum(5))
    \\print("done")
    ,
    // A counter closure: an OPEN upvalue is live on the stack at a mid-call cut.
    \\local function counter()
    \\  local n = 0
    \\  return function() n = n + 1; return n end
    \\end
    \\local c = counter()
    \\print(c()); print(c()); print(c())
    ,
    // Three-deep call stack (main → outer → inner) feeding a table.
    \\local function inner(x) return x * 2 end
    \\local function outer(a, b) return inner(a) + inner(b) end
    \\local t = {}
    \\t.r = outer(3, 4)
    \\print(t.r)
    ,
    // Generic-for over `pairs` of a string-keyed hash, inside a call. A mid-call
    // cut lands mid-iteration with a hash-part `ctrl` live on the stack and the
    // `next` global as the loop's iterator register — resume must continue the
    // canonical-order traversal from that exact key (D4: mid-iteration snapshot).
    // Accumulates numerically so no heap string is created-then-dropped before the
    // cut (keeps the id counter resuming exactly, per the (d) state-equivalence
    // invariant above).
    \\local function total(t)
    \\  local s = 0
    \\  for k, v in pairs(t) do s = s + v end
    \\  return s
    \\end
    \\local m = {}
    \\m.a = 10
    \\m.b = 20
    \\m.c = 30
    \\print(total(m))
    ,
    // Generic-for over `ipairs` of an array part, inside a call. The cut lands with
    // an integer `ctrl` and the hidden `@ipairs_iter` native as the iterator —
    // exercises the by-name native restore for the un-spellable iterator.
    \\local function asum(a)
    \\  local s = 0
    \\  for i, v in ipairs(a) do s = s + v end
    \\  return s
    \\end
    \\local arr = {2, 4, 6, 8, 10}
    \\print(asum(arr))
    ,
    // A `repeat/until` post-test loop inside a call — a mid-loop cut lands with the
    // back-edge `jmp_if_false` pending, so resume must re-test and continue the
    // loop from the restored register state.
    \\local function tri(n)
    \\  local i = 0
    \\  local s = 0
    \\  repeat
    \\    i = i + 1
    \\    s = s + i
    \\  until i >= n
    \\  return s
    \\end
    \\print(tri(6))
    ,
    // A homogeneous-numeric matrix that inflates to a **grid** (doc 14) and stays
    // live across both loops, so a mid-run cut almost always lands while `m` is a
    // grid. Capture deflates the grid to logical nested rows with reserved-space
    // ids (Phase 7); this case is the proof that those ids are a pure function of
    // logical state — the resumed run re-inflates and re-captures to a
    // BYTE-IDENTICAL final snapshot (invariant (d)) despite the phantom rows. All
    // arithmetic is numeric, so nothing heap is created-then-dropped before a cut.
    \\local function grid()
    \\  local m = {{1,2,3,4},{5,6,7,8},{9,10,11,12},{13,14,15,16}}
    \\  for i = 1, 4 do
    \\    for j = 1, 4 do
    \\      m[i][j] = m[i][j] + 1
    \\    end
    \\  end
    \\  local s = 0
    \\  for i = 1, 4 do
    \\    for j = 1, 4 do
    \\      s = s + m[i][j]
    \\    end
    \\  end
    \\  return s
    \\end
    \\print(grid())
    ,
};

// A nested numeric-for shape sized so the tracing JIT would form the Phase-3 link
// chain if this harness enabled tracing: inner trip count exceeds `min_trip_entry`,
// outer trip count gives the loop-done exit enough hits to arm the continuation,
// and the post-inner `s = s + i` keeps the nsieve-style "work after inner loop"
// shape. The F2c harness is intentionally tier-0-only today (see the test below),
// so this covers cut/resume on the same bytecode shape rather than asserting a
// literal cut inside tier-1a linked execution.
const f2c_linking_shape_source =
    \\local function linked_shape()
    \\  local s = 0
    \\  for i = 1, 400 do
    \\    for j = 1, 60 do
    \\      s = s + i * 3 + j
    \\    end
    \\    s = s + i
    \\  end
    \\  return s
    \\end
    \\print(linked_shape())
;

test "F2c: resume from a mid-execution keyframe reproduces output and final state" {
    const gpa = testing.allocator;
    for (f2c_corpus) |source| {
        const ref = try referenceRun(gpa, source);
        defer ref.deinit(gpa);
        try testing.expect(ref.total_safepoints > 4);

        // Cut 1: anywhere ~half-way through (depth gate off — often mid-loop / mid-call).
        gpa.free(try expectResume(gpa, source, .{
            .min_depth = 1,
            .after_safepoints = ref.total_safepoints / 2,
        }, ref));

        // Cut 2: the first safepoint *inside* a nested call (depth >= 2).
        gpa.free(try expectResume(gpa, source, .{
            .min_depth = 2,
            .after_safepoints = 1,
        }, ref));
    }
}

test "F2c: linking-shaped nested numeric-for resumes from a tier-0 keyframe" {
    // Feasibility finding for doc 15: `referenceRun` and `expectResume` create a
    // fresh `Vm.init` and never set `vm.trace.config.enabled`, whose default is
    // false. Therefore F2c cuts cannot literally land inside a tier-1a link chain;
    // they snapshot tier-0 heap/stack/frame state at safepoints. The trace-side
    // proof that this source shape links lives in the Phase-3 counter tests in
    // `interp.zig`; this test pins keyframe resume on the same nested-loop shape.
    const gpa = testing.allocator;
    const ref = try referenceRun(gpa, f2c_linking_shape_source);
    defer ref.deinit(gpa);
    try testing.expect(ref.total_safepoints > 1000);

    gpa.free(try expectResume(gpa, f2c_linking_shape_source, .{
        .min_depth = 2,
        .after_safepoints = ref.total_safepoints / 2,
    }, ref));
}

test "§R3: capture→restore→resume with tracing+opt+native — restored narrow array traces, restored matrix re-inflates" {
    // Doc 18 §T (§R3 additions): the F2c corpus is tier-0-only, so this is THE
    // test where a restored VM resumes with the full JIT enabled. It pins:
    //   (a) resumed output == uninterrupted output;
    //   (b) final logical snapshots agree (trace consts are excluded from the
    //       snapshot walk — the H-2/G-2 property — so bytes still compare);
    //   (c) the restored narrow array records and DISPATCHES traces post-restore
    //       (cache non-empty + trace entries > 0, native entries on x86-64);
    //   (d) the restored matrix re-inflates to a grid on the fused store path;
    //   (e) the restored dense array is narrow-lane resident at the end.
    const gpa = testing.allocator;
    const source =
        \\a = {}
        \\for i = 1, 64 do a[i] = i end
        \\m = {{1,2,3},{4,5,6},{7,8,9}}
        \\local s = 0
        \\for r = 1, 400 do
        \\  for i = 1, 64 do s = s + a[i] end
        \\end
        \\for r = 1, 200 do
        \\  for i = 1, 3 do
        \\    for j = 1, 3 do m[i][j] = m[i][j] + 1 end
        \\  end
        \\end
        \\local g = 0
        \\for i = 1, 3 do
        \\  for j = 1, 3 do g = g + m[i][j] end
        \\end
        \\print(s)
        \\print(g)
    ;
    const ref = try referenceRun(gpa, source);
    defer ref.deinit(gpa);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Cut mid-way through the hot array loop: well after `a` and `m` exist,
    // well before the grid store loop (builds are ~75 of ~27k safepoints).
    vm.suspend_ctl = .{ .min_depth = 1, .after_safepoints = ref.total_safepoints / 4 };
    try testing.expect((try vm.start(chunk.proto)) == .suspended);
    const out_before = try gpa.dupe(u8, sink.buffered());
    defer gpa.free(out_before);
    const mid = try encodeSnapshot(gpa, &vm);
    defer gpa.free(mid);

    const vm_r = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }

    // THE §R3 requirement: resume with tracing + optimization + native codegen.
    const native = @import("nativegen.zig").is_x64_linux;
    vm_r.trace.config.enabled = true;
    vm_r.trace.config.execute = true;
    vm_r.trace.config.optimize = true;
    vm_r.trace.config.native_codegen = native;
    vm_r.trace.config.hotloop = 4; // trace the short test loops

    var buf_r: [64]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.suspend_ctl = null;
    try testing.expect((try vm_r.exec()) == .finished);

    // (a) output equivalence vs the uninterrupted tier-0 reference.
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.full_out, combined[0 .. out_before.len + sink_r.buffered().len]);

    // (c) traces recorded AND dispatched after restore.
    try testing.expect(vm_r.trace.cache.items.len > 0);
    try testing.expect(vm_r.trace.entries > 0);
    if (native) try testing.expect(vm_r.trace.native_entries > 0);

    // (d) the restored matrix re-inflated to a grid on the fused store path.
    const mt = table.Table.fromHeader(vm_r.globals.get(try vm_r.heap.internValue("m")).asHeap());
    try testing.expect(mt.array.isGrid());
    // (e) the restored dense array is narrow-lane resident.
    const at = table.Table.fromHeader(vm_r.globals.get(try vm_r.heap.internValue("a")).asHeap());
    try testing.expect(at.array.lane.isNarrow());

    // (b) final logical snapshots agree (trace-cache identity exempt; trace
    // consts are excluded from the snapshot walk, so bytes compare directly).
    const final_snap_r = try encodeSnapshot(gpa, vm_r);
    defer gpa.free(final_snap_r);
    try testing.expectEqualSlices(u8, ref.final_snap, final_snap_r);
}

test "§R3: failing-allocator restore during the bulk lane repack leaks nothing" {
    // Doc 18 §T (§R3 additions): a mid-repack OOM must leak neither the original
    // `.value` buffer nor the partial narrow buffers (the `errdefer` chain in
    // the restore path). `checkAllAllocationFailures` fails every allocation in
    // turn; `std.testing.allocator` then asserts no leak and no invalid free.
    const gpa = testing.allocator;
    const source =
        \\t = {}
        \\for i = 1, 64 do t[i] = i end
        \\print(#t)
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // The snapshot's `t` restores via the bulk narrow-lane rebuild (append as
    // `.value`, then `optimalLane` → `repack` → frozen).
    const snap = try encodeSnapshot(gpa, &vm);
    defer gpa.free(snap);

    const Inner = struct {
        fn run(fgpa: std.mem.Allocator, snap_: []const u8, proto: *const Proto) !void {
            const vm_r = try restore(fgpa, snap_, proto, NativeRegistry.base());
            vm_r.deinit();
            fgpa.destroy(vm_r);
        }
    };
    try testing.checkAllAllocationFailures(gpa, Inner.run, .{ snap, chunk.proto });
}

test "F2c: independent VMs suspended at the same cut produce byte-identical keyframes" {
    const gpa = testing.allocator;
    for (f2c_corpus) |source| {
        const ref = try referenceRun(gpa, source);
        defer ref.deinit(gpa);
        const ctl: SuspendCtl = .{ .min_depth = 2, .after_safepoints = 1 };
        const mid_a = try expectResume(gpa, source, ctl, ref);
        defer gpa.free(mid_a);
        const mid_b = try expectResume(gpa, source, ctl, ref);
        defer gpa.free(mid_b);
        // Two independent runs cut at the same safepoint snapshot identically —
        // the mid-execution extension of the run-twice determinism property.
        try testing.expectEqualSlices(u8, mid_a, mid_b);
    }
}

test "F2c: live vararg frame cursor round-trips through a keyframe" {
    const gpa = testing.allocator;
    const source =
        \\local function consume(head, ...)
        \\  local n = 0
        \\  while n < 20 do n = n + 1 end
        \\  return head + ... + select(2, ...)
        \\end
        \\print(consume(10, 20, 30, 40))
    ;
    const ref = try referenceRun(gpa, source);
    defer ref.deinit(gpa);

    const mid = try expectResume(gpa, source, .{
        .min_depth = 2,
        .after_safepoints = 1,
    }, ref);
    defer gpa.free(mid);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try schema.SnapshotFile.decode(arena.allocator(), mid);
    try testing.expect(decoded.keyframe.frames.len >= 2);
    const live = decoded.keyframe.frames[decoded.keyframe.frames.len - 1];
    try testing.expectEqual(@as(u32, 3), live.varargs_count);
    try testing.expect(live.varargs_base > 0);
    try testing.expect(live.varargs_base + live.varargs_count <= live.base);
}

test "A-iii: recursive live frames re-key deterministically across keyframe restore and re-record" {
    const gpa = testing.allocator;
    const source =
        \\local function descend(n)
        \\  if n == 0 then
        \\    local x = 0
        \\    while x < 4 do x = x + 1 end
        \\    return x
        \\  end
        \\  return descend(n - 1)
        \\end
        \\print(descend(5))
    ;

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Consume an earlier epoch first, so the suspended stack's live keys do not
    // happen to equal their indices. This makes restore-time re-keying observable
    // and proves capture did not smuggle the old values through a wire field.
    _ = try vm.run(chunk.proto);
    const prior_next = vm.next_call_seq;
    try testing.expect(prior_next > 0);

    vm.suspend_ctl = .{ .min_depth = 5, .after_safepoints = 0 };
    try testing.expect((try vm.start(chunk.proto)) == .suspended);
    try testing.expect(vm.depth >= 5);
    try testing.expectEqual(prior_next + vm.depth, vm.next_call_seq);
    for (vm.frames[0..vm.depth], 0..) |frame, i| {
        try testing.expectEqual(prior_next + i, frame.call_seq);
    }
    // Main is frame 0; the remaining live frames are several activations of the
    // same recursive proto, and must still have distinct activation identities.
    const recursive_proto = vm.frames[1].closure.proto;
    for (vm.frames[1..vm.depth]) |frame| {
        try testing.expectEqual(recursive_proto, frame.closure.proto);
    }

    const mid = try encodeSnapshot(gpa, &vm);
    defer gpa.free(mid);
    const restored = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        restored.deinit();
        gpa.destroy(restored);
    }
    try testing.expectEqual(vm.depth, restored.depth);
    try testing.expectEqual(@as(usize, 0), restored.trace.regionProfitCount());
    for (restored.frames[0..restored.depth], 0..) |frame, i| {
        try testing.expectEqual(@as(u64, @intCast(i)), frame.call_seq);
    }
    try testing.expectEqual(@as(u64, @intCast(restored.depth)), restored.next_call_seq);

    // Re-recording and restoring the same live keyframe produces the same
    // index-ordered transient keys. The bytes remain identical because call_seq
    // is intentionally absent from FrameRef.
    const rerecorded = try encodeSnapshot(gpa, restored);
    defer gpa.free(rerecorded);
    try testing.expectEqualSlices(u8, mid, rerecorded);
    const restored_again = try restore(gpa, rerecorded, chunk.proto, NativeRegistry.base());
    defer {
        restored_again.deinit();
        gpa.destroy(restored_again);
    }
    for (restored_again.frames[0..restored_again.depth], 0..) |frame, i| {
        try testing.expectEqual(@as(u64, @intCast(i)), frame.call_seq);
    }

    // A subsequent physical push takes the first key above the restored range.
    const old_depth = restored.depth;
    const top_closure = restored.frames[old_depth - 1].closure;
    try restored.pushFrame(top_closure, restored.stack_top, 0, 0);
    try testing.expectEqual(@as(u64, @intCast(old_depth)), restored.frames[old_depth].call_seq);
    try testing.expectEqual(@as(u64, @intCast(old_depth + 1)), restored.next_call_seq);
}

test "F2c: a frame window that doesn't tile from 0 is rejected (FrameWindowMismatch)" {
    // Two single-register closures sharing a proto. A faithful capture tiles the
    // windows 0,1; a base of 2 for the second frame leaves a one-slot gap → the
    // restore contiguity guard must reject it rather than read the wrong registers.
    const code = [_]bytecode.Instr{bytecode.Instr.opAB(.halt, 0, 0)};
    const consts = [_]value.Value{};
    const rootp = Proto{
        .code = &code,
        .constants = &consts,
        .num_registers = 1,
        .name = "f",
    };
    const bad: schema.SnapshotFile = .{
        .version = snapshot_format_version,
        .keyframe = .{
            .globals_id = 9,
            .string_metatable_id = 0,
            .next_obj_id = 10,
            .objects = &.{
                .{ .id = 9, .obj_type = 1, .body = .{ .HeapTable = .{ .array = &.{}, .entries = &.{}, .metatable_id = 0 } } },
                .{ .id = 0, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = rootp.id, .upvalue_ids = &.{} } } },
                .{ .id = 1, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = rootp.id, .upvalue_ids = &.{} } } },
            },
            .stack = &.{ sNil(), sNil(), sNil() },
            .frames = &.{
                .{ .closure_id = 0, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0, .varargs_base = 0, .varargs_count = 0 },
                .{ .closure_id = 1, .pc = 0, .base = 2, .ret_dest = 0, .ret_count = 0, .varargs_base = 0, .varargs_count = 0 }, // gap: expected base 1
            },
            .open_upvalues = &.{},
            .loaded_chunks = &.{},
        },
    };
    try expectRestoreError(bad, &rootp, error.FrameWindowMismatch);
}

// ---------------------------------------------------------------------------
// Doc 21 §T-A — canonical final-state capture (the H-5(i) fix)
// ---------------------------------------------------------------------------

/// Compile + run `source` on a fresh VM with the full JIT enabled (tracing +
/// opt + native where available), assert its output matches `ref`, and return
/// its final snapshot (caller frees).
fn jitFinalSnapshot(gpa: std.mem.Allocator, source: [:0]const u8, ref: RefRun) ![]u8 {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(ref.full_out, sink.buffered());
    return try encodeSnapshot(gpa, &vm);
}

test "doc 21 §T-A.2: cross-tier final snapshots byte-identical (the minimized H-5(i) g-loop shape)" {
    // The exact divergence channel from the §R3 bisect, minimized: tier-0
    // leaves the g-loop's final-iteration temps in dead slots; the native exit
    // flush freezes pre-burst values there (the recorder's locals_watermark φ
    // filter prunes never-read temps). The doc-21 final-cut mask must
    // canonicalize both to nil, making the snapshots byte-compare.
    const gpa = testing.allocator;
    const source =
        \\m = {{1,2,3},{4,5,6},{7,8,9}}
        \\local g = 0
        \\for r = 1, 200 do
        \\  for i = 1, 3 do
        \\    for j = 1, 3 do g = g + m[i][j] end
        \\  end
        \\end
        \\print(g)
    ;
    const ref = try referenceRun(gpa, source);
    defer ref.deinit(gpa);
    const snap = try jitFinalSnapshot(gpa, source, ref);
    defer gpa.free(snap);
    try testing.expectEqualSlices(u8, ref.final_snap, snap);
}

test "doc 24 c4 (arc-B acceptance): allocating snew/tostr loop — cross-tier final snapshots byte-identical, next_obj_id explicit, pairs order pinned" {
    // THE arc-B acceptance gate (doc 24 D9.3): a hot loop that allocates
    // on-trace every iteration (tostr_int + srev + ssub, incl. a WRITTEN-BUT-
    // DEAD heap temp per iteration — the codex #6 stale-slot channel), run
    // tier-0 vs full-JIT, and the FINAL SNAPSHOTS must byte-compare. The
    // snapshot walk covers the live object graph, ids, and `next_obj_id` —
    // the total-allocation count is observable state (D2), so one extra or
    // one missing on-trace intern anywhere diverges the bytes. A pairs()
    // fold over string keys interned AFTER the hot loop makes id-order
    // divergence show in stdout too (hash iteration order is keyed on ids).
    // The hot loop is MOD-FREE. That was load-bearing when authored (pre-
    // doc-25, `%` had no native lowering and the safety net would have
    // declined entry entirely, quietly reducing this to tier-0-vs-tier-0);
    // mod now lowers, but the shape stays so the pinned byte-stream and its
    // production-verified native-entry profile don't churn.
    const gpa = testing.allocator;
    const source =
        \\local sub = string.sub
        \\local rev = string.reverse
        \\local base = "The quick brown Fox jumps over the lazy Dog"
        \\local u = 0
        \\local w = 1
        \\for i = 1, 500 do
        \\  local s = tostring(i)
        \\  local dead = rev(s)
        \\  local t = sub(base, w, w + 5)
        \\  u = u + #dead + #t
        \\  w = w + 1
        \\  if w > 30 then w = 1 end
        \\end
        \\local tbl = {}
        \\for i = 1, 26 do tbl[string.char(64 + i)] = i end
        \\local ks = 0
        \\for k, v in pairs(tbl) do ks = (ks * 31 + v + #k) % 1000003 end
        \\print(u, ks)
    ;
    const ref = try referenceRun(gpa, source);
    defer ref.deinit(gpa);
    const snap = try jitFinalSnapshot(gpa, source, ref);
    defer gpa.free(snap);
    try testing.expectEqualSlices(u8, ref.final_snap, snap);

    // `next_obj_id` equality asserted EXPLICITLY (D9.3), not only via the
    // byte-compare above: decode both keyframes and compare the field.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ref_file = try schema.SnapshotFile.decode(arena.allocator(), ref.final_snap);
    const jit_file = try schema.SnapshotFile.decode(arena.allocator(), snap);
    try testing.expectEqual(ref_file.keyframe.next_obj_id, jit_file.keyframe.next_obj_id);
    // Sanity: the run really allocated thousands of ids (500 fresh tostrings
    // + reversals + windows) — a near-zero id count would mean the loop
    // didn't do what this gate thinks it does.
    try testing.expect(ref_file.keyframe.next_obj_id > 1000);
}

test "doc 21 §T-A.3: result span preserved; dead-slot-only garbage excluded from the snapshot walk" {
    const gpa = testing.allocator;
    // `hidden`'s only reference is a dead local at the final state — semantic
    // garbage; the returned table rides the result span and must survive.
    const source =
        \\local hidden = {11, 22}
        \\return {1, 2}
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const fc = vm.final_cut orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), fc.result_count);

    const snap = try encodeSnapshot(gpa, &vm);
    defer gpa.free(snap);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const file = try schema.SnapshotFile.decode(arena.allocator(), snap);
    const kf = file.keyframe;

    // The span slot is a heap ref; every other stack slot is canonical nil.
    for (kf.stack, 0..) |sv, idx| {
        if (idx == fc.result_base) {
            try testing.expect(sv.body == .HeapRef);
        } else {
            try testing.expectEqual(@as(u8, 0), sv.tag); // nil
        }
    }
    // The returned {1,2} is in the walk; hidden {11,22} is not.
    var saw_returned = false;
    for (kf.objects) |obj| {
        if (obj.body != .HeapTable) continue;
        const t = obj.body.HeapTable;
        for (t.array) |av| {
            if (av.body != .ConstInt) continue;
            if (av.body.ConstInt.v == 1) saw_returned = true;
            try testing.expect(av.body.ConstInt.v != 11); // hidden excluded
        }
    }
    try testing.expect(saw_returned);
}

test "doc 21 §T-A.4: all_results finish — dynamic span past the static window is raised, rooted, captured (B-6)" {
    const gpa = testing.allocator;
    const source =
        \\local function f() return 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 end
        \\return f()
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const fc = vm.final_cut orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 10), fc.result_count);
    try testing.expectEqual(@as(u32, @intCast(vm.stack_top)), fc.stack_top);
    // B-6: the dynamic span end is covered by the (possibly raised) stack_top.
    try testing.expect(@as(usize, fc.result_base) + fc.result_count <= vm.stack_top);

    const snap = try encodeSnapshot(gpa, &vm);
    defer gpa.free(snap);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const file = try schema.SnapshotFile.decode(arena.allocator(), snap);
    const kf = file.keyframe;
    try testing.expectEqual(@as(usize, vm.stack_top), kf.stack.len);
    var k: u32 = 0;
    while (k < fc.result_count) : (k += 1) {
        const sv = kf.stack[fc.result_base + k];
        try testing.expect(sv.body == .ConstInt);
        try testing.expectEqual(@as(i64, k + 1), sv.body.ConstInt.v);
    }
    for (kf.stack, 0..) |sv, idx| {
        if (idx >= fc.result_base and idx < fc.result_base + fc.result_count) continue;
        try testing.expectEqual(@as(u8, 0), sv.tag); // nil outside the span
    }
}

test "doc 21 §T-A.5: a depth-0 callValue invalidates the final cut (B-1 shape)" {
    const gpa = testing.allocator;
    const source =
        \\function g() return 7 end
        \\return 1
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expect(vm.final_cut != null);

    // Host reentry at depth 0: the cut must not survive into a capture that
    // would describe the callee's (re-used) stack as the old result span.
    const gfn = vm.globals.get(try vm.heap.internValue("g"));
    var out: [1]Value = undefined;
    _ = try vm.callValue(gfn, &.{}, &out);
    try testing.expectEqual(@as(i64, 7), out[0].asInt());
    try testing.expect(vm.final_cut == null);
    // Capture still succeeds — it just masks nothing (fail-safe path).
    const snap = try encodeSnapshot(gpa, &vm);
    gpa.free(snap);
}

test "doc 21 §T-A.6: pcall/xpcall unwind then finish — the cut reflects the finish" {
    const gpa = testing.allocator;
    const source =
        \\local ok, err = pcall(function() error("boom") end)
        \\local ok2 = xpcall(function() error("bam") end, function(e) return e end)
        \\return ok, ok2
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const fc = vm.final_cut orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), fc.result_count);
    try testing.expectEqual(@as(u32, @intCast(vm.stack_top)), fc.stack_top);
    const snap = try encodeSnapshot(gpa, &vm);
    gpa.free(snap);
}
