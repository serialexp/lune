//! Tables — lune's one structured data type (the basis for arrays, maps, and,
//! once shapes land in Phase 9, objects/structs).
//!
//! Classic Lua split storage: a contiguous **array part** for a dense run of
//! non-negative integer keys `0..asize-1` (identity-mapped, doc 18 — the common
//! list case plus a first-class `t[0]`; `#t` stays a 1-based border), plus a
//! **hash part** for everything else. Keys are
//! normalised Lua-style — a float with an integral value maps to the same slot
//! as the equivalent integer (`t[1] == t[1.0]`), and `nil`/`NaN` keys are
//! rejected. String keys compare by pointer thanks to interning (`string.zig`).
//!
//! Phase 3 builds correct semantics; the shape/hidden-class pointer (for frozen
//! struct-like tables, Phase 9) is not here yet. Growth allocates through an
//! injected allocator (Z-4) — the table does not cache one.
//!
//! Chunk 2a adds a `metatable` field: an optional `*Table` whose well-known
//! `__index`/`__newindex`/… fields drive metamethod dispatch in the interpreter
//! (`interp.zig`). The table itself is metamethod-agnostic — it stores the
//! pointer and the VM does the lookups; `Table.get`/`set` stay **raw** (the
//! `rawget`/`rawset` semantics). The GC marks it (`gc.blacken`) and the keyframe
//! serializer persists it as a heap edge (`keyframeser.zig`).

const std = @import("std");
const object = @import("object.zig");
const value = @import("value.zig");
const arr = @import("array.zig");
const GcHeader = object.GcHeader;
const Value = value.Value;
const ArrayPart = arr.ArrayPart;

/// 2^63 as f64 — the first power of two beyond `i64`'s range, used to bound the
/// float→int key normalisation.
const two_pow_63: f64 = 9223372036854775808.0;

pub const Table = struct {
    header: GcHeader,
    /// Dense array part for the contiguous key run `0..asize-1` (identity
    /// mapping, doc 18; for a grid the extent field counts ROWS), stored in the
    /// narrowest **lane** the contents fit (a boolean bitmap, packed ints, packed
    /// floats, or full `Value`s) — see `array.zig`. The lane is an in-memory
    /// optimisation only: every reader goes through `array.get`/`set` and sees
    /// logical `Value`s, and the lane is never serialised.
    array: ArrayPart = .empty,
    /// Hash part: every key not in the array part.
    hash: Map = .empty,
    /// Optional metatable (chunk 2a). `null` = no metatable (the common case).
    /// The VM reads its well-known fields (`__index`, `__newindex`, …) for
    /// metamethod dispatch; the table stores only the pointer. A GC edge
    /// (`gc.blacken` marks it) and a keyframe edge (`keyframeser` persists its
    /// id). `Table.get`/`set` ignore it entirely — they are the raw accessors.
    metatable: ?*Table = null,
    /// Amortised rehash trigger. lune's hash part (`std.HashMapUnmanaged`)
    /// self-grows, so we can't use Lua's "hash full" hook to drive a rehash —
    /// instead we recompute the array/hash split when the hash-part population
    /// crosses this threshold, doubling it each time (`rehash`). This keeps the
    /// O(n) rehash work amortised O(1) per insert. Default-initialised, so
    /// `create`/`initBare`/restore need no extra wiring; it only gates an
    /// optimisation, never correctness.
    rehash_threshold: usize = 4,
    /// Grid hysteresis (doc 14, Phase 4b). `true` once this table has been ruled
    /// out as a flattened grid — either a `Heap.inflateToGrid` scan found it
    /// non-homogeneous, or a live grid here was deflated (an escape, a bare
    /// structural store, or a type-changing cell store). The fused `set_index2`
    /// store path skips the (potentially O(cells)) inflation scan while this is set,
    /// so each table is scanned at most once and a just-deflated grid is never
    /// immediately re-inflated (no inflate/deflate thrash). Never serialised: it
    /// only gates an in-memory optimisation, and grid vs. nested are byte-identical
    /// in logical values, so a restored table re-deciding from `false` is sound
    /// (doc 14 §Determinism gate). Default `false`; `create`/restore need no wiring.
    no_grid: bool = false,

    pub const Map = std.HashMapUnmanaged(
        Value,
        Value,
        ValueContext,
        std.hash_map.default_max_load_percentage,
    );

    /// Byte offset of the embedded `array` (`ArrayPart`) from a `*Table`. The
    /// tier-1b native compiler (`nativegen.zig`) reaches the packed array
    /// through this base plus the `ArrayPart.Layout.*` field offsets — never a
    /// literal. Frozen contract: a change to `Table`/`ArrayPart` layout
    /// recomputes the JIT's address math automatically, and a `@offsetOf`
    /// regression fails to compile rather than miscompiling.
    pub const array_off = @offsetOf(Table, "array");

    /// Byte offset of the embedded `hash` (`Map`) from a `*Table`. The native
    /// grow-store guard (`astore_append`'s `guard_append`) reads the map's `size`
    /// field at `hash_off + @offsetOf(Map, "size")` to prove the hash part is empty
    /// (so `migrateFromHash` is a no-op on-trace). Same frozen-contract spirit as
    /// `array_off`: a layout change recomputes the JIT's address math or fails to
    /// compile, never miscompiles.
    pub const hash_off = @offsetOf(Table, "hash");

    /// Errors from a store. A bad key is a `TypeError` (Lua: "table index is
    /// nil"/"is NaN"); growth can fail with `OutOfMemory`.
    pub const Error = error{ TypeError, OutOfMemory };

    /// Allocate an empty table. Raw allocation only — GC-linking is the heap's
    /// job (`gc.zig`); callers should use `Heap.newTable`.
    pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Table {
        const self = try gpa.create(Table);
        self.* = .{ .header = GcHeader.init(.table) };
        return self;
    }

    pub fn destroy(self: *Table, gpa: std.mem.Allocator) void {
        self.array.deinit(gpa);
        self.hash.deinit(gpa);
        gpa.destroy(self);
    }

    /// Recover the concrete table from its embedded header (layout-independent).
    pub fn fromHeader(h: *GcHeader) *Table {
        // `@alignCast`: no-op on native, required wasm32 alignment assertion (see
        // `String.fromHeader`). The object is allocated at `@alignOf(Table)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    /// `t[key]`. Returns `nil` for an absent or `nil`/`NaN` key (reads never
    /// error).
    pub fn get(self: *const Table, key: Value) Value {
        const nk = normalizeKey(key);
        if (nk.isInt()) return self.getInt(nk.asInt());
        if (nk.isNil()) return Value.nil();
        // No hash part → the key can't be hash-resident. The Zig hashmap's own
        // `size == 0` short-circuit lives behind a non-inlined call; checking the
        // inline `count()` here skips that call entirely on the hot array path.
        if (self.hash.count() == 0) return Value.nil();
        return self.hash.get(nk) orelse Value.nil();
    }

    /// `t[i]` for an integer key (array part fast path).
    pub fn getInt(self: *const Table, i: i64) Value {
        if (self.array.isGrid()) {
            // A grid table's rows are *virtual*: `t[i]` is a transient `row_view`
            // onto grid row `i-1` (a fat value, no heap object), not a stored
            // slot. The handle carries this table's header so an inner index
            // (`row[j]`) can forward into the flat cell buffer. (Phase 3, doc 14.)
            // Doc 18 D6: for a grid the field means ROW COUNT and rows are keys
            // `1..rows` — the unsigned `inArray` gate would admit `i == 0` and
            // panic in the `i - 1` cast, so the grid arm keeps an explicit
            // `i >= 1` gate; grid key 0 falls through to the hash part.
            // `@constCast`: the handle borrows the table mutably (an inner store
            // writes a cell); the table is genuinely heap-mutable — `*const` is
            // only this read path's view.
            if (i >= 1 and i <= @as(i64, @intCast(self.array.gridRows())))
                return Value.rowView(@constCast(&self.header), @intCast(i - 1));
        } else if (arr.ArrayPart.inArray(i, self.array.asize)) {
            return self.array.get(@intCast(i));
        }
        // Out of array range: only the hash part can hold this key. Skip the
        // (non-inlined) hashmap call when there is no hash part — the common case
        // on an array being built/read by contiguous integer keys.
        if (self.hash.count() == 0) return Value.nil();
        return self.hash.get(Value.int(i)) orelse Value.nil();
    }

    /// `row_view[key]` read — forward an inner index of a grid row into the flat
    /// cell buffer. `rv` must be a `row_view`. A non-integer or out-of-stride key
    /// reads `nil`: a grid row holds only its numeric cells (no hash part, no
    /// metatable until it deflates — Phase 5). (Phase 3, doc 14.)
    pub fn rowViewGet(rv: Value, key: Value) Value {
        const t = fromHeader(rv.rowViewParent());
        std.debug.assert(t.array.isGrid());
        const row: usize = rv.rowViewRow();
        const nk = normalizeKey(key);
        if (nk.isInt()) {
            const j = nk.asInt();
            if (j >= 1 and j <= @as(i64, @intCast(t.array.stride)))
                return t.array.gridGet(row, @intCast(j - 1));
        }
        return Value.nil();
    }

    /// `row_view[key] = val` write — forward an inner store into the grid row's
    /// flat cell buffer. Returns `true` once stored. Returns `false` when the
    /// store cannot stay in the grid — a non-integer key, an index past the
    /// stride, or a value that does not fit the cell lane (`grid_elem`); the
    /// caller must then deflate the row to a real table (Phase 5). A `nil` store
    /// fits every lane and punches a hole. (Phase 3, doc 14.)
    pub fn rowViewSet(rv: Value, key: Value, val: Value) bool {
        const t = fromHeader(rv.rowViewParent());
        std.debug.assert(t.array.isGrid());
        const row: usize = rv.rowViewRow();
        const nk = normalizeKey(key);
        if (nk.isInt()) {
            const j = nk.asInt();
            if (j >= 1 and j <= @as(i64, @intCast(t.array.stride)) and
                ArrayPart.laneFits(t.array.grid_elem, val))
            {
                t.array.gridSet(row, @intCast(j - 1), val);
                return true;
            }
        }
        return false;
    }

    /// Logical length of grid row `row` (0-based) — its `#` border. (Phase 3.)
    pub fn rowViewLen(rv: Value) i64 {
        const t = fromHeader(rv.rowViewParent());
        std.debug.assert(t.array.isGrid());
        return @intCast(t.array.gridRowLen(rv.rowViewRow()));
    }

    /// Pointer to the **hash-part** value cell for `key`, or `null` if the key is
    /// absent from the hash part (including when it lives in the array part — this
    /// is hash-part only, by design). The JIT recorder/oracle (doc 11) uses this to
    /// (a) prove a string field key is *present* before tracing a `t.field` access,
    /// and (b) read/overwrite the cell in place. The returned pointer is stable
    /// across iterations unless the map grows/rehashes (which `guard_hash` catches),
    /// so it is hoistable to the native prologue. The key is normalised (`2.0`↔`2`),
    /// matching `get`/`set`. Never migrates or reshapes the table.
    pub fn fieldPtr(self: *Table, key: Value) ?*Value {
        return self.hash.getPtr(normalizeKey(key));
    }

    /// `t[key] = val`. A `nil`/`NaN` key errors; storing `nil` deletes.
    pub fn set(self: *Table, gpa: std.mem.Allocator, key: Value, val: Value) Error!void {
        // A grid table never takes a raw store: outer row (re)assignment and row
        // append are deflation triggers handled in the interpreter's `indexSet`
        // (Phase 5), which intercepts grids before reaching here.
        std.debug.assert(!self.array.isGrid());
        if (key.isNil()) return Error.TypeError;
        if (key.isFloat() and std.math.isNan(key.asFloat())) return Error.TypeError;

        const nk = normalizeKey(key);
        if (nk.isInt()) {
            const i = nk.asInt();
            const asize: i64 = @intCast(self.array.asize);
            if (arr.ArrayPart.inArray(i, self.array.asize)) {
                try self.array.setInPlace(gpa, @intCast(i), val);
                return;
            }
            if (i == asize and !val.isNil()) {
                // Contiguous append at key == asize (doc 18 D1/D2.3). On a fresh
                // part this is key 0 and routes through the seed primitive, which
                // owns the eager lane commit (`seedAt(0)` IS append under
                // identity mapping).
                if (asize == 0) {
                    try self.array.seedAt(gpa, i, val);
                } else {
                    try self.array.append(gpa, val);
                }
                try self.migrateFromHash(gpa);
                return;
            }
            if (asize == 0 and i == 1 and !val.isNil()) {
                // Fresh-part 1-based idiom (doc 18 D2a): seed `[hole, val]` with
                // `asize = 2` so the ubiquitous `t = {}; t[1] = x` build stays
                // array-resident from the first write.
                try self.array.seedAt(gpa, i, val);
                try self.migrateFromHash(gpa);
                return;
            }
            // A non-contiguous integer key would land in the hash part. If this
            // is a *new* key (not already hash-resident) and the hash population
            // has crossed the rehash threshold, recompute the optimal array/hash
            // split (Lua's `rehash`): a dense run of integer keys (e.g. nsieve's
            // `t[2..m]`, which never sets `t[1]`) migrates into the array part
            // instead of bloating the hash. Then retry the array fast paths *once*
            // — after a grow, `i` may now be in range or be the contiguous
            // successor. A sparse key (the array did not grow to cover it) simply
            // falls through to the hash put below. The retry is non-recursive, so
            // this cannot loop. We require the key be new so a pure value-update
            // of an existing hash key neither double-counts it in the histogram
            // nor changes the table's storage shape (Lua's `rehash` likewise only
            // runs for a key not yet in the table).
            if (!val.isNil() and
                self.hash.count() + 1 >= self.rehash_threshold and
                !self.hash.contains(nk))
            {
                try self.rehash(gpa, i);
                if (arr.ArrayPart.inArray(i, self.array.asize)) {
                    try self.array.setInPlace(gpa, @intCast(i), val);
                    return;
                }
                if (i == @as(i64, @intCast(self.array.asize)) and self.array.asize != 0) {
                    try self.array.append(gpa, val);
                    try self.migrateFromHash(gpa);
                    return;
                }
            }
            // otherwise falls through to the hash part
        }

        if (val.isNil()) {
            _ = self.hash.remove(nk);
        } else {
            try self.hash.put(gpa, nk, val);
        }
    }

    /// Restore-only: insert a key/value straight into the **hash part**, bypassing
    /// `set`'s array-migration logic. The keyframe restorer (`keyframeser.zig`)
    /// uses this to reproduce a snapshot's *exact* array/hash split: a serialized
    /// hash-part entry whose key is an integer that happens to be contiguous with
    /// the already-rebuilt array part must NOT migrate into the array (or the
    /// restored table would re-serialize differently than it was captured). The
    /// array part is restored separately by appending into `array` directly, so
    /// this only ever handles genuine hash-part keys. The key is normalised (so
    /// `2.0` and `2` still collapse), and `nil`/`NaN` keys are rejected as in `set`.
    pub fn restoreEntry(self: *Table, gpa: std.mem.Allocator, key: Value, val: Value) Error!void {
        if (key.isNil()) return Error.TypeError;
        if (key.isFloat() and std.math.isNan(key.asFloat())) return Error.TypeError;
        try self.hash.put(gpa, normalizeKey(key), val);
    }

    /// After extending the array part, absorb any now-contiguous successor keys
    /// that were sitting in the hash part.
    fn migrateFromHash(self: *Table, gpa: std.mem.Allocator) Error!void {
        // Nothing in the hash part can be a contiguous successor if the hash part
        // is empty — and a sequential array build keeps it empty. This inline
        // guard keeps every such append off the non-inlined hashmap probe.
        if (self.hash.count() == 0) return;
        while (true) {
            // Doc 18 D2.3 identity: the contiguous successor key IS `asize`.
            const next = Value.int(@as(i64, @intCast(self.array.asize)));
            const v = self.hash.get(next) orelse break;
            if (v.isNil()) break;
            try self.array.append(gpa, v);
            _ = self.hash.remove(next);
        }
    }

    /// Largest integer key (bits) the array part is allowed to index. Lua bounds
    /// this by `int`'s width; we cap well below `i64` so the histogram, the
    /// `1 << bucket` math, and the array allocation can never overflow. Keys past
    /// this stay in the hash part regardless of density (they'd never be dense
    /// enough to migrate anyway). 2^48 slots is far beyond any feasible array.
    const MAXABITS: u6 = 48;
    /// Histogram length: one bucket per `ceil(log2)` value in `[0, MAXABITS]`.
    const NBUCKETS: usize = @as(usize, MAXABITS) + 1;

    /// `ceil(log2(k))` for `k >= 1`. Binning uses `ceillog2(k + 1)` — the
    /// smallest `b` with `2^b > k`, i.e. the smallest power-of-two extent whose
    /// slot range `0..2^b-1` contains key `k` (doc 18 D7): key 0 → bin 0
    /// (size 1), key 1 → bin 1 (size 2), keys 2–3 → bin 2 (size 4), keys 4–7 →
    /// bin 3, … The `+1` shift also dissolves the `ceillog2(0)` hazard
    /// structurally (`ceillog2(0 + 1) = 0`, no special case).
    fn ceillog2(k: u64) u6 {
        if (k <= 1) return 0;
        return @intCast(64 - @clz(k - 1));
    }

    /// Tally one integer key into the power-of-two histogram. Returns true iff
    /// `k` is a valid *array index* — array-eligible ⇔
    /// `@bitCast(k) < 2^MAXABITS` (doc 18 D7: key 0 counts, negatives are
    /// excluded by the unsigned wrap). Mirrors Lua's `countint`/`arrayindex`
    /// shifted to the 0-based key range.
    fn countKey(k: i64, nums: *[NBUCKETS]u32) bool {
        const uk: u64 = @bitCast(k);
        if (uk >= (@as(u64, 1) << MAXABITS)) return false;
        nums[ceillog2(uk + 1)] += 1;
        return true;
    }

    /// Lua's `computesizes`: pick the optimal power-of-two array size given the
    /// key histogram and the total number of array-index keys. The array grows to
    /// the largest `2^i` for which it gains keys (`nums[i] > 0`) while staying
    /// "cheaper than the hash" under `arrayXhash(na, nh) := na <= nh*3` (an array
    /// slot costs ~⅓ of a hash node). Returns the chosen size (0 = keep hashing).
    /// Arithmetic is in `u64` (not `usize`) on purpose: `twotoi` ranges up to
    /// `2^MAXABITS`, which overflows a 32-bit `usize` on the wasm target. The
    /// returned size is bounded by `na_total*3` (the density gate) — i.e. by the
    /// live key count, hence by addressable memory — so it always fits `usize`.
    fn computeArraySize(nums: *const [NBUCKETS]u32, na_total: u64) u64 {
        var a: u64 = 0; // keys seen so far (< twotoi)
        var optimal: u64 = 0;
        var i: usize = 0;
        var twotoi: u64 = 1; // 2^i
        // Stop once an array of `twotoi` slots could no longer be justified by the
        // total array-index count (`arrayXhash(twotoi, na_total)`), or the bucket
        // index runs off the histogram.
        while (i <= MAXABITS and twotoi <= na_total *| 3) : ({
            i += 1;
            twotoi <<= 1;
        }) {
            a += nums[i];
            if (nums[i] > 0 and twotoi <= a *| 3) { // arrayXhash(twotoi, a)
                optimal = twotoi;
            }
        }
        return optimal;
    }

    /// Recompute the array/hash split (Lua's `rehash`). Counts every integer key
    /// — the pending `extra_key`, the hash part, and the existing array part —
    /// into a power-of-two histogram, asks `computeArraySize` for the optimal
    /// array size, and if that grows the array, migrates the now-covered dense
    /// integer keys out of the hash into their array slots. Grow-only: a rehash
    /// is always insert-driven, so the array never needs to shrink here.
    ///
    /// Determinism: this is a pure function of the table's current contents (no
    /// addresses, no iteration-order dependence), and it runs *only* from `set`,
    /// never on the keyframe-restore path — so snapshot capture/restore stays
    /// byte-identical (the restorer reproduces a captured split verbatim via
    /// `restoreEntry` + direct array append).
    fn rehash(self: *Table, gpa: std.mem.Allocator, extra_key: i64) Error!void {
        var nums: [NBUCKETS]u32 = @splat(0);
        var na_total: usize = 0;

        if (countKey(extra_key, &nums)) na_total += 1;

        var it = self.hash.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.isInt() and countKey(e.key_ptr.asInt(), &nums)) na_total += 1;
        }

        var idx: usize = 0;
        while (idx < self.array.asize) : (idx += 1) {
            if (!self.array.get(idx).isNil() and countKey(@intCast(idx), &nums)) na_total += 1;
        }

        // `new_asize` is bounded by `na_total*3` (density gate), hence by the live
        // key count, so it always fits `usize` on every target.
        const new_asize: usize = @intCast(computeArraySize(&nums, na_total));
        const old_asize = self.array.asize;

        // Grow-only: a rehash is insert-driven, so the array never shrinks. When
        // the density test declines to grow (`new_asize <= old_asize`) there is
        // nothing to migrate — but we still bump the threshold below so that
        // repeated sparse inserts don't re-run this O(n) histogram on every one.
        if (new_asize > old_asize) {
            // `resize` fills the new slots `[old_asize, new_asize)` with holes.
            try self.array.resize(gpa, new_asize);

            // Drain dense integer keys now covered by the array out of the hash.
            // Keys `< old_asize` are already array-resident (set() keeps them
            // there), so only keys `[old_asize, new_asize-1]` — the newly covered
            // identity slots — can still be in the hash.
            var k: usize = old_asize;
            while (k < new_asize) : (k += 1) {
                const key = Value.int(@intCast(k));
                if (self.hash.get(key)) |val| {
                    // Write into the array part *before* evicting from the hash: a
                    // widening inside `setInPlace` can OOM, and a `fetchRemove`-first
                    // ordering would drop the entry on failure. On that OOM the keys
                    // `[k, new_asize-1]` are still hash-resident, so trim the array
                    // extent back to `k` — the first uncommitted physical slot (doc
                    // 18 D7): the array then covers exactly the migrated keys
                    // `< k`, and the freshly-resized nil holes at `[k, new_asize)`
                    // can no longer *shadow* those live hash entries on a later
                    // `get` (which consults the array part for any in-extent index).
                    self.array.setInPlace(gpa, k, val) catch |e| {
                        self.array.asize = k;
                        return e;
                    };
                    _ = self.hash.remove(key);
                }
            }
        }

        // Pick the array part's storage lane — but only **once**, on the first
        // rehash, then freeze it. The rehash already walked every element above,
        // and this pass folds the array into the narrowest lane it fits (e.g.
        // nsieve's all-boolean sieve → a 1-bit boolean lane), recovering most of
        // the per-slot `Value` width. After this one-shot commit the lane is
        // **monotonic**: it only ever widens, and only on the store path (an
        // out-of-lane store steps up the lane lattice via `ArrayPart.widenFor`) —
        // rehash never re-narrows. That bounds an array's total repack work to
        // amortised O(1)/slot and removes the repeated widen+re-narrow attack a
        // fresh table could otherwise be milked for. `repack` is OOM-safe and
        // leaves `self` untouched on failure, so `frozen` is set only after it
        // succeeds (a retried rehash re-attempts the commit). A pure in-memory
        // change — invisible to `get`/keyframes (see `array.zig`).
        //
        // Freeze **only** when we actually commit to a narrow lane. If `optimalLane`
        // returns `.value` (the array is empty, heterogeneous, or heap-bearing at
        // this rehash) there is nothing to lock in, so leave `frozen` false: a later
        // rehash, once the contents have settled into a homogeneous run (e.g. an
        // initially-sparse table that fills a dense int range), can still narrow it.
        // The narrowing → `.value` direction is the one-time commit; once a *narrow*
        // lane is committed (`frozen = true`), the lane only ever widens (store path)
        // and is never re-narrowed — so this still closes the repeated-repack attack.
        if (!self.array.frozen) {
            const lane = self.array.optimalLane();
            if (lane.isNarrow()) {
                try self.array.repack(gpa, lane);
                self.array.frozen = true;
            }
        }

        // Amortise: don't rehash again until the hash population roughly doubles.
        // (`hash.count()` here excludes the still-pending `extra_key`, which the
        // caller stores after we return.)
        self.rehash_threshold = @max(self.hash.count() * 2, 4);
    }

    /// A *border* `n` such that `t[n] ~= nil` and `t[n+1] == nil` (or `0`). Like
    /// Lua, with holes any valid border may be returned; this is `#t`.
    pub fn length(self: *const Table) i64 {
        // Every grid row `1..rows` is a present `row_view` (a table is never nil)
        // and a grid carries no hash-part border, so `#t` is exactly the row
        // count. (Phase 3, doc 14.)
        if (self.array.isGrid()) return @intCast(self.array.gridRows());
        // Doc 18: the extent covers keys 0..asize-1, but `#t` stays a 1-based
        // border — the maximum candidate is key `asize - 1`, and key 0 never
        // participates (the trim loop stops at n == 0 exactly as before).
        var n: usize = if (self.array.asize == 0) 0 else self.array.asize - 1;
        const max_key = n;
        // Trim trailing nils: if the array part ends in a nil, the border is the
        // last non-nil prefix and cannot extend past it.
        while (n > 0 and self.array.get(n).isNil()) n -= 1;
        if (n < max_key) return @intCast(n);

        // Array part is non-nil through its end; the border may continue into the
        // hash part. Unbound-then-binary search, as luaH_getn does.
        if (self.hash.count() == 0) return @intCast(n);
        var i: i64 = @intCast(n); // getInt(i) non-nil (or i == 0)
        var j: i64 = i + 1;
        while (!self.getInt(j).isNil()) {
            i = j;
            if (j > @divFloor(std.math.maxInt(i64), 2)) {
                // Pathological: fall back to a linear scan from 1.
                var k: i64 = 1;
                while (!self.getInt(k).isNil()) k += 1;
                return k - 1;
            }
            j *= 2;
        }
        // getInt(i) non-nil, getInt(j) nil → binary search the border between.
        while (j - i > 1) {
            const m = @divFloor(i + j, 2);
            if (self.getInt(m).isNil()) j = m else i = m;
        }
        return i;
    }
};

/// Map key normalisation: a float with an exact integral value in `i64` range
/// becomes the equivalent integer key, so `t[2]` and `t[2.0]` are one slot.
/// Everything else is returned unchanged. Public so the interpreter's fused
/// grid-cell paths (doc 14) normalise outer/inner index keys the same way
/// `get`/`set` do (`a[i][2.0]` ↔ `a[i][2]`).
pub inline fn normalizeKey(key: Value) Value {
    // `inline`: this is a single tag-compare on the hot int-key path, but the
    // compiler was emitting it as a real call (its own symbol, 16-byte `Value`
    // passed by value) — ~6.5% of grid_matmul_f64's tier-0 run was the call
    // overhead alone, paid twice per fused cell read (`gridCellGet`). Folding it
    // into the 11 call sites collapses the common path to a tag check + return.
    if (key.isFloat()) {
        const f = key.asFloat();
        if (!std.math.isNan(f) and !std.math.isInf(f) and
            @floor(f) == f and f >= -two_pow_63 and f < two_pow_63)
        {
            return Value.int(@intFromFloat(f));
        }
    }
    return key;
}

/// Hash/equality for `Value` keys. Stateless (zero-sized), so the unmanaged map's
/// inferred-context convenience methods apply. Keys are always normalised before
/// they reach here, so equal keys (per `Value.eql`) share tag+payload bits and
/// therefore hash identically.
pub const ValueContext = struct {
    pub fn hash(_: ValueContext, v: Value) u64 {
        // The key is always a tag (1 byte) plus an 8-byte payload, so there is
        // nothing to *stream*: a fixed-width integer avalanche hashes it in a
        // handful of instructions, where `std.hash.Wyhash` paid init+update+final
        // overhead on every single lookup. That per-lookup `Wyhash.final` was
        // ~45–57% of the runtime of the table-heavy benchmarks (nbody, array3d)
        // and dominated `field_hash`; replacing it cut nbody by ~13% of cycles
        // and field_hash by ~16% of instructions.
        //
        // Determinism: this is a pure function of `(tag, payload)`, identical in
        // all 8 modes and on replay. It does NOT affect observable iteration
        // order — that is imposed by `key_order.keyLessThan`'s canonical sort in
        // both `keyframeser.sortedHashEntries` and `pairs`/`next`, which erases
        // the hash-map's internal probe order (see docs/design/02-determinism.md
        // §"Table iteration order"). So the function is free to change without
        // touching any snapshot golden. (`eql` below still does the full
        // `Value.eql`, so distribution quality is a performance concern only,
        // never correctness.)
        const payload: u64 = if (v.isHeap())
            // Hash a heap key by its stable, deterministic object `id`, NOT
            // `payload.bits` (the object's ASLR-dependent address). Consistent
            // with `eql`: equal heap keys are the same interned object, same id.
            v.asHeap().id
        else
            v.payload.bits;

        // Fold the tag into the payload (spread across the word first so a small
        // ordinal still perturbs the high bits), then run a splitmix64-style
        // finalizer — a well-distributed 64-bit avalanche.
        var x = payload ^ (@as(u64, @intFromEnum(v.tag)) *% 0x9E3779B97F4A7C15);
        x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
        x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
        return x ^ (x >> 31);
    }
    pub fn eql(_: ValueContext, a: Value, b: Value) bool {
        return a.eql(b);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "set/get across array and hash parts" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.int(1), Value.int(10));
    try t.set(gpa, Value.int(2), Value.int(20));
    try t.set(gpa, Value.int(100), Value.int(999)); // sparse → hash part

    try testing.expectEqual(@as(i64, 10), t.get(Value.int(1)).asInt());
    try testing.expectEqual(@as(i64, 20), t.get(Value.int(2)).asInt());
    try testing.expectEqual(@as(i64, 999), t.get(Value.int(100)).asInt());
    try testing.expect(t.get(Value.int(3)).isNil());
}

test "float keys with integral value alias integer keys" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.int(1), Value.int(42));
    try testing.expectEqual(@as(i64, 42), t.get(Value.float(1.0)).asInt());

    try t.set(gpa, Value.float(2.0), Value.int(7));
    try testing.expectEqual(@as(i64, 7), t.get(Value.int(2)).asInt());

    // a non-integral float is its own distinct key
    try t.set(gpa, Value.float(2.5), Value.int(8));
    try testing.expectEqual(@as(i64, 8), t.get(Value.float(2.5)).asInt());
    try testing.expectEqual(@as(i64, 7), t.get(Value.int(2)).asInt());
}

test "appending pulls contiguous successors out of the hash part" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Insert 2 and 3 first (land in hash), then 1 (extends array → migrate).
    try t.set(gpa, Value.int(2), Value.int(2));
    try t.set(gpa, Value.int(3), Value.int(3));
    try testing.expectEqual(@as(i64, 0), t.length()); // no border yet (1 missing)
    try t.set(gpa, Value.int(1), Value.int(1));
    try testing.expectEqual(@as(i64, 3), t.length()); // 1,2,3 now contiguous
}

test "length border and deletion" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    var i: i64 = 1;
    while (i <= 5) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * i));
    try testing.expectEqual(@as(i64, 5), t.length());

    // Delete the tail; the border shrinks.
    try t.set(gpa, Value.int(5), Value.nil());
    try testing.expectEqual(@as(i64, 4), t.length());
    try testing.expect(t.get(Value.int(5)).isNil());
}

test "nil and NaN keys are rejected; missing keys read nil" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try testing.expectError(Table.Error.TypeError, t.set(gpa, Value.nil(), Value.int(1)));
    try testing.expectError(Table.Error.TypeError, t.set(gpa, Value.float(std.math.nan(f64)), Value.int(1)));
    try testing.expect(t.get(Value.nil()).isNil());
    try testing.expect(t.get(Value.boolean(true)).isNil());
}

test "boolean and (interned-style) pointer keys live in the hash part" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.boolean(true), Value.int(1));
    try t.set(gpa, Value.boolean(false), Value.int(2));
    try testing.expectEqual(@as(i64, 1), t.get(Value.boolean(true)).asInt());
    try testing.expectEqual(@as(i64, 2), t.get(Value.boolean(false)).asInt());
}

test "ValueContext.hash is a pure function and distributes distinct scalar keys" {
    const ctx = ValueContext{};
    // Pure: same key → same hash, every time.
    try testing.expectEqual(ctx.hash(Value.int(42)), ctx.hash(Value.int(42)));
    try testing.expectEqual(ctx.hash(Value.boolean(true)), ctx.hash(Value.boolean(true)));

    // Distinct keys should (overwhelmingly) land on distinct hashes — a weak but
    // real distribution guard. A contiguous int run is the worst case for a bad
    // mixer (identity hashing would still be collision-free here, but a finalizer
    // that drops bits would not); also fold in a different tag with the same bits.
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    var i: i64 = 0;
    var collisions: usize = 0;
    while (i < 1024) : (i += 1) {
        const gop = try seen.getOrPut(ctx.hash(Value.int(i)));
        if (gop.found_existing) collisions += 1;
    }
    try testing.expectEqual(@as(usize, 0), collisions);
    // The tag is folded in: int 1 and bool 1 (same payload bits) hash apart.
    try testing.expect(ctx.hash(Value.int(1)) != ctx.hash(Value.boolean(true)));
}

// ---- doc 18 §T: slot-0 array part ----

test "set/get: key 0 is a first-class array key; negatives stay hash-resident" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Fresh t[0] = x is exactly the append seed: asize 1, no hole.
    try t.set(gpa, Value.int(0), Value.int(100));
    try testing.expectEqual(@as(usize, 1), t.array.asize);
    try testing.expectEqual(@as(usize, 0), t.hash.count());
    try testing.expectEqual(@as(i64, 100), t.get(Value.int(0)).asInt());
    // The contiguous successor chain continues 1, 2, ... (key == asize).
    try t.set(gpa, Value.int(1), Value.int(101));
    try t.set(gpa, Value.int(2), Value.int(102));
    try testing.expectEqual(@as(usize, 3), t.array.asize);
    try testing.expectEqual(@as(usize, 0), t.hash.count());
    // Negative keys can never be array-resident (unsigned wrap): hash only.
    try t.set(gpa, Value.int(-1), Value.int(7));
    try testing.expectEqual(@as(usize, 3), t.array.asize);
    try testing.expectEqual(@as(usize, 1), t.hash.count());
    try testing.expectEqual(@as(i64, 7), t.get(Value.int(-1)).asInt());
    // Float-spelled 0.0 aliases integer key 0 (normalizeKey).
    try testing.expectEqual(@as(i64, 100), t.get(Value.float(0.0)).asInt());
    try t.set(gpa, Value.float(0.0), Value.int(200));
    try testing.expectEqual(@as(i64, 200), t.get(Value.int(0)).asInt());
    try testing.expectEqual(@as(usize, 3), t.array.asize); // in-place, no reshape
}

test "length: t[0] never changes #t (1-based border), incl. the deletion edge" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try testing.expectEqual(@as(i64, 0), t.length());
    try t.set(gpa, Value.int(0), Value.int(1));
    try testing.expectEqual(@as(i64, 0), t.length()); // key 0 alone: #t == 0
    try t.set(gpa, Value.int(1), Value.int(2));
    try t.set(gpa, Value.int(2), Value.int(3));
    try testing.expectEqual(@as(i64, 2), t.length());
    // Deleting key 0 leaves the 1-based border untouched.
    try t.set(gpa, Value.int(0), Value.nil());
    try testing.expectEqual(@as(i64, 2), t.length());
}

test "set: fresh t[1] seeds [hole, v] and the append chain continues at 2" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.int(1), Value.int(10));
    try testing.expectEqual(@as(usize, 2), t.array.asize); // [hole, 10]
    try testing.expectEqual(@as(usize, 0), t.hash.count());
    try testing.expect(t.get(Value.int(0)).isNil());
    try testing.expectEqual(@as(i64, 10), t.get(Value.int(1)).asInt());
    try t.set(gpa, Value.int(2), Value.int(20)); // key == asize: append
    try testing.expectEqual(@as(usize, 3), t.array.asize);
    try testing.expectEqual(@as(i64, 20), t.get(Value.int(2)).asInt());
    // Back-filling the slot-0 hole is an in-place store, no reshape.
    try t.set(gpa, Value.int(0), Value.int(5));
    try testing.expectEqual(@as(usize, 3), t.array.asize);
    try testing.expectEqual(@as(i64, 5), t.get(Value.int(0)).asInt());
}

test "computeArraySize: chosen power-of-two extent always contains the counted keys (63/64/65/127/128)" {
    // Doc 18 D7: bin(k) = ceillog2(k+1) — the smallest power-of-two size whose
    // slot range 0..2^b-1 contains key k. At exact power-of-two max keys the
    // chosen size steps to the NEXT power (the accepted §R2 memory overshoot):
    // a dense 2..64 run needs slot 64 → size 128, where the 1-based scheme could
    // stop at 64.
    const Case = struct { max_key: i64, want: u64 };
    const cases = [_]Case{
        .{ .max_key = 63, .want = 64 },
        .{ .max_key = 64, .want = 128 },
        .{ .max_key = 65, .want = 128 },
        .{ .max_key = 127, .want = 128 },
        .{ .max_key = 128, .want = 256 },
    };
    for (cases) |c| {
        var nums: [Table.NBUCKETS]u32 = @splat(0);
        var na: u64 = 0;
        var k: i64 = 2;
        while (k <= c.max_key) : (k += 1) {
            if (Table.countKey(k, &nums)) na += 1;
        }
        const size = Table.computeArraySize(&nums, na);
        try testing.expectEqual(c.want, size);
        // The invariant the binning shift exists for: the chosen size CONTAINS
        // every counted key (round-1's off-by-one is structurally impossible).
        try testing.expect(size == 0 or size > @as(u64, @intCast(c.max_key)));
    }
    // Key 0 alone → bin 0 → size 1; key 1 alone → bin 1 → size 2.
    {
        var nums: [Table.NBUCKETS]u32 = @splat(0);
        try testing.expect(Table.countKey(0, &nums));
        try testing.expectEqual(@as(u64, 1), Table.computeArraySize(&nums, 1));
    }
    {
        var nums: [Table.NBUCKETS]u32 = @splat(0);
        try testing.expect(Table.countKey(1, &nums));
        try testing.expectEqual(@as(u64, 2), Table.computeArraySize(&nums, 1));
    }
    // Negative keys are never array-eligible (unsigned wrap in countKey).
    {
        var nums: [Table.NBUCKETS]u32 = @splat(0);
        try testing.expect(!Table.countKey(-1, &nums));
        try testing.expect(!Table.countKey(std.math.minInt(i64), &nums));
    }
}

test "rehash: a dense run from 0 (0-indexed build via hash) migrates incl. key 0" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Insert descending so no key is ever the contiguous successor — everything
    // lands in the hash until a rehash migrates the dense 0-based run.
    var i: i64 = 32;
    while (i >= 0) : (i -= 1) try t.set(gpa, Value.int(i), Value.int(i * 10));

    // The dense run — including key 0 — migrated into the array part. (The
    // topmost key can lag in the hash until the *next* rehash if the last
    // migration's chosen size stopped just below it; that boundary straggler is
    // pre-existing behaviour, not a slot-0 artifact.)
    try testing.expect(t.array.asize >= 32);
    try testing.expect(t.hash.count() <= 1);
    try testing.expect(arr.ArrayPart.inArray(0, t.array.asize));
    i = 0;
    while (i <= 32) : (i += 1) try testing.expectEqual(i * 10, t.get(Value.int(i)).asInt());
}

test "rehash: a dense run from 2 (the nsieve pattern) packs into the array part" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // `p[2..K]` with no `p[1]` — exactly nsieve's sieve fill. Without rehash this
    // piles every key into the hash; with it, the dense run migrates into the
    // array part. Store distinct values so migration correctness is also checked.
    const K: i64 = 64;
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * 10));

    // Every key reads back its value; key 1 was never set.
    try testing.expect(t.get(Value.int(1)).isNil());
    i = 2;
    while (i <= K) : (i += 1) {
        try testing.expectEqual(i * 10, t.get(Value.int(i)).asInt());
    }

    // The regression guard: the keys live in the array part now, not the hash.
    // Doc 18: `asize` is a non-inclusive slot count, so covering key K needs
    // `asize >= K + 1` (slots 0..K).
    try testing.expect(t.array.asize >= @as(usize, @intCast(K + 1)));
    try testing.expectEqual(@as(usize, 0), t.hash.count());
    try testing.expect(t.array.get(0).isNil()); // slot-0 hole (key 0 never set)
    try testing.expect(t.array.get(1).isNil()); // key 1 is a nil hole
}

test "rehash: sparse integer keys stay in the hash part (density gate)" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.int(1), Value.int(1)); // fresh 1-based seed: asize 2, slot-0 hole
    // Four widely-spaced keys: enough inserts to trip the rehash trigger, but the
    // density test must decline to grow the array for them.
    const sparse = [_]i64{ 1_000_000, 2_000_000, 3_000_000, 4_000_000 };
    for (sparse) |k| try t.set(gpa, Value.int(k), Value.int(k));

    try testing.expectEqual(@as(usize, 2), t.array.asize); // array did NOT bloat
    try testing.expectEqual(@as(usize, sparse.len), t.hash.count());
    for (sparse) |k| try testing.expectEqual(k, t.get(Value.int(k)).asInt());
    try testing.expectEqual(@as(i64, 1), t.get(Value.int(1)).asInt());
}

test "rehash: float-normalized and non-integer keys survive the migration" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Build a dense run that will rehash, mixing in a float-spelled key.
    var i: i64 = 2;
    while (i <= 40) : (i += 1) {
        if (i == 7) {
            try t.set(gpa, Value.float(7.0), Value.int(700)); // float key → int 7
        } else {
            try t.set(gpa, Value.int(i), Value.int(i * 10));
        }
    }
    // A boolean key inserted before and read after the rehash stays in the hash.
    try t.set(gpa, Value.boolean(true), Value.int(-1));

    // Float/int spellings alias the same (now array-resident) slot.
    try testing.expectEqual(@as(i64, 700), t.get(Value.int(7)).asInt());
    try testing.expectEqual(@as(i64, 700), t.get(Value.float(7.0)).asInt());
    // The non-integer key is untouched by array migration.
    try testing.expectEqual(@as(i64, -1), t.get(Value.boolean(true)).asInt());
    try testing.expect(t.get(Value.int(7)).isInt()); // not lost/overwritten
}

test "rehash: updating an existing hash key never reshapes the table" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Many distinct sparse keys → hash-resident, array stays small. Inserting
    // these crosses the rehash trigger repeatedly (each declines to grow).
    var j: i64 = 1;
    while (j <= 20) : (j += 1) try t.set(gpa, Value.int(j * 1000), Value.int(j));
    const asize_before = t.array.asize;

    // Re-setting keys that already live in the hash must NOT trigger a reshape
    // (no phantom histogram double-count) — it is a plain in-place value update.
    j = 1;
    while (j <= 20) : (j += 1) try t.set(gpa, Value.int(j * 1000), Value.int(j * 7));
    try testing.expectEqual(asize_before, t.array.asize); // shape unchanged
    j = 1;
    while (j <= 20) : (j += 1) {
        try testing.expectEqual(j * 7, t.get(Value.int(j * 1000)).asInt());
    }
}

test "lane: the nsieve bool pattern packs into a boolean lane (hole at 1)" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // `p[2..K] = true` — nsieve's sieve, all booleans, no p[1].
    const K: i64 = 80;
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    // After rehash+repack the array part is a narrow boolean lane.
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);
    try testing.expect(t.array.isLeaf()); // no heap pointers → GC can skip it

    // Every value reads back; key 1 is a hole (nil), not `false`.
    try testing.expect(t.get(Value.int(1)).isNil());
    i = 2;
    while (i <= K) : (i += 1) {
        const v = t.get(Value.int(i));
        try testing.expect(v.isBool());
        try testing.expectEqual(true, v.asBool());
    }
    // `#t` is unchanged by the packing: the trailing-nil trim lands on the last
    // contiguous non-nil slot, so the border is K regardless of the hole at 1.
    try testing.expectEqual(K, t.length());
}

test "lane: a small-int run packs into a narrow int lane (16-bit example)" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Dense 2..N (hole at 1, so the first inserts route through the hash part and
    // trip a rehash, where the lane is committed once). Values stay within
    // [-32768, 32767] so the committed lane is i16 and no later store needs to
    // widen it. (An int escaping i16 would step the lane *up* the int ladder, not
    // jump to `.value`; a non-int would fall to `.value`. The array.zig unit tests
    // cover the monotonic step-up and i32 selection directly.)
    const N: i64 = 64;
    var i: i64 = 2;
    while (i <= N) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * 100)); // max 6400

    try testing.expectEqual(arr.Lane.i16, t.array.lane);
    try testing.expect(t.array.isLeaf());
    i = 2;
    while (i <= N) : (i += 1) {
        try testing.expectEqual(i * 100, t.get(Value.int(i)).asInt());
    }
    try testing.expect(t.get(Value.int(1)).isNil());
    try testing.expectEqual(N, t.length());
}

test "lane: tiny-int run picks i8" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Dense run (hole at 1 to force a rehash), all values within [-128, 127].
    const N: i64 = 40;
    var i: i64 = 2;
    while (i <= N) : (i += 1) try t.set(gpa, Value.int(i), Value.int(@mod(i, 100) - 50));

    try testing.expectEqual(arr.Lane.i8, t.array.lane);
    i = 2;
    while (i <= N) : (i += 1) {
        try testing.expectEqual(@mod(i, 100) - 50, t.get(Value.int(i)).asInt());
    }
}

test "lane: an all-float run packs into the f64 lane" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    const N: i64 = 48;
    var i: i64 = 2; // hole at 1 forces a rehash so the lane gets selected
    while (i <= N) : (i += 1) try t.set(gpa, Value.int(i), Value.float(@as(f64, @floatFromInt(i)) + 0.5));

    try testing.expectEqual(arr.Lane.f64, t.array.lane);
    try testing.expect(t.array.isLeaf());
    i = 2;
    while (i <= N) : (i += 1) {
        try testing.expectEqual(@as(f64, @floatFromInt(i)) + 0.5, t.get(Value.int(i)).asFloat());
    }
}

test "lane: a heterogeneous/heap-bearing array stays in the value lane" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Build a dense run that rehashes, but mix value types — including a heap
    // string — so no narrow lane can cover it.
    const s = try @import("string.zig").String.create(gpa, "hello");
    defer s.destroy(gpa);

    const N: i64 = 40;
    var i: i64 = 1;
    while (i <= N) : (i += 1) {
        const v: Value = if (i == 5)
            Value.heap(&s.header)
        else if (@mod(i, 2) == 0)
            Value.int(i)
        else
            Value.float(@as(f64, @floatFromInt(i)));
        try t.set(gpa, Value.int(i), v);
    }

    try testing.expectEqual(arr.Lane.value, t.array.lane);
    try testing.expect(!t.array.isLeaf()); // holds a heap pointer → must be marked

    // Every value, including the heap string, reads back intact.
    try testing.expectEqual(@as(i64, 4), t.get(Value.int(4)).asInt());
    try testing.expect(t.get(Value.int(5)).isHeap());
    try testing.expectEqual(@as(f64, 3.0), t.get(Value.int(3)).asFloat());
}

test "lane: a sparse-first table still narrows once a dense int run fills in" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Sparse integer keys trip an early rehash while the array part is still empty,
    // so `optimalLane` returns `.value` (nothing to narrow). That must NOT freeze
    // the lane (the premature-freeze bug), or the dense fill below would be stuck at
    // 16 B/slot for good.
    var s: i64 = 0;
    while (s < 8) : (s += 1) try t.set(gpa, Value.int(1_000_000 + s * 1000), Value.int(1));
    try testing.expectEqual(arr.Lane.value, t.array.lane);
    try testing.expectEqual(@as(usize, 0), t.array.asize); // sparse keys did not grow the array

    // Now fill a dense small-int run (hole at 1 routes through the hash and trips a
    // rehash that finds a homogeneous run → it must still commit to a narrow lane).
    const N: i64 = 80;
    var i: i64 = 2;
    while (i <= N) : (i += 1) try t.set(gpa, Value.int(i), Value.int(@mod(i, 100)));
    try testing.expectEqual(arr.Lane.u8, t.array.lane); // values in [0,255] → byte lane
    try testing.expect(t.array.isLeaf());
    i = 2;
    while (i <= N) : (i += 1) try testing.expectEqual(@mod(i, 100), t.get(Value.int(i)).asInt());
}

test "lane: an out-of-lane int store steps the lane up, never re-narrowing" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Commit to i8 (hole at 1 forces the rehash; all values in [-128,127]).
    const N: i64 = 40;
    var i: i64 = 2;
    while (i <= N) : (i += 1) try t.set(gpa, Value.int(i), Value.int(@mod(i, 100) - 50));
    try testing.expectEqual(arr.Lane.i8, t.array.lane);

    // Store a value past i8 → the lane steps up to i16 (monotonic), staying narrow
    // and leaf — it does not jump to `.value`.
    try t.set(gpa, Value.int(10), Value.int(5000));
    try testing.expectEqual(arr.Lane.i16, t.array.lane);
    try testing.expect(t.array.isLeaf());
    try testing.expectEqual(@as(i64, 5000), t.get(Value.int(10)).asInt());

    // Insert many sparse keys to drive repeated rehashes (they stay in the hash
    // part, never migrating into the array): a monotonic lane must never re-narrow
    // back to i8, even though the only out-of-i8 value sits at a single slot.
    var k: i64 = 1_000_000;
    while (k < 1_000_400) : (k += 1) try t.set(gpa, Value.int(k), Value.int(0));
    try testing.expectEqual(arr.Lane.i16, t.array.lane); // still i16, never re-narrowed to i8
}

test "lane: a rehash drain that OOMs leaves the table consistent (no leak/bad-free)" {
    // Drive a rehash whose drain migrates hash-resident keys into a committed narrow
    // array, with one migrated value out of the lane (so the drain's `setInPlace`
    // widens). `checkAllAllocationFailures` forces each successive allocation to
    // fail, exercising the `len`-rollback path on a mid-drain OOM: the testing
    // allocator then asserts no leak and no invalid free, catching a mishandled
    // truncation. (The shadowing-correctness itself is structural: trimming `len`
    // back to the failed index keeps the not-yet-migrated keys hash-reachable.)
    const Inner = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const t = try Table.create(gpa);
            defer t.destroy(gpa);
            // Commit a narrow i8 array (hole at 1 forces the rehash).
            var i: i64 = 2;
            while (i <= 40) : (i += 1) try t.set(gpa, Value.int(i), Value.int(@mod(i, 100) - 50));
            // Park an out-of-i8 value and a gap-filling dense run in the hash, then
            // a sparse key to trip another rehash that grows the array to cover them.
            try t.set(gpa, Value.int(60), Value.int(9000)); // out of i8 → drain will widen
            i = 41;
            while (i <= 59) : (i += 1) try t.set(gpa, Value.int(i), Value.int(0));
            i = 61;
            while (i <= 64) : (i += 1) try t.set(gpa, Value.int(i), Value.int(0));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Inner.run, .{});
}

test "lane: value identity is preserved across a widening store" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Pack into a narrow int lane first (hole at 1 forces the rehash).
    const N: i64 = 40;
    var i: i64 = 2;
    while (i <= N) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i));
    try testing.expect(t.array.lane != .value);

    // Store a float into the int lane — out of lane → widens to .value in place.
    try t.set(gpa, Value.int(10), Value.float(3.5));
    try testing.expectEqual(arr.Lane.value, t.array.lane);

    // All prior values survive the widening; the new one is present.
    i = 2;
    while (i <= N) : (i += 1) {
        if (i == 10) {
            try testing.expectEqual(@as(f64, 3.5), t.get(Value.int(i)).asFloat());
        } else {
            try testing.expectEqual(i, t.get(Value.int(i)).asInt());
        }
    }
}

// --- grid row forwarding (Phase 3, doc 14) -----------------------------------

test "grid table: getInt mints a row_view; #t is the row count" {
    const gpa = testing.allocator;
    const t = try Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try ArrayPart.initGrid(gpa, 3, 4, .f64); // 3 rows × 4 f64 cells

    // `t[i]` for an in-range row is a transient row_view onto row i-1.
    const r1 = t.getInt(1);
    try testing.expect(r1.isRowView());
    try testing.expectEqual(@as(*GcHeader, &t.header), r1.rowViewParent());
    try testing.expectEqual(@as(u32, 0), r1.rowViewRow());
    try testing.expectEqual(@as(u32, 2), t.getInt(3).rowViewRow());
    // `t.get` (normalising path) reaches the same handle; `2.0` aliases `2`.
    try testing.expect(t.get(Value.float(2)).isRowView());

    // Out-of-range rows are nil (no row, no hash part on a grid).
    try testing.expect(t.getInt(0).isNil());
    try testing.expect(t.getInt(4).isNil());

    // `#t` is exactly the row count — every row is a present row_view.
    try testing.expectEqual(@as(i64, 3), t.length());
}

test "grid row_view: get/set forward into the flat cells; len tracks high-water" {
    const gpa = testing.allocator;
    const t = try Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try ArrayPart.initGrid(gpa, 2, 4, .f64);
    // Row 0 (Lua row 1): cells [10, 11, 12, hole].
    t.array.gridSet(0, 0, Value.float(10));
    t.array.gridSet(0, 1, Value.float(11));
    t.array.gridSet(0, 2, Value.float(12));

    const rv = t.getInt(1);

    // Inner reads forward 1-based → 0-based, holes and past-stride read nil.
    try testing.expectEqual(@as(f64, 10), Table.rowViewGet(rv, Value.int(1)).asFloat());
    try testing.expectEqual(@as(f64, 12), Table.rowViewGet(rv, Value.int(3)).asFloat());
    try testing.expect(Table.rowViewGet(rv, Value.int(4)).isNil()); // hole within stride
    try testing.expect(Table.rowViewGet(rv, Value.int(5)).isNil()); // past stride
    try testing.expect(Table.rowViewGet(rv, Value.boolean(true)).isNil()); // non-int key

    // `#row` is its border high-water (3 non-nil from the left).
    try testing.expectEqual(@as(i64, 3), Table.rowViewLen(rv));

    // A fitting store forwards and raises the border.
    try testing.expect(Table.rowViewSet(rv, Value.int(4), Value.float(13)));
    try testing.expectEqual(@as(f64, 13), Table.rowViewGet(rv, Value.int(4)).asFloat());
    try testing.expectEqual(@as(i64, 4), Table.rowViewLen(rv));

    // A nil store fits every lane, punches a hole, and does NOT shrink the border.
    try testing.expect(Table.rowViewSet(rv, Value.int(2), Value.nil()));
    try testing.expect(Table.rowViewGet(rv, Value.int(2)).isNil());
    try testing.expectEqual(@as(i64, 4), Table.rowViewLen(rv));

    // Stores that can't stay in the grid signal deflation (false), no mutation.
    try testing.expect(!Table.rowViewSet(rv, Value.int(1), Value.int(99))); // int ∉ f64 lane
    try testing.expect(!Table.rowViewSet(rv, Value.int(5), Value.float(1))); // past stride
    try testing.expect(!Table.rowViewSet(rv, Value.boolean(true), Value.float(1))); // non-int key
    try testing.expectEqual(@as(f64, 10), Table.rowViewGet(rv, Value.int(1)).asFloat()); // untouched
}

test "grid row_view: an int-lane grid decodes cells identically to a scalar slot" {
    const gpa = testing.allocator;
    const t = try Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try ArrayPart.initGrid(gpa, 1, 3, .i32);
    t.array.gridSet(0, 0, Value.int(-5));
    t.array.gridSet(0, 1, Value.int(1000));

    const rv = t.getInt(1);
    try testing.expectEqual(@as(i64, -5), Table.rowViewGet(rv, Value.int(1)).asInt());
    try testing.expectEqual(@as(i64, 1000), Table.rowViewGet(rv, Value.int(2)).asInt());
    try testing.expect(Table.rowViewGet(rv, Value.int(3)).isNil());
    try testing.expectEqual(@as(i64, 2), Table.rowViewLen(rv));
}
