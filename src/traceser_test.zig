//! Trace serialization integration and wire-contract tests.
const std = @import("std");
const ser = @import("traceser.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const TraceCode = trace_code.TraceCode;
const value = @import("value.zig");
const Value = value.Value;
const string = @import("string.zig");
const schema = ser.schema;
const format_version = ser.format_version;
const toSchemaConst = ser.toSchemaConst;
const toSchemaTrace = ser.toSchemaTrace;
const encodeFile = ser.encodeFile;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Vm = @import("interp.zig").Vm;
const mahina_parser = @import("parser.zig");
const mahina_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

fn encodeVmTraces(gpa: std.mem.Allocator, vm: *Vm) ![]u8 {
    return vm.trace.encodeTraceFile(gpa);
}

/// Compile + run `source` with tracing on, then hand the populated VM to `check`
/// (still alive, so trace string consts and protos are valid). Mirrors the
/// recipe in `bench.zig`.
fn withRecordedVm(source: [:0]const u8, check: *const fn (vm: *Vm) anyerror!void) !void {
    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    try check(&vm);
}

test "real recorded numeric loop round-trips struct-exact (incl. proto id)" {
    const Check = struct {
        fn run(vm: *Vm) anyerror!void {
            try testing.expect(vm.trace.registry.cache.items.len >= 1);
            const orig = &vm.trace.registry.cache.items[0].code;

            const bytes = try encodeVmTraces(testing.allocator, vm);
            defer testing.allocator.free(bytes);

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const file = try schema.TraceFile.decode(arena.allocator(), bytes);

            try testing.expectEqual(format_version, file.version);
            try testing.expectEqual(vm.trace.registry.cache.items.len, file.traces.len);
            const dec = file.traces[0];

            // Wire v5: the stable Trace.id rides the wire (exec logs join on it).
            try testing.expectEqual(vm.trace.registry.cache.items[0].id, dec.id);
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
            try testing.expect(vm.trace.registry.cache.items.len >= 1);

            const bytes = try encodeVmTraces(testing.allocator, vm);
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
                .id = std.math.maxInt(u32),
                .anchor_proto_id = 0xDEAD_BEEF,
                .anchor_pc = 0,
                .peeled = 1, // doc 39 wire v3: the semantic peel byte
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
                .id = 7,
                .anchor_proto_id = 1,
                .anchor_pc = 12345,
                .peeled = 0,
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
    try testing.expectEqual(std.math.maxInt(u32), t0.id);
    try testing.expectEqual(@as(u32, 7), got.traces[1].id);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), t0.anchor_proto_id);
    try testing.expectEqual(@as(u8, 1), t0.peeled); // doc 39 wire v3
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
    try testing.expectEqual(@as(u8, 0), t1.peeled);
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
    const IrOp = trace_ir.IrOp;
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
    try testing.expectEqual(@as(u8, 40), @intFromEnum(IrOp.guard_func));
    try testing.expectEqual(@as(u8, 41), @intFromEnum(IrOp.href));
    try testing.expectEqual(@as(u8, 42), @intFromEnum(IrOp.hload));
    try testing.expectEqual(@as(u8, 43), @intFromEnum(IrOp.hstore));
    try testing.expectEqual(@as(u8, 44), @intFromEnum(IrOp.guard_hash));
    try testing.expectEqual(@as(u8, 45), @intFromEnum(IrOp.guard_builtin));
    try testing.expectEqual(@as(u8, 46), @intFromEnum(IrOp.fsqrt));
    try testing.expectEqual(@as(u8, 47), @intFromEnum(IrOp.sar));
    // Flattened-grid cell access (doc 14, Phase 8), appended after `sar` so wire
    // ordinals 0..47 are undisturbed.
    try testing.expectEqual(@as(u8, 48), @intFromEnum(IrOp.garow));
    try testing.expectEqual(@as(u8, 49), @intFromEnum(IrOp.gcell));
    try testing.expectEqual(@as(u8, 50), @intFromEnum(IrOp.gload));
    try testing.expectEqual(@as(u8, 51), @intFromEnum(IrOp.gstore));
    try testing.expectEqual(@as(u8, 52), @intFromEnum(IrOp.guard_grid));
    try testing.expectEqual(@as(u8, 53), @intFromEnum(IrOp.guard_stride));
    try testing.expectEqual(@as(u8, 54), @intFromEnum(IrOp.guard_gcol));
    try testing.expectEqual(@as(u8, 55), @intFromEnum(IrOp.guard_gpresent));
    // Nested-loop trace linking (doc 15, Phase 2), appended after `guard_gpresent`
    // so wire ordinals 0..55 are undisturbed.
    try testing.expectEqual(@as(u8, 56), @intFromEnum(IrOp.link));
    // Builtin recording breadth (doc 23, arc A), appended after `link` so wire
    // ordinals 0..56 are undisturbed.
    try testing.expectEqual(@as(u8, 57), @intFromEnum(IrOp.alen));
    try testing.expectEqual(@as(u8, 58), @intFromEnum(IrOp.fsin));
    try testing.expectEqual(@as(u8, 59), @intFromEnum(IrOp.fcos));
    // Deterministic on-trace allocation (doc 24, arc B), appended after `fcos`
    // so wire ordinals 0..59 are undisturbed.
    try testing.expectEqual(@as(u8, 60), @intFromEnum(IrOp.tostr_int));
    try testing.expectEqual(@as(u8, 61), @intFromEnum(IrOp.tostr_num));
    try testing.expectEqual(@as(u8, 62), @intFromEnum(IrOp.slen));
    try testing.expectEqual(@as(u8, 63), @intFromEnum(IrOp.guard_string));
    try testing.expectEqual(@as(u8, 64), @intFromEnum(IrOp.guard_gc));
    try testing.expectEqual(@as(u8, 65), @intFromEnum(IrOp.ssub));
    try testing.expectEqual(@as(u8, 66), @intFromEnum(IrOp.srev));
    try testing.expectEqual(@as(u8, 67), @intFromEnum(IrOp.schar1));
    try testing.expectEqual(@as(u8, 68), @intFromEnum(IrOp.srep2));
    // Non-pattern string surface completion (doc 26), appended after `srep2`
    // so wire ordinals 0..68 are undisturbed.
    try testing.expectEqual(@as(u8, 69), @intFromEnum(IrOp.supper));
    try testing.expectEqual(@as(u8, 70), @intFromEnum(IrOp.slower));
    try testing.expectEqual(@as(u8, 71), @intFromEnum(IrOp.scp));
    // Doc 30: pattern-engine + str2num callouts, appended after `scp`.
    try testing.expectEqual(@as(u8, 72), @intFromEnum(IrOp.sfindp));
    try testing.expectEqual(@as(u8, 73), @intFromEnum(IrOp.smatch));
    try testing.expectEqual(@as(u8, 74), @intFromEnum(IrOp.sgmatch));
    try testing.expectEqual(@as(u8, 75), @intFromEnum(IrOp.scap_int));
    try testing.expectEqual(@as(u8, 76), @intFromEnum(IrOp.scap_str));
    try testing.expectEqual(@as(u8, 77), @intFromEnum(IrOp.str2num_i));
    try testing.expectEqual(@as(u8, 78), @intFromEnum(IrOp.str2num_f));
    try testing.expectEqual(@as(u8, 79), @intFromEnum(IrOp.sgm_setpos));
    try testing.expectEqual(@as(u8, 80), @intFromEnum(IrOp.guard_sid));
    // Doc 35: rounding builtins (float→int).
    try testing.expectEqual(@as(u8, 81), @intFromEnum(IrOp.ffloor));
    try testing.expectEqual(@as(u8, 82), @intFromEnum(IrOp.fceil));
    // Doc 43 P5: closed-upvalue-cell family, appended after `fceil`.
    try testing.expectEqual(@as(u8, 83), @intFromEnum(IrOp.uref));
    try testing.expectEqual(@as(u8, 84), @intFromEnum(IrOp.uload));
    try testing.expectEqual(@as(u8, 85), @intFromEnum(IrOp.ustore));
    // Doc 44 P0: the one-shot head-trace terminator.
    try testing.expectEqual(@as(u8, 86), @intFromEnum(IrOp.terminal));
    try testing.expectEqual(@as(u8, 87), @intFromEnum(IrOp.guard_absent));
    // Doc 45 D3: identity-bearing table effects (precise traces only).
    try testing.expectEqual(@as(u8, 88), @intFromEnum(IrOp.tnew));
    try testing.expectEqual(@as(u8, 89), @intFromEnum(IrOp.tset));
    // Doc 57: value-specialized primitive pins.
    try testing.expectEqual(@as(u8, 90), @intFromEnum(IrOp.guard_is_nil));
    try testing.expectEqual(@as(u8, 91), @intFromEnum(IrOp.guard_is_false));
    try testing.expectEqual(@as(u8, 92), @intFromEnum(IrOp.guard_is_true));
    // Doc 63 §5.1: host calls from precise traces.
    try testing.expectEqual(@as(u8, 93), @intFromEnum(IrOp.guard_native));
    try testing.expectEqual(@as(u8, 94), @intFromEnum(IrOp.call_host));
    try testing.expectEqual(@as(u8, 95), @intFromEnum(IrOp.guard_host_epoch));
    try testing.expectEqual(@as(u8, 96), @intFromEnum(IrOp.host_result));
    // Numeric-for step-direction guards (LuaJIT `rec_for_check`).
    try testing.expectEqual(@as(u8, 97), @intFromEnum(IrOp.guard_step_up));
    try testing.expectEqual(@as(u8, 98), @intFromEnum(IrOp.guard_step_down));
    try testing.expectEqual(@as(u8, 99), @intFromEnum(IrOp.guard_for_nov));
    // Exhaustiveness: if a member is added/removed, this count changes and forces
    // both this test and enums.ts to be revisited.
    try testing.expectEqual(@as(usize, 100), @typeInfo(IrOp).@"enum".field_names.len);

    const ObsType = trace_ir.ObsType;
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
    // 5: transient grid row handle (doc 14), appended so existing wire ordinals
    // 0..4 are undisturbed. Never serialized (inflates to a table first), but the
    // ordinal is pinned to keep value.Tag and enums.ts in lockstep.
    try testing.expectEqual(@as(u8, 5), @intFromEnum(Tag.row_view));
    try testing.expectEqual(@as(usize, 6), @typeInfo(Tag).@"enum".field_names.len);
}
