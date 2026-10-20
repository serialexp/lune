//! The owned hash part (doc 49) — mahina's replacement for the
//! `std.HashMapUnmanaged` that used to back `Table.hash`.
//!
//! Why it exists: the tracing JIT's HREFK lowering (doc 49) must read the hash
//! part's nodes/mask inline from native code. The std map keeps keys, values,
//! and capacity behind a **private `Header` decl** with unspecified field
//! order — unreachable for `@offsetOf` and a churn hazard (Rule Z-1). This map
//! is `extern`-layout end to end: every offset the JIT needs is a comptime
//! fact of our own types.
//!
//! Shape (LuaJIT `lj_tab.c` heritage, adapted to open addressing):
//! - **Interleaved nodes** `{key, value}` (32 B) in one power-of-2 array — a
//!   field access touches one cacheline, not the std map's SoA two-to-three.
//! - **Linear probing**, `idx = hash & mask`, step 1. No metadata/fingerprint
//!   array in v1 (doc 49 P1b measures that choice).
//! - **Lua-style deletion**: removing a key nils the *value* and keeps the
//!   node until the next rehash squeezes it. Free ⇔ nil KEY; dead ⇔ live key
//!   tag + nil VALUE. Delete/reinsert of the same key resurrects the same
//!   slot, which is what keeps HREFK slot pins stable through
//!   `t.x = nil; t.x = 1.5` churn.
//! - **Dead heap keys hold no pointer**: on removal the key payload is
//!   zeroed; the stable `GcHeader.id` stays in `key_id` and the tag is
//!   preserved (doc 62 §3.2). GC marks live nodes only; a deleted key's object graph is
//!   collectable immediately and a later probe can never dereference a stale
//!   pointer. Dead-node key storage is internal — it is never exposed through
//!   the logical API as a `Value`.
//!
//! Determinism: the layout is a pure function of the deterministic `keyHash`
//! (heap keys hash by stable id, never address) and the guest's
//! insertion/deletion history — identical in all 8 modes and across
//! independent runs. Keyframe restore reconstructs the map logically
//! (canonical order), so physical layout may differ across the restore
//! boundary; that divergence is declared permissible (doc 49 §Determinism).
//!
//! Allocator-injected (Rule Z-4): every growing operation takes a `gpa`; the
//! struct never caches one.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// Deterministic key hash — moved here from `table.ValueContext` (doc 49);
/// `ValueContext.hash` now delegates to this. A fixed-width splitmix64-style
/// avalanche over `(tag, payload-or-heap-id)`: the key is always 1 tag byte +
/// 8 payload bytes, so there is nothing to *stream* (the old per-lookup
/// `Wyhash.final` was ~45–57% of table-heavy benchmark runtime).
///
/// Determinism: a pure function of `(tag, payload)`, identical in all 8 modes
/// and on replay. Heap keys hash by their stable, deterministic object `id`,
/// NOT `payload.bits` (an ASLR-dependent address) — consistent with
/// `Value.eql`: equal heap keys are the same interned object, same id.
/// Distribution quality is a performance concern only, never correctness
/// (the probe still compares the full identity: `Ident.matches`).
pub fn keyHash(v: Value) u64 {
    const payload: u64 = if (v.isHeap()) v.asHeap().id else v.payload.bits;
    return mixHash(v.tag, payload);
}

fn mixHash(tag: value.Tag, payload: u64) u64 {
    var x = payload ^ (@as(u64, @intFromEnum(tag)) *% 0x9E3779B97F4A7C15);
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return x ^ (x >> 31);
}

/// One slot: key + value, interleaved so a field access reads one cacheline.
/// All-zero bytes are a FREE node (`Tag.nil == 0`, zero payload, zero pad), so
/// a fresh array is a single `@memset`.
///
/// The key is stored as a `Value`'s tag and payload, with the key's identity
/// in the bytes a `Value` leaves as padding. A heap key's identity is its
/// `GcHeader.id`, the same identity `Value.eql` compares. Keeping it in the
/// node lets a probe match keys without loading the key object's header:
/// one header load per lookup (the key being looked up) instead of two per
/// probed slot.
pub const Node = extern struct {
    key_tag: value.Tag,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Heap keys: `GcHeader.id`, live or dead. Scalar keys: 0.
    key_id: u32,
    /// Live heap keys: the object pointer (GC marks through it). Dead heap
    /// keys: 0, so a dead node holds no pointer. Scalar keys: the raw bits.
    key_payload: value.Payload,
    value: Value,

    /// The key as a `Value`. Live nodes only: a dead heap key has no pointer.
    pub fn key(n: *const Node) Value {
        return .{ .tag = n.key_tag, .payload = n.key_payload };
    }

    fn isFree(n: *const Node) bool {
        return n.key_tag == .nil;
    }

    fn setKey(n: *Node, k: Value, ident: Ident) void {
        n.key_tag = k.tag;
        n._pad = .{ 0, 0, 0 };
        n.key_id = ident.id;
        n.key_payload = k.payload;
    }

    /// The `keyHash` of this node's key, from the stored identity (no header
    /// load).
    fn hash(n: *const Node) u64 {
        const payload: u64 = if (n.key_tag == .heap_ref) n.key_id else n.key_payload.bits;
        return mixHash(n.key_tag, payload);
    }
};

comptime {
    std.debug.assert(@sizeOf(Node) == 32);
    std.debug.assert(@offsetOf(Node, "key_tag") == @offsetOf(Value, "tag"));
    std.debug.assert(@offsetOf(Node, "key_id") == 4);
    std.debug.assert(@offsetOf(Node, "key_payload") == @offsetOf(Value, "payload"));
    std.debug.assert(@offsetOf(Node, "value") == 16);
    // The all-zero-bytes-is-free invariant: nil is tag ordinal 0.
    std.debug.assert(@intFromEnum(value.Tag.nil) == 0);
}

/// A key's identity as a probe compares it, computed once per lookup: the
/// tag plus the stable id (heap keys) or the raw payload bits (scalars).
/// Equal identity is exactly `Value.eql` for the keys a hash part holds:
/// heap keys compare by id in both; integral floats are normalized to ints
/// and NaN is never a key (`Table.set` / `normalizeKey`), so equal numbers
/// have equal bits.
const Ident = struct {
    tag: value.Tag,
    id: u32,
    bits: u64,

    fn of(k: Value) Ident {
        std.debug.assert(k.tag != .row_view);
        if (k.isHeap()) return .{ .tag = k.tag, .id = k.asHeap().id, .bits = 0 };
        return .{ .tag = k.tag, .id = 0, .bits = k.payload.bits };
    }

    /// Does the (non-free) node's key have this identity? Live or dead.
    inline fn matches(self: Ident, n: *const Node) bool {
        if (n.key_tag != self.tag) return false;
        return if (self.tag == .heap_ref) n.key_id == self.id else n.key_payload.bits == self.bits;
    }

    fn hash(self: Ident) u64 {
        return mixHash(self.tag, if (self.tag == .heap_ref) self.id else self.bits);
    }
};

/// One key of `next`'s sorted view: its identity (as `Ident`) and its slot.
/// Ordered exactly as `key_order.keyLessThan` orders keys (tag ordinal, then
/// heap id, else payload bits), from the stored identity, so a dead heap key
/// needs no pointer.
const IterKey = extern struct {
    tag: value.Tag,
    _pad: [3]u8 = .{ 0, 0, 0 },
    id: u32,
    bits: u64,
    /// The key's node; valid while the view is (`HashPart.nextLive`).
    /// Unused (0) for a control value built by `of`.
    slot: u32 = 0,

    /// Any value, including one no table can hold as a key (a `row_view`
    /// passed to `next` as the control): it still orders as `keyLessThan`
    /// orders it.
    fn of(k: Value) IterKey {
        if (k.isHeap()) return .{ .tag = k.tag, .id = k.asHeap().id, .bits = 0 };
        return .{ .tag = k.tag, .id = 0, .bits = k.payload.bits };
    }

    /// Does node `n` (live or dead) hold this key? The stable-slot invariant.
    fn names(k: IterKey, n: *const Node) bool {
        if (n.key_tag != k.tag) return false;
        return if (k.tag == .heap_ref) n.key_id == k.id else n.key_payload.bits == k.bits;
    }

    /// Same key: the slot is not part of the identity.
    fn eql(a: IterKey, b: IterKey) bool {
        return a.tag == b.tag and a.id == b.id and a.bits == b.bits;
    }

    fn lessThan(a: IterKey, b: IterKey) bool {
        if (a.tag != b.tag) return @intFromEnum(a.tag) < @intFromEnum(b.tag);
        return if (a.tag == .heap_ref) a.id < b.id else a.bits < b.bits;
    }

    fn less(_: void, a: IterKey, b: IterKey) bool {
        return a.lessThan(b);
    }
};

/// The alignment of the node array: 32, so a 32-byte node never straddles a
/// 64-byte cacheline.
pub const node_align: std.mem.Alignment = .@"32";

pub const HashPart = extern struct {
    /// Single allocation, `capacity` (= `mask + 1`, power of 2) nodes,
    /// 32-aligned. `null` ⇔ the map has never held an entry (mask 0).
    nodes: ?[*]align(32) Node = null,
    /// capacity − 1; 0 when `nodes == null`. The JIT's hrefk mask guard reads
    /// this field (`cmp dword [tbl + HASH_MASK_OFF], K`).
    mask: u32 = 0,
    /// Entries with a live (non-nil) value — the `count()` answer, and the
    /// field `guard_hash`/`guard_absent` native sequences compare
    /// (`ArrLayout.hash_size` points here).
    live: u32 = 0,
    /// Occupied slots: live + dead. Drives the load test.
    used: u32 = 0,
    /// `next`'s view of the keys (`nextLive`): the identities and slots of
    /// the live keys, sorted into the canonical order. Built on the first
    /// step of a traversal, kept for later traversals of the unchanged
    /// table, and dropped by a collection. No pointers, so the GC never
    /// needs to mark it.
    iter_keys: ?[*]IterKey = null,
    iter_len: u32 = 0,
    iter_cap: u32 = 0,
    /// Index in the view of the key `nextLive` returned last.
    iter_pos: u32 = 0,
    /// Cleared when a key becomes live. Removal leaves it set: a removed
    /// key's node stays (dead) until a rehash, and a rehash only follows an
    /// insertion, so `nextLive` skips it by its identity.
    iter_valid: bool = false,
    /// Sorts performed, so tests can count them.
    iter_builds: u32 = 0,

    pub const empty: HashPart = .{};
    pub const min_capacity: u32 = 4;

    pub const Entry = struct { key: Value, value_ptr: *Value };

    // ------------------------------------------------------------------
    // Logical layer — the std-map-shaped contract `table.zig` and the
    // external call sites consume. Dead nodes are ABSENT here.
    // ------------------------------------------------------------------

    pub fn count(self: *const HashPart) u32 {
        return self.live;
    }

    pub fn capacity(self: *const HashPart) u32 {
        return if (self.nodes == null) 0 else self.mask + 1;
    }

    pub fn deinit(self: *HashPart, gpa: std.mem.Allocator) void {
        if (self.nodes) |n| gpa.free(n[0 .. self.mask + 1]);
        self.dropIterCache(gpa);
        self.* = .empty;
    }

    pub fn get(self: *const HashPart, key: Value) ?Value {
        const idx = self.liveSlotOf(key) orelse return null;
        return self.nodes.?[idx].value;
    }

    pub fn getPtr(self: *const HashPart, key: Value) ?*Value {
        const idx = self.liveSlotOf(key) orelse return null;
        return &self.nodes.?[idx].value;
    }

    pub fn contains(self: *const HashPart, key: Value) bool {
        return self.liveSlotOf(key) != null;
    }

    /// `get` through a slot hint the caller keeps per lookup site (the
    /// interpreter's global-access cache). The hinted slot is used only if it
    /// holds `key`'s identity with a live value; otherwise the normal probe
    /// runs and the hint is moved to where `key` was found. Always the same
    /// result as `get`: the hint can be stale, out of range, or from another
    /// table, and only the cost changes.
    pub fn getHinted(self: *const HashPart, key: Value, hint: *u32) ?Value {
        const ident = Ident.of(key);
        if (self.hintedNode(hint.*)) |n| {
            if (ident.matches(n) and !n.value.isNil()) return n.value;
        }
        const idx = self.liveSlotOfIdent(ident, key) orelse return null;
        hint.* = idx;
        return self.nodes.?[idx].value;
    }

    /// The hit half of `getHinted` for a heap key, inlined into the caller and
    /// calling nothing: the value if the hinted slot holds `key` live, else
    /// null, which means "not known here", not "absent" (the caller then
    /// takes `getHinted`). For the interpreter's global access, where a
    /// global's name is an interned string.
    pub inline fn heapHintHit(self: *const HashPart, key: Value, hint: u32) ?Value {
        if (!key.isHeap()) return null;
        const n = self.hintedNode(hint) orelse return null;
        if (n.key_tag != .heap_ref or n.key_id != key.asHeap().id or n.value.isNil()) return null;
        return n.value;
    }

    /// The node holding heap key `key` live, or null when `key` is absent
    /// (no node, or only a dead one). The probe of `liveSlotOf`, specialised
    /// to a heap key and inlined into the interpreter's `get_index` and
    /// `set_index`, where it calls nothing. A heap key matches by id alone.
    pub inline fn liveHeapNode(self: *const HashPart, key: Value) ?*Node {
        std.debug.assert(key.isHeap());
        return self.liveNodeInline(.heap_ref, key.asHeap().id);
    }

    /// `liveHeapNode` for an integer key (one outside the array part).
    pub inline fn liveIntNode(self: *const HashPart, i: i64) ?*Node {
        return self.liveNodeInline(.int, @bitCast(i));
    }

    /// The inline probe behind `liveHeapNode` / `liveIntNode`: a key whose
    /// tag is known at compile time, identified by its heap id or its
    /// payload bits (`Ident`).
    inline fn liveNodeInline(self: *const HashPart, comptime tag: value.Tag, payload: u64) ?*Node {
        const nodes = self.nodes orelse return null;
        const mask = self.mask;
        var idx: u32 = @truncate(mixHash(tag, payload) & mask);
        var limit: u64 = @as(u64, mask) + 1;
        while (limit != 0) : (limit -= 1) {
            const n = &nodes[idx];
            if (n.isFree()) return null; // chain ends
            const same = n.key_tag == tag and if (tag == .heap_ref) n.key_id == payload else n.key_payload.bits == payload;
            if (same) {
                // A dead match proves logical absence.
                return if (n.value.isNil()) null else n;
            }
            idx = (idx + 1) & mask;
        }
        return null;
    }

    /// The node a hint names, or null when the map has no nodes or the hint
    /// is out of range (a hint can come from an earlier, larger layout, or
    /// from another table). Indexes through a slice so a safe build would
    /// catch an out-of-range read if the range test ever went wrong.
    inline fn hintedNode(self: *const HashPart, hint: u32) ?*Node {
        const nodes = self.nodes orelse return null;
        const all = nodes[0 .. @as(usize, self.mask) + 1];
        if (hint >= all.len) return null;
        return &all[hint];
    }

    /// Overwrite the value of a key already live at the hinted slot. Returns
    /// false (and changes nothing) when the hint misses or `val` is nil; the
    /// caller then takes the full store path. When it returns true the map is
    /// exactly as `put` would have left it: `put` on a live key only
    /// overwrites the value.
    pub fn setExistingHinted(self: *HashPart, key: Value, val: Value, hint: u32) bool {
        if (val.isNil()) return false;
        const n = self.hintedNode(hint) orelse return false;
        if (!Ident.of(key).matches(n) or n.value.isNil()) return false;
        n.value = val;
        return true;
    }

    /// Insert or overwrite. `val` must be non-nil (deletion goes through
    /// `remove` — a nil put would silently mint a dead entry and corrupt the
    /// live/used invariants); `key` must be non-nil, non-NaN-float (callers
    /// normalise and reject upstream, `Table.set`), and never a `row_view`
    /// (its payload packs a parent POINTER, which would violate the
    /// dead-nodes-are-pointer-free contract; row views never persist in the
    /// heap — doc 49 codex round-2).
    pub fn put(self: *HashPart, gpa: std.mem.Allocator, key: Value, val: Value) std.mem.Allocator.Error!void {
        std.debug.assert(!val.isNil());
        std.debug.assert(!key.isNil());
        std.debug.assert(key.tag != .row_view);
        if (self.nodes == null) try self.rehashTo(gpa, min_capacity);
        const ident = Ident.of(key);
        while (true) {
            switch (self.probeForPut(ident)) {
                .live => |idx| {
                    self.nodes.?[idx].value = val;
                    return;
                },
                .resurrect => |idx| {
                    // Same logical key, dead node: restore the REAL key Value
                    // BEFORE publishing the non-nil value (contract: any node
                    // with a non-nil value holds a valid live key). No load
                    // test — occupancy does not grow, and slot stability
                    // through delete/reinsert is the point (doc 49).
                    const n = &self.nodes.?[idx];
                    n.setKey(key, ident);
                    n.value = val;
                    self.live += 1;
                    self.iter_valid = false;
                    return;
                },
                .reuse_dead => |idx| {
                    // New key, unrelated dead slot on its chain (scanned to
                    // the chain's free end first, so no duplicate exists).
                    // Occupancy does not grow → no load test.
                    const n = &self.nodes.?[idx];
                    n.setKey(key, ident);
                    n.value = val;
                    self.live += 1;
                    self.iter_valid = false;
                    return;
                },
                .free => |idx| {
                    // Genuinely free slot — the only case that grows `used`,
                    // so the only case that consults the load test (a
                    // resurrection at the threshold must NOT rehash away its
                    // slot — doc 49 codex round-2 item 3).
                    if (@as(u64, self.used) + 1 > loadLimit(self.mask + 1)) {
                        try self.grow(gpa);
                        continue; // fresh layout — re-probe
                    }
                    const n = &self.nodes.?[idx];
                    n.setKey(key, ident);
                    n.value = val;
                    self.live += 1;
                    self.used += 1;
                    self.iter_valid = false;
                    return;
                },
            }
        }
    }

    /// Remove a key. Lua-style: the node stays (dead) until the next rehash;
    /// a heap key's pointer is cleared (its id stays in `key_id`, which is
    /// what probes match on) so dead nodes hold no pointers. Returns true iff
    /// a live entry was removed.
    pub fn remove(self: *HashPart, key: Value) bool {
        const idx = self.liveSlotOf(key) orelse return false;
        const n = &self.nodes.?[idx];
        // Publication order (doc 49): value goes nil BEFORE the key loses its
        // pointer, so "non-nil value ⇒ valid live key" holds at every point.
        n.value = Value.nil();
        if (n.key_tag == .heap_ref) n.key_payload = .{ .bits = 0 };
        self.live -= 1;
        return true;
    }

    /// Iterate LIVE entries (dead and free nodes are skipped), in slot order.
    /// The key comes by value (a node stores it as tag, id and payload, not
    /// as a `Value`); the value by mutable pointer, like the std map's
    /// iterator. Mutating the map while iterating invalidates the iterator
    /// (also like the std map).
    pub const Iterator = struct {
        nodes: [*]Node,
        remaining: u32,

        pub fn next(it: *Iterator) ?Entry {
            while (it.remaining != 0) {
                const n = &it.nodes[0];
                it.nodes += 1;
                it.remaining -= 1;
                if (!n.isFree() and !n.value.isNil())
                    return .{ .key = n.key(), .value_ptr = &n.value };
            }
            return null;
        }
    };

    pub fn iterator(self: *const HashPart) Iterator {
        const nodes = self.nodes orelse return .{ .nodes = undefined, .remaining = 0 };
        // Const-launder like the std map: `iterator()` on a const map still
        // yields mutable entry pointers; the table object is genuinely
        // heap-mutable and `*const` is only this accessor's view.
        return .{ .nodes = @constCast(nodes), .remaining = self.mask + 1 };
    }

    /// The live entry after `ctrl` in the canonical key order (`key_order`:
    /// tag, then heap id, then payload bits), or the first live entry when
    /// `ctrl` is null; null past the last. This is `next`'s hash-part step.
    /// The successor is the first key strictly greater than `ctrl`, so `ctrl`
    /// need not be present: Lua lets a traversal delete the current key.
    ///
    /// Cost: one sort per key-set change (`buildIterCache`; also after a
    /// collection dropped the view), then one node read
    /// per step, plus a binary search when `ctrl` is not the key returned
    /// last (`iter_pos`). Sorting on every step made a traversal
    /// O(k² log k). The result never depends on the cache: it holds every
    /// live key (it is rebuilt when one is added), and a key removed since
    /// the build is skipped because its node is dead.
    ///
    /// The view records each key's slot. Slots don't move while the view is
    /// valid: only an insertion can rehash, and every insertion of a key
    /// invalidates the view (an overwrite neither rehashes nor invalidates).
    pub fn nextLive(self: *HashPart, gpa: std.mem.Allocator, ctrl: ?Value) std.mem.Allocator.Error!?Entry {
        if (self.live == 0) {
            self.dropIterCache(gpa);
            return null;
        }
        if (!self.iter_valid) try self.buildIterCache(gpa);
        const keys = self.iter_keys.?[0..self.iter_len];
        const nodes = self.nodes.?;
        var lo: usize = 0;
        if (ctrl) |c| {
            if (self.iter_pos < keys.len and self.isKeyAt(keys[self.iter_pos], c)) {
                // The usual step: `ctrl` is the key returned last.
                lo = self.iter_pos + 1;
            } else {
                const ck = IterKey.of(c);
                var hi: usize = keys.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (ck.lessThan(keys[mid])) hi = mid else lo = mid + 1;
                }
            }
        }
        while (lo < keys.len) : (lo += 1) {
            const n = &nodes[keys[lo].slot];
            std.debug.assert(keys[lo].names(n));
            if (n.value.isNil()) continue; // removed since the build
            self.iter_pos = @intCast(lo);
            return .{ .key = n.key(), .value_ptr = &n.value };
        }
        // Past the last key. The view stays for the next traversal; a
        // collection drops it (`gc.zig`, `blacken`).
        return null;
    }

    /// Is `c` the key of view entry `k`? First by the node's raw key bits,
    /// which needs no load of `c`'s object header (for a heap key the bits
    /// are its pointer). Then by identity, which also matches a dead node's
    /// key, or another object with the same id.
    inline fn isKeyAt(self: *const HashPart, k: IterKey, c: Value) bool {
        const n = &self.nodes.?[k.slot];
        if (n.key_tag == c.tag and n.key_payload.bits == c.payload.bits and !n.value.isNil()) return true;
        return IterKey.of(c).eql(k);
    }

    fn buildIterCache(self: *HashPart, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.iter_cap < self.live) {
            const keys = try gpa.alloc(IterKey, self.live);
            if (self.iter_keys) |old| gpa.free(old[0..self.iter_cap]);
            self.iter_keys = keys.ptr;
            self.iter_cap = self.live;
        }
        const keys = self.iter_keys.?[0..self.live];
        var i: usize = 0;
        for (self.nodes.?[0 .. self.mask + 1], 0..) |*n, slot| {
            if (n.isFree() or n.value.isNil()) continue;
            keys[i] = .{
                .tag = n.key_tag,
                .id = n.key_id,
                .bits = if (n.key_tag == .heap_ref) 0 else n.key_payload.bits,
                .slot = @intCast(slot),
            };
            i += 1;
        }
        std.debug.assert(i == self.live);
        // Keys are unique, so stability buys nothing (and the block sort
        // was the walk's largest cost).
        std.mem.sortUnstable(IterKey, keys, {}, IterKey.less);
        self.iter_len = self.live;
        self.iter_pos = 0;
        self.iter_valid = true;
        self.iter_builds +%= 1;
    }

    /// Free `next`'s view. Only the cost of the next traversal changes.
    pub fn dropIterCache(self: *HashPart, gpa: std.mem.Allocator) void {
        if (self.iter_keys) |keys| gpa.free(keys[0..self.iter_cap]);
        self.iter_keys = null;
        self.iter_len = 0;
        self.iter_cap = 0;
        self.iter_pos = 0;
        self.iter_valid = false;
    }

    // ------------------------------------------------------------------
    // Internal probe layer (doc 49): slot arithmetic for put/resurrect, the
    // recorder's hrefk slot capture, GC's live walk, and tests.
    // ------------------------------------------------------------------

    /// Slot of the LIVE node for `key`, or null (absent OR dead — a dead
    /// match proves logical absence and stops the probe: a key occupies at
    /// most one node, live or dead). This is the recorder's `hashSlotOf`
    /// backing: hrefk pins live slots only.
    pub fn liveSlotOf(self: *const HashPart, key: Value) ?u32 {
        return self.liveSlotOfIdent(Ident.of(key), key);
    }

    fn liveSlotOfIdent(self: *const HashPart, ident: Ident, key: Value) ?u32 {
        const nodes = self.nodes orelse return null;
        const mask = self.mask;
        var idx: u32 = @truncate(ident.hash() & mask);
        var limit: u64 = @as(u64, mask) + 1;
        while (limit != 0) : (limit -= 1) {
            const n = &nodes[idx];
            if (n.isFree()) return null; // chain ends
            if (ident.matches(n)) {
                // A dead match proves logical absence.
                if (n.value.isNil()) return null;
                if (std.debug.runtime_safety) std.debug.assert(n.key().eql(key));
                return idx;
            }
            idx = (idx + 1) & mask;
        }
        return null;
    }

    const PutSlot = union(enum) {
        live: u32, // live node with this key — overwrite
        resurrect: u32, // dead node with this key — resurrect in place
        reuse_dead: u32, // no node with this key; first dead slot on the chain
        free: u32, // no node with this key, no dead slot — genuinely free
    };

    /// Probe for `put`: scan the chain to its free end (so a live or dead
    /// match anywhere on it is found before any insertion decision), tracking
    /// the first dead slot for reuse. The chain always ends: `used` is capped
    /// strictly below capacity by the load test, so a free slot exists.
    fn probeForPut(self: *const HashPart, ident: Ident) PutSlot {
        const nodes = self.nodes.?;
        const mask = self.mask;
        var idx: u32 = @truncate(ident.hash() & mask);
        var first_dead: ?u32 = null;
        while (true) {
            const n = &nodes[idx];
            if (n.isFree()) {
                return if (first_dead) |d| .{ .reuse_dead = d } else .{ .free = idx };
            }
            const dead = n.value.isNil();
            if (ident.matches(n)) return if (dead) .{ .resurrect = idx } else .{ .live = idx };
            if (dead and first_dead == null) first_dead = idx;
            idx = (idx + 1) & mask;
        }
    }

    /// Max occupied slots (live + dead) for a capacity: 75% load.
    fn loadLimit(cap: u64) u64 {
        return cap * 3 / 4;
    }

    /// Grow (or shrink, after heavy deletion) to the smallest power-of-2
    /// capacity that fits `live + 1` under the load limit. Overflow-safe: the
    /// arithmetic is u64 and `live` is bounded by addressable memory / 32.
    fn grow(self: *HashPart, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        var cap: u64 = min_capacity;
        while (@as(u64, self.live) + 1 > loadLimit(cap)) cap <<= 1;
        try self.rehashTo(gpa, @intCast(cap));
    }

    /// Rebuild into a fresh zeroed array of `new_cap` slots, reinserting live
    /// nodes in old slot order (deterministic) and squeezing dead ones.
    /// On OOM the map is untouched.
    fn rehashTo(self: *HashPart, gpa: std.mem.Allocator, new_cap: u32) std.mem.Allocator.Error!void {
        std.debug.assert(std.math.isPowerOfTwo(new_cap));
        std.debug.assert(@as(u64, self.live) + 1 <= loadLimit(new_cap));
        const new_nodes = try gpa.alignedAlloc(Node, node_align, new_cap);
        @memset(std.mem.sliceAsBytes(new_nodes), 0); // all-free (nil == 0)
        const new_mask: u32 = new_cap - 1;
        if (self.nodes) |old| {
            for (old[0 .. self.mask + 1]) |*n| {
                if (n.isFree() or n.value.isNil()) continue; // free/dead
                // Fresh array has no dead nodes and no duplicates: plain
                // probe to the first free slot.
                var idx: u32 = @truncate(n.hash() & new_mask);
                while (!new_nodes[idx].isFree()) idx = (idx + 1) & new_mask;
                new_nodes[idx] = n.*;
            }
            gpa.free(old[0 .. self.mask + 1]);
        }
        self.nodes = new_nodes.ptr;
        self.mask = new_mask;
        self.used = self.live;
    }
};

// ----------------------------------------------------------------------
// Tests (P1). `std.testing.allocator` leak-checks every path (Rule Z-4).
// ----------------------------------------------------------------------

const testing = std.testing;

test "basic put/get/overwrite/contains round-trip" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), m.count());
    try testing.expect(m.get(Value.int(1)) == null);

    try m.put(gpa, Value.int(1), Value.int(10));
    try m.put(gpa, Value.int(2), Value.float(2.5));
    try testing.expectEqual(@as(u32, 2), m.count());
    try testing.expectEqual(@as(i64, 10), m.get(Value.int(1)).?.asInt());
    try testing.expectEqual(@as(f64, 2.5), m.get(Value.int(2)).?.asFloat());
    try testing.expect(m.contains(Value.int(1)));
    try testing.expect(!m.contains(Value.int(3)));

    // Overwrite: count unchanged, value replaced, slot unchanged.
    const slot_before = m.liveSlotOf(Value.int(1)).?;
    try m.put(gpa, Value.int(1), Value.int(11));
    try testing.expectEqual(@as(u32, 2), m.count());
    try testing.expectEqual(@as(i64, 11), m.get(Value.int(1)).?.asInt());
    try testing.expectEqual(slot_before, m.liveSlotOf(Value.int(1)).?);
}

test "growth keeps every entry reachable and squeezes dead nodes" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);

    var i: i64 = 0;
    while (i < 100) : (i += 1) try m.put(gpa, Value.int(i), Value.int(i * 3));
    try testing.expectEqual(@as(u32, 100), m.count());
    i = 0;
    while (i < 100) : (i += 1)
        try testing.expectEqual(@as(i64, i * 3), m.get(Value.int(i)).?.asInt());
    // Load invariant held throughout.
    try testing.expect(@as(u64, m.used) <= @as(u64, m.mask + 1) * 3 / 4);

    // Delete most entries, then insert enough fresh keys that a rehash must
    // trip: it squeezes dead nodes, and every insert after it keeps
    // used == live (no removes in between), so the end state proves the
    // squeeze happened.
    i = 0;
    while (i < 90) : (i += 1) try testing.expect(m.remove(Value.int(i)));
    try testing.expectEqual(@as(u32, 10), m.count());
    try testing.expect(m.used > m.live); // dead nodes present
    var j: i64 = 1000;
    while (j < 1200) : (j += 1) try m.put(gpa, Value.int(j), Value.int(j));
    try testing.expectEqual(m.live, m.used);
    // Survivors intact.
    i = 90;
    while (i < 100) : (i += 1)
        try testing.expectEqual(@as(i64, i * 3), m.get(Value.int(i)).?.asInt());
}

test "Lua-style deletion: dead node keeps the slot; reinsert resurrects it" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);

    var i: i64 = 0;
    while (i < 8) : (i += 1) try m.put(gpa, Value.int(i), Value.int(i));
    const slot = m.liveSlotOf(Value.int(3)).?;
    const used_before = m.used;

    try testing.expect(m.remove(Value.int(3)));
    try testing.expect(m.get(Value.int(3)) == null); // logically absent
    try testing.expect(m.getPtr(Value.int(3)) == null);
    try testing.expect(!m.contains(Value.int(3)));
    try testing.expectEqual(used_before, m.used); // node stayed (dead)
    try testing.expect(m.liveSlotOf(Value.int(3)) == null);

    // Reinsert: SAME slot (resurrection), used unchanged.
    try m.put(gpa, Value.int(3), Value.int(33));
    try testing.expectEqual(slot, m.liveSlotOf(Value.int(3)).?);
    try testing.expectEqual(used_before, m.used);
    try testing.expectEqual(@as(i64, 33), m.get(Value.int(3)).?.asInt());

    // remove of an absent key and of an already-dead key are no-ops.
    try testing.expect(!m.remove(Value.int(99)));
    try testing.expect(m.remove(Value.int(3)));
    try testing.expect(!m.remove(Value.int(3)));
}

test "iterator yields live entries only, in slot order" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);

    var i: i64 = 0;
    while (i < 10) : (i += 1) try m.put(gpa, Value.int(i), Value.int(i * 2));
    try testing.expect(m.remove(Value.int(4)));
    try testing.expect(m.remove(Value.int(7)));

    var seen: u32 = 0;
    var sum: i64 = 0;
    var it = m.iterator();
    while (it.next()) |e| {
        seen += 1;
        try testing.expect(!e.value_ptr.isNil());
        sum += e.key.asInt();
    }
    try testing.expectEqual(m.count(), seen);
    try testing.expectEqual(@as(i64, 45 - 4 - 7), sum);

    // Empty-map iterator.
    var e: HashPart = .empty;
    var it2 = e.iterator();
    try testing.expect(it2.next() == null);
}

test "layout is a deterministic pure function of the operation history" {
    const gpa = testing.allocator;
    var a: HashPart = .empty;
    defer a.deinit(gpa);
    var b: HashPart = .empty;
    defer b.deinit(gpa);

    // Same history → identical physical layout (slot-for-slot), the property
    // hrefk's recorded (slot, mask) and the trace-artifact byte-identity
    // contract rest on (doc 49 §Determinism).
    const ops = [_]struct { del: bool, k: i64 }{
        .{ .del = false, .k = 1 },  .{ .del = false, .k = 9 },
        .{ .del = false, .k = 17 }, .{ .del = false, .k = 2 },
        .{ .del = true, .k = 9 },   .{ .del = false, .k = 25 },
        .{ .del = false, .k = 9 },  .{ .del = true, .k = 1 },
        .{ .del = false, .k = 33 }, .{ .del = false, .k = 5 },
    };
    for (&[_]*HashPart{ &a, &b }) |m| {
        for (ops) |op| {
            if (op.del) {
                _ = m.remove(Value.int(op.k));
            } else {
                try m.put(gpa, Value.int(op.k), Value.int(op.k * 7));
            }
        }
    }
    try testing.expectEqual(a.mask, b.mask);
    try testing.expectEqual(a.live, b.live);
    try testing.expectEqual(a.used, b.used);
    var s: u32 = 0;
    while (s <= a.mask) : (s += 1) {
        try testing.expectEqual(a.nodes.?[s].key_tag, b.nodes.?[s].key_tag);
        try testing.expectEqual(a.nodes.?[s].key_id, b.nodes.?[s].key_id);
        try testing.expectEqual(a.nodes.?[s].key_payload.bits, b.nodes.?[s].key_payload.bits);
        try testing.expectEqual(a.nodes.?[s].value.tag, b.nodes.?[s].value.tag);
    }
}

test "collision chains: unrelated dead slot is reusable, chains stay reachable" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);

    // Build enough keys that chains exist, then delete/insert across them.
    var i: i64 = 0;
    while (i < 24) : (i += 1) try m.put(gpa, Value.int(i), Value.int(i));
    const cap_before = m.mask + 1;
    try testing.expect(m.remove(Value.int(11)));
    // Insert a fresh key while the dead node exists — regardless of whether
    // it lands on 11's chain, every other key must remain reachable and
    // occupancy must not grow past the dead-reuse accounting.
    try m.put(gpa, Value.int(1000), Value.int(1000));
    try testing.expectEqual(cap_before, m.mask + 1); // no spurious growth
    i = 0;
    while (i < 24) : (i += 1) {
        if (i == 11) {
            try testing.expect(m.get(Value.int(i)) == null);
        } else {
            try testing.expectEqual(@as(i64, i), m.get(Value.int(i)).?.asInt());
        }
    }
    try testing.expectEqual(@as(i64, 1000), m.get(Value.int(1000)).?.asInt());
}

test "put under allocator failure leaves the map consistent" {
    // Sweep failure indices through a build; on OOM the map must still hold
    // every previously-inserted entry and satisfy its counters.
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var m: HashPart = .empty;
        defer m.deinit(std.testing.allocator); // free with the real allocator
        var inserted: i64 = 0;
        var i: i64 = 0;
        while (i < 40) : (i += 1) {
            m.put(gpa, Value.int(i), Value.int(i)) catch break;
            inserted = i + 1;
        }
        // Everything inserted before the failure is intact.
        var k: i64 = 0;
        while (k < inserted) : (k += 1)
            try testing.expectEqual(@as(i64, k), m.get(Value.int(k)).?.asInt());
        try testing.expectEqual(@as(u32, @intCast(inserted)), m.count());
        try testing.expect(@as(u64, m.used) >= m.live);
    }
}

test "keyHash is pure and distributes distinct scalar keys" {
    // Same key → same hash (purity); distinct small ints → distinct hashes
    // (sanity, not a distribution proof).
    const h1 = keyHash(Value.int(7));
    try testing.expectEqual(h1, keyHash(Value.int(7)));
    var seen = std.AutoHashMapUnmanaged(u64, void).empty;
    defer seen.deinit(testing.allocator);
    var i: i64 = 0;
    while (i < 64) : (i += 1) {
        const gop = try seen.getOrPut(testing.allocator, keyHash(Value.int(i)));
        try testing.expect(!gop.found_existing);
    }
    try testing.expect(keyHash(Value.int(1)) != keyHash(Value.float(1.5)));
    try testing.expect(keyHash(Value.boolean(true)) != keyHash(Value.int(1)));
}

const GcHeader = @import("object.zig").GcHeader;

test "heap keys match by id, so a different object with the same id is the same key" {
    // A restored VM can run a program compiled in another heap: its global
    // names are other objects with the same ids (keyframe restore keeps ids).
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var a: GcHeader = .{ .type = .string, .id = 10 };
    var a_other: GcHeader = .{ .type = .string, .id = 10 };
    var b: GcHeader = .{ .type = .string, .id = 11 };

    try m.put(gpa, Value.heap(&a), Value.int(1));
    try testing.expectEqual(@as(i64, 1), m.get(Value.heap(&a_other)).?.asInt());
    try testing.expect(m.get(Value.heap(&b)) == null);
    // Storing under the other object overwrites; it doesn't add a key.
    try m.put(gpa, Value.heap(&a_other), Value.int(2));
    try testing.expectEqual(@as(u32, 1), m.count());
    try testing.expectEqual(@as(i64, 2), m.get(Value.heap(&a)).?.asInt());

    // Removal leaves a dead node that holds the id but no pointer.
    const slot = m.liveSlotOf(Value.heap(&a)).?;
    try testing.expect(m.remove(Value.heap(&a_other)));
    const n = &m.nodes.?[slot];
    try testing.expectEqual(@as(u32, 10), n.key_id);
    try testing.expectEqual(@as(u64, 0), n.key_payload.bits);
    try testing.expect(m.get(Value.heap(&a)) == null);
    // Reinserting resurrects the same slot with the new pointer.
    try m.put(gpa, Value.heap(&a), Value.int(3));
    try testing.expectEqual(slot, m.liveSlotOf(Value.heap(&a_other)).?);
    try testing.expectEqual(@intFromPtr(&a), @intFromPtr(n.key().asHeap()));

    var it = m.iterator();
    const e = it.next().?;
    try testing.expectEqual(@as(u32, 10), e.key.asHeap().id);
    try testing.expect(it.next() == null);
}

test "slot hints: stale, out-of-range, foreign and dead hints give the plain lookup's answer" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var hs: [40]GcHeader = undefined;
    for (&hs, 0..) |*h, i| h.* = .{ .type = .string, .id = @intCast(100 + i) };
    for (hs[0..8], 0..) |*h, i| try m.put(gpa, Value.heap(h), Value.int(@intCast(i)));
    const k = Value.heap(&hs[3]);

    // A cold hint (slot 0) misses, then points at the key.
    var hint: u32 = 0;
    try testing.expectEqual(@as(i64, 3), m.getHinted(k, &hint).?.asInt());
    try testing.expectEqual(m.liveSlotOf(k).?, hint);
    try testing.expectEqual(@as(i64, 3), m.heapHintHit(k, hint).?.asInt());
    // Out of range.
    hint = m.mask + 100;
    try testing.expect(m.heapHintHit(k, hint) == null);
    try testing.expectEqual(@as(i64, 3), m.getHinted(k, &hint).?.asInt());
    // Another key's slot.
    hint = m.liveSlotOf(Value.heap(&hs[5])).?;
    try testing.expect(m.heapHintHit(k, hint) == null);
    try testing.expect(!m.setExistingHinted(k, Value.int(99), hint));
    try testing.expectEqual(@as(i64, 5), m.get(Value.heap(&hs[5])).?.asInt());
    try testing.expectEqual(@as(i64, 3), m.getHinted(k, &hint).?.asInt());

    // An in-place store through a good hint; a nil store never takes it.
    try testing.expect(m.setExistingHinted(k, Value.int(30), hint));
    try testing.expectEqual(@as(i64, 30), m.get(k).?.asInt());
    try testing.expect(!m.setExistingHinted(k, Value.nil(), hint));

    // A removed key: the hint still names its (now dead) slot.
    try testing.expect(m.remove(k));
    try testing.expect(m.heapHintHit(k, hint) == null);
    try testing.expect(!m.setExistingHinted(k, Value.int(1), hint));
    try testing.expect(m.getHinted(k, &hint) == null);
    try m.put(gpa, k, Value.int(4));

    // Growth moves keys: the old hint is just stale.
    const mask_before = m.mask;
    for (hs[8..], 0..) |*h, i| try m.put(gpa, Value.heap(h), Value.int(@intCast(8 + i)));
    try testing.expect(m.mask != mask_before);
    for (&hs, 0..) |*h, i| {
        var hh = hint;
        const want: i64 = if (i == 3) 4 else @intCast(i);
        try testing.expectEqual(want, m.getHinted(Value.heap(h), &hh).?.asInt());
        try testing.expectEqual(m.liveSlotOf(Value.heap(h)).?, hh);
    }

    // A hint from another table is only a hint.
    var other: HashPart = .empty;
    defer other.deinit(gpa);
    try other.put(gpa, Value.heap(&hs[0]), Value.int(-1));
    var foreign = m.liveSlotOf(k).?;
    try testing.expect(other.getHinted(k, &foreign) == null);
    try testing.expectEqual(@as(i64, -1), other.getHinted(Value.heap(&hs[0]), &foreign).?.asInt());

    // Scalar keys never take the heap hit path.
    try m.put(gpa, Value.int(7), Value.int(70));
    var ih = m.liveSlotOf(Value.int(7)).?;
    try testing.expect(m.heapHintHit(Value.int(7), ih) == null);
    try testing.expectEqual(@as(i64, 70), m.getHinted(Value.int(7), &ih).?.asInt());
}

test "slot hints across shrink, same-capacity rebuild and dead-slot reuse" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var hs: [64]GcHeader = undefined;
    for (&hs, 0..) |*h, i| h.* = .{ .type = .string, .id = @intCast(200 + i) };
    for (hs[0..40], 0..) |*h, i| try m.put(gpa, Value.heap(h), Value.int(@intCast(i)));

    // Every key's hint before the rebuilds.
    var hints: [40]u32 = undefined;
    for (hs[0..40], &hints) |*h, *hint| hint.* = m.liveSlotOf(Value.heap(h)).?;

    // Same-capacity rebuild: dead nodes squeezed out, keys may move.
    for (hs[0..30]) |*h| try testing.expect(m.remove(Value.heap(h)));
    const cap = m.mask + 1;
    try testing.expect(cap > 16); // so `cap - 1` is out of range after the shrink
    try m.rehashTo(gpa, cap);
    try testing.expectEqual(cap, m.mask + 1);
    for (hs[0..40], &hints, 0..) |*h, *hint, i| {
        const k = Value.heap(h);
        if (i < 30) {
            try testing.expect(m.heapHintHit(k, hint.*) == null);
            try testing.expect(m.getHinted(k, hint) == null);
        } else {
            if (m.heapHintHit(k, hint.*)) |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asInt());
            try testing.expectEqual(@as(i64, @intCast(i)), m.getHinted(k, hint).?.asInt());
            try testing.expectEqual(m.liveSlotOf(k).?, hint.*);
        }
    }

    // Shrink: hints from the bigger layout. Half of them are the key's slot
    // there, half are past the small layout's end.
    for (hs[30..40], hints[0..10], 0..) |*h, *hint, i| {
        hint.* = if (i % 2 == 0) m.liveSlotOf(Value.heap(h)).? else cap - 1;
    }
    try m.rehashTo(gpa, 16);
    try testing.expectEqual(@as(u32, 15), m.mask);
    for (hs[30..40], hints[0..10], 30..) |*h, *hint, i| {
        const k = Value.heap(h);
        if (m.heapHintHit(k, hint.*)) |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asInt());
        try testing.expectEqual(@as(i64, @intCast(i)), m.getHinted(k, hint).?.asInt());
    }

    // Dead-slot reuse: another key takes the removed key's slot, and the
    // removed key's hint then names a live node that isn't it.
    const gone = Value.heap(&hs[35]);
    const gone_slot = m.liveSlotOf(gone).?;
    try testing.expect(m.remove(gone));
    var reused = false;
    for (hs[40..]) |*h| {
        try m.put(gpa, Value.heap(h), Value.int(1000));
        if (m.liveSlotOf(Value.heap(h)) == gone_slot) {
            reused = true;
            break;
        }
    }
    try testing.expect(reused);
    var gone_hint = gone_slot;
    try testing.expect(m.heapHintHit(gone, gone_hint) == null);
    try testing.expect(!m.setExistingHinted(gone, Value.int(5), gone_hint));
    try testing.expect(m.getHinted(gone, &gone_hint) == null);
}

test "slot hints hit through another object with the same id" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var a: GcHeader = .{ .type = .string, .id = 10 };
    var a_other: GcHeader = .{ .type = .string, .id = 10 };
    try m.put(gpa, Value.heap(&a), Value.int(1));
    const slot = m.liveSlotOf(Value.heap(&a)).?;

    try testing.expectEqual(@as(i64, 1), m.heapHintHit(Value.heap(&a_other), slot).?.asInt());
    var hint = slot;
    try testing.expectEqual(@as(i64, 1), m.getHinted(Value.heap(&a_other), &hint).?.asInt());
    try testing.expectEqual(slot, hint);
    try testing.expect(m.setExistingHinted(Value.heap(&a_other), Value.int(2), slot));
    try testing.expectEqual(@as(i64, 2), m.get(Value.heap(&a)).?.asInt());
    try testing.expectEqual(@as(u32, 1), m.count());
}

// --- nextLive: `next`'s canonical-order traversal ---------------------------

const key_order = @import("key_order.zig");

/// The live keys sorted by `key_order`: what a walk must visit. Caller frees.
fn canonicalKeys(gpa: std.mem.Allocator, m: *const HashPart) ![]Value {
    const keys = try gpa.alloc(Value, m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) keys[i] = e.key;
    std.mem.sort(Value, keys, {}, key_order.less);
    return keys;
}

fn expectSameKeys(want: []const Value, got: []const Value) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expect(w.eql(g));
}

/// Mixed scalar and heap keys, so every ordering arm is exercised.
fn putMixed(gpa: std.mem.Allocator, m: *HashPart, hs: []GcHeader) !void {
    for (hs, 0..) |*h, i| {
        // Ids out of insertion order, so slot order isn't already sorted.
        h.* = .{ .type = .string, .id = @intCast(1000 - 7 * i) };
        try m.put(gpa, Value.heap(h), Value.int(@intCast(i)));
    }
    const scalars = [_]Value{
        Value.int(5),       Value.int(-3),     Value.int(1 << 40), Value.float(2.5),
        Value.float(-0.5),  Value.boolean(true), Value.boolean(false), Value.int(0),
    };
    for (scalars) |k| try m.put(gpa, k, Value.int(1));
}

test "nextLive walks the live keys in key_order and sorts once" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var hs: [12]GcHeader = undefined;
    try putMixed(gpa, &m, &hs);

    const want = try canonicalKeys(gpa, &m);
    defer gpa.free(want);
    var got: std.ArrayList(Value) = .empty;
    defer got.deinit(gpa);
    var ctrl: ?Value = null;
    while (try m.nextLive(gpa, ctrl)) |e| {
        try got.append(gpa, e.key);
        ctrl = e.key;
    }
    try expectSameKeys(want, got.items);
    try testing.expectEqual(@as(u32, 1), m.iter_builds);

    // A second walk of the unchanged map reuses the view: no sort.
    got.clearRetainingCapacity();
    ctrl = null;
    while (try m.nextLive(gpa, ctrl)) |e| {
        try got.append(gpa, e.key);
        ctrl = e.key;
    }
    try expectSameKeys(want, got.items);
    try testing.expectEqual(@as(u32, 1), m.iter_builds);

    // Dropping the view (as a collection does) costs one more sort only.
    m.dropIterCache(gpa);
    try testing.expect(m.iter_keys == null);
    try testing.expect((try m.nextLive(gpa, null)).?.key.eql(want[0]));
    try testing.expectEqual(@as(u32, 2), m.iter_builds);
}

test "nextLive: deleting each key as it is visited sees every key once, with one sort" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 5000) : (i += 1) try m.put(gpa, Value.int(@mod(i * 7919, 100003)), Value.int(i));

    const want = try canonicalKeys(gpa, &m);
    defer gpa.free(want);
    var got: std.ArrayList(Value) = .empty;
    defer got.deinit(gpa);
    var ctrl: ?Value = null;
    while (try m.nextLive(gpa, ctrl)) |e| {
        const k = e.key;
        try got.append(gpa, k);
        try testing.expect(m.remove(k));
        ctrl = k;
    }
    try expectSameKeys(want, got.items);
    try testing.expectEqual(@as(u32, 0), m.count());
    try testing.expectEqual(@as(u32, 1), m.iter_builds);
}

test "nextLive: a key added mid-walk rebuilds, and the walk resumes after ctrl" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 20) : (i += 1) try m.put(gpa, Value.int(i * 10), Value.int(i));

    // Walk to key 90, then add one key before it and two after.
    var ctrl: ?Value = null;
    while (try m.nextLive(gpa, ctrl)) |e| {
        ctrl = e.key;
        if (e.key.asInt() == 90) break;
    }
    try m.put(gpa, Value.int(45), Value.int(0));
    try m.put(gpa, Value.int(95), Value.int(0));
    try m.put(gpa, Value.int(1000), Value.int(0));
    // An overwrite adds no key, so it does not invalidate.
    try m.put(gpa, Value.int(100), Value.int(-1));

    var rest: std.ArrayList(i64) = .empty;
    defer rest.deinit(gpa);
    while (try m.nextLive(gpa, ctrl)) |e| {
        try rest.append(gpa, e.key.asInt());
        ctrl = e.key;
    }
    // Every key strictly greater than 90, among the keys live now.
    const want = [_]i64{ 95, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 1000 };
    try testing.expectEqualSlices(i64, &want, rest.items);
    try testing.expectEqual(@as(u32, 2), m.iter_builds);
}

test "nextLive: a key removed and re-added mid-walk is visited" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var hs: [12]GcHeader = undefined;
    try putMixed(gpa, &m, &hs);
    const want = try canonicalKeys(gpa, &m);
    defer gpa.free(want);

    // The last key in the order is dead when the view is built (first step)
    // and resurrected after it, so the view must not be trusted.
    const last = want[want.len - 1];
    try testing.expect(m.remove(last));
    const first = (try m.nextLive(gpa, null)).?.key;
    try m.put(gpa, last, Value.int(7));

    var got: std.ArrayList(Value) = .empty;
    defer got.deinit(gpa);
    try got.append(gpa, first);
    var ctrl: ?Value = first;
    while (try m.nextLive(gpa, ctrl)) |e| {
        try got.append(gpa, e.key);
        ctrl = e.key;
    }
    try expectSameKeys(want, got.items);
    try testing.expectEqual(@as(u32, 2), m.iter_builds);
}

test "nextLive: a new key landing in a dead slot mid-walk is visited" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    var i: i64 = 0;
    while (i < 40) : (i += 1) try m.put(gpa, Value.int(i), Value.int(i));
    i = 0;
    while (i < 40) : (i += 2) try testing.expect(m.remove(Value.int(i)));

    const first = (try m.nextLive(gpa, null)).?.key;
    // One new key that takes a dead slot. Only that kind of insertion, since
    // a free-slot one would invalidate the view by itself.
    i = 100;
    while (m.probeForPut(Ident.of(Value.int(i))) != .reuse_dead) i += 1;
    try m.put(gpa, Value.int(i), Value.int(i));

    var got: std.ArrayList(Value) = .empty;
    defer got.deinit(gpa);
    var ctrl: ?Value = first;
    while (try m.nextLive(gpa, ctrl)) |e| {
        try got.append(gpa, e.key);
        ctrl = e.key;
    }
    // Every live key after the first.
    const all = try canonicalKeys(gpa, &m);
    defer gpa.free(all);
    try testing.expect(all[0].eql(first));
    try expectSameKeys(all[1..], got.items);
}

test "nextLive: a control that is not a key resumes at the next greater key" {
    const gpa = testing.allocator;
    var m: HashPart = .empty;
    defer m.deinit(gpa);
    try m.put(gpa, Value.int(10), Value.int(1));
    try m.put(gpa, Value.int(30), Value.int(3));
    try m.put(gpa, Value.boolean(true), Value.int(2));

    try testing.expectEqual(@as(i64, 30), (try m.nextLive(gpa, Value.int(20))).?.key.asInt());
    // Tag order: booleans sort before ints, so the first int follows `true`,
    // and `true` follows `false`.
    try testing.expect((try m.nextLive(gpa, Value.boolean(false))).?.key.eql(Value.boolean(true)));
    try testing.expectEqual(@as(i64, 10), (try m.nextLive(gpa, Value.boolean(true))).?.key.asInt());
    // Past every int key: nothing of a later tag is present.
    try testing.expect((try m.nextLive(gpa, Value.int(31))) == null);
    try testing.expectEqual(@as(u32, 1), m.iter_builds);
    // Empty map: no view is built.
    var e: HashPart = .empty;
    try testing.expect((try e.nextLive(gpa, null)) == null);
    try testing.expectEqual(@as(u32, 0), e.iter_builds);
}

test "nextLive under allocator failure leaves the map unchanged and retryable" {
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var m: HashPart = .empty;
    defer m.deinit(testing.allocator);
    try m.put(testing.allocator, Value.int(1), Value.int(1));
    try m.put(testing.allocator, Value.int(2), Value.int(2));
    // The view's allocation is the failing allocator's first.
    try testing.expectError(error.OutOfMemory, m.nextLive(fa.allocator(), null));
    try testing.expectEqual(@as(u32, 2), m.count());
    try testing.expect(!m.iter_valid);
    try testing.expectEqual(@as(i64, 1), (try m.nextLive(testing.allocator, null)).?.key.asInt());
}
