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
//! hand-rolling bytes. Each event's value reuses `EffectResult` (the same
//! scalar-or-inline-string union the effect log uses): trace values are scalars at
//! this phase (no heap/table IR ops — those abort tracing), so the self-contained
//! encoding fits and a string value (should one ever appear via a `konst`) is
//! carried inline and re-interned into the caller's heap on decode.

const std = @import("std");
const execlog = @import("execlog.zig");
const effectser = @import("effectser.zig");
const gc = @import("gc.zig");

const TraceExecLog = execlog.TraceExecLog;
const TraceEntry = execlog.TraceEntry;
const ExecEvent = execlog.ExecEvent;
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
    /// A non-string heap value reached the value encoder (a serializer bug — trace
    /// values are scalars). Propagated from `effectser.toEffectResult`.
    UnsupportedEffectResult,
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
                .value = try effectser.toEffectResult(ev.value),
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

/// Decode an execution log from bytes into an owned `[]TraceExecLog` (free each with
/// `.deinit(gpa)`, then `gpa.free` the slice — see `freeLogs`). Validates the version
/// and every enum ordinal. String event values are re-interned into `heap`.
pub fn decodeFile(gpa: std.mem.Allocator, heap: *gc.Heap, bytes: []const u8) DecodeError![]TraceExecLog {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded wire structs consumed here
    const file = schema.ExecLogFile.decode(arena.allocator(), bytes) catch return error.Malformed;
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
            for (we.events, 0..) |wev, vi| {
                const kind = std.enums.fromInt(ExecEventKind, wev.kind) orelse return error.UnknownEventKind;
                events[vi] = .{
                    .kind = kind,
                    .ref = wev.ref,
                    .value = effectser.fromEffectResult(heap, wev.value) catch return error.Malformed,
                };
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
const value = @import("value.zig");
const Value = value.Value;

/// Build a small two-entry log: a clean-ish entry with a guard exit ramp, plus a
/// capped entry — exercising every event kind, both exit kinds, and the cap flags.
fn sampleLogs(gpa: std.mem.Allocator) ![]TraceExecLog {
    const out = try gpa.alloc(TraceExecLog, 1);
    var log: TraceExecLog = .{ .trace_id = 0, .entries_capped = true };

    const ev0 = try gpa.dupe(ExecEvent, &.{
        .{ .kind = .value, .ref = 0, .value = Value.int(7) },
        .{ .kind = .guard_pass, .ref = 1, .value = Value.int(7) },
        .{ .kind = .value, .ref = 2, .value = Value.float(2.5) },
        .{ .kind = .commit },
        .{ .kind = .exit, .ref = 1, .value = Value.boolean(false) },
    });
    try log.entries.append(gpa, .{ .iterations = 42, .exit_ref = 1, .exit_kind = .guard, .capped = true, .events = ev0 });

    const ev1 = try gpa.dupe(ExecEvent, &.{
        .{ .kind = .value, .ref = 0, .value = Value.int(-1) },
        .{ .kind = .exit, .ref = 3, .value = Value.nil() },
    });
    try log.entries.append(gpa, .{ .iterations = 1, .exit_ref = 3, .exit_kind = .arith, .capped = false, .events = ev1 });

    out[0] = log;
    return out;
}

test "execution log round-trips struct-exact (events, exit ramps, caps)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();

    const logs = try sampleLogs(gpa);
    defer freeLogs(gpa, logs);

    const bytes = try encodeFile(gpa, logs);
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, &heap, bytes);
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
                try testing.expect(wev.value.eql(gev.value));
            }
        }
    }
}

test "an empty execution log round-trips" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const bytes = try encodeFile(gpa, &.{});
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, &heap, bytes);
    defer freeLogs(gpa, back);
    try testing.expectEqual(@as(usize, 0), back.len);
}

test "a wrong-version execution-log file is rejected" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const file: schema.ExecLogFile = .{ .version = exec_log_format_version + 1, .logs = &.{} };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedVersion, decodeFile(gpa, &heap, bytes));
}

test "an unknown event kind is rejected" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const file: schema.ExecLogFile = .{ .version = exec_log_format_version, .logs = &.{
        .{ .trace_id = 0, .entries_capped = 0, .entries = &.{
            .{ .iterations = 1, .exit_ref = 0, .exit_kind = 0, .capped = 0, .events = &.{
                .{ .kind = 250, .ref = 0, .value = .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } } },
            } },
        } },
    } };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnknownEventKind, decodeFile(gpa, &heap, bytes));
}
