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
//! - `.boolean` — `data` is **one byte per slot**, encoding all three states
//!   in-band: `0 = absent (hole)`, `1 = false`, `2 = true`. No presence bitmap.
//!   The byte is the smallest unit x86 can touch with a single non-RMW
//!   instruction, so a store is one `mov byte` and a load one `movzx` (vs. the
//!   `bt`/`bts`/`btr` read-modify-write a sub-byte bit-packing would force). ~1
//!   byte/slot — 4× a 2-bit packing, still far under a 16 B `Value`.
//! - `.i8/.i16/.i32/.i64` — `data` is packed integers at lane width; `present` is
//!   a separate 1-bit/slot presence bitmap (every int bit pattern is a valid
//!   value, so a hole needs the out-of-band bit).
//! - `.f64` — `data` is packed doubles; `present` is the presence bitmap.
//!
//! Holes round-trip as `nil`: the `.value` and `.boolean` lanes encode absence
//! in-band; the fixed-width int/float lanes carry the presence bitmap
//! (`Lane.usesPresenceBitmap`). `get`/`set` translate between the packed lane and
//! a logical `Value`; the rest of the VM only ever sees `Value`s.
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
    /// One byte per slot: `0 = absent, 1 = false, 2 = true` (presence in-band).
    boolean,
    i8,
    i16,
    i32,
    i64,
    f64,
    /// One byte per slot, holding an unsigned byte `0..255` (zero-extended on
    /// read). The byte-array lane: a non-negative integer `<= 255` packs here at
    /// 1 byte/slot instead of paying `i16`'s two (a byte overflows signed `i8`'s
    /// 127 ceiling). A negative or `> 255` store widens it to the signed ladder.
    /// Appended last so the existing ordinals stay put (trace IR embeds the lane
    /// ordinal in `guard_lane.aux`); lattice order lives in `canWidenTo`, not the
    /// ordinal.
    u8,

    /// The **grid meta-lane** (doc 14): this array part is a flattened nested
    /// numeric array. `data` is a flat row-major `[cap*stride]` buffer of
    /// `grid_elem`-width scalar cells; `present` is a per-*cell* presence bitmap
    /// over those `cap*stride` cells; `row_len[r]` is the logical length of row
    /// `r`; `len` is the row count and `cap` the row capacity. Its outer
    /// "element" is a **row**, not a scalar — read as a value it is a transient
    /// `row_view` `Value` (Phase 3), never a packed scalar — so the scalar
    /// `decode`/`encode`/`get`/`append`/widen paths do **not** apply to it. Grid
    /// access goes through the dedicated `initGrid`/`gridGet`/`gridSet`/`gridRowLen`
    /// methods below; the scalar paths assert `lane != .grid`. Appended at the end
    /// (ordinal 8) so every existing `guard_lane.aux` ordinal stays put. Not a rung
    /// of the scalar widening lattice — `canWidenTo` keeps it isolated; inflation
    /// into a grid is a separate migration (Phase 4), never a `widenFor` step.
    grid,

    /// True for every lane except `.value` — i.e. lanes that hold no heap
    /// pointers (so the GC can skip marking the array part and the native store
    /// needs no write barrier). The grid lane is narrow too: its cells are scalar
    /// leaves and its rows are virtual (a `row_view` is a fat *value*, never a
    /// stored heap pointer), so a grid array part has no heap edges to mark.
    pub fn isNarrow(self: Lane) bool {
        return self != .value;
    }

    /// True for lanes that track holes with a *separate* 1-bit/slot presence
    /// bitmap. The `.value` lane encodes `nil` in-band (a `nil`-tagged `Value`);
    /// the `.boolean` lane likewise encodes absence in-band (its data byte is
    /// `0 = absent, 1 = false, 2 = true`, so a single byte holds all three
    /// states — no bitmap, one non-RMW store/load per slot). Only the fixed-width
    /// `i8…f64` lanes, whose every bit pattern is a valid value, need the bitmap.
    pub fn usesPresenceBitmap(self: Lane) bool {
        return switch (self) {
            .value, .boolean => false,
            .i8, .i16, .i32, .i64, .f64, .u8 => true,
            // The grid keeps a per-*cell* presence bitmap (over `cap*stride`
            // cells), but its size is grid-specific (`gridCells`), so the grid
            // never flows through the scalar alloc/`deinit` paths that consult
            // this predicate — those assert `lane != .grid`. Reported truthfully.
            .grid => true,
        };
    }

    /// True for the fixed-width integer **store-shape** lanes (`i8…i64`, plus the
    /// unsigned-byte `u8`). These share a single native store shape — a
    /// width-truncating data write plus a presence-bit set (`encode`) — so the JIT
    /// grow/in-bounds store paths branch on this to pick the int lowering vs the
    /// boolean in-band byte. The only signedness difference is on the *read*
    /// (`u8` zero-extends, the signed lanes sign-extend), handled in `decode` and
    /// the native `aload`. `.f64` is excluded: it needs XMM stores the native array
    /// path does not yet emit.
    pub fn isInt(self: Lane) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .u8 => true,
            .value, .boolean, .f64 => false,
            // Not a scalar store-shape lane — grid stores go through the grid
            // cell path, never the scalar int/grow lowering this gates.
            .grid => false,
        };
    }

    /// Can a frozen array currently on `self` ever *become* `target` by future
    /// stores? Lanes only widen monotonically (`widenFor`) and never re-narrow,
    /// so this is the reachability relation of the widening lattice:
    ///
    ///   - `value` is the top (type-erased) lane: it only reaches itself.
    ///   - `boolean` and `f64` are type-pure: they reach only themselves and
    ///     `value` (any off-type store erases straight to `value`).
    ///   - the int ladder widens upward `i8→i16→i32→i64`, and any int lane can
    ///     also erase to `value` on a non-int store.
    ///   - `u8` (the unsigned-byte lane, range `[0,255]`) is a sibling entry point,
    ///     not a rung below `i8`: a store outside `[0,255]` (negative or `>255`)
    ///     widens it to the smallest *signed* lane covering `[0,255] ∪ {v}`, which
    ///     is always `≥ i16` (never `i8`, never back to `u8`). Nothing widens *to*
    ///     `u8` — it is only ever an initial commitment (`laneForValue`/
    ///     `optimalLane`).
    ///
    /// The JIT uses this for widen-eviction: a trace whose `guard_lane` pins
    /// lane `T` is permanently dead once the live array sits on a lane `L` with
    /// `!L.canWidenTo(T)` — monotonicity guarantees `T` can never be live again,
    /// so the guard can never pass and the trace's anchor slot should be freed.
    pub fn canWidenTo(self: Lane, target: Lane) bool {
        if (self == target) return true;
        return switch (self) {
            .value => false,
            .boolean => target == .value,
            .f64 => target == .value,
            .i8 => target == .i16 or target == .i32 or target == .i64 or target == .value,
            .i16 => target == .i32 or target == .i64 or target == .value,
            .i32 => target == .i64 or target == .value,
            .i64 => target == .value,
            .u8 => target == .i16 or target == .i32 or target == .i64 or target == .value,
            // The grid is not part of the scalar widening lattice (it holds rows,
            // not scalars): it reaches only itself (the `self == target` early
            // return above), and nothing scalar widens *to* it via this relation —
            // inflation into a grid is a separate migration (Phase 4), not a
            // `widenFor` rung. So a grid-pinned guard is never widen-evicted by a
            // scalar widen, and a scalar guard is never satisfied by a grid.
            .grid => false,
        };
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
    /// **Grid sub-lane** (doc 14): meaningful only when `lane == .grid`, where it
    /// names the scalar lane every flattened *cell* is packed at (a presence-bitmap
    /// fixed-width lane — `i8`/`u8`/`i16`/`i32`/`i64`/`f64`; the boolean/value lanes
    /// are out of grid scope in v1). On every non-grid lane it is `.value` and
    /// unused. Rides in `lane`/`frozen`'s alignment padding (offset 2), so adding it
    /// costs no bytes and does **not** move `len`/`cap`/`data`/`present` — the
    /// nativegen `Layout` offsets the JIT already encodes against are byte-identical.
    grid_elem: Lane = .value,
    /// Logical slot count: keys `1..len` map to packed indices `0..len-1`. This
    /// is the array part's extent, **not** `#t` (which trims trailing holes).
    /// For a grid, this is the **row count**.
    len: usize = 0,
    /// Allocated slot capacity (`>= len`); growth amortises like `ArrayList`.
    /// For a grid, this is the allocated **row capacity** (`data` holds
    /// `cap*stride` cells).
    cap: usize = 0,
    /// Packed element payload, lane-width each. 8-byte aligned so the `.value`
    /// lane can reinterpret it as `[*]Value` and `.i64`/`.f64` stay aligned.
    /// `null` iff `cap == 0`.
    data: ?[*]align(@alignOf(Value)) u8 = null,
    /// Presence bitmap, 1 bit/slot (`null` for the `.value` lane, which encodes
    /// holes in-band). Bit `i` set ⇒ slot `i` holds a value; clear ⇒ hole/`nil`.
    /// For a grid, this is the per-*cell* bitmap over `cap*stride` cells (bit
    /// `row*stride + col`).
    present: ?[*]u8 = null,
    /// **Grid stride** (doc 14): meaningful only when `lane == .grid` — the number
    /// of cells per row, so cell `(row, col)` lives at flat index `row*stride+col`.
    /// `0` on every non-grid lane. Appended after `present` so the existing JIT
    /// `Layout` offsets are undisturbed.
    stride: usize = 0,
    /// **Grid per-row logical length** (doc 14): meaningful only when
    /// `lane == .grid` — `row_len[r]` is the high-water logical length of row `r`
    /// (`0 <= row_len[r] <= stride`), the row's `#`-border analogue, so jagged rows
    /// round-trip. `null` on every non-grid lane. Appended last.
    row_len: ?[*]u32 = null,

    pub const Layout = struct {
        pub const lane = @offsetOf(ArrayPart, "lane");
        pub const frozen = @offsetOf(ArrayPart, "frozen");
        pub const grid_elem = @offsetOf(ArrayPart, "grid_elem");
        pub const len = @offsetOf(ArrayPart, "len");
        pub const cap = @offsetOf(ArrayPart, "cap");
        pub const data = @offsetOf(ArrayPart, "data");
        pub const present = @offsetOf(ArrayPart, "present");
        pub const stride = @offsetOf(ArrayPart, "stride");
        pub const row_len = @offsetOf(ArrayPart, "row_len");
    };

    pub const empty: ArrayPart = .{};

    pub fn deinit(self: *ArrayPart, gpa: std.mem.Allocator) void {
        if (self.lane == .grid) {
            // Grid buffers are sized by the flattened cell count (`cap*stride`),
            // not the scalar `cap`, and carry the extra `row_len` vector — free
            // them on their own terms.
            const cells = gridCells(self.cap, self.stride);
            if (self.data) |d| gpa.free(d[0..dataBytes(self.grid_elem, cells)]);
            if (self.present) |p| gpa.free(p[0..presenceBytes(cells)]);
            if (self.row_len) |r| gpa.free(r[0..self.cap]);
            self.* = .empty;
            return;
        }
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

    /// THE membership predicate for the array part: does logical key `k` have a
    /// slot? Defined exactly once so every tier and every routing site shares one
    /// contract (doc 18 D1). Today's layout: keys `1..len`. After the doc-18 flip
    /// this becomes the LuaJIT-style unsigned compare
    /// `@as(u64, @bitCast(k)) < extent` (identity mapping, slot 0 included) — a
    /// ONE-LINE change here, mirrored per tier, nowhere else.
    pub inline fn inArray(k: i64, extent: usize) bool {
        return k >= 1 and k <= @as(i64, @intCast(extent));
    }

    /// `t[i]` for `1 <= i <= len`. Returns the logical `Value` (or `nil` for a
    /// hole). Caller guarantees the index is in range.
    // `inline`: the tier-0 interpreter reads `t[i]` through this on its hottest path
    // (`.get_index` arm, interp.zig). Across the interp.zig→array.zig module boundary
    // LLVM was leaving `get`→`decode` out-of-line (the profile showed `decode` as ~55%
    // of scimark-sparse / ~11% of fft, a *call per element*). Forcing the chain inline
    // lets the loop-invariant lane `switch` hoist and kills the call overhead.
    pub inline fn get(self: *const ArrayPart, i: usize) Value {
        std.debug.assert(self.lane != .grid); // a grid's element is a row, not a scalar (Phase 3)
        std.debug.assert(i >= 1 and i <= self.len);
        return self.decode(i - 1);
    }

    /// `t[i] = val` for `1 <= i <= len` (in-place). If `val` does not fit the
    /// current narrow lane, the array part widens **monotonically** up the lane
    /// lattice first (an out-of-range int steps to the next int lane; a
    /// type-incompatible value falls to `.value`) — O(n), but bounded to a handful
    /// of crossings over the array's life. Storing `nil` punches a hole.
    pub fn setInPlace(self: *ArrayPart, gpa: std.mem.Allocator, i: usize, val: Value) std.mem.Allocator.Error!void {
        std.debug.assert(self.lane != .grid); // grid stores go through gridSet (Phase 3/4)
        std.debug.assert(i >= 1 and i <= self.len);
        if (!self.fits(val)) try self.widenFor(gpa, val);
        self.encode(i - 1, val);
    }

    /// `t[i] = val` for `1 <= i <= len`, where `val` is **already known to fit**
    /// the current lane (the caller has guarded it) — so no allocation, no widen,
    /// no `gpa`. This is the JIT oracle's in-lane store (`astore`): the recorder
    /// only emits an `astore` for an in-bounds, in-lane value, so `irinterp` can
    /// reproduce the native store byte-for-byte without an allocator. Asserts the
    /// fit so a recorder bug trips in debug rather than silently truncating.
    // `inline`: mirror of `get` for the `.set_index` hot path (and the tier-1a oracle's
    // `astore`). Folds `setInLane`→`encode` into the caller so the store is a direct
    // packed write, not a cross-module call.
    pub inline fn setInLane(self: *ArrayPart, i: usize, val: Value) void {
        std.debug.assert(self.lane != .grid); // grid stores go through gridSet (Phase 3/4)
        std.debug.assert(i >= 1 and i <= self.len);
        std.debug.assert(self.fits(val));
        self.encode(i - 1, val);
    }

    /// Append `val` as the new key `len+1` **within the current capacity**, where
    /// `val` is already known to fit the lane and `len < cap` — so no allocator, no
    /// `ensureCapacity`, no widen, and (unlike `Table.set`'s append) no
    /// `migrateFromHash`. This is the JIT's grow-store oracle (`astore_append`): the
    /// recorder only emits it behind a `guard_append` that proves `idx == len+1`,
    /// `len < cap`, and an empty hash part (so migration would be a no-op), so
    /// `irinterp` reproduces the native grow-store byte-for-byte without touching
    /// the allocator or the hash. Asserts the room + fit so a recorder bug trips in
    /// debug rather than corrupting the array. The realloc itself stays a tier-0
    /// side-exit (the `guard_append` capacity check), keeping every mode identical.
    pub fn appendInCap(self: *ArrayPart, val: Value) void {
        std.debug.assert(self.lane != .grid); // grid growth is a reshape (Phase 4), not a scalar append
        std.debug.assert(self.len < self.cap);
        std.debug.assert(self.fits(val));
        self.len += 1;
        self.encode(self.len - 1, val);
    }

    /// Append `val` as the new key `len+1`, growing the storage. Widens the lane
    /// monotonically (see `setInPlace`) if `val` does not fit the current lane.
    pub fn append(self: *ArrayPart, gpa: std.mem.Allocator, val: Value) std.mem.Allocator.Error!void {
        std.debug.assert(self.lane != .grid); // grid growth is a reshape (Phase 4), not a scalar append
        // Eager narrow-lane commit on the first append into a fresh array. The
        // append fast path never reaches `Table.rehash` (a dense-from-1 fill keeps
        // the hash part empty), so without this a homogeneous bool/int/float fill
        // would stay on `.value` and the JIT recorder would abort on a `.value`
        // lane (`recArraySet` in trace.zig). Commit once, then `frozen` makes the
        // lane monotonic — it only ever widens after, via the `widenFor` path
        // below. Pure in-memory: the lane is never serialised, so it is invisible
        // to keyframe snapshots and to `get()` (which round-trips logical Values on
        // any lane). A from-scratch run evolves the lane purely as a function of the
        // append sequence, so all 8 execution modes agree; and because the lane
        // never escapes, a keyframe restore that arrives at a different lane (e.g. a
        // rehash-narrowed table whose hole-at-1 replays as a nil-first append) is
        // still observably identical.
        if (self.lane == .value and !self.frozen and self.len == 0 and !val.isNil()) {
            const target = laneForValue(val);
            if (target.isNarrow()) {
                if (self.data != null) {
                    // A previously-used buffer (e.g. after `resize(0)` or removal)
                    // is still `.value`-width — reallocate it at the narrow width.
                    // `len == 0`, so the element-copy is a no-op. `convert` is
                    // OOM-atomic: on failure the array is left untouched (.value,
                    // !frozen) and the append retries cleanly.
                    try self.convert(gpa, target);
                } else {
                    // Truly fresh: commit the lane and secure narrow-width capacity
                    // now. `ensureCapacity` allocates against `self.lane` and is
                    // itself OOM-atomic, so on failure roll the speculative lane
                    // back to `.value` — the array stays fresh (len 0, !frozen) and
                    // retryable, never frozen onto a value that was never stored.
                    self.lane = target;
                    self.ensureCapacity(gpa, 1) catch |e| {
                        self.lane = .value;
                        return e;
                    };
                }
                // Both arms have committed durably (capacity secured) → freeze.
                self.frozen = true;
            }
        }
        try self.ensureCapacity(gpa, self.len + 1);
        if (!self.fits(val)) try self.widenFor(gpa, val);
        self.len += 1;
        self.encode(self.len - 1, val);
    }

    /// Seed a FRESH array part from its first array-resident write `t[k] = val`
    /// (doc 18 D2a). Preconditions (asserted): empty part (`len == 0`, no grid),
    /// non-nil `val` (a nil write to a fresh table is a no-op/hash-delete and must
    /// never mint an extent), and `k` in the seedable key set. Commits the lane
    /// eagerly from `val` (the first REAL value — hole slots never influence lane
    /// choice) with the same OOM-atomicity as `append`: on failure the part is
    /// left untouched (`len == 0`, `.value`, `!frozen`).
    ///
    /// Phase 1 (current layout): only `k == 1` is seedable and seeding IS
    /// `append(val)` — key 1 lands in physical slot 0, `len = 1`. After the
    /// doc-18 flip the seedable set becomes `{0, 1}`, seeding creates
    /// `asize = k + 1` with a slot-0 hole for `k == 1`, and presence is set for
    /// slot `k` only.
    pub fn seedAt(self: *ArrayPart, gpa: std.mem.Allocator, k: i64, val: Value) std.mem.Allocator.Error!void {
        std.debug.assert(self.lane != .grid);
        std.debug.assert(self.len == 0);
        std.debug.assert(!val.isNil());
        std.debug.assert(k == 1); // Phase 1 seedable set; {0, 1} after the flip
        try self.append(gpa, val);
    }

    /// Resize the array part to exactly `n` slots. Growing fills the new slots
    /// with `nil` (holes); shrinking simply drops the tail. Lane is preserved.
    pub fn resize(self: *ArrayPart, gpa: std.mem.Allocator, n: usize) std.mem.Allocator.Error!void {
        std.debug.assert(self.lane != .grid); // grid resize is a reshape (Phase 4)
        if (n > self.cap) try self.ensureCapacity(gpa, n);
        if (n > self.len) {
            // New slots are holes. The int/float lanes lean on the presence
            // bitmap (zeroed by the growth path); the boolean lane leans on its
            // in-band data bytes (zeroed by `allocData`, and re-zeroed on shrink
            // below) — both already read `[len, n)` as absent. Only `.value`, with
            // no out-of-band hole marker, must write explicit `nil`s.
            if (self.lane == .value) {
                var k = self.len;
                while (k < n) : (k += 1) self.encode(k, Value.nil());
            }
        } else if (n < self.len and self.lane.isNarrow()) {
            // Shrinking: punch the dropped tail back to holes so a later regrow
            // doesn't resurrect stale values as "present". `encode(nil)` does the
            // right thing per lane — clears the presence bit for the bitmap lanes,
            // zeroes the in-band byte for the boolean lane.
            var k = n;
            while (k < self.len) : (k += 1) self.encode(k, Value.nil());
        }
        self.len = n;
    }

    // ---- lane selection (called from Table.rehash) ----

    /// Scan the live slots and return the narrowest lane that represents them
    /// exactly: `.boolean` if every present value is a boolean, the narrowest int
    /// lane covering the observed `[min,max]` if every present value is an integer
    /// (`u8` when `[0,255]`, else the smallest signed lane — see `intLaneForRange`),
    /// `.f64` if every present value is a float, else `.value`.
    /// Holes never constrain the choice (every lane represents them). An array
    /// with no present values stays `.value` (nothing to gain).
    pub fn optimalLane(self: *const ArrayPart) Lane {
        std.debug.assert(self.lane != .grid); // grid never re-narrows through the scalar rehash
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
        if (all_int) return intLaneForRange(lo, hi);
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

    /// Narrow lane a single value commits to on a fresh array — the per-element
    /// form of `optimalLane`. Heap values and `nil` return `.value` (no narrow
    /// commit: a heap value needs the full `.value` slot, and `nil` carries no
    /// type information to commit on). Only inspects the tag, never dereferences.
    fn laneForValue(val: Value) Lane {
        if (val.isBool()) return .boolean;
        if (val.isInt()) {
            const x = val.asInt();
            return intLaneForRange(x, x);
        }
        if (val.isFloat()) return .f64;
        return .value;
    }

    /// Initial-commitment lane for an integer range `[lo, hi]`. Prefers the
    /// unsigned-byte `u8` lane (1 byte/slot) when the whole range fits `[0,255]`;
    /// otherwise the smallest *signed* lane covering it. This is the entry point
    /// for committing a fresh array (`laneForValue`, `optimalLane`) — NOT for
    /// widening an already-committed lane, which must preserve the existing slots'
    /// range (`widenFor` handles that separately). Public so grid inflation
    /// (`gc.Heap.inflateToGrid`) can pick the unified cell lane over the global
    /// `[lo, hi]` of every cell it is about to flatten.
    pub fn intLaneForRange(lo: i64, hi: i64) Lane {
        if (lo >= 0 and hi <= 255) return .u8;
        return intLaneFor(lo, hi);
    }

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
            .boolean => cap, // one byte/slot (0=absent, 1=false, 2=true), in-band presence
            .i8, .u8 => cap, // one byte/slot; presence via the bitmap
            .i16 => cap * 2,
            .i32 => cap * 4,
            .i64, .f64 => cap * 8,
            // A grid sizes `data` from its flattened cell count at `grid_elem`
            // width (`dataBytes(grid_elem, cap*stride)`), never from the meta-lane
            // itself — callers use `gridCells`/`grid_elem`, so this is unreachable.
            .grid => unreachable,
        };
    }

    /// Bytes of presence bitmap for `cap` slots (0 for the `.value` lane).
    fn presenceBytes(cap: usize) usize {
        return bitmapBytes(cap);
    }

    fn bitmapBytes(slots: usize) usize {
        // Round up to whole 64-bit words, NOT bytes. The native presence path lowers
        // to a REX.W `bts`/`bt [present], idx` (x64.btsMemReg) whose memory operand is
        // 8 bytes wide: for a slot in word k it touches `[present + 8*k, +8)`. A
        // byte-exact `(slots+7)/8` bitmap (e.g. 1 byte at cap 8) would let that 8-byte
        // access run past the allocation — a latent OOB the native int-store path
        // (in-bounds astore and grow astore_append) would trip on small arrays. Sizing
        // to `ceil(slots/64)*8` bytes makes every in-range `bts` land inside the
        // buffer. Tier-0's byte-granular `setBit`/`isPresent` are unaffected; the extra
        // trailing bytes are zeroed (allocPresence) and never read as presence for
        // slots >= cap.
        return ((slots + 63) / 64) * 8;
    }

    /// Does `val` fit the current lane without widening? `nil` always fits (it is
    /// a hole). For `.value` everything fits. Public so the JIT recorder can refuse
    /// to record an out-of-lane `astore` (which would widen — a shape change the
    /// native store ABI can't perform).
    pub fn fits(self: *const ArrayPart, val: Value) bool {
        return laneFits(self.lane, val);
    }

    /// Lane-only form of `fits` (no `ArrayPart` instance needed). The JIT's
    /// `guard_fits` lowering and the tier-1a oracle use this to decide, given a
    /// recorded lane ordinal and a runtime value, whether an `astore` stays
    /// in-lane (vs. forcing a tier-0 widen that native can't perform mid-run).
    pub fn laneFits(lane: Lane, val: Value) bool {
        if (lane == .value or val.isNil()) return true;
        return switch (lane) {
            .value => true,
            .boolean => val.isBool(),
            .i8 => val.isInt() and inRange(val.asInt(), std.math.minInt(i8), std.math.maxInt(i8)),
            .i16 => val.isInt() and inRange(val.asInt(), std.math.minInt(i16), std.math.maxInt(i16)),
            .i32 => val.isInt() and inRange(val.asInt(), std.math.minInt(i32), std.math.maxInt(i32)),
            .i64 => val.isInt(),
            .u8 => val.isInt() and inRange(val.asInt(), 0, 255),
            .f64 => val.isFloat(),
            // The grid's outer element is a row, not a scalar — no scalar value
            // "fits" the meta-lane as a flat store; grid cell fit is tested against
            // `grid_elem` via `laneFits(grid_elem, …)` on the grid path instead.
            .grid => false,
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
    /// `inline`: folds into `get`/the `.get_index` opcode arm so the loop-invariant lane
    /// `switch` hoists out of the hot read loop (was ~55% of scimark-sparse as a call).
    inline fn decode(self: *const ArrayPart, idx: usize) Value {
        switch (self.lane) {
            .value => return self.valueSlot(idx).*,
            // A grid's outer element is a row (a `row_view` value, Phase 3), not a
            // packed scalar — its cells are read through `gridGet`, never `decode`.
            .grid => unreachable,
            // Boolean: one in-band byte. 0 ⇒ absent (hole); 1 ⇒ false, 2 ⇒ true.
            .boolean => {
                const b = self.data.?[idx];
                if (b == 0) return Value.nil();
                return Value.boolean(b == 2);
            },
            else => {
                if (!self.isPresent(idx)) return Value.nil();
                const d = self.data.?;
                return switch (self.lane) {
                    .value, .boolean, .grid => unreachable,
                    .i8 => Value.int(@as(i8, @bitCast(d[idx]))),
                    .u8 => Value.int(@as(i64, d[idx])), // zero-extend, range 0..255
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
    /// `inline`: mirror of `decode` for the store path (`setInLane`/`appendInCap`/the
    /// `.set_index` arm and the tier-1a oracle).
    inline fn encode(self: *ArrayPart, idx: usize, val: Value) void {
        switch (self.lane) {
            .value => self.valueSlot(idx).* = val,
            // A grid's cells are written through `gridSet`, never `encode`.
            .grid => unreachable,
            // Boolean: one in-band byte. nil ⇒ 0 (hole); false ⇒ 1, true ⇒ 2
            // (`1 + @intFromBool`). This single byte store carries both presence
            // and value — the native astore's atomic commit point (no separate
            // presence write).
            .boolean => self.data.?[idx] = if (val.isNil()) 0 else 1 + @as(u8, @intFromBool(val.asBool())),
            else => {
                if (val.isNil()) {
                    self.clearPresent(idx);
                    return;
                }
                const d = self.data.?;
                switch (self.lane) {
                    .value, .boolean, .grid => unreachable,
                    .i8 => d[idx] = @bitCast(@as(i8, @intCast(val.asInt()))),
                    .u8 => d[idx] = @intCast(val.asInt()), // val in [0,255] per fits/laneFits
                    .i16 => writeInt(i16, d, idx, @intCast(val.asInt())),
                    .i32 => writeInt(i32, d, idx, @intCast(val.asInt())),
                    .i64 => writeInt(i64, d, idx, val.asInt()),
                    .f64 => writeInt(u64, d, idx, @bitCast(val.asFloat())),
                }
                self.setPresent(idx);
            },
        }
    }

    // The packed `data` buffer is `align(@alignOf(Value))` (16-byte) allocated, so an
    // element at byte offset `idx*n` is `n`-aligned — but we don't even need to assert
    // that: `std.mem.readInt`/`writeInt` take an array-pointer slice (`*[n]u8`, align 1)
    // and `@bitCast` it, which the backend lowers to a single (here naturally-aligned)
    // `mov`/`movsd`. We pass the slice straight through instead of `@memcpy`-ing into a
    // stack buffer first (the old code's per-element copy showed up as ~55% of
    // scimark-sparse / ~11% of scimark-fft in the tier-0 profile). Output is bit-for-bit
    // identical to the buffered version — same `.little`, same bytes — so 8-mode
    // determinism + replay are unaffected (the explicit endian keeps it host-portable).
    fn readInt(comptime T: type, d: [*]const u8, idx: usize) T {
        const n = @sizeOf(T);
        return std.mem.readInt(T, d[idx * n ..][0..n], .little);
    }
    fn writeInt(comptime T: type, d: [*]u8, idx: usize, v: T) void {
        const n = @sizeOf(T);
        std.mem.writeInt(T, d[idx * n ..][0..n], v, .little);
    }

    // ---- allocation / growth / lane conversion ----

    fn allocData(gpa: std.mem.Allocator, lane: Lane, cap: usize) std.mem.Allocator.Error!?[*]align(@alignOf(Value)) u8 {
        const nbytes = dataBytes(lane, cap);
        if (nbytes == 0) return null;
        const slice = try gpa.alignedAlloc(u8, std.mem.Alignment.of(Value), nbytes);
        // The boolean lane encodes absence in-band (byte 0), so freshly allocated
        // slots must read as holes — zero them, mirroring how `allocPresence`
        // zeroes the bitmap that the int/float lanes lean on. Other lanes write
        // every live slot before reading it, so they need no zeroing.
        if (lane == .boolean) @memset(slice, 0);
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
        if (self.lane.usesPresenceBitmap()) new_present = try allocPresence(gpa, new_cap);

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
        std.debug.assert(self.lane != .grid and target != .grid); // grid migration is a reshape, not a lane convert
        std.debug.assert(target != self.lane);
        const cap = self.cap;

        const new_data = try allocData(gpa, target, cap);
        errdefer if (new_data) |nd| gpa.free(nd[0..dataBytes(target, cap)]);
        const new_present: ?[*]u8 = if (target.usesPresenceBitmap()) try allocPresence(gpa, cap) else null;

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
            // The `u8` lane already spans `[0,255]`, so a non-fitting int is
            // negative or `> 255`; widen to the smallest *signed* lane covering the
            // **combined** range `[min(0,v), max(255,v)]` (never back to `u8`, never
            // a narrower-than-existing lane that would drop bytes). This is always
            // `≥ i16` and a strict superset, so existing slots re-encode exactly.
            .u8 => if (val.isInt()) intLaneFor(@min(0, val.asInt()), @max(255, val.asInt())) else .value,
            // boolean/f64 lanes are type-pure: any value that doesn't fit means a
            // type mismatch, which only `.value` can hold.
            .boolean, .f64 => .value,
            // A grid never widens through the scalar store path (its stores go via
            // gridSet); `setInPlace`/`append` assert `lane != .grid` upstream.
            .grid => unreachable,
        };
        std.debug.assert(target != self.lane);
        try self.convert(gpa, target);
    }

    // ===================================================================
    // Grid representation (doc 14, Phase 2) — flattened nested numeric arrays.
    //
    // A `.grid` array part lays a nested numeric array out as one contiguous
    // row-major buffer: `data` holds `cap*stride` scalar cells at `grid_elem`
    // width, `present` is a per-cell presence bitmap over those cells, and
    // `row_len[r]` is the logical length of row `r`. The outer element is a row
    // (a transient `row_view` value, Phase 3), so these dedicated cell/row methods
    // — never the scalar `get`/`encode`/`append`/widen paths — are how a grid is
    // accessed. Phase 2 builds and round-trips the representation; inflation
    // (Phase 4) and RowView forwarding (Phase 3) are not wired in yet.
    // ===================================================================

    /// `true` iff this array part is a flattened grid.
    pub inline fn isGrid(self: *const ArrayPart) bool {
        return self.lane == .grid;
    }

    /// Flattened cell count for a `rows × stride` grid.
    fn gridCells(rows: usize, stride: usize) usize {
        return rows * stride;
    }

    /// Flat row-major index of cell `(row, col)`.
    inline fn gridCellIndex(self: *const ArrayPart, row: usize, col: usize) usize {
        return row * self.stride + col;
    }

    /// Build a fresh `rows × stride` grid at scalar element lane `grid_elem`, every
    /// cell a hole. `grid_elem` must be a presence-bitmap fixed-width lane
    /// (`i8`/`u8`/`i16`/`i32`/`i64`/`f64`); boolean/value leaves are out of grid
    /// scope in v1. OOM-atomic: on failure nothing leaks and the error propagates.
    pub fn initGrid(
        gpa: std.mem.Allocator,
        rows: usize,
        stride: usize,
        grid_elem: Lane,
    ) std.mem.Allocator.Error!ArrayPart {
        std.debug.assert(grid_elem.usesPresenceBitmap()); // fixed-width bitmap leaf
        std.debug.assert(stride >= 1);

        // Overflow-guard the cell count and its byte size exactly like
        // `ensureCapacity` guards the scalar `cap` (critical where usize is 32-bit:
        // a wrapped tiny allocation behind a huge logical extent is a heap overflow).
        const max_cells = std.math.maxInt(usize) / @sizeOf(Value);
        if (rows != 0 and stride > max_cells / rows) return error.OutOfMemory;
        const cells = gridCells(rows, stride);
        if (cells > max_cells) return error.OutOfMemory;

        // Allocate all three buffers before committing; an OOM on a later alloc
        // frees the earlier ones via the errdefers and leaves nothing behind.
        const data = try allocData(gpa, grid_elem, cells);
        errdefer if (data) |d| gpa.free(d[0..dataBytes(grid_elem, cells)]);
        const present = try allocPresence(gpa, cells); // grid_elem always uses a bitmap
        errdefer if (present) |p| gpa.free(p[0..presenceBytes(cells)]);

        var row_len: ?[*]u32 = null;
        if (rows != 0) {
            const rl = try gpa.alloc(u32, rows);
            @memset(rl, 0); // every row starts logically empty
            row_len = rl.ptr;
        }

        return .{
            .lane = .grid,
            .grid_elem = grid_elem,
            // A grid is a committed representation: `frozen` keeps the scalar
            // rehash (`Table.rehash`, which only fires when `!frozen`) from ever
            // calling `optimalLane`/`repack` on it — both assert `lane != .grid`.
            .frozen = true,
            .len = rows,
            .cap = rows,
            .stride = stride,
            .data = data,
            .present = present,
            .row_len = row_len,
        };
    }

    /// Number of rows in the grid (`= len`).
    pub inline fn gridRows(self: *const ArrayPart) usize {
        std.debug.assert(self.isGrid());
        return self.len;
    }

    /// Logical length (`#`-border high-water) of row `row` (0-based).
    pub inline fn gridRowLen(self: *const ArrayPart, row: usize) usize {
        std.debug.assert(self.isGrid() and row < self.len);
        return if (self.row_len) |r| r[row] else 0;
    }

    /// `grid[row][col+1]` — read cell `(row, col)` (both 0-based) as a logical
    /// `Value` (or `nil` for a hole).
    pub inline fn gridGet(self: *const ArrayPart, row: usize, col: usize) Value {
        std.debug.assert(self.isGrid() and row < self.len and col < self.stride);
        return decodeGridCell(self.grid_elem, self.data.?, self.present.?, self.gridCellIndex(row, col));
    }

    /// `grid[row][col+1] = val` — write cell `(row, col)` (both 0-based). `val`
    /// must already fit `grid_elem` (the caller guards it; the grid-widening reshape
    /// is Phase 4) or be `nil` (punch a hole). A non-nil store raises the row's
    /// logical length to `max(row_len, col+1)`, mirroring how the scalar array's
    /// `len` tracks its high-water slot; a `nil` store does not shrink it (Lua `#`
    /// is any border).
    pub inline fn gridSet(self: *ArrayPart, row: usize, col: usize, val: Value) void {
        std.debug.assert(self.isGrid() and row < self.len and col < self.stride);
        std.debug.assert(laneFits(self.grid_elem, val)); // fits the cell lane, or nil
        encodeGridCell(self.grid_elem, self.data.?, self.present.?, self.gridCellIndex(row, col), val);
        if (!val.isNil()) {
            const want: u32 = @intCast(col + 1);
            if (self.row_len) |r| {
                if (want > r[row]) r[row] = want;
            }
        }
    }

    // ---- grid reshape (doc 14, Phase 4b) — grow on overflow, never deflate ----
    //
    // Bart's escape model: a fused `a[i][j]=v` store whose `j` outruns the current
    // `stride`, or whose integer outgrows the current `grid_elem`, **grows the grid**
    // (geometrically, so amortised O(1)/cell — the array-growth philosophy), rather
    // than deflating. Only a genuine *type* change (a float into an int grid, a
    // non-numeric leaf) deflates; that decision lives in the interpreter, which calls
    // these reshapes when the family is preserved.

    /// Grow the grid's column count (`stride`) to at least `min_stride`,
    /// geometrically (repeated single-column extensions stay amortised O(1)/cell,
    /// mirroring `ensureCapacity`'s row growth). Re-lays the row-major `data` buffer
    /// and the per-cell presence bitmap into the wider stride; `row_len`, `len`,
    /// `cap`, and `grid_elem` are unchanged, and the new trailing cells of each row
    /// are holes. OOM-atomic: on failure the grid is left exactly as it was.
    pub fn gridGrowStride(self: *ArrayPart, gpa: std.mem.Allocator, min_stride: usize) std.mem.Allocator.Error!void {
        std.debug.assert(self.isGrid());
        if (min_stride <= self.stride) return;
        const old_stride = self.stride;
        const rows = self.cap;

        // Geometric: at least double, but jump straight to `min_stride` if larger.
        var new_stride = if (old_stride == 0) @as(usize, 1) else old_stride;
        while (new_stride < min_stride) new_stride = new_stride *| 2;

        // Overflow-guard the new cell count and its byte size (initGrid's guard).
        const max_cells = std.math.maxInt(usize) / @sizeOf(Value);
        if (rows != 0 and new_stride > max_cells / rows) return error.OutOfMemory;
        const new_cells = gridCells(rows, new_stride);
        if (new_cells > max_cells) return error.OutOfMemory;

        const new_data = try allocData(gpa, self.grid_elem, new_cells);
        errdefer if (new_data) |nd| gpa.free(nd[0..dataBytes(self.grid_elem, new_cells)]);
        const new_present = try allocPresence(gpa, new_cells);

        // Re-lay each row from `old_stride` to `new_stride`: bulk-copy its data bytes
        // (grid cells are whole-byte fixed-width lanes — `cell_bytes >= 1`), then move
        // each present bit to its new flat index (cell indices shift with the stride).
        if (self.data) |old_data| {
            const cell_bytes = dataBytes(self.grid_elem, 1);
            const old_present = self.present.?;
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                const old_base = row * old_stride;
                const new_base = row * new_stride;
                if (old_stride > 0) {
                    const nbytes = old_stride * cell_bytes;
                    @memcpy(
                        new_data.?[new_base * cell_bytes ..][0..nbytes],
                        old_data[old_base * cell_bytes ..][0..nbytes],
                    );
                }
                var col: usize = 0;
                while (col < old_stride) : (col += 1) {
                    if (getBit(old_present, old_base + col)) setBit(new_present.?, new_base + col, true);
                }
            }
        }

        // Free old buffers, commit the wider stride.
        const old_cells = gridCells(self.cap, old_stride);
        if (self.data) |d| gpa.free(d[0..dataBytes(self.grid_elem, old_cells)]);
        if (self.present) |p| gpa.free(p[0..presenceBytes(old_cells)]);
        self.data = new_data;
        self.present = new_present;
        self.stride = new_stride;
    }

    /// Widen the grid's cell lane (`grid_elem`) to `target` — a strictly wider lane
    /// in the **same numeric family** (the int ladder; never int↔float, which is a
    /// type change the interpreter handles by deflating). Re-encodes every present
    /// cell through a logical `Value`; `stride`/`row_len`/`len`/`cap` and the cell
    /// layout (hence the presence bitmap) are unchanged — only the per-cell byte
    /// width grows. OOM-atomic. The grid analogue of the scalar `widenFor`.
    pub fn gridWidenElem(self: *ArrayPart, gpa: std.mem.Allocator, target: Lane) std.mem.Allocator.Error!void {
        std.debug.assert(self.isGrid());
        std.debug.assert(target.usesPresenceBitmap() and target != self.grid_elem);
        const cells = gridCells(self.cap, self.stride);

        const new_data = try allocData(gpa, target, cells);
        errdefer if (new_data) |nd| gpa.free(nd[0..dataBytes(target, cells)]);

        // Re-encode present cells; the shared presence bitmap is reused as-is (cell
        // positions don't move), so absent cells stay holes.
        if (self.data) |old_data| {
            const present = self.present.?;
            var idx: usize = 0;
            while (idx < cells) : (idx += 1) {
                if (getBit(present, idx)) {
                    const v = decodeGridCell(self.grid_elem, old_data, present, idx);
                    encodeGridCell(target, new_data.?, present, idx, v);
                }
            }
            gpa.free(old_data[0..dataBytes(self.grid_elem, cells)]);
        }
        self.data = new_data;
        self.grid_elem = target;
    }

    /// The strictly-wider integer cell lane needed to hold `v` (an integer that does
    /// not fit the current int `grid_elem`), or `null` when `v` cannot be
    /// accommodated by an in-family widen — a float (int↔float is a type change), a
    /// non-number, or a grid already on `.f64` (an int into a float grid changes the
    /// cell's observable subtype). The interpreter deflates in the `null` case.
    /// Mirrors `widenFor`'s int-ladder arm exactly.
    pub fn gridWidenTargetForInt(grid_elem: Lane, v: Value) ?Lane {
        if (!v.isInt()) return null;
        return switch (grid_elem) {
            .i8, .i16, .i32, .i64 => intLaneFor(v.asInt(), v.asInt()),
            .u8 => intLaneFor(@min(0, v.asInt()), @max(255, v.asInt())),
            else => null, // .f64 (subtype change) or a non-int leaf lane
        };
    }

    /// Decode packed grid cell `idx` (flat 0-based) at fixed-width bitmap lane
    /// `lane`. Mirrors the scalar `decode` int/float arms exactly (shared
    /// `readInt`/`getBit`), so a grid cell round-trips byte-identically to a scalar
    /// slot — the determinism contract for a deflated row reading the same values.
    inline fn decodeGridCell(lane: Lane, data: [*]const u8, present: [*]const u8, idx: usize) Value {
        if (!getBit(present, idx)) return Value.nil();
        return switch (lane) {
            .i8 => Value.int(@as(i8, @bitCast(data[idx]))),
            .u8 => Value.int(@as(i64, data[idx])), // zero-extend, range 0..255
            .i16 => Value.int(readInt(i16, data, idx)),
            .i32 => Value.int(readInt(i32, data, idx)),
            .i64 => Value.int(readInt(i64, data, idx)),
            .f64 => Value.float(@bitCast(readInt(u64, data, idx))),
            .value, .boolean, .grid => unreachable, // not a grid leaf lane
        };
    }

    /// Encode logical `val` into packed grid cell `idx`. Mirror of the scalar
    /// `encode` int/float arms (shared `writeInt`/`setBit`); `nil` clears presence.
    inline fn encodeGridCell(lane: Lane, data: [*]u8, present: [*]u8, idx: usize, val: Value) void {
        if (val.isNil()) {
            setBit(present, idx, false);
            return;
        }
        switch (lane) {
            .i8 => data[idx] = @bitCast(@as(i8, @intCast(val.asInt()))),
            .u8 => data[idx] = @intCast(val.asInt()), // val in [0,255] per laneFits
            .i16 => writeInt(i16, data, idx, @intCast(val.asInt())),
            .i32 => writeInt(i32, data, idx, @intCast(val.asInt())),
            .i64 => writeInt(i64, data, idx, val.asInt()),
            .f64 => writeInt(u64, data, idx, @bitCast(val.asFloat())),
            .value, .boolean, .grid => unreachable,
        }
        setBit(present, idx, true);
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

test "boolean lane: repack packs true/false/hole at one byte/slot, presence in-band" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);

    // hole at 1, then alternating booleans — the nsieve shape.
    try a.append(gpa, Value.nil());
    var i: usize = 2;
    while (i <= 65) : (i += 1) try a.append(gpa, Value.boolean(i % 3 == 0));

    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.boolean, a.lane);

    // Byte-granular, in-band presence: no separate presence bitmap, and the data
    // payload is exactly one byte per slot (0=absent, 1=false, 2=true).
    try testing.expect(a.present == null);
    try testing.expect(!Lane.boolean.usesPresenceBitmap());
    try testing.expectEqual(a.cap, ArrayPart.dataBytes(.boolean, a.cap));

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

test "u8 lane: a byte array commits to u8 at 1 byte/slot and zero-extends on read" {
    const gpa = testing.allocator;
    // Every value in [0,255] — including bytes >= 128 that overflow signed i8 —
    // packs into the unsigned-byte lane.
    var a = try fromSlice(gpa, &.{ Value.int(0), Value.int(127), Value.int(128), Value.int(200), Value.int(255) });
    defer a.deinit(gpa);
    try testing.expectEqual(Lane.u8, a.lane);
    try testing.expect(a.frozen);
    try testing.expect(a.lane.usesPresenceBitmap()); // separate bitmap, unlike boolean
    // 1 byte/slot (NOT i16's two), the whole point of S-E.
    try testing.expectEqual(a.cap, ArrayPart.dataBytes(a.lane, a.cap));
    // High bytes decode by ZERO-extension: 200 reads back 200, not -56 (the i8
    // sign-extended value of byte 0xC8).
    try testing.expectEqual(@as(i64, 0), a.get(1).asInt());
    try testing.expectEqual(@as(i64, 127), a.get(2).asInt());
    try testing.expectEqual(@as(i64, 128), a.get(3).asInt());
    try testing.expectEqual(@as(i64, 200), a.get(4).asInt());
    try testing.expectEqual(@as(i64, 255), a.get(5).asInt());
    try testing.expectEqual(Lane.u8, a.optimalLane());
}

test "u8 lane: a value > 255 widens to i16, preserving every byte" {
    const gpa = testing.allocator;
    var a = try fromSlice(gpa, &.{ Value.int(10), Value.int(200), Value.int(255) });
    defer a.deinit(gpa);
    try testing.expectEqual(Lane.u8, a.lane);

    // 256 escapes the byte range → widen to the smallest signed lane covering
    // [0,256], i.e. i16 (never i8, never back to u8). Existing bytes survive.
    try a.append(gpa, Value.int(256));
    try testing.expectEqual(Lane.i16, a.lane);
    try testing.expectEqual(@as(i64, 10), a.get(1).asInt());
    try testing.expectEqual(@as(i64, 200), a.get(2).asInt());
    try testing.expectEqual(@as(i64, 255), a.get(3).asInt());
    try testing.expectEqual(@as(i64, 256), a.get(4).asInt());
}

test "u8 lane: a negative store widens to i16 (not i8), preserving high bytes" {
    const gpa = testing.allocator;
    var a = try fromSlice(gpa, &.{ Value.int(0), Value.int(200), Value.int(255) });
    defer a.deinit(gpa);
    try testing.expectEqual(Lane.u8, a.lane);

    // A -1 store: u8 already spans [0,255], so the smallest signed lane covering
    // [-1,255] is i16 — NOT i8 (which tops out at 127 and would drop the 200/255
    // bytes). This is the load-bearing combined-range widen.
    try a.setInPlace(gpa, 2, Value.int(-1));
    try testing.expectEqual(Lane.i16, a.lane);
    try testing.expectEqual(@as(i64, 0), a.get(1).asInt());
    try testing.expectEqual(@as(i64, -1), a.get(2).asInt());
    try testing.expectEqual(@as(i64, 255), a.get(3).asInt());
}

test "int lane: values survive a repack and decode exactly" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: i64 = 1;
    while (i <= 50) : (i += 1) try a.append(gpa, Value.int(i * 100)); // up to 5000 → i16

    // Eager commit narrows on the first append (int 100 → u8, the byte lane), then
    // widens up to i16 as the values grow past 255 — no manual repack needed.
    try testing.expectEqual(Lane.i16, a.lane);
    i = 1;
    while (i <= 50) : (i += 1) try testing.expectEqual(i * 100, a.get(@intCast(i)).asInt());
}

test "f64 lane round-trips" {
    const gpa = testing.allocator;
    var a = try fromSlice(gpa, &.{ Value.float(1.5), Value.float(-2.25), Value.float(3.0e10) });
    defer a.deinit(gpa);
    // fromSlice appends, so the first float eager-commits the f64 lane.
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
    try testing.expectEqual(Lane.boolean, a.lane); // eager-committed on first append

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
    try testing.expectEqual(Lane.u8, a.lane); // eager-committed on first append (bytes → u8)

    try a.append(gpa, Value.float(1.5)); // doesn't fit u8 → widen
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expectEqual(@as(usize, 11), a.len);
    try testing.expectEqual(@as(i64, 1), a.get(1).asInt());
    try testing.expectEqual(@as(f64, 1.5), a.get(11).asFloat());
}

test "monotonic widen: an int outgrowing its lane steps up the int ladder, not to value" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);

    // Pack into u8 (all values in [0, 255]) — eager-committed on first append.
    var i: usize = 1;
    while (i <= 10) : (i += 1) try a.append(gpa, Value.int(@intCast(i)));
    try testing.expectEqual(Lane.u8, a.lane);

    // Store 1000 (out of u8, fits i16) → steps up to i16, NOT .value.
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
    try testing.expectEqual(Lane.u8, a.lane); // eager-committed on first append (bytes → u8)

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
    // Eager commit already narrowed to u8 AND set frozen on the first append —
    // no need to repack or set frozen by hand.
    try testing.expect(a.frozen);

    try a.setInPlace(gpa, 3, Value.int(1000)); // u8 → i16 via widenFor/convert
    try testing.expectEqual(Lane.i16, a.lane);
    try testing.expect(a.frozen); // commitment survives the widen
}

test "canWidenTo encodes the monotonic widening lattice exactly" {
    const all = [_]Lane{ .value, .boolean, .i8, .i16, .i32, .i64, .f64, .u8 };
    // Reachability table: from-lane → the set of lanes it can ever become.
    // Mirrors `widenFor`: ints climb the ladder then erase to value; pure lanes
    // (boolean/f64) erase straight to value; value is the top and reaches only
    // itself. Every lane reaches itself.
    const Case = struct { from: Lane, reaches: []const Lane };
    const cases = [_]Case{
        .{ .from = .value, .reaches = &.{.value} },
        .{ .from = .boolean, .reaches = &.{ .boolean, .value } },
        .{ .from = .f64, .reaches = &.{ .f64, .value } },
        .{ .from = .i8, .reaches = &.{ .i8, .i16, .i32, .i64, .value } },
        .{ .from = .i16, .reaches = &.{ .i16, .i32, .i64, .value } },
        .{ .from = .i32, .reaches = &.{ .i32, .i64, .value } },
        .{ .from = .i64, .reaches = &.{ .i64, .value } },
        // u8 is a sibling entry point: it widens only to the *signed* ladder
        // (≥ i16) or value — never to i8, never back to u8. Nothing reaches it.
        .{ .from = .u8, .reaches = &.{ .u8, .i16, .i32, .i64, .value } },
    };
    for (cases) |c| {
        for (all) |target| {
            var expected = false;
            for (c.reaches) |r| {
                if (r == target) expected = true;
            }
            try testing.expectEqual(expected, c.from.canWidenTo(target));
        }
    }
    // The lattice is a strict partial order off the diagonal: no two distinct
    // lanes can widen to each other (would imply re-narrowing).
    for (all) |x| {
        for (all) |y| {
            if (x == y) continue;
            try testing.expect(!(x.canWidenTo(y) and y.canWidenTo(x)));
        }
    }
}

test "resize grows with holes and shrinks dropping the tail" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, Value.int(1));
    try a.append(gpa, Value.int(2));
    try testing.expectEqual(Lane.u8, a.lane); // eager-committed on first append (bytes → u8)

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
    // A narrow (eager-committed) int array is a leaf.
    var a = try fromSlice(gpa, &.{ Value.int(1), Value.int(2) });
    defer a.deinit(gpa);
    try testing.expect(a.isLeaf()); // narrow lane, committed on first append

    // A `.value`-lane array (heap-first → no narrow commit) is NOT a leaf.
    var b: ArrayPart = .empty;
    defer b.deinit(gpa);
    var hdr = object.GcHeader.init(.table); // tag-only; never dereferenced
    try b.append(gpa, Value.heap(&hdr));
    try testing.expectEqual(Lane.value, b.lane);
    try testing.expect(!b.isLeaf());
}

// ---- eager narrow-lane commit on first append ----

test "eager commit: dense-from-1 boolean fill commits .boolean + frozen, no manual repack" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var i: usize = 1;
    while (i <= 32) : (i += 1) try a.append(gpa, Value.boolean(i % 2 == 0));
    try testing.expectEqual(Lane.boolean, a.lane); // committed on the FIRST append
    try testing.expect(a.frozen);
    try testing.expect(a.present == null); // boolean lane is in-band, no bitmap
    i = 1;
    while (i <= 32) : (i += 1) try testing.expectEqual(i % 2 == 0, a.get(i).asBool());
}

test "eager commit: dense-from-1 int fill narrows then widens up the int ladder" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, Value.int(100)); // eager → u8 (byte)
    try testing.expectEqual(Lane.u8, a.lane);
    try testing.expect(a.frozen);
    try a.append(gpa, Value.int(5000)); // u8 → i16
    try testing.expectEqual(Lane.i16, a.lane);
    try a.append(gpa, Value.int(100000)); // i16 → i32
    try testing.expectEqual(Lane.i32, a.lane);
    try testing.expect(a.frozen); // commitment survives every widen
    try testing.expectEqual(@as(i64, 100), a.get(1).asInt());
    try testing.expectEqual(@as(i64, 5000), a.get(2).asInt());
    try testing.expectEqual(@as(i64, 100000), a.get(3).asInt());
}

test "eager commit: heterogeneous first-two (int then float) ends in the value lane" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, Value.int(7)); // eager → u8 + frozen (byte)
    try testing.expectEqual(Lane.u8, a.lane);
    try a.append(gpa, Value.float(1.5)); // float doesn't fit any int lane → .value
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expect(a.frozen);
    try testing.expectEqual(@as(i64, 7), a.get(1).asInt());
    try testing.expectEqual(@as(f64, 1.5), a.get(2).asFloat());
}

test "eager commit: heap-first append stays in the value lane, not frozen" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    var hdr = object.GcHeader.init(.table); // tag-only; laneForValue never derefs
    try a.append(gpa, Value.heap(&hdr)); // laneForValue → .value → no commit
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expect(!a.frozen);
}

test "eager commit: nil-first then booleans stays .value until a manual repack" {
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, Value.nil()); // laneForValue(nil) → .value → no commit
    try a.append(gpa, Value.boolean(true)); // len != 0 → eager block skipped
    try testing.expectEqual(Lane.value, a.lane);
    try testing.expect(!a.frozen);
    // Not committed, so the explicit rehash-style repack still works.
    try a.repack(gpa, a.optimalLane());
    try testing.expectEqual(Lane.boolean, a.lane);
}

test "eager commit on a truly-fresh array (data==null) is OOM-safe and retryable" {
    // The fresh arm commits the lane then secures narrow-width capacity; a forced
    // OOM there must roll the speculative lane back to `.value` and leave the array
    // fresh (len 0, !frozen) so a retry succeeds — never frozen onto an unstored
    // value. `checkAllAllocationFailures` reruns from scratch forcing each alloc to
    // fail and asserts no leak / no bad free across the rollback path.
    const Inner = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var a: ArrayPart = .empty; // data == null, the fresh arm
            defer a.deinit(gpa);
            try a.append(gpa, Value.boolean(true));
            try testing.expectEqual(Lane.boolean, a.lane);
            try testing.expect(a.frozen);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Inner.run, .{});
}

test "eager commit via the convert arm (data!=null at len==0) is OOM-safe" {
    // After `resize(0)` the array keeps its `.value`-width buffer (data != null)
    // at len==0, so the next append takes the eager-commit `convert` branch. Force
    // each allocation in that path to fail and assert no leak / no bad free.
    const Inner = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var a: ArrayPart = .empty;
            defer a.deinit(gpa);
            try a.append(gpa, Value.nil()); // .value, allocates a buffer (data != null)
            try a.resize(gpa, 0); // len → 0 but data stays non-null, lane still .value
            try a.append(gpa, Value.boolean(true)); // hits the convert arm
            try testing.expectEqual(Lane.boolean, a.lane);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Inner.run, .{});
}

test "presence bitmap is sized to whole 64-bit words (native bts can't run past it)" {
    // The native presence path uses a REX.W `bts [present], idx` that accesses the
    // 8-byte word holding bit `idx`. So the bitmap for `cap` slots must be at least
    // `ceil((cap-1)/64 + 1)` words = enough that a `bts` at the top slot (cap-1)
    // stays in-bounds. Pin both the word-multiple and the sufficiency here so a
    // regression to a byte-exact `(cap+7)/8` size (which OOBs for cap<64) fails loudly.
    const cases = [_]usize{ 0, 1, 8, 16, 63, 64, 65, 128, 1000 };
    for (cases) |cap| {
        const bytes = ArrayPart.presenceBytes(cap);
        try testing.expectEqual(@as(usize, 0), bytes % 8); // whole 64-bit words
        if (cap > 0) {
            // The word touched by a bts at the highest slot must be fully inside.
            const top_word = (cap - 1) / 64;
            try testing.expect(bytes >= (top_word + 1) * 8);
        }
    }
}

test "appendInCap on an int lane encodes the value and sets the presence bit" {
    // `appendInCap` is the on-trace `astore_append` oracle (tier-1a) that native
    // Phase-B int lowering must match byte-for-byte. Unlike the bool lane (in-band
    // presence), an int lane uses a *separate* presence bitmap, so the oracle's
    // `encode` must both write the width-truncated value AND set the bit — the exact
    // pair the native int grow store emits (`[data]=value(w)` + `bts [present],idx0`).
    const gpa = testing.allocator;
    var a: ArrayPart = .empty;
    defer a.deinit(gpa);
    try a.append(gpa, Value.int(7)); // eager-commit → .u8 (byte lane), len 1
    try testing.expectEqual(Lane.u8, a.lane);
    try testing.expect(a.lane.usesPresenceBitmap());
    // Secure room for an in-cap append, then drive the oracle directly (no realloc).
    try a.ensureCapacity(gpa, a.len + 1);
    const before = a.len; // 1 (logical len); the new slot's 0-based index is `before`
    a.appendInCap(Value.int(42));
    try testing.expectEqual(before + 1, a.len);
    try testing.expectEqual(Value.int(42), a.get(before + 1)); // new slot round-trips (1-based)
    try testing.expect(a.isPresent(before)); // its presence bit set (0-based slot index)
    try testing.expectEqual(Value.int(7), a.get(1)); // earlier slot intact
}

test "Layout offsets are stable and lane is first" {
    // Phase B's JIT encodes these offsets via `@offsetOf`; pin them so a layout
    // drift fails here rather than silently miscompiling native array access.
    try testing.expectEqual(@as(usize, 0), ArrayPart.Layout.lane);
    // `frozen` and the grid sub-lane `grid_elem` ride in `lane`'s alignment padding
    // (offsets 1 and 2), so they must NOT push the pointer-aligned fields out: `len`
    // still lands at the first usize-aligned offset and the word-sized fields follow
    // contiguously. Crucially this keeps `len`/`cap`/`data`/`present` byte-identical
    // to before the grid fields existed — the offsets nativegen already encodes
    // against are undisturbed. Derived from `@sizeOf(usize)` so the contract holds on
    // both 64- and 32-bit targets.
    const word = @sizeOf(usize);
    try testing.expectEqual(@as(usize, 1), ArrayPart.Layout.frozen);
    try testing.expectEqual(@as(usize, 2), ArrayPart.Layout.grid_elem);
    try testing.expectEqual(@alignOf(usize), ArrayPart.Layout.len);
    try testing.expectEqual(ArrayPart.Layout.len + word, ArrayPart.Layout.cap);
    try testing.expectEqual(ArrayPart.Layout.cap + word, ArrayPart.Layout.data);
    try testing.expectEqual(ArrayPart.Layout.data + word, ArrayPart.Layout.present);
    // The grid fields are appended after `present` (doc 14 Phase 2), so they land
    // last and only grow the struct — the offsets above are untouched.
    try testing.expectEqual(ArrayPart.Layout.present + word, ArrayPart.Layout.stride);
    try testing.expectEqual(ArrayPart.Layout.stride + word, ArrayPart.Layout.row_len);
    try testing.expectEqual(ArrayPart.Layout.row_len + word, @sizeOf(ArrayPart));
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
            // Lead with a nil hole so eager commit does NOT fire (laneForValue(nil)
            // is .value): the array then grows in the value lane, exercising
            // ensureCapacity's realloc + free and keeping the value→narrow repack
            // below meaningful. (The eager-commit `convert` arm has its own OOM
            // test, "eager commit via the convert arm is OOM-safe".)
            try a.append(gpa, Value.nil());
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

// ---- grid representation (doc 14, Phase 2) ----

test "grid: round-trips f64 cells row-major, holes read as nil" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 3, 4, .f64); // 3 rows × stride 4
    defer g.deinit(gpa);

    try testing.expect(g.isGrid());
    try testing.expectEqual(Lane.grid, g.lane);
    try testing.expectEqual(Lane.f64, g.grid_elem);
    try testing.expect(g.frozen);
    try testing.expectEqual(@as(usize, 3), g.gridRows());
    try testing.expectEqual(@as(usize, 4), g.stride);

    // Every cell starts a hole.
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1) try testing.expect(g.gridGet(r, c).isNil());
        try testing.expectEqual(@as(usize, 0), g.gridRowLen(r));
    }

    // Fill (r,c) = r*10 + c as a float; read it back exactly.
    r = 0;
    while (r < 3) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1) g.gridSet(r, c, Value.float(@floatFromInt(r * 10 + c)));
    }
    r = 0;
    while (r < 3) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1)
            try testing.expectEqual(@as(f64, @floatFromInt(r * 10 + c)), g.gridGet(r, c).asFloat());
        try testing.expectEqual(@as(usize, 4), g.gridRowLen(r)); // high-water = full stride
    }
}

test "grid: int leaf round-trips and a cell decodes identically to a scalar slot" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 2, 3, .i32);
    defer g.deinit(gpa);

    g.gridSet(0, 0, Value.int(-5));
    g.gridSet(0, 1, Value.int(100000));
    g.gridSet(1, 2, Value.int(7));

    try testing.expectEqual(@as(i64, -5), g.gridGet(0, 0).asInt());
    try testing.expectEqual(@as(i64, 100000), g.gridGet(0, 1).asInt());
    try testing.expect(g.gridGet(0, 2).isNil()); // never written
    try testing.expect(g.gridGet(1, 0).isNil());
    try testing.expectEqual(@as(i64, 7), g.gridGet(1, 2).asInt());

    // A grid cell must decode byte-identically to the same value in a scalar i32
    // array part — the determinism contract (a deflated row reads the same values).
    var scalar = try fromSlice(gpa, &.{ Value.int(-5), Value.int(100000) });
    defer scalar.deinit(gpa);
    try testing.expectEqual(Lane.i32, scalar.lane);
    try testing.expectEqual(scalar.get(1), g.gridGet(0, 0));
    try testing.expectEqual(scalar.get(2), g.gridGet(0, 1));
}

test "grid: jagged rows — row_len is the high-water column, nil store does not shrink it" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 2, 5, .i16);
    defer g.deinit(gpa);

    // Row 0: cells 0,1,2 present (logical length 3); columns 3,4 stay holes.
    g.gridSet(0, 0, Value.int(10));
    g.gridSet(0, 1, Value.int(20));
    g.gridSet(0, 2, Value.int(30));
    try testing.expectEqual(@as(usize, 3), g.gridRowLen(0));

    // Internal hole: clearing cell 1 reads back nil but does NOT shrink the border.
    g.gridSet(0, 1, Value.nil());
    try testing.expect(g.gridGet(0, 1).isNil());
    try testing.expectEqual(@as(i64, 10), g.gridGet(0, 0).asInt());
    try testing.expectEqual(@as(i64, 30), g.gridGet(0, 2).asInt());
    try testing.expectEqual(@as(usize, 3), g.gridRowLen(0)); // # is any border; unchanged

    // Row 1 left empty entirely.
    try testing.expectEqual(@as(usize, 0), g.gridRowLen(1));
    var c: usize = 0;
    while (c < 5) : (c += 1) try testing.expect(g.gridGet(1, c).isNil());
}

test "grid: u8 leaf packs at one byte/cell" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 4, 4, .u8);
    defer g.deinit(gpa);
    // The flat data buffer is exactly cap*stride bytes for a u8 grid.
    try testing.expectEqual(@as(usize, 4 * 4), ArrayPart.dataBytes(.u8, 4 * 4));
    g.gridSet(2, 3, Value.int(200)); // > i8 max, fits u8, zero-extends on read
    try testing.expectEqual(@as(i64, 200), g.gridGet(2, 3).asInt());
}

test "grid: a row-0 grid allocates nothing and deinits cleanly" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 0, 8, .f64);
    defer g.deinit(gpa);
    try testing.expect(g.isGrid());
    try testing.expectEqual(@as(usize, 0), g.gridRows());
    try testing.expect(g.data == null);
    try testing.expect(g.present == null);
    try testing.expect(g.row_len == null);
}

test "grid: initGrid is OOM-safe at every allocation point (no leak, no bad free)" {
    const Inner = struct {
        fn run(gpa: std.mem.Allocator) !void {
            // 3×4 f64 grid: data alloc, presence alloc, row_len alloc — force each
            // to fail in turn and assert the errdefers unwind cleanly.
            var g = try ArrayPart.initGrid(gpa, 3, 4, .f64);
            defer g.deinit(gpa);
            g.gridSet(1, 1, Value.float(2.5));
            try testing.expectEqual(@as(f64, 2.5), g.gridGet(1, 1).asFloat());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Inner.run, .{});
}

test "grid reshape: gridGrowStride preserves cells/holes/row_len, grows geometrically" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 3, 2, .i16);
    defer g.deinit(gpa);

    // Fill a jagged shape across the original stride 2.
    g.gridSet(0, 0, Value.int(10));
    g.gridSet(0, 1, Value.int(11));
    g.gridSet(1, 0, Value.int(20)); // row 1 length 1; col 1 a hole
    g.gridSet(2, 1, Value.int(31)); // row 2: col 0 hole, col 1 present (row_len 2)
    try testing.expectEqual(@as(usize, 2), g.gridRowLen(0));
    try testing.expectEqual(@as(usize, 1), g.gridRowLen(1));
    try testing.expectEqual(@as(usize, 2), g.gridRowLen(2));

    // Need column index 4 (1-based 5) → grow. Geometric: 2 → 4 → 8 covers >=5.
    try g.gridGrowStride(gpa, 5);
    try testing.expectEqual(@as(usize, 8), g.stride);

    // Every prior cell, hole, and per-row length survives the re-lay.
    try testing.expectEqual(@as(i64, 10), g.gridGet(0, 0).asInt());
    try testing.expectEqual(@as(i64, 11), g.gridGet(0, 1).asInt());
    try testing.expectEqual(@as(i64, 20), g.gridGet(1, 0).asInt());
    try testing.expect(g.gridGet(1, 1).isNil());
    try testing.expect(g.gridGet(2, 0).isNil());
    try testing.expectEqual(@as(i64, 31), g.gridGet(2, 1).asInt());
    try testing.expectEqual(@as(usize, 2), g.gridRowLen(0));
    try testing.expectEqual(@as(usize, 1), g.gridRowLen(1));
    try testing.expectEqual(@as(usize, 2), g.gridRowLen(2));
    // New trailing columns are holes; now addressable.
    var c: usize = 2;
    while (c < 8) : (c += 1) try testing.expect(g.gridGet(0, c).isNil());

    // A no-op grow (min_stride <= stride) leaves it untouched.
    try g.gridGrowStride(gpa, 3);
    try testing.expectEqual(@as(usize, 8), g.stride);
}

test "grid reshape: gridWidenElem re-encodes cells into a wider int lane" {
    const gpa = testing.allocator;
    var g = try ArrayPart.initGrid(gpa, 2, 2, .u8);
    defer g.deinit(gpa);
    g.gridSet(0, 0, Value.int(5));
    g.gridSet(0, 1, Value.int(250));
    g.gridSet(1, 1, Value.int(7)); // (1,0) stays a hole

    // A store of 1000 (> u8) needs the next signed lane covering [0,255] ∪ {1000}.
    const target = ArrayPart.gridWidenTargetForInt(g.grid_elem, Value.int(1000)).?;
    try testing.expectEqual(Lane.i16, target);
    try g.gridWidenElem(gpa, target);
    try testing.expectEqual(Lane.i16, g.grid_elem);

    // Values round-trip; the hole stays a hole; row_len unchanged.
    try testing.expectEqual(@as(i64, 5), g.gridGet(0, 0).asInt());
    try testing.expectEqual(@as(i64, 250), g.gridGet(0, 1).asInt());
    try testing.expect(g.gridGet(1, 0).isNil());
    try testing.expectEqual(@as(i64, 7), g.gridGet(1, 1).asInt());
    // The widened lane now stores the value that didn't fit before.
    g.gridSet(1, 0, Value.int(1000));
    try testing.expectEqual(@as(i64, 1000), g.gridGet(1, 0).asInt());
}

test "grid reshape: gridWidenTargetForInt refuses cross-family / non-int widens" {
    // Float into an int grid, or any value into an f64 grid, has no in-family widen.
    try testing.expectEqual(@as(?Lane, null), ArrayPart.gridWidenTargetForInt(.i32, Value.float(1.0)));
    try testing.expectEqual(@as(?Lane, null), ArrayPart.gridWidenTargetForInt(.f64, Value.int(1)));
    try testing.expectEqual(@as(?Lane, null), ArrayPart.gridWidenTargetForInt(.i32, Value.boolean(true)));
    // An int that outgrows i8 climbs the signed ladder.
    try testing.expectEqual(@as(?Lane, .i16), ArrayPart.gridWidenTargetForInt(.i8, Value.int(1000)));
}

test "grid reshape: gridGrowStride is OOM-safe (grid intact on failure)" {
    const Inner = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var g = try ArrayPart.initGrid(gpa, 3, 2, .i32);
            defer g.deinit(gpa);
            g.gridSet(0, 0, Value.int(1));
            g.gridSet(2, 1, Value.int(9));
            try g.gridGrowStride(gpa, 6);
            try testing.expectEqual(@as(i64, 1), g.gridGet(0, 0).asInt());
            try testing.expectEqual(@as(i64, 9), g.gridGet(2, 1).asInt());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Inner.run, .{});
}
