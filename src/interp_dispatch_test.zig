//! Doc 42 prep (§7): focused behavior pins for the tail-call dispatch
//! conversion, written BEFORE the conversion against the labeled-switch loop.
//!
//! Hashgate pins whole-program output; these pin the *seams* the conversion
//! rewires — the per-instruction prologue at call/return boundaries, the
//! error path's recording cleanup, fast↔full mode handoff, and reentrant
//! `callValue` — at safepoint granularity, where a skipped or doubled
//! prologue shifts every subsequent index. If any of these breaks during the
//! doc-42 flip, the conversion changed observable interpreter timing, even
//! if final outputs still match. T-6 (real-handler O(1)-stack chain) and T-7
//! (wasm smoke) land WITH the conversion; T-1..T-5 live here.

const std = @import("std");
const testing = std.testing;
const interp = @import("interp.zig");
const io = @import("io.zig");
const compiler = @import("compiler.zig");
const parser = @import("parser.zig");
const diag = @import("diag.zig");
const testutil = @import("interp_testutil.zig");

const Vm = interp.Vm;

/// One suspend probe: run `source` in a fresh VM to safepoint `stop_after`.
const Probe = struct {
    depth: u32,
    pc: usize,
    safepoint_seq: u64,
    stdout: []u8,
    finished: bool,
    fn deinit(self: *const Probe, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

fn probeAt(gpa: std.mem.Allocator, source: [:0]const u8, stop_after: u64) !Probe {
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [4096]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.suspend_ctl = .{ .after_safepoints = stop_after };

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    const outcome = try vm.start(chunk.proto);
    const suspended = outcome == .suspended;
    return .{
        .depth = vm.depth,
        .pc = if (suspended) vm.frames[vm.depth - 1].pc else 0,
        .safepoint_seq = vm.safepoint_seq,
        .stdout = try gpa.dupe(u8, sink.buffered()),
        .finished = !suspended,
    };
}

/// Total safepoints for an uninterrupted run of `source`.
fn totalSafepoints(gpa: std.mem.Allocator, source: [:0]const u8) !u64 {
    var p = try probeAt(gpa, source, std.math.maxInt(u64));
    defer p.deinit(gpa);
    try testing.expect(p.finished);
    return p.safepoint_seq;
}

const callret_src: [:0]const u8 =
    \\local function f()
    \\  print("in")
    \\end
    \\print("before")
    \\f()
    \\print("after")
    \\
;

// T-2: the suspend cut lands on the boundary immediately before the FIRST
// callee instruction: depth is already 2 (frame pushed), callee pc is 0, and
// nothing of the callee has executed (stdout is still the caller's). Exactly
// one such boundary exists for one call. A conversion that runs the
// per-instruction prologue zero or two times around the call push shifts or
// duplicates this probe.
test "T-2: suspend boundary at callee entry (prologue neither skipped nor doubled on call)" {
    const gpa = testing.allocator;
    const total = try totalSafepoints(gpa, callret_src);
    var hits: usize = 0;
    var k: u64 = 0;
    while (k < total) : (k += 1) {
        var p = try probeAt(gpa, callret_src, k);
        defer p.deinit(gpa);
        if (p.finished) continue;
        if (p.depth == 2 and p.pc == 0) {
            hits += 1;
            try testing.expectEqualStrings("before\n", p.stdout);
            // The cut is an instruction boundary: exactly k safepoints ran.
            try testing.expectEqual(k, p.safepoint_seq);
        }
    }
    try testing.expectEqual(@as(usize, 1), hits);
}

// T-3: the parent-resumption boundary after `.ret`: there is at least one
// suspend point back at depth 1 where the callee's output is complete but the
// caller's next effect has not happened. A doubled/skipped prologue on the
// pop side breaks the existence or duplicates boundaries (total drifts).
test "T-3: suspend boundary at parent resumption after ret" {
    const gpa = testing.allocator;
    const total = try totalSafepoints(gpa, callret_src);
    var seen_resumed = false;
    var k: u64 = 0;
    while (k < total) : (k += 1) {
        var p = try probeAt(gpa, callret_src, k);
        defer p.deinit(gpa);
        if (p.finished) continue;
        if (p.depth == 1 and std.mem.eql(u8, p.stdout, "before\nin\n")) {
            seen_resumed = true;
            break;
        }
    }
    try testing.expect(seen_resumed);
}

// The safepoint total itself is a determinism pin: every suspend cut above is
// keyed by it, and replay cuts land on it. Two independent runs must agree.
test "safepoint totals are deterministic across runs" {
    const gpa = testing.allocator;
    const a = try totalSafepoints(gpa, callret_src);
    const b = try totalSafepoints(gpa, callret_src);
    try testing.expectEqual(a, b);
}

// T-4: fast↔full handoff must be invisible to safepoint accounting. The
// `.fast` instantiation compiles the full-only hooks out but the prologue
// runs between every instruction pair in BOTH modes, so a run that flips
// modes (recording arms `.full` at a back-edge, closes back to `.fast`)
// counts exactly the same safepoints as a trace-off run. This is the
// direct pin on "prologue runs once per instruction in both modes".
test "T-4: fast/full mode handoff preserves the safepoint count" {
    const gpa = testing.allocator;
    const src: [:0]const u8 =
        \\local acc = 0
        \\for i = 1, 40 do
        \\  acc = acc + i
        \\end
        \\print(acc)
        \\
    ;
    const Hook = struct {
        var seq_off: u64 = 0;
        var seq_rec: u64 = 0;
        fn off(vm: *Vm, mode: testutil.TraceMode) anyerror!void {
            _ = mode;
            seq_off = vm.safepoint_seq;
        }
        fn rec(vm: *Vm, mode: testutil.TraceMode) anyerror!void {
            _ = mode;
            seq_rec = vm.safepoint_seq;
            // The loop is far past the test hotloop threshold (4): recording
            // must actually have armed (and closed) during this run for the
            // handoff pin to mean anything.
            try testing.expect(vm.trace.registry.cache.items.len >= 1);
        }
    };
    var sink_buf_a: [256]u8 = undefined;
    var sink_a = io.Writer.fixed(&sink_buf_a);
    try testutil.runCapturedTuned(gpa, src, &sink_a, false, .off, .{ .inspect = Hook.off });
    var sink_buf_b: [256]u8 = undefined;
    var sink_b = io.Writer.fixed(&sink_buf_b);
    try testutil.runCapturedTuned(gpa, src, &sink_b, false, .record_only, .{ .inspect = Hook.rec });
    try testing.expectEqualStrings(sink_a.buffered(), sink_b.buffered());
    try testing.expect(Hook.seq_off != 0);
    try testing.expectEqual(Hook.seq_off, Hook.seq_rec);
}

// T-1: an error raised while a recording is live must abort the recording
// (doc 26 D1a: the raise is invisible to the recorded IR) and clear any
// pending continuation anchor — even when a pcall catches the error and the
// program completes normally. After the doc-42 flip this same cleanup rides
// `execImpl`'s translated error boundary instead of `try`-propagation, so
// pin it now.
test "T-1: error mid-recording aborts the recording and clears pending anchors" {
    const gpa = testing.allocator;
    const src: [:0]const u8 =
        \\local function boom(i)
        \\  if i == 30 then error("mid") end
        \\  return i
        \\end
        \\local acc = 0
        \\local ok = pcall(function()
        \\  for i = 1, 40 do
        \\    acc = acc + boom(i)
        \\  end
        \\end)
        \\print(ok, acc)
        \\
    ;
    const Hook = struct {
        fn check(vm: *Vm, mode: testutil.TraceMode) anyerror!void {
            _ = mode;
            try testing.expect(!vm.trace.isRecording());
            try testing.expect(vm.trace.pending_exit_anchor == null);
            try testing.expect(vm.trace.pending_replay_anchor == null);
        }
    };
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try testutil.runCapturedTuned(gpa, src, &sink, false, .record_only, .{ .inspect = Hook.check });
    try testing.expectEqualStrings("false\t435\n", sink.buffered());
}

// T-5: reentrant `callValue` (a metamethod re-entering the interpreter from
// inside the dispatch loop) — the outer activation's cached execution state
// must survive the nested run. Pinned at output + safepoint granularity so
// a conversion that corrupts the outer ExecState across the nested execWith
// (doc 42 §4.1 ownership) fails loudly here, not just in program output.
test "T-5: reentrant callValue via __index preserves outer execution state" {
    const gpa = testing.allocator;
    const src: [:0]const u8 =
        \\local t = setmetatable({}, { __index = function(_, k) return k * 2 end })
        \\local acc = 0
        \\for i = 1, 12 do
        \\  acc = acc + t[i]
        \\end
        \\print(acc)
        \\
    ;
    const Hook = struct {
        var seq: u64 = 0;
        fn grab(vm: *Vm, mode: testutil.TraceMode) anyerror!void {
            _ = mode;
            seq = vm.safepoint_seq;
        }
    };
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try testutil.runCapturedTuned(gpa, src, &sink, false, .off, .{ .inspect = Hook.grab });
    try testing.expectEqualStrings("156\n", sink.buffered());
    const first = Hook.seq;
    var sink_buf2: [256]u8 = undefined;
    var sink2 = io.Writer.fixed(&sink_buf2);
    try testutil.runCapturedTuned(gpa, src, &sink2, false, .off, .{ .inspect = Hook.grab });
    try testing.expectEqual(first, Hook.seq);
}
