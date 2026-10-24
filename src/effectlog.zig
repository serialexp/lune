//! The in-memory effect log (doc 02, doc 65 §4.2): the ordered list of
//! nondeterministic inputs a run observed. `record` appends, `replay` reads
//! front to back, and `effectser` maps it to and from the wire format.
//!
//! A result is a `Value` (a scalar, `nil`, or an interned heap string), the
//! bytes of a `b`-mode read, or the error class of a failed host call. The
//! bytes live in the log's own buffer, never in a VM byte array: a byte
//! array is mutable, so the log keeps its own copy and a replay builds a
//! fresh array from it each time.

const std = @import("std");
const value = @import("value.zig");
const function = @import("function.zig");
const system = @import("system.zig");

const Value = value.Value;
pub const EffectKind = function.EffectKind;

/// A run of bytes in `EffectLog.bytes`.
pub const ByteSpan = struct { start: usize, len: usize };

/// One recorded nondeterministic input: the effect that produced it and what
/// it returned. `result.value` may be a heap **string** (`getenv`,
/// `file_read`); such results are GC roots while parked in the log (see
/// `Vm.forEachRootHeader`) and serialize as inline bytes.
pub const Effect = struct {
    kind: EffectKind,
    result: Result,

    pub const Result = union(enum) {
        /// A scalar, `nil`, or an interned heap string.
        value: Value,
        /// A `b`-mode read: the bytes, in `EffectLog.bytes`.
        bytes: ByteSpan,
        /// The host call failed (doc 65 §4.2). The message is rebuilt from
        /// the class and the program's own arguments, so only the class is
        /// logged.
        fail: system.ErrorClass,
    };

    /// The common case: a `Value` result.
    pub fn of(kind: EffectKind, v: Value) Effect {
        return .{ .kind = kind, .result = .{ .value = v } };
    }
};

/// The log: entries in call order, plus the bytes their `bytes` results
/// point into. Owned by the VM (`Vm.effect_log`).
pub const EffectLog = struct {
    entries: std.ArrayList(Effect) = .empty,
    /// Every `bytes` result's content, back to back, in entry order.
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *EffectLog, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.bytes.deinit(gpa);
    }

    pub fn len(self: *const EffectLog) usize {
        return self.entries.items.len;
    }

    pub fn append(self: *EffectLog, gpa: std.mem.Allocator, e: Effect) std.mem.Allocator.Error!void {
        try self.entries.append(gpa, e);
    }

    /// Append an entry whose result is `content` as bytes: the content is
    /// copied into the log.
    pub fn appendBytes(self: *EffectLog, gpa: std.mem.Allocator, kind: EffectKind, content: []const u8) std.mem.Allocator.Error!void {
        try self.entries.ensureUnusedCapacity(gpa, 1);
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(gpa, content);
        self.entries.appendAssumeCapacity(.{ .kind = kind, .result = .{ .bytes = .{ .start = start, .len = content.len } } });
    }

    /// The content of a `bytes` result.
    pub fn bytesOf(self: *const EffectLog, span: ByteSpan) []const u8 {
        return self.bytes.items[span.start..][0..span.len];
    }
};

const testing = std.testing;

test "EffectLog keeps bytes results apart from the caller's buffer" {
    var log: EffectLog = .{};
    defer log.deinit(testing.allocator);
    var buf = [_]u8{ 0, 1, 2, 0xff };
    try log.append(testing.allocator, Effect.of(.clock, Value.int(7)));
    try log.appendBytes(testing.allocator, .file_read_op, &buf);
    try log.appendBytes(testing.allocator, .file_read_op, "xy");
    buf[0] = 9;
    try testing.expectEqual(@as(usize, 3), log.len());
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 0xff }, log.bytesOf(log.entries.items[1].result.bytes));
    try testing.expectEqualSlices(u8, "xy", log.bytesOf(log.entries.items[2].result.bytes));
}
