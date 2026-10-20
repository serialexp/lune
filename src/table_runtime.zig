//! Shared non-collecting table helpers for both trace executors.
const table = @import("table.zig");
const object = @import("object.zig");
const Value = @import("value.zig").Value;
const Heap = @import("gc.zig").Heap;

/// C-ABI status for the Doc 45 D5 effect shims and the doc 63 host-call shim.
/// An int enum (not a Zig error union) so native code can branch on a
/// register value. Ordinals are pinned (test below): executors carry them
/// raw in `ExecResult.runtime_error`, and the dispatcher decodes them with
/// `toError`.
pub const Status = enum(u32) {
    ok = 0,
    /// A VM allocation, or the host-call shim's `host_out`, failed.
    out_of_memory = 1,
    /// Reserved for `tset` (metatable/type refusal); `tnew` never returns it.
    /// Doc 63: the host returned a malformed value.
    type_error = 2,
    /// Doc 63: the host failed; the VM already holds the pending error value,
    /// located at the call.
    lua_error = 3,
    /// Doc 63: `host_out` is exhausted.
    stack_overflow = 4,
};

/// The guest error a failure status raises, located at the failing
/// bytecode. Exactly tier-0's error for the same failure: an OOM is
/// uncatchable (doc 45 D5), and a host's `lua_error` leaves its pending value
/// to the VM. `.ok` is not a failure.
pub fn toError(status: Status) error{ OutOfMemory, TypeError, LuaError, StackOverflow } {
    return switch (status) {
        .ok => unreachable,
        .out_of_memory => error.OutOfMemory,
        .type_error => error.TypeError,
        .lua_error => error.LuaError,
        .stack_overflow => error.StackOverflow,
    };
}

/// Doc 45 D3/D5: the `tnew` effect — allocate one fresh empty table and
/// register it with the heap. EXACTLY one `Heap.newTable` call: on success
/// one GC object is linked and `next_obj_id` advances once; on OOM nothing
/// is linked, nothing advances, and NO collection or retry happens here —
/// the executor exits `.precise_error` and tier-0 propagates the uncatchable
/// OOM (D5: partial heap preserved, no rollback). GC headroom is the
/// caller's problem: `guard_gc` (aux = the trace's alloc bound) already
/// proved the budget at the loop head, so this shim never collects.
pub noinline fn tnew(heap: *Heap, out: **table.Table) callconv(.c) Status {
    const t = heap.newTable() catch return .out_of_memory;
    out.* = t;
    return .ok;
}

test "effect-shim status ABI ordinals" {
    // `ExecResult.runtime_error` carries these raw; the future native exit
    // stub bakes the shim's return register verbatim — pin the ABI.
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Status.out_of_memory));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Status.type_error));
    // Doc 63 §5.8: the host-call statuses.
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Status.lua_error));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Status.stack_overflow));
    try std.testing.expectEqual(@as(usize, 5), std.enums.values(Status).len);
}

test "every failure status decodes to tier-0's error" {
    const std = @import("std");
    try std.testing.expectEqual(error.OutOfMemory, toError(.out_of_memory));
    try std.testing.expectEqual(error.TypeError, toError(.type_error));
    try std.testing.expectEqual(error.LuaError, toError(.lua_error));
    try std.testing.expectEqual(error.StackOverflow, toError(.stack_overflow));
}

/// Absence is a full lookup, not an array-bounds predicate: an out-of-array
/// integer may be hash-resident. Check metatables on every invocation so a
/// later __index cannot be suppressed. No allocation, mutation or collection.
pub fn isAbsent(header: *object.GcHeader, key: Value) bool {
    if (header.type != .table) return false;
    const t = table.Table.fromHeader(header);
    return t.metatable == null and t.get(key).isNil();
}

pub noinline fn absentInt(header: *object.GcHeader, key: i64) callconv(.c) u64 {
    return @intFromBool(isAbsent(header, Value.int(key)));
}

pub noinline fn absentString(header: *object.GcHeader, key: *object.GcHeader) callconv(.c) u64 {
    return @intFromBool(isAbsent(header, Value.heap(key)));
}
