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
