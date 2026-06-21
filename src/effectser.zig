//! Effect-log (de)serializer — the third record family of the time-travel
//! substrate (F2d), after the trace cache (`traceser`) and the keyframe
//! (`keyframeser`). An effect log is the ordered list of **nondeterministic
//! inputs** observed during a run (today: `clock()` results). Replay restores a
//! keyframe and feeds this log back in call order, so re-execution past an effect
//! is reproducible (docs/design/02-determinism.md, 04-snapshot-replay-schema.md).
//!
//! Like its siblings it maps the in-memory form (`interp.Effect`) to the generated
//! binschema structs (`schema.Effect` / `schema.EffectFile`) and back — never
//! hand-rolls bytes. An effect result is a `schema.EffectResult`: a small tag
//! space of its own (NOT a `Value.Tag` mirror) carrying scalars (clock/argc/
//! random_seed) plus **inline string bytes** (getenv/argv), never a heap ref. A
//! standalone effect log has no heap graph, so a string result is carried inline
//! (length-prefixed) and re-interned into the caller's heap on decode.

const std = @import("std");
const value = @import("value.zig");
const interp = @import("interp.zig");
const gc = @import("gc.zig");
const string = @import("string.zig");

const Value = value.Value;
const Effect = interp.Effect;
const EffectKind = interp.EffectKind;

/// The generated binschema codec, shared with `traceser`/`keyframeser` (one
/// schema, three record families).
pub const schema = @import("gen/trace_schema.zig");

/// Effect-log wire-format version, written into every `EffectFile`. Independent of
/// the trace and keyframe versions — a distinct record family sharing only the
/// binschema *encoding* (docs/design/04 "two artifacts, one substrate"; this is a
/// third). v2: results are `EffectResult` (scalars + inline string bytes), so the
/// log can carry `getenv`/`argv` string results (v1 was scalars only). v3 (L-3):
/// the `file_read` kind (ordinal 5) joins the kind space — no result-format change
/// (it reuses the inline-string `EffectResult` like `getenv`), but the expanded
/// valid-kind set gets its own version so a v2 reader rejects a v3 log explicitly.
/// v4 (S-C): the `unicode_version` kind (ordinal 6) joins — a scalar int (the
/// packed Unicode version), no result-format change, same explicit-rejection
/// rationale as v3.
/// v5: `clock`'s scalar result changed *units* — `os.clock` now records **float
/// seconds** (was integer nanoseconds; `os.nsclock` keeps the int). No wire-shape
/// change (`.clock` was already `scalar`, and the codec round-trips int+float), so
/// a v4 int-ns log would still *decode* cleanly but replay with wrong units. The
/// bump makes that incompatibility explicit (refuse, not silently diverge) — the
/// same fail-loud discipline as the unicode-version guard, not backward-compat.
pub const effect_format_version: u32 = 5;

/// Errors from encoding/decoding an effect log.
pub const DecodeError = error{
    /// `EffectFile.version` != `effect_format_version`.
    UnsupportedVersion,
    /// `Effect.kind` is not a known `interp.EffectKind` ordinal.
    UnknownEffectKind,
    /// An effect result was a heap value that isn't a string (a table/closure).
    /// Effects only ever return scalars or strings, so this is a serializer bug.
    UnsupportedEffectResult,
    /// A decoded effect's result type doesn't match what its kind can ever produce
    /// (e.g. a `file_read`/`getenv` result that isn't nil-or-string, or a `clock`/
    /// `argc`/`random_seed` result that isn't an int). A well-formed log this code
    /// wrote never trips this; it guards a corrupt or hand-edited log so replay
    /// rejects it cleanly here at the decode boundary instead of a downstream
    /// consumer unwrapping the wrong type and panicking (e.g. `loadfile`'s
    /// `strBytes(content).?`). The kind→result-type invariant every replay consumer
    /// relies on is established exactly once, here.
    MismatchedEffectResult,
    /// binschema decode failure (truncated / malformed bytes).
    Malformed,
    OutOfMemory,
};

/// The result-type a given effect kind can ever carry, so the decoder can reject a
/// corrupt log whose result type contradicts its kind. `scalar` covers the numeric
/// inputs (`clock` nanoseconds, `argc` count, `random_seed` bit-cast u64 — int in
/// practice, but the `EffectResult` codec also round-trips float, so the gate stays
/// at "a number", never nil/heap); `string_or_nil` covers the inline-string inputs
/// (`getenv`/`argv`/`file_read`, where nil = absent/unopenable). The string case is
/// the one with teeth: it is what lets a replay consumer do `strBytes(result).?`
/// without a corrupt log turning into a panic. Exhaustive over `EffectKind` so a
/// newly added kind forces a deliberate classification here.
fn resultShapeOf(kind: EffectKind) enum { scalar, string_or_nil } {
    return switch (kind) {
        .clock, .random_seed, .argc, .unicode_version => .scalar,
        .getenv, .argv, .file_read => .string_or_nil,
    };
}

/// Validate that `result` matches the shape `kind` can ever produce (see
/// `resultShapeOf`). Returns `MismatchedEffectResult` on a contradiction.
fn checkResultShape(kind: EffectKind, result: Value) DecodeError!void {
    const ok = switch (resultShapeOf(kind)) {
        .scalar => result.tag == .int or result.tag == .float,
        .string_or_nil => result.tag == .nil or (result.isHeap() and result.heapType() == .string),
    };
    if (!ok) return error.MismatchedEffectResult;
}

/// Serialize an ordered effect log to bytes (binschema wire format). The result
/// is owned by the caller (`gpa.free`). String results (`getenv`/`argv`) are
/// written inline; the borrowed bytes are valid only while the source VM is alive
/// (true during encode).
pub fn encodeFile(gpa: std.mem.Allocator, effects: []const Effect) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const wire = try a.alloc(schema.Effect, effects.len);
    for (effects, 0..) |e, i| wire[i] = .{
        .kind = @intFromEnum(e.kind),
        .result = try toEffectResult(e.result),
    };

    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = wire };
    return file.encode(gpa);
}

/// Decode an effect log from bytes into an owned `[]Effect` (caller frees with
/// `gpa.free`). Validates the version and every effect kind. A string result is
/// re-interned into `heap` (so the decoded `Value` is a live heap string in the
/// VM about to replay it); scalars are copied by value.
pub fn decodeFile(gpa: std.mem.Allocator, heap: *gc.Heap, bytes: []const u8) DecodeError![]Effect {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded structs consumed here (scalars by value; string bytes copied by intern)
    const file = schema.EffectFile.decode(arena.allocator(), bytes) catch return error.Malformed;
    if (file.version != effect_format_version) return error.UnsupportedVersion;

    const out = try gpa.alloc(Effect, file.effects.len);
    errdefer gpa.free(out);
    for (file.effects, 0..) |we, i| {
        const kind = std.enums.fromInt(EffectKind, we.kind) orelse return error.UnknownEffectKind;
        const result = try fromEffectResult(heap, we.result);
        // Establish the kind→result-type invariant once, here at the trust
        // boundary, so no replay consumer has to re-check (or panic on a corrupt log).
        try checkResultShape(kind, result);
        out[i] = .{ .kind = kind, .result = result };
    }
    return out;
}

/// Map a `Value` to its wire `EffectResult`: scalars directly, a heap string as
/// inline bytes. A non-string heap value can never be an effect result (effects
/// return scalars or strings), so it is a serializer-side bug. Shared with
/// `execlogser` (the trace-execution log reuses `EffectResult` for its scalar
/// trace values).
pub fn toEffectResult(v: Value) DecodeError!schema.EffectResult {
    return switch (v.tag) {
        .nil => .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } },
        .boolean => .{ .tag = 1, .body = .{ .ConstBool = .{ .v = @intFromBool(v.asBool()) } } },
        .int => .{ .tag = 2, .body = .{ .ConstInt = .{ .v = v.asInt() } } },
        .float => .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = v.asFloat() } } },
        .heap_ref => if (v.heapType() == .string)
            .{ .tag = 4, .body = .{ .ConstString = .{ .v = string.String.fromHeader(v.asHeap()).bytes() } } }
        else
            error.UnsupportedEffectResult,
    };
}

/// Inverse of `toEffectResult`: a scalar maps back directly; an inline string is
/// re-interned into `heap` (so the result is a live heap string the VM can feed
/// back to the program on replay). Shared with `execlogser`.
pub fn fromEffectResult(heap: *gc.Heap, er: schema.EffectResult) DecodeError!Value {
    return switch (er.body) {
        .ConstNil => Value.nil(),
        .ConstBool => |b| Value.boolean(b.v != 0),
        .ConstInt => |x| Value.int(x.v),
        .ConstFloat => |x| Value.float(x.v),
        .ConstString => |s| try heap.internValue(s.v),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Round-trip an all-scalar log: encode, decode into a throwaway heap, compare
/// kind + result. (Strings need the same heap on both sides — see the dedicated
/// string test — so this helper is for scalar effects.)
fn expectLogRoundTrips(effects: []const Effect) !void {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const bytes = try encodeFile(gpa, effects);
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, &heap, bytes);
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
    // F2e: the random_seed ordinal carries a u64 seed as a (bit-cast) non-heap int,
    // so it round-trips through the int path. Exercise it here (including a seed
    // whose top bit is set, i.e. a negative i64 after cast).
    try expectLogRoundTrips(&.{
        .{ .kind = .random_seed, .result = Value.int(@bitCast(@as(u64, 0xC0FFEE))) },
        .{ .kind = .random_seed, .result = Value.int(@bitCast(@as(u64, 0xFFFF_FFFF_FFFF_FFFF))) },
    });
    // argc is an int result like clock; nil is a valid result (getenv/argv miss).
    try expectLogRoundTrips(&.{
        .{ .kind = .argc, .result = Value.int(3) },
        .{ .kind = .getenv, .result = Value.nil() },
        .{ .kind = .argv, .result = Value.nil() },
    });
}

test "a string effect result round-trips as inline bytes (getenv/argv)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    // Intern the inputs into `heap`, encode, then decode back into the SAME heap:
    // identical bytes intern to the identical object, so `eql` (pointer identity)
    // holds — and an empty string is distinct from a nil result.
    const log = [_]Effect{
        .{ .kind = .getenv, .result = try heap.internValue("/home/bart") },
        .{ .kind = .argv, .result = try heap.internValue("alpha") },
        .{ .kind = .getenv, .result = try heap.internValue("") }, // set-but-empty
        .{ .kind = .getenv, .result = Value.nil() }, // unset
    };
    const bytes = try encodeFile(gpa, &log);
    defer gpa.free(bytes);
    const back = try decodeFile(gpa, &heap, bytes);
    defer gpa.free(back);
    try testing.expectEqual(log.len, back.len);
    for (log, back) |want, got| {
        try testing.expectEqual(want.kind, got.kind);
        try testing.expect(want.result.eql(got.result));
    }
    // The empty-string result decoded to a (non-nil) heap string, not nil.
    try testing.expect(back[2].result.isHeap() and back[2].result.heapType() == .string);
    try testing.expect(back[3].result.tag == .nil);
}

test "encode then decode reproduces the same bytes (stable)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const log = [_]Effect{
        .{ .kind = .clock, .result = Value.int(100) },
        .{ .kind = .getenv, .result = try heap.internValue("X=1") },
    };
    const b0 = try encodeFile(gpa, &log);
    defer gpa.free(b0);
    const back = try decodeFile(gpa, &heap, b0);
    defer gpa.free(back);
    const b1 = try encodeFile(gpa, back);
    defer gpa.free(b1);
    try testing.expectEqualSlices(u8, b0, b1);
}

test "a wrong-version effect file is rejected" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const file: schema.EffectFile = .{ .version = effect_format_version + 1, .effects = &.{} };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedVersion, decodeFile(gpa, &heap, bytes));
}

test "an unknown effect kind is rejected" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
        .{ .kind = 250, .result = .{ .tag = 2, .body = .{ .ConstInt = .{ .v = 1 } } } },
    } };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnknownEffectKind, decodeFile(gpa, &heap, bytes));
}

test "a result whose type contradicts its kind is rejected at decode (corrupt log)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    // file_read (ordinal 5) can only carry nil-or-string; an int result is a corrupt
    // log that would otherwise reach `loadfile`'s `strBytes(content).?` and panic.
    {
        const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
            .{ .kind = @intFromEnum(EffectKind.file_read), .result = .{ .tag = 2, .body = .{ .ConstInt = .{ .v = 42 } } } },
        } };
        const bytes = try file.encode(gpa);
        defer gpa.free(bytes);
        try testing.expectError(error.MismatchedEffectResult, decodeFile(gpa, &heap, bytes));
    }
    // The mirror image: a scalar kind (clock) carrying a string is equally corrupt.
    {
        const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
            .{ .kind = @intFromEnum(EffectKind.clock), .result = .{ .tag = 4, .body = .{ .ConstString = .{ .v = "nope" } } } },
        } };
        const bytes = try file.encode(gpa);
        defer gpa.free(bytes);
        try testing.expectError(error.MismatchedEffectResult, decodeFile(gpa, &heap, bytes));
    }
}

test "a non-string heap effect result is a serializer-side error" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    // A table can never be an effect result; encoding one is a serializer bug.
    const t = try heap.newTable();
    const log = [_]Effect{.{ .kind = .getenv, .result = Value.heap(&t.header) }};
    try testing.expectError(error.UnsupportedEffectResult, encodeFile(gpa, &log));
}
