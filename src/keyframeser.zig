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
const gc = @import("gc.zig");
const key_order = @import("key_order.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");

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
/// v3 (chunk 2a): `HeapTable` gained `metatable_id` — the table's metatable as a
/// heap edge (0 = none), so a metatable'd table round-trips through a snapshot.
/// v4 (L-2): `Keyframe` gained `loaded_sources` — the source text of every
/// runtime-`load`ed chunk, in load order. Restore re-compiles each (compile is
/// deterministic) so a live `load` closure survives snapshot→restore without
/// serializing bytecode.
pub const snapshot_format_version: u32 = 4;

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
        // A `row_view` never reaches the wire (doc 14, Phase 7). The gate ensures a
        // view is produced only transiently by a fused `a[i][j]` and consumed
        // within that one opcode — it never persists in a register across a
        // safepoint, and any *bare* access deflates the grid first. Snapshots fall
        // on opcode boundaries (safepoints), and `encodeSnapshot` additionally
        // deflates all grids up front, so neither a register nor a table array can
        // hand us one here.
        .row_view => unreachable,
    };
}

/// A table hash-part (key, value) pair, used to serialize in a canonical order.
/// Ordered by the shared `key_order.keyLessThan` — the same comparator the
/// `pairs`/`next` iterator uses, so snapshot bytes and live iteration agree.
const HashKV = struct {
    key: Value,
    val: Value,
    fn lessThan(_: void, x: HashKV, y: HashKV) bool {
        return key_order.keyLessThan(x.key, y.key);
    }
};

/// Collect a table's hash-part entries into `a`-owned scratch, sorted by
/// `key_order.keyLessThan`. Serializing the hash part in this **canonical** order (rather
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
pub fn toSchemaHeapObject(a: std.mem.Allocator, vm: *Vm, h: *GcHeader) !schema.HeapObject {
    const Body = schema.BsUnion_HeapString_HeapTable_HeapClosure_HeapNative_HeapUpvalue;
    const body: Body = switch (h.type) {
        .string => .{ .HeapString = .{ .bytes = string.String.fromHeader(h).bytes() } },
        .table => blk: {
            const t = table.Table.fromHeader(h);
            const array = try a.alloc(schema.SnapValue, t.array.len);
            // Capture emits *logical* Values via `array.get`, so the snapshot bytes
            // are independent of the in-memory lane (a packed bool/int array and an
            // unpacked `.value` array with the same logical contents serialize
            // identically). `get` is 1-based.
            for (0..t.array.len) |i| array[i] = toSchemaValue(t.array.get(i + 1));
            const kvs = try sortedHashEntries(a, t);
            const entries = try a.alloc(schema.TableEntry, kvs.len);
            for (kvs, 0..) |kv, i| {
                entries[i] = .{ .key = toSchemaValue(kv.key), .val = toSchemaValue(kv.val) };
            }
            // The metatable is a heap edge, encoded as a **1-based** optional id:
            // `header.id + 1` when present, `0` when absent. Id 0 IS a live object
            // (the first allocation — `globals` — gets id 0; see `gc.zig`), so a
            // bare id cannot serve as the "none" sentinel: `setmetatable(t, _G)`
            // would round-trip as no-metatable and silently drop the edge.
            const mt_id: u32 = if (t.metatable) |m| m.header.id + 1 else 0;
            break :blk .{ .HeapTable = .{ .array = array, .entries = entries, .metatable_id = mt_id } };
        },
        .function => blk: {
            const cl = function.Closure.fromHeader(h);
            const upvalue_ids = try a.alloc(u32, cl.upvalues.len);
            for (cl.upvalues, 0..) |uv, i| upvalue_ids[i] = uv.header.id;
            break :blk .{ .HeapClosure = .{ .proto_id = cl.proto.id, .upvalue_ids = upvalue_ids } };
        },
        .upvalue => blk: {
            const u = function.Upvalue.fromHeader(h);
            // An open cell's value lives in a live stack slot — `upvalGet` resolves
            // the index against the VM stack; a closed cell owns it directly. (At the
            // F2a quiescent capture point every reachable cell is closed; F2b uses
            // `open_upvalues` to re-derive the open slot on restore.)
            const is_closed = !u.isOpen();
            break :blk .{ .HeapUpvalue = .{ .closed = @intFromBool(is_closed), .value = toSchemaValue(vm.upvalGet(u)) } };
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
                for (0..t.array.len) |i| self.pushValue(t.array.get(i + 1));
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
                // The metatable edge (chunk 2a) — the same child `gc.blacken`
                // marks. Without this, a metatable reachable ONLY via this edge
                // (the common `setmetatable(t, {…})` with an anonymous metatable)
                // is omitted from `objects[]`, yet the serializer still writes its
                // id, so restore fails with `UnresolvedHeapRef`. The serializer and
                // the GC must enumerate the identical child set.
                if (t.metatable) |m| self.push(&m.header);
            },
            .upvalue => switch (function.Upvalue.fromHeader(h).loc) {
                // Open ⇒ the value rides a live stack slot already seeded as a root.
                .open => {},
                .closed => |v| self.pushValue(v),
            },
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

    // 0. Deflate every live grid back to nested row Tables (doc 14, Phase 7). A
    //    grid is an in-memory-only optimisation never written to the wire; capture
    //    persists the logical nested form, so the snapshot is identical whether or
    //    not a matrix happened to be flattened at this instant. After this no
    //    `t.array.get` below can hit a grid (which would assert) and no `row_view`
    //    can be produced.
    try vm.heap.deflateAllGrids();

    // 1. Enumerate the reachable heap graph from the VM roots.
    var walk = Walk{ .a = a };
    vm.forEachRootHeader(&walk, Walk.push);
    var i: usize = 0;
    while (i < walk.order.items.len) : (i += 1) walk.enumerateChildren(walk.order.items[i]);
    if (walk.err) |e| return e;

    // 2. Map each object to its wire form.
    const objects = try a.alloc(schema.HeapObject, walk.order.items.len);
    for (walk.order.items, 0..) |h, idx| objects[idx] = try toSchemaHeapObject(a, vm, h);

    // 3. Capture the roots verbatim (the live register window, active frames, and
    //    open upvalues — empty at final-state capture; load-bearing in F2b).
    const stack = try a.alloc(schema.SnapValue, vm.stack_top);
    for (stack, 0..) |*sv, idx| sv.* = toSchemaValue(vm.regGet(idx));

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

    // Runtime-`load`ed chunks, in load order (L-2): source + chunk name. Restore
    // recompiles each — compile is deterministic, so the same sources in the same
    // order regenerate byte-identical protos/ids — letting a live `load` closure
    // survive snapshot→restore. The NUL terminator is omitted; restore re-adds it.
    // The name is the (renamed) root proto's name, so a post-restore fault in
    // loaded code reports the same `(load):N:`/`<name>:N:` as the live VM.
    const loaded = try a.alloc(schema.LoadedChunk, vm.loaded_chunks.items.len);
    for (vm.loaded_chunks.items, 0..) |lc, idx| loaded[idx] = .{
        .source = lc.source,
        .name = lc.chunk.proto.name,
    };

    const file: schema.SnapshotFile = .{
        .version = snapshot_format_version,
        .keyframe = .{
            .globals_id = vm.globals.header.id,
            // The shared string metatable is a VM-level root (chunk 2a): captured
            // by id so restore rebinds the *same* table rather than rebuilding a
            // fresh one with a drifted id. Encoded **1-based** (`id + 1`); 0 = none
            // (a bare VM that never built metatable support — only hand-built test
            // snapshots) — id 0 is a real object, so it cannot be the sentinel.
            .string_metatable_id = if (vm.string_metatable) |s| s.header.id + 1 else 0,
            .objects = objects,
            .stack = stack,
            .frames = frames,
            .open_upvalues = open,
            .loaded_chunks = loaded,
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
// rebound last. The VM is heap-allocated and returned by pointer so its register
// stack (and the heap it owns) keep a stable address across the caller's lifetime;
// open upvalue cells reference their slot by **index** (not a `*Value`), so they
// survive the stack later splitting into parallel tag/payload arrays (doc 09).
// ---------------------------------------------------------------------------

const RestoreError = error{
    UnsupportedVersion, // SnapshotFile.version != snapshot_format_version
    HeapNotEmpty, // restoring into a non-bare VM would collide ids/interning
    DuplicateId, // two HeapObjects share an id (corrupt snapshot)
    DuplicateInternedString, // two HeapStrings carry identical bytes (corrupt snapshot — breaks interning)
    IdSpaceExhausted, // restored ids fill the u32 space, leaving no room for recompiled chunk literals
    UnresolvedHeapRef, // a HeapRef / root id has no matching object
    UnknownProto, // a HeapClosure.proto_id is not in the program's proto tree
    LoadedChunkRecompileFailed, // a recorded `load` source no longer parses/compiles (corrupt snapshot)
    UnknownNative, // a HeapNative.name is not in the native registry
    GlobalsNotATable, // globals_id resolves to a non-table object
    MetatableNotATable, // a HeapTable.metatable_id resolves to a non-table object
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

/// Resolve a `proto_id` across the static `root` tree **and** every runtime-loaded
/// chunk's tree (L-2). The id space is disjoint by construction (`load` offsets
/// each loaded tree's ids by the running `next_proto_id`), so a `proto_id` matches
/// exactly one proto. Static protos are checked first (the common case).
fn resolveProto(root: *const Proto, vm: *const Vm, id: u32) ?*const Proto {
    if (findProto(root, id)) |p| return p;
    for (vm.loaded_chunks.items) |lc| if (findProto(lc.chunk.proto, id)) |p| return p;
    return null;
}

/// Recompile every runtime-`load`ed chunk recorded in the keyframe (L-2), in load
/// order, into `vm.loaded_chunks` — regenerating byte-identical protos/ids because
/// compile is deterministic. Seeds `vm.next_proto_id` from the static `root` first
/// (matching `Vm.run`/`start`), then compiles each source at the running id base
/// and renames the root proto so post-restore faults match the live VM. A source
/// that fails to recompile means a corrupt/incompatible snapshot. Ownership of the
/// dup'd source mirrors `stdlib/load.zig`: exactly one freer on every path.
fn recompileLoadedChunks(vm: *Vm, root: *const Proto, loaded: []const schema.LoadedChunk) RestoreError!void {
    vm.seedProtoIds(root); // ids [0, countProtos(root)) belong to the static tree
    for (loaded) |lc| {
        const owned = try vm.gpa.dupeSentinel(u8, lc.source, 0);

        var diags = diag.Diagnostics.init(vm.gpa);
        defer diags.deinit();

        var tree = parser.parse(vm.gpa, owned, &diags) catch {
            vm.gpa.free(owned);
            return error.LoadedChunkRecompileFailed;
        };
        defer tree.deinit();
        if (diags.hasErrors()) {
            vm.gpa.free(owned);
            return error.LoadedChunkRecompileFailed;
        }

        var chunk = compiler.compileWithOptions(vm.gpa, &vm.heap, owned, tree.root, &diags, .{
            .known_globals = &interp.builtin_global_names,
            .id_base = vm.next_proto_id,
            .vararg_root = true,
        }) catch {
            vm.gpa.free(owned);
            return error.LoadedChunkRecompileFailed;
        };
        if (diags.hasErrors()) {
            chunk.deinit();
            vm.gpa.free(owned);
            return error.LoadedChunkRecompileFailed;
        }

        chunk.proto.name = chunk.arena.allocator().dupe(u8, lc.name) catch {
            chunk.deinit();
            vm.gpa.free(owned);
            return error.OutOfMemory;
        };

        vm.loaded_chunks.append(vm.gpa, .{ .chunk = chunk, .source = owned }) catch |e| {
            chunk.deinit();
            vm.gpa.free(owned);
            return e;
        };
        vm.next_proto_id += chunk.proto_count;
    }
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

    // Advance the id counter past every restored id BEFORE recompiling loaded
    // chunks (L-2): a loaded chunk whose closure was collected has no string
    // objects in the snapshot, so recompiling it re-interns those literals as
    // fresh heap strings — which must take ids ABOVE the restored range, never
    // collide with a restored id. (Reachable loaded chunks keep their literals in
    // the snapshot; recompile reuses them via interning, allocating nothing new.)
    // Phantom grid rows (doc 14, Phase 7) carry ids in the reserved high half
    // (`gc.reserved_grid_id_base`+) so capture timing can't shift them. They are
    // NOT genuine allocations and must not advance the counter — a post-restore
    // allocation belongs in the normal low space, right above the real objects.
    // So compute the high-water from non-reserved ids only.
    var max_id: u32 = 0;
    for (kf.objects) |o| {
        if (o.id >= gc.reserved_grid_id_base) continue;
        max_id = @max(max_id, o.id);
    }
    // If the restored ids already fill the (non-reserved) id space, recompiling a
    // loaded chunk (which allocates fresh interned strings via `link`) would wrap
    // the counter and collide with a restored id. Reject rather than silently
    // alias. (The engine assumes < 2³¹ live objects everywhere; this only bites if
    // a snapshot both names the top id AND carries loaded chunks to recompile.)
    if (max_id == gc.reserved_grid_id_base - 1 and kf.loaded_chunks.len > 0)
        return error.IdSpaceExhausted;
    vm.heap.adoptNextId(max_id +| 1);

    // --- Pass 1a: create every object shell EXCEPT closures, stamped with its
    // original id. Strings are interned first so the recompile below reuses them
    // (same bytes → same object → same id) rather than minting new ids. Closures
    // are deferred to pass 1b because they bind a proto that may live in a loaded
    // chunk not yet recompiled. ---
    for (kf.objects) |o| {
        if (o.body == .HeapClosure) continue; // deferred to 1b
        if (idmap.contains(o.id)) return error.DuplicateId;
        const header: *GcHeader = switch (o.body) {
            .HeapString => |hs| blk: {
                // Re-intern: allocate the bytes and register them so later program
                // interning of the same bytes resolves to this object, and sweep
                // can de-intern it. NOT `heap.intern` — that auto-links a counter id.
                const s = try string.String.create(gpa, hs.bytes);
                errdefer s.destroy(gpa);
                // A valid snapshot interns one String per byte-sequence, so these
                // bytes must be unseen. A corrupt snapshot with two strings sharing
                // bytes (different ids) would overwrite the first mapping here and
                // leave both objects linked — silently breaking the interning
                // invariant. Reject it instead.
                const gop = try vm.heap.interned.getOrPut(gpa, s.bytes());
                // `errdefer s.destroy` above frees `s` on this error return.
                if (gop.found_existing) return error.DuplicateInternedString;
                gop.value_ptr.* = s;
                vm.heap.linkRestored(&s.header, o.id);
                break :blk &s.header;
            },
            .HeapTable => blk: {
                const t = try table.Table.create(gpa);
                vm.heap.linkRestored(&t.header, o.id);
                break :blk &t.header;
            },
            .HeapClosure => unreachable, // skipped above
            .HeapUpvalue => blk: {
                // Born closed-holding-nil (never dangling); pass 2 sets a closed
                // cell's value, and the root rebind switches open cells to `.open`.
                const u = try function.Upvalue.createClosed(gpa, Value.nil());
                vm.heap.linkRestored(&u.header, o.id);
                break :blk &u.header;
            },
            .HeapNative => |hn| blk: {
                const entry = natives.lookup(hn.name) orelse return error.UnknownNative;
                // Use the registry's static name (outlives the decode arena).
                const n = try function.Native.create(gpa, entry.func, entry.name);
                n.effect = entry.effect; // an effect native stays an effect on replay
                n.multi = entry.multi; // …and keeps its multi-result projection
                n.pure = entry.pure; // …and its JIT-inlinable pure-builtin tag
                vm.heap.linkRestored(&n.header, o.id);
                break :blk &n.header;
            },
        };
        idmap.putAssumeCapacityNoClobber(o.id, header);
    }

    // Rebuild the runtime-`load`ed chunk image (L-2): recompile each recorded
    // source so `resolveProto` can rebind a dynamic `HeapClosure.proto_id` in pass
    // 1b. Deterministic recompile reproduces the same protos/ids the live VM had;
    // string literals resolve to the already-interned snapshot strings above.
    try recompileLoadedChunks(vm, root, kf.loaded_chunks);

    // --- Pass 1b: create closure shells now that all protos (static + loaded)
    // exist. linkRestored stamps the original id (the counter was already advanced
    // past it). ---
    for (kf.objects) |o| {
        const hc = switch (o.body) {
            .HeapClosure => |hc| hc,
            else => continue,
        };
        if (idmap.contains(o.id)) return error.DuplicateId;
        const proto = resolveProto(root, vm, hc.proto_id) orelse return error.UnknownProto;
        const cl = try function.Closure.create(gpa, proto, hc.upvalue_ids.len);
        vm.heap.linkRestored(&cl.header, o.id);
        idmap.putAssumeCapacityNoClobber(o.id, &cl.header);
    }

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
                // Metatable edge (chunk 2a): 1-based optional id — 0 = none,
                // otherwise rebind `id - 1` → *Table.
                if (ht.metatable_id != 0) {
                    const mh = idmap.get(ht.metatable_id - 1) orelse return error.UnresolvedHeapRef;
                    if (mh.type != .table) return error.MetatableNotATable;
                    t.metatable = table.Table.fromHeader(mh);
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
                // A closed cell owns its value. An open cell's recorded value is
                // re-derived from the live stack at the root rebind below, so the
                // value here is a harmless placeholder until then.
                u.loc = .{ .closed = try fromSchemaValue(hu.value, &idmap) };
            },
        }
    }

    // --- Roots ---
    const gh = idmap.get(kf.globals_id) orelse return error.UnresolvedHeapRef;
    if (gh.type != .table) return error.GlobalsNotATable;
    vm.globals = table.Table.fromHeader(gh);

    if (kf.stack.len > vm.regCapacity()) return error.StackTooLarge;
    for (kf.stack, 0..) |sv, i| vm.regSet(i, try fromSchemaValue(sv, &idmap));
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
        // Switch the cell from its closed placeholder to open over the live slot.
        cell.loc = .{ .open = ou.stack_index };
        try vm.open_upvalues.append(gpa, .{ .index = ou.stack_index, .cell = cell });
    }

    // VM-level metatable support (chunk 2a). A non-zero `string_metatable_id`
    // marks a snapshot whose VM had metatable support built (`initMetatableSupport`
    // — always true for a real run, false only for the hand-built minimal test
    // corpus). Rebind the string metatable by id (it is a VM-only root, not
    // reachable from globals) and re-derive the interned metamethod-name cache:
    // pass-1 re-interned every captured string into `heap.interned`, so these
    // `internValue` calls resolve to the restored strings with their original ids
    // (no new objects), keeping `encodeSnapshot ∘ restore == identity`.
    if (kf.string_metatable_id != 0) {
        const sh = idmap.get(kf.string_metatable_id - 1) orelse return error.UnresolvedHeapRef;
        if (sh.type != .table) return error.MetatableNotATable;
        vm.string_metatable = table.Table.fromHeader(sh);
        try vm.internMetamethodNames();
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
            .string_metatable_id = 0,
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
                    .metatable_id = 0,
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
    // A table filled `t[2..K]` with no `t[1]` (the nsieve pattern) now triggers a
    // rehash that migrates the dense run into the array part, leaving a nil hole
    // at slot 1. Capture must serialize that array/hash split (holes included) and
    // restore must reproduce it verbatim — the rehash never runs on the restore
    // path, so a captured split round-trips byte-identically.
    try expectRoundTrip(
        \\local t = {}
        \\for i = 2, 40 do t[i] = i * 3 end
        \\t.tag = "sieve-shaped"
        \\result = t
    );
    // The literal nsieve fill: `t[2..K] = true`, all booleans, hole at 1. In memory
    // this packs into the *boolean* lane (~2 bits/slot), but capture emits logical
    // Values via `array.get`, so the snapshot bytes are independent of the lane — a
    // packed bool array and an unpacked `.value` array serialize identically. The
    // restored VM rebuilds the array in the `.value` lane (restore only appends,
    // never rehashes), and its re-capture is byte-identical to the original.
    try expectRoundTrip(
        \\local t = {}
        \\for i = 2, 64 do t[i] = true end
        \\t.tag = "bool-lane"
        \\result = t
    );
    // Metatables (chunk 2a): a table whose metatable is reachable ONLY through the
    // `metatable` edge (an anonymous `{ __index = ... }`), plus a function handler
    // that itself hangs off that metatable. The serializer must follow the
    // metatable edge into `objects[]` (just as `gc.blacken` marks it) or the
    // serialized `metatable_id` dangles and restore fails with `UnresolvedHeapRef`.
    // Restore rebinds `metatable_id` by id and re-derives the VM-level mm-name /
    // string-metatable roots, so the re-capture is byte-identical.
    try expectRoundTrip(
        \\local Obj = {}
        \\Obj.__index = Obj
        \\function Obj:val() return self.x end
        \\local o = setmetatable({ x = 7 }, Obj)
        \\local logged = setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v) end })
        \\result = { o = o, logged = logged }
    );
    // L-2: a live `load` closure reachable from globals. The keyframe carries the
    // chunk's source; restore recompiles it deterministically to the same proto/id,
    // so the serialized `HeapClosure.proto_id` resolves and the re-snapshot matches.
    // No string literals → nothing extra in the constant pool.
    try expectRoundTrip(
        \\f = load("return 6 * 7")
    );
    // L-2: a loaded chunk WITH a string-literal constant. The literal is interned
    // into the heap and is reachable through the closure's proto constants (the
    // walk mirrors `gc.markProtoConstants`), so it serializes as an object with its
    // own id. Restore re-interns the *same* bytes (pass 1a) BEFORE recompiling, so
    // the recompiled proto reuses that restored string rather than minting a new id
    // — the interning invariant (one String per byte-sequence) holds across restore.
    try expectRoundTrip(
        \\greet = load("return 'hello, lune'")
    );
    // L-2: two loaded chunks, exercising the running `next_proto_id` offset across
    // chunks (chunk 2's ids start past chunk 1's). The second is vararg-bodied and
    // multi-proto (a nested function), so its proto subtree must also re-offset to
    // the identical id range on restore.
    try expectRoundTrip(
        \\a = load("return 1")
        \\b = load("local function inner(x) return x + ... end return inner")
    );
}

test "keyframe: a live grid deflates at capture and round-trips byte-identically (doc 14)" {
    // A matrix left *flattened* at final state must serialize as its logical nested
    // form — a grid is an in-memory optimisation, never written to the wire — and
    // re-snapshot byte-identically. `encodeSnapshot` deflates all grids up front;
    // restore only ever builds nested tables, so the re-capture matches.
    try expectRoundTrip(
        \\m = { {1,2,3}, {4,5,6} }
        \\m[1][1] = 10            -- inflate to a grid; still reachable from globals
    );
    // Reshaped (grown stride) + lane-widened, still a grid at capture; deflation
    // must reproduce the grown box and the widened cells as plain row tables.
    try expectRoundTrip(
        \\m = { {1,2}, {3,4} }
        \\m[1][1] = 9
        \\m[1][3] = 7             -- grow stride past 2
        \\m[2][1] = 1000000       -- widen the cell lane
        \\result = m
    );
    // A self-referential outer table that *also* holds a flattened matrix: the
    // matrix deflates, the cycle and the sibling string key round-trip unchanged.
    try expectRoundTrip(
        \\g = {}
        \\g.grid = { {1,2}, {3,4} }
        \\g.grid[2][2] = 40       -- inflate the inner matrix
        \\g.self = g
        \\g.name = "lune"
    );
}

test "restore reanimates a live load closure that runs with the same result (L-2)" {
    const gpa = testing.allocator;
    const source =
        \\f = load("local a, b = ...\nreturn a * b + 1")
    ;
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

    // Sanity: the live VM owns exactly the one loaded chunk.
    try testing.expectEqual(@as(usize, 1), vm.loaded_chunks.items.len);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // The loaded chunk was recompiled on restore.
    try testing.expectEqual(@as(usize, 1), vm2.loaded_chunks.items.len);

    // The restored closure is callable and computes the same vararg result:
    // (6 * 7) + 1 == 43.
    const key = try vm2.heap.internValue("f");
    const f = vm2.globals.get(key);
    try testing.expect(f.isHeap() and f.heapType() == .function);
    var out: [1]Value = undefined;
    const n = try vm2.callValue(f, &.{ Value.int(6), Value.int(7) }, out[0..]);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i64, 43), out[0].asInt());
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
    try testing.expectEqual(@as(i64, 10), vm2.upvalGet(add_cl.upvalues[0]).asInt());

    // print is still a native bound under its name.
    const print_val = vm2.globals.get(try vm2.heap.internValue("print"));
    try testing.expect(print_val.isHeap() and print_val.heapType() == .native);
    try testing.expectEqualStrings("print", function.Native.fromHeader(print_val.asHeap()).name);
}

test "restore reanimates the package/require module system (searchers rebind, cache survives)" {
    const gpa = testing.allocator;
    // Two preloaded modules; only "a" is required (and cached) before the snapshot.
    // After restore: require("a") must hit the surviving cache, and require("b") must
    // run the searcher array — proving the `manual` searcher natives rebound by name
    // and the restored preload closures are still callable.
    const source =
        \\package.preload["a"] = function(n) return "A:" .. n end
        \\package.preload["b"] = function(n) return "B:" .. n end
        \\loaded_a = require("a")
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
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

    // package.searchers restored as a 2-element array of natives, rebound by name.
    const pkg_val = vm2.globals.get(try vm2.heap.internValue("package"));
    try testing.expect(pkg_val.isHeap() and pkg_val.heapType() == .table);
    const pkg = table.Table.fromHeader(pkg_val.asHeap());
    const searchers_val = pkg.get(try vm2.heap.internValue("searchers"));
    try testing.expect(searchers_val.isHeap() and searchers_val.heapType() == .table);
    const searchers = table.Table.fromHeader(searchers_val.asHeap());
    try testing.expect(searchers.getInt(1).heapType() == .native);
    try testing.expect(searchers.getInt(2).heapType() == .native);

    // The cached module "a" survived the snapshot (package.loaded.a == "A:a").
    const loaded_val = pkg.get(try vm2.heap.internValue("loaded"));
    const loaded = table.Table.fromHeader(loaded_val.asHeap());
    const cached_a = loaded.get(try vm2.heap.internValue("a"));
    try testing.expectEqualStrings("A:a", string.String.fromHeader(cached_a.asHeap()).bytes());

    // require still works on the restored VM: "a" from cache, "b" via the rebound
    // searcher + restored preload closure.
    const require_val = vm2.globals.get(try vm2.heap.internValue("require"));
    try testing.expect(require_val.isHeap() and require_val.heapType() == .native);
    var out: [1]Value = undefined;
    _ = try vm2.callValue(require_val, &.{try vm2.heap.internValue("a")}, out[0..]);
    try testing.expectEqualStrings("A:a", string.String.fromHeader(out[0].asHeap()).bytes());
    _ = try vm2.callValue(require_val, &.{try vm2.heap.internValue("b")}, out[0..]);
    try testing.expectEqualStrings("B:b", string.String.fromHeader(out[0].asHeap()).bytes());
}

test "metatable edge to the id-0 object survives round-trip (1-based encoding)" {
    // Regression: `metatable_id` is a 1-based optional id (`header.id + 1`, 0 =
    // none), NOT a bare id with 0 = none. Id 0 IS a live object — the first heap
    // allocation (`globals`) gets it — so the bare-id encoding would serialize a
    // metatable pointing at the id-0 object as `0` and restore would drop the edge.
    // Crucially, byte-identity round-trip CANNOT catch this (encode writes 0, the
    // restored table has no metatable, re-encode writes 0 → b0==b1 holds while the
    // edge silently vanished). The only sound check is to assert the restored
    // pointer directly.
    const gpa = testing.allocator;
    const source = "g = {}";

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // `globals` is the first allocation, so it holds id 0 — the value that the old
    // bare-id encoding overloaded as the "none" sentinel.
    try testing.expectEqual(@as(u32, 0), vm.globals.header.id);

    // Point g's metatable at the id-0 object (globals). Reachable only via the
    // metatable edge from g's perspective, so a dropped edge is observable.
    const g_val0 = vm.globals.get(try vm.heap.internValue("g"));
    try testing.expect(g_val0.isHeap() and g_val0.heapType() == .table);
    table.Table.fromHeader(g_val0.asHeap()).metatable = vm.globals;

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // The edge must come back pointing at the restored id-0 object — not null.
    const g_val = vm2.globals.get(try vm2.heap.internValue("g"));
    try testing.expect(g_val.isHeap() and g_val.heapType() == .table);
    const g_mt = table.Table.fromHeader(g_val.asHeap()).metatable;
    try testing.expect(g_mt != null);
    try testing.expectEqual(@as(u32, 0), g_mt.?.header.id);
    try testing.expect(g_mt.? == vm2.globals);

    // And re-capture is byte-identical (the 1-based id survives both directions).
    const b1 = try encodeSnapshot(gpa, vm2);
    defer gpa.free(b1);
    try testing.expectEqualSlices(u8, b0, b1);
}

test "restore preserves a multi-result native's projection and multi fn" {
    // A multi-return native (`math.modf`) serializes by name only (`HeapNative`),
    // so the restore path must reattach BOTH its single-result `func` projection
    // and its `multi` fn from the registry entry — otherwise a snapshot taken
    // mid-program would come back single-return and `local i, f = math.modf(x)`
    // would silently lose its second result after replay.
    const gpa = testing.allocator;
    const source = "m = math.modf"; // make the native reachable from a global

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // Walk both routes to the restored native: the direct global `m`, and the
    // `math` table's `modf` field — both must resolve to a `math.modf` native.
    const via_global = vm2.globals.get(try vm2.heap.internValue("m"));
    const math_tbl_val = vm2.globals.get(try vm2.heap.internValue("math"));
    try testing.expect(math_tbl_val.isHeap() and math_tbl_val.heapType() == .table);
    const via_field = table.Table.fromHeader(math_tbl_val.asHeap()).get(try vm2.heap.internValue("modf"));

    for ([_]Value{ via_global, via_field }) |nv| {
        try testing.expect(nv.isHeap() and nv.heapType() == .native);
        const n = function.Native.fromHeader(nv.asHeap());
        try testing.expectEqualStrings("math.modf", n.name);
        try testing.expect(n.effect == null); // modf is pure, not an effect native
        try testing.expect(n.multi != null); // …and its multi projection survived

        // The single-result projection still yields the integral part…
        const ip = try n.func(undefined, &.{Value.float(3.5)});
        try testing.expect(ip.isFloat() and ip.asFloat() == 3.0);

        // …and the multi fn still writes both integral + fractional parts.
        var out: [2]Value = .{ Value.nil(), Value.nil() };
        const produced = try n.multi.?(undefined, &.{Value.float(3.5)}, &out);
        try testing.expectEqual(@as(usize, 2), produced);
        try testing.expect(out[0].asFloat() == 3.0);
        try testing.expect(out[1].asFloat() == 0.5);
    }
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
            .string_metatable_id = 0,
            .objects = &.{
                .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a\x00b\xff\xfe" } } },
                .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "" } } },
                .{ .id = 2, .obj_type = 1, .body = .{ .HeapTable = .{
                    .array = &.{ sInt(10), sFloat(2.5), sBool(true) },
                    .entries = &.{
                        .{ .key = sRef(0), .val = sRef(3) },
                        .{ .key = sInt(7), .val = sRef(2) }, // self-ref
                    },
                    .metatable_id = 0,
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
            .loaded_chunks = &.{},
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
    try testing.expectEqual(@as(i64, 99), vm.upvalGet(vm.frames[0].closure.upvalues[0]).asInt());

    // Closed upvalue id 4 holds 99; open upvalue id 5 was rebound over stack[0]
    // and therefore reads the table ref now living there.
    try testing.expectEqual(@as(usize, 1), vm.open_upvalues.items.len);
    const open_cell = vm.open_upvalues.items[0].cell;
    try testing.expectEqual(@as(u32, 5), open_cell.header.id);
    try testing.expectEqual(@as(usize, 0), open_cell.loc.open);
    try testing.expect(vm.upvalGet(open_cell).isHeap() and vm.upvalGet(open_cell).asHeap() == &vm.globals.header);

    // Stack window restored.
    try testing.expectEqual(@as(usize, 2), vm.stack_top);
    try testing.expectEqual(@as(i64, -1), vm.regGet(1).asInt());
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
        .string_metatable_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{},
            .entries = &.{.{ .key = sInt(1), .val = sRef(77) }},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnresolvedHeapRef);

    // A closure naming a proto id the program image does not contain.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 99, .upvalue_ids = &.{} } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnknownProto);

    // A native whose name is not in the registry.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "nope" } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnknownNative);

    // globals_id resolves to a string, not a table.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .objects = &.{.{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "x" } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.GlobalsNotATable);

    // Two objects sharing an id.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 5,
        .string_metatable_id = 0,
        .objects = &.{
            .{ .id = 5, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a" } } },
            .{ .id = 5, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "b" } } },
        },
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.DuplicateId);

    // A wrong-version file is rejected outright.
    try expectRestoreError(.{ .version = snapshot_format_version + 1, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .objects = &.{},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnsupportedVersion);

    // L-2: two HeapStrings carrying identical bytes under distinct ids. A valid
    // snapshot interns one String per byte-sequence, so this is corrupt — restore
    // must reject it rather than overwrite the interning map and leave both linked.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .objects = &.{
            .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "dup" } } },
            .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "dup" } } },
        },
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.DuplicateInternedString);

    // L-2: the restored id space is exhausted (an object names the top *genuine*
    // id — the reserved high half is for phantom grid rows, doc 14 Phase 7) AND the
    // snapshot carries a loaded chunk to recompile — recompiling would allocate
    // fresh interned strings that wrap the counter into the restored range. Reject.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .objects = &.{.{ .id = gc.reserved_grid_id_base - 1, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{},
            .entries = &.{},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{.{ .source = "return 1", .name = "(load)" }},
    } }, &rootp, error.IdSpaceExhausted);
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
    // Generic-for over `pairs` of a string-keyed hash, inside a call. A mid-call
    // cut lands mid-iteration with a hash-part `ctrl` live on the stack and the
    // `next` global as the loop's iterator register — resume must continue the
    // canonical-order traversal from that exact key (D4: mid-iteration snapshot).
    // Accumulates numerically so no heap string is created-then-dropped before the
    // cut (keeps the id counter resuming exactly, per the (d) state-equivalence
    // invariant above).
    \\local function total(t)
    \\  local s = 0
    \\  for k, v in pairs(t) do s = s + v end
    \\  return s
    \\end
    \\local m = {}
    \\m.a = 10
    \\m.b = 20
    \\m.c = 30
    \\print(total(m))
    ,
    // Generic-for over `ipairs` of an array part, inside a call. The cut lands with
    // an integer `ctrl` and the hidden `@ipairs_iter` native as the iterator —
    // exercises the by-name native restore for the un-spellable iterator.
    \\local function asum(a)
    \\  local s = 0
    \\  for i, v in ipairs(a) do s = s + v end
    \\  return s
    \\end
    \\local arr = {2, 4, 6, 8, 10}
    \\print(asum(arr))
    ,
    // A `repeat/until` post-test loop inside a call — a mid-loop cut lands with the
    // back-edge `jmp_if_false` pending, so resume must re-test and continue the
    // loop from the restored register state.
    \\local function tri(n)
    \\  local i = 0
    \\  local s = 0
    \\  repeat
    \\    i = i + 1
    \\    s = s + i
    \\  until i >= n
    \\  return s
    \\end
    \\print(tri(6))
    ,
    // A homogeneous-numeric matrix that inflates to a **grid** (doc 14) and stays
    // live across both loops, so a mid-run cut almost always lands while `m` is a
    // grid. Capture deflates the grid to logical nested rows with reserved-space
    // ids (Phase 7); this case is the proof that those ids are a pure function of
    // logical state — the resumed run re-inflates and re-captures to a
    // BYTE-IDENTICAL final snapshot (invariant (d)) despite the phantom rows. All
    // arithmetic is numeric, so nothing heap is created-then-dropped before a cut.
    \\local function grid()
    \\  local m = {{1,2,3,4},{5,6,7,8},{9,10,11,12},{13,14,15,16}}
    \\  for i = 1, 4 do
    \\    for j = 1, 4 do
    \\      m[i][j] = m[i][j] + 1
    \\    end
    \\  end
    \\  local s = 0
    \\  for i = 1, 4 do
    \\    for j = 1, 4 do
    \\      s = s + m[i][j]
    \\    end
    \\  end
    \\  return s
    \\end
    \\print(grid())
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
        .string_metatable_id = 0,
        .objects = &.{
            .{ .id = 9, .obj_type = 1, .body = .{ .HeapTable = .{ .array = &.{}, .entries = &.{}, .metatable_id = 0 } } },
            .{ .id = 0, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = rootp.id, .upvalue_ids = &.{} } } },
            .{ .id = 1, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = rootp.id, .upvalue_ids = &.{} } } },
        },
        .stack = &.{ sNil(), sNil(), sNil() },
        .frames = &.{
            .{ .closure_id = 0, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0 },
            .{ .closure_id = 1, .pc = 0, .base = 2, .ret_dest = 0, .ret_count = 0 }, // gap: expected base 1
        },
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
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
    \\  for i = 1, n do s = s + os.nsclock() end
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

// ---------------------------------------------------------------------------
// S-C — `unicode_version` survives a snapshot cut without double-consuming.
//
// Unlike F2d (a multi-entry clock() log cut mid-stream), the unicode_version
// effect is logged EXACTLY ONCE per session — at the first case op. So the
// replay hazard is the opposite shape: a later `upper` on a *restored* VM (whose
// in-memory `unicode_version_pinned` was reset to false by `restore`) must NOT
// try to consume a second, nonexistent effect. It must instead DERIVE that the
// version was already pinned pre-cut by scanning the consumed effect-log prefix
// (`versionAlreadyConsumed`). This test cuts AFTER the lone effect is consumed,
// then runs more case ops on the restored VM and proves the forward output is
// byte-identical with the log consumed exactly once.
// ---------------------------------------------------------------------------

const sc_snapshot_source =
    \\local function shout(s, n)
    \\  local r = s
    \\  for i = 1, n do r = string.upper(r) end
    \\  return r
    \\end
    \\print(shout("café", 3))
    \\print(shout("naïve", 3))
;

test "S-C: unicode_version survives a snapshot cut with no double-consume" {
    const gpa = testing.allocator;
    const source = sc_snapshot_source;

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // --- Run 1 (record): reference output F + effect log L (a single unicode_version).
    const ref = blk: {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
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
    // Six upper() calls across the two shout()s, but the version is pinned ONCE.
    try testing.expectEqual(@as(usize, 1), ref.log.len);
    try testing.expectEqual(interp.EffectKind.unicode_version, ref.log[0].kind);

    // --- Run 2 (replay + suspend): cut mid-execution, after the version is pinned.
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
    // The lone effect was consumed before the cut: the whole (length-1) log is spent.
    const cursor_at_cut = vm2.effect_cursor;
    try testing.expectEqual(ref.log.len, cursor_at_cut);
    // And there is genuinely forward work left (the second shout has not printed yet).
    try testing.expect(out_before.len < ref.out.len);

    const mid = try encodeSnapshot(gpa, &vm2);
    defer gpa.free(mid);

    // --- Restore + replay-from-cursor. `restore` rebuilds the VM fresh, so
    // `unicode_version_pinned` is false again — the derivation is what must hold.
    const vm_r = try restore(gpa, mid, chunk2.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    try testing.expect(!vm_r.unicode_version_pinned); // restore did NOT carry the flag
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.effect_mode = .replay;
    try vm_r.effect_log.appendSlice(gpa, ref.log);
    vm_r.effect_cursor = cursor_at_cut;
    vm_r.suspend_ctl = null;
    // If the derivation were wrong, the post-cut upper() would try to consume a
    // second effect and fault (log exhausted); instead it finishes cleanly.
    try testing.expect((try vm_r.exec()) == .finished);

    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.out, combined[0 .. out_before.len + sink_r.buffered().len]);
    // The single effect was consumed exactly once across the whole cut.
    try testing.expectEqual(ref.log.len, vm_r.effect_cursor);
}
