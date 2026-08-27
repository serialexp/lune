//! The object heap — allocates heap objects, threads them onto an intrusive
//! list, owns the string interning table, and runs the collector.
//!
//! The collector (Phase 4) is a **stop-the-world, non-moving, tri-colour
//! mark-sweep** — deliberately boring (docs/design/03-gc-memory.md): stable
//! object addresses (so later trace tiers may hold raw pointers), no compaction,
//! no finalizers/weak refs, no concurrency. It builds directly on machinery that
//! has been in place since Phase 1:
//!
//!   * Every object is linked through its `GcHeader.next` into one intrusive
//!     list — the **sweep list** the collector walks (and `deinit` still walks to
//!     free everything).
//!   * Each object carries a `GcColor` (white/gray/black) in its header.
//!     **Mark**: roots are coloured gray and pushed to a worklist; draining the
//!     worklist colours each object black and greys its children. **Sweep**: any
//!     object still white is unreachable and freed; survivors reset to white.
//!   * Strings are **interned** here: identical bytes yield the identical object,
//!     so string equality and table keys are pointer comparisons. Interned
//!     strings are **collectible** — a swept white string is removed from the
//!     intern table (no unbounded string leak).
//!   * `writeBarrier` is a **no-op**: a stop-the-world collector needs no barrier
//!     (those matter only for incremental/generational). The call sites stay so
//!     the generational upgrade is a body to fill in, not a hunt for sites.
//!
//! The heap owns the mark/sweep *mechanism*; the **root set** lives in the VM
//! (`interp.zig` `Vm.collect`), which knows what is live (globals, registers,
//! active frames, open upvalues). Collection runs only at the interpreter's
//! dispatch-loop safepoint, where no half-built object is exposed.
//!
//! Allocation goes through an injected allocator (Z-4); wrap it in
//! `mem.TrackingAllocator` to measure a script's heap footprint.

const std = @import("std");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const GcHeader = object.GcHeader;
const GcColor = object.GcColor;
const String = string.String;
const Table = table.Table;
const Value = value.Value;
const Closure = function.Closure;
const Native = function.Native;
const Upvalue = function.Upvalue;
const Proto = bytecode.Proto;

/// Base of the **reserved id space** for capture-time grid deflation (doc 14,
/// Phase 7). A grid is never serialised; `deflateAllGrids` rebuilds its logical
/// nested rows at capture, but those phantom row Tables exist only for the
/// snapshot and are immediately orphaned on restore (a re-inflating program
/// re-decides from scratch). If they drew ids from the monotonic counter they
/// would (a) bump it and (b) take allocation-order-dependent values — both shift
/// every id minted afterwards, so a snapshot taken mid-execution would not match
/// the same snapshot reached by resume (invariant (d) breaks). Instead they draw
/// ids from this high half of the u32 space by a **canonical** (parent-id-sorted)
/// enumeration: a pure function of logical state, identical across ref/resume,
/// and — since the real counter is asserted never to reach here (2³¹ allocations)
/// — collision-free with every genuine object. Restore ignores ids at/above this
/// base when reconstructing `next_obj_id`, so they never pollute the counter.
pub const reserved_grid_id_base: u32 = 0x8000_0000;

/// The initial collection threshold (and the floor it never drops below): the
/// collector first runs once the live-object count reaches this, and afterwards
/// targets `max(this, live * heap_growth)`. Small enough that even short
/// programs exercise a cycle; the growth factor keeps long programs from
/// collecting on every allocation.
const initial_gc_threshold: usize = 1024;
const heap_growth: usize = 2;

pub const Heap = struct {
    gpa: std.mem.Allocator,
    /// Intrusive singly-linked list of every live object (newest first). This is
    /// the collector's sweep list.
    objects: ?*GcHeader = null,
    /// Number of live objects. Drives the collection trigger.
    object_count: usize = 0,
    /// Monotonic allocation counter — the next `GcHeader.id` to hand out. Never
    /// reset (not even by a collection), so every object allocated in a run has a
    /// unique, stable id, and the id *sequence* is reproducible because allocation
    /// order follows the deterministic execution. This is the identity used for
    /// observable rendering (`io.writeValue`) and, later, keyframe heap graphs —
    /// addresses are deliberately never observed (docs/design/02-determinism.md).
    next_obj_id: u32 = 0,
    /// Interning table (lj_str.c shape): a power-of-2 array of bucket heads,
    /// chained through `String.next_intern` — the unique object for given bytes
    /// is found by stored hash + length + byte compare down one short chain.
    ///
    /// WHY NOT A `std.StringHashMapUnmanaged` (which this replaced, 2026-08-27):
    /// the sweep de-interns every dead string, and under an open-addressing map
    /// each remove leaves a tombstone that only a rehash reclaims — the stdlib's
    /// own doc comment warns that this exact long-lived insert/delete pattern
    /// degrades into "excessive probing". Measured: 82–89% of scalar's and
    /// str_format's TOTAL runtime was `internValue` probe loops (12,896 ns/op in
    /// an isolated churn harness vs 124 without removes). Chains threaded through
    /// the strings themselves have no tombstones BY CONSTRUCTION — the sweep
    /// rebuilds the chains from the survivors — and intern allocates nothing
    /// beyond the string. Empty until the first intern (`Heap.init` stays
    /// infallible); geometry is runtime-private (nothing iterates it, snapshots
    /// serialize strings by bytes+id), so chain order and bucket count are
    /// unobservable and the determinism story rests on the fixed-seed hash only.
    ///
    /// Trust model (explicit decision): no hash-flood hardening. LuaJIT's
    /// SECURITY_STRHASH secondary hash needs a random seed; lune runs trusted
    /// programs, and a recorded-then-replayed seed is the future path if that
    /// ever changes.
    strtab: []?*String = &.{},
    /// Live entries in `strtab` (== interned strings on the object list).
    strtab_count: usize = 0,
    /// Mark-phase worklist: the *gray* set (objects marked but whose children are
    /// not yet scanned). Pre-sized before each cycle so marking cannot allocate.
    /// Capacity is retained across cycles.
    gray: std.ArrayListUnmanaged(*GcHeader) = .empty,
    /// Live-count threshold at which the next collection triggers.
    next_gc: usize = initial_gc_threshold,
    /// Test/diagnostic knob: when set, `shouldCollect` is always true, so the
    /// collector runs at *every* safepoint. Surfaces use-after-free and missing
    /// roots immediately (a wrongly-freed live object breaks the very next op).
    gc_stress: bool = false,

    pub fn init(gpa: std.mem.Allocator) Heap {
        return .{ .gpa = gpa };
    }

    /// Free every object, the worklist, and the interning table. After this the
    /// heap is unusable.
    pub fn deinit(self: *Heap) void {
        var it = self.objects;
        while (it) |h| {
            const next = h.next;
            destroyObject(self.gpa, h);
            it = next;
        }
        self.objects = null;
        self.object_count = 0;
        self.gray.deinit(self.gpa);
        if (self.strtab.len != 0) self.gpa.free(self.strtab);
        self.strtab = &.{};
        self.strtab_count = 0;
    }

    fn link(self: *Heap, h: *GcHeader) void {
        // Stamp a stable, deterministic identity before threading the object in.
        // This is the single allocation chokepoint, so every heap object gets one.
        self.linkRestored(h, self.next_obj_id);
        self.next_obj_id += 1;
    }

    /// Restore-only: thread `h` onto the sweep list with an **explicit** id taken
    /// from a snapshot, instead of the monotonic counter. The keyframe restorer
    /// (`keyframeser.zig`) uses this to reproduce a snapshot's exact id space —
    /// which matters because `table.ValueContext` hashes heap keys by id, so a
    /// restored table only lays out (and re-serializes) identically when its keys
    /// keep their original ids. Never call this during normal execution: it does
    /// **not** touch `next_obj_id`, so the caller must follow a batch of restores
    /// with `adoptNextId(max_id + 1)` to keep future ids collision-free. The
    /// snapshot guarantees distinct ids, so no two restored objects collide.
    pub fn linkRestored(self: *Heap, h: *GcHeader, id: u32) void {
        h.id = id;
        h.next = self.objects;
        self.objects = h;
        self.object_count += 1;
    }

    /// Advance the monotonic id counter to at least `next`, so allocations after a
    /// restore cannot reuse an id that a restored object already holds. Idempotent
    /// and monotonic (never lowers the counter).
    pub fn adoptNextId(self: *Heap, next: u32) void {
        self.next_obj_id = @max(self.next_obj_id, next);
    }

    /// Allocate a fresh empty table and register it with the heap.
    pub fn newTable(self: *Heap) std.mem.Allocator.Error!*Table {
        const t = try Table.create(self.gpa);
        self.link(&t.header);
        return t;
    }

    /// Attempt to flatten a `.value` array-of-rows table into a flat grid
    /// (doc 14, Phase 4). **STRICT homogeneous-numeric** precondition — inflate
    /// only when:
    ///   * the parent's array part is `.value` (its elements are heap refs),
    ///     with an **empty hash part** (the grid owns the whole `1..len` run, so
    ///     a stray hash border would change the observable `#`), and `len >= 1`;
    ///   * every element `1..len` is a heap **table** with no metatable, an
    ///     empty hash part, and a numeric array lane (`i8`/`u8`/`i16`/`i32`/`i64`
    ///     /`f64` — never `.value`/`.boolean`/`.grid`); and
    ///   * every cell across every row unifies to ONE fixed-width lane — all-int
    ///     ⇒ narrowest int lane over the global `[lo, hi]`, all-float ⇒ `f64`.
    /// Mixed int/float, a bool/heap cell, or a nil/scalar row blocks inflation.
    /// Jagged rows are allowed (the grid is sized to the longest row = bounding
    /// box; short rows keep their own `row_len`).
    ///
    /// Returns `true` and swaps the grid in on success (the old `.value` buffer
    /// of row refs is dropped — the orphaned row tables are reclaimed at the next
    /// GC safepoint). On any precondition miss **or** OOM the parent is left
    /// exactly as it was and returns `false` — the caller records a don't-retry
    /// flag (hysteresis), so a non-qualifying table is scanned at most once.
    ///
    /// GC-atomic: runs inside a single opcode, so no collection sees the
    /// half-swapped parent (collection only fires at the dispatch-loop safepoint).
    pub fn inflateToGrid(self: *Heap, parent: *Table) bool {
        const gpa = self.gpa;

        // --- outer shape ---
        if (parent.no_grid) return false; // hysteresis: ruled out, don't re-scan
        if (parent.array.isGrid()) return false; // already a grid
        if (parent.array.lane != .value) return false; // rows are heap refs ⇒ .value
        if (parent.hash.count() != 0) return false; // grid owns the whole 1..len run
        // A grid's outer `a[i]` miss returns nil with no `__index` consultation
        // (the fused read path, doc 14); a metatable'd parent would break that, so a
        // matrix carrying a metatable simply stays nested (rare; deflated on
        // `setmetatable` regardless).
        if (parent.metatable != null) return false;
        // Doc 18 D6: the field is `asize` (slot count incl. the key-0 slot) on a
        // scalar parent, but grid rows are 1-based — so guard BEFORE subtracting
        // (`asize == 0` underflows; `asize == 1` has no 1-based rows), and a
        // populated key 0 cannot be represented in-grid, so it blocks inflation
        // (conservative: costs only the optimization, deflation stays the
        // escape hatch).
        if (parent.array.asize <= 1) return false;
        if (!parent.array.get(0).isNil()) return false;
        const rows = parent.array.asize - 1;

        // --- scan rows: qualify each, unify the cell lane, measure the box ---
        var stride: usize = 0;
        var all_int = true;
        var all_float = true;
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const rv = parent.array.get(r + 1); // outer keys 1..rows (identity slots)
            if (!rv.isHeap()) return false; // nil row or scalar ⇒ block
            const h = rv.asHeap();
            if (h.type != .table) return false; // typed_array/string/... ⇒ block
            const row = Table.fromHeader(h);
            if (row.metatable != null) return false;
            if (row.hash.count() != 0) return false;
            // Doc 18: a row's array part covers keys 0..asize-1; its grid-able
            // cells are keys 1..asize-1 (rowView is 1-based). A populated row
            // key 0 cannot be represented in-grid ⇒ block (same conservative
            // rule as the parent's slot 0 above).
            if (row.array.isGrid()) return false; // nested grid ⇒ block (get() forbids grids)
            if (row.array.asize == 0) continue; // an empty row contributes no cells
            if (!row.array.get(0).isNil()) return false;
            const rl = row.array.asize - 1; // cell count: keys 1..rl
            if (rl == 0) continue; // only the slot-0 hole ⇒ no cells
            switch (row.array.lane) {
                .i8, .u8, .i16, .i32, .i64, .f64 => {}, // numeric leaf ok
                else => return false, // .value/.boolean/.grid ⇒ block
            }
            if (rl > stride) stride = rl;
            var c: usize = 0;
            while (c < rl) : (c += 1) {
                const v = row.array.get(c + 1);
                if (v.isNil()) continue; // jagged hole inside the row
                if (v.isInt()) {
                    all_float = false;
                    const x = v.asInt();
                    if (x < lo) lo = x;
                    if (x > hi) hi = x;
                } else if (v.isFloat()) {
                    all_int = false;
                } else {
                    return false; // bool/heap cell ⇒ block
                }
            }
        }

        if (stride == 0) return false; // no cells anywhere ⇒ nothing to flatten
        if (!all_int and !all_float) return false; // mixed int/float ⇒ block
        const grid_elem: arr.Lane = if (all_int) arr.ArrayPart.intLaneForRange(lo, hi) else .f64;

        // --- build the grid (OOM-atomic: parent untouched until the swap) ---
        var grid = arr.ArrayPart.initGrid(gpa, rows, stride, grid_elem) catch return false;
        r = 0;
        while (r < rows) : (r += 1) {
            const row = Table.fromHeader(parent.array.get(r + 1).asHeap());
            // Cells are keys 1..asize-1 (slot 0 is nil — verified in the scan).
            const rl = if (row.array.asize == 0) 0 else row.array.asize - 1;
            var c: usize = 0;
            while (c < rl) : (c += 1) {
                const v = row.array.get(c + 1);
                if (!v.isNil()) grid.gridSet(r, c, v); // grid_elem fits every cell by construction
            }
        }

        // --- swap (no safepoint between here and return) ---
        parent.array.deinit(gpa); // drop the .value row-ref buffer; row tables orphaned → GC
        parent.array = grid;
        return true;
    }

    /// Tear a flattened grid back into a `.value` array of real heap row Tables
    /// (doc 14, Phase 5) — the inverse of `inflateToGrid`. Each grid row becomes
    /// a freshly allocated `Table` whose array part holds that row's logical
    /// cells `1..gridRowLen(row)` (inner nil holes preserved); the parent's
    /// `.grid` array is replaced by a `.value` array of those row refs. Restores
    /// full table semantics so a row can grow, take a metatable, or hold
    /// heterogeneous values — the price paid whenever a mutation can't be
    /// represented in-grid, or a row escapes to the heap (its real Table ref must
    /// then alias through the parent slot).
    ///
    /// Allocation-heavy (one `Table` per row) but GC-atomic: runs inside one
    /// opcode, so the half-built parent is never exposed to a collection. On OOM
    /// the grid is left intact (the new outer array is discarded) so the original
    /// op can surface the error and the parent stays a valid grid.
    pub fn deflateGrid(self: *Heap, parent: *Table) std.mem.Allocator.Error!void {
        return self.deflateGridImpl(parent, null);
    }

    /// Shared core of runtime and capture-time deflation. `reserved` selects how
    /// the rebuilt row Tables are identified:
    ///   * `null` (runtime, bare-access escape): each row gets a fresh monotonic
    ///     id via `newTable` — a genuine new program object, counter advances.
    ///   * non-null (capture-time, `deflateAllGrids`): each row is stamped with
    ///     `reserved.*` and the cursor advances, drawing from `reserved_grid_id_base`
    ///     without touching the monotonic counter. These rows are phantom (snapshot
    ///     only); see the constant's doc for why this preserves determinism.
    fn deflateGridImpl(self: *Heap, parent: *Table, reserved: ?*u32) std.mem.Allocator.Error!void {
        std.debug.assert(parent.array.isGrid());
        const gpa = self.gpa;
        const rows = parent.array.gridRows();

        // Build the replacement outer `.value` array first; only swap once every
        // row Table is built, so an OOM leaves the grid untouched and retryable.
        var outer = arr.ArrayPart.empty;
        errdefer outer.deinit(gpa);
        // Doc 18 D6: rows are keys 1..rows, but identity append would land the
        // first row at KEY 0 and shift every row down by one. Seed the slot-0
        // hole first so the appends below materialize keys 1..rows.
        try outer.resize(gpa, 1);

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const row = if (reserved) |cur| blk: {
                const t = try Table.create(gpa);
                std.debug.assert(cur.* >= reserved_grid_id_base);
                self.linkRestored(&t.header, cur.*);
                cur.* += 1;
                break :blk t;
            } else try self.newTable(); // linked + id-stamped
            const rl = parent.array.gridRowLen(r);
            var c: usize = 0;
            while (c < rl) : (c += 1) {
                const v = parent.array.gridGet(r, c);
                // Skip nil holes: leaving key c+1 unset reproduces the hole in the
                // rebuilt row exactly (`get` returns nil for an absent key).
                if (!v.isNil()) row.set(gpa, Value.int(@intCast(c + 1)), v) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.TypeError => unreachable, // a positive int key is never nil/NaN
                };
            }
            try outer.append(gpa, Value.heap(&row.header));
        }

        parent.array.deinit(gpa);
        parent.array = outer;
        // Hysteresis (doc 14, Phase 4b): a table that just deflated is not
        // re-inflated by a following fused store — that would thrash. It stays
        // nested for the rest of its life (a fresh restore re-decides from false).
        parent.no_grid = true;
    }

    /// Deflate every live grid table back to real nested row Tables (doc 14,
    /// Phase 7). A grid is an in-memory-only optimisation and is **never**
    /// serialised — keyframe capture persists the *logical* nested form, so a
    /// restore that lands on a different grid/nested state is observably
    /// identical. Called once at the top of `keyframeser.encodeSnapshot`.
    ///
    /// Phantom-row ids must be a pure function of *logical* state, not allocation
    /// history, or a snapshot taken mid-execution would not match the same snapshot
    /// reached by resume (the phantom rows would land on different ids and shift
    /// everything minted afterwards). So we deflate grids in a **canonical order**
    /// — sorted by the parent table's stable id — assigning each row a sequential
    /// id from `reserved_grid_id_base`. The sweep-list order is allocation-order
    /// and diverges across resume, hence the explicit sort. Restore ignores ids in
    /// the reserved half when reconstructing the counter, so these never pollute it.
    pub fn deflateAllGrids(self: *Heap) std.mem.Allocator.Error!void {
        // The real counter must never have entered the reserved half (2³¹ live
        // objects is unreachable); if it had, a phantom id could alias a genuine
        // object. Cheap guard against a future that breaks the invariant.
        std.debug.assert(self.next_obj_id <= reserved_grid_id_base);

        // Collect every grid parent, then sort by id for a deterministic order.
        var grids: std.ArrayListUnmanaged(*Table) = .empty;
        defer grids.deinit(self.gpa);
        var it = self.objects;
        while (it) |h| : (it = h.next) {
            if (h.type != .table) continue;
            const t = Table.fromHeader(h);
            if (t.array.isGrid()) try grids.append(self.gpa, t);
        }
        std.mem.sort(*Table, grids.items, {}, struct {
            fn lt(_: void, a: *Table, b: *Table) bool {
                return a.header.id < b.header.id;
            }
        }.lt);

        var cursor: u32 = reserved_grid_id_base;
        for (grids.items) |t| try self.deflateGridImpl(t, &cursor);
    }

    /// Minimum bucket count. Power of two; also the lazy first allocation, so a
    /// program that interns at all pays for 512 slots (4 KiB) once.
    const strtab_min_size: usize = 512;

    /// Look up `content` in the intern chains: the unique live `String`, or null.
    /// A hit costs one hash + on average ≤1 chain hop (grow keeps load ≤ ~100%).
    fn strtabLookup(self: *const Heap, content: []const u8, hash: u64) ?*String {
        if (self.strtab.len == 0) return null;
        var s = self.strtab[hash & (self.strtab.len - 1)];
        while (s) |cur| : (s = cur.next_intern) {
            if (cur.hash == hash and cur.len == content.len and std.mem.eql(u8, cur.bytes(), content))
                return cur;
        }
        return null;
    }

    /// Push `s` at its bucket's head. Infallible; the caller has ensured capacity.
    fn strtabInsert(self: *Heap, s: *String) void {
        std.debug.assert(self.strtab.len != 0);
        const idx = s.hash & (self.strtab.len - 1);
        s.next_intern = self.strtab[idx];
        self.strtab[idx] = s;
        self.strtab_count += 1;
    }

    /// Make room for one more entry: lazy-allocate the minimum table, or grow ×2
    /// when the load would pass 100% (LuaJIT's policy — average chain length
    /// stays ~1). Growing rebuilds the chains by stored hash. The ONLY fallible
    /// step of an intern miss besides the string allocation itself; on error
    /// nothing has been mutated.
    fn strtabEnsureCapacity(self: *Heap) std.mem.Allocator.Error!void {
        if (self.strtab.len == 0) {
            const nt = try self.gpa.alloc(?*String, strtab_min_size);
            @memset(nt, null);
            self.strtab = nt;
            return;
        }
        if (self.strtab_count + 1 <= self.strtab.len) return;
        // Cap: past 2^31 buckets just tolerate higher load (as LuaJIT does at
        // LJ_MAX_STRTAB) rather than overflowing the shift.
        if (self.strtab.len >= (@as(usize, 1) << 31)) return;
        try self.strtabRebuild(self.strtab.len * 2);
    }

    /// Allocate a `new_len`-bucket table, re-chain every live string into it by
    /// stored hash, and free the old table. `new_len` must be a power of two.
    /// Transactional: on allocation failure the old table is untouched.
    fn strtabRebuild(self: *Heap, new_len: usize) std.mem.Allocator.Error!void {
        const nt = try self.gpa.alloc(?*String, new_len);
        @memset(nt, null);
        const mask = new_len - 1;
        for (self.strtab) |head| {
            var s = head;
            while (s) |cur| {
                const next = cur.next_intern; // save before overwriting the link
                const idx = cur.hash & mask;
                cur.next_intern = nt[idx];
                nt[idx] = cur;
                s = next;
            }
        }
        self.gpa.free(self.strtab);
        self.strtab = nt;
    }

    /// Intern `content`: return the existing object for these bytes, or allocate,
    /// register, and return a new one. The returned string's bytes are a copy —
    /// `content` need not outlive the call.
    ///
    /// The miss path is transactional (codex review, 2026-08-27): every fallible
    /// step — the string allocation and any table growth — happens before any
    /// heap mutation, so an OOM can never leave a half-interned string or a
    /// consumed object id behind.
    pub fn intern(self: *Heap, content: []const u8) std.mem.Allocator.Error!*String {
        const h = std.hash.Wyhash.hash(0, content);
        if (self.strtabLookup(content, h)) |existing| return existing;
        const s = try String.createWithHash(self.gpa, content, h);
        errdefer s.destroy(self.gpa);
        try self.strtabEnsureCapacity();
        // Infallible from here.
        self.strtabInsert(s);
        self.link(&s.header);
        return s;
    }

    /// The interned `String` for `content`, or null if these bytes are not
    /// currently interned. Read-only probe (tests, diagnostics) — program code
    /// wants `intern`, which creates on miss.
    pub fn internedLookup(self: *const Heap, content: []const u8) ?*String {
        return self.strtabLookup(content, std.hash.Wyhash.hash(0, content));
    }

    /// Restore-only (keyframeser pass 1a): register an already-created `String`
    /// in the intern chains, REJECTING duplicate bytes — a valid snapshot interns
    /// one object per byte-sequence, and silently keeping two would break the
    /// interning invariant (pointer equality). Does NOT GC-link or stamp an id;
    /// the restorer does that with the snapshot's own id. Failure-atomic: on any
    /// error the table is unchanged and `s` is untouched (the caller owns it).
    pub fn internRestoredUnique(self: *Heap, s: *String) error{ OutOfMemory, DuplicateInternedString }!void {
        if (self.strtabLookup(s.bytes(), s.hash) != null) return error.DuplicateInternedString;
        try self.strtabEnsureCapacity();
        self.strtabInsert(s);
    }

    /// Convenience: intern `content` and wrap it as a `Value`.
    pub fn internValue(self: *Heap, content: []const u8) std.mem.Allocator.Error!Value {
        const s = try self.intern(content);
        return Value.heap(&s.header);
    }

    /// Allocate a closure over `proto` with `n_upvalues` (uninitialised) cells,
    /// and register it with the heap. The caller fills `closure.upvalues[i]`.
    pub fn newClosure(self: *Heap, proto: *const Proto, n_upvalues: usize) std.mem.Allocator.Error!*Closure {
        const cl = try Closure.create(self.gpa, proto, n_upvalues);
        self.link(&cl.header);
        return cl;
    }

    /// Allocate a native function object and register it with the heap.
    pub fn newNative(self: *Heap, func: function.NativeFn, name: []const u8) std.mem.Allocator.Error!*Native {
        const n = try Native.create(self.gpa, func, name);
        self.link(&n.header);
        return n;
    }

    /// Allocate an *open* upvalue over live stack slot `index`, and register it
    /// with the heap. Closing is the interpreter's job.
    pub fn newUpvalue(self: *Heap, index: usize) std.mem.Allocator.Error!*Upvalue {
        const u = try Upvalue.createOpen(self.gpa, index);
        self.link(&u.header);
        return u;
    }

    /// Write barrier — invoked whenever a heap `Value` is stored into a heap
    /// `container`. A deliberate **no-op**: a stop-the-world mark-sweep needs no
    /// barrier (the mark phase sees the final heap state). The call sites remain
    /// so a future *generational / incremental* collector fills in the body
    /// (remember-set insert, card mark, or grey-stack push) without any call site
    /// moving. See docs/design/03-gc-memory.md §Barriers.
    pub inline fn writeBarrier(self: *Heap, container: *GcHeader, stored: Value) void {
        _ = self;
        _ = container;
        _ = stored;
    }

    // -----------------------------------------------------------------------
    // Collector — stop-the-world tri-colour mark-sweep.
    //
    // The VM drives a cycle: `beginCollect()`, then `markValue`/`markHeader` on
    // every root, then `traceAll()`, then `sweep()`. The heap owns the mechanism;
    // the VM owns the root set (it alone knows what is live). Splitting it this
    // way keeps `gc.zig` free of any interpreter dependency.
    // -----------------------------------------------------------------------

    /// Whether a collection should run at the next safepoint.
    pub fn shouldCollect(self: *const Heap) bool {
        return self.gc_stress or self.object_count >= self.next_gc;
    }

    /// Begin a cycle: reserve worklist capacity for the worst case (every object
    /// gray at once). This is the *only* fallible step of a collection — once it
    /// succeeds, marking and sweeping cannot allocate. On OOM the caller skips
    /// the cycle; nothing has been coloured, so the heap is untouched and safe.
    pub fn beginCollect(self: *Heap) std.mem.Allocator.Error!void {
        try self.gray.ensureTotalCapacity(self.gpa, self.object_count);
    }

    /// Mark one object reachable: if white, colour it gray and enqueue it. Each
    /// object is enqueued at most once (the white check), so the worklist never
    /// exceeds the capacity reserved in `beginCollect` — hence `appendAssumeCapacity`.
    pub fn markHeader(self: *Heap, h: *GcHeader) void {
        if (h.color != .white) return;
        h.color = .gray;
        self.gray.appendAssumeCapacity(h);
    }

    /// Mark a `Value` if it references a heap object (scalars are no-ops).
    pub fn markValue(self: *Heap, v: Value) void {
        if (v.isHeap()) {
            self.markHeader(v.asHeap());
        } else if (v.isRowView()) {
            // A transient grid row handle (doc 14) keeps its parent grid table
            // alive while it is live in a register during a collection. The row
            // is an index into the parent's buffer, so marking the parent covers
            // the row's storage; there is no separate row object. Exercised once
            // grids are enabled (Phase 6).
            self.markHeader(v.rowViewParent());
        }
    }

    /// Drain the gray worklist: blacken each object and grey its children, until
    /// nothing remains reachable-but-unscanned.
    pub fn traceAll(self: *Heap) void {
        while (self.gray.pop()) |h| {
            h.color = .black;
            self.blacken(h);
        }
    }

    /// Scan one object's outgoing references, marking each. Type-dispatched on
    /// the header so the collector knows where the child pointers live.
    fn blacken(self: *Heap, h: *GcHeader) void {
        switch (h.type) {
            // Leaves: no heap children. A `Native`'s name is a borrowed/static
            // slice, not a heap String.
            .string, .native => {},
            .table => {
                const t = Table.fromHeader(h);
                // Narrow lanes (bool/int/float) hold no heap pointers — the array
                // part is a GC leaf and is skipped entirely. Only the `.value`
                // lane can carry heap references. The hash part is always marked.
                if (!t.array.isLeaf()) {
                    var i: usize = 0;
                    while (i < t.array.asize) : (i += 1) self.markValue(t.array.get(i));
                }
                var it = t.hash.iterator();
                while (it.next()) |entry| {
                    self.markValue(entry.key_ptr.*);
                    self.markValue(entry.value_ptr.*);
                }
                // The metatable (chunk 2a) is a heap edge: keep it alive while
                // any table references it.
                if (t.metatable) |m| self.markHeader(&m.header);
            },
            .upvalue => {
                // Closed ⇒ the value is owned by the cell, so mark it here. Open ⇒
                // the value lives in a live stack slot, which the VM root scan
                // (`forEachRootHeader`) already covers — and `gc.zig` has no stack
                // to resolve the index anyway. So mark only the closed case.
                const u = Upvalue.fromHeader(h);
                switch (u.loc) {
                    .open => {},
                    .closed => |v| self.markValue(v),
                }
            },
            .function => {
                const cl = Closure.fromHeader(h);
                for (cl.upvalues) |uv| self.markHeader(&uv.header);
                self.markProtoConstants(cl.proto);
            },
            // typed_array (Phase 9b) and host (embedding) are not heap-managed
            // here yet; nothing to scan.
            else => {},
        }
    }

    /// Mark every heap object held in a prototype's constant pool, recursing
    /// through its nested prototypes. Protos are arena-owned (not GC objects), so
    /// they are not coloured — but their string constants *are* heap objects that
    /// would otherwise be unreachable until loaded into a register. Walking the
    /// proto tree from a live closure keeps every constant in the whole program
    /// alive (the proto tree is finite and acyclic, so the recursion terminates).
    fn markProtoConstants(self: *Heap, proto: *const Proto) void {
        for (proto.constants) |c| self.markValue(c);
        for (proto.protos) |child| self.markProtoConstants(child);
    }

    /// Sweep: free every white (unreachable, unpinned) object and reset survivors
    /// to white for the next cycle. Updates `object_count` and the next trigger
    /// from the surviving population.
    ///
    /// The intern chains are REBUILT from the survivors during this same walk
    /// (codex review, 2026-08-27) rather than unlinking each dead string from its
    /// bucket: per-dead unlinking walks the chain to find a predecessor, which in
    /// a bucket with k interleaved live/dead strings is O(k²) across the sweep —
    /// the rebuild is O(buckets + objects), on top of a walk we are already
    /// doing. Mid-walk the chains are transiently inconsistent (cleared, then
    /// refilled survivor by survivor); that is fine because a sweep is atomic
    /// with respect to interning — nothing can call `intern` until it returns.
    /// Infallible by contract (`beginCollect` is a collection's only fallible
    /// step): the rebuild reuses the existing bucket array, and the optional
    /// shrink below treats OOM as "keep the current table".
    pub fn sweep(self: *Heap) void {
        @memset(self.strtab, null);
        var live_str: usize = 0;
        var slot: *?*GcHeader = &self.objects;
        var live: usize = 0;
        while (slot.*) |h| {
            if (h.color == .white and !h.flags.pinned) {
                // Unreachable: unlink (leaving `slot` pointing at the successor)
                // and free. Dead strings simply never re-enter the chains.
                slot.* = h.next;
                destroyObject(self.gpa, h);
            } else {
                // Survivor (reachable, or pinned): reset to white and advance.
                h.color = .white;
                live += 1;
                if (h.type == .string) {
                    self.strtabInsert(String.fromHeader(h));
                    live_str += 1;
                }
                slot = &h.next;
            }
        }
        // `strtabInsert` recounted the survivors; overwrite rather than trusting
        // the pre-sweep figure.
        self.strtab_count = live_str;
        self.object_count = live;
        self.next_gc = @max(initial_gc_threshold, live * heap_growth);
        self.strtabMaybeShrink();
    }

    /// Optional post-sweep maintenance: halve the bucket array when live entries
    /// fall below a quarter of it (hysteresis against grow's 100%-load trigger:
    /// a shrink needs the population to halve twice, a re-grow needs it to double
    /// twice — sawtooth populations near a boundary do not thrash). One halving
    /// per sweep. OOM keeps the current (larger) table — geometry is runtime-
    /// private, so this costs memory, never correctness or determinism of output.
    fn strtabMaybeShrink(self: *Heap) void {
        if (self.strtab.len <= strtab_min_size) return;
        if (self.strtab_count >= self.strtab.len / 4) return;
        const new_len = @max(strtab_min_size, self.strtab.len / 2);
        // strtabRebuild re-chains without touching strtab_count, which the sweep
        // walk above has just recounted.
        self.strtabRebuild(new_len) catch return;
    }
};

/// Free one object according to its concrete type.
fn destroyObject(gpa: std.mem.Allocator, h: *GcHeader) void {
    switch (h.type) {
        .string => String.fromHeader(h).destroy(gpa),
        .table => Table.fromHeader(h).destroy(gpa),
        .function => Closure.fromHeader(h).destroy(gpa),
        .native => Native.fromHeader(h).destroy(gpa),
        .upvalue => Upvalue.fromHeader(h).destroy(gpa),
        // typed_array (Phase 9b) and host (embedding) are not heap-allocated
        // here yet.
        else => @panic("gc: unknown object type during sweep"),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "interning returns the same object for identical bytes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.intern("hello");
    const b = try heap.intern("hello");
    const c = try heap.intern("world");

    try testing.expectEqual(a, b); // same pointer — interned
    try testing.expect(a != c);
    try testing.expectEqualStrings("hello", a.bytes());
    // Two interns of "hello" allocated only one object; plus "world".
    try testing.expectEqual(@as(usize, 2), heap.object_count);
}

test "interned string equality is pointer identity through Value.eql" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const x = try heap.internValue("abc");
    const y = try heap.internValue("abc");
    const z = try heap.internValue("abd");
    try testing.expect(x.eql(y));
    try testing.expect(!x.eql(z));
}

test "heap frees tables and strings without leaking" {
    // Runs under testing.allocator, which fails the test on any leak.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const t = try heap.newTable();
    try t.set(heap.gpa, try heap.internValue("k"), Value.int(1));
    try t.set(heap.gpa, Value.int(1), try heap.internValue("v"));

    try testing.expectEqual(@as(i64, 1), t.get(try heap.internValue("k")).asInt());
    try testing.expectEqualStrings("v", string.String.fromHeader(t.get(Value.int(1)).asHeap()).bytes());
}

// ---------------------------------------------------------------------------
// Collector tests — drive the mark/sweep primitives directly with hand-supplied
// roots (the VM's real root set is exercised by the stress tests in interp.zig).
// ---------------------------------------------------------------------------

/// Run a full cycle rooting exactly the given headers.
fn collectWithRoots(heap: *Heap, roots: []const *GcHeader) !void {
    try heap.beginCollect();
    for (roots) |r| heap.markHeader(r);
    heap.traceAll();
    heap.sweep();
}

test "sweep frees an unreachable object and de-interns it" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const keep = try heap.intern("keep");
    _ = try heap.intern("drop");
    try testing.expectEqual(@as(usize, 2), heap.object_count);

    try collectWithRoots(&heap, &.{&keep.header});

    // "drop" was unreachable → freed; "keep" survived and is reset to white.
    try testing.expectEqual(@as(usize, 1), heap.object_count);
    try testing.expectEqual(GcColor.white, keep.header.color);
    // "keep" is still interned (same object); "drop" was de-interned, so a fresh
    // intern allocates a new object and the count climbs back to 2.
    try testing.expectEqual(keep, try heap.intern("keep"));
    _ = try heap.intern("drop");
    try testing.expectEqual(@as(usize, 2), heap.object_count);
}

test "marking a table keeps its keys and values alive" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const t = try heap.newTable();
    try t.set(heap.gpa, try heap.internValue("k"), try heap.internValue("v"));
    // Objects: the table, "k", "v".
    try testing.expectEqual(@as(usize, 3), heap.object_count);

    // An *unrooted* extra string that should not survive.
    _ = try heap.intern("garbage");
    try testing.expectEqual(@as(usize, 4), heap.object_count);

    try collectWithRoots(&heap, &.{&t.header});

    // Table + its reachable key/value survive; the loose string is gone.
    try testing.expectEqual(@as(usize, 3), heap.object_count);
    try testing.expectEqualStrings("v", string.String.fromHeader(t.get(try heap.internValue("k")).asHeap()).bytes());
}

test "a narrow-lane (leaf) array survives GC with its values intact" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const t = try heap.newTable();
    // nsieve's bool pattern (hole at 1) → packs into the boolean lane, a GC leaf.
    const K: i64 = 80;
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(heap.gpa, Value.int(i), Value.boolean(true));
    try testing.expect(t.array.isLeaf()); // blacken must skip the array entirely

    // A loose unrooted string that should not survive.
    _ = try heap.intern("garbage");

    try collectWithRoots(&heap, &.{&t.header});

    // The table survived; the narrow-lane values are all intact post-sweep.
    i = 2;
    while (i <= K) : (i += 1) {
        try testing.expectEqual(true, t.get(Value.int(i)).asBool());
    }
    try testing.expect(t.get(Value.int(1)).isNil());
    try testing.expect(t.array.isLeaf()); // lane unchanged by collection
}

test "a value-lane array still marks its nested-table children" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const outer = try heap.newTable();
    const inner = try heap.newTable();
    try inner.set(heap.gpa, try heap.internValue("k"), try heap.internValue("v"));

    // Put the inner table in the outer's array part. A heap value keeps the array
    // in the `.value` lane (not a leaf), so blacken must walk it.
    try outer.set(heap.gpa, Value.int(1), Value.heap(&inner.header));
    try testing.expect(!outer.array.isLeaf());

    // Objects: outer, inner, "k", "v" = 4. Plus a loose string that must die.
    _ = try heap.intern("garbage");

    try collectWithRoots(&heap, &.{&outer.header});

    // outer + inner + "k" + "v" survive (the loose string is swept).
    try testing.expectEqual(@as(usize, 4), heap.object_count);
    const got = outer.get(Value.int(1));
    try testing.expect(got.isHeap());
    try testing.expectEqualStrings(
        "v",
        string.String.fromHeader(inner.get(try heap.internValue("k")).asHeap()).bytes(),
    );
}

test "collecting with no roots frees everything" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    _ = try heap.newTable();
    _ = try heap.intern("a");
    _ = try heap.intern("b");
    try testing.expect(heap.object_count > 0);

    try collectWithRoots(&heap, &.{});
    try testing.expectEqual(@as(usize, 0), heap.object_count);
    try testing.expectEqual(@as(?*GcHeader, null), heap.objects);
}

/// Test-only chain integrity: every chained string sits in the bucket its hash
/// names, the chain population equals `strtab_count`, and every member is on
/// the GC object list. A dangling or misplaced link fails loudly here instead
/// of as a later use-after-free.
fn strtabCheckIntegrity(heap: *Heap) !void {
    var chained: usize = 0;
    for (heap.strtab, 0..) |head, idx| {
        var s = head;
        while (s) |cur| : (s = cur.next_intern) {
            try testing.expectEqual(idx, cur.hash & (heap.strtab.len - 1));
            chained += 1;
            var on_list = false;
            var it = heap.objects;
            while (it) |h| : (it = h.next) {
                if (h == &cur.header) {
                    on_list = true;
                    break;
                }
            }
            try testing.expect(on_list);
        }
    }
    try testing.expectEqual(heap.strtab_count, chained);
}

test "strtab: same-bucket collisions — dedupe holds, sweep keeps only the live interleaving" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    _ = try heap.intern("prime the table"); // allocate the min-size strtab

    // Find four distinct strings that share one bucket at the minimum size.
    const mask = heap.strtab.len - 1;
    var found: [4]*String = undefined;
    var nfound: usize = 0;
    var i: usize = 0;
    const want_bucket = std.hash.Wyhash.hash(0, "c0") & mask;
    var namebuf: [16]u8 = undefined;
    while (nfound < 4) : (i += 1) {
        const name = std.fmt.bufPrint(&namebuf, "c{d}", .{i}) catch unreachable;
        if (std.hash.Wyhash.hash(0, name) & mask != want_bucket) continue;
        found[nfound] = try heap.intern(name);
        nfound += 1;
    }
    // All four are distinct objects in ONE chain, and re-interning dedupes.
    try testing.expectEqual(found[0], try heap.intern(found[0].bytes()));
    try testing.expectEqual(found[3], try heap.intern(found[3].bytes()));
    try strtabCheckIntegrity(&heap);

    // Kill 1 and 3, keep 0 and 2 — the interleaving the per-dead-unlink design
    // handled worst. The rebuild sweep must keep exactly the survivors.
    try collectWithRoots(&heap, &.{ &found[0].header, &found[2].header });
    try testing.expectEqual(@as(?*String, found[0]), heap.internedLookup(found[0].bytes()));
    try testing.expectEqual(@as(?*String, found[2]), heap.internedLookup(found[2].bytes()));
    try testing.expectEqual(@as(usize, 2), heap.strtab_count);
    try strtabCheckIntegrity(&heap);
}

test "strtab: grows past the minimum and every string stays reachable at the same pointer" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var ptrs: [1500]*String = undefined;
    var namebuf: [16]u8 = undefined;
    for (0..ptrs.len) |i| {
        const name = std.fmt.bufPrint(&namebuf, "g{d}", .{i}) catch unreachable;
        ptrs[i] = try heap.intern(name);
    }
    try testing.expect(heap.strtab.len > strtab_min_for_test); // grew (512 → 1024 → 2048)
    for (0..ptrs.len) |i| {
        const name = std.fmt.bufPrint(&namebuf, "g{d}", .{i}) catch unreachable;
        try testing.expectEqual(@as(?*String, ptrs[i]), heap.internedLookup(name));
    }
    try strtabCheckIntegrity(&heap);
}

const strtab_min_for_test = Heap.strtab_min_size;

test "strtab: mass death shrinks the table back to minimum without losing survivors" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var namebuf: [16]u8 = undefined;
    var keep: [10]*String = undefined;
    for (0..3000) |i| {
        const name = std.fmt.bufPrint(&namebuf, "s{d}", .{i}) catch unreachable;
        const s = try heap.intern(name);
        if (i < keep.len) keep[i] = s;
    }
    try testing.expect(heap.strtab.len >= 4096);

    // Each sweep halves at most once (hysteresis): 4096 → 2048 → 1024 → 512.
    var roots: [10]*GcHeader = undefined;
    for (keep, 0..) |s, i| roots[i] = &s.header;
    for (0..4) |_| try collectWithRoots(&heap, &roots);
    try testing.expectEqual(strtab_min_for_test, heap.strtab.len);
    try testing.expectEqual(keep.len, heap.strtab_count);
    for (keep) |s| try testing.expectEqual(@as(?*String, s), heap.internedLookup(s.bytes()));
    try strtabCheckIntegrity(&heap);

    // A dead string's bytes re-intern as a NEW object (fresh id above the old range).
    const reborn = try heap.intern("s2999");
    try testing.expect(reborn.header.id >= 3000);
}

test "strtab: interning distinguishes embedded-NUL strings and handles the empty string" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.intern("a\x00b");
    const b = try heap.intern("a\x00c");
    try testing.expect(a != b);
    try testing.expectEqual(a, try heap.intern("a\x00b"));
    const empty = try heap.intern("");
    try testing.expectEqual(empty, try heap.intern(""));
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "strtab: churn — unique interns across repeated stress sweeps stay correct" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const pinned = try heap.intern("pinned survivor");
    var namebuf: [24]u8 = undefined;
    for (0..2000) |i| {
        const name = std.fmt.bufPrint(&namebuf, "churn{d}", .{i}) catch unreachable;
        _ = try heap.intern(name);
        if (i % 100 == 99) {
            try collectWithRoots(&heap, &.{&pinned.header});
            try testing.expectEqual(@as(?*String, pinned), heap.internedLookup("pinned survivor"));
        }
    }
    try collectWithRoots(&heap, &.{&pinned.header});
    try testing.expectEqual(@as(usize, 1), heap.strtab_count);
    try strtabCheckIntegrity(&heap);
}

test "a second cycle is stable (survivors reset to white)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const t = try heap.newTable();
    try t.set(heap.gpa, Value.int(1), try heap.internValue("one"));

    try collectWithRoots(&heap, &.{&t.header});
    const after_first = heap.object_count;
    // Re-running with the same root must not free survivors nor trip on a
    // leftover non-white colour.
    try collectWithRoots(&heap, &.{&t.header});
    try testing.expectEqual(after_first, heap.object_count);
    try testing.expectEqualStrings("one", string.String.fromHeader(t.get(Value.int(1)).asHeap()).bytes());
}

test "shouldCollect honours the stress knob and the threshold" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    try testing.expect(!heap.shouldCollect()); // empty, below threshold
    heap.gc_stress = true;
    try testing.expect(heap.shouldCollect());
    heap.gc_stress = false;
    heap.next_gc = 1;
    _ = try heap.intern("x");
    try testing.expect(heap.shouldCollect()); // count (1) >= next_gc (1)
}

test "inflateToGrid: strict homogeneous int rows flatten; round-trip via deflate is logically identical" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // outer = { {1,2,3}, {4,5}, {6,7,8} }  (jagged, all ints)
    const outer = try heap.newTable();
    const want = [_][]const i64{ &.{ 1, 2, 3 }, &.{ 4, 5 }, &.{ 6, 7, 8 } };
    for (want, 0..) |rowvals, ri| {
        const row = try heap.newTable();
        for (rowvals, 0..) |x, ci| try row.set(heap.gpa, Value.int(@intCast(ci + 1)), Value.int(x));
        try outer.set(heap.gpa, Value.int(@intCast(ri + 1)), Value.heap(&row.header));
    }
    try testing.expect(!outer.array.isGrid());

    try testing.expect(heap.inflateToGrid(outer));
    try testing.expect(outer.array.isGrid());
    try testing.expectEqual(@as(usize, 3), outer.array.gridRows());
    try testing.expectEqual(@as(usize, 3), outer.array.stride); // bounding box = longest row
    // Row lengths track the jagged shape.
    try testing.expectEqual(@as(usize, 3), outer.array.gridRowLen(0));
    try testing.expectEqual(@as(usize, 2), outer.array.gridRowLen(1));
    try testing.expectEqual(@as(usize, 3), outer.array.gridRowLen(2));
    // Cells decode identically.
    try testing.expectEqual(@as(i64, 5), outer.array.gridGet(1, 1).asInt());
    try testing.expectEqual(@as(i64, 8), outer.array.gridGet(2, 2).asInt());

    // Deflate restores the nested-table shape with logically identical values.
    try heap.deflateGrid(outer);
    try testing.expect(!outer.array.isGrid());
    for (want, 0..) |rowvals, ri| {
        const rt = Table.fromHeader(outer.get(Value.int(@intCast(ri + 1))).asHeap());
        try testing.expectEqual(@as(i64, @intCast(rowvals.len)), rt.length());
        for (rowvals, 0..) |x, ci| {
            try testing.expectEqual(x, rt.get(Value.int(@intCast(ci + 1))).asInt());
        }
    }
}

test "inflateToGrid: a populated key 0 (outer or row) blocks; empty/asize<=1 outers decline without underflow" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Empty outer: asize == 0 must decline cleanly (doc 18 D6 — the `asize - 1`
    // underflow guard; reachable via any fused store on a non-grid table).
    {
        const outer = try heap.newTable();
        try testing.expect(!heap.inflateToGrid(outer));
    }
    // asize == 1 (only a slot-0 hole after t[1]-seed + delete): no 1-based rows.
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        try outer.array.resize(heap.gpa, 1); // shrink to just the slot-0 hole
        try testing.expect(!heap.inflateToGrid(outer));
    }
    // Outer key 0 populated ⇒ block (a grid cannot represent outer key 0).
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        const row0 = try heap.newTable();
        try row0.set(heap.gpa, Value.int(1), Value.int(9));
        try outer.set(heap.gpa, Value.int(0), Value.heap(&row0.header));
        try testing.expect(!heap.inflateToGrid(outer));
        try testing.expect(!outer.array.isGrid());
    }
    // Row key 0 populated ⇒ block (rowView is 1-based; the cell would be lost).
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(0), Value.int(5));
        try row.set(heap.gpa, Value.int(1), Value.int(6));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        try testing.expect(!heap.inflateToGrid(outer));
    }
}

test "deflateGrid: outer keys land at 1..rows with a slot-0 hole (no down-shift)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const outer = try heap.newTable();
    inline for (1..4) |ri| {
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(@intCast(ri * 100)));
        try outer.set(heap.gpa, Value.int(@intCast(ri)), Value.heap(&row.header));
    }
    try testing.expect(heap.inflateToGrid(outer));
    try heap.deflateGrid(outer);
    try testing.expect(!outer.array.isGrid());
    // Doc 18 D6: identity append would have landed row 1 at KEY 0; the seeded
    // slot-0 hole keeps every row at its original 1-based key.
    try testing.expectEqual(@as(usize, 4), outer.array.asize); // hole + 3 rows
    try testing.expect(outer.array.get(0).isNil());
    try testing.expect(outer.get(Value.int(0)).isNil());
    inline for (1..4) |ri| {
        const rt = Table.fromHeader(outer.get(Value.int(@intCast(ri))).asHeap());
        try testing.expectEqual(@as(i64, @intCast(ri * 100)), rt.get(Value.int(1)).asInt());
    }
    try testing.expectEqual(@as(i64, 3), outer.length());
}

test "GC: a heap ref in slot 0 is marked (the 0-based mark walk covers it)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const outer = try heap.newTable();
    const child = try heap.newTable();
    try child.set(heap.gpa, Value.int(1), Value.int(77));
    try outer.set(heap.gpa, Value.int(0), Value.heap(&child.header)); // key 0 = slot 0
    try collectWithRoots(&heap, &.{&outer.header});
    // The child must have survived through the slot-0 edge.
    try testing.expectEqual(@as(i64, 77), Table.fromHeader(outer.get(Value.int(0)).asHeap()).get(Value.int(1)).asInt());
}

test "inflateToGrid: all-float rows unify to f64" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const outer = try heap.newTable();
    inline for (0..2) |ri| {
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.float(@floatFromInt(ri)));
        try row.set(heap.gpa, Value.int(2), Value.float(1.5));
        try outer.set(heap.gpa, Value.int(@intCast(ri + 1)), Value.heap(&row.header));
    }
    try testing.expect(heap.inflateToGrid(outer));
    try testing.expectEqual(arr.Lane.f64, outer.array.grid_elem);
    try testing.expectEqual(@as(f64, 1.5), outer.array.gridGet(0, 1).asFloat());
}

test "inflateToGrid: blockers — mixed int/float, hash on a row, metatable, non-table row, outer hash" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // mixed int/float across cells ⇒ block
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try row.set(heap.gpa, Value.int(2), Value.float(2.5));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        try testing.expect(!heap.inflateToGrid(outer));
        try testing.expect(!outer.array.isGrid());
    }
    // a row with a hash part ⇒ block
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try row.set(heap.gpa, try heap.internValue("k"), Value.int(9));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        try testing.expect(!heap.inflateToGrid(outer));
    }
    // a non-table (scalar) row ⇒ block
    {
        const outer = try heap.newTable();
        try outer.set(heap.gpa, Value.int(1), Value.int(7));
        try testing.expect(!heap.inflateToGrid(outer));
    }
    // outer hash border ⇒ block (would change observable #)
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        try outer.set(heap.gpa, try heap.internValue("x"), Value.int(0));
        try testing.expect(!heap.inflateToGrid(outer));
    }
    // a metatable on the parent ⇒ block (the grid read path skips __index)
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        outer.metatable = try heap.newTable();
        try testing.expect(!heap.inflateToGrid(outer));
    }
    // the `no_grid` hysteresis flag ⇒ block even when otherwise eligible
    {
        const outer = try heap.newTable();
        const row = try heap.newTable();
        try row.set(heap.gpa, Value.int(1), Value.int(1));
        try outer.set(heap.gpa, Value.int(1), Value.heap(&row.header));
        outer.no_grid = true;
        try testing.expect(!heap.inflateToGrid(outer));
        try testing.expect(!outer.array.isGrid());
    }
}
