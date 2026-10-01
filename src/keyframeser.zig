//! Keyframe snapshot serialization (Phase 7 v2 — F2a) — the bridge between a
//! live VM's reachable heap graph + roots and its on-disk snapshot form.
//!
//! Mirrors `traceser.zig`: the wire format is defined once, declaratively, in
//! `schema/trace.json` (binschema); `tools/regen-trace-schema.sh` generates the
//! Zig codec into `src/gen/trace_schema.zig` (vendored, committed). We never
//! hand-write encode/decode — this module only *maps* mahina's runtime structs
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
//! `decode` therefore yields the generated schema structs, not mahina types.

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
/// v5 (H-2): `Keyframe` gained `next_obj_id` — the heap's monotonic allocation
/// counter, serialized so restore reproduces the id timeline EXACTLY even after
/// pre-cut garbage (an object allocated then dropped before the cut bumps the
/// counter but leaves no `objects` entry, so reconstructing it as max(id)+1 drifts
/// it low and diverges subsequent ids, which are observable via table/pairs order).
/// v6 (A-vi foundation): `FrameRef` gained the live vararg cursor
/// (`varargs_base`/`varargs_count`), making a keyframe captured inside an active
/// vararg callee semantically complete.
/// v7 (B-5, doc 18): the table array part became slot-0/identity-mapped —
/// `HeapTable` array entries are positional from key 0 (non-inclusive `asize`),
/// and restore validation rejects an array-covered hash key
/// (`ArrayResidentKeyInHash`-adjacent shapes; a key == asize hash resident is
/// valid). (This history line was omitted when v7 landed; recorded here.)
/// v8 (doc 19): loaded-chunk proto constants joined the `.snapshot` root walk,
/// so every loaded proto's string literal is in `objects[]` and
/// `recompileLoadedChunks` is guaranteed ZERO-allocation (enforced post-recompile
/// via `next_obj_id`; trip = `LoadedChunkRecompileAllocated`, corrupt snapshot).
/// Pre-v8 snapshots could legitimately omit a dropped loaded chunk's constants —
/// accepting one would fork the allocation timeline, hence the bump.
///
/// v9 (doc 21, the H-5(i) fix): final-state captures canonicalize every stack
/// slot outside the top-level result span (`Vm.final_cut`) to nil, in BOTH the
/// `.snapshot` root walk and the verbatim stack serialization — dead slots no
/// longer leak tier-dependent garbage (tier-0's last-iteration temps vs the
/// native exit flush's frozen pre-burst values) into the bytes or the reachable
/// set. No structural schema change; the bump exists because two encoders must
/// never emit different bytes for one logical state under one version number.
pub const snapshot_format_version: u32 = 9;

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
            const array = try a.alloc(schema.SnapValue, t.array.asize);
            // Capture emits *logical* Values via `array.get`, so the snapshot bytes
            // are independent of the in-memory lane (a packed bool/int array and an
            // unpacked `.value` array with the same logical contents serialize
            // identically). `get` is 1-based.
            for (0..t.array.asize) |i| array[i] = toSchemaValue(t.array.get(i));
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
                for (0..t.array.asize) |i| self.pushValue(t.array.get(i));
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

    // 0b. Doc 21 Phase A capture policy, computed ONCE and passed to both
    //     consumers (root walk + stack serialization) — neither re-derives VM
    //     state. At a VALIDATED final state (depth 0, a published `final_cut`
    //     whose `stack_top` still matches, in-bounds span, no open upvalues)
    //     the only live stack content is the top-level result span; every
    //     other slot is semantic garbage whose bytes are tier-dependent (the
    //     H-5(i) divergence: tier-0's last-iteration temps vs the native exit
    //     flush's frozen pre-burst values). Any validation miss → null → mask
    //     nothing (fail-safe: exactly the pre-doc-21 capture).
    const mask: ?interp.ResultSpan = blk: {
        if (vm.depth != 0) break :blk null;
        const fc = vm.final_cut orelse break :blk null;
        if (fc.stack_top != vm.stack_top) break :blk null;
        if (@as(usize, fc.result_base) + fc.result_count > vm.stack_top) break :blk null;
        // All upvalues are closed before every pop, so this is empty at any
        // genuine final state — treat a violation as invalid metadata (mask
        // nothing) rather than risk serializing an open cell's slot as nil.
        if (vm.open_upvalues.items.len != 0) break :blk null;
        break :blk .{ .base = fc.result_base, .len = fc.result_count };
    };

    // 1. Enumerate the reachable heap graph from the VM roots.
    var walk = Walk{ .a = a };
    vm.forEachRootHeader(.snapshot, mask, &walk, Walk.push);
    var i: usize = 0;
    while (i < walk.order.items.len) : (i += 1) walk.enumerateChildren(walk.order.items[i]);
    if (walk.err) |e| return e;

    // 2. Map each object to its wire form.
    const objects = try a.alloc(schema.HeapObject, walk.order.items.len);
    for (walk.order.items, 0..) |h, idx| objects[idx] = try toSchemaHeapObject(a, vm, h);

    // 3. Capture the roots verbatim (the live register window, active frames, and
    //    open upvalues — empty at final-state capture; load-bearing in F2b).
    const stack = try a.alloc(schema.SnapValue, vm.stack_top);
    for (stack, 0..) |*sv, idx| {
        // Doc 21: outside the validated final-state result span, serialize
        // canonical nil — the slot is dead and its bytes are tier noise.
        const live = if (mask) |m| (idx >= m.base and idx < @as(usize, m.base) + m.len) else true;
        sv.* = toSchemaValue(if (live) vm.regGet(idx) else Value.nil());
    }

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
        .varargs_base = @intCast(f.varargs_base),
        .varargs_count = @intCast(f.varargs_count),
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
            // The heap's monotonic allocation counter (H-2, v5): the NEXT id to
            // hand out. Serialized verbatim so restore reproduces the id timeline
            // exactly — a pre-cut allocation that was GC'd before the cut bumped
            // this but left no `objects` entry, so reconstructing it as max(id)+1
            // would drift it low and diverge every post-restore id.
            .next_obj_id = vm.heap.next_obj_id,
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

pub const RestoreError = error{
    UnsupportedVersion, // SnapshotFile.version != snapshot_format_version
    HeapNotEmpty, // restoring into a non-bare VM would collide ids/interning
    DuplicateId, // two HeapObjects share an id (corrupt snapshot)
    DuplicateInternedString, // two HeapStrings carry identical bytes (corrupt snapshot — breaks interning)
    IdSpaceExhausted, // restored ids fill the u32 space, leaving no room for recompiled chunk literals
    NextObjIdBelowObjects, // serialized next_obj_id sits at/below a restored id (corrupt — a live object can't hold an unallocated id)
    UnresolvedHeapRef, // a HeapRef / root id has no matching object
    UnknownProto, // a HeapClosure.proto_id is not in the program's proto tree
    LoadedChunkRecompileFailed, // a recorded `load` source no longer parses/compiles (corrupt snapshot)
    LoadedChunkRecompileAllocated, // recompiling loaded chunks allocated a heap object — a v8 snapshot must carry every loaded-proto literal (doc 19), so a moved counter means a forked allocation timeline (corrupt snapshot)
    UnknownNative, // a HeapNative.name is not in the native registry
    GlobalsNotATable, // globals_id resolves to a non-table object
    MetatableNotATable, // a HeapTable.metatable_id resolves to a non-table object
    ArrayResidentKeyInHash, // a hash entry's normalized integer key is array-covered (`inArray(k, asize)`, incl. float-spelled) — it would be shadowed by the array slot (corrupt/hand-forged snapshot)
    FrameNotAClosure, // a frame's closure_id resolves to a non-closure
    FrameWindowMismatch, // a frame's base != the running sum of prior register windows
    InvalidFrameVarargs, // a frame's vararg cursor is non-canonical or outside its live prefix
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

        var chunk = compiler.compileWithOptions(vm.gpa, vm.heap, owned, tree.root, &diags, .{
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

        vm.appendLoadedChunk(.{ .chunk = chunk, .source = owned }) catch |e| {
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
    // A-iv transient JIT-tiering state is deliberately outside schema v5. A
    // restore always starts with no live logical-region accumulator; execution
    // rebuilds it from the re-keyed physical activations and receipt stream.
    vm.trace.resetRegionProfit();

    // A bare VM is the contract: an empty heap means restored ids and interned
    // bytes cannot collide with pre-seeded state.
    if (vm.heap.object_count != 0 or vm.heap.next_obj_id != 0 or vm.heap.strtab_count != 0)
        return error.HeapNotEmpty;

    var idmap = IdMap.init(gpa);
    defer idmap.deinit();
    try idmap.ensureTotalCapacity(@intCast(kf.objects.len));

    // Advance the id counter past every restored id BEFORE recompiling loaded
    // chunks (L-2). Under v8 (doc 19) every loaded chunk's string literals are
    // rooted in the `.snapshot` walk, so a valid snapshot ALWAYS carries them and
    // recompile re-interns to the restored objects, allocating nothing — enforced
    // below (`LoadedChunkRecompileAllocated`). Advancing first still matters: it
    // is what makes a corrupt snapshot's illegitimate recompile allocation land
    // ABOVE the restored range (detectable) instead of colliding with it.
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
    // Restore the counter from the serialized `next_obj_id` (v5, H-2), NOT from
    // `max_id + 1`: the two are equal only when no object was allocated-then-dropped
    // before the cut. Pre-cut garbage bumps `next_obj_id` but leaves no `objects`
    // entry, so `max_id + 1` would drift the counter LOW and every post-restore id
    // would diverge (ids are observable via table/pairs order). The serialized
    // counter must sit strictly above every restored non-reserved id — a live
    // object with `id >= next_obj_id` is impossible, so reject it as corrupt.
    if (kf.next_obj_id < max_id +| 1) return error.NextObjIdBelowObjects;
    vm.heap.adoptNextId(kf.next_obj_id);

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
                // NB: deliberately NO UTF-8 validation — a legitimate snapshot
                // can carry raw non-UTF-8 bytes (a recorded invalid host input
                // parked by the effect log under validate-after-log). `create`
                // recomputes `cp_len` and the exact `str_ascii` bit from the
                // bytes, so the doc-28 ASCII fast paths stay sound regardless.
                // Re-intern: allocate the bytes and register them so later program
                // interning of the same bytes resolves to this object, and sweep
                // can de-intern it. NOT `heap.intern` — that auto-links a counter id.
                const s = try string.String.create(gpa, hs.bytes);
                errdefer s.destroy(gpa);
                // A valid snapshot interns one String per byte-sequence, so these
                // bytes must be unseen. A corrupt snapshot with two strings sharing
                // bytes (different ids) would leave two objects claiming the same
                // interned identity — silently breaking the pointer-equality
                // invariant. `internRestoredUnique` rejects that (and is failure-
                // atomic; the `errdefer s.destroy` above frees `s` on the way out).
                try vm.heap.internRestoredUnique(s);
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
                n.recorded = entry.recorded; // …and its JIT-inlinable pure-builtin tag
                // `pure ⇒ !effect` (doc 17, H-4 / 9-A(i)). The static `base_natives`
                // registry is comptime-proven in `interp.zig`; this guards a
                // caller-supplied `NativeRegistry` on the restore path.
                std.debug.assert(!(n.recorded != null and n.effect != null));
                vm.heap.linkRestored(&n.header, o.id);
                break :blk &n.header;
            },
        };
        idmap.putAssumeCapacityNoClobber(o.id, header);
    }

    // Rebuild the runtime-`load`ed chunk image (L-2): recompile each recorded
    // source so `resolveProto` can rebind a loaded `HeapClosure.proto_id` in pass
    // 1b. Deterministic recompile reproduces the same protos/ids the live VM had;
    // string literals resolve to the already-interned snapshot strings above.
    try recompileLoadedChunks(vm, root, kf.loaded_chunks);
    // v8 integrity check (doc 19): the encoder roots every loaded proto's string
    // constants in the `.snapshot` walk, and Pass 1a interned every restored
    // string (byte-keyed) before the recompile — so a valid v8 recompile resolves
    // every literal to a restored object and allocates NOTHING. A moved counter
    // means the snapshot is missing a loaded-proto literal: its allocation
    // timeline is already forked from the source VM's, so reject rather than
    // diverge silently.
    if (vm.heap.next_obj_id != kf.next_obj_id) return error.LoadedChunkRecompileAllocated;

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
                // Array part: append in order — v7 is positional 0-based (doc 18
                // D5): serialized entry `i` IS logical key / physical slot `i`,
                // holes ride in-band as nils (the ubiquitous slot-0 hole
                // included). Append starts at key 0 under identity mapping, so a
                // plain in-order append reproduces the split exactly.
                for (ht.array) |sv| try t.array.append(gpa, try fromSchemaValue(sv, &idmap));
                // Bulk lane rebuild (doc 18 D5): the appends above leave the part
                // `.value`/unfrozen even for a homogeneous narrow run — a leading
                // nil (e.g. the slot-0 hole) defeats append's eager first-value
                // lane commit. Left that way, a restored sieve loses its narrow
                // lane's density and per-element codegen (doc 32 made `.value`
                // int/float scalars recordable, so it is no longer *untraceable*
                // — but a `.value` element still costs a tag check per access
                // and a whole 16-byte cell per slot), and a restored deflated
                // grid can never re-inflate (inflation requires packed numeric
                // rows).
                // Recompute the optimal lane over the present values exactly as
                // rehash's one-shot commit does: narrow → repack + freeze
                // (monotonic from here); `.value` → stay unfrozen so a later
                // rehash may still narrow. In-memory only: invisible to logical
                // values and to a re-capture, so determinism is untouched.
                if (t.array.asize > 0 and !t.array.frozen) {
                    const lane = t.array.optimalLane();
                    if (lane.isNarrow()) {
                        try t.array.repack(gpa, lane);
                        t.array.frozen = true;
                    }
                }
                // Hash part: straight into the hash, preserving the recorded
                // split — but never an array-covered key (v7 validation): such an
                // entry would be permanently shadowed by the array slot on every
                // read, a state no capture can produce.
                for (ht.entries) |e| {
                    const k = try fromSchemaValue(e.key, &idmap);
                    const v = try fromSchemaValue(e.val, &idmap);
                    const nk = table.normalizeKey(k);
                    if (nk.isInt() and arr.ArrayPart.inArray(nk.asInt(), t.array.asize))
                        return error.ArrayResidentKeyInHash;
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
    // Doc 43 §3.2 (P0b): restore reseats the globals table at a new address, so
    // refresh the recorder's globals-header channel to match (a trace recorded
    // after a restore must compare stores against the live table).
    vm.trace.rec_globals_header = &vm.globals.header;

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
        if (fr.varargs_count == 0) {
            if (fr.varargs_base != 0) return error.InvalidFrameVarargs;
        } else {
            if (!cl.proto.is_vararg) return error.InvalidFrameVarargs;
            const varargs_end = std.math.add(u32, fr.varargs_base, fr.varargs_count) catch
                return error.InvalidFrameVarargs;
            if (varargs_end > fr.base or varargs_end > kf.stack.len)
                return error.InvalidFrameVarargs;
        }
        // Restore through the same physical-frame choke point as live calls, so
        // the vararg cursor, stack window, call_seq, and region context cannot
        // drift from normal frame construction. Only the resumable pc is a
        // restore-specific overwrite.
        vm.pushFrameVararg(
            cl,
            fr.base,
            fr.ret_dest,
            fr.ret_count,
            fr.varargs_base,
            fr.varargs_count,
        ) catch return error.TooManyFrames;
        vm.frames[i].pc = fr.pc;
        expected_base += cl.proto.num_registers;
    }
    // `pushFrameVararg` raises this to each physical window end. The serialized
    // live prefix may additionally contain caller-owned argument/vararg slots
    // (and structural test snapshots can use zero-register frames), so restore
    // the authoritative captured top after all frame pushes.
    vm.stack_top = kf.stack.len;

    for (kf.open_upvalues) |ou| {
        const uh = idmap.get(ou.upvalue_id) orelse return error.UnresolvedHeapRef;
        if (uh.type != .upvalue) return error.UpvalueNotAnUpvalue;
        if (ou.stack_index >= vm.stack_top) return error.StackIndexOutOfRange;
        const cell = function.Upvalue.fromHeader(uh);
        // Switch the cell from its closed placeholder to open over the live slot.
        cell.loc = .{ .open = ou.stack_index };
        // Doc 54 P1: through the centralized method, so the rebuilt list
        // republishes `open_upvalue_ceiling` as it grows (round-1 blocker 5:
        // a restore that bypassed the ceiling would leave it stale-LOW).
        try vm.appendOpenUpvalue(ou.stack_index, cell);
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
//
// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only
// analyses a file that is reachable by import, so this block is what makes them
// run under `zig build test`.

test {
    _ = @import("keyframeser_capture_test.zig");
    _ = @import("keyframeser_restore_test.zig");
    _ = @import("keyframeser_resume_test.zig");
    _ = @import("keyframeser_replay_test.zig");
    _ = @import("keyframeser_unicode_test.zig");
}
