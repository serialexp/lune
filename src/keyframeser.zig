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
/// v2 (F2c): `FrameRef` gained the per-frame execution cursor (pc/base/
/// return-wiring) for mid-execution capture + resume. (v1 was final-state only.)
pub const snapshot_format_version: u32 = 2;

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

/// A table hash-part (key, value) pair, used to serialize in a canonical order.
const HashKV = struct {
    key: Value,
    val: Value,
    fn lessThan(_: void, x: HashKV, y: HashKV) bool {
        return keyLessThan(x.key, y.key);
    }
};

/// A total order on *distinct* table keys, deterministic across runs. Heap keys
/// order by their stable object id (interning makes equal keys the same object);
/// non-heap keys (int/float/bool) order by tag then raw payload bits. Distinct
/// keys never tie, so this is a strict total order.
fn keyLessThan(a: Value, b: Value) bool {
    const ta = @intFromEnum(a.tag);
    const tb = @intFromEnum(b.tag);
    if (ta != tb) return ta < tb;
    if (a.isHeap()) return a.asHeap().id < b.asHeap().id;
    return a.payload.bits < b.payload.bits;
}

/// Collect a table's hash-part entries into `a`-owned scratch, sorted by
/// `keyLessThan`. Serializing the hash part in this **canonical** order (rather
/// than `std.HashMap`'s internal slot order) makes the snapshot byte layout a
/// function of the key *set* and their ids alone — never of insertion history.
/// This is what keeps capture→restore→recapture byte-identical: a restored table,
/// rebuilt by re-inserting entries one by one, can land collided keys in a
/// different probe slot than the original (so its raw iteration order differs),
/// but the canonical sort erases that difference. It also decouples the wire
/// format from `std.HashMap`'s implementation details across Zig versions.
fn sortedHashEntries(a: std.mem.Allocator, t: *const table.Table) ![]HashKV {
    const kvs = try a.alloc(HashKV, t.hash.count());
    var it = t.hash.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) kvs[i] = .{ .key = e.key_ptr.*, .val = e.value_ptr.* };
    std.mem.sort(HashKV, kvs, {}, HashKV.lessThan);
    return kvs;
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
            const kvs = try sortedHashEntries(a, t);
            const entries = try a.alloc(schema.TableEntry, kvs.len);
            for (kvs, 0..) |kv, i| {
                entries[i] = .{ .key = toSchemaValue(kv.key), .val = toSchemaValue(kv.val) };
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
                // Enumerate hash children in the same canonical key order the
                // serializer uses, so BFS object-discovery order (and thus the
                // `objects[]` array layout) is insertion-order-independent too.
                const kvs = sortedHashEntries(self.a, t) catch |e| {
                    self.err = e;
                    return;
                };
                for (kvs) |kv| {
                    self.pushValue(kv.key);
                    self.pushValue(kv.val);
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

    // Capture each frame's resumable cursor (pc/base/return-wiring), not just the
    // closure id — this is what makes a mid-execution snapshot re-executable (F2c).
    // At final-state capture `vm.depth == 0`, so this is empty and the bytes match
    // the v1 layout for those programs save the version word.
    const frames = try a.alloc(schema.FrameRef, vm.depth);
    for (vm.frames[0..vm.depth], 0..) |f, idx| frames[idx] = .{
        .closure_id = f.closure.header.id,
        .pc = @intCast(f.pc),
        .base = @intCast(f.base),
        .ret_dest = f.ret_dest,
        .ret_count = f.ret_count,
    };

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
// Restore (F2b) — rebuild a live VM from a decoded snapshot.
//
// The inverse of the encoder above. Restoring re-stamps each object with its
// ORIGINAL id (`gc.Heap.linkRestored`), because a table's hash-iteration order is
// keyed on `GcHeader.id` — preserving ids is what lets a restored VM re-serialize
// to the identical bytes. Reconstruction is two-pass: pass 1 creates every object
// shell and records id→header, pass 2 wires the inter-object edges (so cycles and
// forward references resolve). Roots (globals, stack, frames, open upvalues) are
// rebound last. The VM is heap-allocated and returned by pointer: open upvalue
// cells point at `&vm.stack[i]`, so the VM's address must stay fixed.
// ---------------------------------------------------------------------------

const RestoreError = error{
    UnsupportedVersion, // SnapshotFile.version != snapshot_format_version
    HeapNotEmpty, // restoring into a non-bare VM would collide ids/interning
    DuplicateId, // two HeapObjects share an id (corrupt snapshot)
    UnresolvedHeapRef, // a HeapRef / root id has no matching object
    UnknownProto, // a HeapClosure.proto_id is not in the program's proto tree
    UnknownNative, // a HeapNative.name is not in the native registry
    GlobalsNotATable, // globals_id resolves to a non-table object
    FrameNotAClosure, // a frame's closure_id resolves to a non-closure
    FrameWindowMismatch, // a frame's base != the running sum of prior register windows
    UpvalueNotAnUpvalue, // a closure/open-upvalue id resolves to a non-upvalue
    StackTooLarge, // the snapshot stack exceeds the VM's register window
    TooManyFrames, // the snapshot frame count exceeds max_call_depth
    StackIndexOutOfRange, // an open upvalue points past the live stack window
} || std.mem.Allocator.Error || SchemaDecodeError // + the codec's own decode errors
    || table.Table.Error; // a corrupt snapshot could carry a nil/NaN table key

/// The generated codec's `decode` error set, lifted straight from its signature
/// so `restore` (which decodes) can propagate a malformed-bytes failure without
/// re-listing binschema's internal error names (which it does not re-export).
const SchemaDecodeError = blk: {
    const ret = @typeInfo(@TypeOf(schema.SnapshotFile.decode)).@"fn".return_type.?;
    break :blk @typeInfo(ret).error_union.error_set;
};

/// Maps a snapshot's stable id to the freshly-restored object. Built in pass 1,
/// read in pass 2 + the root rebind.
const IdMap = std.AutoHashMap(u32, *GcHeader);

/// Resolves a serialized native (by name) back to its function. Backed by the
/// single `interp.base_natives` table, so install and restore share one truth.
pub const NativeRegistry = struct {
    entries: []const interp.BaseNative,

    /// The default registry — every built-in the VM installs at `init`.
    pub fn base() NativeRegistry {
        return .{ .entries = &interp.base_natives };
    }

    pub fn lookup(self: NativeRegistry, name: []const u8) ?interp.BaseNative {
        for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

/// Inverse of `toSchemaValue`: a scalar maps back directly; a `HeapRef` resolves
/// through the id map to a live `Value.heap`. Switching on the decoded union (not
/// the raw tag) keeps the value consistent with what the codec discriminated.
fn fromSchemaValue(sv: schema.SnapValue, idmap: *const IdMap) RestoreError!Value {
    return switch (sv.body) {
        .ConstNil => Value.nil(),
        .ConstBool => |b| Value.boolean(b.v != 0),
        .ConstInt => |x| Value.int(x.v),
        .ConstFloat => |x| Value.float(x.v),
        .HeapRef => |r| Value.heap(idmap.get(r.id) orelse return error.UnresolvedHeapRef),
    };
}

/// Resolve a `proto_id` by walking the program's prototype tree (pre-order, the
/// same order the compiler assigns ids). There is no runtime proto-by-id registry
/// — protos are arena-owned compile-time entities — so a closure rebinds against
/// the program image the snapshot was taken from.
fn findProto(root: *const Proto, id: u32) ?*const Proto {
    if (root.id == id) return root;
    for (root.protos) |child| if (findProto(child, id)) |p| return p;
    return null;
}

/// Decode `bytes` and restore them into a fresh VM (see `restoreSnapshot`).
pub fn restore(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    root: *const Proto,
    natives: NativeRegistry,
) RestoreError!*Vm {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded structs are consumed during restore (bytes copied)
    const snapshot = try schema.SnapshotFile.decode(arena.allocator(), bytes);
    return restoreSnapshot(gpa, snapshot, root, natives);
}

/// Rebuild a live VM from a decoded keyframe. `root` is the program's root
/// prototype (resolves `HeapClosure.proto_id`); `natives` rebinds serialized
/// natives by name. The returned VM is owned by the caller (`vm.deinit()` then
/// `gpa.destroy(vm)`); on any error nothing is leaked.
pub fn restoreSnapshot(
    gpa: std.mem.Allocator,
    snapshot: schema.SnapshotFile,
    root: *const Proto,
    natives: NativeRegistry,
) RestoreError!*Vm {
    if (snapshot.version != snapshot_format_version) return error.UnsupportedVersion;
    const kf = snapshot.keyframe;

    const vm = try gpa.create(Vm);
    errdefer gpa.destroy(vm);
    vm.* = try Vm.initBare(gpa);
    errdefer vm.deinit();

    // A bare VM is the contract: an empty heap means restored ids and interned
    // bytes cannot collide with pre-seeded state.
    if (vm.heap.object_count != 0 or vm.heap.next_obj_id != 0 or vm.heap.interned.count() != 0)
        return error.HeapNotEmpty;

    var idmap = IdMap.init(gpa);
    defer idmap.deinit();
    try idmap.ensureTotalCapacity(@intCast(kf.objects.len));

    // --- Pass 1: create every object shell, stamped with its original id. ---
    var max_id: u32 = 0;
    for (kf.objects) |o| {
        if (idmap.contains(o.id)) return error.DuplicateId;
        const header: *GcHeader = switch (o.body) {
            .HeapString => |hs| blk: {
                // Re-intern: allocate the bytes and register them so later program
                // interning of the same bytes resolves to this object, and sweep
                // can de-intern it. NOT `heap.intern` — that auto-links a counter id.
                const s = try string.String.create(gpa, hs.bytes);
                errdefer s.destroy(gpa);
                try vm.heap.interned.put(gpa, s.bytes(), s);
                vm.heap.linkRestored(&s.header, o.id);
                break :blk &s.header;
            },
            .HeapTable => blk: {
                const t = try table.Table.create(gpa);
                vm.heap.linkRestored(&t.header, o.id);
                break :blk &t.header;
            },
            .HeapClosure => |hc| blk: {
                const proto = findProto(root, hc.proto_id) orelse return error.UnknownProto;
                const cl = try function.Closure.create(gpa, proto, hc.upvalue_ids.len);
                vm.heap.linkRestored(&cl.header, o.id);
                break :blk &cl.header;
            },
            .HeapUpvalue => blk: {
                // Born closed-and-self-pointing so `ptr` is never dangling; pass 2
                // sets the value, and the root rebind repoints open cells at a slot.
                const u = try function.Upvalue.create(gpa, undefined);
                u.closed = Value.nil();
                u.ptr = &u.closed;
                vm.heap.linkRestored(&u.header, o.id);
                break :blk &u.header;
            },
            .HeapNative => |hn| blk: {
                const entry = natives.lookup(hn.name) orelse return error.UnknownNative;
                // Use the registry's static name (outlives the decode arena).
                const n = try function.Native.create(gpa, entry.func, entry.name);
                n.effect = entry.effect; // an effect native stays an effect on replay
                vm.heap.linkRestored(&n.header, o.id);
                break :blk &n.header;
            },
        };
        idmap.putAssumeCapacityNoClobber(o.id, header);
        max_id = @max(max_id, o.id);
    }
    // Future allocations must not reuse a restored id.
    vm.heap.adoptNextId(max_id +| 1);

    // --- Pass 2: wire inter-object edges (all shells now exist). ---
    for (kf.objects) |o| {
        const h = idmap.get(o.id).?;
        switch (o.body) {
            .HeapString, .HeapNative => {},
            .HeapTable => |ht| {
                const t = table.Table.fromHeader(h);
                // Array part: append in order (faithfully round-trips nil holes).
                for (ht.array) |sv| try t.array.append(gpa, try fromSchemaValue(sv, &idmap));
                // Hash part: straight into the hash, preserving the recorded split.
                for (ht.entries) |e| {
                    const k = try fromSchemaValue(e.key, &idmap);
                    const v = try fromSchemaValue(e.val, &idmap);
                    try t.restoreEntry(gpa, k, v);
                }
            },
            .HeapClosure => |hc| {
                const cl = function.Closure.fromHeader(h);
                for (hc.upvalue_ids, 0..) |uid, i| {
                    const uh = idmap.get(uid) orelse return error.UnresolvedHeapRef;
                    if (uh.type != .upvalue) return error.UpvalueNotAnUpvalue;
                    cl.upvalues[i] = function.Upvalue.fromHeader(uh);
                }
            },
            .HeapUpvalue => |hu| {
                const u = function.Upvalue.fromHeader(h);
                u.closed = try fromSchemaValue(hu.value, &idmap);
                u.ptr = &u.closed; // open cells are repointed in the root rebind
            },
        }
    }

    // --- Roots ---
    const gh = idmap.get(kf.globals_id) orelse return error.UnresolvedHeapRef;
    if (gh.type != .table) return error.GlobalsNotATable;
    vm.globals = table.Table.fromHeader(gh);

    if (kf.stack.len > vm.stack.len) return error.StackTooLarge;
    for (kf.stack, 0..) |sv, i| vm.stack[i] = try fromSchemaValue(sv, &idmap);
    vm.stack_top = kf.stack.len;

    if (kf.frames.len > vm.frames.len) return error.TooManyFrames;
    var expected_base: usize = 0;
    for (kf.frames, 0..) |fr, i| {
        const fh = idmap.get(fr.closure_id) orelse return error.UnresolvedHeapRef;
        if (fh.type != .function) return error.FrameNotAClosure;
        const cl = function.Closure.fromHeader(fh);
        // Frame windows stack contiguously from 0; a base that doesn't match the
        // running sum of prior frames' register counts is a corrupt/incompatible
        // snapshot (and would make resume read the wrong registers).
        if (fr.base != expected_base) return error.FrameWindowMismatch;
        vm.frames[i] = .{
            .closure = cl,
            .base = fr.base,
            .pc = fr.pc,
            .ret_dest = fr.ret_dest,
            .ret_count = fr.ret_count,
        };
        expected_base += cl.proto.num_registers;
    }
    vm.depth = @intCast(kf.frames.len);

    for (kf.open_upvalues) |ou| {
        const uh = idmap.get(ou.upvalue_id) orelse return error.UnresolvedHeapRef;
        if (uh.type != .upvalue) return error.UpvalueNotAnUpvalue;
        if (ou.stack_index >= vm.stack_top) return error.StackIndexOutOfRange;
        const cell = function.Upvalue.fromHeader(uh);
        // Repoint the open cell from its closed-self placeholder at the live slot.
        cell.ptr = &vm.stack[ou.stack_index];
        try vm.open_upvalues.append(gpa, .{ .index = ou.stack_index, .cell = cell });
    }

    return vm;
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
            .frames = &.{
                .{ .closure_id = 3, .pc = 7, .base = 0, .ret_dest = 0, .ret_count = 0 },
                .{ .closure_id = 6, .pc = 2, .base = 5, .ret_dest = 1, .ret_count = 1 },
            },
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

// ---------------------------------------------------------------------------
// Restore (F2b) tests
// ---------------------------------------------------------------------------

/// Compile + run `source`, snapshot the final VM (`b0`), restore into a fresh VM,
/// re-snapshot it (`b1`), and assert `b0 == b1` byte-for-byte — the headline
/// guarantee that restore is the exact inverse of capture. The chunk is kept
/// alive across the restore (restored closures borrow its `*const Proto`s).
/// Returns the decoded object count so callers can add structural assertions.
fn expectRoundTrip(source: [:0]const u8) !void {
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

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    const b1 = try encodeSnapshot(gpa, vm2);
    defer gpa.free(b1);

    try testing.expectEqualSlices(u8, b0, b1);
}

test "restore is the exact inverse of capture (byte-identical re-snapshot)" {
    // Each program leaves a different heap shape reachable from globals:
    // closures+upvalues, nested + string-keyed tables, a self-referential cycle,
    // multiple globals. A correct id-preserving restore must reproduce every one
    // byte-for-byte.
    try expectRoundTrip(
        \\local function adder(x) return function(y) return x + y end end
        \\g = {}
        \\g.add = adder(10)
        \\g[1] = 100
        \\g[2] = 200
        \\g.name = "lune"
        \\g.self = g
    );
    try expectRoundTrip(
        \\config = { width = 640, height = 480, name = "lune" }
        \\alpha = "a"; beta = "b"; gamma = "g"
    );
    try expectRoundTrip(
        \\local t = {}
        \\for i = 1, 8 do t[i] = i * i end
        \\t.tag = "squares"
        \\result = t
    );
    try expectRoundTrip(
        \\local function counter()
        \\  local n = 0
        \\  return function() n = n + 1; return n end
        \\end
        \\c = counter()
        \\first = c()
    );
    // The stdlib module tables (`string`, `io`) and `tonumber` are now in every
    // VM's globals as real heap tables/natives. Round-tripping a program that
    // references them confirms the module-table natives restore by their
    // qualified names without `UnknownNative`, and that the larger globals table
    // (which exposed the hash-layout fragility above) re-snapshots byte-identically.
    try expectRoundTrip(
        \\local s = string.format("%d-%s", 7, "x")
        \\result = { s = s, n = tonumber("42") }
    );
}

test "restore rebuilds globals, ids, and a reachable value graph" {
    const gpa = testing.allocator;
    const source =
        \\local function adder(x) return function(y) return x + y end end
        \\g = {}
        \\g.add = adder(10)
        \\g.name = "lune"
        \\g.self = g
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    // Decode the original to learn the object count + globals id for assertions.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try schema.SnapshotFile.decode(arena.allocator(), b0);
    var max_id: u32 = 0;
    for (decoded.keyframe.objects) |o| max_id = @max(max_id, o.id);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // Id space is reproduced exactly; the counter is parked past the max.
    try testing.expectEqual(@as(usize, decoded.keyframe.objects.len), vm2.heap.object_count);
    try testing.expectEqual(max_id + 1, vm2.heap.next_obj_id);
    try testing.expectEqual(decoded.keyframe.globals_id, vm2.globals.header.id);

    // Walk globals → g → name == "lune"; interning an already-present key resolves
    // to the restored object (no new allocation).
    const g_val = vm2.globals.get(try vm2.heap.internValue("g"));
    try testing.expect(g_val.isHeap() and g_val.heapType() == .table);
    const g_tbl = table.Table.fromHeader(g_val.asHeap());

    const name_val = g_tbl.get(try vm2.heap.internValue("name"));
    try testing.expect(name_val.isHeap() and name_val.heapType() == .string);
    try testing.expectEqualStrings("lune", string.String.fromHeader(name_val.asHeap()).bytes());

    // g.self is the same restored table object (cycle preserved).
    const self_val = g_tbl.get(try vm2.heap.internValue("self"));
    try testing.expect(self_val.isHeap() and self_val.asHeap() == &g_tbl.header);

    // g.add is a closure whose captured upvalue holds 10.
    const add_val = g_tbl.get(try vm2.heap.internValue("add"));
    try testing.expect(add_val.isHeap() and add_val.heapType() == .function);
    const add_cl = function.Closure.fromHeader(add_val.asHeap());
    try testing.expectEqual(@as(usize, 1), add_cl.upvalues.len);
    try testing.expectEqual(@as(i64, 10), add_cl.upvalues[0].get().asInt());

    // print is still a native bound under its name.
    const print_val = vm2.globals.get(try vm2.heap.internValue("print"));
    try testing.expect(print_val.isHeap() and print_val.heapType() == .native);
    try testing.expectEqualStrings("print", function.Native.fromHeader(print_val.asHeap()).name);
}

test "restore the hand-built edge corpus (cycles, open+closed upvalues, frames)" {
    const gpa = testing.allocator;

    // A stub proto tree carrying the ids the corpus closures reference (1 and 42),
    // so `findProto` resolves them. Restore borrows these `*const Proto`s.
    var p1 = Proto{ .code = &.{}, .name = "p1", .id = 1 };
    var p42 = Proto{ .code = &.{}, .name = "p42", .id = 42 };
    var rootp = Proto{ .code = &.{}, .name = "root", .id = 0, .protos = &.{ &p1, &p42 } };

    const file: schema.SnapshotFile = .{
        .version = snapshot_format_version,
        .keyframe = .{
            .globals_id = 2,
            .objects = &.{
                .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a\x00b\xff\xfe" } } },
                .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "" } } },
                .{ .id = 2, .obj_type = 1, .body = .{ .HeapTable = .{
                    .array = &.{ sInt(10), sFloat(2.5), sBool(true) },
                    .entries = &.{
                        .{ .key = sRef(0), .val = sRef(3) },
                        .{ .key = sInt(7), .val = sRef(2) }, // self-ref
                    },
                } } },
                .{ .id = 3, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 42, .upvalue_ids = &.{ 4, 5 } } } },
                .{ .id = 6, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 1, .upvalue_ids = &.{} } } },
                .{ .id = 4, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 1, .value = sInt(99) } } },
                .{ .id = 5, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 0, .value = sRef(2) } } },
                .{ .id = 7, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "print" } } },
            },
            .stack = &.{ sRef(2), sInt(-1) },
            // Both stub protos have num_registers == 0, so contiguity wants base 0
            // for both frames (this corpus exercises structural restore, not resume).
            .frames = &.{
                .{ .closure_id = 3, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0 },
                .{ .closure_id = 6, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0 },
            },
            .open_upvalues = &.{.{ .stack_index = 0, .upvalue_id = 5 }},
        },
    };

    const vm = try restoreSnapshot(gpa, file, &rootp, NativeRegistry.base());
    defer {
        vm.deinit();
        gpa.destroy(vm);
    }

    // 8 objects restored with their exact ids; counter parked past id 7.
    try testing.expectEqual(@as(usize, 8), vm.heap.object_count);
    try testing.expectEqual(@as(u32, 8), vm.heap.next_obj_id);

    // globals is the table id 2; its self-ref entry (key 7) points back at it.
    try testing.expectEqual(@as(u32, 2), vm.globals.header.id);
    const self_ref = vm.globals.get(Value.int(7));
    try testing.expect(self_ref.isHeap() and self_ref.asHeap() == &vm.globals.header);
    // Array part round-tripped (key 1 == 10, key 2 == 2.5, key 3 == true).
    try testing.expectEqual(@as(i64, 10), vm.globals.get(Value.int(1)).asInt());
    try testing.expectEqual(@as(f64, 2.5), vm.globals.get(Value.int(2)).asFloat());

    // Frames rebound (depth 2; frame 0 = closure 3, frame 1 = closure 6, which
    // has zero upvalues — exercising both the N- and 0-upvalue closure shapes).
    try testing.expectEqual(@as(u32, 2), vm.depth);
    try testing.expectEqual(@as(u32, 3), vm.frames[0].closure.header.id);
    try testing.expectEqual(@as(u32, 6), vm.frames[1].closure.header.id);
    try testing.expectEqual(@as(usize, 2), vm.frames[0].closure.upvalues.len);
    try testing.expectEqual(@as(usize, 0), vm.frames[1].closure.upvalues.len);
    // The two-upvalue closure's closed cell (id 4) holds 99.
    try testing.expectEqual(@as(i64, 99), vm.frames[0].closure.upvalues[0].get().asInt());

    // Closed upvalue id 4 holds 99; open upvalue id 5 was repointed at stack[0]
    // and therefore reads the table ref now living there.
    try testing.expectEqual(@as(usize, 1), vm.open_upvalues.items.len);
    const open_cell = vm.open_upvalues.items[0].cell;
    try testing.expectEqual(@as(u32, 5), open_cell.header.id);
    try testing.expectEqual(&vm.stack[0], open_cell.ptr);
    try testing.expect(open_cell.get().isHeap() and open_cell.get().asHeap() == &vm.globals.header);

    // Stack window restored.
    try testing.expectEqual(@as(usize, 2), vm.stack_top);
    try testing.expectEqual(@as(i64, -1), vm.stack[1].asInt());
}

/// Restore the given file and assert it fails with exactly `want`.
fn expectRestoreError(file: schema.SnapshotFile, root: *const Proto, want: RestoreError) !void {
    const gpa = testing.allocator;
    if (restoreSnapshot(gpa, file, root, NativeRegistry.base())) |vm| {
        vm.deinit();
        gpa.destroy(vm);
        return error.TestUnexpectedSuccess;
    } else |err| {
        try testing.expectEqual(want, err);
    }
}

test "restore surfaces specific errors for malformed snapshots" {
    var rootp = Proto{ .code = &.{}, .name = "root", .id = 0 };

    // A dangling HeapRef in a table value.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{},
            .entries = &.{.{ .key = sInt(1), .val = sRef(77) }},
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
    } }, &rootp, error.UnresolvedHeapRef);

    // A closure naming a proto id the program image does not contain.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 99, .upvalue_ids = &.{} } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
    } }, &rootp, error.UnknownProto);

    // A native whose name is not in the registry.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "nope" } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
    } }, &rootp, error.UnknownNative);

    // globals_id resolves to a string, not a table.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "x" } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
    } }, &rootp, error.GlobalsNotATable);

    // Two objects sharing an id.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 5,
        .objects = &.{
            .{ .id = 5, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a" } } },
            .{ .id = 5, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "b" } } },
        },
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
    } }, &rootp, error.DuplicateId);

    // A wrong-version file is rejected outright.
    try expectRestoreError(.{ .version = snapshot_format_version + 1, .keyframe = .{
        .globals_id = 0,
        .objects = &.{},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
    } }, &rootp, error.UnsupportedVersion);
}

// ---------------------------------------------------------------------------
// F2c — mid-execution capture + resume
// ---------------------------------------------------------------------------
//
// The F2b headline (`encodeSnapshot ∘ restore == identity`) was only ever proven
// for a *final-state* snapshot (empty stack/frames). F2c suspends execution at a
// mid-loop / mid-call safepoint, captures the live stack + frame cursors, restores
// into a fresh VM, and **re-executes forward** to the same result. The resumed VM
// borrows the original program image (`chunk.proto`), whose string constants live
// in the *compile-time* heap — a different heap than the restored one. That works
// only because heap identity is by stable `GcHeader.id` (value.zig `eql`), not by
// address: a borrowed proto constant and its restored twin share an id, so a
// resumed `get_global`/table lookup resolves. (Before the id-based `eql` fix this
// test failed with `TypeError`: `print` resolved to `nil`.)

const SuspendCtl = interp.SuspendCtl;

/// A reference (uninterrupted) run of `source`: its full output `F`, its
/// final-state snapshot `Sf`, and the total safepoint count (to place a mid-run
/// suspend). Owns the two byte buffers.
const RefRun = struct {
    full_out: []u8,
    final_snap: []u8,
    total_safepoints: u64,

    fn deinit(self: RefRun, gpa: std.mem.Allocator) void {
        gpa.free(self.full_out);
        gpa.free(self.final_snap);
    }
};

fn referenceRun(gpa: std.mem.Allocator, source: [:0]const u8) !RefRun {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);

    return .{
        .full_out = try gpa.dupe(u8, sink.buffered()),
        .final_snap = try encodeSnapshot(gpa, &vm),
        .total_safepoints = vm.safepoint_seq,
    };
}

/// Suspend `source` at `ctl`, snapshot mid-execution, restore into a fresh VM,
/// resume to completion, and assert full equivalence to `ref`:
///   (a) the program actually suspended (didn't run straight through);
///   (b) F2b byte-identity holds mid-execution: `encodeSnapshot(restore(mid)) == mid`;
///   (c) `out_before ++ out_after == F`  (output equivalence — the headline);
///   (d) the resumed final-state snapshot `== Sf`  (state equivalence).
/// Returns the mid snapshot bytes (caller owns) so determinism can be cross-checked.
fn expectResume(gpa: std.mem.Allocator, source: [:0]const u8, ctl: SuspendCtl, ref: RefRun) ![]u8 {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // The suspend VM owns the heap the program image's constants are interned
    // into; it must outlive the restored VM that borrows `chunk.proto`.
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    vm.suspend_ctl = ctl;
    try testing.expect((try vm.start(chunk.proto)) == .suspended); // (a)
    const out_before = try gpa.dupe(u8, sink.buffered());
    defer gpa.free(out_before);

    const mid = try encodeSnapshot(gpa, &vm);
    errdefer gpa.free(mid);

    // (b) F2b property holds mid-execution.
    const vm_r = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    {
        const mid2 = try encodeSnapshot(gpa, vm_r);
        defer gpa.free(mid2);
        try testing.expectEqualSlices(u8, mid, mid2);
    }

    // Resume the restored VM to completion.
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.suspend_ctl = null;
    try testing.expect((try vm_r.exec()) == .finished);

    // (c) output equivalence: out_before ++ out_after == F.
    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.full_out, combined[0 .. out_before.len + sink_r.buffered().len]);

    // (d) state equivalence: the resumed VM's final snapshot matches the
    // uninterrupted run's. Identical because ids are assigned deterministically
    // and these corpus programs leak no pre-suspend garbage (no heap object is
    // created then dropped before the cut), so the restored id counter resumes
    // exactly where the reference run's did.
    const final_snap_r = try encodeSnapshot(gpa, vm_r);
    defer gpa.free(final_snap_r);
    try testing.expectEqualSlices(u8, ref.final_snap, final_snap_r);

    return mid;
}

// Corpus: nested calls + loops + closures/upvalues + tables. Each is replayed at
// two cuts — one anywhere mid-run (depth gate off), one forced *inside a call*.
const f2c_corpus = [_][:0]const u8{
    // Loop inside a call, two host calls after it returns.
    \\local function sum(n)
    \\  local s = 0
    \\  for i = 1, n do s = s + i end
    \\  return s
    \\end
    \\print(sum(5))
    \\print("done")
    ,
    // A counter closure: an OPEN upvalue is live on the stack at a mid-call cut.
    \\local function counter()
    \\  local n = 0
    \\  return function() n = n + 1; return n end
    \\end
    \\local c = counter()
    \\print(c()); print(c()); print(c())
    ,
    // Three-deep call stack (main → outer → inner) feeding a table.
    \\local function inner(x) return x * 2 end
    \\local function outer(a, b) return inner(a) + inner(b) end
    \\local t = {}
    \\t.r = outer(3, 4)
    \\print(t.r)
    ,
};

test "F2c: resume from a mid-execution keyframe reproduces output and final state" {
    const gpa = testing.allocator;
    for (f2c_corpus) |source| {
        const ref = try referenceRun(gpa, source);
        defer ref.deinit(gpa);
        try testing.expect(ref.total_safepoints > 4);

        // Cut 1: anywhere ~half-way through (depth gate off — often mid-loop / mid-call).
        gpa.free(try expectResume(gpa, source, .{
            .min_depth = 1,
            .after_safepoints = ref.total_safepoints / 2,
        }, ref));

        // Cut 2: the first safepoint *inside* a nested call (depth >= 2).
        gpa.free(try expectResume(gpa, source, .{
            .min_depth = 2,
            .after_safepoints = 1,
        }, ref));
    }
}

test "F2c: independent VMs suspended at the same cut produce byte-identical keyframes" {
    const gpa = testing.allocator;
    for (f2c_corpus) |source| {
        const ref = try referenceRun(gpa, source);
        defer ref.deinit(gpa);
        const ctl: SuspendCtl = .{ .min_depth = 2, .after_safepoints = 1 };
        const mid_a = try expectResume(gpa, source, ctl, ref);
        defer gpa.free(mid_a);
        const mid_b = try expectResume(gpa, source, ctl, ref);
        defer gpa.free(mid_b);
        // Two independent runs cut at the same safepoint snapshot identically —
        // the mid-execution extension of the run-twice determinism property.
        try testing.expectEqualSlices(u8, mid_a, mid_b);
    }
}

test "F2c: a frame window that doesn't tile from 0 is rejected (FrameWindowMismatch)" {
    // Two single-register closures sharing a proto. A faithful capture tiles the
    // windows 0,1; a base of 2 for the second frame leaves a one-slot gap → the
    // restore contiguity guard must reject it rather than read the wrong registers.
    const code = [_]bytecode.Instr{bytecode.Instr.opAB(.halt, 0, 0)};
    const consts = [_]value.Value{};
    const rootp = Proto{
        .code = &code,
        .constants = &consts,
        .num_registers = 1,
        .name = "f",
    };
    const bad: schema.SnapshotFile = .{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 9,
        .objects = &.{
            .{ .id = 9, .obj_type = 1, .body = .{ .HeapTable = .{ .array = &.{}, .entries = &.{} } } },
            .{ .id = 0, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = rootp.id, .upvalue_ids = &.{} } } },
            .{ .id = 1, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = rootp.id, .upvalue_ids = &.{} } } },
        },
        .stack = &.{ sNil(), sNil(), sNil() },
        .frames = &.{
            .{ .closure_id = 0, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0 },
            .{ .closure_id = 1, .pc = 0, .base = 2, .ret_dest = 0, .ret_count = 0 }, // gap: expected base 1
        },
        .open_upvalues = &.{},
    } };
    try expectRestoreError(bad, &rootp, error.FrameWindowMismatch);
}

// ---------------------------------------------------------------------------
// F2d — combined keyframe + effect replay (the real demo)
//
// F2c proved a mid-execution keyframe re-executes forward to the same result —
// but only for a *deterministic* program. The moment a run reads a
// nondeterministic input (`clock()`), re-execution diverges unless the recorded
// inputs are fed back. This test ties the two halves of the substrate together:
// restore a mid-run keyframe AND replay its effect log from the cut, and the
// forward output matches the uninterrupted run byte-for-byte.
//
// The seam the keyframe does NOT carry is the effect cursor: the keyframe is the
// heap/stack/frames, the effect log + cursor are replay-driver state supplied
// alongside it. So restore() rebuilds the VM, then the driver sets
// effect_mode/effect_log/effect_cursor before resuming — exactly what a real
// replay harness would marshal next to the snapshot.
// ---------------------------------------------------------------------------

// A deterministic test clock injected as a `ClockSource` (the interpreter holds
// no platform clock of its own). Returns next, next+1, next+2, … so the recorded
// effect log is reproducible.
const TestClock = struct {
    next: i64,
    fn nowNs(ctx: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        const v = self.next;
        self.next += 1;
        return v;
    }
    fn source(self: *TestClock) interp.ClockSource {
        return .{ .ctx = self, .nowNs = &TestClock.nowNs };
    }
};

// A clock()-using program with a loop inside a nested call: each cut lands with
// live frames AND a partially-consumed effect log, so both halves are exercised.
const f2d_combined_source =
    \\local function ticks(n)
    \\  local s = 0
    \\  for i = 1, n do s = s + clock() end
    \\  return s
    \\end
    \\print(ticks(3))
    \\print(ticks(3))
;

test "F2d: restore a mid-run keyframe + replay its effect log → identical forward output" {
    const gpa = testing.allocator;
    const source = f2d_combined_source;

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // --- Run 1 (record): full uninterrupted run → reference output F + effect log L.
    const ref = blk: {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());

        // Inject a deterministic clock so the recorded log is reproducible (the
        // record VM is the only one that calls clock(); the replay VMs feed L back).
        var clk = TestClock{ .next = 1000 };
        vm.clock_source = clk.source();
        vm.effect_mode = .record;
        _ = try vm.run(chunk.proto);

        break :blk .{
            .out = try gpa.dupe(u8, sink.buffered()),
            .log = try gpa.dupe(interp.Effect, vm.effect_log.items),
            .safepoints = vm.safepoint_seq,
        };
    };
    defer gpa.free(ref.out);
    defer gpa.free(ref.log);
    try testing.expectEqual(@as(usize, 6), ref.log.len); // 3 + 3 clock() calls
    try testing.expect(ref.safepoints > 4);

    // --- Run 2 (replay + suspend): re-run feeding L back, cut mid-execution. Replay
    // (not a fresh record) so the clock values match L exactly — the pre-cut output
    // is then a true prefix of F, and the cursor names how much of L was consumed.
    // The suspend VM owns the heap the program image interns into; it must outlive
    // the restored VM that borrows `chunk.proto`.
    var vm2 = try Vm.init(gpa);
    defer vm2.deinit();
    var buf2: [512]u8 = undefined;
    var sink2 = io.Writer.fixed(&buf2);
    vm2.out = &sink2;
    var chunk2 = try lune_compiler.compile(gpa, &vm2.heap, source, tree.root, &diags);
    defer chunk2.deinit();
    try testing.expect(!diags.hasErrors());

    vm2.effect_mode = .replay;
    try vm2.effect_log.appendSlice(gpa, ref.log);
    vm2.suspend_ctl = .{ .min_depth = 2, .after_safepoints = ref.safepoints / 2 };
    try testing.expect((try vm2.start(chunk2.proto)) == .suspended);

    const out_before = try gpa.dupe(u8, sink2.buffered());
    defer gpa.free(out_before);
    const cursor_at_cut = vm2.effect_cursor; // replay-driver state the keyframe omits
    try testing.expect(cursor_at_cut > 0 and cursor_at_cut < ref.log.len); // genuinely mid-log

    const mid = try encodeSnapshot(gpa, &vm2);
    defer gpa.free(mid);

    // --- Restore + replay-from-cursor: rebuild the VM from the keyframe, then the
    // driver re-attaches the effect log and cursor (the seam the keyframe omits).
    const vm_r = try restore(gpa, mid, chunk2.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.effect_mode = .replay;
    try vm_r.effect_log.appendSlice(gpa, ref.log);
    vm_r.effect_cursor = cursor_at_cut;
    vm_r.suspend_ctl = null;
    try testing.expect((try vm_r.exec()) == .finished);

    // out_before ++ out_after == F: the restored run consumed the tail of L from the
    // cursor and reproduced the rest of the output exactly.
    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.out, combined[0 .. out_before.len + sink_r.buffered().len]);
    // The whole log was consumed exactly once across the cut (no effect lost or replayed twice).
    try testing.expectEqual(ref.log.len, vm_r.effect_cursor);
}
