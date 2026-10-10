//! Trace execution-log (de)serializer — the **fourth** record family of the
//! time-travel substrate, after the trace cache (`traceser`), the keyframe
//! (`keyframeser`), and the effect log (`effectser`). An execution log is the
//! visualizer's record of how a cached trace actually *ran*: for every trace entry
//! (exit ramp) the per-iteration events (value / guard_pass / commit) and the
//! terminal side-exit (`execlog.zig`, docs/design/01-trace-lifecycle.md).
//!
//! Unlike the effect log it is an **observation** log, not a replay input — nothing
//! feeds it back. Like its siblings it maps the in-memory form
//! (`execlog.TraceExecLog`) to the generated binschema structs and back, never
//! hand-rolling bytes. Each event's value reuses the wire `EffectResult` (the same
//! scalar-or-inline-string union the effect log uses). The in-memory log already
//! owns detached string bytes (`execlog.LogValue`, doc 61 §7.1 item 7), so neither
//! direction touches a VM heap: encode borrows the log's bytes, decode copies them.

const std = @import("std");
const execlog = @import("execlog.zig");

const TraceExecLog = execlog.TraceExecLog;
const TraceEntry = execlog.TraceEntry;
const ExecEvent = execlog.ExecEvent;
const LogValue = execlog.LogValue;
const ExecEventKind = execlog.ExecEventKind;
const ExitKind = execlog.ExitKind;

/// The generated binschema codec, shared with the other record families.
pub const schema = @import("gen/trace_schema.zig");

/// Execution-log wire-format version, written into every `ExecLogFile`. Independent
/// of the trace/keyframe/effect versions — a distinct record family sharing only the
/// binschema *encoding* (docs/design/04 "two artifacts, one substrate"; this is the
/// fourth). v1: the initial format.
pub const exec_log_format_version: u32 = 1;

/// Errors from encoding/decoding an execution log.
pub const DecodeError = error{
    /// `ExecLogFile.version` != `exec_log_format_version`.
    UnsupportedVersion,
    /// An event `kind` / entry `exit_kind` ordinal is not a known enum value.
    UnknownEventKind,
    UnknownExitKind,
    /// binschema decode failure (truncated / malformed bytes).
    Malformed,
    OutOfMemory,
};

/// Serialize a slice of per-trace execution logs to bytes (binschema wire format).
/// The result is owned by the caller (`gpa.free`).
pub fn encodeFile(gpa: std.mem.Allocator, logs: []const TraceExecLog) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const wire_logs = try a.alloc(schema.TraceExecLog, logs.len);
    for (logs, 0..) |log, li| {
        const wire_entries = try a.alloc(schema.TraceEntry, log.entries.items.len);
        for (log.entries.items, 0..) |entry, ei| {
            const wire_events = try a.alloc(schema.ExecEvent, entry.events.len);
            for (entry.events, 0..) |ev, vi| wire_events[vi] = .{
                .kind = @intFromEnum(ev.kind),
                .ref = ev.ref,
                .value = toWire(ev.value),
            };
            wire_entries[ei] = .{
                .iterations = entry.iterations,
                .exit_ref = entry.exit_ref,
                .exit_kind = @intFromEnum(entry.exit_kind),
                .capped = @intFromBool(entry.capped),
                .events = wire_events,
            };
        }
        wire_logs[li] = .{
            .trace_id = log.trace_id,
            .entries_capped = @intFromBool(log.entries_capped),
            .entries = wire_entries,
        };
    }

    const file: schema.ExecLogFile = .{ .version = exec_log_format_version, .logs = wire_logs };
    return file.encode(gpa);
}

/// A log value on the wire: the `EffectResult` scalar-or-inline-string union. The
/// log already owns detached bytes (`execlog.LogValue`), so this cannot fail.
fn toWire(v: LogValue) schema.EffectResult {
    return switch (v) {
        .nil => .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } },
        .boolean => |b| .{ .tag = 1, .body = .{ .ConstBool = .{ .v = @intFromBool(b) } } },
        .int => |x| .{ .tag = 2, .body = .{ .ConstInt = .{ .v = x } } },
        .float => |x| .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = x } } },
        .string => |s| .{ .tag = 4, .body = .{ .ConstString = .{ .v = s } } },
    };
}

/// Inverse of `toWire`; a string's bytes are copied out of the (arena-backed)
/// decoded wire struct into `gpa`, owned by the returned value.
fn fromWire(gpa: std.mem.Allocator, er: schema.EffectResult) error{OutOfMemory}!LogValue {
    return switch (er.body) {
        .ConstNil => .nil,
        .ConstBool => |b| .{ .boolean = b.v != 0 },
        .ConstInt => |x| .{ .int = x.v },
        .ConstFloat => |x| .{ .float = x.v },
        .ConstString => |s| .{ .string = try gpa.dupe(u8, s.v) },
    };
}

/// Decode an execution log from bytes into an owned `[]TraceExecLog` (free each with
/// `.deinit(gpa)`, then `gpa.free` the slice — see `freeLogs`). Validates the version
/// and every enum ordinal. String event values are owned byte copies (no VM heap).
pub fn decodeFile(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]TraceExecLog {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded wire structs consumed here
    const file = schema.ExecLogFile.decode(arena.allocator(), bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
    if (file.version != exec_log_format_version) return error.UnsupportedVersion;

    const out = try gpa.alloc(TraceExecLog, file.logs.len);
    errdefer gpa.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |*l| l.deinit(gpa);

    for (file.logs, 0..) |wl, li| {
        var log: TraceExecLog = .{ .trace_id = wl.trace_id, .entries_capped = wl.entries_capped != 0 };
        errdefer log.deinit(gpa);
        for (wl.entries) |we| {
            const exit_kind = std.enums.fromInt(ExitKind, we.exit_kind) orelse return error.UnknownExitKind;
            const events = try gpa.alloc(ExecEvent, we.events.len);
            errdefer gpa.free(events);
            var filled: usize = 0;
            errdefer execlog.freeEventValues(gpa, events[0..filled]);
            for (we.events, 0..) |wev, vi| {
                const kind = std.enums.fromInt(ExecEventKind, wev.kind) orelse return error.UnknownEventKind;
                events[vi] = .{ .kind = kind, .ref = wev.ref, .value = try fromWire(gpa, wev.value) };
                filled += 1;
            }
            try log.entries.append(gpa, .{
                .iterations = we.iterations,
                .exit_ref = we.exit_ref,
                .exit_kind = exit_kind,
                .capped = we.capped != 0,
                .events = events,
            });
        }
        out[li] = log;
        built += 1;
    }
    return out;
}

/// Free a decoded `[]TraceExecLog` (each log's owned entries/events, then the slice).
pub fn freeLogs(gpa: std.mem.Allocator, logs: []TraceExecLog) void {
    for (logs) |*l| l.deinit(gpa);
    gpa.free(logs);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a small two-entry log: a clean-ish entry with a guard exit ramp, plus a
/// capped entry — exercising every event kind, every value kind (an owned string
/// included), both exit kinds, and the cap flags. `trace_id` is a stable
/// `Trace.id`, not a cache position.
fn sampleLogs(gpa: std.mem.Allocator) ![]TraceExecLog {
    const out = try gpa.alloc(TraceExecLog, 1);
    var log: TraceExecLog = .{ .trace_id = 9, .entries_capped = true };

    const ev0 = try gpa.dupe(ExecEvent, &.{
        .{ .kind = .value, .ref = 0, .value = .{ .int = 7 } },
        .{ .kind = .guard_pass, .ref = 1, .value = .{ .int = 7 } },
        .{ .kind = .value, .ref = 2, .value = .{ .float = 2.5 } },
        .{ .kind = .value, .ref = 4, .value = .{ .string = try gpa.dupe(u8, "a\x00b\xff") } },
        .{ .kind = .commit },
        .{ .kind = .exit, .ref = 1, .value = .{ .boolean = false } },
    });
    try log.entries.append(gpa, .{ .iterations = 42, .exit_ref = 1, .exit_kind = .guard, .capped = true, .events = ev0 });

    const ev1 = try gpa.dupe(ExecEvent, &.{
        .{ .kind = .value, .ref = 0, .value = .{ .int = -1 } },
        .{ .kind = .exit, .ref = 3, .value = .nil },
    });
    try log.entries.append(gpa, .{ .iterations = 1, .exit_ref = 3, .exit_kind = .arith, .capped = false, .events = ev1 });

    out[0] = log;
    return out;
}

test "execution log round-trips struct-exact (events, exit ramps, caps)" {
    const gpa = testing.allocator;

    const logs = try sampleLogs(gpa);
    defer freeLogs(gpa, logs);

    const bytes = try encodeFile(gpa, logs);
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, bytes);
    defer freeLogs(gpa, back);

    try testing.expectEqual(logs.len, back.len);
    for (logs, back) |want, got| {
        try testing.expectEqual(want.trace_id, got.trace_id);
        try testing.expectEqual(want.entries_capped, got.entries_capped);
        try testing.expectEqual(want.entries.items.len, got.entries.items.len);
        for (want.entries.items, got.entries.items) |we, ge| {
            try testing.expectEqual(we.iterations, ge.iterations);
            try testing.expectEqual(we.exit_ref, ge.exit_ref);
            try testing.expectEqual(we.exit_kind, ge.exit_kind);
            try testing.expectEqual(we.capped, ge.capped);
            try testing.expectEqual(we.events.len, ge.events.len);
            for (we.events, ge.events) |wev, gev| {
                try testing.expectEqual(wev.kind, gev.kind);
                try testing.expectEqual(wev.ref, gev.ref);
                switch (wev.value) {
                    // Decode copies the bytes: equal content, distinct ownership.
                    .string => |s| {
                        try testing.expectEqualStrings(s, gev.value.string);
                        try testing.expect(s.ptr != gev.value.string.ptr);
                    },
                    else => try testing.expectEqual(wev.value, gev.value),
                }
            }
        }
    }
}

fn decodeSample(gpa: std.mem.Allocator, bytes: []const u8) !void {
    freeLogs(gpa, try decodeFile(gpa, bytes));
}

test "every allocation failure while decoding an execution log unwinds with no leak" {
    const logs = try sampleLogs(testing.allocator);
    defer freeLogs(testing.allocator, logs);
    const bytes = try encodeFile(testing.allocator, logs);
    defer testing.allocator.free(bytes);
    try testing.checkAllAllocationFailures(testing.allocator, decodeSample, .{bytes});
}

test "an empty execution log round-trips" {
    const gpa = testing.allocator;
    const bytes = try encodeFile(gpa, &.{});
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, bytes);
    defer freeLogs(gpa, back);
    try testing.expectEqual(@as(usize, 0), back.len);
}

test "a wrong-version execution-log file is rejected" {
    const gpa = testing.allocator;
    const file: schema.ExecLogFile = .{ .version = exec_log_format_version + 1, .logs = &.{} };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedVersion, decodeFile(gpa, bytes));
}

test "an unknown event kind is rejected" {
    const gpa = testing.allocator;
    const file: schema.ExecLogFile = .{ .version = exec_log_format_version, .logs = &.{
        .{ .trace_id = 0, .entries_capped = 0, .entries = &.{
            .{ .iterations = 1, .exit_ref = 0, .exit_kind = 0, .capped = 0, .events = &.{
                .{ .kind = 250, .ref = 0, .value = .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } } },
            } },
        } },
    } };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnknownEventKind, decodeFile(gpa, bytes));
}
