//! The table **array part** — a lane-tagged, packed storage for the dense run of
//! positive-integer keys `1..len` that every Lua list/array degenerates to.
//!
//! Motivation: a table whose array part holds only small integers or booleans
//! pays a full 16-byte `Value` per slot in the naive representation, even though
//! the live data is one bit (a boolean) or two bytes (an int ≤ 65 535). lune
//! instead stores the array part in the **narrowest lane** the data fits — a
//! single type marker plus packed elements — and falls back to full `Value`s only
//! when the contents are heterogeneous or heap-bearing. nsieve's sieve array is
//! all booleans, so its ~20 M-slot array drops from ~320 MB (16 B/slot) to a few
//! MB (~2 bits/slot), *below* LuaJIT.
//!
//! This is the table's *internal* storage, distinct from `object.TypedArray`
//! (the standalone, user-facing GPU/voxel buffer). They share the spirit (unboxed
//! homogeneous elements) and the element widths (`object.ElementType.sizeBytes`),
//! but an `ArrayPart` is embedded in a `Table`, carries a presence bitmap for
//! holes, and re-narrows itself automatically at rehash time.
//!
//! ### Lanes
//! - `.value` — today's representation: `data` reinterpreted as `[*]Value`, 16 B
//!   each, `nil` represented **in-band** (a `nil`-tagged `Value`), no presence
//!   bitmap. This is the correctness fallback: a fresh, heterogeneous, or
//!   heap-bearing array lives here.
//! - `.boolean` — `data` is a **value bitmap** (1 bit/slot: the boolean), plus a
//!   separate **presence bitmap** (a narrow lane has no bit pattern for a hole).
//!   ~2 bits/slot.
//! - `.i8/.i16/.i32/.i64` — `data` is packed integers at lane width; `present` is
//!   the presence bitmap.
//! - `.f64` — `data` is packed doubles; `present` is the presence bitmap.
//!
//! Every narrow lane carries the presence bitmap so a hole (`t[1]` unset while
//! `t[2..]` are) round-trips as `nil`. `get`/`set` translate between the packed
//! lane and a logical `Value`; the rest of the VM only ever sees `Value`s.
//!
//! ### Determinism / phase-B contract
//! The lane is a pure in-memory optimisation: it is **never** serialised. Keyframe
//! capture reads logical `Value`s via `get`, and restore rebuilds via `append`
//! (which starts in `.value` and re-narrows only on a later `set`-driven rehash) —
//! so a snapshot's bytes are independent of how any array happens to be packed
//! (see `docs/design/04`). The field layout (`Layout` below) is a frozen contract
//! the future tier-1b JIT (Phase B) encodes against via `@offsetOf`, never literals.

const std = @import("std");
const object = @import("object.zig");
const value = @import("value.zig");
const Value = value.Value;

/// The storage lane of an array part. The ordinal is irrelevant to correctness
/// (the lane is never serialised); `get`/`set` switch on it.
pub const Lane = enum(u8) {
    /// Full 16-byte `Value`s, `nil` in-band. The fallback / heterogeneous case.
    value,
    /// 1-bit booleans + a presence bitmap.
    boolean,
    i8,
    i16,
    i32,
    i64,
    f64,

    /// True for every lane except `.value` — i.e. lanes that hold no heap
    /// pointers (so the GC can skip marking the array part) and that need a
    /// presence bitmap for holes.
    pub fn isNarrow(self: Lane) bool {
        return self != .value;
    }
};

/// Frozen field offsets for the tier-1b JIT (Phase B, `B0`). Phase B addresses
/// `lane`/`len`/`data`/`present` relative to a `*Table` as
/// `@offsetOf(Table, "array") + ArrayPart.Layout.<field>` — a compile error if
/// this struct's layout ever changes, never a silent JIT miscompile.
pub const ArrayPart = extern struct {
    /// Current storage lane. `extern` pins the field order, so `lane` sits at
    /// offset 0 of the array part — a stable layout Phase B's `guard_lane` reads
    /// as a single byte (the whole point of the `Layout` contract below).
    lane: Lane = .value,
    /// One-shot lane commitment flag (lives in `lane`'s alignment padding, so it
    /// costs no extra bytes). False until a `rehash` commits the array to a
    /// **narrow** lane (`optimalLane` returning `.value` — empty/heterogeneous —
    /// does *not* freeze, leaving a later rehash free to narrow once the contents
    /// settle); true forever after that commit. Once committed, the lane is **monotonic**
    /// — it only ever widens (up the lattice, on the store path) and is never
    /// re-narrowed. This bounds an array's total repack work to amortised O(1)/slot
    /// and removes the repeated-repack attack surface (a fresh table forced to
    /// widen+re-narrow on every rehash). It also distinguishes a fresh, still
    /// in-`.value` array (narrow it at the next rehash) from one demoted to
    /// `.value` by a type-incompatible store (leave it; never re-narrow).
    frozen: bool = false,
    /// Logical slot count: keys `1..len` map to packed indices `0..len-1`. This
    /// is the array part's extent, **not** `#t` (which trims trailing holes).
    len: usize = 0,
    /// Allocated slot capacity (`>= len`); growth amortises like `ArrayList`.
    cap: usize = 0,
    /// Packed element payload, lane-width each. 8-byte aligned so the `.value`
    /// lane can reinterpret it as `[*]Value` and `.i64`/`.f64` stay aligned.
    /// `null` iff `cap == 0`.
    data: ?[*]align(@alignOf(Value)) u8 = null,
    /// Presence bitmap, 1 bit/slot (`null` for the `.value` lane, which encodes
    /// holes in-band). Bit `i` set ⇒ slot `i` holds a value; clear ⇒ hole/`nil`.
    present: ?[*]u8 = null,

    pub const Layout = struct {
        pub const lane = @offsetOf(ArrayPart, "lane");
        pub const frozen = @offsetOf(ArrayPart, "frozen");
        pub const len = @offsetOf(ArrayPart, "len");
        pub const cap = @offsetOf(ArrayPart, "cap");
        pub const data = @offsetOf(ArrayPart, "data");
        pub const present = @offsetOf(ArrayPart, "present");
    };

    pub const empty: ArrayPart = .{};

    pub fn deinit(self: *ArrayPart, gpa: std.mem.Allocator) void {
        if (self.data) |d| gpa.free(d[0..dataBytes(self.lane, self.cap)]);
        if (self.present) |p| gpa.free(p[0..presenceBytes(self.cap)]);
        self.* = .empty;
    }

    /// `true` when the lane holds no heap pointers — the GC marks the array part
    /// only for `.value`.
    pub fn isLeaf(self: *const ArrayPart) bool {
        return self.lane.isNarrow();
    }

    // ---- element access (1-based keys, like the rest of the table) ----

    /// `t[i]` for `1 <= i <= len`. Returns the logical `Value` (or `nil` for a
    /// hole). Caller guarantees the index is in range.
    pub fn get(self: *const ArrayPart, i: usize) Value {
        std.debug.assert(i >= 1 and i <= self.len);
        return self.decode(i - 1);
    }

    /// `t[i] = val` for `1 <= i <= len` (in-place). If `val` does not fit the
    /// current narrow lane, the array part widens **monotonically** up the lane
    /// lattice first (an out-of-range int steps to the next int lane; a
    /// type-incompatible value falls to `.value`) — O(n), but bounded to a handful
    /// of crossings over the array's life. Storing `nil` punches a hole.
    pub fn setInPlace(self: *ArrayPart, gpa: std.mem.Allocator, i: usize, val: Value) std.mem.Allocator.Error!void {
        std.debug.assert(i >= 1 and i <= self.len);
        if (!self.fits(val)) try self.widenFor(gpa, val);
        self.encode(i - 1, val);
    }

    /// Append `val` as the new key `len+1`, growing the storage. Widens the lane
    /// monotonically (see `setInPlace`) if `val` does not fit the current lane.
    pub fn append(self: *ArrayPart, gpa: std.mem.Allocator, val: Value) std.mem.Allocator.Error!void {
        try self.ensureCapacity(gpa, self.len + 1);
        if (!self.fits(val)) try self.widenFor(gpa, val);
        self.len += 1;
        self.encode(self.len - 1, val);
    }

    /// Resize the array part to exactly `n` slots. Growing fills the new slots
    /// with `nil` (holes); shrinking simply drops the tail. Lane is preserved.
    pub fn resize(self: *ArrayPart, gpa: std.mem.Allocator, n: usize) std.mem.Allocator.Error!void {
        if (n > self.cap) try self.ensureCapacity(gpa, n);
        if (n > self.len) {
            // New slots are holes: for narrow lanes the presence bits in
            // `[len, n)` were already zeroed by the growth path; for `.value`
            // write explicit `nil`s (no presence bitmap to lean on).
            if (self.lane == .value) {
                var k = self.len;
                while (k < n) : (k += 1) self.encode(k, Value.nil());
            }
        } else if (n < self.len and self.lane.isNarrow()) {
            // Shrinking: clear presence for the dropped tail so a later regrow
            // doesn't resurrect stale values as "present".
            var k = n;
            while (k < self.len) : (k += 1) self.clearPresent(k);
        }
        self.len = n;
    }

    // ---- lane selection (called from Table.rehash) ----

    /// Scan the live slots and return the narrowest lane that represents them
    /// exactly: `.boolean` if every present value is a boolean, the smallest
    /// signed-int lane covering the observed `[min,max]` if every present value
    /// is an integer, `.f64` if every present value is a float, else `.value`.
    /// Holes never constrain the choice (every lane represents them). An array
    /// with no present values stays `.value` (nothing to gain).
    pub fn optimalLane(self: *const ArrayPart) Lane {
        var any = false;
        var all_bool = true;
        var all_int = true;
        var all_float = true;
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);

        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const v = self.decode(i);
            if (v.isNil()) continue; // hole
            any = true;
            if (v.isInt()) {
                all_bool = false;
                all_float = false;
                const x = v.asInt();
                if (x < lo) lo = x;
                if (x > hi) hi = x;
            } else if (v.isBool()) {
                all_int = false;
                all_float = false;
            } else if (v.isFloat()) {
                all_bool = false;
                all_int = false;
            } else {
                // heap value (or anything else) → only `.value` can hold it.
                return .value;
            }
        }

        if (!any) return .value;
        if (all_bool) return .boolean;
        if (all_float) return .f64;
        if (all_int) return intLaneFor(lo, hi);
        return .value;
    }

    /// Re-encode the array part into `target` (a no-op if already there). Used by
    /// rehash to narrow a `.value` array, or to re-narrow after a widening store.
    pub fn repack(self: *ArrayPart, gpa: std.mem.Allocator, target: Lane) std.mem.Allocator.Error!void {
        if (target == self.lane) return;
        // `repack` is the one-time lane *commitment* (driven by the first rehash).
        // After commit the lane only ever widens — and only via the store path
        // (`widenFor`), never through `repack`. Re-laning a frozen array would be a
        // monotonicity violation (the repeated-repack attack), so enforce it at the
        // type boundary rather than relying solely on the caller's `!frozen` guard.
        std.debug.assert(!self.frozen);
        try self.convert(gpa, target);
    }

    // ===================================================================
    // Internals
    // ===================================================================

    /// Smallest signed-int lane whose range covers `[lo, hi]`.
    fn intLaneFor(lo: i64, hi: i64) Lane {
        if (lo >= std.math.minInt(i8) and hi <= std.math.maxInt(i8)) return .i8;
        if (lo >= std.math.minInt(i16) and hi <= std.math.maxInt(i16)) return .i16;
        if (lo >= std.math.minInt(i32) and hi <= std.math.maxInt(i32)) return .i32;
        return .i64;
    }

    /// Bytes of `data` payload for `cap` slots in `lane`.
    fn dataBytes(lane: Lane, cap: usize) usize {
        return switch (lane) {
            .value => cap * @sizeOf(Value),
            .boolean => bitmapBytes(cap),
            .i8 => cap,
            .i16 => cap * 2,
            .i32 => cap * 4,
            .i64, .f64 => cap * 8,
        };
    }

    /// Bytes of presence bitmap for `cap` slots (0 for the `.value` lane).
    fn presenceBytes(cap: usize) usize {
        return bitmapBytes(cap);
    }

    fn bitmapBytes(slots: usize) usize {
        return (slots + 7) / 8;
    }

    /// Does `val` fit the current lane without widening? `nil` always fits (it is
    /// a hole). For `.value` everything fits.
    fn fits(self: *const ArrayPart, val: Value) bool {
        if (self.lane == .value or val.isNil()) return true;
        return switch (self.lane) {
            .value => true,
            .boolean => val.isBool(),
            .i8 => val.isInt() and inRange(val.asInt(), std.math.minInt(i8), std.math.maxInt(i8)),
            .i16 => val.isInt() and inRange(val.asInt(), std.math.minInt(i16), std.math.maxInt(i16)),
            .i32 => val.isInt() and inRange(val.asInt(), std.math.minInt(i32), std.math.maxInt(i32)),
            .i64 => val.isInt(),
            .f64 => val.isFloat(),
        };
    }

    fn inRange(x: i64, lo: i64, hi: i64) bool {
        return x >= lo and x <= hi;
    }

    // ---- bit helpers (presence bitmap and the boolean value bitmap) ----

    fn getBit(map: [*]const u8, i: usize) bool {
        return (map[i >> 3] >> @intCast(i & 7)) & 1 != 0;
    }
    fn setBit(map: [*]u8, i: usize, on: bool) void {
        const mask = @as(u8, 1) << @intCast(i & 7);
        if (on) map[i >> 3] |= mask else map[i >> 3] &= ~mask;
    }

    fn isPresent(self: *const ArrayPart, idx: usize) bool {
        if (self.present) |p| return getBit(p, idx);
        return false; // narrow lane with no allocation ⇒ no live slots
    }
    fn setPresent(self: *ArrayPart, idx: usize) void {
        if (self.present) |p| setBit(p, idx, true);
    }
    fn clearPresent(self: *ArrayPart, idx: usize) void {
        if (self.present) |p| setBit(p, idx, false);
    }

    // ---- typed element views over `data` ----

    fn valueSlot(self: *const ArrayPart, idx: usize) *Value {
        const base: [*]align(@alignOf(Value)) u8 = self.data.?;
        const vs: [*]Value = @ptrCast(base);
        return &vs[idx];
    }

    /// Decode packed slot `idx` (0-based) into a logical `Value`.
    fn decode(self: *const ArrayPart, idx: usize) Value {
        switch (self.lane) {
            .value => return self.valueSlot(idx).*,
            else => {
                if (!self.isPresent(idx)) return Value.nil();
                const d = self.data.?;
                return switch (self.lane) {
                    .value => unreachable,
                    .boolean => Value.boolean(getBit(d, idx)),
                    .i8 => Value.int(@as(i8, @bitCast(d[idx]))),
                    .i16 => Value.int(readInt(i16, d, idx)),
                    .i32 => Value.int(readInt(i32, d, idx)),
                    .i64 => Value.int(readInt(i64, d, idx)),
                    .f64 => Value.float(@bitCast(readInt(u64, d, idx))),
                };
            },
        }
    }

    /// Encode logical `val` into packed slot `idx` (0-based). Assumes `val` fits
    /// the current lane (caller widens otherwise). `nil` clears presence.
    fn encode(self: *ArrayPart, idx: usize, val: Value) void {
        switch (self.lane) {
            .value => self.valueSlot(idx).* = val,
            else => {
                if (val.isNil()) {
                    self.clearPresent(idx);
                    return;
                }
                const d = self.data.?;
                switch (self.lane) {
                    .value => unreachable,
                    .boolean => setBit(d, idx, val.asBool()),
                    .i8 => d[idx] = @bitCast(@as(i8, @intCast(val.asInt()))),
                    .i16 => writeInt(i16, d, idx, @intCast(val.asInt())),
                    .i32 => writeInt(i32, d, idx, @intCast(val.asInt())),
                    .i64 => writeInt(i64, d, idx, val.asInt()),
                    .f64 => writeInt(u64, d, idx, @bitCast(val.asFloat())),
                }
                self.setPresent(idx);
            },
        }
    }

    fn readInt(comptime T: type, d: [*]const u8, idx: usize) T {
        const n = @sizeOf(T);
        var buf: [n]u8 = undefined;
        @memcpy(&buf, d[idx * n ..][0..n]);
        return std.mem.readInt(T, &buf, .little);
    }
    fn writeInt(comptime T: type, d: [*]u8, idx: usize, v: T) void {
        const n = @sizeOf(T);
        var buf: [n]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        @memcpy(d[idx * n ..][0..n], &buf);
    }

    // ---- allocation / growth / lane conversion ----

    fn allocData(gpa: std.mem.Allocator, lane: Lane, cap: usize) std.mem.Allocator.Error!?[*]align(@alignOf(Value)) u8 {
        const nbytes = dataBytes(lane, cap);
        if (nbytes == 0) return null;
        const slice = try gpa.alignedAlloc(u8, std.mem.Alignment.of(Value), nbytes);
        return slice.ptr;
    }

    fn allocPresence(gpa: std.mem.Allocator, cap: usize) std.mem.Allocator.Error!?[*]u8 {
        const nbytes = presenceBytes(cap);
        if (nbytes == 0) return null;
        const slice = try gpa.alloc(u8, nbytes);
        @memset(slice, 0); // all slots absent until written
        return slice.ptr;
    }

    /// Ensure `cap >= needed`, reallocating `data` (and the presence bitmap for a
    /// narrow lane) and preserving existing contents. New capacity grows
    /// geometrically. New slots are left absent (presence zeroed); `.value`
    /// new slots are written by the caller (`append`/`resize`) before being read.
    fn ensureCapacity(self: *ArrayPart, gpa: std.mem.Allocator, needed: usize) std.mem.Allocator.Error!void {
        if (needed <= self.cap) return;
        // Cap growth so the widest-lane byte math (`cap * @sizeOf(Value)`) can never
        // overflow `usize` — critical on wasm32 where `usize` is 32-bit, since a
        // wrapped (tiny) allocation behind a huge `cap` would be a heap overflow.
        const max_cap = std.math.maxInt(usize) / @sizeOf(Value);
        if (needed > max_cap) return error.OutOfMemory;
        var new_cap = if (self.cap == 0) @as(usize, 8) else self.cap;
        while (new_cap < needed) new_cap = @min(new_cap *| 2, max_cap);

        // Allocate *both* new buffers before freeing or mutating anything: an OOM on
        // the presence alloc must not leave `self` half-rewritten (old data freed,
        // `cap` stale) — that would later free the wrong slice length and corrupt.
        const new_data = try allocData(gpa, self.lane, new_cap);
        errdefer if (new_data) |nd| gpa.free(nd[0..dataBytes(self.lane, new_cap)]);

        var new_present: ?[*]u8 = null;
        if (self.lane.isNarrow()) new_present = try allocPresence(gpa, new_cap);

        // Both allocations succeeded — now it is safe to copy, free, and commit.
        if (self.data) |old| {
            // Copy the live payload. For bit-packed lanes the live byte count is
            // ceil(len/8); for byte lanes it's len*width. Copying `dataBytes(len)`
            // covers exactly the occupied prefix.
            const live = dataBytes(self.lane, self.len);
            if (live > 0) @memcpy(new_data.?[0..live], old[0..live]);
            gpa.free(old[0..dataBytes(self.lane, self.cap)]);
        }
        if (new_present) |np| {
            if (self.present) |old| {
                const live = presenceBytes(self.len);
                if (live > 0) @memcpy(np[0..live], old[0..live]);
                gpa.free(old[0..presenceBytes(self.cap)]);
            }
        }
        self.data = new_data;
        self.present = new_present;
        self.cap = new_cap;
    }

    /// Convert the array part to `target` by re-encoding every live slot through
    /// a logical `Value`. Allocates fresh storage sized to the current `cap`,
    /// copies, then frees the old buffers.
    fn convert(self: *ArrayPart, gpa: std.mem.Allocator, target: Lane) std.mem.Allocator.Error!void {
        std.debug.assert(target != self.lane);
        const cap = self.cap;

        const new_data = try allocData(gpa, target, cap);
        errdefer if (new_data) |nd| gpa.free(nd[0..dataBytes(target, cap)]);
        const new_present: ?[*]u8 = if (target.isNarrow()) try allocPresence(gpa, cap) else null;

        // Build a temporary view of the destination to encode into, then commit.
        // `frozen` carries through unchanged: a monotonic widen on the store path
        // must keep the array committed (else the next rehash would re-narrow it).
        var dst: ArrayPart = .{
            .lane = target,
            .frozen = self.frozen,
            .len = self.len,
            .cap = cap,
            .data = new_data,
            .present = new_present,
        };
        var i: usize = 0;
        while (i < self.len) : (i += 1) dst.encode(i, self.decode(i));

        // Free the old buffers and adopt the converted storage.
        if (self.data) |old| gpa.free(old[0..dataBytes(self.lane, self.cap)]);
        if (self.present) |old| gpa.free(old[0..presenceBytes(self.cap)]);
        self.* = dst;
    }

    /// Monotonic widen: climb the lane lattice just enough to hold `val`, which
    /// the caller has determined does **not** fit the current (narrow) lane. An
    /// int that outgrows its lane steps up to the next int lane (i8→i16→i32→i64);
    /// any type-incompatible value (a float into an int lane, a bool into an int
    /// lane, a heap value, …) falls straight to `.value`. The lane never narrows
    /// again, so over an array's lifetime it crosses at most a handful of
    /// boundaries — total widening work is amortised O(1) per slot, and the
    /// repeated-repack attack (re-narrowing at every rehash) is structurally gone.
    fn widenFor(self: *ArrayPart, gpa: std.mem.Allocator, val: Value) std.mem.Allocator.Error!void {
        std.debug.assert(self.lane.isNarrow()); // `.value` fits everything; caller short-circuits
        const target: Lane = switch (self.lane) {
            .value => unreachable,
            // A non-fitting int needs a strictly wider int lane (`intLaneFor`
            // returns the narrowest covering it, which is necessarily > current,
            // and every wider int lane is a superset — existing slots re-encode
            // exactly). A non-int forces the type-erased `.value` lane.
            .i8, .i16, .i32, .i64 => if (val.isInt()) intLaneFor(val.asInt(), val.asInt()) else .value,
            // boolean/f64 lanes are type-pure: any value that doesn't fit means a
            // type mismatch, which only `.value` can hold.
            .boolean, .f64 => .value,
        };
        std.debug.assert(target != self.lane);
        try self.convert(gpa, target);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build an array part by appending `vals` (keys 1..n).
fn fromSlice(gpa: std.mem.Allocator, vals: []const Value) !ArrayPart {
    var a: ArrayPart = .empty;
    for (vals) |v| try a.append(gpa, v);
    return a;
}

test "value lane: round-trips every value kind incl. nil holes" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);

    try a.append(gpa, Value.int(7));
    try a.append(gpa, Value.nil()); // explicit hole
    try a.append(gpa, Value.float(2.5));
    try a.append(gpa, Value.boolean(true));

    try testing.expectEqual(Lane.value, a.lane);
    try testing.expectEqual(@as(usize, 4), a.len);
    try testing.expectEqual(@as(i64, 7), a.get(1).asInt());
    try testing.expect(a.get(2).isNil());
    try testing.expectEqual(@as(f64, 2.5), a.get(3).asFloat());
    try testing.expectEqual(true, a.get(4).asBool());
}

test "boolean lane: repack packs true/false/hole at ~2 bits/slot" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);

    // hole at 1, then alternating booleans — the nsieve shape.
    try a.append(gpa, Value.nil());
    var i: usize = 2;
    while (i <= 65) : (i += 1) try a.append(gpa, Value.boolean(i % 3 == 0));

    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.boolean, a.lane);
    try testing.expect(a.get(1).isNil());
    i = 2;
    while (i <= 65) : (i += 1) {
        try testing.expectEqual(i % 3 == 0, a.get(i).asBool());
    }
}

test "int lanes: narrowest covering [min,max] is chosen" {
    const gpa = testing.allocator;
    {
        var a = try fromSlice(gpa, &.{ Value.int(0), Value.int(127), Value.int(-128) });
        defer a.deinit(gpa);
        try testing.expectEqual(Lane.i8, a.optimalLane());
    }
    {
        var a = try fromSlice(gpa, &.{ Value.int(0), Value.int(65000) });
        defer a.deinit(gpa);
        // 65000 > i16 max (32767) ⇒ needs i32 (the "ints up to 65k" example).
        try testing.expectEqual(Lane.i32, a.optimalLane());
    }
    {
        var a = try fromSlice(gpa, &.{ Value.int(0), Value.int(30000), Value.int(-30000) });
        defer a.deinit(gpa);
        try testing.expectEqual(Lane.i16, a.optimalLane());
    }
    {
        var a = try fromSlice(gpa, &.{ Value.int(1 << 40) });
        defer a.deinit(gpa);
        try testing.expectEqual(Lane.i64, a.optimalLane());
    }
}

test "int lane: values survive a repack and decode exactly" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: i64 = 1;
    while (i <= 50) : (i += 1) try a.append(gpa, Value.int(i * 100)); // up to 5000 → i16

    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.i16, a.lane);
    i = 1;
    while (i <= 50) : (i += 1) try testing.expectEqual(i * 100, a.get(@intCast(i)).asInt());
}

test "f64 lane round-trips" {
    const gpa = testing.allocator;
    var a = try fromSlice(gpa, &.{ Value.float(1.5), Value.float(-2.25), Value.float(3.0e10) });
    defer a.deinit(gpa);
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.f64, a.lane);
    try testing.expectEqual(@as(f64, 1.5), a.get(1).asFloat());
    try testing.expectEqual(@as(f64, -2.25), a.get(2).asFloat());
    try testing.expectEqual(@as(f64, 3.0e10), a.get(3).asFloat());
}

test "widening: an out-of-lane store reverts to the value lane, preserving slots" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: usize = 1;
    while (i <= 10) : (i += 1) try a.append(gpa, Value.boolean(true));
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.boolean, a.lane);

    // Store an int into a boolean lane → must widen to .value and keep the rest.
    try a.setInPlace(gpa, 5, Value.int(42));
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expectEqual(@as(i64, 42), a.get(5).asInt());
    try testing.expectEqual(true, a.get(1).asBool());
    try testing.expectEqual(true, a.get(10).asBool());
}

test "widening on append of an out-of-lane value" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: usize = 1;
    while (i <= 10) : (i += 1) try a.append(gpa, Value.int(@intCast(i)));
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.i8, a.lane);

    try a.append(gpa, Value.float(1.5)); // doesn't fit i8 → widen
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expectEqual(@as(usize, 11), a.len);
    try testing.expectEqual(@as(i64, 1), a.get(1).asInt());
    try testing.expectEqual(@as(f64, 1.5), a.get(11).asFloat());
}

test "monotonic widen: an int outgrowing its lane steps up the int ladder, not to value" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);

    // Pack into i8 (all values in [-128, 127]).
    var i: usize = 1;
    while (i <= 10) : (i += 1) try a.append(gpa, Value.int(@intCast(i)));
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.i8, a.lane);

    // Store 1000 (out of i8, fits i16) → steps up to i16, NOT .value.
    try a.setInPlace(gpa, 3, Value.int(1000));
    try testing.expectEqual(Lane.i16, a.lane);
    try testing.expectEqual(@as(i64, 1000), a.get(3).asInt());
    try testing.expectEqual(@as(i64, 1), a.get(1).asInt()); // earlier slots intact

    // Append 100000 (out of i16, fits i32) → steps up to i32.
    try a.append(gpa, Value.int(100000));
    try testing.expectEqual(Lane.i32, a.lane);
    try testing.expectEqual(@as(i64, 100000), a.get(11).asInt());

    // Append 1<<40 (out of i32) → i64.
    try a.append(gpa, Value.int(1 << 40));
    try testing.expectEqual(Lane.i64, a.lane);
    try testing.expectEqual(@as(i64, 1 << 40), a.get(12).asInt());
}

test "monotonic widen: a type-incompatible store still falls straight to value" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: usize = 1;
    while (i <= 10) : (i += 1) try a.append(gpa, Value.int(@intCast(i)));
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.i8, a.lane);

    // A float into an int lane is a type mismatch → no int lane covers it → .value.
    try a.setInPlace(gpa, 4, Value.float(1.5));
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expectEqual(@as(f64, 1.5), a.get(4).asFloat());
    try testing.expectEqual(@as(i64, 1), a.get(1).asInt());
}

test "monotonic: a frozen lane is preserved across a widening convert" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: usize = 1;
    while (i <= 10) : (i += 1) try a.append(gpa, Value.int(@intCast(i)));
    try a.repack(gpa, a.optimalLane());
    a.frozen = true; // simulate the rehash commit

    try a.setInPlace(gpa, 3, Value.int(1000)); // i8 → i16 via widenFor/convert
    try testing.expectEqual(Lane.i16, a.lane);
    try testing.expect(a.frozen); // commitment survives the widen
}

test "resize grows with holes and shrinks dropping the tail" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, Value.int(1));
    try a.append(gpa, Value.int(2));
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.i8, a.lane);

    try a.resize(gpa, 6); // grow → slots 3..6 are holes
    try testing.expectEqual(@as(usize, 6), a.len);
    try testing.expectEqual(@as(i64, 2), a.get(2).asInt());
    try testing.expect(a.get(3).isNil());
    try testing.expect(a.get(6).isNil());

    try a.resize(gpa, 1); // shrink
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqual(@as(i64, 1), a.get(1).asInt());
}

test "empty / all-hole array stays in the value lane" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try testing.expectEqual(Lane.value, a.optimalLane());
    try a.append(gpa, Value.nil());
    try a.append(gpa, Value.nil());
    try testing.expectEqual(Lane.value, a.optimalLane());
}

test "isLeaf tracks the lane" {
    const gpa = testing.allocator;
    var a = try fromSlice(gpa, &.{ Value.int(1), Value.int(2) });
    defer a.deinit(gpa);
    try testing.expect(!a.isLeaf()); // value lane
    try a.repack(gpa, a.optimalLane());
    try testing.expect(a.isLeaf()); // narrow
}

test "Layout offsets are stable and lane is first" {
    // Phase B's JIT encodes these offsets via `@offsetOf`; pin them so a layout
    // drift fails here rather than silently miscompiling native array access.
    try testing.expectEqual(@as(usize, 0), ArrayPart.Layout.lane);
    // `frozen` rides in `lane`'s alignment padding (offset 1), so it must NOT push
    // the pointer-aligned fields out: `len` still lands at the first usize-aligned
    // offset and the three word-sized fields follow contiguously. Derived from
    // `@sizeOf(usize)` so the contract holds on both 64- and 32-bit targets.
    const word = @sizeOf(usize);
    try testing.expectEqual(@as(usize, 1), ArrayPart.Layout.frozen);
    try testing.expectEqual(@alignOf(usize), ArrayPart.Layout.len);
    try testing.expectEqual(ArrayPart.Layout.len + word, ArrayPart.Layout.cap);
    try testing.expectEqual(ArrayPart.Layout.cap + word, ArrayPart.Layout.data);
    try testing.expectEqual(ArrayPart.Layout.data + word, ArrayPart.Layout.present);
    try testing.expectEqual(ArrayPart.Layout.present + word, @sizeOf(ArrayPart));
}

test "OOM at any allocation point leaves the array part consistent (no leak, no bad free)" {
    // `checkAllAllocationFailures` reruns the body forcing each successive
    // allocation to fail. The testing allocator then asserts no leak and no
    // invalid free — so a half-rewritten `ensureCapacity`/`convert`/`widenToValue`
    // (the OOM hazards the review flagged) is caught here.
    const Inner = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var a: ArrayPart = .empty;
            defer a.deinit(gpa);
            // Grow in the value lane → exercises ensureCapacity's realloc + free.
            var i: i64 = 1;
            while (i <= 20) : (i += 1) try a.append(gpa, Value.int(i));
            // Repack value→narrow → exercises convert (data + presence allocs).
            try a.repack(gpa, a.optimalLane());
            // An out-of-lane store widens narrow→value → exercises widenToValue.
            try a.setInPlace(gpa, 5, Value.float(2.5));
            // Grow again in the (now value) lane to re-exercise ensureCapacity.
            try a.append(gpa, Value.int(99));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Inner.run, .{});
}
