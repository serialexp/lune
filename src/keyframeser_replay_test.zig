//! Tests for `keyframeser.zig` — replay.
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
const lune_parser = @import("parser.zig");
const lune_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

const NativeRegistry = keyframeser.NativeRegistry;
const encodeSnapshot = keyframeser.encodeSnapshot;
const restore = keyframeser.restore;

// ---------------------------------------------------------------------------
// F2d — combined keyframe + effect replay (the real demo)
//
// F2c proved a mid-execution keyframe re-executes forward to the same result —
// but only for a *deterministic* program. The moment a run reads a
// nondeterministic input (`clock()`), re-execution diverges unless the recorded
// inputs are fed back. This test ties the two halves of the substrate together:
// restore a mid-run keyframe AND replay its effect log from the cut, and the
// forward output matches the uninterrupted run byte-for-byte.
//
// The seam the keyframe does NOT carry is the effect cursor: the keyframe is the
// heap/stack/frames, the effect log + cursor are replay-driver state supplied
// alongside it. So restore() rebuilds the VM, then the driver sets
// effect_mode/effect_log/effect_cursor before resuming — exactly what a real
// replay harness would marshal next to the snapshot.
// ---------------------------------------------------------------------------

// A deterministic test clock injected as a `ClockSource` (the interpreter holds
// no platform clock of its own). Returns next, next+1, next+2, … so the recorded
// effect log is reproducible.
const TestClock = struct {
    next: i64,
    fn nowNs(ctx: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        const v = self.next;
        self.next += 1;
        return v;
    }
    fn source(self: *TestClock) interp.ClockSource {
        return .{ .ctx = self, .nowNs = &TestClock.nowNs };
    }
};

// A clock()-using program with a loop inside a nested call: each cut lands with
// live frames AND a partially-consumed effect log, so both halves are exercised.
const f2d_combined_source =
    \\local function ticks(n)
    \\  local s = 0
    \\  for i = 1, n do s = s + os.nsclock() end
    \\  return s
    \\end
    \\print(ticks(3))
    \\print(ticks(3))
;

test "F2d: restore a mid-run keyframe + replay its effect log → identical forward output" {
    const gpa = testing.allocator;
    const source = f2d_combined_source;

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // --- Run 1 (record): full uninterrupted run → reference output F + effect log L.
    const ref = blk: {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try lune_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());

        // Inject a deterministic clock so the recorded log is reproducible (the
        // record VM is the only one that calls clock(); the replay VMs feed L back).
        var clk = TestClock{ .next = 1000 };
        vm.clock_source = clk.source();
        vm.effect_mode = .record;
        _ = try vm.run(chunk.proto);

        break :blk .{
            .out = try gpa.dupe(u8, sink.buffered()),
            .log = try gpa.dupe(interp.Effect, vm.effect_log.items),
            .safepoints = vm.safepoint_seq,
        };
    };
    defer gpa.free(ref.out);
    defer gpa.free(ref.log);
    try testing.expectEqual(@as(usize, 6), ref.log.len); // 3 + 3 clock() calls
    try testing.expect(ref.safepoints > 4);

    // --- Run 2 (replay + suspend): re-run feeding L back, cut mid-execution. Replay
    // (not a fresh record) so the clock values match L exactly — the pre-cut output
    // is then a true prefix of F, and the cursor names how much of L was consumed.
    // The suspend VM owns the heap the program image interns into; it must outlive
    // the restored VM that borrows `chunk.proto`.
    var vm2 = try Vm.init(gpa);
    defer vm2.deinit();
    var buf2: [512]u8 = undefined;
    var sink2 = io.Writer.fixed(&buf2);
    vm2.out = &sink2;
    var chunk2 = try lune_compiler.compile(gpa, vm2.heap, source, tree.root, &diags);
    defer chunk2.deinit();
    try testing.expect(!diags.hasErrors());

    vm2.effect_mode = .replay;
    try vm2.effect_log.appendSlice(gpa, ref.log);
    vm2.suspend_ctl = .{ .min_depth = 2, .after_safepoints = ref.safepoints / 2 };
    try testing.expect((try vm2.start(chunk2.proto)) == .suspended);

    const out_before = try gpa.dupe(u8, sink2.buffered());
    defer gpa.free(out_before);
    const cursor_at_cut = vm2.effect_cursor; // replay-driver state the keyframe omits
    try testing.expect(cursor_at_cut > 0 and cursor_at_cut < ref.log.len); // genuinely mid-log

    const mid = try encodeSnapshot(gpa, &vm2);
    defer gpa.free(mid);

    // --- Restore + replay-from-cursor: rebuild the VM from the keyframe, then the
    // driver re-attaches the effect log and cursor (the seam the keyframe omits).
    const vm_r = try restore(gpa, mid, chunk2.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.effect_mode = .replay;
    try vm_r.effect_log.appendSlice(gpa, ref.log);
    vm_r.effect_cursor = cursor_at_cut;
    vm_r.suspend_ctl = null;
    try testing.expect((try vm_r.exec()) == .finished);

    // out_before ++ out_after == F: the restored run consumed the tail of L from the
    // cursor and reproduced the rest of the output exactly.
    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.out, combined[0 .. out_before.len + sink_r.buffered().len]);
    // The whole log was consumed exactly once across the cut (no effect lost or replayed twice).
    try testing.expectEqual(ref.log.len, vm_r.effect_cursor);
}

const NativeF2cCut = struct {
    keyframe: []u8,
    effects: []u8,
    output_prefix: []u8,
    rng_state: [4]u64,
    effect_cursor: usize,
    committed_effect_seq: u64,
    traced_iters: u64,
    compiled_native_traces: usize,

    fn deinit(self: NativeF2cCut, gpa: std.mem.Allocator) void {
        gpa.free(self.keyframe);
        gpa.free(self.effects);
        gpa.free(self.output_prefix);
    }
};

/// Capture the first snapshot-eligible tier-0 boundary at/after the first
/// committed effect. With `native=true`, the numeric-for immediately before the
/// effect must have executed as native code; the effect is a host barrier, so the
/// cut itself remains a coherent tier-0 boundary.
fn captureNativeF2cCut(gpa: std.mem.Allocator, source: [:0]const u8, native: bool) !NativeF2cCut {
    const effectser = @import("effectser.zig");
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var out_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&out_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    var clock = TestClock{ .next = 1000 };
    vm.clock_source = clock.source();
    vm.trace.config.enabled = native;
    vm.trace.config.execute = native;
    vm.trace.config.optimize = native;
    vm.trace.config.native_codegen = native;
    vm.trace.config.coverage = native;
    vm.trace.config.hotloop = 4;
    vm.suspend_ctl = .{
        .min_depth = 2,
        .after_safepoints = 0,
        .after_committed_effects = 1,
    };

    var chunk = try lune_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    try testing.expect((try vm.start(chunk.proto)) == .suspended);
    try testing.expectEqual(@as(u64, 1), vm.committed_effect_seq);
    try testing.expect(vm.rng != null);

    var compiled_native_traces: usize = 0;
    for (vm.trace.cache.items) |tr| if (tr.native == .compiled) {
        compiled_native_traces += 1;
    };
    return .{
        .keyframe = try encodeSnapshot(gpa, &vm),
        .effects = try effectser.encodeFile(gpa, vm.effect_log.items),
        .output_prefix = try gpa.dupe(u8, sink.buffered()),
        .rng_state = vm.rng.?.s,
        .effect_cursor = vm.effect_cursor,
        .committed_effect_seq = vm.committed_effect_seq,
        .traced_iters = vm.trace.iters_traced,
        .compiled_native_traces = compiled_native_traces,
    };
}

test "A-vi F-5: native post-burst effect cut has full-state identity and resumes from an empty trace cache" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    // The expression creates numeric-for temporaries above the locals watermark.
    // They used to be omitted from the exit snapshot, leaving stale physical
    // registers after native execution; byte-identical keyframes make that bug
    // observable at the post-native-burst effect cut.
    const source: [:0]const u8 =
        \\local function work()
        \\  math.randomseed(123456)
        \\  local before = math.random()
        \\  local acc = 0
        \\  for i = 1, 400 do
        \\    acc = acc + ((i + 1) * (i + 2) + (i + 3) * (i + 4))
        \\      * ((i + 5) * (i + 6) + (i + 7) * (i + 8))
        \\  end
        \\  local t = os.clock()
        \\  local after = math.random()
        \\  print(acc, before, after, t)
        \\end
        \\work()
    ;

    const tier0 = try captureNativeF2cCut(gpa, source, false);
    defer tier0.deinit(gpa);
    const native = try captureNativeF2cCut(gpa, source, true);
    defer native.deinit(gpa);
    try testing.expect(native.traced_iters > 0); // genuine native burst before cut
    try testing.expect(native.compiled_native_traces > 0);

    // F-5 full-state oracle: semantic keyframe plus every replay-driver facet the
    // keyframe deliberately omits. No coarse counter-only shortcut is accepted.
    try testing.expectEqualSlices(u8, tier0.keyframe, native.keyframe);
    try testing.expectEqualSlices(u8, tier0.effects, native.effects);
    try testing.expectEqualStrings(tier0.output_prefix, native.output_prefix);
    try testing.expectEqualSlices(u64, &tier0.rng_state, &native.rng_state);
    try testing.expectEqual(tier0.effect_cursor, native.effect_cursor);
    try testing.expectEqual(tier0.committed_effect_seq, native.committed_effect_seq);

    // Recreate the native cut with its program image kept alive, then restore into
    // a fresh VM. The restored trace cache is empty; replay-driver state is
    // reattached explicitly before execution continues.
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var cut_vm = try Vm.init(gpa);
    defer cut_vm.deinit();
    var cut_out_buf: [512]u8 = undefined;
    var cut_sink = io.Writer.fixed(&cut_out_buf);
    cut_vm.out = &cut_sink;
    cut_vm.effect_mode = .record;
    var cut_clock = TestClock{ .next = 1000 };
    cut_vm.clock_source = cut_clock.source();
    cut_vm.trace.config.enabled = true;
    cut_vm.trace.config.execute = true;
    cut_vm.trace.config.optimize = true;
    cut_vm.trace.config.native_codegen = true;
    cut_vm.trace.config.coverage = true;
    cut_vm.trace.config.hotloop = 4;
    cut_vm.suspend_ctl = .{ .min_depth = 2, .after_committed_effects = 1 };
    var chunk = try lune_compiler.compile(gpa, cut_vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    try testing.expect((try cut_vm.start(chunk.proto)) == .suspended);
    const mid = try encodeSnapshot(gpa, &cut_vm);
    defer gpa.free(mid);
    try testing.expectEqualSlices(u8, native.keyframe, mid);
    const cut_effects = try effectser.encodeFile(gpa, cut_vm.effect_log.items);
    defer gpa.free(cut_effects);

    const resumed = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        resumed.deinit();
        gpa.destroy(resumed);
    }
    try testing.expectEqual(@as(usize, 0), resumed.trace.cache.items.len);
    const replay_log = try effectser.decodeFile(gpa, resumed.heap, cut_effects);
    defer gpa.free(replay_log);
    try resumed.effect_log.appendSlice(gpa, replay_log);
    resumed.effect_mode = .record;
    resumed.effect_cursor = cut_vm.effect_cursor;
    resumed.committed_effect_seq = cut_vm.committed_effect_seq;
    resumed.rng = cut_vm.rng;
    resumed.trace.config.enabled = true;
    resumed.trace.config.execute = true;
    resumed.trace.config.optimize = true;
    resumed.trace.config.native_codegen = true;
    resumed.trace.config.hotloop = 4;
    var resumed_out_buf: [512]u8 = undefined;
    var resumed_sink = io.Writer.fixed(&resumed_out_buf);
    resumed.out = &resumed_sink;
    resumed.suspend_ctl = null;
    try testing.expect((try resumed.exec()) == .finished);

    // Uninterrupted tier-0 reference with the same deterministic clock.
    var ref_vm = try Vm.init(gpa);
    defer ref_vm.deinit();
    var ref_out_buf: [512]u8 = undefined;
    var ref_sink = io.Writer.fixed(&ref_out_buf);
    ref_vm.out = &ref_sink;
    ref_vm.effect_mode = .record;
    var ref_clock = TestClock{ .next = 1000 };
    ref_vm.clock_source = ref_clock.source();
    var ref_chunk = try lune_compiler.compile(gpa, ref_vm.heap, source, tree.root, &diags);
    defer ref_chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try ref_vm.run(ref_chunk.proto);

    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..cut_sink.buffered().len], cut_sink.buffered());
    @memcpy(combined[cut_sink.buffered().len..][0..resumed_sink.buffered().len], resumed_sink.buffered());
    try testing.expectEqualStrings(
        ref_sink.buffered(),
        combined[0 .. cut_sink.buffered().len + resumed_sink.buffered().len],
    );
    const resumed_final = try encodeSnapshot(gpa, resumed);
    defer gpa.free(resumed_final);
    const ref_final = try encodeSnapshot(gpa, &ref_vm);
    defer gpa.free(ref_final);
    try testing.expectEqualSlices(u8, ref_final, resumed_final);
    try testing.expectEqual(ref_vm.committed_effect_seq, resumed.committed_effect_seq);
    try testing.expectEqualSlices(u64, &ref_vm.rng.?.s, &resumed.rng.?.s);
}
