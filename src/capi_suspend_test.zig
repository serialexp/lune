//! Doc 63 Phase 1: every §5.9 gate honours `TraceState.suspend_depth`.
//!
//! Nothing raises the depth outside tests yet (Phase 2c raises it around a
//! recording-time host call), so these tests raise it by hand around a
//! host-made callback: `susp(name, n)` looks up the global `name` and calls
//! it with `n` through `mh_call` while suspended. Each test pairs the
//! suspended run with an unsuspended control showing the same program does
//! reach the gate, so a passing test cannot be a gate that was never hit.

const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");
const mahina = @import("mahina");

const Value = mahina.Value;
const Closure = mahina.function.Closure;
const mh_value = capi.mh_value;
const mh_str = capi.mh_str;
const Status = capi.mh_status;
const AnchorKey = mahina.trace.AnchorKey;

fn s(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn toValue(cv: mh_value) Value {
    return .{ .tag = @enumFromInt(cv.tag), .payload = .{ .bits = cv.payload } };
}

/// Calls `args[0]` (a global's name) with `args[1]` while the JIT is
/// suspended, and returns its first result.
fn hostSusp(vm: ?*capi.VmBox, userdata: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    _ = .{ userdata, max_results };
    if (nargs != 2) return .err_api;
    const box = vm.?;
    var name: mh_str = .{};
    if (capi.mh_value_str(box, args.?[0], &name) != .ok) return .err_api;
    var f: mh_value = .{};
    if (capi.mh_global_get(box, name, &f) != .ok) return .err_api;
    box.vm.trace.raiseSuspend();
    defer box.vm.trace.lowerSuspend();
    var r: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_call(box, f, args.? + 1, 1, &r, 1, &n);
    if (st != .ok) return st;
    results.?[0] = if (n == 0) capi.mh_nil() else r[0];
    nresults.* = 1;
    return .ok;
}

const program =
    \\function work(n) local s = 0 for i = 1, n do s = s + i % 7 end return s end
    \\function wloop(n) local s, i = 0, 0 while i < n do s = s + i i = i + 1 end return s end
    \\function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
    \\function boom(n) error("boom " .. n) end
;

fn newVm() !*capi.VmBox {
    const box = try capi.createVm(testing.allocator, .{});
    errdefer _ = capi.mh_vm_free(box);
    try testing.expectEqual(Status.ok, capi.mh_register_fn(box, s("susp"), &hostSusp, null, null));
    var n: usize = 0;
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s(program), s("prog"), null, 0, &n));
    return box;
}

fn freeVm(box: *capi.VmBox) void {
    testing.expectEqual(Status.ok, capi.mh_vm_free(box)) catch unreachable;
}

fn evalInt(box: *capi.VmBox, src: []const u8) !i64 {
    var out: [1]mh_value = undefined;
    var n: usize = 0;
    const st = capi.mh_eval(box, s(src), s("t"), &out, 1, &n);
    if (st != .ok) {
        const e = capi.mh_last_error(box);
        std.debug.print("eval failed: {s}\n", .{if (e.ptr) |p| p[0..e.len] else ""});
        return error.EvalFailed;
    }
    var x: i64 = 0;
    try testing.expectEqual(Status.ok, capi.mh_value_int(out[0], &x));
    return x;
}

fn traceCount(box: *capi.VmBox) usize {
    return box.vm.trace.registry.cache.items.len;
}

/// The image op at every live patch, for comparison across a suspended call.
const PatchSnap = struct {
    ops: [64]mahina.bytecode.OpCode = undefined,
    len: usize = 0,

    fn take(box: *capi.VmBox) PatchSnap {
        var snap: PatchSnap = .{};
        for (box.vm.trace.registry.entry_registry.entry_patches.items) |p| {
            snap.ops[snap.len] = imageOp(box, p);
            snap.len += 1;
        }
        return snap;
    }
};

fn imageOp(box: *capi.VmBox, p: *const mahina.trace.EntryPatch) mahina.bytecode.OpCode {
    return box.vm.trace.registry.entry_registry.codeFor(p.proto)[p.patch_pc].op;
}

test "doc 63 suspend: a suspended callback records nothing (for-loop, while-loop, head)" {
    const box = try newVm();
    defer freeVm(box);
    try testing.expectEqual(@as(i64, 6000), try evalInt(box, "return susp('work', 2000)"));
    try testing.expectEqual(@as(i64, 1999000), try evalInt(box, "return susp('wloop', 2000)"));
    try testing.expectEqual(@as(i64, 2584), try evalInt(box, "return susp('fib', 18)"));
    try testing.expect(!box.vm.trace.isRecording());
    try testing.expectEqual(@as(usize, 0), traceCount(box));

    // Control: the same calls unsuspended record all three.
    try testing.expectEqual(@as(i64, 6000), try evalInt(box, "return work(2000)"));
    try testing.expectEqual(@as(i64, 1999000), try evalInt(box, "return wloop(2000)"));
    try testing.expectEqual(@as(i64, 2584), try evalInt(box, "return fib(18)"));
    try testing.expect(traceCount(box) >= 3);
}

test "doc 63 suspend: a suspended callback enters no trace and leaves every patch installed" {
    const box = try newVm();
    defer freeVm(box);
    // Warm up unsuspended until loop and head patches are installed and
    // entered.
    for (0..4) |_| {
        _ = try evalInt(box, "return work(2000)");
        _ = try evalInt(box, "return wloop(2000)");
        _ = try evalInt(box, "return fib(18)");
    }
    const patches = box.vm.trace.registry.entry_registry.entry_patches.items;
    try testing.expect(patches.len >= 3);
    // Every patched kind is present, so each patched handler's gate is
    // reached below: the loop pair, the head and the continuation.
    var kinds: std.EnumSet(mahina.bytecode.OpCode) = .empty;
    for (patches) |p| {
        try testing.expect(p.live);
        try testing.expectEqual(p.patched_op, imageOp(box, p));
        kinds.insert(p.patched_op);
    }
    for ([_]mahina.bytecode.OpCode{ .jfor_loop, .jloop, .jfunc_head, .jcont }) |k| {
        if (!kinds.contains(k)) {
            std.debug.print("warm-up installed no {t} patch\n", .{k});
            return error.MissingPatchKind;
        }
    }

    // Per function: suspended, no entry and no patch change; unsuspended
    // (the control), the same call enters, so the suspended run did execute
    // the patched instructions the control enters through.
    const calls = [_]struct { name: []const u8, want: i64 }{
        .{ .name = "work", .want = 6000 },
        .{ .name = "wloop", .want = 1999000 },
        .{ .name = "fib", .want = 2584 },
    };
    var buf: [64]u8 = undefined;
    for (calls) |c| {
        const entries = box.vm.trace.entries;
        const traces = traceCount(box);
        const snap = PatchSnap.take(box);
        const susp_src = try std.fmt.bufPrint(&buf, "return susp('{s}', {d})", .{ c.name, if (c.want == 2584) @as(i64, 18) else 2000 });
        try testing.expectEqual(c.want, try evalInt(box, susp_src));
        try testing.expectEqual(entries, box.vm.trace.entries);
        try testing.expectEqual(traces, traceCount(box));
        const after = PatchSnap.take(box);
        try testing.expectEqualSlices(mahina.bytecode.OpCode, snap.ops[0..snap.len], after.ops[0..after.len]);

        const ctl_src = try std.fmt.bufPrint(&buf, "return {s}({d})", .{ c.name, if (c.want == 2584) @as(i64, 18) else 2000 });
        try testing.expectEqual(c.want, try evalInt(box, ctl_src));
        if (box.vm.trace.entries == entries) {
            std.debug.print("control: {s} entered no trace\n", .{c.name});
            return error.ControlEnteredNothing;
        }
    }
}

test "doc 63 suspend: a cached trace without an entry patch is not entered from the back-edge" {
    const box = try newVm();
    defer freeVm(box);
    // Tier-1a only: loop patches need a compiled native, so the cached
    // trace is entered through `backEdgeEpilogue`'s walk, not a patch.
    box.vm.trace.config.native_codegen = false;
    for (0..4) |_| _ = try evalInt(box, "return work(2000)");
    try testing.expect(traceCount(box) >= 1);
    try testing.expectEqual(@as(usize, 0), box.vm.trace.registry.entry_registry.entry_patches.items.len);

    const entries = box.vm.trace.entries;
    const base = box.vm.trace.pending_anchor_base;
    try testing.expectEqual(@as(i64, 6000), try evalInt(box, "return susp('work', 2000)"));
    try testing.expectEqual(entries, box.vm.trace.entries);
    // The back-edge slow path, whose first write is the recorder's slab
    // base, did not run either.
    try testing.expectEqual(base, box.vm.trace.pending_anchor_base);

    // Control.
    try testing.expectEqual(@as(i64, 6000), try evalInt(box, "return work(2000)"));
    try testing.expect(box.vm.trace.entries > entries);
}

test "doc 63 suspend: logically invalidated patches reached while suspended stay for the next unsuspended visit" {
    const box = try newVm();
    defer freeVm(box);
    for (0..4) |_| {
        _ = try evalInt(box, "return work(2000)");
        _ = try evalInt(box, "return wloop(2000)");
        _ = try evalInt(box, "return fib(18)");
    }
    const reg = &box.vm.trace.registry.entry_registry;
    const patches = reg.entry_patches.items;
    // Invalidate every patch, all four handler kinds among them.
    var kinds: std.EnumSet(mahina.bytecode.OpCode) = .empty;
    for (patches, 0..) |p, i| {
        try testing.expect(p.live);
        kinds.insert(p.patched_op);
        box.vm.trace.markEntryPatchPending(@intCast(i));
        try testing.expect(!p.live and p.pending_unpatch);
    }
    for ([_]mahina.bytecode.OpCode{ .jfor_loop, .jloop, .jfunc_head, .jcont }) |k|
        try testing.expect(kinds.contains(k));

    // Suspended: each handler runs the canonical op and leaves its slot to
    // the next unsuspended visit.
    try testing.expectEqual(@as(i64, 6000), try evalInt(box, "return susp('work', 2000)"));
    try testing.expectEqual(@as(i64, 1999000), try evalInt(box, "return susp('wloop', 2000)"));
    try testing.expectEqual(@as(i64, 2584), try evalInt(box, "return susp('fib', 18)"));
    for (patches) |p| {
        try testing.expect(p.pending_unpatch);
        try testing.expectEqual(p.patched_op, imageOp(box, p));
    }

    // Unsuspended: the first contact completes each unpatch. A trace still
    // alive may be reinstalled into the freed slot; either way the slot is
    // settled and the image agrees with it.
    try testing.expectEqual(@as(i64, 6000), try evalInt(box, "return work(2000)"));
    try testing.expectEqual(@as(i64, 1999000), try evalInt(box, "return wloop(2000)"));
    try testing.expectEqual(@as(i64, 2584), try evalInt(box, "return fib(18)"));
    for (patches) |p| {
        try testing.expect(!p.pending_unpatch);
        try testing.expectEqual(if (p.live) p.patched_op else p.orig.op, imageOp(box, p));
    }
}

test "doc 63 suspend: a suspended raising exec keeps the pending exit anchor and starts nothing" {
    const box = try newVm();
    defer freeVm(box);
    var f: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_global_get(box, s("boom"), &f));
    const proto = Closure.fromHeader(toValue(f).asHeap()).proto;
    const key: AnchorKey = .{ .proto = proto, .pc = 0, .proto_id = proto.id };
    const vm = &box.vm;
    const arg = [_]mh_value{capi.mh_int(1)};
    var r: [1]mh_value = undefined;
    var n: usize = 0;

    vm.trace.setPendingExitAnchor(key);
    vm.trace.raiseSuspend();
    try testing.expectEqual(Status.err_runtime, capi.mh_call(box, f, &arg, 1, &r, 1, &n));
    vm.trace.lowerSuspend();
    try testing.expect(!vm.trace.isRecording());
    try testing.expectEqual(@as(?AnchorKey, key), vm.trace.pending_exit_anchor);

    // Control: unsuspended, the raising exec clears it.
    try testing.expectEqual(Status.err_runtime, capi.mh_call(box, f, &arg, 1, &r, 1, &n));
    try testing.expectEqual(@as(?AnchorKey, null), vm.trace.pending_exit_anchor);
}

/// Step `vm` one instruction at a time (the replay tests' `suspend_ctl`
/// cut) until a recording is active. Returns false if the run finished
/// first. The resumed instruction's prologue counts its own safepoint
/// before the cut is checked, so the next cut is two safepoints on (one
/// would re-suspend at the same pc forever).
fn stepUntilRecording(vm: *mahina.interp.Vm, outcome_in: mahina.interp.ExecOutcome) !bool {
    var outcome = outcome_in;
    var steps: usize = 0;
    while (outcome == .suspended) : (steps += 1) {
        if (vm.trace.isRecording()) return true;
        if (steps == 100_000) return error.NoRecordingStarted;
        vm.setSuspendCtl(.{ .after_safepoints = vm.safepoint_seq + 2 });
        outcome = try vm.exec();
    }
    return false;
}

const RecSnap = struct {
    anchor_pc: u32,
    instrs: usize,
    rec_path: usize,
    consts: usize,
    pending_anchor_base: usize,
    /// The pending exit anchor's identity (proto address, pc), if any.
    pending_exit: ?struct { usize, u32 },
    traces: usize,

    fn take(box: *capi.VmBox) RecSnap {
        const tr = &box.vm.trace;
        return .{
            .anchor_pc = tr.rec.anchor.pc,
            .instrs = tr.rec.instrs.items.len,
            .rec_path = tr.rec.rec_path.items.len,
            .consts = tr.rec.consts.items.len,
            .pending_anchor_base = tr.pending_anchor_base,
            .pending_exit = if (tr.pending_exit_anchor) |k| .{ @intFromPtr(k.proto), k.pc } else null,
            .traces = traceCount(box),
        };
    }
};

test "doc 63 suspend: a suspended callback leaves an active outer recording untouched" {
    const box = try newVm();
    defer freeVm(box);
    const vm = &box.vm;
    // The outer loop, paused mid-recording at a safepoint. Its frame base
    // differs from the callback's, so a stray slab-base write would show.
    var sb: *capi.ScriptBox = undefined;
    try testing.expectEqual(Status.ok, capi.mh_compile(box, s(
        \\local s = 0
        \\for i = 1, 3000 do s = s + i % 5 end
        \\return s
    ), s("outer"), &sb));
    defer capi.mh_script_free(sb);
    vm.setSuspendCtl(.{ .after_safepoints = vm.safepoint_seq + 1 });
    try testing.expect(try stepUntilRecording(vm, try vm.start(sb.proto)));
    vm.setSuspendCtl(null);

    // A suspended callback runs loops, calls and returns (and a raise that
    // `pcall` catches): the recording sees none of it.
    const snap = RecSnap.take(box);
    var f: mh_value = .{};
    try testing.expectEqual(Status.ok, capi.mh_global_get(box, s("work"), &f));
    var res: [1]Value = undefined;
    vm.trace.raiseSuspend();
    _ = try vm.callValue(toValue(f), &.{Value.int(2000)}, &res);
    try testing.expectEqual(@as(i64, 6000), res[0].asInt());
    try testing.expectEqual(Status.ok, capi.mh_global_get(box, s("fib"), &f));
    _ = try vm.callValue(toValue(f), &.{Value.int(12)}, &res);
    vm.trace.abortRaised();
    vm.trace.lowerSuspend();
    try testing.expect(vm.trace.isRecording());
    try testing.expectEqual(snap, RecSnap.take(box));

    // The outer run resumes and finishes with the right answer.
    const out = try vm.exec();
    try testing.expect(out == .finished);
    try testing.expectEqual(@as(i64, 6000), vm.regGet(out.finished.reg).asInt());
}

test "doc 63 suspend: abortRaised leaves an active recording to its owner only while suspended" {
    const box = try newVm();
    defer freeVm(box);
    const vm = &box.vm;
    var sb: *capi.ScriptBox = undefined;
    try testing.expectEqual(Status.ok, capi.mh_compile(box, s(
        \\local s = 0
        \\for i = 1, 3000 do s = s + i % 5 end
        \\return s
    ), s("outer"), &sb));
    defer capi.mh_script_free(sb);
    vm.setSuspendCtl(.{ .after_safepoints = vm.safepoint_seq + 1 });
    try testing.expect(try stepUntilRecording(vm, try vm.start(sb.proto)));
    vm.setSuspendCtl(null);

    vm.trace.raiseSuspend();
    vm.trace.abortRaised();
    vm.trace.lowerSuspend();
    try testing.expect(vm.trace.isRecording());
    // Control: unsuspended, the same call aborts it.
    vm.trace.abortRaised();
    try testing.expect(!vm.trace.isRecording());

    const out = try vm.exec();
    try testing.expect(out == .finished);
    try testing.expectEqual(@as(i64, 6000), vm.regGet(out.finished.reg).asInt());
}
