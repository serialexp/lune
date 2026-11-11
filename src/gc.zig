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
const bytes = @import("bytes.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const system = @import("system.zig");
const File = @import("file.zig").File;
const ByteBuf = @import("bytebuf.zig").ByteBuf;
const stack_mem = @import("stack_mem.zig");
const GcHeader = object.GcHeader;
const GcColor = object.GcColor;
const String = string.String;
const Table = table.Table;
const Value = value.Value;
const Closure = function.Closure;
const Native = function.Native;
const Upvalue = function.Upvalue;
const Proto = bytecode.Proto;

/// The initial collection threshold (and the floor it never drops below): the
/// collector first runs once the live-object count reaches this, and afterwards
/// targets `max(this, (live + debt) * heap_growth)` pacing units (an object is
/// one, `nominal_object_bytes` of coroutine stack or string bytes another). Small
/// enough that even short
/// programs exercise a cycle; the growth factor keeps long programs from
/// collecting on every allocation.
const initial_gc_threshold: usize = 1024;
const heap_growth: usize = 2;

/// Doc 73: the bytes of coroutine stack one pacing unit stands for, so a
/// stack's charge (`Heap.chargeStack`) is its committed memory over this.
/// Pacing counts objects, not bytes, so this is a typical object's real
/// footprint (an empty table measures ~270 B with its allocations): then
/// garbage stacks get the headroom garbage objects do, about the live
/// heap's size, before they bring a collection forward.
pub const nominal_object_bytes: usize = 256;

/// The pacing units a string of `len` bytes is charged beyond its one as an
/// object (`Heap.string_debt`): its bytes over `nominal_object_bytes`, so a
/// string under that charges nothing and an 80 KB one 312. Without it a
/// program building big strings keeps a cycle's worth of them, a thousand
/// objects at the floor, alive between collections: `s = s .. "x"` to 80k
/// held 230 MB where Lua holds 3.
pub inline fn stringUnits(len: usize) usize {
    return len / nominal_object_bytes;
}

/// Doc 30: the JIT pattern-match scratch — plain per-VM memory the match
/// callouts (`smatch`/`sgmatch` in stralloc.zig) write and the projection ops
/// (`scap_int`/`scap_str`) read within a single trace iteration. NOT a heap
/// object and NOT VM state: invisible to GC roots, serialization, and
/// snapshots. A side-exit mid-projection replays the whole iteration in
/// tier-0, which never reads scratch, so stale contents are unobservable
/// (doc 30 §3). Native code reaches the slots via absolute addresses baked
/// off the VM-lifetime-stable `*Heap` (the `guard_gc` counter-load
/// discipline), hence the `extern` layout.
///
/// Layout: `words[2k, 2k+1]` is slot `k`. Int slots (start/end char index,
/// position captures, `next_pos`) use word `2k` only; span slots (whole
/// match, string captures) are `(byte_init, byte_len)` into the subject
/// recorded in `subj`. Slot indices are fixed by doc 30 §3: 0 = start char,
/// 1 = end char, 2 = whole-match span, 3.. = captures in capture order,
/// `slot_next_pos` = the gmatch cursor.
/// The most string operands a template join keeps in `Heap.join_parts`; a
/// longer template is not recorded (tier-0 joins any number).
pub const join_max = 32;

pub const MatchScratch = extern struct {
    /// `*const String` of the subject the last match op ran on (`scap_str`
    /// interns spans out of its bytes). Raw address, valid only within the
    /// trace iteration that wrote it.
    subj: usize = 0,
    words: [2 * n_slots]u64 = @splat(0),

    /// 3 fixed + max captures + next_pos. The 32 must equal
    /// `pattern.max_captures` — cross-checked by a comptime assert in
    /// `stdlib/string.zig` (gc.zig deliberately does not import stdlib).
    pub const n_slots = 3 + 32 + 1;
    pub const slot_start = 0;
    pub const slot_end = 1;
    pub const slot_whole = 2;
    pub const slot_cap0 = 3;
    pub const slot_next_pos = 3 + 32;
};

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
    /// The hash is LuaJIT's, widened (doc 28 §5): `string.sparseHash` reads
    /// six words, so strings that differ only between them collide. A miss
    /// whose walk costs more than `strtab_max_coll`, or a hit that first
    /// byte-compares `strtab_max_ident` strings sharing its hash and length,
    /// rehashes that chain with `string.denseHash` (`strtabRehashChain`,
    /// `lj_str_rehash_chain`). The invariant: a string's `hash` is its dense
    /// hash (`string.isDense`) exactly when the bucket its sparse hash names
    /// is marked in `strtab_dense`. Each sweep decides the marks afresh from
    /// the dense survivors (`strtabResettle`). Both seeds are fixed (LuaJIT draws them at random), so
    /// the geometry stays a function of the program; this answers accidental
    /// collisions, not a hostile flood.
    strtab: []?*String = &.{},
    /// One bit per `strtab` bucket: its strings are hashed densely. Allocated
    /// with `strtab`, so marking a chain never allocates.
    strtab_dense: []u64 = &.{},
    /// Some bucket is marked, so lookups must check the bit.
    strtab_any_dense: bool = false,
    /// Live entries in `strtab` (== interned strings on the object list).
    strtab_count: usize = 0,
    /// Mark-phase worklist: the *gray* set (objects marked but whose children are
    /// not yet scanned). Pre-sized before each cycle so marking cannot allocate.
    /// Capacity is retained across cycles.
    gray: std.ArrayListUnmanaged(*GcHeader) = .empty,
    /// Doc 73 §5.1: suspended coroutines marked this cycle, whose stacks the
    /// VM walks (`Vm.collect`): their registers need the VM's liveness
    /// masks, which the heap doesn't have. Pre-sized like `gray`, from
    /// `thread_count`.
    threads_to_walk: std.ArrayListUnmanaged(*GcHeader) = .empty,
    /// Live coroutine objects, recounted by every sweep.
    thread_count: usize = 0,
    /// Stacks of dead coroutines, kept for the next ones (`stack_mem.Pool`).
    stack_pool: stack_mem.Pool = .{},
    /// How the heap reaches coroutine objects, installed by the VM. The
    /// `Thread` type lives above the heap (it holds VM stack state), and the
    /// heap must not depend on the VM (`tools/check-jit-boundaries.py`).
    thread_ops: ?*const ThreadOps = null,
    /// Live-count threshold at which the next collection triggers, derived
    /// as `gc_target -| stack_debt` by `retarget` (which also keeps
    /// `gc_headroom` exact); never written directly. The JIT's budget guard
    /// reads it with `object_count`, so the stack charge lives here rather
    /// than in the count.
    next_gc: usize = initial_gc_threshold,
    /// The collection target in pacing units: one per object plus
    /// `stack_debt`. Set by the sweep and by keyframe restore
    /// (`setGcTarget`); a keyframe carries it, since `next_gc` alone loses
    /// the debt once it saturates.
    gc_target: usize = initial_gc_threshold,
    /// Doc 73: pacing units charged for the coroutine stacks currently held
    /// (`chargeStack`/`refundStack`), so garbage coroutines bring the next
    /// collection forward by the memory their stacks pin, not by one object
    /// each.
    stack_debt: usize = 0,
    /// Pacing units charged for the strings currently linked
    /// (`stringUnits`), so garbage strings bring the next collection forward
    /// by their bytes. Charged at link (`internImpl`, and keyframe restore
    /// through `internRestoredUnique`), refunded when the sweep frees one.
    string_debt: usize = 0,
    /// Doc 24 D3 with string pacing (doc 80 §3): the `A` of the last
    /// `guard_gc`/`guard_host_epoch` a trace passed, which native code and
    /// tier-1a store as they pass it. Read only while `trace_callout` is set.
    trace_alloc_bound: usize = 0,
    /// Set by the trace-side string callouts (`stralloc.zig`) around their
    /// core call: a string the intern would charge is then linked only when
    /// the charge cannot make a collection due before the iteration ends
    /// (`traceChargeFits`). Tier-0 never sets it.
    trace_callout: bool = false,
    /// Set when `internImpl` refused a charge for `trace_callout`, so the
    /// callout declines (tier-0 replays the op and collects) instead of
    /// reporting the OOM the refusal surfaces as.
    trace_charge_refused: bool = false,
    /// Sweeps run so far. Not program-visible state: tests compare it across
    /// tiers to pin the collection schedule.
    collections: u64 = 0,
    /// The dispatch prologue's GC gate, a countdown: a collection is due
    /// exactly when it is `<= 0`, which holds iff `gc_stress or object_count
    /// >= next_gc`. It is `next_gc - object_count` (`0` under stress),
    /// re-derived at every write of `next_gc`/`gc_stress` (`retarget`,
    /// `setGcStress`) and decremented in step with `object_count`
    /// in `link`, so the per-instruction safepoint test is one compare
    /// instead of the three-field predicate, and an allocation pays one
    /// decrement. Signed so a due-but-deferred heap (a pending multret, a
    /// skipped cycle) keeps counting down below zero; 2^63 allocations
    /// cannot wrap it. Debug builds re-derive the verdict in `shouldCollect`.
    gc_headroom: i64 = initial_gc_threshold,
    /// Doc 75 §4: a Ctrl-C asked the running program to stop. Set from a
    /// signal handler (`requestInterrupt`), which also zeroes `gc_headroom`
    /// so the dispatch prologue's one GC compare sends the next safepoint to
    /// the cold trampoline, where the VM raises `Error.Interrupted`. Not
    /// part of any snapshot: it is the host's, not the program's.
    interrupt_requested: bool = false,
    /// Doc 63 §5.6: moves whenever something a trace may rely on can have
    /// changed across a host call: guest execution, a collection, a host's
    /// structural change, or any C API entry not on the §5.6 exemption
    /// list. Lives here, not on `Vm`, because native pages bake only stable
    /// addresses and `Vm` may move. Only equality across one call is ever
    /// read, so it wraps. Bump through `bumpHostEpoch`.
    host_epoch: u64 = 0,
    /// Test/diagnostic knob: when set, `shouldCollect` is always true, so the
    /// collector runs at *every* safepoint. Surfaces use-after-free and missing
    /// roots immediately (a wrongly-freed live object breaks the very next op).
    /// Write it through `setGcStress`, which keeps `gc_headroom` exact.
    gc_stress: bool = false,
    /// Doc 30: the pattern-match callout scratch (see `MatchScratch`). Plain
    /// memory — the collector, the serializer, and the snapshot machinery all
    /// ignore it by construction (nothing walks `Heap` fields; strings are
    /// reached via `objects`/`strtab`, and this holds no `Value`s).
    match_scratch: MatchScratch = .{},
    /// Doc 82 §5: the template-join scratch. `sjpart` ops store the string
    /// operands of a template here (raw header addresses, valid only inside
    /// the trace iteration that wrote them); `sjoin` joins the first `n`.
    /// Plain memory like `match_scratch`: no roots, no serialization.
    join_parts: [join_max]u64 = @splat(0),

    pub fn init(gpa: std.mem.Allocator) Heap {
        return .{ .gpa = gpa };
    }

    /// Free every object, the worklist, and the interning table. After this the
    /// heap is unusable.
    pub fn deinit(self: *Heap) void {
        var it = self.objects;
        while (it) |h| {
            const next = h.next;
            destroyObject(self, h);
            it = next;
        }
        self.objects = null;
        self.object_count = 0;
        self.stack_pool.deinit(self.gpa); // after the threads put theirs back
        self.gray.deinit(self.gpa);
        self.threads_to_walk.deinit(self.gpa);
        if (self.strtab.len != 0) self.gpa.free(self.strtab);
        if (self.strtab_dense.len != 0) self.gpa.free(self.strtab_dense);
        self.strtab = &.{};
        self.strtab_dense = &.{};
        self.strtab_any_dense = false;
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
        self.gc_headroom -= 1;
    }

    /// `linkRestored` for a coroutine, which the heap also counts.
    pub fn linkRestoredThread(self: *Heap, h: *GcHeader, id: u32) void {
        self.linkRestored(h, id);
        self.thread_count += 1;
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

    /// `newTable` with the hash part allocated for `nhash` keys: a table
    /// constructor's (doc 72 P0).
    pub fn newTableSized(self: *Heap, nhash: u32) std.mem.Allocator.Error!*Table {
        const t = try Table.createSized(self.gpa, nhash);
        self.link(&t.header);
        return t;
    }

    /// `Table.clone`, registered with the heap.
    pub fn cloneTable(self: *Heap, src: *const Table) std.mem.Allocator.Error!*Table {
        const t = try src.clone(self.gpa);
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
        const plan = gridPlan(parent) orelse return false;
        const rows = plan.rows;

        // --- build the grid (OOM-atomic: parent untouched until the swap) ---
        var grid = arr.ArrayPart.initGrid(self.gpa, rows, plan.stride, plan.elem) catch return false;
        var r: usize = 0;
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
        parent.array.deinit(self.gpa); // drop the .value row-ref buffer; row tables orphaned → GC
        parent.array = grid;
        return true;
    }

    /// The grid `inflateToGrid` would build from `parent`: its row count, its
    /// stride (the longest row) and its cell lane. Null when `parent` does not
    /// qualify (the preconditions on `inflateToGrid`). Pure: the trace
    /// recorder asks it whether tier 0's fused store is about to inflate a
    /// table it has not yet ruled out (`recIndex2Set`).
    pub const GridPlan = struct { rows: usize, stride: usize, elem: arr.Lane };

    pub fn gridPlan(parent: *const Table) ?GridPlan {
        // --- outer shape ---
        if (parent.no_grid) return null; // hysteresis: ruled out, don't re-scan
        if (parent.array.isGrid()) return null; // already a grid
        if (parent.array.lane != .value) return null; // rows are heap refs ⇒ .value
        if (parent.hash.count() != 0) return null; // grid owns the whole 1..len run
        // A grid's outer `a[i]` miss returns nil with no `__index` consultation
        // (the fused read path, doc 14); a metatable'd parent would break that, so a
        // matrix carrying a metatable simply stays nested (rare; deflated on
        // `setmetatable` regardless).
        if (parent.metatable != null) return null;
        // Doc 18 D6: the field is `asize` (slot count incl. the key-0 slot) on a
        // scalar parent, but grid rows are 1-based — so guard BEFORE subtracting
        // (`asize == 0` underflows; `asize == 1` has no 1-based rows), and a
        // populated key 0 cannot be represented in-grid, so it blocks inflation
        // (conservative: costs only the optimization, deflation stays the
        // escape hatch).
        if (parent.array.asize <= 1) return null;
        if (!parent.array.get(0).isNil()) return null;
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
            if (!rv.isHeap()) return null; // nil row or scalar ⇒ block
            const h = rv.asHeap();
            if (h.type != .table) return null; // typed_array/string/... ⇒ block
            const row = Table.fromHeader(h);
            if (row.metatable != null) return null;
            // A grid's rows are its cells, written by the fused store with no
            // per-row check, and deflation rebuilds them: a frozen row stays
            // a table (doc 76 §5).
            if (row.isReadonly()) return null;
            if (row.hash.count() != 0) return null;
            // Doc 18: a row's array part covers keys 0..asize-1; its grid-able
            // cells are keys 1..asize-1 (rowView is 1-based). A populated row
            // key 0 cannot be represented in-grid ⇒ block (same conservative
            // rule as the parent's slot 0 above).
            if (row.array.isGrid()) return null; // nested grid ⇒ block (get() forbids grids)
            if (row.array.asize == 0) continue; // an empty row contributes no cells
            if (!row.array.get(0).isNil()) return null;
            const rl = row.array.asize - 1; // cell count: keys 1..rl
            if (rl == 0) continue; // only the slot-0 hole ⇒ no cells
            switch (row.array.lane) {
                .i8, .u8, .i16, .i32, .i64, .f64 => {}, // numeric leaf ok
                else => return null, // .value/.boolean/.grid ⇒ block
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
                    return null; // bool/heap cell ⇒ block
                }
            }
        }

        if (stride == 0) return null; // no cells anywhere ⇒ nothing to flatten
        if (!all_int and !all_float) return null; // mixed int/float ⇒ block
        const elem: arr.Lane = if (all_int) arr.ArrayPart.intLaneForRange(lo, hi) else .f64;
        return .{ .rows = rows, .stride = stride, .elem = elem };
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
    ///
    /// Each row is a genuine new program object (`newTable`, the counter
    /// advances). Keyframes serialize a grid as a grid (doc 61 Phase K), so
    /// capture never deflates.
    pub fn deflateGrid(self: *Heap, parent: *Table) std.mem.Allocator.Error!void {
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
            const row = try self.newTable(); // linked + id-stamped
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
        // Doc 63 §5.6: the array storage a trace may have hoisted is gone. A
        // C API read can get here without guest reentry (`mh_table_get`).
        self.bumpHostEpoch();
        // Hysteresis (doc 14, Phase 4b): a table that just deflated is not
        // re-inflated by a following fused store — that would thrash. It stays
        // nested for the rest of its life (keyframes carry the flag).
        parent.no_grid = true;
    }

    /// Minimum bucket count. Power of two; also the lazy first allocation, so a
    /// program that interns at all pays for 512 slots (4 KiB) once.
    const strtab_min_size: usize = 512;

    /// A chain an intern miss walks past this many strings on is rehashed
    /// densely (LuaJIT's `LJ_STR_MAXCOLL`). A string whose bytes the walk
    /// compared counts twice, as in `lj_str_new`.
    const strtab_max_coll: usize = 32;

    /// A hit that byte-compared this many strings sharing its sparse hash
    /// and length before its own rehashes their chain densely (doc 28 §5.1).
    /// They are strings the samples cannot tell apart, and every hit on one
    /// compares bytes along the group; LuaJIT waits for `strtab_max_coll`.
    /// A miss does not count them: short-lived strings that collide (a day's
    /// dates differing only in the hour) are seldom looked up again, and
    /// promoting their groups costs more than it saves. Misses keep the
    /// long-chain guard, so an unmarked group holds at most
    /// `strtab_max_coll / 2 + 1` strings: a miss that compared that many
    /// counts past `strtab_max_coll`.
    const strtab_max_ident: usize = 4;

    /// The hash `content` is stored and found under (doc 28 §5): its sparse
    /// hash, or its dense one when the sparse hash's bucket is marked.
    inline fn strtabHash(self: *const Heap, content: []const u8) u64 {
        const h = string.sparseHash(content);
        if (self.strtab_any_dense and self.bucketDense(self.strtab_dense, @as(usize, @truncate(h)) & (self.strtab.len - 1))) {
            @branchHint(.unlikely);
            return string.denseHash(content);
        }
        return h;
    }

    inline fn bucketDense(_: *const Heap, marks: []const u64, idx: usize) bool {
        return marks[idx / 64] & (@as(u64, 1) << @intCast(idx % 64)) != 0;
    }

    inline fn markDense(_: *const Heap, marks: []u64, idx: usize) void {
        marks[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
    }

    /// What `strtabFind` saw: the string, or for a miss what the walk cost.
    const Found = struct {
        s: ?*String,
        /// Strings passed, counting twice each whose bytes were compared.
        coll: usize,
        /// Strings passed that share the hash and length, on a hit too.
        ident: usize,
    };

    /// Look up `content`, stored under `hash`, in the intern chains: the
    /// unique live `String` or null, and what the walk cost (`coll` only on
    /// a miss).
    /// A hit costs one hash + on average ≤1 chain hop (grow keeps load ≤ ~100%).
    inline fn strtabFind(self: *const Heap, content: []const u8, hash: u64) Found {
        if (self.strtab.len == 0) return .{ .s = null, .coll = 0, .ident = 0 };
        var s = self.strtab[@as(usize, @truncate(hash)) & (self.strtab.len - 1)];
        var passed: usize = 0;
        var ident: usize = 0;
        while (s) |cur| : (s = cur.next_intern) {
            if (cur.hash == hash and cur.len == content.len) {
                if (bytes.eql(cur.bytes(), content)) return .{ .s = cur, .coll = 0, .ident = ident };
                ident += 1;
            }
            passed += 1;
        }
        return .{ .s = null, .coll = passed + ident, .ident = ident };
    }

    fn strtabLookup(self: *const Heap, content: []const u8, hash: u64) ?*String {
        return self.strtabFind(content, hash).s;
    }

    /// The miss path's chain guard: when the walk for a sparse-hashed
    /// `content` cost more than `strtab_max_coll`, rehash that chain densely
    /// and return the hash `content` now goes under; else `hash`. Infallible
    /// (the marks were allocated with the table).
    inline fn strtabGuard(self: *Heap, content: []const u8, hash: u64, found: Found) u64 {
        if (found.coll <= strtab_max_coll) return hash;
        // A dense lookup's chain has nothing left to rehash.
        if (string.isDense(hash)) return hash;
        const idx = @as(usize, @truncate(hash)) & (self.strtab.len - 1);
        if (self.bucketDense(self.strtab_dense, idx)) return hash;
        self.strtabRehashChain(idx);
        return string.denseHash(content);
    }

    /// The hit path's guard: a hit found under sparse `hash` after
    /// byte-comparing `strtab_max_ident` look-alikes rehashes their chain.
    /// No allocation, no collection, and no string moves, so the caller's
    /// pointer stays good; only the chain geometry changes. Read-only probes
    /// (`internedLookup`, the recorder's) never come here.
    inline fn strtabHitGuard(self: *Heap, hash: u64, found: Found) void {
        if (found.ident >= strtab_max_ident) {
            @branchHint(.unlikely);
            // A dense lookup's bucket is not the group's.
            if (string.isDense(hash)) return;
            self.strtabRehashChain(@as(usize, @truncate(hash)) & (self.strtab.len - 1));
        }
    }

    /// Mark bucket `idx` dense and move its sparse-hashed strings to their
    /// dense buckets (`lj_str_rehash_chain`). Strings already dense stay
    /// where their dense hash puts them, which may be `idx` again.
    noinline fn strtabRehashChain(self: *Heap, idx: usize) void {
        const mask = self.strtab.len - 1;
        var s = self.strtab[idx];
        self.strtab[idx] = null;
        var moved: ?*String = null; // decided strings, rechained after the walk
        while (s) |cur| {
            const next = cur.next_intern;
            if (!string.isDense(cur.hash)) cur.hash = string.denseHash(cur.bytes());
            cur.next_intern = moved;
            moved = cur;
            s = next;
        }
        self.markDense(self.strtab_dense, idx);
        self.strtab_any_dense = true;
        while (moved) |cur| {
            const next = cur.next_intern;
            const at = @as(usize, @truncate(cur.hash)) & mask;
            cur.next_intern = self.strtab[at];
            self.strtab[at] = cur;
            moved = next;
        }
    }

    /// Push `s` at its bucket's head. Infallible; the caller has ensured capacity.
    fn strtabInsert(self: *Heap, s: *String) void {
        self.strtabLink(s);
        self.strtab_count += 1;
    }

    /// `strtabInsert` for a string already counted.
    inline fn strtabLink(self: *Heap, s: *String) void {
        std.debug.assert(self.strtab.len != 0);
        const idx = @as(usize, @truncate(s.hash)) & (self.strtab.len - 1);
        s.next_intern = self.strtab[idx];
        self.strtab[idx] = s;
    }

    /// Make room for one more entry: lazy-allocate the minimum table, or grow ×2
    /// when the load would pass 100% (LuaJIT's policy — average chain length
    /// stays ~1). Growing rebuilds the chains by stored hash. The ONLY fallible
    /// step of an intern miss besides the string allocation itself; on error
    /// nothing has been mutated.
    /// Inline, as every intern miss passes it, nearly always with room.
    inline fn strtabEnsureCapacity(self: *Heap) std.mem.Allocator.Error!void {
        if (self.strtab_count < self.strtab.len) return;
        return self.strtabGrow();
    }

    noinline fn strtabGrow(self: *Heap) std.mem.Allocator.Error!void {
        if (self.strtab.len == 0) {
            const nt = try self.gpa.alloc(?*String, strtab_min_size);
            errdefer self.gpa.free(nt);
            const marks = try self.gpa.alloc(u64, strtab_min_size / 64);
            @memset(nt, null);
            @memset(marks, 0);
            self.strtab = nt;
            self.strtab_dense = marks;
            return;
        }
        // Cap: past 2^31 buckets just tolerate higher load (as LuaJIT does at
        // LJ_MAX_STRTAB) rather than overflowing the shift.
        if (self.strtab.len >= (@as(usize, 1) << 31)) return;
        try self.strtabRebuild(self.strtab.len * 2);
    }

    /// Allocate a `new_len`-bucket table, re-chain every live string into it by
    /// stored hash, and free the old table. `new_len` must be a power of two.
    /// Transactional: on allocation failure the old table is untouched.
    ///
    /// With dense chains about, the marks are decided afresh for the new
    /// geometry (`strtabDecideMarks`), and each string takes the hash its new
    /// bucket calls for, recomputing the dense one only when it was sparse
    /// before. With none, every string stays sparse: no group can need a mark
    /// (see `strtabDecideMarks`), and more strings per bucket than
    /// `strtab_max_coll` is what the miss guard is for.
    fn strtabRebuild(self: *Heap, new_len: usize) std.mem.Allocator.Error!void {
        const nt = try self.gpa.alloc(?*String, new_len);
        errdefer self.gpa.free(nt);
        const marks = try self.gpa.alloc(u64, new_len / 64);
        errdefer self.gpa.free(marks);
        @memset(nt, null);
        @memset(marks, 0);
        const mask = new_len - 1;
        const any_dense = self.strtab_any_dense and try self.strtabDecideMarks(marks, mask);
        for (self.strtab) |head| {
            var s = head;
            while (s) |cur| {
                const next = cur.next_intern; // save before overwriting the link
                if (self.strtab_any_dense) {
                    const was_dense = string.isDense(cur.hash);
                    const sparse = if (was_dense) string.sparseHash(cur.bytes()) else cur.hash;
                    if (!self.bucketDense(marks, @as(usize, @truncate(sparse)) & mask)) {
                        cur.hash = sparse;
                    } else if (!was_dense) {
                        cur.hash = string.denseHash(cur.bytes());
                    }
                }
                const idx = @as(usize, @truncate(cur.hash)) & mask;
                cur.next_intern = nt[idx];
                nt[idx] = cur;
                s = next;
            }
        }
        self.gpa.free(self.strtab);
        self.gpa.free(self.strtab_dense);
        self.strtab = nt;
        self.strtab_dense = marks;
        self.strtab_any_dense = any_dense;
    }

    /// One sparse hash and length, for grouping strings by them.
    const Twin = struct {
        hash: u64,
        len: usize,

        fn lessThan(_: void, a: Twin, b: Twin) bool {
            return a.hash < b.hash or (a.hash == b.hash and a.len < b.len);
        }
    };

    /// Mark in `marks` the buckets of a `mask + 1`-bucket table that hash
    /// densely (`lj_str_resize`, widened): those more than `strtab_max_coll`
    /// strings name by their sparse hash, and those holding more than
    /// `strtab_max_ident` dense strings of one sparse hash and length, the
    /// groups the hit guard promoted that are still that large. Whether any is
    /// marked. A group not yet promoted stays sparse and waits for its next
    /// expensive hit; every geometry keeps a group in one bucket. So only the
    /// dense strings are grouped, sorted in scratch freed here.
    fn strtabDecideMarks(self: *const Heap, marks: []u64, mask: usize) std.mem.Allocator.Error!bool {
        const counts = try self.gpa.alloc(u32, mask + 1);
        defer self.gpa.free(counts);
        @memset(counts, 0);
        var grouped: usize = 0;
        for (self.strtab) |head| {
            var s = head;
            while (s) |cur| : (s = cur.next_intern) {
                const dense = string.isDense(cur.hash);
                const sparse = if (dense) string.sparseHash(cur.bytes()) else cur.hash;
                counts[@as(usize, @truncate(sparse)) & mask] +|= 1;
                if (dense) grouped += 1;
            }
        }
        const twins = try self.gpa.alloc(Twin, grouped);
        defer self.gpa.free(twins);
        var n: usize = 0;
        for (self.strtab) |head| {
            var s = head;
            while (s) |cur| : (s = cur.next_intern) {
                if (!string.isDense(cur.hash)) continue;
                twins[n] = .{ .hash = string.sparseHash(cur.bytes()), .len = cur.len };
                n += 1;
            }
        }
        var any = false;
        for (counts, 0..) |c, i| if (c > strtab_max_coll) {
            self.markDense(marks, i);
            any = true;
        };
        std.mem.sortUnstable(Twin, twins, {}, Twin.lessThan);
        var i: usize = 0;
        while (i < twins.len) {
            var j = i + 1;
            while (j < twins.len and twins[j].hash == twins[i].hash and twins[j].len == twins[i].len) j += 1;
            if (j - i > strtab_max_ident) {
                self.markDense(marks, @as(usize, @truncate(twins[i].hash)) & mask);
                any = true;
            }
            i = j;
        }
        return any;
    }

    /// A dense survivor `strtabResettle` decides: its sparse hash, and it.
    const Settler = struct {
        sparse: u64,
        s: *String,

        /// By sparse bucket, then sparse hash, then length.
        fn lessThan(mask: usize, a: Settler, b: Settler) bool {
            if (a.sparse & mask != b.sparse & mask) return a.sparse & mask < b.sparse & mask;
            if (a.sparse != b.sparse) return a.sparse < b.sparse;
            return a.s.len < b.s.len;
        }
    };

    /// The sweep's `strtabDecideMarks` (doc 28 §5.1): clear every mark and
    /// decide afresh from the `n` dense survivors in `dense` (linked through
    /// `next_intern`, not yet chained), so a mark lasts only as long as the
    /// group or crowd that needs it. Without this, short-lived strings that
    /// collide (a day's dates differing only in the hour) mark bucket after
    /// bucket of a table that never grows, and every later string in them
    /// pays both hashes. The sparse survivors are chained already, and no
    /// sparse string's bucket was marked, so a marked bucket's strings are
    /// all in `dense` and they alone decide it, by `strtabDecideMarks`'s
    /// rules. Costs a sparse hash per dense survivor and a sort of them,
    /// nothing per sparse one. Without the scratch, every dense survivor
    /// stays dense and marks its bucket again, which is always valid.
    fn strtabResettle(self: *Heap, dense: ?*String, n: usize) void {
        @memset(self.strtab_dense, 0);
        self.strtab_any_dense = false;
        if (n == 0) return;
        const mask = self.strtab.len - 1;
        const settlers = self.gpa.alloc(Settler, n) catch {
            var s = dense;
            while (s) |cur| {
                const next = cur.next_intern; // save before relinking
                self.markDense(self.strtab_dense, @as(usize, @truncate(string.sparseHash(cur.bytes()))) & mask);
                self.strtabLink(cur);
                s = next;
            }
            self.strtab_any_dense = true;
            return;
        };
        defer self.gpa.free(settlers);
        var i: usize = 0;
        var s = dense;
        while (s) |cur| : (s = cur.next_intern) {
            settlers[i] = .{ .sparse = string.sparseHash(cur.bytes()), .s = cur };
            i += 1;
        }
        std.mem.sortUnstable(Settler, settlers, mask, Settler.lessThan);
        // Each bucket's run of settlers, and inside it each group's run.
        i = 0;
        while (i < n) {
            const bucket = @as(usize, @truncate(settlers[i].sparse)) & mask;
            var end = i + 1;
            while (end < n and @as(usize, @truncate(settlers[end].sparse)) & mask == bucket) end += 1;
            var marked = end - i > strtab_max_coll;
            var g = i;
            while (!marked and g < end) {
                var h = g + 1;
                while (h < end and settlers[h].sparse == settlers[g].sparse and settlers[h].s.len == settlers[g].s.len) h += 1;
                marked = h - g > strtab_max_ident;
                g = h;
            }
            if (marked) {
                self.markDense(self.strtab_dense, bucket);
                self.strtab_any_dense = true;
            }
            for (settlers[i..end]) |st| {
                if (!marked) st.s.hash = st.sparse;
                self.strtabLink(st.s);
            }
            i = end;
        }
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
        return self.internImpl(content, .{});
    }

    /// `intern` with producer-`Known` character facts (doc 28 §6): a caller
    /// that can PROVE the result's code-point count and/or ASCII bit (a
    /// substring's count is `j - i + 1` by definition; a repetition or
    /// permutation preserves the source's bit) passes them and the miss path
    /// skips that half of the construction scan. Wrong claims trap in safe
    /// builds — on the miss path (construction asserts against the fused scan)
    /// AND on the hit path below, so a bad producer cannot hide behind bytes
    /// that happen to be interned already.
    pub fn internKnown(self: *Heap, content: []const u8, known: String.Known) std.mem.Allocator.Error!*String {
        return self.internImpl(content, known);
    }

    /// The ONE intern body (doc 28 §6 [MF]: centralized so the doc-24 D5
    /// transactional shape — every fallible step before any heap mutation,
    /// at most one `Heap.link` — cannot fork between the plain and known-facts
    /// entries).
    fn internImpl(self: *Heap, content: []const u8, known: String.Known) std.mem.Allocator.Error!*String {
        // Program-visible strings are valid UTF-8 by construction (S-B), but
        // this entry ALSO accepts raw non-UTF-8 host bytes on purpose — the
        // effect log parks invalid host input as interned strings so a recorded
        // failure replays byte-identically (validate-after-log). String-side
        // character caches (`cp_len`, the exact `str_ascii` bit) are computed
        // from the bytes and stay well-defined either way (doc 28 §2).
        const h0 = self.strtabHash(content);
        const found = self.strtabFind(content, h0);
        if (found.s) |existing| {
            // Hit-path contract check (doc 28 §6 [MF]).
            if (known.cp_len) |n| std.debug.assert(n == existing.cp_len);
            if (known.ascii) |a| std.debug.assert(a == existing.isAscii());
            self.strtabHitGuard(h0, found);
            return existing;
        }
        // The chain guard may re-chain before anything fallible: geometry is
        // runtime-private, and the table stays valid either way.
        const h = self.strtabGuard(content, h0, found);
        const s = try String.createWithHashKnown(self.gpa, content, h, known);
        errdefer s.destroy(self.gpa);
        try self.linkNew(s);
        return s;
    }

    /// Intern a string built in place (`String.Builder`, doc 80 §4): the
    /// existing object for its bytes, freeing the built one, or else the
    /// built one, registered and linked. Takes the builder's allocation
    /// either way; on error the heap is unchanged.
    pub fn internBuilt(self: *Heap, b: *String.Builder) std.mem.Allocator.Error!*String {
        const s = b.finish();
        const h0 = self.strtabHash(s.bytes());
        const found = self.strtabFind(s.bytes(), h0);
        if (found.s) |existing| {
            s.destroy(self.gpa);
            self.strtabHitGuard(h0, found);
            return existing;
        }
        s.hash = self.strtabGuard(s.bytes(), h0, found);
        errdefer s.destroy(self.gpa);
        try self.linkNew(s);
        return s;
    }

    /// The string of `parts` laid end to end (doc 82 `interp`), each a string
    /// header's address. Short results are assembled on the stack, long ones
    /// in the string's own allocation; the parts' character facts stand in
    /// for the scan. The ONE join: tier-0's `interp` and the trace's `sjoin`
    /// both end here, so they intern the same string at the same id.
    pub fn internJoin(self: *Heap, parts: []const u64) std.mem.Allocator.Error!*String {
        var len: usize = 0;
        var cps: usize = 0;
        var ascii = true;
        for (parts) |p| {
            const s = String.fromHeader(@ptrFromInt(@as(usize, @intCast(p))));
            len = std.math.add(usize, len, s.bytes().len) catch return error.OutOfMemory;
            cps += s.cpLen();
            ascii = ascii and s.isAscii();
        }
        if (len <= nominal_object_bytes) {
            var buf: [nominal_object_bytes]u8 = undefined;
            var at: usize = 0;
            for (parts) |p| {
                const part = String.fromHeader(@ptrFromInt(@as(usize, @intCast(p)))).bytes();
                @memcpy(buf[at..][0..part.len], part);
                at += part.len;
            }
            return self.internKnown(buf[0..len], .{ .cp_len = cps, .ascii = ascii });
        }
        var sb = try String.Builder.init(self.gpa, len);
        defer sb.deinit(self.gpa);
        for (parts) |p| {
            const s = String.fromHeader(@ptrFromInt(@as(usize, @intCast(p))));
            sb.append(s.bytes(), s.cpLen(), s.isAscii());
        }
        return self.internBuilt(&sb);
    }

    /// The miss path every intern entry ends in (doc 28 §6 [MF], doc 24 D5):
    /// register and link `s`, which is not in the intern table. Its fallible
    /// steps come first, so on error the heap is unchanged and the caller
    /// still owns `s`. Inline: out of line, the call cost every miss ~25
    /// instructions.
    inline fn linkNew(self: *Heap, s: *String) std.mem.Allocator.Error!void {
        const units = stringUnits(s.len);
        if (self.chargeRefused(units)) return error.OutOfMemory;
        try self.strtabMakeRoom(s);
        // Infallible from here.
        self.strtabInsert(s);
        self.link(&s.header);
        if (units != 0) self.chargeString(units);
    }

    /// Room for `s`, not yet chained, whose `hash` was taken for the current
    /// table: a grow re-decides the dense marks, so it is taken again.
    inline fn strtabMakeRoom(self: *Heap, s: *String) std.mem.Allocator.Error!void {
        const len = self.strtab.len;
        try self.strtabEnsureCapacity();
        if (self.strtab.len != len) {
            @branchHint(.unlikely);
            s.hash = self.strtabHash(s.bytes());
        }
    }

    /// Whether a trace callout's charge of `units` must be refused (doc 80
    /// §3); a refusal is recorded for the callout and surfaces as an OOM.
    fn chargeRefused(self: *Heap, units: usize) bool {
        if (units == 0 or !self.trace_callout or self.traceChargeFits(units)) return false;
        self.trace_charge_refused = true;
        return true;
    }

    /// Whether a trace callout may link a string charged `units`: then no
    /// collection can come due before the iteration ends, as `guard_gc`
    /// promised for its links (doc 24 D3) — the iteration links at most
    /// `trace_alloc_bound` objects, and the charge lowers `next_gc` by
    /// `units`. When it may not, the callout declines before linking and
    /// tier-0 replays the op, which charges and collects where it always
    /// would (doc 80 §3).
    fn traceChargeFits(self: *const Heap, units: usize) bool {
        return !self.gc_stress and (self.object_count +| self.trace_alloc_bound +| units) < self.next_gc;
    }

    fn chargeString(self: *Heap, units: usize) void {
        self.string_debt += units;
        self.retarget();
    }

    /// The interned `String` for `content`, or null if these bytes are not
    /// currently interned. Read-only probe (tests, diagnostics) — program code
    /// wants `intern`, which creates on miss.
    pub fn internedLookup(self: *const Heap, content: []const u8) ?*String {
        return self.strtabLookup(content, self.strtabHash(content));
    }

    /// Restore-only (keyframeser pass 1a): register an already-created `String`
    /// in the intern chains, REJECTING duplicate bytes — a valid snapshot interns
    /// one object per byte-sequence, and silently keeping two would break the
    /// interning invariant (pointer equality). Does NOT GC-link or stamp an id;
    /// the restorer does that with the snapshot's own id. Failure-atomic: on any
    /// error the table holds the same strings and `s` is untouched (the caller
    /// owns it). It passes the miss guard as an intern does, so a restored
    /// table keeps the bound on same-hash groups `strtabDecideMarks` relies on.
    pub fn internRestoredUnique(self: *Heap, s: *String) error{ OutOfMemory, DuplicateInternedString }!void {
        const h0 = self.strtabHash(s.bytes());
        const found = self.strtabFind(s.bytes(), h0);
        if (found.s != null) return error.DuplicateInternedString;
        const old = s.hash;
        s.hash = self.strtabGuard(s.bytes(), h0, found);
        self.strtabMakeRoom(s) catch |e| {
            s.hash = old; // untouched on failure
            return e;
        };
        self.strtabInsert(s);
        // The restorer links it next; the snapshot's `gc_target` less this
        // debt is the `next_gc` the captured heap had.
        const units = stringUnits(s.len);
        if (units != 0) self.chargeString(units);
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

    /// Allocate a copy of `template` (an unlinked native, e.g. a registry
    /// row's `interp.base_templates` entry) and register it with the heap.
    pub fn newNativeFrom(self: *Heap, template: *const Native) std.mem.Allocator.Error!*Native {
        const n = try self.gpa.create(Native);
        n.* = template.*;
        self.link(&n.header);
        return n;
    }

    /// Allocate a copy of `template` with `n_bound` bound values, nil for
    /// the caller to fill before the next safepoint, and register it with
    /// the heap.
    pub fn newBoundNative(self: *Heap, template: *const Native, n_bound: usize) std.mem.Allocator.Error!*Native {
        const n = try Native.createBound(self.gpa, template, n_bound);
        self.link(&n.header);
        return n;
    }

    /// Allocate a file handle (doc 65 §4.1) and register it with the heap.
    pub fn newFile(self: *Heap, id: system.FileId, kind: File.Kind, mode: system.OpenMode, path: []const u8) std.mem.Allocator.Error!*File {
        const f = try File.create(self.gpa, id, kind, mode, path);
        self.link(&f.header);
        return f;
    }

    /// Allocate a byte buffer (doc 68 §7.4) owning `list`, and register it
    /// with the heap. Charges the pacing for the bytes it already holds.
    pub fn newByteBuf(self: *Heap, list: std.ArrayList(u8)) std.mem.Allocator.Error!*ByteBuf {
        const b = try ByteBuf.create(self.gpa, list);
        self.link(&b.header);
        self.chargeByteBuf(b);
        return b;
    }

    /// Charge the pacing for the bytes `b` has grown by since the last
    /// charge, as a string's bytes are (`stringUnits`).
    pub fn chargeByteBuf(self: *Heap, b: *ByteBuf) void {
        const want = stringUnits(b.list.items.len);
        if (want > b.charged) {
            self.chargeString(want - b.charged);
            b.charged = want;
        }
    }

    /// Register a new coroutine object (doc 73; `coroutine.newThread`).
    pub fn linkThread(self: *Heap, h: *GcHeader) void {
        self.link(h);
        self.thread_count += 1;
    }

    /// Allocate an *open* upvalue over live stack slot `index`, whose lanes
    /// are `tag` and `payload`, and register it with the heap. Closing is the
    /// interpreter's job.
    pub fn newUpvalue(self: *Heap, index: usize, tag: *u8, payload: *u64) std.mem.Allocator.Error!*Upvalue {
        const u = try Upvalue.createOpen(self.gpa, index, tag, payload);
        self.link(&u.header);
        return u;
    }

    /// Allocate an already-closed upvalue holding `v` and register it with the
    /// heap: a cell nothing has captured yet, such as a REPL line's new
    /// top-level local (doc 75 §6).
    pub fn newClosedUpvalue(self: *Heap, v: Value) std.mem.Allocator.Error!*Upvalue {
        const u = try Upvalue.createClosed(self.gpa, v);
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

    /// Doc 63 §5.6: record that something a trace may rely on can have
    /// changed (see `host_epoch`).
    pub inline fn bumpHostEpoch(self: *Heap) void {
        self.host_epoch +%= 1;
    }

    /// Whether a collection should run at the next safepoint.
    pub inline fn shouldCollect(self: *const Heap) bool {
        const due = self.gc_headroom <= 0;
        std.debug.assert(due == self.dueFromInputs());
        return due;
    }

    fn dueFromInputs(self: *const Heap) bool {
        return self.gc_stress or self.interrupt_requested or self.object_count >= self.next_gc;
    }

    /// Ask the running program to stop at its next safepoint. Async-signal-
    /// safe: two plain stores. An allocation's `gc_headroom` decrement racing
    /// the store can undo the zeroing; the flag survives, `refreshHeadroom`
    /// honours it, and a repeated request lands.
    pub fn requestInterrupt(self: *Heap) void {
        const flag: *volatile bool = &self.interrupt_requested;
        flag.* = true;
        const headroom: *volatile i64 = &self.gc_headroom;
        headroom.* = 0;
    }

    pub fn interruptPending(self: *const Heap) bool {
        const flag: *const volatile bool = &self.interrupt_requested;
        return flag.*;
    }

    /// Forget a request (it was served, or arrived after its line ended).
    pub fn clearInterrupt(self: *Heap) void {
        const flag: *volatile bool = &self.interrupt_requested;
        flag.* = false;
        self.refreshHeadroom();
    }

    pub fn setGcStress(self: *Heap, on: bool) void {
        self.gc_stress = on;
        self.refreshHeadroom();
    }

    pub fn setGcTarget(self: *Heap, target: usize) void {
        self.gc_target = target;
        self.retarget();
    }

    /// Doc 73: a coroutine took a stack worth `units` (`coroutine.Stack`).
    pub fn chargeStack(self: *Heap, units: usize) void {
        self.stack_debt += units;
        self.retarget();
    }

    /// Doc 73: a coroutine gave back a stack charged with `chargeStack`.
    pub fn refundStack(self: *Heap, units: usize) void {
        self.stack_debt -= units;
        self.retarget();
    }

    fn retarget(self: *Heap) void {
        self.next_gc = self.gc_target -| self.debt();
        self.refreshHeadroom();
    }

    /// The pacing units charged beyond one per object.
    pub fn debt(self: *const Heap) usize {
        return self.stack_debt +| self.string_debt;
    }

    fn refreshHeadroom(self: *Heap) void {
        const max: u64 = std.math.maxInt(i64);
        const count: u64 = self.object_count;
        const next: u64 = self.next_gc;
        self.gc_headroom = if (self.gc_stress or self.interrupt_requested)
            0
        else if (count >= next)
            -@as(i64, @intCast(@min(count - next, max)))
        else
            @intCast(@min(next - count, max));
    }

    /// Begin a cycle: reserve worklist capacity for the worst case (every object
    /// gray at once). This is the *only* fallible step of a collection — once it
    /// succeeds, marking and sweeping cannot allocate. On OOM the caller skips
    /// the cycle; nothing has been coloured, so the heap is untouched and safe.
    pub fn beginCollect(self: *Heap) std.mem.Allocator.Error!void {
        try self.gray.ensureTotalCapacity(self.gpa, self.object_count);
        try self.threads_to_walk.ensureTotalCapacity(self.gpa, self.thread_count);
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

    /// Whether the next `sweep` frees `h`: the sweep's own predicate, so a
    /// caller between `traceAll` and `sweep` gets an exact answer (doc 61
    /// §7.1). White alone is not enough: pinned objects (loaded-chunk
    /// constants) are never marked and never freed.
    pub inline fn willFree(h: *const GcHeader) bool {
        return h.color == .white and !h.flags.pinned;
    }

    /// Scan one object's outgoing references, marking each. Type-dispatched on
    /// the header so the collector knows where the child pointers live.
    fn blacken(self: *Heap, h: *GcHeader) void {
        switch (h.type) {
            // Leaves: no heap children. A `File`'s path is owned bytes.
            .string, .file, .bytebuf => {},
            // A `Native`'s name is a borrowed/static slice, not a heap
            // String; its bound values (`coroutine.wrap`'s coroutine) are
            // its only children.
            .native => for (Native.fromHeader(h).bound) |v| self.markValue(v),
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
                    self.markValue(entry.key);
                    self.markValue(entry.value_ptr.*);
                }
                // `next`'s sorted view is derived and kept between traversals;
                // a collection drops it, so the views alive are only those of
                // tables walked since the last one. Freeing allocates nothing.
                t.hash.dropIterCache(self.gpa);
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
                    // Doc 73 §5.1: the slot's coroutine stays alive with it.
                    .open => if (u.owner) |o| self.markHeader(o),
                    .closed => |v| self.markValue(v),
                }
            },
            .thread => self.thread_ops.?.blacken(self, h),
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
        // Dense survivors wait for `strtabResettle`, linked through
        // `next_intern`; sparse ones re-chain as they are met.
        var dense: ?*String = null;
        var dense_n: usize = 0;
        var slot: *?*GcHeader = &self.objects;
        var live: usize = 0;
        var live_threads: usize = 0;
        while (slot.*) |h| {
            if (willFree(h)) {
                // Unreachable: unlink (leaving `slot` pointing at the successor)
                // and free. Dead strings simply never re-enter the chains.
                slot.* = h.next;
                destroyObject(self, h);
            } else {
                // Survivor (reachable, or pinned): reset to white and advance.
                h.color = .white;
                live += 1;
                if (h.type == .thread) live_threads += 1;
                if (h.type == .string) {
                    const s = String.fromHeader(h);
                    if (string.isDense(s.hash)) {
                        s.next_intern = dense;
                        dense = s;
                        dense_n += 1;
                    } else self.strtabLink(s);
                    live_str += 1;
                }
                slot = &h.next;
            }
        }
        // Count the survivors rather than trusting the pre-sweep figure.
        self.strtab_count = live_str;
        if (self.strtab_any_dense) self.strtabResettle(dense, dense_n) else std.debug.assert(dense_n == 0);
        self.object_count = live;
        self.thread_count = live_threads;
        self.collections += 1;
        // The destroyed coroutines refunded their stacks above, and the
        // destroyed strings their bytes, so the debt is what the survivors
        // hold.
        self.setGcTarget(@max(initial_gc_threshold, (live +| self.debt()) *| heap_growth));
        self.strtabMaybeShrink();
        // Doc 73: stacks pooled since the last collection hand their pages
        // back, so an idle pool holds no committed stack memory.
        self.stack_pool.trim();
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

/// The heap's view of a coroutine object (`Heap.thread_ops`).
pub const ThreadOps = struct {
    /// Mark the object's children; queue its stack on `threads_to_walk`
    /// when it isn't the running one.
    blacken: *const fn (heap: *Heap, h: *GcHeader) void,
    /// Free it; its stack goes back to `Heap.stack_pool`.
    destroy: *const fn (heap: *Heap, h: *GcHeader) void,
};

/// Free one object according to its concrete type.
fn destroyObject(heap: *Heap, h: *GcHeader) void {
    const gpa = heap.gpa;
    switch (h.type) {
        .string => {
            const s = String.fromHeader(h);
            heap.string_debt -= stringUnits(s.len);
            s.destroy(gpa);
        },
        .table => Table.fromHeader(h).destroy(gpa),
        .function => Closure.fromHeader(h).destroy(gpa),
        .native => Native.fromHeader(h).destroy(gpa),
        .upvalue => Upvalue.fromHeader(h).destroy(gpa),
        .file => File.fromHeader(h).destroy(gpa),
        .bytebuf => {
            const b = ByteBuf.fromHeader(h);
            heap.string_debt -= b.charged;
            b.destroy(gpa);
        },
        .thread => heap.thread_ops.?.destroy(heap, h),
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

test "doc 28 c3a: internKnown — same object as plain intern on hit AND miss, correct caches, link audit" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // MISS with full known facts: links exactly once (object count AND the
    // monotonic id counter advance by one), caches are right.
    const a = try heap.internKnown("hello", .{ .cp_len = 5, .ascii = true });
    try testing.expectEqual(@as(usize, 1), heap.object_count);
    try testing.expectEqual(@as(u32, 1), heap.next_obj_id);
    try testing.expectEqual(@as(usize, 5), a.cpLen());
    try testing.expect(a.isAscii());

    // HIT with known facts: same pointer, zero new links (the hit-path assert
    // ran against the existing object's caches).
    const b = try heap.internKnown("hello", .{ .cp_len = 5, .ascii = true });
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), heap.object_count);
    try testing.expectEqual(@as(u32, 1), heap.next_obj_id);

    // HIT from the PLAIN entry over a known-interned string, and vice versa —
    // the two entries dedupe against each other (one internImpl body).
    const c = try heap.intern("hello");
    try testing.expectEqual(a, c);
    const d = try heap.internKnown("world", .{}); // no facts: full scan path
    const e = try heap.intern("world");
    try testing.expectEqual(d, e);
    try testing.expectEqual(@as(usize, 2), heap.object_count);

    // Partial knowledge: count known, ASCII derived by scan (and conversely) —
    // a multibyte miss gets the exact bit even when only the count is claimed.
    const f = try heap.internKnown("héllo", .{ .cp_len = 5 });
    try testing.expectEqual(@as(usize, 5), f.cpLen());
    try testing.expect(!f.isAscii());
    const g = try heap.internKnown("abc", .{ .ascii = true });
    try testing.expectEqual(@as(usize, 3), g.cpLen());
    try testing.expect(g.isAscii());
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
            // Dense exactly when its sparse bucket is marked (doc 28 §5).
            try testing.expectEqual(heap.strtabHash(cur.bytes()), cur.hash);
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
            // An unmarked bucket holds no group the long-chain guard would
            // have promoted (`strtab_max_ident`'s bound).
            if (heap.strtab_any_dense and heap.bucketDense(heap.strtab_dense, idx)) continue;
            var twins: usize = 0;
            var t = head;
            while (t) |o| : (t = o.next_intern) {
                if (o.hash == cur.hash and o.len == cur.len) twins += 1;
            }
            try testing.expect(twins <= Heap.strtab_max_coll / 2 + 1);
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
    const want_bucket = string.sparseHash("c0") & mask;
    var namebuf: [16]u8 = undefined;
    while (nfound < 4) : (i += 1) {
        const name = std.fmt.bufPrint(&namebuf, "c{d}", .{i}) catch unreachable;
        if (string.sparseHash(name) & mask != want_bucket) continue;
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

/// The longest intern chain (test-only).
fn strtabMaxChain(heap: *const Heap) usize {
    var most: usize = 0;
    for (heap.strtab) |head| {
        var n: usize = 0;
        var s = head;
        while (s) |cur| : (s = cur.next_intern) n += 1;
        most = @max(most, n);
    }
    return most;
}

/// `n` 64-byte strings that differ only in bytes 40..43, which
/// `string.sparseHash` never reads at that length (it reads 0..7, 15..18,
/// 30..33 and 56..63), so all of them share one sparse hash.
fn sparseColliders(buf: *[64]u8, i: usize) []const u8 {
    @memset(buf, 'p');
    std.mem.writeInt(u32, buf[40..44], @intCast(i), .little);
    return buf;
}

test "doc 28 §5: sparse collisions intern exactly, and their chain is rehashed densely" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    const h = string.sparseHash(sparseColliders(&buf, 0));
    try testing.expectEqual(h, string.sparseHash(sparseColliders(&buf, 199)));

    var ptrs: [200]*String = undefined;
    for (&ptrs, 0..) |*p, i| p.* = try heap.intern(sparseColliders(&buf, i));
    // Distinct bytes, distinct objects; the same bytes, the same object.
    for (ptrs, 0..) |p, i| {
        try testing.expectEqualSlices(u8, sparseColliders(&buf, i), p.bytes());
        try testing.expectEqual(p, try heap.intern(sparseColliders(&buf, i)));
        if (i > 0) try testing.expect(p != ptrs[i - 1]);
    }
    try testing.expect(heap.strtab_any_dense);
    // One chain would hold all 200; the guard keeps every chain short.
    try testing.expect(strtabMaxChain(&heap) <= Heap.strtab_max_coll + 2);
    try strtabCheckIntegrity(&heap);

    // A grow re-decides the marks for the new geometry.
    var name: [16]u8 = undefined;
    for (0..1500) |i| _ = try heap.intern(std.fmt.bufPrint(&name, "g{d}", .{i}) catch unreachable);
    try testing.expect(heap.strtab.len > Heap.strtab_min_size);
    try testing.expect(heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
    for (ptrs, 0..) |p, i| try testing.expectEqual(@as(?*String, p), heap.internedLookup(sparseColliders(&buf, i)));

    // The sweep re-decides the marks for the survivors: two colliders are
    // no group, so they hash sparsely again.
    try collectWithRoots(&heap, &.{ &ptrs[3].header, &ptrs[150].header });
    try testing.expect(!heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
    try testing.expectEqual(@as(?*String, ptrs[3]), heap.internedLookup(sparseColliders(&buf, 3)));
    try testing.expectEqual(@as(?*String, ptrs[150]), heap.internedLookup(sparseColliders(&buf, 150)));
    try testing.expectEqual(@as(?*String, null), heap.internedLookup(sparseColliders(&buf, 4)));
}

test "doc 28 §5: a miss counts twice a string whose bytes it compared, as lj_str_new does" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    _ = try heap.intern(sparseColliders(&buf, 0));
    _ = try heap.intern(sparseColliders(&buf, 1));
    // Fill the colliders' chain to 31 with strings of other hashes.
    const mask = heap.strtab.len - 1;
    const bucket = string.sparseHash(sparseColliders(&buf, 0)) & mask;
    var name: [16]u8 = undefined;
    var i: usize = 0;
    var chain: usize = 2;
    while (chain < 31) : (i += 1) {
        const n = std.fmt.bufPrint(&name, "c{d}", .{i}) catch unreachable;
        if (string.sparseHash(n) & mask != bucket) continue;
        _ = try heap.intern(n);
        chain += 1;
    }
    try testing.expectEqual(@as(usize, 31), strtabMaxChain(&heap));
    try testing.expect(!heap.strtab_any_dense);
    // The third collider passes 31 strings and compares two: 33.
    _ = try heap.intern(sparseColliders(&buf, 2));
    try testing.expect(heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
}

/// Intern the colliders `0..n` again. The one last in their chain compares
/// the others first, so with more than `strtab_max_ident` of them a hit
/// promotes the group.
fn hitColliders(heap: *Heap, buf: *[64]u8, n: usize) !void {
    for (0..n) |i| _ = try heap.intern(sparseColliders(buf, i));
}

test "doc 28 §5.1: a hit that compares four look-alikes first rehashes their chain" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    var group: [Heap.strtab_max_ident + 1]*String = undefined;
    for (&group, 0..) |*g, i| g.* = try heap.intern(sparseColliders(&buf, i));
    // Misses do not count look-alikes.
    try testing.expect(!heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
    // The newest is first in the chain: its hit compares nothing.
    try testing.expectEqual(group[group.len - 1], try heap.intern(sparseColliders(&buf, group.len - 1)));
    try testing.expect(!heap.strtab_any_dense);
    // A read-only probe never promotes.
    try testing.expectEqual(@as(?*String, group[0]), heap.internedLookup(sparseColliders(&buf, 0)));
    try testing.expect(!heap.strtab_any_dense);
    // The oldest is last: its hit compares the other four, and promotes.
    try testing.expectEqual(group[0], try heap.intern(sparseColliders(&buf, 0)));
    try testing.expect(heap.strtab_any_dense);
    for (group) |g| try testing.expect(string.isDense(g.hash));
    try strtabCheckIntegrity(&heap);
    for (group, 0..) |g, i| try testing.expectEqual(g, try heap.intern(sparseColliders(&buf, i)));
}

test "doc 28 §5.1: misses alone let a group grow to strtab_max_coll / 2 + 1" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    const bound = Heap.strtab_max_coll / 2 + 1;
    for (0..bound) |i| _ = try heap.intern(sparseColliders(&buf, i));
    try testing.expect(!heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
    const next = try heap.intern(sparseColliders(&buf, bound));
    try testing.expect(heap.strtab_any_dense);
    try testing.expect(string.isDense(next.hash));
    try strtabCheckIntegrity(&heap);
}

test "doc 28 §5.1: a group of four never promotes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    for (0..Heap.strtab_max_ident) |i| _ = try heap.intern(sparseColliders(&buf, i));
    try hitColliders(&heap, &buf, Heap.strtab_max_ident);
    try hitColliders(&heap, &buf, Heap.strtab_max_ident);
    try testing.expect(!heap.strtab_any_dense);
}

test "doc 28 §5: a rebuild keeps a same-hash group dense while it is larger than strtab_max_ident" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    var group: [Heap.strtab_max_ident + 1]*String = undefined;
    for (&group, 0..) |*g, i| g.* = try heap.intern(sparseColliders(&buf, i));
    try hitColliders(&heap, &buf, group.len);
    try testing.expect(heap.strtab_any_dense);

    // A grow: five strings, far under strtab_max_coll, yet still dense.
    var name: [16]u8 = undefined;
    var keep: [1500]*String = undefined;
    for (&keep, 0..) |*k, i| k.* = try heap.intern(std.fmt.bufPrint(&name, "g{d}", .{i}) catch unreachable);
    try testing.expect(heap.strtab.len > Heap.strtab_min_size);
    try testing.expect(heap.strtab_any_dense);
    for (group) |g| try testing.expect(string.isDense(g.hash));
    try strtabCheckIntegrity(&heap);

    // Five survive a collection: the sweep's rebuild keeps them dense.
    var roots: [Heap.strtab_max_ident + 1]*GcHeader = undefined;
    for (&roots, 0..) |*r, i| r.* = &group[i].header;
    try collectWithRoots(&heap, &roots);
    try testing.expect(heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);

    // Four survive, so the sweep hashes them sparsely again; with a fifth,
    // hits promote them once more.
    try collectWithRoots(&heap, roots[0..Heap.strtab_max_ident]);
    try testing.expect(!heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
    for (group[0..Heap.strtab_max_ident], 0..) |g, i| try testing.expectEqual(@as(?*String, g), heap.internedLookup(sparseColliders(&buf, i)));
    _ = try heap.intern(sparseColliders(&buf, Heap.strtab_max_ident));
    try testing.expect(!heap.strtab_any_dense);
    try hitColliders(&heap, &buf, group.len);
    try testing.expect(heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
}

test "doc 28 §5.1: the sweep keeps a crowd's mark and drops a dead group's, without resizing" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    // A group of five, then a crowd of more than strtab_max_coll strings
    // whose sparse hashes differ but name one bucket.
    var group: [Heap.strtab_max_ident + 1]*String = undefined;
    for (&group, 0..) |*g, i| g.* = try heap.intern(sparseColliders(&buf, i));
    try hitColliders(&heap, &buf, group.len);
    const mask = heap.strtab.len - 1;
    const bucket = string.sparseHash("c0") & mask;
    // The 34th walks past 33: the guard marks the bucket.
    var crowd: [Heap.strtab_max_coll + 2]*String = undefined;
    var name: [16]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (n < crowd.len) : (i += 1) {
        const c = std.fmt.bufPrint(&name, "c{d}", .{i}) catch unreachable;
        if (string.sparseHash(c) & mask != bucket) continue;
        crowd[n] = try heap.intern(c);
        n += 1;
    }
    try testing.expect(string.isDense(crowd[crowd.len - 1].hash));
    try testing.expect(string.isDense(group[0].hash));
    const len = heap.strtab.len;

    // The group dies, the crowd lives: only the crowd's bucket stays marked.
    var roots: [crowd.len]*GcHeader = undefined;
    for (&roots, crowd) |*r, c| r.* = &c.header;
    try collectWithRoots(&heap, &roots);
    try testing.expectEqual(len, heap.strtab.len);
    try testing.expect(heap.strtab_any_dense);
    try testing.expect(heap.bucketDense(heap.strtab_dense, bucket));
    try testing.expect(!heap.bucketDense(heap.strtab_dense, string.sparseHash(sparseColliders(&buf, 0)) & mask));
    for (crowd) |c| try testing.expect(string.isDense(c.hash));
    try strtabCheckIntegrity(&heap);

    // Half the crowd dies: what is left hashes sparsely again.
    try collectWithRoots(&heap, roots[0 .. crowd.len / 2]);
    try testing.expect(!heap.strtab_any_dense);
    for (crowd[0 .. crowd.len / 2]) |c| try testing.expect(!string.isDense(c.hash));
    try strtabCheckIntegrity(&heap);
}

test "doc 28 §5.1: without scratch, the sweep keeps the dense survivors dense" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var heap = Heap.init(failing.allocator());
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    var group: [Heap.strtab_max_ident]*String = undefined;
    for (&group, 0..) |*g, i| g.* = try heap.intern(sparseColliders(&buf, i));
    _ = try heap.intern(sparseColliders(&buf, Heap.strtab_max_ident));
    try hitColliders(&heap, &buf, Heap.strtab_max_ident + 1);
    try testing.expect(heap.strtab_any_dense);

    // Four of the five survive, too few to need the mark, but the sweep
    // cannot allocate its scratch: they stay dense, still valid.
    var roots: [group.len]*GcHeader = undefined;
    for (&roots, group) |*r, g| r.* = &g.header;
    try heap.beginCollect();
    for (roots) |r| heap.markHeader(r);
    heap.traceAll();
    failing.fail_index = failing.alloc_index;
    heap.sweep();
    failing.fail_index = std.math.maxInt(usize);
    try testing.expect(heap.strtab_any_dense);
    for (group) |g| try testing.expect(string.isDense(g.hash));
    try strtabCheckIntegrity(&heap);
    for (group, 0..) |g, k| try testing.expectEqual(@as(?*String, g), heap.internedLookup(sparseColliders(&buf, k)));

    // The next sweep has its scratch and drops the mark.
    try collectWithRoots(&heap, &roots);
    try testing.expect(!heap.strtab_any_dense);
    try strtabCheckIntegrity(&heap);
}

test "doc 28 §5: once the colliders are gone, the next rebuild hashes sparsely again" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [64]u8 = undefined;
    for (0..100) |i| _ = try heap.intern(sparseColliders(&buf, i));
    try testing.expect(heap.strtab_any_dense);
    try collectWithRoots(&heap, &.{});
    try testing.expect(!heap.strtab_any_dense);
    var name: [16]u8 = undefined;
    var keep: [1500]*String = undefined;
    for (&keep, 0..) |*k, i| k.* = try heap.intern(std.fmt.bufPrint(&name, "g{d}", .{i}) catch unreachable);
    try testing.expect(!heap.strtab_any_dense);
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

test "doc 80: a string past nominal_object_bytes charges its bytes to pacing, and the sweep refunds them" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const before = heap.next_gc;

    var buf: [3 * nominal_object_bytes + 5]u8 = undefined;
    @memset(&buf, 'x');
    _ = try heap.intern(buf[0 .. nominal_object_bytes - 1]); // too short to charge
    try testing.expectEqual(@as(usize, 0), heap.string_debt);
    _ = try heap.intern(&buf); // 3 units
    try testing.expectEqual(@as(usize, 3), heap.string_debt);
    try testing.expectEqual(before - 3, heap.next_gc);
    // An intern hit links nothing and charges nothing.
    _ = try heap.intern(&buf);
    try testing.expectEqual(@as(usize, 3), heap.string_debt);
    try testing.expect(heap.gc_headroom == @as(i64, @intCast(heap.next_gc)) - @as(i64, @intCast(heap.object_count)));

    // Nothing is rooted: the sweep frees both and the debt with them.
    try heap.beginCollect();
    heap.traceAll();
    heap.sweep();
    try testing.expectEqual(@as(usize, 0), heap.string_debt);
    try testing.expectEqual(@as(usize, initial_gc_threshold), heap.next_gc);
    try testing.expectEqual(@as(u64, 1), heap.collections);
}

test "doc 68 §7.4: a byte buffer charges its used bytes as it grows, a rooted one survives, the sweep refunds" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var list: std.ArrayList(u8) = .empty;
    try list.appendNTimes(heap.gpa, 'a', nominal_object_bytes - 1);
    const base_objects = heap.object_count;
    const b = try heap.newByteBuf(list);
    try testing.expectEqual(@as(usize, 0), heap.string_debt);
    try testing.expectEqual(base_objects + 1, heap.object_count);

    // Growth charges the difference only, however the capacity moved.
    try b.list.appendNTimes(heap.gpa, 'b', 2 * nominal_object_bytes + 1);
    heap.chargeByteBuf(b);
    try testing.expectEqual(@as(usize, 3), heap.string_debt);
    heap.chargeByteBuf(b);
    try testing.expectEqual(@as(usize, 3), heap.string_debt);
    try testing.expectEqual(@as(usize, 3), b.charged);
    try testing.expectEqualStrings("a", b.bytes()[0..1]);

    // Rooted, it survives a collection with its charge; unrooted, the sweep
    // frees it and refunds exactly what it paid.
    try collectWithRoots(&heap, &.{&b.header});
    try testing.expectEqual(@as(usize, 3), heap.string_debt);
    try testing.expectEqual(base_objects + 1, heap.object_count);
    try collectWithRoots(&heap, &.{});
    try testing.expectEqual(@as(usize, 0), heap.string_debt);
    try testing.expectEqual(base_objects, heap.object_count);
}

test "doc 80 §3: an armed intern links a charged string only when no collection can come due" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [10 * nominal_object_bytes]u8 = undefined;
    @memset(&buf, 'y');

    heap.setGcTarget(heap.object_count + 20);
    heap.trace_alloc_bound = 5;
    heap.trace_callout = true;
    // object_count + A + 10 units = 15 < 20: linked and charged.
    _ = try heap.intern(&buf);
    try testing.expect(!heap.trace_charge_refused);
    try testing.expectEqual(@as(usize, 10), heap.string_debt);
    // Now 1 + 5 + 10 >= next_gc (10): refused before anything is linked.
    const count = heap.object_count;
    const id = heap.next_obj_id;
    try testing.expectError(error.OutOfMemory, heap.intern(buf[1..]));
    try testing.expect(heap.trace_charge_refused);
    try testing.expectEqual(count, heap.object_count);
    try testing.expectEqual(id, heap.next_obj_id);
    try testing.expectEqual(@as(usize, 10), heap.string_debt);
    // A string too short to charge is never refused.
    _ = try heap.intern(buf[0..10]);
    // Unarmed (tier-0), the same intern links and charges.
    heap.trace_callout = false;
    _ = try heap.intern(buf[1..]);
    try testing.expectEqual(@as(usize, 19), heap.string_debt);
    try testing.expect(heap.shouldCollect());
}

test "doc 80 §4: internBuilt links a new string, and frees the built copy of one already interned" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var big: [2 * nominal_object_bytes]u8 = undefined;
    @memset(&big, 'z');

    var b = try String.Builder.init(testing.allocator, big.len + 3);
    defer b.deinit(testing.allocator);
    b.append(&big, big.len, true);
    b.append("abc", 3, true);
    const count = heap.object_count;
    const s = try heap.internBuilt(&b);
    try testing.expectEqual(count + 1, heap.object_count);
    try testing.expectEqual(@as(usize, 2), heap.string_debt);
    try testing.expectEqual(big.len + 3, s.len);
    // The same bytes through the plain intern find the built string.
    var flat: [big.len + 3]u8 = undefined;
    @memcpy(flat[0..big.len], &big);
    @memcpy(flat[big.len..], "abc");
    try testing.expectEqual(s, try heap.intern(&flat));

    // Built again: the existing object comes back, nothing is linked or
    // charged, and the built copy is freed (testing.allocator would report
    // it leaked).
    var again = try String.Builder.init(testing.allocator, flat.len);
    defer again.deinit(testing.allocator);
    again.append(&flat, flat.len, true);
    try testing.expectEqual(s, try heap.internBuilt(&again));
    try testing.expectEqual(count + 1, heap.object_count);
    try testing.expectEqual(@as(usize, 2), heap.string_debt);
}

test "doc 80 §4: internBuilt under an armed callout refuses a charge as intern does" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var buf: [10 * nominal_object_bytes]u8 = undefined;
    @memset(&buf, 'q');
    heap.setGcTarget(heap.object_count + 12);
    heap.trace_alloc_bound = 5;
    heap.trace_callout = true;
    var b = try String.Builder.init(testing.allocator, buf.len);
    defer b.deinit(testing.allocator);
    b.append(&buf, buf.len, true);
    const count = heap.object_count;
    try testing.expectError(error.OutOfMemory, heap.internBuilt(&b));
    try testing.expect(heap.trace_charge_refused);
    try testing.expectEqual(count, heap.object_count);
    try testing.expectEqual(@as(usize, 0), heap.string_debt);
}

test "shouldCollect honours the stress knob and the threshold" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    try testing.expect(!heap.shouldCollect()); // empty, below threshold
    heap.setGcStress(true);
    try testing.expect(heap.shouldCollect());
    heap.setGcStress(false);
    heap.setGcTarget(1);
    _ = try heap.intern("x");
    try testing.expect(heap.shouldCollect()); // count (1) >= next_gc (1)
}

test "the countdown gate tracks the trigger through allocation, deferral, stress and sweep" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    heap.setGcTarget(heap.object_count + 2);
    _ = try heap.intern("a");
    try testing.expect(!heap.shouldCollect());
    _ = try heap.intern("b");
    try testing.expect(heap.shouldCollect()); // count reached next_gc
    // A deferred collection (pending multret, skipped cycle) keeps counting
    // below zero and stays due.
    _ = try heap.intern("c");
    try testing.expectEqual(@as(i64, -1), heap.gc_headroom);
    try testing.expect(heap.shouldCollect());
    // Clearing stress re-derives from the counters, so it stays due.
    heap.setGcStress(true);
    heap.setGcStress(false);
    try testing.expect(heap.shouldCollect());
    // Nothing is rooted: the sweep frees everything and re-arms the
    // countdown at the floor threshold.
    try heap.beginCollect();
    heap.traceAll();
    heap.sweep();
    try testing.expectEqual(@as(usize, 0), heap.object_count);
    try testing.expectEqual(@as(i64, initial_gc_threshold), heap.gc_headroom);
    try testing.expect(!heap.shouldCollect());
    // Stress forces it due with headroom to spare, and allocating under
    // stress never brings it back.
    heap.setGcStress(true);
    _ = try heap.intern("d");
    try testing.expect(heap.shouldCollect());
    heap.setGcStress(false);
    try testing.expect(!heap.shouldCollect());
    // A restored threshold past i64 saturates instead of wrapping.
    heap.setGcTarget(std.math.maxInt(usize));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), heap.gc_headroom);
    try testing.expect(!heap.shouldCollect());
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
