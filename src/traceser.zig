//! Trace serialization (Phase 5b) — the bridge between an in-memory committed
//! `trace.Trace` and its on-disk wire form.
//!
//! The wire format is defined once, declaratively, in `schema/trace.json`
//! (binschema). `tools/regen-trace-schema.sh` generates the Zig encoder/decoder
//! from it into `src/gen/trace_schema.zig` (+ the `binschema` runtime under
//! `src/gen/binschema/`), which we vendor and commit. We never hand-write
//! encode/decode — this module only *maps* lune's runtime structs to/from the
//! generated schema structs.
//!
//! Increment A wires the generated code into the build and re-exports it. The
//! `Trace` ↔ schema mapping and round-trip tests land in Increment B.

const std = @import("std");

/// The generated binschema codec (structs + encode/decode). Generated from
/// `schema/trace.json`; see this file's module doc.
pub const schema = @import("gen/trace_schema.zig");

test "binschema wiring: a TraceFile round-trips through the vendored codec" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const file: schema.TraceFile = .{
        .version = 1,
        .traces = &.{
            .{
                .anchor_proto_id = 7,
                .anchor_pc = 42,
                .instrs = &.{
                    .{ .op = 1, .a = 0, .b = 0, .aux = -5, .ty = 2, .snap = 3 },
                },
                .consts = &.{
                    .{ .tag = 2, .body = .{ .ConstInt = .{ .v = -9223372036854775808 } } },
                    .{ .tag = 4, .body = .{ .ConstString = .{ .v = "hi" } } },
                },
                .entry_slots = &.{ 0, 4 },
                .exit_stores = &.{.{ .slot = 0, .ref = 0 }},
            },
        },
    };

    const bytes = try file.encode(a);
    const got = try schema.TraceFile.decode(a, bytes);

    try testing.expectEqual(@as(u32, 1), got.version);
    try testing.expectEqual(@as(usize, 1), got.traces.len);
    const t = got.traces[0];
    try testing.expectEqual(@as(u32, 7), t.anchor_proto_id);
    try testing.expectEqual(@as(u32, 42), t.anchor_pc);
    try testing.expectEqual(@as(i32, -5), t.instrs[0].aux);
    try testing.expectEqual(@as(i64, -9223372036854775808), t.consts[0].body.ConstInt.v);
    try testing.expectEqualStrings("hi", t.consts[1].body.ConstString.v);
    try testing.expectEqual(@as(usize, 2), t.entry_slots.len);
}
