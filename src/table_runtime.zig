//! Shared non-collecting table helpers for both trace executors.
const table = @import("table.zig");
const object = @import("object.zig");
const Value = @import("value.zig").Value;

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
