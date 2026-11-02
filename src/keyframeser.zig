//! Keyframe snapshot serialization (Phase 7 v2 — F2a) — the bridge between a
//! live VM's heap + roots and its on-disk snapshot form.
//!
//! Mirrors `traceser.zig`: the wire format is defined once, declaratively, in
//! `schema/trace.json` (binschema); `tools/regen-trace-schema.sh` generates the
//! Zig codec into `src/gen/trace_schema.zig` (vendored, committed). We never
//! hand-write encode/decode — this module only *maps* mahina's runtime structs
//! onto the generated schema structs.
//!
//! A keyframe is "the whole VM state at a moment": a flat array of every
//! unswept heap object (keyed by its stable `GcHeader.id`, never an address)
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
const system = @import("system.zig");
const filemod = @import("file.zig");
const File = filemod.File;
const coroutine = @import("coroutine.zig");
const native_act = @import("native_act.zig");
const stdaio = @import("stdlib/aio.zig");
const Thread = coroutine.Thread;

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
///
/// v10 (doc 61 Phase K): `objects` is every unswept object in ascending id
/// order, not the reachable set; `next_gc` is new; `stack` is `StackValue`,
/// where a slot dead at capture (outside the collector's keep set, or outside
/// the v9 result span at a final state) is a `DeadSlot` tombstone, not nil.
/// `HeapTable` carries its array part physically — `lane`, `flags` (frozen,
/// no_grid) and a live grid as `grid` — so capture no longer deflates grids and
/// restore reproduces the representation that decides later inflation.
///
/// v11 (doc 68 §5): `FrameRef` gained `ctl`, the frame's `FrameCtl` byte. A
/// `pcall`/`xpcall` of a Lua function runs it in a frame tagged
/// `ctl.protect`, and without the tag a restored VM would not catch the
/// errors raised under it. Only `protect` may be set yet, and never on the
/// bottom frame.
///
/// v12 (doc 65 §4.1): file handles. `HeapObject` gained `HeapFile` (obj_type
/// 7: the handle id, kind, packed mode, closed flag, path, and the host's
/// fingerprint of an open file captured live), and `Keyframe` the file
/// metatable, the default input and output handles (1-based optional ids)
/// and `next_file_id`.
///
/// v13 (doc 73): coroutines. `HeapObject` gained `HeapThread` (obj_type 8:
/// kind, status, body, resumer, death, the resume and yield wiring, and the
/// saved stack of one that isn't running as a `ThreadContext`). v13 captured
/// only while no coroutine ran.
///
/// v14 (doc 73): a stop inside a coroutine. `Keyframe` gained `current_id`,
/// the running coroutine (1-based optional id), and `main_context`, the main
/// stack while a coroutine runs; the running and normal coroutines carry
/// their resumer and resume wiring.
///
/// v15 (doc 73): `Keyframe.next_gc` became `gc_target`, the collection
/// target in pacing units: coroutine stacks are charged against it, and the
/// live-object threshold is derived from it and the restored stacks'
/// charge (it can't be the other way round, the threshold saturates).
///
/// v16 (doc 73): `coroutine.wrap`. `HeapNative` gained `bound`, the values
/// bound to the native (a wrap function's coroutine), and `HeapThread`
/// `wrapped`, set while its resume is a wrap function's call.
///
/// v17 (doc 73 §7): `Keyframe.task_lib_id`, the task library's function
/// table, a VM-level root (1-based optional id).
///
/// v18 (doc 73 §7.6): `Keyframe.aio_ops_id`, the `aio` operations in
/// flight (a VM-level root, 1-based optional id), and `aio_next_id`, the
/// next operation id.
///
/// v19 (doc 76 §5): `HeapTable.flags` bit 2, `readonly`: a table
/// `table.freeze` froze, so a restored session refuses the same stores. The
/// field is unchanged; an older reader would drop the bit.
///
/// v20 (doc 68 P2): `FrameRef.ctl` may carry `cont = .finish_op` and its
/// `phase`: a metamethod's frame, whose return finishes the instruction its
/// caller is at (in flight there, re-derived on restore). Its `ret_dest`
/// and `ret_count` are the continuation's payload (a `close`'s cursor and
/// `return f()` span), not return wiring. The field is unchanged; an older
/// reader would refuse the bits.
pub const snapshot_format_version: u32 = 20;

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
        // on opcode boundaries (safepoints), and a grid's cells are scalars read
        // through `gridGet` (`toSchemaGrid`), so nothing can hand us one here.
        .row_view => unreachable,
    };
}

/// `HeapTable.flags` bits.
const table_flag_frozen: u8 = 1 << 0;
const table_flag_no_grid: u8 = 1 << 1;
/// The table's `GcFlags.readonly` (doc 76 §5), not its array part's `frozen`.
const table_flag_readonly: u8 = 1 << 2;

/// A grid array part on the wire: every `rows × stride` cell, row-major.
fn toSchemaGrid(a: std.mem.Allocator, ap: *const arr.ArrayPart) !schema.GridPart {
    const rows = ap.gridRows();
    const row_len = try a.alloc(u32, rows);
    for (row_len, 0..) |*rl, r| rl.* = @intCast(ap.gridRowLen(r));
    const cells = try a.alloc(schema.SnapValue, rows * ap.stride);
    for (0..rows) |r| {
        for (0..ap.stride) |c| cells[r * ap.stride + c] = toSchemaValue(ap.gridGet(r, c));
    }
    return .{ .elem = @intFromEnum(ap.grid_elem), .stride = @intCast(ap.stride), .row_len = row_len, .cells = cells };
}

/// Rebuild a grid array part from the wire (doc 61 Phase K). Every cell must
/// fit the cell lane and lie within its row's logical length; the grid's
/// rows own keys `1..rows`, with no slot 0 (doc 18 D6).
fn fromSchemaGrid(gpa: std.mem.Allocator, g: schema.GridPart) RestoreError!arr.ArrayPart {
    const elem = std.enums.fromInt(arr.Lane, g.elem) orelse return error.InvalidTableLane;
    if (elem == .grid or !elem.usesPresenceBitmap()) return error.InvalidTableLane;
    const rows = g.row_len.len;
    if (g.stride == 0) return error.InvalidTableLane;
    const ncells = std.math.mul(usize, rows, g.stride) catch return error.InvalidTableLane;
    if (g.cells.len != ncells) return error.InvalidTableLane;
    var ap = try arr.ArrayPart.initGrid(gpa, rows, g.stride, elem);
    errdefer ap.deinit(gpa);
    for (g.row_len, 0..) |rl, r| {
        if (rl > g.stride) return error.InvalidTableLane;
        for (0..g.stride) |c| {
            const v: Value = switch (g.cells[r * g.stride + c].body) {
                .ConstNil => continue,
                .ConstInt => |x| Value.int(x.v),
                .ConstFloat => |x| Value.float(x.v),
                .ConstBool, .HeapRef => return error.InvalidTableLane,
            };
            if (c >= rl or !arr.ArrayPart.laneFits(elem, v)) return error.InvalidTableLane;
            ap.gridSet(r, c, v);
        }
        // A nil store never shrinks a row, so its length can exceed its last
        // present cell; carry it verbatim.
        ap.row_len.?[r] = rl;
    }
    return ap;
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
    while (it.next()) |e| : (i += 1) kvs[i] = .{ .key = e.key, .val = e.value_ptr.* };
    // Keys are distinct, so the order is total and an unstable sort is exact.
    std.mem.sortUnstable(HashKV, kvs, {}, HashKV.lessThan);
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
///
/// `live` is the host system when the capture is live (`off`/`record`): an
/// open file's fingerprint is then the host's view of it now (doc 65 Q7).
/// Otherwise a file carries the fingerprint it was restored with, if any.
/// A coroutine's stack is read through `vm` (`toSchemaThread`).
pub fn toSchemaHeapObject(a: std.mem.Allocator, vm: *Vm, h: *GcHeader, live: ?system.HostSystem) !schema.HeapObject {
    const Body = schema.BsUnion_HeapString_HeapTable_HeapClosure_HeapNative_HeapUpvalue_HeapFile_HeapThread;
    const body: Body = switch (h.type) {
        .string => .{ .HeapString = .{ .bytes = string.String.fromHeader(h).bytes() } },
        .table => blk: {
            const t = table.Table.fromHeader(h);
            // Values are logical (`array.get`), and the lane rides beside them
            // (doc 61 Phase K): it decides later grid inflation, hence later
            // allocations, so restore must reproduce it. A grid is carried as
            // a grid, with an empty `array`.
            var array: []schema.SnapValue = &.{};
            var grid: []schema.GridPart = &.{};
            if (t.array.isGrid()) {
                grid = try a.alloc(schema.GridPart, 1);
                grid[0] = try toSchemaGrid(a, &t.array);
            } else {
                array = try a.alloc(schema.SnapValue, t.array.asize);
                for (0..t.array.asize) |i| array[i] = toSchemaValue(t.array.get(i));
            }
            var flags: u8 = 0;
            if (t.array.frozen) flags |= table_flag_frozen;
            if (t.no_grid) flags |= table_flag_no_grid;
            if (t.isReadonly()) flags |= table_flag_readonly;
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
            break :blk .{ .HeapTable = .{
                .array = array,
                .entries = entries,
                .metatable_id = mt_id,
                .lane = @intFromEnum(t.array.lane),
                .flags = flags,
                .rehash_threshold = t.rehash_threshold,
                .grid = grid,
            } };
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
            break :blk .{ .HeapUpvalue = .{ .closed = @intFromBool(is_closed), .value = toSchemaValue(u.get()) } };
        },
        .native => blk: {
            const n = function.Native.fromHeader(h);
            const bound = try a.alloc(schema.SnapValue, n.bound.len);
            for (n.bound, bound) |v, *s| s.* = toSchemaValue(v);
            break :blk .{ .HeapNative = .{ .name = n.name, .bound = bound } };
        },
        .file => blk: {
            const f = File.fromHeader(h);
            var fp = f.fingerprint;
            if (live) |sys| {
                if (f.kind == .file and !f.closed and !f.detached) {
                    if (sys.vtable.fingerprint) |get| fp = get(sys.ctx, f.id);
                }
            }
            const fps: []schema.FileFingerprint = if (fp) |x| blk2: {
                const one = try a.alloc(schema.FileFingerprint, 1);
                one[0] = .{ .size = x.size, .mtime_ns = x.mtime_ns, .position = x.position };
                break :blk2 one;
            } else &.{};
            break :blk .{ .HeapFile = .{
                .file_id = f.id,
                .kind = @intFromEnum(f.kind),
                .mode = filemod.packMode(f.mode),
                .closed = @intFromBool(f.closed),
                .path = f.path,
                .fingerprint = fps,
            } };
        },
        .thread => .{ .HeapThread = try toSchemaThread(a, vm, Thread.fromHeader(h)) },
        else => return error.UnsupportedObject, // typed_array / host: no F2a variant
    };
    return .{ .id = h.id, .obj_type = @intFromEnum(h.type), .body = body };
}

/// `HeapThread.kind`.
const thread_kind_coroutine: u8 = 0;
const thread_kind_main: u8 = 1;

/// A coroutine on the wire (doc 73). A stack that isn't running is captured
/// by loading it into `vm` as a collection walks it (`Vm.walkSavedStacks`),
/// so its keep set is the collector's; the running state is put back before
/// this returns. The resume and yield wiring is written only where the
/// status gives it a meaning, so the bytes don't carry what a past resume
/// left behind.
fn toSchemaThread(a: std.mem.Allocator, vm: *Vm, t: *Thread) !schema.HeapThread {
    var context: []schema.ThreadContext = &.{};
    if (t.stack != null and t.status != .running) {
        context = try a.alloc(schema.ThreadContext, 1);
        var running: coroutine.SavedContext = undefined;
        coroutine.save(vm, &running);
        defer coroutine.load(vm, &running);
        coroutine.load(vm, &t.saved);
        context[0] = try captureContext(a, vm);
    }
    const death: []schema.SnapValue = if (t.death) |d| blk: {
        const one = try a.alloc(schema.SnapValue, 1);
        one[0] = toSchemaValue(d);
        break :blk one;
    } else &.{};
    const wired = t.status == .running or t.status == .normal;
    // Resumed from Zig: that frame is above the capture, which refuses to
    // run inside one (`encodeSnapshot`), so no chain member can be.
    if (wired and t.sync) return error.CaptureInsideNativeActivation;
    const at_yield = t.status == .suspended and t.stack != null and t.saved.depth > 0;
    return .{
        .kind = if (vm.main_thread == t) thread_kind_main else thread_kind_coroutine,
        .status = @intFromEnum(t.status),
        .body = toSchemaValue(t.body),
        .resumer_id = if (t.resumer) |r| r.header.id + 1 else 0,
        .death = death,
        .ret_lo = if (wired) @intCast(t.ret_lo) else 0,
        .ret_c = if (wired) t.ret_c else 0,
        .wrapped = @intFromBool(wired and t.wrapped),
        .yield_lo = if (at_yield) @intCast(t.yield_lo) else 0,
        .yield_c = if (at_yield) t.yield_c else 0,
        .has_stack = @intFromBool(t.stack != null),
        .context = context,
    };
}

/// The loaded stack on the wire: the registers the collector's keep set
/// names (`Vm.fillKeep`, doc 61 Phase K), every other slot a tombstone; the
/// frames with their resumable cursors (F2c); the open upvalues.
fn captureContext(a: std.mem.Allocator, vm: *const Vm) !schema.ThreadContext {
    // Dead slots are where a JIT run can differ from tier-0 between
    // collections, so dropping them makes the bytes tier-identical. At a
    // validated final state (doc 21 Phase A) the keep set is the top-level
    // result span; otherwise frame masks, varargs spans, open-upvalue slots,
    // and every gap and unmasked window whole.
    const keep = try a.alloc(u64, (vm.stack_top + 63) / 64);
    vm.fillKeep(keep);
    const stack = try a.alloc(schema.StackValue, vm.stack_top);
    for (stack, 0..) |*sv, idx| {
        const kept = (keep[idx / 64] >> @intCast(idx % 64)) & 1 != 0;
        sv.* = toStackValue(vm.regGet(idx), kept);
    }

    // Each frame's resumable cursor (pc/base/return-wiring), not just the
    // closure id — this is what makes a mid-execution snapshot re-executable
    // (F2c). At final-state capture `vm.depth == 0`, so this is empty.
    const frames = try a.alloc(schema.FrameRef, vm.depth);
    for (vm.frames[0..vm.depth], 0..) |f, idx| frames[idx] = .{
        .closure_id = f.closure.header.id,
        .pc = @intCast(f.pc),
        .base = @intCast(f.base),
        .ret_dest = f.ret_dest,
        .ret_count = f.ret_count,
        .varargs_base = @intCast(f.varargs_base),
        .varargs_count = @intCast(f.varargs_count),
        .ctl = @bitCast(f.ctl),
    };

    const open = try a.alloc(schema.OpenUpvalueRef, vm.open_upvalues.items.len);
    for (vm.open_upvalues.items, 0..) |ou, idx| open[idx] = .{
        .stack_index = @intCast(ou.index),
        .upvalue_id = ou.cell.header.id,
    };
    return .{ .stack = stack, .frames = frames, .open_upvalues = open };
}

fn idLessThan(_: void, x: *GcHeader, y: *GcHeader) bool {
    return x.id < y.id;
}

/// Every unswept object on the heap, in ascending id order (doc 61 Phase K).
/// Sorted rather than read off the sweep list, because restore links objects
/// in its own pass order, so list order is not a function of the state.
fn heapObjectsById(a: std.mem.Allocator, heap: *const gc.Heap) ![]*GcHeader {
    const all = try a.alloc(*GcHeader, heap.object_count);
    var n: usize = 0;
    var it = heap.objects;
    while (it) |h| : (it = h.next) {
        all[n] = h;
        n += 1;
    }
    std.debug.assert(n == all.len);
    // Ids are unique, so an unstable sort is exact. The sweep list is close
    // to reverse allocation order, a run pdq detects in linear time.
    std.mem.sortUnstable(*GcHeader, all, {}, idLessThan);
    return all;
}

/// A register's wire form: its value, or a tombstone when capture dropped it.
fn toStackValue(v: Value, kept: bool) schema.StackValue {
    return if (kept) stackValueOf(toSchemaValue(v)) else dead_slot;
}

/// A `DeadSlot` register tombstone.
pub const dead_slot: schema.StackValue = .{ .tag = dead_slot_tag, .body = .{ .DeadSlot = .{ .pad = 0 } } };

/// A `SnapValue` as a register: the same tag and body.
pub fn stackValueOf(sv: schema.SnapValue) schema.StackValue {
    return .{ .tag = sv.tag, .body = switch (sv.body) {
        .ConstNil => |x| .{ .ConstNil = x },
        .ConstBool => |x| .{ .ConstBool = x },
        .ConstInt => |x| .{ .ConstInt = x },
        .ConstFloat => |x| .{ .ConstFloat = x },
        .HeapRef => |x| .{ .HeapRef = x },
    } };
}

/// `StackValue.tag` of a `DeadSlot` tombstone, outside the `Value.Tag` space.
pub const dead_slot_tag: u8 = 255;

/// Serialize the whole live VM to a keyframe snapshot (a versioned
/// `SnapshotFile`). The returned slice is owned by `gpa` (caller frees);
/// intermediate schema structs live in an arena freed before return. The VM
/// must be alive (the mapping borrows live string bytes). Carries every
/// unswept heap object and the live register window with dead slots
/// tombstoned (doc 61 Phase K).
pub fn encodeSnapshot(gpa: std.mem.Allocator, vm: *Vm) ![]u8 {
    // Doc 61 P4: capture happens at suspend boundaries only, never inside a
    // native activation, whether called from bytecode or re-entered through
    // `callValue`. Its frame is mid-instruction (in flight, §4.2) and Zig code
    // above it holds state no keyframe can carry, so its frames cannot be
    // resumed. The one frame in flight a keyframe can carry is the parent of
    // a metamethod's `.finish_op` frame (doc 68 P2), whose instruction the
    // frame's return finishes from the canonical code. That keeps `in_flight`
    // out of the format: restore re-derives it from the frame above. A real
    // error, not an assert: release builds refuse it.
    if (vm.native_reentry_depth != 0) return error.CaptureInsideNativeActivation;
    for (vm.frames[0..vm.depth], 0..) |*fr, i| {
        if (fr.in_flight and !(i + 1 < vm.depth and vm.frames[i + 1].ctl.cont == .finish_op))
            return error.CaptureInsideNativeActivation;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Capture leaves the VM as it found it (doc 61 Phase K: grids are
    // carried as grids, so nothing deflates). A coroutine's stack is read by
    // loading it for the moment (`toSchemaThread`).
    //
    // 1. Every unswept object, garbage included (doc 61 Phase K). Allocation
    //    and collection points are tier-identical, and only registers can be
    //    stale, so this set is too. Carrying the garbage is what lets a
    //    restored VM get the same intern hits and collect at the same points
    //    (with `gc_target`) as the uninterrupted run.
    const all = try heapObjectsById(a, vm.heap);
    const objects = try a.alloc(schema.HeapObject, all.len);
    const live: ?system.HostSystem = if (vm.effect_mode == .replay) null else vm.system;
    for (all, 0..) |h, idx| objects[idx] = try toSchemaHeapObject(a, vm, h, live);

    // 2. The running stack: its kept registers (doc 61 Phase K), frames and
    //    open upvalues. With a coroutine running (doc 73), the main stack is
    //    a saved one, captured with it loaded, as a coroutine's is.
    const running = try captureContext(a, vm);
    var main_context: []schema.ThreadContext = &.{};
    if (vm.current != null) {
        main_context = try a.alloc(schema.ThreadContext, 1);
        var saved_running: coroutine.SavedContext = undefined;
        coroutine.save(vm, &saved_running);
        defer coroutine.load(vm, &saved_running);
        coroutine.load(vm, &vm.main_saved);
        main_context[0] = try captureContext(a, vm);
    }

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
            // Doc 65: the file metatable and the default input/output, VM-level
            // roots like the string metatable (1-based optional ids).
            .file_metatable_id = if (vm.file_metatable) |t| t.header.id + 1 else 0,
            .io_input_id = if (vm.io_input) |f| f.header.id + 1 else 0,
            .io_output_id = if (vm.io_output) |f| f.header.id + 1 else 0,
            .next_file_id = vm.next_file_id,
            // The heap's monotonic allocation counter (H-2, v5): the NEXT id to
            // hand out. Serialized verbatim so restore reproduces the id timeline
            // exactly — a pre-cut allocation that was GC'd before the cut bumped
            // this but left no `objects` entry, so reconstructing it as max(id)+1
            // would drift it low and diverge every post-restore id.
            .next_obj_id = vm.heap.next_obj_id,
            // Doc 61 Phase K: the collection threshold, so a restored VM
            // collects at the same allocation as the uninterrupted run.
            .gc_target = vm.heap.gc_target,
            .objects = objects,
            .stack = running.stack,
            .frames = running.frames,
            .open_upvalues = running.open_upvalues,
            .loaded_chunks = loaded,
            .current_id = if (vm.current) |t| t.header.id + 1 else 0,
            .main_context = main_context,
            .task_lib_id = if (vm.task_lib) |t| t.header.id + 1 else 0,
            .aio_ops_id = if (vm.aio_ops) |t| t.header.id + 1 else 0,
            .aio_next_id = vm.aio_next_id,
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
    RootRecompileFailed, // the program source passed to restore doesn't parse/compile
    ImageHasHeapConstants, // a borrowed `Program.image` holds a heap constant, which would live in another heap
    RecompileAllocated, // recompiling the program or a loaded chunk allocated a heap object — a snapshot carries every program and loaded-proto literal (doc 19), so a moved counter means a forked allocation timeline (corrupt snapshot, or not this program's)
    UnknownNative, // a HeapNative.name is not in the native registry
    InvalidNative, // a HeapNative's bound values are not the ones its registry row binds
    DuplicateLibNative, // two HeapNatives fill one `Vm.lib_natives` slot
    MissingLibNative, // a real run's snapshot (metatable support built) lacks a `Vm.lib_natives` native
    GlobalsNotATable, // globals_id resolves to a non-table object
    MetatableNotATable, // a HeapTable.metatable_id resolves to a non-table object
    ArrayResidentKeyInHash, // a hash entry's normalized integer key is array-covered (`inArray(k, asize)`, incl. float-spelled) — it would be shadowed by the array slot (corrupt/hand-forged snapshot)
    FrameNotAClosure, // a frame's closure_id resolves to a non-closure
    FrameWindowMismatch, // a frame's base != the running sum of prior register windows
    InvalidFrameVarargs, // a frame's vararg cursor is non-canonical or outside its live prefix
    InvalidFrameCtl, // a frame's control byte sets more than a known `protect` tag, or tags the bottom frame
    UpvalueNotAnUpvalue, // a closure/open-upvalue id resolves to a non-upvalue
    StackTooLarge, // the snapshot stack exceeds the VM's register window
    TooManyFrames, // the snapshot frame count exceeds max_call_depth
    StackIndexOutOfRange, // an open upvalue points past the live stack window
    InvalidTombstones, // a tombstone in a slot the restored keep set requires, or a depth-0 stack whose kept registers are not one contiguous result span
    InvalidTableLane, // a table's lane/grid does not describe its values (unknown lane, a value that does not fit, a malformed grid)
    InvalidRehashThreshold, // a table's rehash trigger is below 4 or past usize
    InvalidFile, // a file handle's kind or mode byte is not one the encoder writes, or it has more than one fingerprint
    FileRootNotAFile, // io_input_id / io_output_id resolves to a non-file object
    InvalidTaskLib, // task_lib_id resolves to something other than a table whose first entry is a closure of a loaded chunk
    InvalidAioOps, // aio_ops_id resolves to a non-table, or one holding something other than an operation record under an id below aio_next_id (or aio_next_id is 0)
    NextFileIdBelowFiles, // next_file_id is at or below a restored file's id, or below the standard streams' 3
    InvalidThread, // a coroutine record no capture writes: an unknown kind or status, a stack that doesn't match the status, a running coroutine or a resumer (v13 captures only with none running), a second main thread, a non-function body
    UpvalueOpenTwice, // an open upvalue cell appears in two open lists
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

/// The depth-0 final cut a tombstoned stack describes: the one contiguous run
/// of kept registers (the result span). Null when nothing is tombstoned (no
/// cut was captured). Kept registers split by a tombstone cannot come from a
/// capture. An all-tombstone stack had an empty span, whose base is not in
/// the bytes; 0 recaptures identically.
fn finalCutFromStack(stack: []const schema.StackValue) RestoreError!?interp.FinalCut {
    var lo: ?usize = null;
    var hi: usize = 0;
    var any_dead = false;
    for (stack, 0..) |sv, i| {
        if (sv.body == .DeadSlot) {
            any_dead = true;
            continue;
        }
        if (lo == null) lo = i else if (hi != i) return error.InvalidTombstones;
        hi = i + 1;
    }
    if (!any_dead) return null;
    const base = lo orelse 0;
    return .{ .result_base = @intCast(base), .result_count = @intCast(hi -| base), .stack_top = @intCast(stack.len) };
}

/// A register on restore. A tombstone becomes nil, so it never enters a
/// running VM: the slot is dead, written before any read on every path.
fn fromStackValue(sv: schema.StackValue, idmap: *const IdMap) RestoreError!Value {
    return switch (sv.body) {
        .ConstNil, .DeadSlot => Value.nil(),
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
fn resolveProto(root: *const Proto, vm: *Vm, id: u32) std.mem.Allocator.Error!?*const Proto {
    // Doc 73: the frame a native-body coroutine runs its native from.
    if (id == coroutine.native_body_proto_id) return vm.nativeBodyProto() catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // compiling it raises nothing else
    };
    // Doc 68 §5.1: a resumable native's activation.
    if (native_act.kindOfId(id)) |kind| return native_act.protoOf(kind);
    if (findProto(root, id)) |p| return p;
    for (vm.loaded_chunks.items) |lc| if (findProto(lc.chunk.proto, id)) |p| return p;
    return null;
}

/// The root program's proto tree in `vm`: a source recompiled into it
/// (`Vm.root_chunk`), or a constant-free image borrowed as is.
fn recompileRoot(vm: *Vm, program: Program) RestoreError!*const Proto {
    const src = switch (program) {
        .image => |p| {
            if (hasHeapConstants(p)) return error.ImageHasHeapConstants;
            return p;
        },
        .source => |s| s,
    };
    const owned = try vm.gpa.dupeSentinel(u8, src.text, 0);
    var diags = diag.Diagnostics.init(vm.gpa);
    defer diags.deinit();
    var tree = parser.parse(vm.gpa, owned, &diags) catch |e| {
        vm.gpa.free(owned);
        return if (e == error.OutOfMemory) error.OutOfMemory else error.RootRecompileFailed;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        vm.gpa.free(owned);
        return error.RootRecompileFailed;
    }
    var chunk = compiler.compileWithOptions(vm.gpa, vm.heap, owned, tree.root, &diags, src.options) catch |e| {
        vm.gpa.free(owned);
        return if (e == error.OutOfMemory) error.OutOfMemory else error.RootRecompileFailed;
    };
    if (diags.hasErrors()) {
        chunk.deinit();
        vm.gpa.free(owned);
        return error.RootRecompileFailed;
    }
    vm.adoptRootChunk(.{ .chunk = chunk, .source = owned });
    return chunk.proto;
}

fn hasHeapConstants(p: *const Proto) bool {
    for (p.constants) |c| if (c.isHeap()) return true;
    for (p.protos) |child| if (hasHeapConstants(child)) return true;
    return false;
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
            .chunk_name = lc.name,
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

/// A 1-based optional file root id (`io_input_id`/`io_output_id`).
fn fileRoot(idmap: *const IdMap, id1: u32) RestoreError!?*File {
    if (id1 == 0) return null;
    const h = idmap.get(id1 - 1) orelse return error.UnresolvedHeapRef;
    if (h.type != .file) return error.FileRootNotAFile;
    return File.fromHeader(h);
}

/// A `HeapThread` whose fields agree with each other, as capture writes
/// them: the running coroutine (`is_current`) owns a stack but carries none,
/// being the keyframe's own; a normal or suspended one carries its stack; a
/// dead one has none. Only running and normal ones have a resumer and
/// resume wiring (`checkResumerChain` checks they form one chain). The main
/// thread object has no stack and a fixed status.
fn checkThreadShape(ht: schema.HeapThread, is_current: bool) RestoreError!void {
    if (ht.has_stack > 1 or ht.death.len > 1 or ht.context.len > 1) return error.InvalidThread;
    const status = std.enums.fromInt(Thread.Status, ht.status) orelse return error.InvalidThread;
    const wired = ht.kind == thread_kind_coroutine and (status == .running or status == .normal);
    if (!wired and (ht.resumer_id != 0 or ht.ret_lo != 0 or ht.ret_c != 0 or ht.wrapped != 0)) return error.InvalidThread;
    if (ht.wrapped > 1) return error.InvalidThread;
    switch (ht.kind) {
        thread_kind_main => if (is_current or status != .running or ht.has_stack != 0 or ht.context.len != 0 or ht.death.len != 0)
            return error.InvalidThread,
        thread_kind_coroutine => {
            if ((status == .running) != is_current) return error.InvalidThread;
            const want_context: u8 = switch (status) {
                .running, .dead => 0,
                .normal, .suspended => 1,
            };
            if (ht.has_stack != @intFromBool(status != .dead) or ht.context.len != want_context) return error.InvalidThread;
            if (status != .dead and ht.death.len != 0) return error.InvalidThread;
            // Only a coroutine stopped at a yield takes values there.
            const at_yield = status == .suspended and ht.context[0].frames.len != 0;
            if (!at_yield and (ht.yield_lo != 0 or ht.yield_c != 0)) return error.InvalidThread;
        },
        else => return error.InvalidThread,
    }
}

/// With a coroutine running (`current`), the running one and every normal
/// one form one chain through `resumer` that ends at the main stack; with
/// none, no coroutine is normal. Run after pass 2 wired the edges.
fn checkResumerChain(kf: schema.Keyframe, current: ?*Thread) RestoreError!void {
    var normal: usize = 0;
    for (kf.objects) |o| {
        if (o.body == .HeapThread and o.body.HeapThread.status == @intFromEnum(Thread.Status.normal)) normal += 1;
    }
    var t = current orelse return if (normal == 0) {} else error.InvalidThread;
    var waiting: usize = 0;
    while (t.resumer) |r| : (t = r) {
        // Each step reaches a distinct normal coroutine, so a cycle runs
        // past the count.
        if (r.status != .normal) return error.InvalidThread;
        waiting += 1;
        if (waiting > normal) return error.InvalidThread;
    }
    if (waiting != normal) return error.InvalidThread;
}

/// Rebuild the loaded stack from `ctx`: its registers, its frames through the
/// live call path, its open upvalues (whose `owner` becomes `owner`), then
/// check its tombstones against the keep set the restored state derives.
/// `owner` is null for the running (main) stack, which alone may hold a
/// final cut.
fn restoreContext(vm: *Vm, ctx: schema.ThreadContext, idmap: *const IdMap, owner: ?*Thread) RestoreError!void {
    if (ctx.stack.len > vm.regCapacity()) return error.StackTooLarge;
    for (ctx.stack, 0..) |sv, i| vm.regSet(i, try fromStackValue(sv, idmap));
    vm.stack_top = ctx.stack.len;

    if (ctx.frames.len > vm.frames.len) return error.TooManyFrames;
    var expected_base: usize = 0;
    for (ctx.frames, 0..) |fr, i| {
        const fh = idmap.get(fr.closure_id) orelse return error.UnresolvedHeapRef;
        if (fh.type != .function) return error.FrameNotAClosure;
        const cl = function.Closure.fromHeader(fh);
        // Doc 68 §5: a protected call's tag, or (P2) a metamethod's
        // `.finish_op` continuation with its phase; never both, and neither
        // on the bottom frame, which has no caller. The caller of a
        // continuation must be at an instruction `finishOp` completes.
        // Checked on the raw bits: an out-of-range tag is no enum value.
        const protect_off = @bitOffsetOf(interp.FrameCtl, "protect");
        const cont_off = @bitOffsetOf(interp.FrameCtl, "cont");
        const phase_off = @bitOffsetOf(interp.FrameCtl, "phase");
        const protect_bits = (fr.ctl >> protect_off) & 0b11;
        const cont_bits = (fr.ctl >> cont_off) & 0b11;
        const phase_bit = (fr.ctl >> phase_off) & 0b1;
        const known = (@as(u8, 0b11) << protect_off) | (@as(u8, 0b11) << cont_off) | (@as(u8, 0b1) << phase_off);
        const finish = cont_bits == @intFromEnum(interp.Cont.finish_op);
        if (fr.ctl & ~known != 0 or
            protect_bits > @intFromEnum(interp.Protect.xpcall) or
            (cont_bits != 0 and !finish) or
            (phase_bit != 0 and !finish) or
            (finish and protect_bits != 0) or
            (i == 0 and fr.ctl != 0)) return error.InvalidFrameCtl;
        if (finish) {
            const caller = ctx.frames[i - 1];
            const caller_cl = function.Closure.fromHeader(idmap.get(caller.closure_id).?);
            if (caller.pc >= caller_cl.proto.code.len or !interp.Vm.finishesOp(caller_cl.proto.code[caller.pc].op))
                return error.InvalidFrameCtl;
        }
        const ctl: interp.FrameCtl = .{
            .protect = @enumFromInt(protect_bits),
            .cont = @enumFromInt(cont_bits),
            .phase = @intCast(phase_bit),
        };
        // Frame windows are ordered, non-overlapping and in bounds, starting
        // at 0. Usually they are contiguous, but a callee whose dynamic
        // argument span ran past its caller's window sits above that span
        // (doc 61 P1), leaving a gap that holds the span. Anything else is a
        // corrupt/incompatible snapshot (and would make resume read the wrong
        // registers).
        // A coroutine's body frame, started with surplus arguments for its
        // varargs, sits right above them (`Vm.bindAndPushClosure`).
        const above_args = owner != null and fr.varargs_count != 0 and
            @as(u64, fr.varargs_base) + fr.varargs_count == fr.base;
        if (i == 0 and fr.base != 0 and !above_args) return error.FrameWindowMismatch;
        if (fr.base < expected_base) return error.FrameWindowMismatch;
        if (@as(usize, fr.base) + cl.proto.num_registers > ctx.stack.len) return error.FrameWindowMismatch;
        if (fr.varargs_count == 0) {
            if (fr.varargs_base != 0) return error.InvalidFrameVarargs;
        } else {
            if (!cl.proto.is_vararg) return error.InvalidFrameVarargs;
            const varargs_end = std.math.add(u32, fr.varargs_base, fr.varargs_count) catch
                return error.InvalidFrameVarargs;
            if (varargs_end > fr.base or varargs_end > ctx.stack.len)
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
        vm.frames[i].ctl = ctl;
        if (ctl.cont == .finish_op) vm.frames[i - 1].in_flight = true;
        expected_base = @as(usize, fr.base) + cl.proto.num_registers;
    }
    // `pushFrameVararg` raises this to each physical window end. The serialized
    // live prefix may additionally contain caller-owned argument/vararg slots
    // (and structural test snapshots can use zero-register frames), so restore
    // the authoritative captured top after all frame pushes.
    vm.stack_top = ctx.stack.len;
    // Doc 61 Phase K: frames re-derive their tombstones at recapture, but at
    // depth 0 the only capture that tombstones is a validated final cut,
    // keeping exactly the result span. Re-derive that cut so recapture is
    // the identity. A coroutine's stack never has one.
    if (ctx.frames.len == 0 and owner == null) vm.setFinalCut(try finalCutFromStack(ctx.stack));

    for (ctx.open_upvalues) |ou| {
        const uh = idmap.get(ou.upvalue_id) orelse return error.UnresolvedHeapRef;
        if (uh.type != .upvalue) return error.UpvalueNotAnUpvalue;
        if (ou.stack_index >= vm.stack_top) return error.StackIndexOutOfRange;
        const cell = function.Upvalue.fromHeader(uh);
        if (cell.isOpen()) return error.UpvalueOpenTwice;
        // Switch the cell from its closed placeholder to open over the live slot.
        cell.reopen(ou.stack_index, &vm.tags[ou.stack_index], &vm.payloads[ou.stack_index]);
        cell.owner = if (owner) |t| &t.header else null;
        // Doc 54 P1: through the centralized method, so the rebuilt list
        // republishes `open_upvalue_ceiling` as it grows (round-1 blocker 5:
        // a restore that bypassed the ceiling would leave it stale-LOW).
        try vm.appendOpenUpvalue(ou.stack_index, cell);
    }

    // Doc 61 Phase K: with frames, pcs, open upvalues and the cut in place,
    // `fillKeep` is the keep set capture used. A tombstone inside it would
    // turn a live operand, vararg or upvalue slot into nil, so it cannot
    // come from a capture.
    vm.fillKeep(vm.gc_keep);
    for (ctx.stack, 0..) |sv, i| {
        if (sv.body == .DeadSlot and (vm.gc_keep[i / 64] >> @intCast(i % 64)) & 1 != 0)
            return error.InvalidTombstones;
    }
}

/// The program a keyframe was captured from.
pub const Program = union(enum) {
    /// As its host compiled it: the source and the options it passed the
    /// compiler. Restore recompiles it into the restored heap, so its
    /// literals are that heap's restored strings and nothing in the restored
    /// VM points into the compiling VM's heap.
    source: Source,
    /// A prebuilt proto tree the restored VM borrows. Only one with no heap
    /// constants (a hand-built structural test proto) is accepted, since a
    /// borrowed literal would live in another heap.
    image: *const Proto,

    pub const Source = struct {
        text: []const u8,
        options: compiler.Options = .{},
    };

    pub fn of(text: []const u8) Program {
        return .{ .source = .{ .text = text } };
    }
};

/// Decode `bytes` and restore them into a fresh VM (see `restoreSnapshot`).
pub fn restore(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    program: Program,
    natives: NativeRegistry,
) RestoreError!*Vm {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // decoded structs are consumed during restore (bytes copied)
    const snapshot = try schema.SnapshotFile.decode(arena.allocator(), bytes);
    return restoreSnapshot(gpa, snapshot, program, natives);
}

/// Rebuild a live VM from a decoded keyframe. `program` is recompiled into
/// the VM (`Vm.root_chunk`) and resolves `HeapClosure.proto_id`; `natives`
/// rebinds serialized natives by name. The returned VM is owned by the caller
/// (`vm.deinit()` then `gpa.destroy(vm)`); on any error nothing is leaked.
pub fn restoreSnapshot(
    gpa: std.mem.Allocator,
    snapshot: schema.SnapshotFile,
    program: Program,
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
    // chunks (L-2). Every loaded chunk's string literals are pinned (doc 19), so
    // they are unswept and a valid snapshot ALWAYS carries them (v10), and
    // recompile re-interns to the restored objects, allocating nothing — enforced
    // below (`LoadedChunkRecompileAllocated`). Advancing first still matters: it
    // is what makes a corrupt snapshot's illegitimate recompile allocation land
    // ABOVE the restored range (detectable) instead of colliding with it.
    var max_id: u32 = 0;
    for (kf.objects) |o| max_id = @max(max_id, o.id);
    // If the restored ids already fill the id space, recompiling a loaded chunk
    // (which allocates fresh interned strings via `link`) would wrap the counter
    // and collide with a restored id. Reject rather than silently alias. (This
    // only bites if a snapshot both names the top id AND carries loaded chunks
    // to recompile.)
    if (max_id == std.math.maxInt(u32) and kf.loaded_chunks.len > 0)
        return error.IdSpaceExhausted;
    // Restore the counter from the serialized `next_obj_id` (v5, H-2), NOT from
    // `max_id + 1`: the two are equal only when no object was allocated-then-dropped
    // before the cut. A swept object bumped `next_obj_id` but leaves no `objects`
    // entry, so `max_id + 1` would drift the counter LOW and every post-restore id
    // would diverge (ids are observable via table/pairs order). The serialized
    // counter must sit strictly above every restored id — a live object with
    // `id >= next_obj_id` is impossible, so reject it as corrupt.
    if (kf.next_obj_id < max_id +| 1) return error.NextObjIdBelowObjects;
    vm.heap.adoptNextId(kf.next_obj_id);
    // Doc 61 Phase K: the source's collection target. With every unswept
    // object restored, `object_count` matches the source's too, and so does
    // the stack charge once the coroutines below take their stacks (doc 73),
    // so the next collection fires at the same allocation. (On a 32-bit host
    // a target past usize can never be reached either way.)
    vm.heap.setGcTarget(std.math.cast(usize, kf.gc_target) orelse std.math.maxInt(usize));

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
            .HeapFile => |hf| blk: {
                const kind = std.enums.fromInt(File.Kind, hf.kind) orelse return error.InvalidFile;
                const mode = filemod.unpackMode(hf.mode) orelse return error.InvalidFile;
                if (hf.closed > 1 or hf.fingerprint.len > 1) return error.InvalidFile;
                if (hf.file_id >= kf.next_file_id) return error.NextFileIdBelowFiles;
                const f = try File.create(gpa, hf.file_id, kind, mode, hf.path);
                f.closed = hf.closed == 1;
                // Q7: an open file restored into a live VM has nothing behind
                // it on the host until `Vm.reopenFiles` reopens it. The
                // standard streams are the process's own and stay usable.
                f.detached = !f.closed and (kind == .file or kind == .tmpfile);
                if (hf.fingerprint.len == 1) {
                    const x = hf.fingerprint[0];
                    f.fingerprint = .{ .size = x.size, .mtime_ns = x.mtime_ns, .position = x.position };
                }
                vm.heap.linkRestored(&f.header, o.id);
                break :blk &f.header;
            },
            .HeapThread => |ht| blk: {
                try checkThreadShape(ht, kf.current_id != 0 and kf.current_id - 1 == o.id);
                if (ht.kind == thread_kind_main and vm.main_thread != null) return error.InvalidThread;
                const t = try coroutine.createRestored(vm.heap, ht.has_stack == 1);
                vm.heap.linkRestoredThread(&t.header, o.id);
                if (ht.kind == thread_kind_main) vm.main_thread = t;
                break :blk &t.header;
            },
            .HeapNative => |hn| blk: {
                const entry = natives.lookup(hn.name) orelse return error.UnknownNative;
                // As many bound values as the row binds (doc 73), filled in
                // pass 2.
                if (hn.bound.len != entry.bound) return error.InvalidNative;
                // The library's own natives (`function.LibNative`): one
                // object per slot, the one the live VM held.
                if (entry.slot) |s| if (vm.lib_natives[@intFromEnum(s)] != null) return error.DuplicateLibNative;
                const template: function.Native = .{
                    .header = GcHeader.init(.native),
                    .func = entry.func,
                    .name = entry.name, // the registry's static name (outlives the decode arena)
                    .effect = entry.effect, // an effect native stays an effect on replay
                    .multi = entry.multi, // …and keeps its multi-result projection
                    .recorded = entry.recorded, // …and its JIT-inlinable pure-builtin tag
                    .protocol = function.Native.protocolOf(false, entry.effect != null, entry.fast, entry.multi != null), // …and its call protocol (doc 70)
                    .itern = entry.itern, // …and its `itern` lane (doc 66)
                };
                const n = try function.Native.createBound(gpa, &template, hn.bound.len);
                // `pure ⇒ !effect` (doc 17, H-4 / 9-A(i)). The static `base_natives`
                // registry is comptime-proven in `interp.zig`; this guards a
                // caller-supplied `NativeRegistry` on the restore path.
                std.debug.assert(!(n.recorded != null and n.effect != null));
                if (entry.slot) |s| vm.lib_natives[@intFromEnum(s)] = n;
                vm.heap.linkRestored(&n.header, o.id);
                break :blk &n.header;
            },
        };
        idmap.putAssumeCapacityNoClobber(o.id, header);
    }

    // Rebuild the program image: the root program, then the runtime-`load`ed
    // chunks (L-2), recompiled so `resolveProto` can rebind a `HeapClosure.
    // proto_id` in pass 1b. Deterministic recompile reproduces the same
    // protos/ids the live VM had; string literals resolve to the
    // already-interned snapshot strings above.
    const root = try recompileRoot(vm, program);
    try recompileLoadedChunks(vm, root, kf.loaded_chunks);
    // v8 integrity check (doc 19): the encoder carries every loaded proto's
    // (pinned, so unswept) string constants and, while the program runs, the
    // program's (its frame 0 roots them), and Pass 1a interned every restored
    // string (byte-keyed) before the recompile — so a valid recompile
    // resolves every literal to a restored object and allocates NOTHING. A
    // moved counter means the snapshot is missing a literal: a corrupt one,
    // one whose program isn't `program`, or one captured after the program
    // returned and a collection swept its own literals (TODO.md). Its
    // allocation timeline is forked from the source VM's, so reject rather
    // than diverge silently.
    if (vm.heap.next_obj_id != kf.next_obj_id) return error.RecompileAllocated;

    // --- Pass 1b: create closure shells now that all protos (static + loaded)
    // exist. linkRestored stamps the original id (the counter was already advanced
    // past it). ---
    for (kf.objects) |o| {
        const hc = switch (o.body) {
            .HeapClosure => |hc| hc,
            else => continue,
        };
        if (idmap.contains(o.id)) return error.DuplicateId;
        const proto = (try resolveProto(root, vm, hc.proto_id)) orelse return error.UnknownProto;
        const cl = try function.Closure.create(gpa, proto, hc.upvalue_ids.len);
        vm.heap.linkRestored(&cl.header, o.id);
        idmap.putAssumeCapacityNoClobber(o.id, &cl.header);
    }

    // --- Pass 2: wire inter-object edges (all shells now exist). ---
    for (kf.objects) |o| {
        const h = idmap.get(o.id).?;
        switch (o.body) {
            .HeapString, .HeapFile => {},
            .HeapNative => |hn| {
                const n = function.Native.fromHeader(h);
                for (hn.bound, n.bound) |sv, *v| v.* = try fromSchemaValue(sv, &idmap);
            },
            .HeapTable => |ht| {
                const t = table.Table.fromHeader(h);
                // Array part: append in order — v7 is positional 0-based (doc 18
                // D5): serialized entry `i` IS logical key / physical slot `i`,
                // holes ride in-band as nils (the ubiquitous slot-0 hole
                // included). Append starts at key 0 under identity mapping, so a
                // plain in-order append reproduces the split exactly.
                // The array part comes back in exactly its captured
                // representation (doc 61 Phase K): lane and commitment decide
                // later grid inflation, so later allocations and ids.
                const lane = std.enums.fromInt(arr.Lane, ht.lane) orelse return error.InvalidTableLane;
                if (lane == .grid) {
                    if (ht.grid.len != 1 or ht.array.len != 0) return error.InvalidTableLane;
                    // A grid owns the whole table (no hash, no metatable — the
                    // inflation gate, gc.zig) and is always committed.
                    if (ht.entries.len != 0 or ht.metatable_id != 0) return error.InvalidTableLane;
                    if (ht.flags & table_flag_frozen == 0) return error.InvalidTableLane;
                    const g = try fromSchemaGrid(gpa, ht.grid[0]);
                    t.array.deinit(gpa); // the fresh table's empty part
                    t.array = g;
                } else {
                    if (ht.grid.len != 0) return error.InvalidTableLane;
                    for (ht.array) |sv| try t.array.append(gpa, try fromSchemaValue(sv, &idmap));
                    t.array.restoreLane(gpa, lane) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.LaneMismatch => return error.InvalidTableLane,
                    };
                }
                t.array.frozen = ht.flags & table_flag_frozen != 0;
                t.no_grid = ht.flags & table_flag_no_grid != 0;
                t.header.flags.readonly = ht.flags & table_flag_readonly != 0;
                // The rehash trigger depends on history and decides where later
                // integer keys land, so `#t` and `next` order (Table.rehash).
                // Below 4 no capture can produce it.
                if (ht.rehash_threshold < 4) return error.InvalidRehashThreshold;
                t.rehash_threshold = std.math.cast(usize, ht.rehash_threshold) orelse return error.InvalidRehashThreshold;
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
                u.closeWith(try fromSchemaValue(hu.value, &idmap));
            },
            .HeapThread => |ht| {
                const t = Thread.fromHeader(h);
                t.status = @enumFromInt(ht.status); // checked in pass 1a
                t.body = try fromSchemaValue(ht.body, &idmap);
                // A coroutine runs a function, Lua or native
                // (`coroutine.create`); the main thread runs none.
                const body_ok = if (ht.kind == thread_kind_main)
                    t.body.isNil()
                else
                    t.body.isHeap() and (t.body.asHeap().type == .function or t.body.asHeap().type == .native);
                if (!body_ok) return error.InvalidThread;
                if (ht.death.len == 1) t.death = try fromSchemaValue(ht.death[0], &idmap);
                if (ht.resumer_id != 0) {
                    const rh = idmap.get(ht.resumer_id - 1) orelse return error.UnresolvedHeapRef;
                    if (rh.type != .thread) return error.InvalidThread;
                    t.resumer = Thread.fromHeader(rh);
                }
                t.ret_lo = ht.ret_lo;
                t.ret_c = ht.ret_c;
                t.wrapped = ht.wrapped == 1;
                t.yield_lo = ht.yield_lo;
                t.yield_c = ht.yield_c;
            },
        }
    }

    // Bound values are checked once every edge is wired: a `wrap`
    // function's coroutine is told from the main thread by its body.
    for (kf.objects) |o| {
        const hn = switch (o.body) {
            .HeapNative => |hn| hn,
            else => continue,
        };
        const entry = natives.lookup(hn.name).?; // resolved in pass 1a
        if (entry.bound_ok) |ok| {
            if (!ok(function.Native.fromHeader(idmap.get(o.id).?).bound)) return error.InvalidNative;
        }
    }

    // --- Roots ---
    const gh = idmap.get(kf.globals_id) orelse return error.UnresolvedHeapRef;
    if (gh.type != .table) return error.GlobalsNotATable;
    // Globals never inflate (`Vm.fusedStore`): global stores write the table
    // raw, and a grid takes no raw store.
    if (table.Table.fromHeader(gh).array.isGrid()) return error.GlobalsNotATable;
    vm.globals = table.Table.fromHeader(gh);
    // Doc 43 §3.2 (P0b): restore reseats the globals table at a new address, so
    // refresh the recorder's globals-header channel to match (a trace recorded
    // after a restore must compare stores against the live table).
    vm.trace.rec_globals_header = &vm.globals.header;

    // Doc 73: the running stack is the keyframe's own. With a coroutine
    // running, the main stack is rebuilt first and put aside as a switch
    // would, and the coroutine's is rebuilt loaded.
    const current: ?*Thread = if (kf.current_id == 0) null else blk: {
        const h = idmap.get(kf.current_id - 1) orelse return error.UnresolvedHeapRef;
        if (h.type != .thread) return error.InvalidThread;
        break :blk Thread.fromHeader(h);
    };
    try checkResumerChain(kf, current);
    const running_ctx: schema.ThreadContext = .{ .stack = kf.stack, .frames = kf.frames, .open_upvalues = kf.open_upvalues };
    if (current) |t| {
        // The main stack is stopped at the resume that began the chain.
        if (kf.main_context.len != 1 or kf.main_context[0].frames.len == 0) return error.InvalidThread;
        try restoreContext(vm, kf.main_context[0], &idmap, null);
        coroutine.save(vm, &vm.main_saved);
        coroutine.load(vm, &t.saved);
        vm.current = t;
        try restoreContext(vm, running_ctx, &idmap, t);
    } else {
        if (kf.main_context.len != 0) return error.InvalidThread;
        try restoreContext(vm, running_ctx, &idmap, null);
    }

    // Doc 73: each other coroutine's stack, rebuilt like the running one
    // with that stack loaded, as a collection walks it.
    var running_saved: coroutine.SavedContext = undefined;
    coroutine.save(vm, &running_saved);
    for (kf.objects) |o| {
        const ht = switch (o.body) {
            .HeapThread => |ht| ht,
            else => continue,
        };
        if (ht.context.len == 0) continue;
        const t = Thread.fromHeader(idmap.get(o.id).?);
        coroutine.load(vm, &t.saved);
        // Whatever happens, the stack's state goes back to its thread and
        // the running stack's into the VM, so each is freed once.
        defer {
            coroutine.save(vm, &t.saved);
            coroutine.load(vm, &running_saved);
        }
        try restoreContext(vm, ht.context[0], &idmap, t);
        // A suspended coroutine has its body frame, or hasn't started.
        if (ht.context[0].frames.len == 0 and ht.context[0].stack.len != 0) return error.InvalidThread;
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

    // Doc 65: the file metatable, the default input/output, and the handle
    // counter (above every restored handle and the standard streams).
    if (kf.next_file_id < 3) return error.NextFileIdBelowFiles;
    vm.next_file_id = kf.next_file_id;
    if (kf.file_metatable_id != 0) {
        const mh = idmap.get(kf.file_metatable_id - 1) orelse return error.UnresolvedHeapRef;
        if (mh.type != .table) return error.MetatableNotATable;
        vm.file_metatable = table.Table.fromHeader(mh);
        // Its `__index` is the methods table (`Vm.initIoStreams`).
        const methods = vm.file_metatable.?.get(vm.mm.index);
        if (!(methods.isHeap() and methods.heapType() == .table)) return error.MetatableNotATable;
        vm.file_methods = table.Table.fromHeader(methods.asHeap());
    }
    // A real run's VM (metatable support built) has every library native;
    // a snapshot without one could not run its `pairs`.
    if (kf.string_metatable_id != 0) {
        for (vm.lib_natives) |n| if (n == null) return error.MissingLibNative;
    }
    vm.io_input = try fileRoot(&idmap, kf.io_input_id);
    vm.io_output = try fileRoot(&idmap, kf.io_output_id);

    // Doc 73 §7: the task library, whose chunk the recompile made a plain
    // loaded one: flag its protos the VM's own again.
    if (kf.task_lib_id != 0) {
        const th = idmap.get(kf.task_lib_id - 1) orelse return error.UnresolvedHeapRef;
        if (th.type != .table) return error.InvalidTaskLib;
        const lib = table.Table.fromHeader(th);
        const spawn = lib.get(Value.int(1));
        if (!spawn.isHeap() or spawn.heapType() != .function) return error.InvalidTaskLib;
        const at = vm.loadedChunkIndexOf(function.Closure.fromHeader(spawn.asHeap()).proto.id) orelse return error.InvalidTaskLib;
        Vm.markSystem(@constCast(vm.loaded_chunks.items[at].chunk.proto));
        vm.task_lib = lib;
    }

    // Doc 73 §7.6: the `aio` operations in flight. No host runs them, so a
    // live wait on one refuses; a replay settles them from the log.
    if (kf.aio_ops_id != 0) {
        const oh = idmap.get(kf.aio_ops_id - 1) orelse return error.UnresolvedHeapRef;
        if (oh.type != .table) return error.InvalidAioOps;
        vm.aio_ops = table.Table.fromHeader(oh);
    }
    try stdaio.restoreOps(vm, kf.aio_next_id);

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
