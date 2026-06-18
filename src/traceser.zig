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
//! Direction: this is the *producer* side (VM → bytes). Decoding back into live
//! VM `Value`s / `*Proto`s (reload-into-VM) is deliberately out of scope — a
//! serialized anchor is a proto *id*, not a pointer, and the consumer (the
//! Phase 7 visualiser) reads the structural form, never rebinds a live pointer.
//! `decode` therefore yields the generated schema structs, not lune types.

const std = @import("std");
const trace = @import("trace.zig");
const value = @import("value.zig");
const string = @import("string.zig");

const Value = value.Value;

/// The generated binschema codec (structs + encode/decode). Generated from
/// `schema/trace.json`; see this file's module doc.
pub const schema = @import("gen/trace_schema.zig");

/// Wire-format version, written into every `TraceFile`. Bump on any
/// schema-incompatible change. The compat policy (visualiser reads only its own
/// VM commit's traces) lives in `docs/design/04-snapshot-replay-schema.md`.
///
/// v2 (Phase E0): loop-carried writebacks moved from a separate `exit_stores`
/// list into the instruction stream as slot-bound `phi` nodes; `exit_stores` and
/// the `SlotStore` type were dropped from the schema. A v1 trace's trailing
/// `exit_stores` bytes are wire-incompatible with the v2 layout.
pub const format_version: u32 = 2;

/// Map one trace constant. A `heap_ref` const is always a string — the only
/// heap value a trace constant can be (tables/closures are never compile-time
/// constants); anything else is a recorder bug, surfaced as `UnsupportedConst`.
/// The returned `ConstString` borrows the live string's bytes, so the value is
/// valid only while the source heap object is alive (true during encode).
pub fn toSchemaConst(v: Value) error{UnsupportedConst}!schema.ConstValue {
    return switch (v.tag) {
        .nil => .{ .tag = @intFromEnum(value.Tag.nil), .body = .{ .ConstNil = .{ .pad = 0 } } },
        .boolean => .{ .tag = @intFromEnum(value.Tag.boolean), .body = .{ .ConstBool = .{ .v = @intFromBool(v.asBool()) } } },
        .int => .{ .tag = @intFromEnum(value.Tag.int), .body = .{ .ConstInt = .{ .v = v.asInt() } } },
        .float => .{ .tag = @intFromEnum(value.Tag.float), .body = .{ .ConstFloat = .{ .v = v.asFloat() } } },
        .heap_ref => blk: {
            const hdr = v.asHeap();
            if (hdr.type != .string) return error.UnsupportedConst;
            break :blk .{
                .tag = @intFromEnum(value.Tag.heap_ref),
                .body = .{ .ConstString = .{ .v = string.String.fromHeader(hdr).bytes() } },
            };
        },
    };
}

/// Map a committed `trace.Trace` to its schema struct. Allocates the mapped
/// arrays from `a` (use a scratch arena; the result borrows from it and from the
/// trace's live string consts). The anchor is the proto's *id*, never its
/// pointer.
pub fn toSchemaTrace(a: std.mem.Allocator, t: *const trace.Trace) !schema.Trace {
    const instrs = try a.alloc(schema.IrInstr, t.instrs.len);
    for (t.instrs, 0..) |ins, i| instrs[i] = .{
        .op = @intFromEnum(ins.op),
        .a = ins.a,
        .b = ins.b,
        .aux = ins.aux,
        .ty = @intFromEnum(ins.ty),
        .snap = ins.snap,
    };

    const consts = try a.alloc(schema.ConstValue, t.consts.len);
    for (t.consts, 0..) |c, i| consts[i] = try toSchemaConst(c);

    return .{
        .anchor_proto_id = t.anchor.proto.id,
        .anchor_pc = t.anchor.pc,
        .instrs = instrs,
        .consts = consts,
        // `[]u16` coerces directly to the schema's `[]const u16` — no remap.
        .entry_slots = t.entry_slots,
    };
}

/// Serialize a whole trace cache to bytes (a versioned `TraceFile`). The
/// returned slice is owned by `gpa` (caller frees). Intermediate schema structs
/// live in a scratch arena freed before return.
pub fn encodeFile(gpa: std.mem.Allocator, traces: []const *trace.Trace) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const sch = try a.alloc(schema.Trace, traces.len);
    for (traces, 0..) |t, i| sch[i] = try toSchemaTrace(a, t);

    const file: schema.TraceFile = .{ .version = format_version, .traces = sch };
    return file.encode(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Vm = @import("interp.zig").Vm;
const lune_parser = @import("parser.zig");
const lune_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

/// Compile + run `source` with tracing on, then hand the populated VM to `check`
/// (still alive, so trace string consts and protos are valid). Mirrors the
/// recipe in `bench.zig`.
fn withRecordedVm(source: [:0]const u8, check: *const fn (vm: *Vm) anyerror!void) !void {
    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    try check(&vm);
}

test "real recorded numeric loop round-trips struct-exact (incl. proto id)" {
    const Check = struct {
        fn run(vm: *Vm) anyerror!void {
            try testing.expect(vm.trace.cache.items.len >= 1);
            const orig = vm.trace.cache.items[0];

            const bytes = try encodeFile(testing.allocator, vm.trace.cache.items);
            defer testing.allocator.free(bytes);

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const file = try schema.TraceFile.decode(arena.allocator(), bytes);

            try testing.expectEqual(format_version, file.version);
            try testing.expectEqual(vm.trace.cache.items.len, file.traces.len);
            const dec = file.traces[0];

            // Anchor: the in-memory pointer became a stable id.
            try testing.expectEqual(orig.anchor.proto.id, dec.anchor_proto_id);
            try testing.expectEqual(orig.anchor.pc, dec.anchor_pc);

            // Arrays: same lengths, byte-identical instruction fields.
            try testing.expectEqual(orig.instrs.len, dec.instrs.len);
            try testing.expectEqual(orig.consts.len, dec.consts.len);
            try testing.expectEqual(orig.entry_slots.len, dec.entry_slots.len);
            // Loop-carried writebacks are now slot-bound `phi` instrs in the stream,
            // so the instruction-field comparison below covers them too.
            for (orig.instrs, dec.instrs) |o, d| {
                try testing.expectEqual(@intFromEnum(o.op), d.op);
                try testing.expectEqual(o.a, d.a);
                try testing.expectEqual(o.b, d.b);
                try testing.expectEqual(o.aux, d.aux);
                try testing.expectEqual(@intFromEnum(o.ty), d.ty);
                try testing.expectEqual(o.snap, d.snap);
            }
            for (orig.entry_slots, dec.entry_slots) |o, d| try testing.expectEqual(o, d);
        }
    };
    try withRecordedVm(
        \\local n = 0
        \\for i = 1, 2000 do
        \\  n = n + i * 2
        \\end
        \\print(n)
    , Check.run);
}

test "real recorded trace with a string const round-trips the bytes" {
    const Check = struct {
        fn run(vm: *Vm) anyerror!void {
            try testing.expect(vm.trace.cache.items.len >= 1);

            const bytes = try encodeFile(testing.allocator, vm.trace.cache.items);
            defer testing.allocator.free(bytes);

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const file = try schema.TraceFile.decode(arena.allocator(), bytes);

            // The loop body stores a string literal into a loop-carried slot, so
            // a heap_ref (string) const survives into the trace. Find it.
            var found = false;
            for (file.traces) |t| {
                for (t.consts) |c| {
                    if (c.tag == @intFromEnum(value.Tag.heap_ref)) {
                        try testing.expectEqualStrings("spark", c.body.ConstString.v);
                        found = true;
                    }
                }
            }
            try testing.expect(found);
        }
    };
    try withRecordedVm(
        \\local s = ""
        \\for i = 1, 2000 do
        \\  s = "spark"
        \\end
        \\print(s)
    , Check.run);
}

test "hand-built schema edge corpus round-trips byte-exact" {
    // Drives value ranges a normal program won't reliably emit: extreme ints,
    // negative aux, every const variant, FP specials, a string with NUL + high
    // bytes, and a multi-trace file. Pure schema-level (no VM) — proves the
    // generated codec covers the full wire range.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nan_bits: u64 = 0x7ff8_0000_0000_0001; // a quiet NaN with payload
    const file: schema.TraceFile = .{
        .version = format_version,
        .traces = &.{
            .{
                .anchor_proto_id = 0xDEAD_BEEF,
                .anchor_pc = 0,
                .instrs = &.{
                    .{ .op = 0, .a = 0, .b = 0, .aux = std.math.minInt(i32), .ty = 0, .snap = 0 },
                    .{ .op = 1, .a = 65535, .b = 65535, .aux = std.math.maxInt(i32), .ty = 5, .snap = 4294967295 },
                    .{ .op = 250, .a = 1, .b = 2, .aux = -1, .ty = 3, .snap = 7 },
                    // a slot-bound φ (op 35) — the loop-carried writeback now rides the
                    // instr stream instead of a separate exit_stores array.
                    .{ .op = 35, .a = 0, .b = 1, .aux = 3, .ty = 1, .snap = 0 },
                },
                .consts = &.{
                    .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } },
                    .{ .tag = 1, .body = .{ .ConstBool = .{ .v = 1 } } },
                    .{ .tag = 2, .body = .{ .ConstInt = .{ .v = std.math.minInt(i64) } } },
                    .{ .tag = 2, .body = .{ .ConstInt = .{ .v = std.math.maxInt(i64) } } },
                    .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = -0.0 } } },
                    .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = std.math.inf(f64) } } },
                    .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = @bitCast(nan_bits) } } },
                    .{ .tag = 4, .body = .{ .ConstString = .{ .v = "a\x00b\xff\xfe" } } },
                    .{ .tag = 4, .body = .{ .ConstString = .{ .v = "" } } },
                },
                .entry_slots = &.{ 0, 1, 2, 3 },
            },
            .{
                .anchor_proto_id = 1,
                .anchor_pc = 12345,
                .instrs = &.{.{ .op = 99, .a = 0, .b = 0, .aux = 0, .ty = 0, .snap = 0 }},
                .consts = &.{},
                .entry_slots = &.{},
            },
        },
    };

    const bytes = try file.encode(a);
    const got = try schema.TraceFile.decode(a, bytes);

    try testing.expectEqual(file.version, got.version);
    try testing.expectEqual(@as(usize, 2), got.traces.len);

    const t0 = got.traces[0];
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), t0.anchor_proto_id);
    try testing.expectEqual(std.math.minInt(i32), t0.instrs[0].aux);
    try testing.expectEqual(std.math.maxInt(i32), t0.instrs[1].aux);
    try testing.expectEqual(@as(u32, 4294967295), t0.instrs[1].snap);
    try testing.expectEqual(@as(u8, 250), t0.instrs[2].op);
    try testing.expectEqual(std.math.minInt(i64), t0.consts[2].body.ConstInt.v);
    try testing.expectEqual(std.math.maxInt(i64), t0.consts[3].body.ConstInt.v);
    // -0.0 must survive with its sign bit.
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(t0.consts[4].body.ConstFloat.v)));
    try testing.expect(std.math.isPositiveInf(t0.consts[5].body.ConstFloat.v));
    try testing.expectEqual(nan_bits, @as(u64, @bitCast(t0.consts[6].body.ConstFloat.v)));
    try testing.expectEqualStrings("a\x00b\xff\xfe", t0.consts[7].body.ConstString.v);
    try testing.expectEqualStrings("", t0.consts[8].body.ConstString.v);
    try testing.expectEqual(@as(usize, 4), t0.entry_slots.len);
    // the slot-bound φ rode the instr stream (op 35, carries slot 3 via aux)
    try testing.expectEqual(@as(u8, 35), t0.instrs[3].op);
    try testing.expectEqual(@as(i32, 3), t0.instrs[3].aux);

    const t1 = got.traces[1];
    try testing.expectEqual(@as(u32, 12345), t1.anchor_pc);
    try testing.expectEqual(@as(u8, 99), t1.instrs[0].op);
    try testing.expectEqual(@as(usize, 0), t1.consts.len);
}

test "wire enum ordinals are a pinned contract (mirrored by viz/src/enums.ts)" {
    // The wire stores `op`, `ty`, and `tag` as raw u8 ordinals; the visualiser
    // (viz/src/enums.ts) maps them back to names by *position*. The round-trip
    // tests above only check ordinals survive encode→decode (relative), so they
    // would NOT catch a reordering of these enums — which would silently desync
    // the TS name tables. This test pins the absolute ordinals: reorder/insert an
    // enum member and this fails, signalling that viz/src/enums.ts must change in
    // lockstep. (If you add a member at the end, extend both this test and
    // enums.ts.) See docs/design/04-snapshot-replay-schema.md.
    const IrOp = trace.IrOp;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(IrOp.slot_load));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(IrOp.konst));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(IrOp.add));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(IrOp.sub));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(IrOp.mul));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(IrOp.div));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(IrOp.idiv));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(IrOp.mod));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(IrOp.pow));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(IrOp.band));
    try testing.expectEqual(@as(u8, 10), @intFromEnum(IrOp.bor));
    try testing.expectEqual(@as(u8, 11), @intFromEnum(IrOp.bxor));
    try testing.expectEqual(@as(u8, 12), @intFromEnum(IrOp.shl));
    try testing.expectEqual(@as(u8, 13), @intFromEnum(IrOp.shr));
    try testing.expectEqual(@as(u8, 14), @intFromEnum(IrOp.neg));
    try testing.expectEqual(@as(u8, 15), @intFromEnum(IrOp.not));
    try testing.expectEqual(@as(u8, 16), @intFromEnum(IrOp.bnot));
    try testing.expectEqual(@as(u8, 17), @intFromEnum(IrOp.eq));
    try testing.expectEqual(@as(u8, 18), @intFromEnum(IrOp.ne));
    try testing.expectEqual(@as(u8, 19), @intFromEnum(IrOp.lt));
    try testing.expectEqual(@as(u8, 20), @intFromEnum(IrOp.le));
    try testing.expectEqual(@as(u8, 21), @intFromEnum(IrOp.guard_int));
    try testing.expectEqual(@as(u8, 22), @intFromEnum(IrOp.guard_float));
    try testing.expectEqual(@as(u8, 23), @intFromEnum(IrOp.guard_number));
    try testing.expectEqual(@as(u8, 24), @intFromEnum(IrOp.guard_true));
    try testing.expectEqual(@as(u8, 25), @intFromEnum(IrOp.guard_false));
    try testing.expectEqual(@as(u8, 26), @intFromEnum(IrOp.aref));
    try testing.expectEqual(@as(u8, 27), @intFromEnum(IrOp.aload));
    try testing.expectEqual(@as(u8, 28), @intFromEnum(IrOp.astore));
    try testing.expectEqual(@as(u8, 29), @intFromEnum(IrOp.guard_table));
    try testing.expectEqual(@as(u8, 30), @intFromEnum(IrOp.guard_lane));
    try testing.expectEqual(@as(u8, 31), @intFromEnum(IrOp.guard_bounds));
    try testing.expectEqual(@as(u8, 32), @intFromEnum(IrOp.guard_present));
    try testing.expectEqual(@as(u8, 33), @intFromEnum(IrOp.guard_fits));
    try testing.expectEqual(@as(u8, 34), @intFromEnum(IrOp.loop));
    try testing.expectEqual(@as(u8, 35), @intFromEnum(IrOp.phi));
    try testing.expectEqual(@as(u8, 36), @intFromEnum(IrOp.preheader));
    try testing.expectEqual(@as(u8, 37), @intFromEnum(IrOp.int_of_float));
    try testing.expectEqual(@as(u8, 38), @intFromEnum(IrOp.guard_append));
    try testing.expectEqual(@as(u8, 39), @intFromEnum(IrOp.astore_append));
    // Exhaustiveness: if a member is added/removed, this count changes and forces
    // both this test and enums.ts to be revisited.
    try testing.expectEqual(@as(usize, 40), @typeInfo(IrOp).@"enum".field_names.len);

    const ObsType = trace.ObsType;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ObsType.unknown));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ObsType.int));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ObsType.float));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ObsType.boolean));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ObsType.nil));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(ObsType.heap));
    try testing.expectEqual(@as(usize, 6), @typeInfo(ObsType).@"enum".field_names.len);

    const Tag = value.Tag;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Tag.nil));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Tag.boolean));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Tag.int));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Tag.float));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Tag.heap_ref));
    try testing.expectEqual(@as(usize, 5), @typeInfo(Tag).@"enum".field_names.len);
}
