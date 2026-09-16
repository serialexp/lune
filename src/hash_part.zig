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
//!   rewritten from the object pointer to the stable `GcHeader.id` (tag
//!   preserved). GC marks live nodes only; a deleted key's object graph is
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
/// (`eql` still does the full comparison).
pub fn keyHash(v: Value) u64 {
    const payload: u64 = if (v.isHeap()) v.asHeap().id else v.payload.bits;
    var x = payload ^ (@as(u64, @intFromEnum(v.tag)) *% 0x9E3779B97F4A7C15);
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return x ^ (x >> 31);
}

/// One slot: key + value, interleaved so a field access reads one cacheline.
/// All-zero bytes are a FREE node (`Tag.nil == 0`, zero payload, zero pad), so
/// a fresh array is a single `@memset`.
pub const Node = extern struct {
    key: Value,
    value: Value,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 32);
    std.debug.assert(@offsetOf(Node, "key") == 0);
    std.debug.assert(@offsetOf(Node, "value") == 16);
    // The all-zero-bytes-is-free invariant: nil is tag ordinal 0.
    std.debug.assert(@intFromEnum(value.Tag.nil) == 0);
}

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

    pub const empty: HashPart = .{};
    pub const min_capacity: u32 = 4;

    pub const Entry = struct { key_ptr: *Value, value_ptr: *Value };

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
        while (true) {
            switch (self.probeForPut(key)) {
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
                    n.key = key;
                    n.value = val;
                    self.live += 1;
                    return;
                },
                .reuse_dead => |idx| {
                    // New key, unrelated dead slot on its chain (scanned to
                    // the chain's free end first, so no duplicate exists).
                    // Occupancy does not grow → no load test.
                    const n = &self.nodes.?[idx];
                    n.key = key;
                    n.value = val;
                    self.live += 1;
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
                    n.key = key;
                    n.value = val;
                    self.live += 1;
                    self.used += 1;
                    return;
                },
            }
        }
    }

    /// Remove a key. Lua-style: the node stays (dead) until the next rehash;
    /// a heap key's payload is rewritten pointer → stable id so dead nodes
    /// hold no pointers. Returns true iff a live entry was removed.
    pub fn remove(self: *HashPart, key: Value) bool {
        const idx = self.liveSlotOf(key) orelse return false;
        const n = &self.nodes.?[idx];
        // Publication order (doc 49): value goes nil BEFORE the key loses its
        // pointer, so "non-nil value ⇒ valid live key" holds at every point.
        n.value = Value.nil();
        if (n.key.isHeap()) n.key.payload = .{ .bits = @as(u64, n.key.asHeap().id) };
        self.live -= 1;
        return true;
    }

    /// Iterate LIVE entries (dead and free nodes are skipped), in slot order.
    /// Mutable pointers, like the std map's iterator; mutating the map while
    /// iterating invalidates the iterator (also like the std map).
    pub const Iterator = struct {
        nodes: [*]Node,
        remaining: u32,

        pub fn next(it: *Iterator) ?Entry {
            while (it.remaining != 0) {
                const n = &it.nodes[0];
                it.nodes += 1;
                it.remaining -= 1;
                if (!n.key.isNil() and !n.value.isNil())
                    return .{ .key_ptr = &n.key, .value_ptr = &n.value };
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

    // ------------------------------------------------------------------
    // Internal probe layer (doc 49): slot arithmetic for put/resurrect, the
    // recorder's hrefk slot capture, GC's live walk, and tests.
    // ------------------------------------------------------------------

    /// Slot of the LIVE node for `key`, or null (absent OR dead — a dead
    /// match proves logical absence and stops the probe: a key occupies at
    /// most one node, live or dead). This is the recorder's `hashSlotOf`
    /// backing: hrefk pins live slots only.
    pub fn liveSlotOf(self: *const HashPart, key: Value) ?u32 {
        std.debug.assert(key.tag != .row_view);
        const nodes = self.nodes orelse return null;
        const mask = self.mask;
        var idx: u32 = @truncate(keyHash(key) & mask);
        var limit: u64 = @as(u64, mask) + 1;
        const dead_bits = deadBitsOf(key);
        while (limit != 0) : (limit -= 1) {
            const n = &nodes[idx];
            if (n.key.isNil()) return null; // free — chain ends
            if (n.value.isNil()) {
                // Dead node: internal key encoding — match by (tag, id-or-raw
                // bits), never by dereferencing (`Value.eql` would chase a
                // heap pointer the node no longer holds).
                if (n.key.tag == key.tag and n.key.payload.bits == dead_bits) return null;
            } else if (n.key.eql(key)) {
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
    fn probeForPut(self: *const HashPart, key: Value) PutSlot {
        const nodes = self.nodes.?;
        const mask = self.mask;
        var idx: u32 = @truncate(keyHash(key) & mask);
        const dead_bits = deadBitsOf(key);
        var first_dead: ?u32 = null;
        while (true) {
            const n = &nodes[idx];
            if (n.key.isNil()) {
                return if (first_dead) |d| .{ .reuse_dead = d } else .{ .free = idx };
            }
            if (n.value.isNil()) {
                if (n.key.tag == key.tag and n.key.payload.bits == dead_bits)
                    return .{ .resurrect = idx };
                if (first_dead == null) first_dead = idx;
            } else if (n.key.eql(key)) {
                return .{ .live = idx };
            }
            idx = (idx + 1) & mask;
        }
    }

    /// The internal identity bits a DEAD node stores for this key: the stable
    /// `GcHeader.id` for heap keys (pointer-free), the raw payload for
    /// scalars. Tags are compared first, and ids are globally unique within
    /// the allocation timeline, so there is no cross-kind collision.
    fn deadBitsOf(v: Value) u64 {
        return if (v.isHeap()) @as(u64, v.asHeap().id) else v.payload.bits;
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
                if (n.key.isNil() or n.value.isNil()) continue; // free/dead
                // Fresh array has no dead nodes and no duplicates: plain
                // probe to the first free slot.
                var idx: u32 = @truncate(keyHash(n.key) & new_mask);
                while (!new_nodes[idx].key.isNil()) idx = (idx + 1) & new_mask;
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
        sum += e.key_ptr.asInt();
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
        try testing.expectEqual(a.nodes.?[s].key.tag, b.nodes.?[s].key.tag);
        try testing.expectEqual(a.nodes.?[s].key.payload.bits, b.nodes.?[s].key.payload.bits);
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
