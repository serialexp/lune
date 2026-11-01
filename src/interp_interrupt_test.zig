//! Tests for the interrupt request (doc 75 §4): `Heap.requestInterrupt`
//! makes the dispatch prologue's one GC compare send the next safepoint to
//! the cold trampoline, which raises `Error.Interrupted` — an unwind no
//! `pcall` may stop, after which the VM runs again.

const std = @import("std");
const interp = @import("interp.zig");
const util = @import("interp_testutil.zig");
const testing = std.testing;

const Vm = interp.Vm;

test "interrupt: a requested interrupt stops a runaway loop" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.requestInterrupt();
    try testing.expect(vm.heap.interruptPending());
    try testing.expectError(error.Interrupted, util.compileRun(testing.allocator, &vm, "while true do end"));
}

test "interrupt: pcall does not catch it" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.requestInterrupt();
    try testing.expectError(
        error.Interrupted,
        util.compileRun(testing.allocator, &vm, "pcall(function() while true do end end); caught = true"),
    );
    try testing.expect(!interp.catchable(error.Interrupted));
}

test "interrupt: clearing the request lets the VM run again" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    vm.heap.requestInterrupt();
    try testing.expectError(error.Interrupted, util.compileRun(testing.allocator, &vm, "while true do end"));
    vm.heap.clearInterrupt();
    vm.pending_error = null;
    vm.unwindTo(0, 0);
    try util.compileRun(testing.allocator, &vm, "local n = 0; for i = 1, 1000 do n = n + i end; assert(n == 500500)");
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
        try util.compileRun(testing.allocator, &vm, "local n = 0; for i = 1, 1000 do n = n + i end; assert(n == 500500)");
    }
};

const arith_loop = "local x = 0 while true do x = x + 1 end";
const call_loop = "local function f(a) return a + 1 end local x = 0 while true do x = f(x) end";
const table_loop = "local t = {} local n = 0 while true do n = n + 1 t[n % 8 + 1] = n end";
const for_loop = "local x = 0 for i = 1, math.maxinteger do x = x + i end";

test "interrupt: a running tier-1a trace stops at its back-edge (arith)" {
    try tracing.run(arith_loop, false);
}

test "interrupt: a running tier-1a trace stops at its back-edge (call)" {
    try tracing.run(call_loop, false);
}

test "interrupt: a running tier-1a trace stops at its back-edge (table)" {
    try tracing.run(table_loop, false);
}

test "interrupt: a running tier-1a trace stops at its back-edge (for)" {
    try tracing.run(for_loop, false);
}

test "interrupt: a running native trace stops at its back-edge (arith)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(arith_loop, true);
}

test "interrupt: a running native trace stops at its back-edge (call)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(call_loop, true);
}

test "interrupt: a running native trace stops at its back-edge (table)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(table_loop, true);
}

test "interrupt: a running native trace stops at its back-edge (for)" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try tracing.run(for_loop, true);
}
