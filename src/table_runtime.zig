//! Shared non-collecting table helpers for both trace executors.
const table = @import("table.zig");
const object = @import("object.zig");
const Value = @import("value.zig").Value;
const Heap = @import("gc.zig").Heap;

/// C-ABI status for the Doc 45 D5 effect shims. An int enum (not a Zig error
/// union) so the future native executor can branch on a register value.
pub const Status = enum(u32) {
    ok = 0,
    out_of_memory = 1,
    /// Reserved for `tset` (metatable/type refusal); `tnew` never returns it.
    type_error = 2,
};

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
