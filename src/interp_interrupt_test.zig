//! Tests for the interrupt request (doc 75 §4): `Heap.requestInterrupt`
//! makes the dispatch prologue's one GC compare send the next safepoint to
//! the cold trampoline, which raises `Error.Interrupted` — an unwind no
//! `pcall` may stop, after which the VM runs again.

const std = @import("std");
const interp = @import("interp.zig");
const util = @import("interp_testutil.zig");
const testing = std.testing;

const Vm = interp.Vm;

/// Set before a loop that never ends; the next chunk checks it survived.
const keep = "keep = 42 ";
const reuse = "assert(keep == 42); local n = 0; for i = 1, 1000 do n = n + i end; assert(n == 500500)";

test "[REQ-4.1] interrupt: a requested interrupt stops a runaway loop" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.requestInterrupt();
    try testing.expect(vm.heap.interruptPending());
    try testing.expectError(error.Interrupted, util.compileRun(testing.allocator, &vm, "while true do end"));
}

test "[REQ-5.2] interrupt: pcall does not catch it" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.requestInterrupt();
    try testing.expectError(
        error.Interrupted,
        util.compileRun(testing.allocator, &vm, "pcall(function() while true do end end); caught = true"),
    );
    try testing.expect(!interp.catchable(error.Interrupted));
    // The code after the protected call did not run.
    vm.heap.clearInterrupt();
    vm.pending_error = null;
    vm.unwindTo(0, 0);
    try util.compileRun(testing.allocator, &vm, "assert(caught == nil)");
}

test "[REQ-5.1] interrupt: clearing the request lets the VM run again" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try util.compileRun(testing.allocator, &vm, keep);
    vm.heap.requestInterrupt();
    try testing.expectError(error.Interrupted, util.compileRun(testing.allocator, &vm, "while true do end"));
    vm.heap.clearInterrupt();
    vm.pending_error = null;
    vm.unwindTo(0, 0);
    try util.compileRun(testing.allocator, &vm, reuse);
}

test "interrupt: a request keeps the headroom at zero until it is cleared" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const heap = vm.heap;
    try testing.expect(!heap.shouldCollect());
    heap.requestInterrupt();
    try testing.expect(heap.shouldCollect());
    heap.setGcTarget(heap.gc_target); // anything that re-derives the headroom
    try testing.expect(heap.shouldCollect());
    heap.clearInterrupt();
    try testing.expect(!heap.shouldCollect());
}

// ---- doc 77: the loop back-edge of a running trace polls the request ----

const tracing = struct {
    /// Delivers the interrupt once the trace is entered (`entries` moves
    /// only after the dispatcher enters a trace, so the loop is then
    /// running traced code that never reaches the tier-0 prologue). The
    /// spin is bounded by iterations, not time; if the trace is never
    /// entered the request still goes out and the test's `entries` check
    /// reports it.
    fn deliver(vm: *Vm) void {
        var spins: usize = 0;
        while (@atomicLoad(u64, &vm.trace.entries, .acquire) == 0 and spins < 200_000_000) : (spins += 1) {
            std.Thread.yield() catch {};
        }
        vm.heap.requestInterrupt();
    }

    /// Delivers the interrupt while the recorder is active, if the spin
    /// catches that window (it is short); otherwise it delivers anyway. What
    /// the test asserts holds either way: the run raises `Interrupted`, and
    /// no recording is left active.
    fn deliverWhileRecording(vm: *Vm) void {
        var spins: usize = 0;
        while (!vm.trace.isRecording() and spins < 200_000_000) : (spins += 1) {
            std.Thread.yield() catch {};
        }
        vm.heap.requestInterrupt();
    }

    fn runRecording(source: [:0]const u8, native: bool) !void {
        var vm = try Vm.init(testing.allocator);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.optimize = true;
        vm.trace.config.native_codegen = native;
        vm.trace.config.hotloop = 1;
        const th = try std.Thread.spawn(.{}, deliverWhileRecording, .{&vm});
        const res = util.compileRun(testing.allocator, &vm, source);
        th.join();
        try testing.expectError(error.Interrupted, res);
        try testing.expect(!vm.trace.isRecording());
        vm.heap.clearInterrupt();
        vm.pending_error = null;
        vm.unwindTo(0, 0);
        try util.compileRun(testing.allocator, &vm, reuse);
    }

    fn run(source: [:0]const u8, native: bool) !void {
        var vm = try Vm.init(testing.allocator);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.optimize = true;
        vm.trace.config.native_codegen = native;
        vm.trace.config.hotloop = 4;
        const th = try std.Thread.spawn(.{}, deliver, .{&vm});
        const res = util.compileRun(testing.allocator, &vm, source);
        th.join();
        try testing.expectError(error.Interrupted, res);
        try testing.expect(vm.trace.entries > 0);
        // The VM is usable afterwards, with its state intact.
        vm.heap.clearInterrupt();
        vm.pending_error = null;
        vm.unwindTo(0, 0);
        try util.compileRun(testing.allocator, &vm, reuse);
    }
};

const arith_loop = keep ++ "local x = 0 while true do x = x + 1 end";
const call_loop = keep ++ "local function f(a) return a + 1 end local x = 0 while true do x = f(x) end";
const table_loop = keep ++ "local t = {} local n = 0 while true do n = n + 1 t[n % 8 + 1] = n end";
// A float step on an integer accumulator (int entry, float body). NOT a
// peeled trace: a doc-39 peel needs the loop to be re-entered per instance, so
// a runaway loop cannot be one. The peeled first back-edge (counts two laps)
// is therefore not covered by an interrupt test.
const mixed_loop = keep ++ "local x = 0 while true do x = x + 0.5 end";
// An inner loop under an outer one: the inner trace is entered through a
// chain, so the ledger holds more than one row when the poll fires.
const nested_loop = keep ++ "local x = 0 while true do for j = 1, 7 do x = x + j end end";
// A long body keeps the recorder active for many instructions.
const long_body_loop = keep ++ "local a, b, c, d = 0, 1, 2, 3 while true do a = a + 1 b = b + a c = c + b d = d + c a = a - d b = b - c c = c - a d = d - b end";
const for_loop = keep ++ "local x = 0 for i = 1, math.maxinteger do x = x + i end";

test "[REQ-4.2] [REQ-5.1] interrupt: a running tier-1a trace stops at its back-edge (arith)" {
    try tracing.run(arith_loop, false);
}

test "[REQ-4.2] [REQ-5.1] interrupt: a running tier-1a trace stops at its back-edge (call)" {
    try tracing.run(call_loop, false);
}

test "[REQ-4.2] [REQ-5.1] interrupt: a running tier-1a trace stops at its back-edge (table)" {
    try tracing.run(table_loop, false);
}

test "[REQ-4.2] [REQ-5.1] interrupt: a running tier-1a trace stops at its back-edge (for)" {
    try tracing.run(for_loop, false);
}

test "[REQ-4.3] [REQ-5.1] interrupt: a running native trace stops at its back-edge (arith)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(arith_loop, true);
}

test "[REQ-4.3] [REQ-5.1] interrupt: a running native trace stops at its back-edge (call)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(call_loop, true);
}

test "[REQ-4.3] [REQ-5.1] interrupt: a running native trace stops at its back-edge (table)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(table_loop, true);
}

test "[REQ-4.3] [REQ-5.1] interrupt: a running native trace stops at its back-edge (for)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(for_loop, true);
}

test "[REQ-4.2] [REQ-5.1] interrupt: a running tier-1a trace on an int-to-float loop stops at its back-edge" {
    try tracing.run(mixed_loop, false);
}

test "[REQ-4.3] [REQ-5.1] interrupt: a running native trace on an int-to-float loop stops at its back-edge" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(mixed_loop, true);
}

test "[REQ-4.2] [REQ-5.1] interrupt: a nested loop entered through a chain stops (tier-1a)" {
    try tracing.run(nested_loop, false);
}

test "[REQ-4.3] [REQ-5.1] interrupt: a nested loop entered through a chain stops (native)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(nested_loop, true);
}

test "[REQ-4.4] [REQ-5.1] interrupt: an interrupt during recording leaves no recording active (tier-1a)" {
    try tracing.runRecording(long_body_loop, false);
}

test "[REQ-4.4] [REQ-5.1] interrupt: an interrupt during recording leaves no recording active (native)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.runRecording(long_body_loop, true);
}
