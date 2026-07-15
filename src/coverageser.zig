//! JIT execution-coverage (de)serializer — the **fifth** record family of the
//! time-travel substrate, after the trace cache (`traceser`), the keyframe
//! (`keyframeser`), the effect log (`effectser`), and the trace execution log
//! (`execlogser`). A coverage artifact answers the diagnostic question Phase 1
//! surfaced on the CLI: of the code that ran, how much executed *as a trace*
//! (native/tier-1a) vs *fell back to tier-0* despite a trace existing — split by
//! both loop iterations and TSC time, plus the raw JIT event counters and a
//! per-anchor breakdown.
//!
//! Like its siblings it maps the in-memory form (`trace.TraceState` — the
//! aggregate counters + the per-anchor `coverage` map) to the generated binschema
//! structs and back, never hand-rolling bytes. It is the *producer* side
//! (VM → bytes); the consumer is the visualiser (Phase 3), which reads the
//! structural form (a proto *id*, never a live pointer). `decodeFile` therefore
//! yields the generated schema struct, not a live `TraceState` — an
//! *observation* artifact, nothing feeds it back (docs/design/04 "two artifacts,
//! one substrate", now five).
//!
//! `cycles_*`/`run_cycles` are 0 on a target without `rdtsc` (the wasm VM); the
//! visualiser then shows time as n/a and weighs by iterations only.

const std = @import("std");
const trace = @import("trace.zig");

/// The generated binschema codec, shared with the other record families.
pub const schema = @import("gen/trace_schema.zig");

/// Coverage wire-format version, written into every `CoverageFile`. Independent of
/// the trace/keyframe/effect/execlog versions — a distinct record family sharing
/// only the binschema *encoding*. v1: the initial format (iteration + TSC split,
/// event counters, per-anchor breakdown).
pub const coverage_format_version: u32 = 1;

/// Errors from decoding a coverage artifact.
pub const DecodeError = error{
    /// `CoverageFile.version` != `coverage_format_version`.
    UnsupportedVersion,
    /// binschema decode failure (truncated / malformed bytes).
    Malformed,
    OutOfMemory,
};

/// Map the always-live JIT event counters off a `TraceState`.
fn toSchemaCounters(ts: *const trace.TraceState) schema.JitCounters {
    return .{
        .entries = ts.entries,
        .native_link_arms = ts.native_link_arms,
        .native_source_link_arms = ts.native_source_link_arms,
        .native_loopdone_link_arms = ts.native_loopdone_link_arms,
        .native_source_link_fused = ts.native_source_link_fused,
        .native_loopdone_link_fused = ts.native_loopdone_link_fused,
        .native_link_disarms = ts.native_link_disarms,
        .native_link_exits = ts.native_link_exits,
        .native_link_follow_count = ts.native_link_follow_count,
        .link_ir_exits = ts.link_ir_exits,
        .link_follow_count = ts.link_follow_count,
        .prime_side_arms = ts.prime_side_arms,
        .prime_side_chain_follows = ts.prime_side_chain_follows,
        .tier0_outer_body_entries = ts.tier0_outer_body_entries,
    };
}

/// Serialize a `TraceState`'s coverage accounting to bytes (binschema wire
/// format). The result is owned by the caller (`gpa.free`). The per-anchor list is
/// sorted `(proto_id, pc)` so the artifact is reproducible (a hashmap has no stable
/// iteration order; Rule Z-3). Reads `ts` only — never mutates it.
pub fn encodeState(gpa: std.mem.Allocator, ts: *const trace.TraceState) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var anchors = try a.alloc(schema.CoverageAnchor, ts.coverage.count());
    var n: usize = 0;
    var it = ts.coverage.iterator();
    while (it.next()) |e| : (n += 1) {
        anchors[n] = .{
            .proto_id = e.key_ptr.proto.id,
            .pc = e.key_ptr.pc,
            .traced_iters = e.value_ptr.traced,
            .interp_iters = e.value_ptr.interp,
            .traced_cycles = e.value_ptr.traced_cycles,
            .interp_cycles = e.value_ptr.interp_cycles,
            .has_trace = @intFromBool(e.value_ptr.has_trace),
        };
    }
    std.mem.sort(schema.CoverageAnchor, anchors[0..n], {}, struct {
        fn lt(_: void, x: schema.CoverageAnchor, y: schema.CoverageAnchor) bool {
            if (x.proto_id != y.proto_id) return x.proto_id < y.proto_id;
            return x.pc < y.pc;
        }
    }.lt);

    const file: schema.CoverageFile = .{
        .version = coverage_format_version,
        .iters_traced = ts.iters_traced,
        .iters_tier0_covered = ts.iters_tier0_covered,
        .iters_tier0_uncovered = ts.iters_tier0_uncovered,
        .cycles_traced = ts.cycles_traced,
        .cycles_tier0_covered = ts.cycles_tier0_covered,
        .cycles_tier0_uncovered = ts.cycles_tier0_uncovered,
        .run_cycles = ts.run_cycles,
        .counters = toSchemaCounters(ts),
        .anchors = anchors[0..n],
    };
    return file.encode(gpa);
}

/// Decode a coverage artifact from bytes into the generated `schema.CoverageFile`
/// (its `anchors` slice is allocated with `gpa` — free with `freeFile`). Validates
/// the version. Yields the schema struct, not a live `TraceState`: coverage is an
/// observation artifact the consumer reads structurally, never rebinds into a VM.
pub fn decodeFile(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!schema.CoverageFile {
    const file = schema.CoverageFile.decode(gpa, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
    if (file.version != coverage_format_version) {
        gpa.free(file.anchors);
        return error.UnsupportedVersion;
    }
    return file;
}

/// Free a `schema.CoverageFile` decoded by `decodeFile` (its `gpa`-owned `anchors`).
pub fn freeFile(gpa: std.mem.Allocator, file: schema.CoverageFile) void {
    gpa.free(file.anchors);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const bytecode = @import("bytecode.zig");

/// Populate a `TraceState` with a couple of anchors and non-zero aggregates so the
/// round-trip exercises every field. `protos` supply the stable ids the anchors key
/// on; they must outlive the state's use.
fn seedState(ts: *trace.TraceState, gpa: std.mem.Allocator, pa: *const bytecode.Proto, pb: *const bytecode.Proto) !void {
    ts.iters_traced = 30_000_000;
    ts.iters_tier0_covered = 1_500;
    ts.iters_tier0_uncovered = 7;
    ts.cycles_traced = 2_000_000;
    ts.cycles_tier0_covered = 40_000_000;
    ts.cycles_tier0_uncovered = 500;
    ts.run_cycles = 45_000_000;
    ts.entries = 12;
    ts.native_link_arms = 3;
    ts.prime_side_chain_follows = 40_291;
    ts.tier0_outer_body_entries = 9;

    try ts.coverage.put(gpa, .{ .proto = pb, .pc = 24 }, .{
        .traced = 111, .interp = 0, .traced_cycles = 900, .interp_cycles = 10, .has_trace = true,
    });
    try ts.coverage.put(gpa, .{ .proto = pa, .pc = 14 }, .{
        .traced = 0, .interp = 222, .traced_cycles = 0, .interp_cycles = 5_000, .has_trace = true,
    });
    try ts.coverage.put(gpa, .{ .proto = pa, .pc = 3 }, .{
        .traced = 5, .interp = 6, .traced_cycles = 7, .interp_cycles = 8, .has_trace = false,
    });
}

test "coverage artifact round-trips struct-exact (aggregates, counters, per-anchor)" {
    const gpa = testing.allocator;
    var ts = trace.TraceState.init(gpa);
    defer ts.deinit();

    const pa = bytecode.Proto{ .code = &.{}, .name = "a", .num_registers = 1, .id = 2 };
    const pb = bytecode.Proto{ .code = &.{}, .name = "b", .num_registers = 1, .id = 5 };
    try seedState(&ts, gpa, &pa, &pb);

    const bytes = try encodeState(gpa, &ts);
    defer gpa.free(bytes);
    const file = try decodeFile(gpa, bytes);
    defer freeFile(gpa, file);

    try testing.expectEqual(coverage_format_version, file.version);
    try testing.expectEqual(ts.iters_traced, file.iters_traced);
    try testing.expectEqual(ts.iters_tier0_covered, file.iters_tier0_covered);
    try testing.expectEqual(ts.iters_tier0_uncovered, file.iters_tier0_uncovered);
    try testing.expectEqual(ts.cycles_traced, file.cycles_traced);
    try testing.expectEqual(ts.cycles_tier0_covered, file.cycles_tier0_covered);
    try testing.expectEqual(ts.cycles_tier0_uncovered, file.cycles_tier0_uncovered);
    try testing.expectEqual(ts.run_cycles, file.run_cycles);

    try testing.expectEqual(ts.entries, file.counters.entries);
    try testing.expectEqual(ts.native_link_arms, file.counters.native_link_arms);
    try testing.expectEqual(ts.prime_side_chain_follows, file.counters.prime_side_chain_follows);
    try testing.expectEqual(ts.tier0_outer_body_entries, file.counters.tier0_outer_body_entries);

    // Three anchors, sorted (proto_id, pc): (2,3), (2,14), (5,24).
    try testing.expectEqual(@as(usize, 3), file.anchors.len);
    try testing.expectEqual(@as(u32, 2), file.anchors[0].proto_id);
    try testing.expectEqual(@as(u32, 3), file.anchors[0].pc);
    try testing.expectEqual(@as(u32, 2), file.anchors[1].proto_id);
    try testing.expectEqual(@as(u32, 14), file.anchors[1].pc);
    try testing.expectEqual(@as(u32, 5), file.anchors[2].proto_id);
    try testing.expectEqual(@as(u32, 24), file.anchors[2].pc);

    // The smell anchor: has_trace but fully interpreted (a:14).
    try testing.expectEqual(@as(u64, 0), file.anchors[1].traced_iters);
    try testing.expectEqual(@as(u64, 222), file.anchors[1].interp_iters);
    try testing.expectEqual(@as(u8, 1), file.anchors[1].has_trace);
    // The fully-traced anchor (b:24).
    try testing.expectEqual(@as(u64, 111), file.anchors[2].traced_iters);
    try testing.expectEqual(@as(u64, 900), file.anchors[2].traced_cycles);
    // The no-trace anchor (a:3).
    try testing.expectEqual(@as(u8, 0), file.anchors[0].has_trace);
}

test "an empty coverage artifact round-trips" {
    const gpa = testing.allocator;
    var ts = trace.TraceState.init(gpa);
    defer ts.deinit();
    const bytes = try encodeState(gpa, &ts);
    defer gpa.free(bytes);
    const file = try decodeFile(gpa, bytes);
    defer freeFile(gpa, file);
    try testing.expectEqual(@as(usize, 0), file.anchors.len);
    try testing.expectEqual(@as(u64, 0), file.iters_traced);
}

test "a truncated anchor array is rejected without leaking the partial slice" {
    // Encode a real 3-anchor artifact, then lop bytes off the tail so the anchor
    // array's length prefix still says 3 but the buffer ends mid-third-anchor. The
    // generated decoder allocates the 3-slot slice, decodes the first two, then
    // faults on the truncated third — and must free the slice on that error path.
    // testing.allocator leak-checks, so a missing errdefer fails this test.
    const gpa = testing.allocator;
    var ts = trace.TraceState.init(gpa);
    defer ts.deinit();

    const pa = bytecode.Proto{ .code = &.{}, .name = "a", .num_registers = 1, .id = 2 };
    const pb = bytecode.Proto{ .code = &.{}, .name = "b", .num_registers = 1, .id = 5 };
    try seedState(&ts, gpa, &pa, &pb);

    const bytes = try encodeState(gpa, &ts);
    defer gpa.free(bytes);
    // Drop the last 5 bytes: enough to leave the final CoverageAnchor (41 bytes)
    // incomplete while keeping the length prefix and the first two anchors intact.
    try testing.expect(bytes.len > 5);
    const truncated = bytes[0 .. bytes.len - 5];
    try testing.expectError(error.Malformed, decodeFile(gpa, truncated));
}

test "a wrong-version coverage file is rejected" {
    const gpa = testing.allocator;
    const file: schema.CoverageFile = .{
        .version = coverage_format_version + 1,
        .iters_traced = 0,
        .iters_tier0_covered = 0,
        .iters_tier0_uncovered = 0,
        .cycles_traced = 0,
        .cycles_tier0_covered = 0,
        .cycles_tier0_uncovered = 0,
        .run_cycles = 0,
        .counters = std.mem.zeroes(schema.JitCounters),
        .anchors = &.{},
    };
    const bytes = try file.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedVersion, decodeFile(gpa, bytes));
}
