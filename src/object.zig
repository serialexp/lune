//! Heap object model — the GC header every heap value starts with, and the
//! typed-array storage descriptor.
//!
//! Phase 1 *settles the shapes*; it does not allocate anything. There is no GC
//! yet (Phase 4) and no strings/tables yet (Phase 3). What must be fixed now is
//! the memory layout the rest of the system encodes against: the common header
//! a `Value.heap_ref` points at, and the typed-array storage model the
//! GPU-upload path depends on (see docs/design/03-gc-memory.md).

const std = @import("std");

/// Concrete kind of a heap object. Lives in the object header (one source of
/// truth). `Value`'s tag stays coarse (`heap_ref`) and defers to this on a
/// dereference — promoting hot heap kinds to value-level tags is a later
/// optimisation, mirroring the NaN-boxing stance in the architecture doc.
pub const ObjectType = enum(u8) {
    string,
    table,
    /// A Lua closure: a prototype paired with captured upvalues.
    function,
    /// A native (host/builtin) function exposed through the embedding boundary.
    native,
    /// A captured-variable cell (open or closed upvalue).
    upvalue,
    typed_array,
    /// Opaque host-owned object exposed through the embedding API.
    host,
    _,
};

/// Tri-colour mark state for the future non-moving mark-sweep collector
/// (Phase 4). Present in the header from day one so allocation sites and the
/// header layout don't change when the collector lands.
pub const GcColor = enum(u8) {
    white = 0, // unmarked / candidate for collection
    gray = 1, // marked, children not yet scanned
    black = 2, // marked, children scanned
};

/// Per-object flags. Bitfield kept in the header's spare byte.
pub const GcFlags = packed struct(u8) {
    /// Pinned: must not be moved or freed (e.g. leased to the host/GPU).
    pinned: bool = false,
    /// Reserved for a future generational write-barrier (`remembered`).
    remembered: bool = false,
    /// Meaningful for `.string` objects only: every payload byte is < 0x80.
    /// Computed EXACTLY at construction (`String.createWithHash`, one fused
    /// scan with the code-point count) — true ⟹ char index == byte index for
    /// every seam, valid for ANY bytes (the effect log deliberately parks raw
    /// non-UTF-8 host input as interned strings — validate-after-log — so this
    /// bit must not be derived from `cp_len == len`, which malformed bytes can
    /// counterfeit). Doc 28 §2; not serialized (restore recomputes via
    /// `String.create`).
    str_ascii: bool = false,
    _reserved: u5 = 0,
};

/// The common header at the start of *every* heap object. Concrete object
/// structs embed this as their first field, so a `*GcHeader` round-trips to the
/// concrete type via `@fieldParentPtr` — and a `Value.heap_ref` payload is
/// exactly a `*GcHeader`.
///
/// Note: the shape/hidden-class pointer is deliberately **not** here. Only
/// table-likes have shapes, so it lives in the table object (Phase 3/9) rather
/// than bloating every string by 8 bytes. `03-gc-memory.md` says "shape pointer
/// for table-likes" — i.e. in the table, not the universal header.
pub const GcHeader = extern struct {
    type: ObjectType,
    color: GcColor = .white,
    flags: GcFlags = .{},
    _pad: u8 = 0,
    /// Stable, monotonic per-object identity assigned by the heap at allocation
    /// (`gc.Heap.link`). Unlike the object's address it is **deterministic** and
    /// reproducible run-to-run, so it is what observable rendering uses (`print`
    /// of a table/function — see `io.writeValue`) instead of `@intFromPtr`, which
    /// would leak ASLR into program output and break deterministic replay
    /// (docs/design/02-determinism.md). It is also the identity a future
    /// keyframe's heap graph keys on (docs/design/01, 04). 0 until linked.
    id: u32 = 0,
    /// Intrusive next-pointer for the collector's allocation list (sweep walk).
    /// Null until an allocator threads the object in (Phase 4).
    next: ?*GcHeader = null,

    pub fn init(object_type: ObjectType) GcHeader {
        return .{ .type = object_type };
    }
};

/// Element type of a typed unboxed array. Narrow widths are first-class — this
/// is the voxel/GPU-buffer case. The element's natural width *is* its alignment.
pub const ElementType = enum(u8) {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,

    /// Size of one element in bytes.
    pub fn sizeBytes(self: ElementType) usize {
        return switch (self) {
            .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .f64 => 8,
        };
    }

    /// Required alignment of the payload for this element type (== element size
    /// for all current widths; kept as its own method so a future wider type
    /// or over-alignment can diverge).
    pub fn alignBytes(self: ElementType) usize {
        return self.sizeBytes();
    }
};

/// Who owns the off-heap payload behind a typed array, and therefore who may
/// free or mutate it. The zero-copy host/GPU handoff returns a *lease* keyed off
/// this (Phase 9b); see `03-gc-memory.md` §Buffer ownership.
pub const BufferOwner = enum(u8) {
    /// Allocated and freed by the VM.
    vm_owned,
    /// Borrowed from the host; the VM neither frees nor outlives it.
    external_borrowed,
    /// Host-allocated; the VM frees it via a registered finalizer.
    external_owned_with_finalizer,
    /// Leased out to the host/GPU; pinned for the borrow window, VM must not
    /// mutate or free until the lease ends.
    pinned_export,
};

/// A typed unboxed array: a GC'd header pointing at a contiguous, **off-heap,
/// non-moving** payload of raw elements (no per-element tag, no per-element GC).
/// A `u8`/`u16` payload is a `memcpy` — or a zero-copy lease — straight to the
/// GPU.
///
/// Phase 1 fixes the descriptor shape only; allocation, growth, element get/set,
/// and the lease API are Phase 9b. `data` is a raw byte pointer reinterpreted
/// according to `elem`; `len`/`cap` count *elements*, not bytes.
pub const TypedArray = extern struct {
    header: GcHeader,
    elem: ElementType,
    _pad: [7]u8 = @splat(0),
    len: usize, // element count
    cap: usize,
    /// Off-heap payload, aligned to `elem.alignBytes()`. Null only for a
    /// zero-capacity array.
    data: ?[*]u8,
    owner: BufferOwner,
    _pad2: [7]u8 = @splat(0),

    /// Total payload size in bytes for `cap` elements.
    pub fn payloadBytes(self: *const TypedArray) usize {
        return self.cap * self.elem.sizeBytes();
    }
};

test "GcHeader layout is compact and pointer-aligned" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GcHeader));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(GcHeader));
    // header begins at offset 0 of any concrete object (embedding convention).
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TypedArray, "header"));
}

test "GcFlags packs into one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GcFlags));
    var f = GcFlags{};
    try std.testing.expect(!f.pinned);
    f.pinned = true;
    try std.testing.expect(f.pinned);
}

test "ElementType sizes and alignments" {
    try std.testing.expectEqual(@as(usize, 1), ElementType.u8.sizeBytes());
    try std.testing.expectEqual(@as(usize, 2), ElementType.i16.sizeBytes());
    try std.testing.expectEqual(@as(usize, 4), ElementType.f32.sizeBytes());
    try std.testing.expectEqual(@as(usize, 8), ElementType.f64.sizeBytes());
    try std.testing.expectEqual(@as(usize, 8), ElementType.u64.alignBytes());
}

test "TypedArray header embeds GcHeader first and reports payload bytes" {
    var arr = TypedArray{
        .header = GcHeader.init(.typed_array),
        .elem = .f32,
        .len = 0,
        .cap = 256,
        .data = null,
        .owner = .vm_owned,
    };
    try std.testing.expectEqual(ObjectType.typed_array, arr.header.type);
    try std.testing.expectEqual(@as(usize, 1024), arr.payloadBytes());
}
