//! Frozen-layout constants + lane helpers for tier-1b native codegen
//! (split from `nativegen.zig`, file-split pass): every byte offset and
//! type/lane ordinal the emitted machine code encodes against — all
//! derived via `@offsetOf`/`@intFromEnum` so a layout change in
//! `value.zig`/`table.zig`/`array.zig` fails the build instead of
//! silently miscompiling (Z-1/Z-2) — plus the per-iteration
//! `resolveHashCell` callout target and the lane classification helpers.

const std = @import("std");
const value = @import("value.zig");
const table = @import("table.zig");
const hash_part = @import("hash_part.zig");
const arr = @import("array.zig");
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const Value = value.Value;
const Trace = trace_code.TraceCode;
const Kind = @import("nativegen_artifact.zig").Kind;

/// Frozen in-memory layout the lane-aware native array path (Phase B) encodes
/// against. Every constant is imported from the table/array modules via
/// `@offsetOf`, never a literal — a layout change in `table.zig`/`array.zig` is
/// reflected here at comptime, and a regression fails to compile rather than
/// silently miscompiling a load/store address. Reaching a packed slot from a
/// `*Table` is `ArrLayout.array_base + ArrLayout.<field>`.
pub const ArrLayout = struct {
    /// `*Table` → embedded `ArrayPart`.
    pub const array_base = table.Table.array_off;
    /// `ArrayPart` field offsets (from `array_base`).
    pub const lane = arr.ArrayPart.Layout.lane;
    pub const asize = arr.ArrayPart.Layout.asize;
    pub const cap = arr.ArrayPart.Layout.cap;
    pub const data = arr.ArrayPart.Layout.data;
    pub const present = arr.ArrayPart.Layout.present;
    /// Grid fields (doc 14): the per-cell element lane and the row stride. A grid's
    /// `data`/`present` are the SAME fields as a scalar array's, reinterpreted as a
    /// flat `cap*stride` cell buffer indexed by `row*stride + col` at `grid_elem`
    /// width. `@offsetOf` makes a layout churn a compile error (Z-1/Z-2).
    pub const grid_elem = arr.ArrayPart.Layout.grid_elem;
    pub const stride = arr.ArrayPart.Layout.stride;
    /// `*Table` → embedded hash part's `size` (live entry count, u32). The grow
    /// store's `guard_append` reads this to prove the hash is empty (so tier-0's
    /// `migrateFromHash` would be a no-op). `@offsetOf` on the std map field makes a
    /// layout churn a compile error, never a silent miscompile (Z-1/Z-2).
    pub const hash_size = table.Table.hash_off + @offsetOf(table.Table.Map, "live");
};

comptime {
    // Sanity (evaluated at file scope, so it always runs and marks ArrLayout
    // used): the array sits past an 8-byte GcHeader, lane is the first
    // ArrayPart byte, and the pointer/len fields are usize-aligned. These are
    // the assumptions the native address math (B2+) relies on.
    std.debug.assert(ArrLayout.array_base >= @sizeOf(@import("object.zig").GcHeader));
    std.debug.assert(ArrLayout.lane == 0);
    std.debug.assert(ArrLayout.asize % @alignOf(usize) == 0);
    std.debug.assert(ArrLayout.data % @alignOf(usize) == 0);
    std.debug.assert(ArrLayout.present % @alignOf(usize) == 0);
}

pub const TAG_NIL: u8 = @intFromEnum(value.Tag.nil);
pub const TAG_INT: u8 = @intFromEnum(value.Tag.int);
pub const TAG_BOOL: u8 = @intFromEnum(value.Tag.boolean);
pub const TAG_FLOAT: u8 = @intFromEnum(value.Tag.float);
pub const TAG_HEAP: u8 = @intFromEnum(value.Tag.heap_ref);
/// Byte offsets within a 16-byte tagged `Value` — used by `hload`/`hstore` to
/// touch a hash-part value cell (`*Value`) directly. The tag lives at offset 0
/// (1 byte), the payload union at offset 8 (8 bytes); the 7 bytes between are
/// padding the oracle's struct-assign also leaves undefined, so native writing
/// only tag+payload is byte-identical at every observable point.
pub const VALUE_TAG_OFF: i32 = @offsetOf(value.Value, "tag");
pub const VALUE_PAYLOAD_OFF: i32 = @offsetOf(value.Value, "payload");
/// `ObjectType.table` ordinal — the byte at `GcHeader.type` for a table.
pub const TABLE_TYPE: u8 = @intFromEnum(object.ObjectType.table);
/// Offset of `GcHeader.type` (the first header byte) from a `*GcHeader`.
pub const HEADER_TYPE_OFF: i32 = @offsetOf(object.GcHeader, "type");
/// Offset of `Table.metatable` (an optional `*Table`; null = 0) from a
/// `*GcHeader`. The prologue checks this is null: a table that grew a metatable
/// after the trace was recorded must side-exit to tier-0 (which dispatches
/// `__index`/`__newindex`), never run the raw native load/store — chunk 2a.
pub const METATABLE_OFF: i32 = @offsetOf(table.Table, "metatable");
/// `ObjectType.function` ordinal — the byte at `GcHeader.type` for a Lua closure.
/// The cross-frame `guard_func` (U1) checks a snapshot callee value is a closure
/// of this type before reading its `proto.id`.
pub const FUNCTION_TYPE: u8 = @intFromEnum(object.ObjectType.function);
/// Offset of `Closure.proto` (a `*const Proto`) from a `*GcHeader`. The header is
/// the first field, so this is the closure's second word.
pub const CLOSURE_PROTO_OFF: i32 = @offsetOf(function.Closure, "proto");
comptime {
    // Everything that applies a Closure field offset to a raw TAG_HEAP payload
    // (`*GcHeader`) — the guard_func prologue, doc 54's inline push callee
    // guard, and the push's `frame.closure = payload` store — assumes the
    // header IS the closure address. Pin it (Z-1).
    std.debug.assert(@offsetOf(function.Closure, "header") == 0);
}
/// Offset of `Proto.id` (a stable `u32` compile-time identity — NOT an address, so
/// it survives keyframe restore/replay) from a `*const Proto`. `guard_func` compares
/// the recorded id against `[closure.proto + PROTO_ID_OFF]`.
pub const PROTO_ID_OFF: i32 = @offsetOf(bytecode.Proto, "id");
/// doc 49 — the hrefk inline hash access encodes against the OWNED hash part
/// (`hash_part.HashPart`, extern layout by design). All from-`*GcHeader`
/// offsets, like `HASH_SIZE_FROM_HEADER` (header is `Table`'s first field).
pub const HASH_MASK_FROM_HEADER: i32 = table.Table.hash_off + @offsetOf(table.Table.Map, "mask") - @as(i32, @intCast(@offsetOf(table.Table, "header")));
pub const HASH_NODES_FROM_HEADER: i32 = table.Table.hash_off + @offsetOf(table.Table.Map, "nodes") - @as(i32, @intCast(@offsetOf(table.Table, "header")));
/// Node geometry: `hash_part.Node` is `extern { key: Value, value: Value }`,
/// 32 bytes. Comptime-pinned so a Node change recomputes the JIT's address
/// math or fails the build, never miscompiles.
pub const NODE_SIZE: i32 = @sizeOf(hash_part.Node);
pub const NODE_KEY_TAG_OFF: i32 = @offsetOf(hash_part.Node, "key") + @offsetOf(value.Value, "tag");
pub const NODE_KEY_PAYLOAD_OFF: i32 = @offsetOf(hash_part.Node, "key") + @offsetOf(value.Value, "payload");
pub const NODE_VALUE_OFF: i32 = @offsetOf(hash_part.Node, "value");
/// Offset of `GcHeader.id` (the stable `u32` object identity — NOT an address,
/// survives keyframe restore) from a `*GcHeader`. The hrefk key guard compares
/// the recorded interned-key id against `[node.key.payload + GCHEADER_ID_OFF]`.
pub const GCHEADER_ID_OFF: i32 = @offsetOf(object.GcHeader, "id");
comptime {
    std.debug.assert(NODE_SIZE == 32);
    std.debug.assert(HASH_MASK_FROM_HEADER >= 0 and HASH_NODES_FROM_HEADER >= 0);
}

/// `ObjectType.native` ordinal — the byte at `GcHeader.type` for a host native.
/// The pure-builtin `guard_builtin` checks a snapshot callee value is a native of this
/// type before reading its `pure` tag.
pub const NATIVE_TYPE: u8 = @intFromEnum(object.ObjectType.native);
/// doc 24 c3: the header-type byte a `guard_string`-pinned slot's prologue check
/// compares against (the snew ops' string operands).
pub const STRING_TYPE: u8 = @intFromEnum(object.ObjectType.string);
/// Offset of `Native.recorded` (a `?RecordedBuiltin` — an `enum(u8)` optional, 2 bytes laid
/// out `[payload, has_value]`) from a `*GcHeader`. `guard_builtin` proves the callee is
/// the recorded builtin with two byte compares: `[native + recorded]` (the payload
/// ordinal) == the recorded `RecordedBuiltin` tag, AND `[native + recorded + 1]` (the
/// non-null flag) == 1. Two byte compares sidestep needing a 16-bit-immediate
/// compare encoder and don't depend on the optional's internal byte order beyond the
/// verified `[payload, flag]` layout.
pub const NATIVE_RECORDED_OFF: i32 = @offsetOf(function.Native, "recorded");
comptime {
    // Pin the `?RecordedBuiltin` size the `guard_builtin` prologue depends on (Z-1: a
    // toolchain bump that changes optional layout must fail the build loudly, not
    // silently miscompile the two-byte identity check). The `[payload, has_value]`
    // byte *order* can't be asserted at comptime (an optional has no well-defined
    // comptime layout to deref) — it's pinned by the runtime test below instead.
    std.debug.assert(@sizeOf(?function.RecordedBuiltin) == 2);
}
/// Packed-lane ordinals the native array path can lower. The bool lane (B2/B3,
/// the nsieve sieve) is bit-packed; the int lanes (B4) are byte-packed and
/// SIB-indexed; the `f64` lane (Phase D, float arrays) is 8-byte doubles read/
/// written with `movsd` into the XMM pool. Only `.value` (16-B unpacked,
/// heap-bearing) always bails to tier-1a — `laneKind` returns null for it.
pub const BOOL_LANE: i32 = @intFromEnum(arr.Lane.boolean);
pub const I8_LANE: i32 = @intFromEnum(arr.Lane.i8);
pub const I16_LANE: i32 = @intFromEnum(arr.Lane.i16);
pub const I32_LANE: i32 = @intFromEnum(arr.Lane.i32);
pub const I64_LANE: i32 = @intFromEnum(arr.Lane.i64);
pub const U8_LANE: i32 = @intFromEnum(arr.Lane.u8);
pub const F64_LANE: i32 = @intFromEnum(arr.Lane.f64);
/// The grid meta-lane (doc 14): a `.grid` array's `lane` field. Used as the
/// `SlotInfo.lane` prologue check for a grid table (`array.lane == .grid`); the
/// per-cell element width comes from the separate `grid_elem` field/ordinal,
/// which the grid ops carry in their `aux` (an int lane, so `laneKind`/
/// `intLaneWidth` classify it exactly like a scalar int lane).
pub const GRID_LANE: i32 = @intFromEnum(arr.Lane.grid);

/// The `.value` lane ordinal — 16-byte full-`Value` elements, heap-bearing.
/// Phase 2 admits this lane for aload→guard_table→href→hload chains (the
/// array-of-structs pattern `bodies[i].x`); the aload itself produces a `.heap`
/// kind (a per-iteration `*GcHeader` table pointer) consumed by the hash-field
/// path, not a scalar lane kind.
pub const VALUE_LANE: i32 = @intFromEnum(arr.Lane.value);

/// Offset from a `*GcHeader` (the table's embedded header) to the hash-part
/// `size` (u32 live-entry count). The comptime chain is:
/// `@offsetOf(Table, "hash") + @offsetOf(Map, "size") - @offsetOf(Table, "header")`.
/// Since `header` is always the first field (`@offsetOf(Table, "header") == 0`
/// for Zig's default layout where `GcHeader` is first), this equals
/// `ArrLayout.hash_size`. We name it separately for clarity and pin the
/// assumption via a comptime assert below.
pub const HASH_SIZE_FROM_HEADER: i32 = ArrLayout.hash_size - @as(i32, @intCast(@offsetOf(table.Table, "header")));
comptime {
    // The header-to-hash offset must be non-negative (header is before hash).
    std.debug.assert(HASH_SIZE_FROM_HEADER >= 0);
}

/// Per-iteration hash-cell resolver for `.value`-lane table loads (Phase 2).
///
/// The native loop body calls this via `call rax` to resolve the value-cell
/// pointer for a constant string key in a per-iteration element table. The
/// existing loop-invariant href path resolves the cell once at entry via
/// `seedTraceInputs`; this function is the per-iteration equivalent.
///
/// SysV ABI: rdi = `*GcHeader` (element table from aload), rsi = key tag
/// bits (low byte = `Tag` ordinal), rdx = key payload bits. Returns the
/// `*Value` cell pointer as a `usize` in rax, or 0 if the key is absent.
///
/// Does NOT check metatable (`guard_table` already did) or hash count
/// (`guard_hash` does it inline). Pure `fieldPtr` resolution — a wrapper
/// that confines the Zig HashMap's non-extern internals to one call site
/// (Rule Z-2).
pub fn resolveHashCell(header_bits: usize, key_tag_bits: u64, key_payload_bits: u64) callconv(.c) usize {
    const header: *object.GcHeader = @ptrFromInt(header_bits);
    const tbl = table.Table.fromHeader(header);
    const key = Value{ .tag = @enumFromInt(@as(u8, @truncate(key_tag_bits))), .payload = .{ .bits = key_payload_bits } };
    const cell = tbl.fieldPtr(key) orelse return 0;
    return @intFromPtr(cell);
}

/// The native scalar `Kind` a packed lane decodes to, or `null` when the native
/// array path does not lower this lane (`.value` → tier-1a). The bool lane
/// yields a 0/1 boolean; the i8…i64 lanes yield a sign-extended int; the
/// unsigned-byte `u8` lane yields a zero-extended int (same `.int` Kind — the
/// signedness difference is purely in the `aload` extension width, see below);
/// the `f64` lane yields a `.float` (an 8-byte double, XMM-resident).
pub fn laneKind(aux: i32) ?Kind {
    if (aux == BOOL_LANE) return .bool;
    if (aux == I8_LANE or aux == I16_LANE or aux == I32_LANE or aux == I64_LANE or aux == U8_LANE) return .int;
    if (aux == F64_LANE) return .float;
    return null;
}

/// Packed-element width in bytes for an int lane (1/2/4/8 → the SIB scale).
/// Asserts an int lane (`laneKind(aux) == .int`); the bit-packed bool lane uses
/// `bt`/`bts`/`btr` instead and never calls this. `u8` is one byte wide, like i8.
pub fn intLaneWidth(aux: i32) u8 {
    return if (aux == I8_LANE or aux == U8_LANE) 1 else if (aux == I16_LANE) 2 else if (aux == I32_LANE) 4 else if (aux == I64_LANE) 8 else unreachable;
}

/// True when SSA ref `r` is a `.konst` whose value statically fits the lane named
/// by `aux`. A *constant* int-lane array store needs no runtime `guard_fits`: the
/// recorder only emits the store when the value fit the lane (`recArraySet`'s
/// `array.fits` precondition), and a constant never changes — so tropt proves the
/// `guard_fits` always-passes and folds it away (`tropt` const-eval via the same
/// `laneFits`). Native then sees no covering `guard_fits` and would bail the whole
/// trace to tier-1a; re-derive the static fit here with the identical `laneFits`
/// rule so a constant int-lane fill/init store (`p[i]=0`, `a[k]=7`) compiles to
/// native instead. Narrow lanes (i8…i32/u8) range-check the constant; the i64 lane
/// fits every int. Mirrors the f64 arm, which already compiles a const-fill whose
/// guard_fits tropt DCE'd. A *variant* (non-const) narrow-lane value keeps its
/// guard_fits (tropt can't prove it always fits), so it takes the `fits_ok` path,
/// not this one.
pub fn konstFitsLane(t: *const Trace, r: trace_ir.Ref, aux: i32) bool {
    if (r >= t.instrs.len) return false;
    const ki = t.instrs[r];
    if (ki.op != .konst) return false;
    if (ki.aux < 0 or ki.aux >= t.consts.len) return false;
    return arr.ArrayPart.laneFits(@enumFromInt(aux), t.consts[@intCast(ki.aux)]);
}

