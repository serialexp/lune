//! Effect-log (de)serializer — the third record family of the time-travel
//! substrate (F2d), after the trace cache (`traceser`) and the keyframe
//! (`keyframeser`). An effect log is the ordered list of **nondeterministic
//! inputs** observed during a run. Replay restores a keyframe and feeds this log
//! back in call order, so re-execution past an effect is reproducible
//! (docs/design/02-determinism.md, 04-snapshot-replay-schema.md).
//!
//! Like its siblings it maps the in-memory form (`effectlog.EffectLog`) to the
//! generated binschema structs (`schema.Effect` / `schema.EffectFile`) and back —
//! never hand-rolls bytes. An effect result is a `schema.EffectResult`: a small
//! tag space of its own (NOT a `Value.Tag` mirror) carrying scalars, **inline
//! string bytes** (getenv/file_read), the inline bytes of a `b`-mode read, or a
//! failed host call's error class (doc 65 §4.2), never a heap ref. A standalone
//! effect log has no heap graph, so a string result is carried inline
//! (length-prefixed) and re-interned into the caller's heap on decode.

const std = @import("std");
const value = @import("value.zig");
const effectlog = @import("effectlog.zig");
const system = @import("system.zig");
const gc = @import("gc.zig");
const string = @import("string.zig");

const Value = value.Value;
const Effect = effectlog.Effect;
const EffectLog = effectlog.EffectLog;
const EffectKind = effectlog.EffectKind;

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
/// v6 (doc 65): the `io`/`os` kinds (ordinals 7–16) and two result variants,
/// `EffectBytes` (tag 5, a `b`-mode read) and `HostFail` (tag 6, an error
/// class); `argc`/`argv` (3, 4) are retired.
/// v7 (doc 65 Phase 4): kind 15 is `local_zone`, a byte record (offset,
/// daylight saving, abbreviation) where v6's `local_offset` was an int.
/// v8 (doc 73 §7.6): `aio_complete` (17) and `aio_result` (18).
/// v9 (doc 75 §4): `environ` (19), the environment as one byte record.
pub const effect_format_version: u32 = 9;

/// The encoded size of an `EffectFile` with no entries: the `version` word and
/// the entry count.
pub const file_header_size: usize = 4 + 4;

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
    /// (e.g. a `file_read`/`getenv` result that isn't nil-or-string, a `clock`
    /// result that isn't a number, or a failure class this binary does not know).
    /// A well-formed log this code wrote never trips this; it guards a corrupt or
    /// hand-edited log so replay rejects it cleanly here at the decode boundary
    /// instead of a downstream consumer unwrapping the wrong type and panicking
    /// (e.g. `loadfile`'s `strBytes(content).?`). The kind→result-type invariant
    /// every replay consumer relies on is established exactly once, here.
    MismatchedEffectResult,
    /// binschema decode failure (truncated / malformed bytes).
    Malformed,
    OutOfMemory,
};

/// What a given effect kind can ever log, so the decoder can reject a corrupt
/// log whose result contradicts its kind. Exhaustive over `EffectKind` so a
/// newly added kind forces a deliberate classification here.
const Shape = enum {
    /// An int: a seed, a packed version, seconds, a mode.
    int,
    /// A number: `os.clock`'s float seconds or `os.nsclock`'s int nanoseconds.
    number,
    /// A string, or `nil` (absent / could not be opened). The one with teeth: it
    /// lets a replay consumer do `strBytes(result).?` without a corrupt log
    /// turning into a panic.
    string_or_nil,
    /// An int (a handle id, a position), or a failure.
    int_or_fail,
    /// `nil` (success), or a failure.
    ok_or_fail,
    /// A string, or a failure.
    string_or_fail,
    /// What one `read` format returns: a string, a number, `nil` at EOF, the
    /// bytes of a `b`-mode read, or a failure.
    read_value,
    /// A local-zone record: bytes, at least the fixed part
    /// (`system.LocalZone.fixed_len`).
    zone,
    /// How an `aio` operation ended: `nil`, the bytes it read, or a failure.
    nil_bytes_or_fail,
    /// The environment record (`os.environ`): bytes, never a failure.
    environ,
};

fn resultShapeOf(kind: EffectKind) Shape {
    return switch (kind) {
        .random_seed, .unicode_version, .wall_clock, .io_error_mode, .aio_complete => .int,
        .local_zone => .zone,
        .clock => .number,
        .getenv, .file_read => .string_or_nil,
        .file_open, .file_seek => .int_or_fail,
        .file_write, .file_control, .fs_mutate => .ok_or_fail,
        .fs_tmpname => .string_or_fail,
        .file_read_op => .read_value,
        .aio_result => .nil_bytes_or_fail,
        .environ => .environ,
    };
}

/// Validate that `result` matches the shape `kind` can ever produce (see
/// `resultShapeOf`). Returns `MismatchedEffectResult` on a contradiction.
fn checkResultShape(kind: EffectKind, result: Effect.Result) DecodeError!void {
    const shape = resultShapeOf(kind);
    const ok = switch (result) {
        .fail => switch (shape) {
            .int_or_fail, .ok_or_fail, .string_or_fail, .read_value, .nil_bytes_or_fail => true,
            .int, .number, .string_or_nil, .zone, .environ => false,
        },
        .bytes => |span| shape == .read_value or shape == .nil_bytes_or_fail or shape == .environ or (shape == .zone and span.len >= system.local_zone_fixed_len),
        .value => |v| switch (shape) {
            .int, .int_or_fail => v.tag == .int,
            .number => v.tag == .int or v.tag == .float,
            .string_or_nil => v.tag == .nil or isString(v),
            .ok_or_fail, .nil_bytes_or_fail => v.tag == .nil,
            .string_or_fail => isString(v),
            .read_value => v.tag == .nil or v.tag == .int or v.tag == .float or isString(v),
            .zone, .environ => false,
        },
    };
    if (!ok) return error.MismatchedEffectResult;
}

fn isString(v: Value) bool {
    return v.isHeap() and v.heapType() == .string;
}

/// The encoded size of one entry with this result: the kind byte, the
/// result's tag byte, and its body. `Vm.logEffect` charges it against the
/// recording cap (doc 65 §4.5), so it must match what `encodeFile` writes
/// (pinned by a test below).
pub fn encodedEntrySize(result: Effect.Result) usize {
    const body: usize = switch (result) {
        .fail => 1,
        .bytes => |span| 4 + span.len,
        .value => |v| switch (v.tag) {
            .nil, .boolean => 1,
            .int, .float => 8,
            .heap_ref => 4 + (if (isString(v)) string.String.fromHeader(v.asHeap()).bytes().len else 0),
            .row_view => 0,
        },
    };
    return 1 + 1 + body;
}

/// Serialize an ordered effect log to bytes (binschema wire format). The result
/// is owned by the caller (`gpa.free`). String results (`getenv`/`file_read`)
/// are written inline; the borrowed bytes are valid only while the source VM is
/// alive (true during encode).
pub fn encodeFile(gpa: std.mem.Allocator, log: *const EffectLog) ![]u8 {
    return encodePrefix(gpa, log, log.len());
}

/// `encodeFile` for the first `n` entries only (a log cut at a keyframe).
pub fn encodePrefix(gpa: std.mem.Allocator, log: *const EffectLog, n: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const wire = try a.alloc(schema.Effect, n);
    for (log.entries.items[0..n], 0..) |e, i| wire[i] = .{
        .kind = @intFromEnum(e.kind),
        .result = try toWire(log, e.result),
    };

    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = wire };
    return file.encode(gpa);
}

/// Decode an effect log from bytes and append its entries to `log` (`gpa` is
/// the log's allocator). Validates the version, every effect kind, and every
/// result against its kind. A string result is re-interned into `heap` (so it
/// is a live heap string in the VM about to replay it); a `bytes` result is
/// copied into the log. On an error `log` is left as it was.
pub fn decodeInto(log: *EffectLog, gpa: std.mem.Allocator, heap: *gc.Heap, bytes: []const u8) DecodeError!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded structs consumed here (scalars by value; bytes copied)
    const file = schema.EffectFile.decode(arena.allocator(), bytes) catch return error.Malformed;
    if (file.version != effect_format_version) return error.UnsupportedVersion;

    const entries0 = log.entries.items.len;
    const bytes0 = log.bytes.items.len;
    errdefer {
        log.entries.shrinkRetainingCapacity(entries0);
        log.bytes.shrinkRetainingCapacity(bytes0);
    }
    try log.entries.ensureUnusedCapacity(gpa, file.effects.len);
    for (file.effects) |we| {
        const kind = std.enums.fromInt(EffectKind, we.kind) orelse return error.UnknownEffectKind;
        const result: Effect.Result = switch (we.result.body) {
            .ConstNil => .{ .value = Value.nil() },
            .ConstBool => |b| .{ .value = Value.boolean(b.v != 0) },
            .ConstInt => |x| .{ .value = Value.int(x.v) },
            .ConstFloat => |x| .{ .value = Value.float(x.v) },
            .ConstString => |str| .{ .value = try heap.internValue(str.v) },
            .EffectBytes => |b| blk: {
                const start = log.bytes.items.len;
                try log.bytes.appendSlice(gpa, b.v);
                break :blk .{ .bytes = .{ .start = start, .len = b.v.len } };
            },
            .HostFail => |f| .{ .fail = std.enums.fromInt(system.ErrorClass, f.class) orelse return error.MismatchedEffectResult },
        };
        // Establish the kind→result-type invariant once, here at the trust
        // boundary, so no replay consumer has to re-check (or panic on a corrupt log).
        try checkResultShape(kind, result);
        log.entries.appendAssumeCapacity(.{ .kind = kind, .result = result });
    }
}

/// Map a result to its wire `EffectResult`: scalars directly, a heap string
/// and a `bytes` result as inline bytes, a failure as its class. A non-string
/// heap value can never be an effect result, so it is a serializer-side bug.
fn toWire(log: *const EffectLog, result: Effect.Result) DecodeError!schema.EffectResult {
    return switch (result) {
        .fail => |class| .{ .tag = 6, .body = .{ .HostFail = .{ .class = @intFromEnum(class) } } },
        .bytes => |span| .{ .tag = 5, .body = .{ .EffectBytes = .{ .v = log.bytesOf(span) } } },
        .value => |v| switch (v.tag) {
            .nil => .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } },
            .boolean => .{ .tag = 1, .body = .{ .ConstBool = .{ .v = @intFromBool(v.asBool()) } } },
            .int => .{ .tag = 2, .body = .{ .ConstInt = .{ .v = v.asInt() } } },
            .float => .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = v.asFloat() } } },
            .heap_ref => if (isString(v))
                .{ .tag = 4, .body = .{ .ConstString = .{ .v = string.String.fromHeader(v.asHeap()).bytes() } } }
            else
                error.UnsupportedEffectResult,
            // A grid row handle is never an effect result; reaching here is a
            // serializer-side bug.
            .row_view => error.UnsupportedEffectResult,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test log over `testing.allocator`.
fn testLog(effects: []const Effect) !EffectLog {
    var log: EffectLog = .{};
    errdefer log.deinit(testing.allocator);
    try log.entries.appendSlice(testing.allocator, effects);
    return log;
}

/// Round-trip a log with no string results: encode, decode into a throwaway
/// heap, compare kind + result. (Strings need the same heap on both sides — see
/// the dedicated string test.)
fn expectLogRoundTrips(effects: []const Effect) !void {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var log = try testLog(effects);
    defer log.deinit(gpa);
    const bytes = try encodeFile(gpa, &log);
    defer gpa.free(bytes);
    var back: EffectLog = .{};
    defer back.deinit(gpa);
    try decodeInto(&back, gpa, &heap, bytes);
    try testing.expectEqual(effects.len, back.len());
    for (effects, back.entries.items) |want, got| {
        try testing.expectEqual(want.kind, got.kind);
        try testing.expect(std.meta.activeTag(want.result) == std.meta.activeTag(got.result));
        switch (want.result) {
            .value => |v| try testing.expect(v.eql(got.result.value)),
            .fail => |c| try testing.expectEqual(c, got.result.fail),
            .bytes => unreachable, // see the bytes test
        }
    }
}

test "effect log round-trips byte/struct-exact (empty, single, multi; int + float)" {
    try expectLogRoundTrips(&.{}); // empty log
    try expectLogRoundTrips(&.{Effect.of(.clock, Value.int(1234567890))});
    try expectLogRoundTrips(&.{
        Effect.of(.clock, Value.int(0)),
        Effect.of(.clock, Value.int(-42)),
        Effect.of(.clock, Value.float(2.5)),
        Effect.of(.clock, Value.int(9223372036854775807)),
    });
    // F2e: the random_seed ordinal carries a u64 seed as a (bit-cast) non-heap int,
    // so it round-trips through the int path. Exercise it here (including a seed
    // whose top bit is set, i.e. a negative i64 after cast).
    try expectLogRoundTrips(&.{
        Effect.of(.random_seed, Value.int(@bitCast(@as(u64, 0xC0FFEE)))),
        Effect.of(.random_seed, Value.int(@bitCast(@as(u64, 0xFFFF_FFFF_FFFF_FFFF)))),
    });
    // nil is a valid result (a getenv/file_read miss).
    try expectLogRoundTrips(&.{
        Effect.of(.getenv, Value.nil()),
        Effect.of(.file_read, Value.nil()),
    });
}

test "doc 65 host-operation results round-trip, failures as their class" {
    try expectLogRoundTrips(&.{
        Effect.of(.io_error_mode, Value.int(0)),
        Effect.of(.file_open, Value.int(3)),
        .{ .kind = .file_open, .result = .{ .fail = .not_found } },
        Effect.of(.file_read_op, Value.float(1.5)),
        Effect.of(.file_read_op, Value.nil()),
        .{ .kind = .file_read_op, .result = .{ .fail = .not_utf8 } },
        Effect.of(.file_write, Value.nil()),
        .{ .kind = .file_write, .result = .{ .fail = .other } },
        Effect.of(.file_seek, Value.int(4096)),
        Effect.of(.file_control, Value.nil()),
        .{ .kind = .fs_mutate, .result = .{ .fail = .permission_denied } },
        .{ .kind = .fs_tmpname, .result = .{ .fail = .exists } },
        Effect.of(.wall_clock, Value.int(1_790_000_000)),
        // Doc 73 §7.6: an `aio` completion is its id, then its outcome.
        Effect.of(.aio_complete, Value.int(7)),
        Effect.of(.aio_result, Value.nil()),
        Effect.of(.aio_complete, Value.int(2)),
        .{ .kind = .aio_result, .result = .{ .fail = .is_a_directory } },
    });
}

test "a local-zone record round-trips; a short one is refused" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var rec: [system.max_local_zone_len]u8 = undefined;
    const zone: system.LocalZone = .{ .offset = -7 * 3600, .dst = true, .abbr = "PDT" };
    var log: EffectLog = .{};
    defer log.deinit(gpa);
    try log.appendBytes(gpa, .local_zone, system.encodeLocalZone(zone, &rec));
    const bytes = try encodeFile(gpa, &log);
    defer gpa.free(bytes);
    var back: EffectLog = .{};
    defer back.deinit(gpa);
    try decodeInto(&back, gpa, &heap, bytes);
    const got = system.decodeLocalZone(back.bytesOf(back.entries.items[0].result.bytes));
    try testing.expectEqual(zone.offset, got.offset);
    try testing.expectEqual(zone.dst, got.dst);
    try testing.expectEqualStrings(zone.abbr, got.abbr);

    var short: EffectLog = .{};
    defer short.deinit(gpa);
    try short.appendBytes(gpa, .local_zone, "abc");
    const short_bytes = try encodeFile(gpa, &short);
    defer gpa.free(short_bytes);
    var refused: EffectLog = .{};
    defer refused.deinit(gpa);
    try testing.expectError(error.MismatchedEffectResult, decodeInto(&refused, gpa, &heap, short_bytes));
}

test "a bytes result round-trips into the decoding log's own buffer" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var log: EffectLog = .{};
    defer log.deinit(gpa);
    try log.appendBytes(gpa, .file_read_op, &.{ 0xff, 0, 0xfe });
    try log.append(gpa, Effect.of(.file_seek, Value.int(3)));
    try log.appendBytes(gpa, .file_read_op, "");
    const bytes = try encodeFile(gpa, &log);
    defer gpa.free(bytes);
    // Decode after an existing entry: spans are rebased onto the receiving log.
    var back: EffectLog = .{};
    defer back.deinit(gpa);
    try back.appendBytes(gpa, .file_read_op, "pre");
    try decodeInto(&back, gpa, &heap, bytes);
    try testing.expectEqual(@as(usize, 4), back.len());
    try testing.expectEqualSlices(u8, &.{ 0xff, 0, 0xfe }, back.bytesOf(back.entries.items[1].result.bytes));
    try testing.expectEqual(@as(i64, 3), back.entries.items[2].result.value.asInt());
    try testing.expectEqualSlices(u8, "", back.bytesOf(back.entries.items[3].result.bytes));
}

test "an environ record round-trips as bytes, is charged exactly, and cannot be a failure" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var log: EffectLog = .{};
    defer log.deinit(gpa);
    const rec = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 'A', 1, 0, 0, 0, 'x' };
    try log.appendBytes(gpa, .environ, &rec);
    const bytes = try encodeFile(gpa, &log);
    defer gpa.free(bytes);
    try testing.expectEqual(file_header_size + encodedEntrySize(log.entries.items[0].result), bytes.len);
    var back: EffectLog = .{};
    defer back.deinit(gpa);
    try decodeInto(&back, gpa, &heap, bytes);
    try testing.expectEqualSlices(u8, &rec, back.bytesOf(back.entries.items[0].result.bytes));

    var bad = try testLog(&.{.{ .kind = .environ, .result = .{ .fail = .other } }});
    defer bad.deinit(gpa);
    const bad_bytes = try encodeFile(gpa, &bad);
    defer gpa.free(bad_bytes);
    var sink: EffectLog = .{};
    defer sink.deinit(gpa);
    try testing.expectError(error.MismatchedEffectResult, decodeInto(&sink, gpa, &heap, bad_bytes));
}

test "a string effect result round-trips as inline bytes (getenv/file_read)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    // Intern the inputs into `heap`, encode, then decode back into the SAME heap:
    // identical bytes intern to the identical object, so `eql` (pointer identity)
    // holds — and an empty string is distinct from a nil result.
    var log = try testLog(&.{
        Effect.of(.getenv, try heap.internValue("/home/bart")),
        Effect.of(.file_read, try heap.internValue("alpha")),
        Effect.of(.getenv, try heap.internValue("")), // set-but-empty
        Effect.of(.getenv, Value.nil()), // unset
        Effect.of(.fs_tmpname, try heap.internValue("/tmp/lua_x")),
    });
    defer log.deinit(gpa);
    const bytes = try encodeFile(gpa, &log);
    defer gpa.free(bytes);
    var back: EffectLog = .{};
    defer back.deinit(gpa);
    try decodeInto(&back, gpa, &heap, bytes);
    try testing.expectEqual(log.len(), back.len());
    for (log.entries.items, back.entries.items) |want, got| {
        try testing.expectEqual(want.kind, got.kind);
        try testing.expect(want.result.value.eql(got.result.value));
    }
    // The empty-string result decoded to a (non-nil) heap string, not nil.
    try testing.expect(isString(back.entries.items[2].result.value));
    try testing.expect(back.entries.items[3].result.value.tag == .nil);
}

test "encode then decode reproduces the same bytes (stable)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var log = try testLog(&.{
        Effect.of(.clock, Value.int(100)),
        Effect.of(.getenv, try heap.internValue("X=1")),
        .{ .kind = .fs_mutate, .result = .{ .fail = .is_a_directory } },
    });
    defer log.deinit(gpa);
    try log.appendBytes(gpa, .file_read_op, "\x00\x01");
    const b0 = try encodeFile(gpa, &log);
    defer gpa.free(b0);
    var back: EffectLog = .{};
    defer back.deinit(gpa);
    try decodeInto(&back, gpa, &heap, b0);
    const b1 = try encodeFile(gpa, &back);
    defer gpa.free(b1);
    try testing.expectEqualSlices(u8, b0, b1);
}

test "encodedEntrySize matches what encodeFile writes, entry by entry" {
    // `Vm.logEffect` charges the recording cap with these sizes, so they must
    // add up to the real encoding exactly.
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    var log = try testLog(&.{
        Effect.of(.getenv, Value.nil()),
        Effect.of(.clock, Value.float(0.25)),
        Effect.of(.random_seed, Value.int(-1)),
        Effect.of(.getenv, try heap.internValue("päth")),
        .{ .kind = .file_open, .result = .{ .fail = .not_found } },
    });
    defer log.deinit(gpa);
    try log.appendBytes(gpa, .file_read_op, "abcdef");
    var want: usize = file_header_size;
    var n: usize = 0;
    while (n <= log.len()) : (n += 1) {
        const bytes = try encodePrefix(gpa, &log, n);
        defer gpa.free(bytes);
        try testing.expectEqual(want, bytes.len);
        if (n < log.len()) want += encodedEntrySize(log.entries.items[n].result);
    }
}

test "a decode error leaves the receiving log as it was" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
        .{ .kind = @intFromEnum(EffectKind.file_read_op), .result = .{ .tag = 5, .body = .{ .EffectBytes = .{ .v = "abc" } } } },
        .{ .kind = 250, .result = .{ .tag = 2, .body = .{ .ConstInt = .{ .v = 1 } } } },
    } };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    var log: EffectLog = .{};
    defer log.deinit(gpa);
    try log.append(gpa, Effect.of(.clock, Value.int(1)));
    try testing.expectError(error.UnknownEffectKind, decodeInto(&log, gpa, &heap, bytes));
    try testing.expectEqual(@as(usize, 1), log.len());
    try testing.expectEqual(@as(usize, 0), log.bytes.items.len);
}

test "a wrong-version effect file is rejected" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const file: schema.EffectFile = .{ .version = effect_format_version + 1, .effects = &.{} };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    var log: EffectLog = .{};
    defer log.deinit(gpa);
    try testing.expectError(error.UnsupportedVersion, decodeInto(&log, gpa, &heap, bytes));
}

test "an unknown effect kind is rejected" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    // 3 and 4 are the retired argc/argv.
    for ([_]u8{ 3, 4, 20, 250 }) |kind| {
        const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
            .{ .kind = kind, .result = .{ .tag = 2, .body = .{ .ConstInt = .{ .v = 1 } } } },
        } };
        const bytes = try file.encode(gpa);
        defer gpa.free(bytes);
        var log: EffectLog = .{};
        defer log.deinit(gpa);
        try testing.expectError(error.UnknownEffectKind, decodeInto(&log, gpa, &heap, bytes));
    }
}

test "a result whose type contradicts its kind is rejected at decode (corrupt log)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const Case = struct { kind: EffectKind, result: schema.EffectResult };
    const int1: schema.EffectResult = .{ .tag = 2, .body = .{ .ConstInt = .{ .v = 42 } } };
    const str: schema.EffectResult = .{ .tag = 4, .body = .{ .ConstString = .{ .v = "nope" } } };
    const flt: schema.EffectResult = .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = 1.0 } } };
    const nil: schema.EffectResult = .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } };
    const fail: schema.EffectResult = .{ .tag = 6, .body = .{ .HostFail = .{ .class = 1 } } };
    const bad_class: schema.EffectResult = .{ .tag = 6, .body = .{ .HostFail = .{ .class = 0 } } };
    const raw: schema.EffectResult = .{ .tag = 5, .body = .{ .EffectBytes = .{ .v = "x" } } };
    const cases = [_]Case{
        // file_read can only carry nil-or-string; an int would otherwise reach
        // `loadfile`'s `strBytes(content).?` and panic.
        .{ .kind = .file_read, .result = int1 },
        // The mirror image: a number kind (clock) carrying a string.
        .{ .kind = .clock, .result = str },
        // The seed is an int: `obtainRandomSeed` reads it with `asInt()`.
        .{ .kind = .random_seed, .result = flt },
        // A pre-doc-65 kind never fails.
        .{ .kind = .getenv, .result = fail },
        // Only a read returns bytes.
        .{ .kind = .file_write, .result = raw },
        .{ .kind = .file_write, .result = int1 },
        .{ .kind = .file_open, .result = nil },
        .{ .kind = .fs_tmpname, .result = nil },
        // Class 0 is no class.
        .{ .kind = .file_open, .result = bad_class },
        // An operation id is an int; an outcome is nil, bytes or a failure.
        .{ .kind = .aio_complete, .result = nil },
        .{ .kind = .aio_complete, .result = fail },
        .{ .kind = .aio_result, .result = int1 },
        .{ .kind = .aio_result, .result = str },
    };
    for (cases) |c| {
        const file: schema.EffectFile = .{ .version = effect_format_version, .effects = &.{
            .{ .kind = @intFromEnum(c.kind), .result = c.result },
        } };
        const bytes = try file.encode(gpa);
        defer gpa.free(bytes);
        var log: EffectLog = .{};
        defer log.deinit(gpa);
        try testing.expectError(error.MismatchedEffectResult, decodeInto(&log, gpa, &heap, bytes));
    }
}

test "a non-string heap effect result is a serializer-side error" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    // A table can never be an effect result; encoding one is a serializer bug.
    const t = try heap.newTable();
    var log = try testLog(&.{Effect.of(.getenv, Value.heap(&t.header))});
    defer log.deinit(gpa);
    try testing.expectError(error.UnsupportedEffectResult, encodeFile(gpa, &log));
}
