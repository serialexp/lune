//! Tests for `keyframeser.zig` — capture.
//!
//! Extracted verbatim from `keyframeser.zig`; bodies are unchanged.
//! Shared harness lives in `keyframeser_testutil.zig`.

const keyframeser = @import("keyframeser.zig");
const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const interp = @import("interp.zig");
const gc = @import("gc.zig");
const key_order = @import("key_order.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");
const trace = @import("trace.zig");
const Value = value.Value;
const GcHeader = object.GcHeader;
const Proto = bytecode.Proto;
const Vm = interp.Vm;
pub const schema = @import("gen/trace_schema.zig");
const testing = std.testing;
const mahina_parser = @import("parser.zig");
const mahina_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

const encodeSnapshot = keyframeser.encodeSnapshot;
const snapshot_format_version = keyframeser.snapshot_format_version;

const util = @import("keyframeser_testutil.zig");
const sBool = util.sBool;
const sFloat = util.sFloat;
const sInt = util.sInt;
const sNil = util.sNil;
const sRef = util.sRef;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn refId(v: schema.SnapValue) ?u32 {
    return if (v.tag == @intFromEnum(value.Tag.heap_ref)) v.body.HeapRef.id else null;
}

test "hand-built snapshot edge corpus round-trips byte-exact" {
    // Pure schema level (no VM): every HeapObject variant, every SnapValue kind,
    // a self-referential table (cycle), open vs closed upvalue, an empty and a
    // NUL/high-byte string, and non-empty roots (stack/frames/open_upvalues that
    // final-state capture never produces). Proves the generated codec covers the
    // full snapshot wire range.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const file: schema.SnapshotFile = .{
        .version = snapshot_format_version,
        .keyframe = .{
            .globals_id = 2,
            .string_metatable_id = 0,
            .next_obj_id = 8,
            .objects = &.{
                .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a\x00b\xff\xfe" } } },
                .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "" } } },
                .{
                    .id = 2,
                    .obj_type = 1,
                    .body = .{
                        .HeapTable = .{
                            .array = &.{ sInt(10), sFloat(2.5), sBool(true), sNil() },
                            // entries include a string key, an int key, and a self-ref (id 2).
                            .entries = &.{
                                .{ .key = sRef(0), .val = sRef(3) },
                                .{ .key = sInt(7), .val = sRef(2) },
                            },
                            .metatable_id = 0,
                        },
                    },
                },
                .{ .id = 3, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 42, .upvalue_ids = &.{ 4, 5 } } } },
                .{ .id = 6, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 1, .upvalue_ids = &.{} } } },
                .{ .id = 4, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 1, .value = sInt(99) } } },
                .{ .id = 5, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 0, .value = sRef(2) } } },
                .{ .id = 7, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "print" } } },
            },
            .stack = &.{ sRef(2), sInt(-1) },
            .frames = &.{
                .{ .closure_id = 3, .pc = 7, .base = 0, .ret_dest = 0, .ret_count = 0, .varargs_base = 0, .varargs_count = 0 },
                .{ .closure_id = 6, .pc = 2, .base = 5, .ret_dest = 1, .ret_count = 1, .varargs_base = 0, .varargs_count = 0 },
            },
            .open_upvalues = &.{.{ .stack_index = 0, .upvalue_id = 5 }},
            .loaded_chunks = &.{},
        },
    };

    const bytes = try file.encode(a);
    const got = try schema.SnapshotFile.decode(a, bytes);

    try testing.expectEqual(snapshot_format_version, got.version);
    const kf = got.keyframe;
    try testing.expectEqual(@as(u32, 2), kf.globals_id);
    try testing.expectEqual(@as(usize, 8), kf.objects.len);

    // String with NUL + high bytes, and the empty string.
    try testing.expectEqualStrings("a\x00b\xff\xfe", kf.objects[0].body.HeapString.bytes);
    try testing.expectEqualStrings("", kf.objects[1].body.HeapString.bytes);

    // Table: array spread + a self-referential entry.
    const tbl = kf.objects[2].body.HeapTable;
    try testing.expectEqual(@as(i64, 10), tbl.array[0].body.ConstInt.v);
    try testing.expectEqual(@as(f64, 2.5), tbl.array[1].body.ConstFloat.v);
    try testing.expectEqual(@as(u8, 1), tbl.array[2].body.ConstBool.v);
    try testing.expectEqual(@as(u8, 0), tbl.array[3].tag); // nil
    try testing.expectEqual(@as(u32, 0), tbl.entries[0].key.body.HeapRef.id);
    try testing.expectEqual(@as(u32, 2), tbl.entries[1].val.body.HeapRef.id); // self-ref

    // Closures: N and 0 upvalues.
    try testing.expectEqual(@as(u32, 42), kf.objects[3].body.HeapClosure.proto_id);
    try testing.expectEqualSlices(u32, &.{ 4, 5 }, kf.objects[3].body.HeapClosure.upvalue_ids);
    try testing.expectEqual(@as(usize, 0), kf.objects[4].body.HeapClosure.upvalue_ids.len);

    // Upvalues: closed (holds a value) and open (holds the slot's current value).
    try testing.expectEqual(@as(u8, 1), kf.objects[5].body.HeapUpvalue.closed);
    try testing.expectEqual(@as(i64, 99), kf.objects[5].body.HeapUpvalue.value.body.ConstInt.v);
    try testing.expectEqual(@as(u8, 0), kf.objects[6].body.HeapUpvalue.closed);
    try testing.expectEqual(@as(u32, 2), kf.objects[6].body.HeapUpvalue.value.body.HeapRef.id);

    // Native by name.
    try testing.expectEqualStrings("print", kf.objects[7].body.HeapNative.name);

    // Non-empty roots survive.
    try testing.expectEqual(@as(usize, 2), kf.stack.len);
    try testing.expectEqual(@as(u32, 2), kf.stack[0].body.HeapRef.id);
    try testing.expectEqual(@as(usize, 2), kf.frames.len);
    try testing.expectEqual(@as(u32, 6), kf.frames[1].closure_id);
    try testing.expectEqual(@as(u32, 2), kf.frames[1].pc);
    try testing.expectEqual(@as(u32, 5), kf.frames[1].base);
    try testing.expectEqual(@as(u16, 1), kf.frames[1].ret_dest);
    try testing.expectEqual(@as(u16, 1), kf.frames[1].ret_count);
    try testing.expectEqual(@as(usize, 1), kf.open_upvalues.len);
    try testing.expectEqual(@as(u32, 5), kf.open_upvalues[0].upvalue_id);
}

/// Compile + run `source` (no tracing), then snapshot the live VM and hand the
/// decoded `SnapshotFile` (+ id set) to `check`. The snapshot is taken at the
/// final state (after run returns), so the stack is empty but globals and the
/// graph it reaches are populated. Mirrors `traceser.withRecordedVm`.
fn withSnapshot(source: [:0]const u8, check: *const fn (file: schema.SnapshotFile) anyerror!void) !void {
    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const bytes = try encodeSnapshot(gpa, &vm);
    defer gpa.free(bytes);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const file = try schema.SnapshotFile.decode(arena.allocator(), bytes);
    try check(file);
}

test "VM-driven snapshot captures a complete, non-dangling heap graph" {
    const Check = struct {
        fn run(file: schema.SnapshotFile) anyerror!void {
            try testing.expectEqual(snapshot_format_version, file.version);
            const kf = file.keyframe;

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            // Build the id set; assert no duplicate ids.
            var ids = std.AutoHashMap(u32, void).init(a);
            for (kf.objects) |o| {
                const gop = try ids.getOrPut(o.id);
                try testing.expect(!gop.found_existing); // each id appears once
            }

            // The globals root must be present.
            try testing.expect(ids.contains(kf.globals_id));

            // Every outgoing edge (object bodies + the root windows) must resolve
            // to a present object — no dangling reference.
            var refs: std.ArrayList(u32) = .empty;
            for (kf.objects) |o| switch (o.body) {
                .HeapString, .HeapNative => {},
                .HeapTable => |t| {
                    for (t.array) |v| if (refId(v)) |id| try refs.append(a, id);
                    for (t.entries) |e| {
                        if (refId(e.key)) |id| try refs.append(a, id);
                        if (refId(e.val)) |id| try refs.append(a, id);
                    }
                },
                .HeapClosure => |c| for (c.upvalue_ids) |id| try refs.append(a, id),
                .HeapUpvalue => |u| if (refId(u.value)) |id| try refs.append(a, id),
            };
            for (kf.stack) |v| if (refId(v)) |id| try refs.append(a, id);
            for (refs.items) |id| try testing.expect(ids.contains(id));

            // Graph completeness: the program leaves a table, a closure with an
            // upvalue, a native, and strings reachable from globals.
            var n_table: usize = 0;
            var n_closure: usize = 0;
            var n_upvalue: usize = 0;
            var n_native: usize = 0;
            var n_string: usize = 0;
            for (kf.objects) |o| switch (o.body) {
                .HeapTable => n_table += 1,
                .HeapClosure => n_closure += 1,
                .HeapUpvalue => n_upvalue += 1,
                .HeapNative => n_native += 1,
                .HeapString => n_string += 1,
            };
            try testing.expect(n_table >= 2); // globals + g
            try testing.expect(n_closure >= 1); // g.add
            try testing.expect(n_upvalue >= 1); // captured x (closed)
            try testing.expect(n_native >= 1); // print
            try testing.expect(n_string >= 3); // "g","add","name","mahina","print",...
        }
    };
    try withSnapshot(
        \\local function adder(x) return function(y) return x + y end end
        \\g = {}
        \\g.add = adder(10)
        \\g[1] = 100
        \\g[2] = 200
        \\g.name = "mahina"
        \\g.self = g
    , Check.run);
}

test "snapshot wire enum ordinals (HeapObject.obj_type) are a pinned contract" {
    // HeapObject.obj_type is a raw u8 mirroring object.ObjectType; a consumer
    // (and a future viz TS decoder) maps it back by position. Pin the absolute
    // ordinals so reordering ObjectType fails here and forces the wire mapping to
    // be revisited in lockstep. See docs/design/04-snapshot-replay-schema.md.
    const ObjectType = object.ObjectType;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ObjectType.string));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ObjectType.table));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ObjectType.function));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ObjectType.native));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ObjectType.upvalue));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(ObjectType.typed_array));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(ObjectType.host));
}
