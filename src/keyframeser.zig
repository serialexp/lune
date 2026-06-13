//! Keyframe snapshot serialization (Phase 7 v2 — F2a) — the bridge between a
//! live VM's reachable heap graph + roots and its on-disk snapshot form.
//!
//! Mirrors `traceser.zig`: the wire format is defined once, declaratively, in
//! `schema/trace.json` (binschema); `tools/regen-trace-schema.sh` generates the
//! Zig codec into `src/gen/trace_schema.zig` (vendored, committed). We never
//! hand-write encode/decode — this module only *maps* lune's runtime structs
//! onto the generated schema structs.
//!
//! A keyframe is "the whole VM state at a moment": a flat array of every
//! reachable heap object (keyed by its stable `GcHeader.id`, never an address)
//! plus the roots (the globals table, the live register window, the active frame
//! closures, and the open upvalues). Every inter-object edge is an id, so the
//! object graph is reproducible and address-independent — the property
//! deterministic replay rests on (docs/design/02, 04).
//!
//! Direction: this is the *producer* side (VM → bytes). Restoring a snapshot
//! back into a live VM (id→pointer rebind, re-interning, Proto/Native rebind,
//! stack + open-upvalue reconstruction) is deliberately out of scope for F2a —
//! it is the next increment, F2b (docs/design/04-snapshot-replay-schema.md).
//! `decode` therefore yields the generated schema structs, not lune types.

const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const interp = @import("interp.zig");

const Value = value.Value;
const GcHeader = object.GcHeader;
const Proto = bytecode.Proto;
const Vm = interp.Vm;

/// The generated binschema codec (structs + encode/decode). Generated from
/// `schema/trace.json`; shared with `traceser.zig` (one schema, two record
/// families).
pub const schema = @import("gen/trace_schema.zig");

/// Snapshot wire-format version, written into every `SnapshotFile`. Bumped
/// independently of `traceser.format_version` — a keyframe is a distinct record
/// family that shares the binschema *encoding*, not a fused artifact
/// (docs/design/04-snapshot-replay-schema.md "two artifacts, one substrate").
pub const snapshot_format_version: u32 = 1;

/// Map a live `Value` to its wire form. A `heap_ref` becomes a `HeapRef` holding
/// the referenced object's stable id — **never** a pointer. Scalars carry inline.
/// `tag` mirrors `value.Tag` (the same ordinals `traceser.toSchemaConst` uses).
pub fn toSchemaValue(v: Value) schema.SnapValue {
    return switch (v.tag) {
        .nil => .{ .tag = @intFromEnum(value.Tag.nil), .body = .{ .ConstNil = .{ .pad = 0 } } },
        .boolean => .{ .tag = @intFromEnum(value.Tag.boolean), .body = .{ .ConstBool = .{ .v = @intFromBool(v.asBool()) } } },
        .int => .{ .tag = @intFromEnum(value.Tag.int), .body = .{ .ConstInt = .{ .v = v.asInt() } } },
        .float => .{ .tag = @intFromEnum(value.Tag.float), .body = .{ .ConstFloat = .{ .v = v.asFloat() } } },
        .heap_ref => .{ .tag = @intFromEnum(value.Tag.heap_ref), .body = .{ .HeapRef = .{ .id = v.asHeap().id } } },
    };
}

/// Map one heap object to its `HeapObject` schema struct, switching on its type.
/// The per-type child set mirrors `gc.blacken` exactly, so the serialized edges
/// match the GC's own notion of reachability. Allocates mapped arrays from `a`
/// (a scratch arena); a `HeapString`/`HeapNative` borrows live bytes, so the
/// result is valid only while the source VM is alive (true during encode).
///
/// `typed_array`/`host` have no wire variant in F2a — a reachable one is a
/// serializer bug surfaced as `UnsupportedObject`, not a silent drop.
pub fn toSchemaHeapObject(a: std.mem.Allocator, h: *GcHeader) !schema.HeapObject {
    const Body = schema.BsUnion_HeapString_HeapTable_HeapClosure_HeapNative_HeapUpvalue;
    const body: Body = switch (h.type) {
        .string => .{ .HeapString = .{ .bytes = string.String.fromHeader(h).bytes() } },
        .table => blk: {
            const t = table.Table.fromHeader(h);
            const array = try a.alloc(schema.SnapValue, t.array.items.len);
            for (t.array.items, 0..) |v, i| array[i] = toSchemaValue(v);
            const entries = try a.alloc(schema.TableEntry, t.hash.count());
            var it = t.hash.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                entries[i] = .{ .key = toSchemaValue(e.key_ptr.*), .val = toSchemaValue(e.value_ptr.*) };
            }
            break :blk .{ .HeapTable = .{ .array = array, .entries = entries } };
        },
        .function => blk: {
            const cl = function.Closure.fromHeader(h);
            const upvalue_ids = try a.alloc(u32, cl.upvalues.len);
            for (cl.upvalues, 0..) |uv, i| upvalue_ids[i] = uv.header.id;
            break :blk .{ .HeapClosure = .{ .proto_id = cl.proto.id, .upvalue_ids = upvalue_ids } };
        },
        .upvalue => blk: {
            const u = function.Upvalue.fromHeader(h);
            // `ptr` aims at the cell's own `closed` field iff the cell is closed;
            // otherwise it points into a live stack slot. Either way `ptr.*` is the
            // current value (F2b uses `open_upvalues` to re-derive the open slot).
            const is_closed = u.ptr == &u.closed;
            break :blk .{ .HeapUpvalue = .{ .closed = @intFromBool(is_closed), .value = toSchemaValue(u.ptr.*) } };
        },
        .native => .{ .HeapNative = .{ .name = function.Native.fromHeader(h).name } },
        else => return error.UnsupportedObject, // typed_array / host: no F2a variant
    };
    return .{ .id = h.id, .obj_type = @intFromEnum(h.type), .body = body };
}

/// The reachable-set walk: a read-only mirror of `gc`'s mark phase that collects
/// every reachable header into an ordered list, **without** touching GC colour
/// state or freeing anything. Seeded from the VM's roots via
/// `Vm.forEachRootHeader` (the single root definition the collector also uses),
/// then drained, enumerating each object's children exactly as `gc.blacken` does.
/// All allocation is arena scratch; an OOM is stashed in `err` and surfaced after
/// the walk (the void root-callback can't return one).
const Walk = struct {
    a: std.mem.Allocator,
    /// Reachable objects in discovery order — the order they serialize in.
    order: std.ArrayListUnmanaged(*GcHeader) = .empty,
    /// Dedup set, keyed by stable id (an object is enqueued at most once).
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    err: ?std.mem.Allocator.Error = null,

    fn push(self: *Walk, h: *GcHeader) void {
        if (self.err != null) return;
        const gop = self.seen.getOrPut(self.a, h.id) catch |e| {
            self.err = e;
            return;
        };
        if (gop.found_existing) return;
        self.order.append(self.a, h) catch |e| {
            self.err = e;
        };
    }

    fn pushValue(self: *Walk, v: Value) void {
        if (v.isHeap()) self.push(v.asHeap());
    }

    /// Walk a prototype's constant pool (recursing nested protos) — the same
    /// heap constants `gc.markProtoConstants` keeps alive from a live closure.
    fn pushProtoConstants(self: *Walk, proto: *const Proto) void {
        for (proto.constants) |c| self.pushValue(c);
        for (proto.protos) |child| self.pushProtoConstants(child);
    }

    fn enumerateChildren(self: *Walk, h: *GcHeader) void {
        switch (h.type) {
            .string, .native => {},
            .table => {
                const t = table.Table.fromHeader(h);
                for (t.array.items) |v| self.pushValue(v);
                var it = t.hash.iterator();
                while (it.next()) |e| {
                    self.pushValue(e.key_ptr.*);
                    self.pushValue(e.value_ptr.*);
                }
            },
            .upvalue => self.pushValue(function.Upvalue.fromHeader(h).ptr.*),
            .function => {
                const cl = function.Closure.fromHeader(h);
                for (cl.upvalues) |uv| self.push(&uv.header);
                self.pushProtoConstants(cl.proto);
            },
            else => {},
        }
    }
};

/// Serialize the whole live VM to a keyframe snapshot (a versioned
/// `SnapshotFile`). The returned slice is owned by `gpa` (caller frees);
/// intermediate schema structs and the reachable-set scratch live in an arena
/// freed before return. The VM must be alive (the mapping borrows live string
/// bytes). For F2a this is taken at the *final* state after `vm.run` returns, so
/// the stack/frames/open-upvalues are empty — but globals and everything it
/// reaches (tables, closures, upvalues, natives, their strings) are captured.
pub fn encodeSnapshot(gpa: std.mem.Allocator, vm: *Vm) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Enumerate the reachable heap graph from the VM roots.
    var walk = Walk{ .a = a };
    vm.forEachRootHeader(&walk, Walk.push);
    var i: usize = 0;
    while (i < walk.order.items.len) : (i += 1) walk.enumerateChildren(walk.order.items[i]);
    if (walk.err) |e| return e;

    // 2. Map each object to its wire form.
    const objects = try a.alloc(schema.HeapObject, walk.order.items.len);
    for (walk.order.items, 0..) |h, idx| objects[idx] = try toSchemaHeapObject(a, h);

    // 3. Capture the roots verbatim (the live register window, active frames, and
    //    open upvalues — empty at final-state capture; load-bearing in F2b).
    const stack = try a.alloc(schema.SnapValue, vm.stack_top);
    for (vm.stack[0..vm.stack_top], 0..) |v, idx| stack[idx] = toSchemaValue(v);

    const frames = try a.alloc(schema.FrameRef, vm.depth);
    for (vm.frame_closures[0..vm.depth], 0..) |cl, idx| frames[idx] = .{ .closure_id = cl.header.id };

    const open = try a.alloc(schema.OpenUpvalueRef, vm.open_upvalues.items.len);
    for (vm.open_upvalues.items, 0..) |ou, idx| open[idx] = .{
        .stack_index = @intCast(ou.index),
        .upvalue_id = ou.cell.header.id,
    };

    const file: schema.SnapshotFile = .{
        .version = snapshot_format_version,
        .keyframe = .{
            .globals_id = vm.globals.header.id,
            .objects = objects,
            .stack = stack,
            .frames = frames,
            .open_upvalues = open,
        },
    };
    return file.encode(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const lune_parser = @import("parser.zig");
const lune_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

// Small SnapValue constructors for the hand-built corpus.
fn sNil() schema.SnapValue {
    return .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } };
}
fn sBool(b: bool) schema.SnapValue {
    return .{ .tag = 1, .body = .{ .ConstBool = .{ .v = @intFromBool(b) } } };
}
fn sInt(v: i64) schema.SnapValue {
    return .{ .tag = 2, .body = .{ .ConstInt = .{ .v = v } } };
}
fn sFloat(v: f64) schema.SnapValue {
    return .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = v } } };
}
fn sRef(id: u32) schema.SnapValue {
    return .{ .tag = 4, .body = .{ .HeapRef = .{ .id = id } } };
}
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
            .objects = &.{
                .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a\x00b\xff\xfe" } } },
                .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "" } } },
                .{ .id = 2, .obj_type = 1, .body = .{ .HeapTable = .{
                    .array = &.{ sInt(10), sFloat(2.5), sBool(true), sNil() },
                    // entries include a string key, an int key, and a self-ref (id 2).
                    .entries = &.{
                        .{ .key = sRef(0), .val = sRef(3) },
                        .{ .key = sInt(7), .val = sRef(2) },
                    },
                } } },
                .{ .id = 3, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 42, .upvalue_ids = &.{ 4, 5 } } } },
                .{ .id = 6, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 1, .upvalue_ids = &.{} } } },
                .{ .id = 4, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 1, .value = sInt(99) } } },
                .{ .id = 5, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 0, .value = sRef(2) } } },
                .{ .id = 7, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "print" } } },
            },
            .stack = &.{ sRef(2), sInt(-1) },
            .frames = &.{ .{ .closure_id = 3 }, .{ .closure_id = 6 } },
            .open_upvalues = &.{.{ .stack_index = 0, .upvalue_id = 5 }},
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
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
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
            try testing.expect(n_string >= 3); // "g","add","name","lune","print",...
        }
    };
    try withSnapshot(
        \\local function adder(x) return function(y) return x + y end end
        \\g = {}
        \\g.add = adder(10)
        \\g[1] = 100
        \\g[2] = 200
        \\g.name = "lune"
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
