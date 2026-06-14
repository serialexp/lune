//! Effect-log (de)serializer — the third record family of the time-travel
//! substrate (F2d), after the trace cache (`traceser`) and the keyframe
//! (`keyframeser`). An effect log is the ordered list of **nondeterministic
//! inputs** observed during a run (today: `clock()` results). Replay restores a
//! keyframe and feeds this log back in call order, so re-execution past an effect
//! is reproducible (docs/design/02-determinism.md, 04-snapshot-replay-schema.md).
//!
//! Like its siblings it maps the in-memory form (`interp.Effect`) to the generated
//! binschema structs (`schema.Effect` / `schema.EffectFile`) and back — never
//! hand-rolls bytes. It shares the schema's `SnapValue` for an effect result, but
//! only **non-heap** results round-trip: a standalone effect log carries no heap
//! graph, so a heap result (a string/table) has no id to resolve against. `clock`
//! returns an int, so this covers every effect that exists.

const std = @import("std");
const value = @import("value.zig");
const interp = @import("interp.zig");
const keyframeser = @import("keyframeser.zig");

const Value = value.Value;
const Effect = interp.Effect;
const EffectKind = interp.EffectKind;

/// The generated binschema codec, shared with `traceser`/`keyframeser` (one
/// schema, three record families).
pub const schema = @import("gen/trace_schema.zig");

/// Effect-log wire-format version, written into every `EffectFile`. Independent of
/// the trace and keyframe versions — a distinct record family sharing only the
/// binschema *encoding* (docs/design/04 "two artifacts, one substrate"; this is a
/// third). v1: a flat ordered list of `{kind, result}`, consumed in call order.
pub const effect_format_version: u32 = 1;

/// Errors from decoding an effect log back into in-memory `Effect`s.
pub const DecodeError = error{
    /// `EffectFile.version` != `effect_format_version`.
    UnsupportedVersion,
    /// `Effect.kind` is not a known `interp.EffectKind` ordinal.
    UnknownEffectKind,
    /// An effect result was a heap reference — unsupported in a standalone effect
    /// log (no heap graph to resolve the id against; only `clock`'s int exists).
    UnsupportedEffectResult,
    /// binschema decode failure (truncated / malformed bytes).
    Malformed,
    OutOfMemory,
};

/// Serialize an ordered effect log to bytes (binschema wire format). The result
/// is owned by the caller (`gpa.free`). `clock` results are ints, so this never
/// touches the heap.
pub fn encodeFile(gpa: std.mem.Allocator, effects: []const Effect) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const wire = try a.alloc(schema.Effect, effects.len);
    for (effects, 0..) |e, i| wire[i] = .{
        .kind = @intFromEnum(e.kind),
        .result = keyframeser.toSchemaValue(e.result),
    };

    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = wire };
    return file.encode(gpa);
}

/// Decode an effect log from bytes into an owned `[]Effect` (caller frees with
/// `gpa.free`). Validates the version and every effect kind; rejects a heap
/// result (unsupported in a standalone log).
pub fn decodeFile(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]Effect {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded structs consumed here (results copied out by value)
    const file = schema.EffectFile.decode(arena.allocator(), bytes) catch return error.Malformed;
    if (file.version != effect_format_version) return error.UnsupportedVersion;

    const out = try gpa.alloc(Effect, file.effects.len);
    errdefer gpa.free(out);
    for (file.effects, 0..) |we, i| {
        const kind = std.enums.fromInt(EffectKind, we.kind) orelse return error.UnknownEffectKind;
        out[i] = .{ .kind = kind, .result = try fromSchemaNonHeap(we.result) };
    }
    return out;
}

/// Map a `SnapValue` back to a `Value`, rejecting heap refs (a standalone effect
/// log has no idmap). Mirrors `keyframeser.fromSchemaValue` minus the heap case.
fn fromSchemaNonHeap(sv: schema.SnapValue) DecodeError!Value {
    return switch (sv.body) {
        .ConstNil => Value.nil(),
        .ConstBool => |b| Value.boolean(b.v != 0),
        .ConstInt => |x| Value.int(x.v),
        .ConstFloat => |x| Value.float(x.v),
        .HeapRef => error.UnsupportedEffectResult,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectLogRoundTrips(effects: []const Effect) !void {
    const gpa = testing.allocator;
    const bytes = try encodeFile(gpa, effects);
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, bytes);
    defer gpa.free(back);
    try testing.expectEqual(effects.len, back.len);
    for (effects, back) |want, got| {
        try testing.expectEqual(want.kind, got.kind);
        try testing.expect(want.result.eql(got.result));
    }
}

test "effect log round-trips byte/struct-exact (empty, single, multi; int + float)" {
    try expectLogRoundTrips(&.{}); // empty log
    try expectLogRoundTrips(&.{.{ .kind = .clock, .result = Value.int(1234567890) }});
    try expectLogRoundTrips(&.{
        .{ .kind = .clock, .result = Value.int(0) },
        .{ .kind = .clock, .result = Value.int(-42) },
        .{ .kind = .clock, .result = Value.float(2.5) },
        .{ .kind = .clock, .result = Value.int(9223372036854775807) },
    });
}

test "encode then decode reproduces the same bytes (stable)" {
    const gpa = testing.allocator;
    const log = [_]Effect{
        .{ .kind = .clock, .result = Value.int(100) },
        .{ .kind = .clock, .result = Value.int(200) },
    };
    const b0 = try encodeFile(gpa, &log);
    defer gpa.free(b0);
    const back = try decodeFile(gpa, b0);
    defer gpa.free(back);
    const b1 = try encodeFile(gpa, back);
    defer gpa.free(b1);
    try testing.expectEqualSlices(u8, b0, b1);
}

test "a wrong-version effect file is rejected" {
    const gpa = testing.allocator;
    const file: schema.EffectFile = .{ .version = effect_format_version + 1, .effects = &.{} };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedVersion, decodeFile(gpa, bytes));
}

test "an unknown effect kind is rejected" {
    const gpa = testing.allocator;
    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
        .{ .kind = 250, .result = keyframeser.toSchemaValue(Value.int(1)) },
    } };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnknownEffectKind, decodeFile(gpa, bytes));
}

test "a heap-ref effect result is rejected (no idmap in a standalone log)" {
    const gpa = testing.allocator;
    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
        .{ .kind = 0, .result = .{ .tag = 4, .body = .{ .HeapRef = .{ .id = 7 } } } },
    } };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedEffectResult, decodeFile(gpa, bytes));
}
