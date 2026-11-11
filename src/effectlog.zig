//! The in-memory effect log (doc 02, doc 65 §4.2): the ordered list of
//! nondeterministic inputs a run observed. `record` appends, `replay` reads
//! front to back, and `effectser` maps it to and from the wire format.
//!
//! A result is a scalar or `nil`, a string's bytes, the bytes of a `b`-mode
//! read, or the error class of a failed host call. The log holds no heap
//! value (doc 86 §6.1): every byte lives in the log's own buffer, so one log
//! outlives the VMs that record and replay it and never roots an object.
//! A replay turns a string entry back into a value only when it consumes
//! it, interning it then, as the recording interned it when the host
//! produced it, so both runs allocate the same objects in the same order.
//! (Interning a whole log at decode would allocate its strings early.) A
//! byte array is mutable, so a `b`-mode read keeps its own copy too and a
//! replay builds a fresh array from it each time.

const std = @import("std");
const value = @import("value.zig");
const function = @import("function.zig");
const system = @import("system.zig");
const string = @import("string.zig");

const Value = value.Value;
pub const EffectKind = function.EffectKind;

/// A run of bytes in `EffectLog.bytes`.
pub const ByteSpan = struct { start: usize, len: usize };

/// One recorded nondeterministic input: the effect that produced it and what
/// it returned.
pub const Effect = struct {
    kind: EffectKind,
    result: Result,

    pub const Result = union(enum) {
        /// A scalar or `nil`, never a heap value.
        value: Value,
        /// A string result (`getenv`, `file_read`, a text read): its bytes,
        /// in `EffectLog.bytes`.
        string: ByteSpan,
        /// A `b`-mode read: the bytes, in `EffectLog.bytes`.
        bytes: ByteSpan,
        /// The host call failed (doc 65 §4.2). The message is rebuilt from
        /// the class and the program's own arguments, so only the class is
        /// logged.
        fail: system.ErrorClass,
    };

    /// A scalar result. A string goes through `EffectLog.appendValue`.
    pub fn of(kind: EffectKind, v: Value) Effect {
        std.debug.assert(!v.isHeap());
        return .{ .kind = kind, .result = .{ .value = v } };
    }
};

/// What a host operation hands the record/replay boundary, and what a replay
/// hands back: an entry's result with a string as a live heap string of the
/// VM at hand (`Vm.recordHost`, `Vm.replayHost`).
pub const HostResult = union(enum) {
    /// A scalar, `nil`, or a heap string.
    value: Value,
    /// A `b`-mode read: the bytes, in `EffectLog.bytes`.
    bytes: ByteSpan,
    fail: system.ErrorClass,
};

/// The encoded size of an effect file with no entries: the `version` word
/// and the entry count.
pub const file_header_size: usize = 4 + 4;

/// The encoded size of one entry with this result: the kind byte, the
/// result's tag byte, and its body. It must match what
/// `effectser.encodeFile` writes (pinned by a test there).
pub fn entrySize(result: Effect.Result) usize {
    const body: usize = switch (result) {
        .fail => 1,
        .bytes, .string => |span| 4 + span.len,
        .value => |v| switch (v.tag) {
            .nil, .boolean => 1,
            .int, .float => 8,
            // Never logged (`effectser.checkResultShape`), and
            // `effectser.toWire` refuses them.
            .heap_ref, .row_view => 0,
        },
    };
    return 1 + 1 + body;
}

/// The log: entries in call order, plus the bytes their `bytes` results
/// point into. A VM's own, or the debug session's that its VMs share
/// (`Vm.shareEffectLog`, doc 86 §6.1).
pub const EffectLog = struct {
    entries: std.ArrayList(Effect) = .empty,
    /// Every `bytes` result's content, back to back, in entry order.
    bytes: std.ArrayList(u8) = .empty,
    /// What `effectser.encodeFile` would write for the log: the header
    /// plus every appended entry's `entrySize`. The recording cap
    /// (`Vm.effect_log_limit`, doc 65 §4.5) is charged against it. It is the
    /// log's, not a VM's, so every VM recording into a shared log counts
    /// against the one total, and a keyframe need not carry it.
    encoded: usize = file_header_size,

    pub fn deinit(self: *EffectLog, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.bytes.deinit(gpa);
    }

    pub fn len(self: *const EffectLog) usize {
        return self.entries.items.len;
    }

    pub fn append(self: *EffectLog, gpa: std.mem.Allocator, e: Effect) std.mem.Allocator.Error!void {
        try self.entries.append(gpa, e);
        self.encoded += entrySize(e.result);
    }

    /// Append an entry whose result is `content` as bytes: the content is
    /// copied into the log.
    pub fn appendBytes(self: *EffectLog, gpa: std.mem.Allocator, kind: EffectKind, content: []const u8) std.mem.Allocator.Error!void {
        return self.appendSpan(gpa, kind, .bytes, content);
    }

    /// Append an entry whose result is the string `content`, copied into the
    /// log.
    pub fn appendString(self: *EffectLog, gpa: std.mem.Allocator, kind: EffectKind, content: []const u8) std.mem.Allocator.Error!void {
        return self.appendSpan(gpa, kind, .string, content);
    }

    /// Append a value result: a heap string as its bytes, a scalar as it is.
    /// No other heap value is ever an effect result.
    pub fn appendValue(self: *EffectLog, gpa: std.mem.Allocator, kind: EffectKind, v: Value) std.mem.Allocator.Error!void {
        if (v.isHeap()) return self.appendString(gpa, kind, string.String.fromHeader(v.asHeap()).bytes());
        return self.append(gpa, Effect.of(kind, v));
    }

    fn appendSpan(self: *EffectLog, gpa: std.mem.Allocator, kind: EffectKind, comptime tag: std.meta.Tag(Effect.Result), content: []const u8) std.mem.Allocator.Error!void {
        try self.entries.ensureUnusedCapacity(gpa, 1);
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(gpa, content);
        const result = @unionInit(Effect.Result, @tagName(tag), .{ .start = start, .len = content.len });
        self.entries.appendAssumeCapacity(.{ .kind = kind, .result = result });
        self.encoded += entrySize(result);
    }

    /// The content of a `string` or `bytes` result.
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
