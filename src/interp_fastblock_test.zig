//! Doc 60 §5.4 / §6.1: the packed fast-path word. `trace.fast_block` must
//! equal `Vm.fastBlockReference()` (the eleven-condition predicate, rebuilt
//! from the fields) bit for bit after EVERY transition — not just agree on
//! "zero or not", which could hide a missing or extra bit while another
//! condition is set. Each test drives the real mutation methods (setters and
//! the lifecycle consumers that clear) and checks the exact expected word.

const std = @import("std");
const testing = std.testing;
const interp = @import("interp.zig");
const trace = @import("trace.zig");
const bytecode = @import("bytecode.zig");
const util = @import("interp_testutil.zig");

const Vm = interp.Vm;
const Trace = trace.Trace;
const AnchorKey = trace.AnchorKey;
const Bit = trace.TraceState.FastBit;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;

fn expectWord(vm: *const Vm, want: u16) !void {
    try testing.expectEqual(vm.fastBlockReference(), vm.trace.fast_block);
    try testing.expectEqual(want, vm.trace.fast_block);
}

const proto = Proto{ .code = &.{}, .name = "fb", .num_registers = 2 };
const key_a: AnchorKey = .{ .proto = &proto, .pc = 4, .proto_id = proto.id };
const key_b: AnchorKey = .{ .proto = &proto, .pc = 7, .proto_id = proto.id };

test "fast_block: each of the eleven conditions owns exactly its bit" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try expectWord(&vm, 0);

    vm.setSuspendCtl(.{ .after_safepoints = 1 });
    try expectWord(&vm, Bit.vm_suspend);
    vm.setSuspendCtl(null);
    try expectWord(&vm, 0);

    vm.setRecordSafepointLines(true);
    try expectWord(&vm, Bit.vm_safepoint_lines);
    vm.setRecordSafepointLines(false);
    try expectWord(&vm, 0);

    vm.setFinalCut(.{ .result_base = 0, .result_count = 0, .stack_top = 0 });
    try expectWord(&vm, Bit.vm_final_cut);
    vm.retireFinalCut();
    try expectWord(&vm, 0);

    const ts = &vm.trace;
    ts.setPendingExitAnchor(key_a);
    try expectWord(&vm, Bit.exit_anchor);
    ts.setPendingExitAnchor(null);
    ts.setPendingReplayAnchor(key_a);
    try expectWord(&vm, Bit.replay_anchor);
    ts.setPendingReplayAnchor(null);
    ts.setPendingCallAnchor(.{ .proto = &proto, .base = 0, .call_seq = 1 });
    try expectWord(&vm, Bit.call_anchor);
    ts.setPendingCallAnchor(null);
    ts.setPendingRetAnchor(.{ .proto = &proto, .resume_pc = 3, .base = 0, .call_seq = 1 });
    try expectWord(&vm, Bit.ret_anchor);
    ts.setPendingRetAnchor(null);
    ts.setPendingRetContArm(.{ .trace_id = 1, .exit_instr = 2 });
    try expectWord(&vm, Bit.ret_cont_arm);
    ts.setPendingRetContArm(null);
    ts.setPendingCallHeadArm(.{ .trace_id = 1, .exit_instr = 2 });
    try expectWord(&vm, Bit.call_head_arm);
    ts.setPendingCallHeadArm(null);
    try expectWord(&vm, 0);

    // Doc 63 §5.9 suspension: held through nesting, cleared by the last
    // lower.
    ts.raiseSuspend();
    try expectWord(&vm, Bit.jit_suspended);
    ts.raiseSuspend();
    ts.lowerSuspend();
    try expectWord(&vm, Bit.jit_suspended);
    ts.lowerSuspend();
    try expectWord(&vm, 0);

    // Recording: set by the start funnel, cleared by the raise abort.
    try testing.expect(ts.startRecording(key_a, proto.num_registers));
    try expectWord(&vm, Bit.recording);
    ts.abortRaised();
    try expectWord(&vm, 0);
    // And by the test-only direct start/stop wrappers.
    try ts.startRecordingForTest(testing.allocator, key_a, proto.num_registers);
    try expectWord(&vm, Bit.recording);
    ts.stopRecordingForTest();
    try expectWord(&vm, 0);
}

test "fast_block: the audit's coexistences, and selective clearing" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ts = &vm.trace;

    // Exit anchor + ret anchor (doc 60 §5.4: `onRetResume` checks only
    // `rec.active`). Consuming the ret anchor on a mismatch leaves the exit.
    ts.setPendingExitAnchor(key_a);
    ts.setPendingRetAnchor(.{ .proto = &proto, .resume_pc = 3, .base = 0, .call_seq = 1 });
    try expectWord(&vm, Bit.exit_anchor | Bit.ret_anchor);
    try testing.expect(!ts.maybeStartCont(&proto, 9, 0, 1));
    try expectWord(&vm, Bit.exit_anchor);

    // Exit anchor + replay anchor (`consumeSideTraceWantAtResume` does not
    // check the exit anchor). `clearPendingExitAnchor` drops both, and only
    // those two: a call anchor filed meanwhile survives.
    ts.setPendingReplayAnchor(key_b);
    ts.setPendingCallAnchor(.{ .proto = &proto, .base = 0, .call_seq = 2 });
    try expectWord(&vm, Bit.exit_anchor | Bit.replay_anchor | Bit.call_anchor);
    ts.clearPendingExitAnchor();
    try expectWord(&vm, Bit.call_anchor);
    try testing.expect(!ts.maybeStartHead(&proto, 5, 0, 2)); // pc != 0: discard
    try expectWord(&vm, 0);

    // A continuation start consumes the exit anchor and raises the recording
    // bit in the same step; arm requests (which wait for a trace entry) ride
    // through untouched — including a live recording.
    ts.setPendingRetContArm(.{ .trace_id = 1, .exit_instr = 2 });
    ts.setPendingExitAnchor(key_a);
    try expectWord(&vm, Bit.ret_cont_arm | Bit.exit_anchor);
    ts.maybeStartContinuation(&proto, key_a.pc);
    try expectWord(&vm, Bit.ret_cont_arm | Bit.recording);
    ts.setPendingCallHeadArm(.{ .trace_id = 3, .exit_instr = 4 });
    try expectWord(&vm, Bit.ret_cont_arm | Bit.recording | Bit.call_head_arm);
    ts.abortRaised();
    try expectWord(&vm, Bit.ret_cont_arm | Bit.call_head_arm);

    // The same for the replay-side start.
    ts.setPendingReplayAnchor(key_b);
    ts.maybeStartReplaySide(&proto, key_b.pc);
    try expectWord(&vm, Bit.ret_cont_arm | Bit.call_head_arm | Bit.recording);
    ts.stopRecordingForTest();

    // VM bits alongside trace bits, then cleared selectively.
    vm.setSuspendCtl(.{ .after_safepoints = 1 });
    vm.setRecordSafepointLines(true);
    try expectWord(&vm, Bit.ret_cont_arm | Bit.call_head_arm | Bit.vm_suspend | Bit.vm_safepoint_lines);
    vm.setSuspendCtl(null);
    ts.setPendingCallHeadArm(null);
    try expectWord(&vm, Bit.ret_cont_arm | Bit.vm_safepoint_lines);
    vm.setRecordSafepointLines(false);
    ts.setPendingRetContArm(null);
    try expectWord(&vm, 0);
}

test "fast_block: arm-request displacement keeps the bit; stale-parent drops clear it" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ts = &vm.trace;
    ts.config.hotguard = 2;

    const cont_proto = Proto{ .code = &.{Instr.op0(.ret)}, .name = "fb-displace", .num_registers = 1 };
    var owner: Trace = .{
        .code = .{
            .anchor = .{ .proto = &cont_proto, .pc = trace.contAnchorPc(0), .proto_id = cont_proto.id },
            .instrs = &.{},
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
        },
        .id = 7,
    };
    // A stale request occupies the slot; the owner's hotguard crossing
    // displaces it (`noteRetContTransition` → `fileRetContArm`).
    ts.setPendingRetContArm(.{ .trace_id = 99, .exit_instr = 3 });
    try expectWord(&vm, Bit.ret_cont_arm);
    ts.noteRetContTransition(&owner, 5);
    ts.noteRetContTransition(&owner, 5);
    try testing.expectEqual(@as(u32, 7), ts.pending_ret_cont_arm.?.trace_id);
    try expectWord(&vm, Bit.ret_cont_arm);

    // Unsafe-to-arm entries keep both requests; a safe entry whose parents
    // are gone (no trace 7, no trace 98 in the registry) drops both.
    ts.setPendingCallHeadArm(.{ .trace_id = 98, .exit_instr = 1 });
    ts.tryArmFrameLinks(&owner, false);
    try expectWord(&vm, Bit.ret_cont_arm | Bit.call_head_arm);
    ts.tryArmFrameLinks(&owner, true);
    try testing.expectEqual(@as(?trace.ExitKey, null), ts.pending_ret_cont_arm);
    try testing.expectEqual(@as(?trace.ExitKey, null), ts.pending_call_head_arm);
    try expectWord(&vm, 0);
}

test "fast_block: a cache clear recomputes only the trace bits and keeps the VM bits" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ts = &vm.trace;

    vm.setSuspendCtl(.{ .after_safepoints = 1 });
    vm.setRecordSafepointLines(true);
    ts.setPendingExitAnchor(key_a);
    ts.setPendingReplayAnchor(key_b);
    ts.setPendingRetContArm(.{ .trace_id = 1, .exit_instr = 2 });
    ts.setPendingCallHeadArm(.{ .trace_id = 3, .exit_instr = 4 });
    // Call/ret anchors are frame-keyed (consume-or-discard), not cache
    // state: the clear leaves them, and their bits with them.
    ts.setPendingRetAnchor(.{ .proto = &proto, .resume_pc = 3, .base = 0, .call_seq = 1 });
    try expectWord(&vm, Bit.vm_suspend | Bit.vm_safepoint_lines | Bit.exit_anchor | Bit.replay_anchor |
        Bit.ret_cont_arm | Bit.call_head_arm | Bit.ret_anchor);

    ts.clearCache();
    try expectWord(&vm, Bit.vm_suspend | Bit.vm_safepoint_lines | Bit.ret_anchor);

    vm.setSuspendCtl(null);
    vm.setRecordSafepointLines(false);
    ts.setPendingRetAnchor(null);
    try expectWord(&vm, 0);
}

// The recorder lifecycle. `TraceState.assertTraceBitsInSync` checks the word
// at every start, recorded instruction, close and abort inside these runs;
// the tests below pin the end states, with unrelated bits held set.

test "fast_block: a start that fails to allocate drops the recording bit and keeps the rest" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ts = &vm.trace;
    ts.setPendingCallHeadArm(.{ .trace_id = 3, .exit_instr = 4 });
    vm.setRecordSafepointLines(true);
    try testing.expect(ts.startRecording(key_a, proto.num_registers));
    try expectWord(&vm, Bit.call_head_arm | Bit.vm_safepoint_lines | Bit.recording);

    // A restart whose register map must grow, on an allocator that refuses:
    // the reset has already retired the old recording, so its bit goes too.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const real = ts.gpa;
    ts.gpa = failing.allocator();
    const started = ts.startRecording(key_b, proto.num_registers + 1);
    ts.gpa = real;
    try testing.expect(!started);
    try testing.expect(!ts.rec.active);
    try expectWord(&vm, Bit.call_head_arm | Bit.vm_safepoint_lines);

    // The recorder recovers on the real allocator.
    try testing.expect(ts.startRecording(key_b, proto.num_registers + 1));
    try expectWord(&vm, Bit.call_head_arm | Bit.vm_safepoint_lines | Bit.recording);
    ts.abortRaised();
    try expectWord(&vm, Bit.call_head_arm | Bit.vm_safepoint_lines);
}

fn recordingVm(vm: *Vm, maxrecord: u32) void {
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.maxrecord = maxrecord;
    vm.trace.config.record_aborts = true;
}

const lifecycle_src =
    \\local acc = 0
    \\for i = 1, 80 do acc = acc + i * 2 - (i % 3) + (i // 4) end
    \\local t = {}
    \\for i = 1, 40 do t[i] = i + acc end
;

test "fast_block: a recording that commits and one that aborts itself mid-record leave only the other bits" {
    // Commit: the default budget lets the loops close and finalize.
    {
        var vm = try Vm.init(testing.allocator);
        defer vm.deinit();
        recordingVm(&vm, 2000);
        vm.setRecordSafepointLines(true);
        try util.compileRun(testing.allocator, &vm, lifecycle_src);
        try testing.expect(vm.trace.registry.cache.items.len > 0);
        // The finished run published its final cut.
        try expectWord(&vm, Bit.vm_safepoint_lines | Bit.vm_final_cut);
    }
    // Self-abort: an 8-instruction budget kills each recording inside
    // `rec.recordInstr` (`too_long`), the path with no `TraceState.abort`.
    {
        var vm = try Vm.init(testing.allocator);
        defer vm.deinit();
        recordingVm(&vm, 8);
        vm.setRecordSafepointLines(true);
        try util.compileRun(testing.allocator, &vm, lifecycle_src);
        var too_long = false;
        for (vm.trace.abort_log.items) |r| too_long = too_long or r.reason == .too_long;
        try testing.expect(too_long);
        try expectWord(&vm, Bit.vm_safepoint_lines | Bit.vm_final_cut);
    }
}

test "fast_block: every allocation failure in a recording run leaves the word in sync" {
    // Count the run's allocations once, then fail each one in turn: recorder
    // starts, IR growth, finalize, registry publication and the interpreter's
    // own allocations all fail somewhere in the sweep.
    var total: usize = 0;
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var vm = try Vm.init(fa.allocator());
        defer vm.deinit();
        recordingVm(&vm, 2000);
        const before = fa.alloc_index;
        try util.compileRun(fa.allocator(), &vm, lifecycle_src);
        total = fa.alloc_index - before;
    }
    try testing.expect(total > 0);
    for (0..total) |k| {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var vm = try Vm.init(fa.allocator());
        defer vm.deinit();
        recordingVm(&vm, 2000);
        fa.fail_index = fa.alloc_index + k;
        util.compileRun(fa.allocator(), &vm, lifecycle_src) catch |e| switch (e) {
            error.OutOfMemory => {},
            else => return e,
        };
        try testing.expectEqual(vm.fastBlockReference(), vm.trace.fast_block);
    }
}
