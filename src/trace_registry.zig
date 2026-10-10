//! Allocation and physical lifetime owner. No coordinator references or policy callbacks.
//! Constituents are composed by value and borrowed only for each operation: init is movable.
const std = @import("std");
const Trace = @import("trace_record.zig").TraceRecord;
const NativeSeedCtx = @import("trace_code.zig").NativeSeedCtx;
const nativegen = @import("nativegen.zig");
const EntryRegistry = @import("trace_entry_registry.zig").EntryRegistry;
const NativePhysicalRegistry = @import("trace_native_registry.zig").NativePhysicalRegistry;
const AnchorKey = @import("trace_types.zig").AnchorKey;

/// One anchor's published traces: an intrusive doubly-linked list through
/// `TraceRecord.anchor_prev`/`anchor_next`, in cache order, plus its counts.
pub const AnchorList = struct {
    head: *Trace,
    tail: *Trace,
    count: u32,
    /// Members of inner-loop-root shape (a `.loop` terminal).
    inner_roots: u32,
};

/// Inner-loop-root shape, anchor aside: a `.loop`-terminated body. Code is
/// immutable once published, so the shape is fixed for a record's lifetime.
pub fn isInnerRootShape(t: *const Trace) bool {
    return t.code.instrs.len != 0 and t.code.instrs[t.code.instrs.len - 1].op == .loop;
}

/// Iterates one anchor's traces in cache order.
pub const AnchorIter = struct {
    next_trace: ?*Trace,
    pub fn next(self: *AnchorIter) ?*Trace {
        const t = self.next_trace orelse return null;
        self.next_trace = t.anchor_next;
        return t;
    }
};

pub const TraceRegistry = struct {
    gpa: std.mem.Allocator,
    /// Published traces in publish order. Mutate only through `publish`,
    /// `attach`, `detach`, `detachAll`, `unpublishDoomed` and `clear`: they
    /// keep `by_anchor` in step.
    cache: std.ArrayListUnmanaged(*Trace) = .empty,
    /// Anchor → its published traces (cache order) and counts, so every
    /// per-anchor lookup is O(traces at that anchor), never O(cache).
    by_anchor: std.AutoHashMapUnmanaged(AnchorKey, AnchorList) = .empty,
    trace_by_id: std.ArrayListUnmanaged(?*Trace) = .empty,
    next_trace_id: u32 = 0,
    cache_gen: u32 = 1,
    entry_registry: EntryRegistry,
    native_physical: NativePhysicalRegistry,
    mcode_arena: nativegen.McodeArena,
    native_seed_ctx: ?*NativeSeedCtx = null,
    /// Doc 61 §7.1 item 6: one `*Trace` list with capacity ≥ the cache,
    /// reserved at publish so a collection's doomed set and the entry-patch
    /// drain's install list never allocate. Contents live for one operation.
    batch_scratch: std.ArrayListUnmanaged(*Trace) = .empty,

    pub fn init(gpa: std.mem.Allocator) TraceRegistry {
        return .{ .gpa = gpa, .entry_registry = EntryRegistry.init(gpa), .native_physical = NativePhysicalRegistry.init(gpa), .mcode_arena = nativegen.McodeArena.init(gpa) };
    }
    fn changed(self: *TraceRegistry) void {
        self.cache_gen +%= 1;
        if (self.cache_gen == 0) self.cache_gen = 1;
    }
    /// Unpublished storage; caller prepares code, and owns its arrays until publish succeeds.
    pub fn allocate(self: *TraceRegistry) !*Trace {
        const t = try self.gpa.create(Trace);
        t.* = .{ .id = self.next_trace_id, .code = undefined };
        self.next_trace_id += 1;
        return t;
    }
    pub fn discardAllocation(self: *TraceRegistry, t: *Trace) void {
        self.gpa.destroy(t);
    }
    /// Ownership transfers only on success. Index allocation is an optional acceleration.
    pub fn publish(self: *TraceRegistry, t: *Trace) !void {
        try self.batch_scratch.ensureTotalCapacity(self.gpa, self.cache.items.len + 1);
        try self.attach(t);
        if (t.id >= self.trace_by_id.items.len) {
            const old_len = self.trace_by_id.items.len;
            self.trace_by_id.resize(self.gpa, @as(usize, t.id) + 1) catch return;
            @memset(self.trace_by_id.items[old_len..], null);
        }
        self.trace_by_id.items[t.id] = t;
    }
    /// Append `t` to the cache and its anchor list, without the id index or
    /// the batch reservation: `publish`'s core, and the way tests install
    /// caller-owned (often stack) records. Such records must leave through
    /// `detach`/`detachAll` before `clear`/`deinit`, which destroy the cache.
    /// All-or-nothing: both reservations happen before any mutation.
    pub fn attach(self: *TraceRegistry, t: *Trace) !void {
        try self.by_anchor.ensureUnusedCapacity(self.gpa, 1);
        try self.cache.ensureUnusedCapacity(self.gpa, 1);
        self.cache.appendAssumeCapacity(t);
        self.linkAnchor(t);
        self.changed();
    }
    /// Remove one attached record (order-preserving), without destroying it.
    /// False when `t` is not in the cache.
    pub fn detach(self: *TraceRegistry, t: *Trace) bool {
        const i = std.mem.indexOfScalar(*Trace, self.cache.items, t) orelse return false;
        _ = self.cache.orderedRemove(i);
        self.unlinkAnchor(t);
        if (t.id < self.trace_by_id.items.len and self.trace_by_id.items[t.id] == t) self.trace_by_id.items[t.id] = null;
        self.changed();
        return true;
    }
    /// Remove every record without destroying or touching any (a caller may
    /// already have freed them): the counterpart of `attach` for caller-owned
    /// records. Their stale anchor links are dead — `linkAnchor` rewrites
    /// both on a re-attach.
    pub fn detachAll(self: *TraceRegistry) void {
        self.cache.clearRetainingCapacity();
        self.by_anchor.clearRetainingCapacity();
        @memset(self.trace_by_id.items, null);
        self.changed();
    }
    fn linkAnchor(self: *TraceRegistry, t: *Trace) void {
        const gop = self.by_anchor.getOrPutAssumeCapacity(t.code.anchor);
        const root: u32 = @intFromBool(isInnerRootShape(t));
        t.anchor_next = null;
        if (gop.found_existing) {
            const l = gop.value_ptr;
            t.anchor_prev = l.tail;
            l.tail.anchor_next = t;
            l.tail = t;
            l.count += 1;
            l.inner_roots += root;
        } else {
            t.anchor_prev = null;
            gop.value_ptr.* = .{ .head = t, .tail = t, .count = 1, .inner_roots = root };
        }
    }
    /// O(1) and allocation-free (a hash-map `remove` never allocates).
    fn unlinkAnchor(self: *TraceRegistry, t: *Trace) void {
        const l = self.by_anchor.getPtr(t.code.anchor).?;
        std.debug.assert(l.count != 0);
        l.count -= 1;
        l.inner_roots -= @intFromBool(isInnerRootShape(t));
        if (l.count == 0) {
            std.debug.assert(l.head == t and l.tail == t);
            _ = self.by_anchor.remove(t.code.anchor);
        } else {
            if (t.anchor_prev) |p| p.anchor_next = t.anchor_next else l.head = t.anchor_next.?;
            if (t.anchor_next) |n| n.anchor_prev = t.anchor_prev else l.tail = t.anchor_prev.?;
        }
        t.anchor_prev = null;
        t.anchor_next = null;
    }
    /// The traces anchored at `anchor`, in cache order.
    pub fn tracesAt(self: *const TraceRegistry, anchor: AnchorKey) AnchorIter {
        const l = self.by_anchor.get(anchor) orelse return .{ .next_trace = null };
        return .{ .next_trace = l.head };
    }
    pub fn countAt(self: *const TraceRegistry, anchor: AnchorKey) usize {
        const l = self.by_anchor.get(anchor) orelse return 0;
        return l.count;
    }
    /// Whether a trace of inner-loop-root shape is anchored at `anchor`.
    pub fn innerRootAt(self: *const TraceRegistry, anchor: AnchorKey) bool {
        const l = self.by_anchor.get(anchor) orelse return false;
        return l.inner_roots != 0;
    }
    pub fn traceById(self: *const TraceRegistry, id: u32) ?*Trace {
        if (id < self.trace_by_id.items.len) if (self.trace_by_id.items[id]) |t| return t;
        for (self.cache.items) |t| if (t.id == id) return t;
        return null;
    }
    /// Retirement is forbidden during replay: deferred disarm cannot protect freed pages.
    /// Retire one published trace: the one-element case of `unpublishDoomed`
    /// + `destroyDoomed`. False when `t` is not in the cache.
    pub fn retire(self: *TraceRegistry, t: *Trace) bool {
        for (self.cache.items) |live| {
            if (live != t) continue;
            t.doomed = true;
            const one = [_]*Trace{t};
            self.unpublishDoomed(&one);
            destroyDoomed(self.gpa, &one);
            return true;
        }
        return false;
    }
    /// The physical half of a batch retirement (doc 61 §7.1 item 5 steps 3–4).
    /// Every member of `doomed` is published and has `Trace.doomed` set; the
    /// records stay allocated (the caller still reads their anchors) until
    /// `destroyDoomed`. Links, proofs and promoted sets touching a doomed
    /// trace are torn down first, then entry patches go non-live (restore is
    /// deferred to the safe-point drain so borrowed entry-patch pointers
    /// remain stable; `EntryPatch.trace` is poisoned), and the cache is
    /// compacted in order.
    pub fn unpublishDoomed(self: *TraceRegistry, doomed: []const *Trace) void {
        if (self.native_physical.inReplayWalk()) @panic("trace retirement during replay");
        self.native_physical.resetLinksTouchingDoomed(&self.mcode_arena);
        for (doomed) |t| {
            std.debug.assert(t.doomed);
            if (t.entry_slot) |slot| {
                self.entry_registry.markEntryPatchPending(slot);
                const patch = self.entry_registry.entry_patches.items[slot];
                patch.trace = undefined;
                patch.owner_retired = true;
            }
            if (t.id < self.trace_by_id.items.len) self.trace_by_id.items[t.id] = null;
            self.unlinkAnchor(t);
        }
        var w: usize = 0;
        for (self.cache.items) |t| {
            if (t.doomed) continue;
            self.cache.items[w] = t;
            w += 1;
        }
        std.debug.assert(self.cache.items.len - w == doomed.len);
        self.cache.shrinkRetainingCapacity(w);
        self.changed();
    }
    pub fn destroyDoomed(gpa: std.mem.Allocator, doomed: []const *Trace) void {
        for (doomed) |t| t.destroy(gpa);
    }
    /// Self-contained epoch safety; never relies on coordinator pre-disarm.
    pub fn clear(self: *TraceRegistry) void {
        if (self.native_physical.inReplayWalk()) @panic("trace clear during replay");
        self.native_physical.demoteAllSets();
        self.native_physical.disarmAllLinks(&self.mcode_arena);
        self.native_physical.resetPromotionCandidate();
        _ = self.native_physical.drainBarrier(&self.mcode_arena);
        self.entry_registry.dropEntryPatchState();
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.clearRetainingCapacity();
        self.by_anchor.clearRetainingCapacity();
        @memset(self.trace_by_id.items, null);
        self.changed();
    }
    pub fn createSeedContext(self: *TraceRegistry, value: NativeSeedCtx) !void {
        std.debug.assert(self.native_seed_ctx == null);
        const ctx = try self.gpa.create(NativeSeedCtx);
        ctx.* = value;
        self.native_seed_ctx = ctx;
    }
    pub fn deinit(self: *TraceRegistry) void {
        self.clear();
        self.native_physical.deinit(&self.mcode_arena);
        self.entry_registry.deinit();
        self.cache.deinit(self.gpa);
        self.by_anchor.deinit(self.gpa);
        self.batch_scratch.deinit(self.gpa);
        self.trace_by_id.deinit(self.gpa);
        self.mcode_arena.deinit();
        if (self.native_seed_ctx) |ctx| self.gpa.destroy(ctx);
    }
};

fn emptyCandidate(registry: *TraceRegistry) !*Trace {
    const t = try registry.allocate();
    t.code = .{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    return t;
}

test "registry publication retirement and clear preserve monotonic identity" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    const first = try emptyCandidate(&registry);
    const first_id = first.id;
    try registry.publish(first);
    try testing.expectEqual(first, registry.traceById(first_id).?);
    const generation = registry.cache_gen;
    try testing.expect(registry.retire(first));
    try testing.expect(registry.traceById(first_id) == null);
    try testing.expect(registry.cache_gen != generation);
    const second = try emptyCandidate(&registry);
    const second_id = second.id;
    try testing.expect(second_id > first_id);
    try registry.publish(second);
    registry.clear();
    try testing.expect(registry.traceById(second_id) == null);
    const third = try emptyCandidate(&registry);
    defer registry.discardAllocation(third);
    try testing.expect(third.id > second_id);
}

test "registry failed publication keeps candidate ownership with caller" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    const t = try emptyCandidate(&registry);
    defer registry.discardAllocation(t);
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = registry.gpa;
    registry.gpa = failing.allocator();
    defer registry.gpa = allocator;
    const generation = registry.cache_gen;
    try testing.expectError(error.OutOfMemory, registry.publish(t));
    try testing.expectEqual(generation, registry.cache_gen);
    try testing.expect(registry.traceById(t.id) == null);
}

test "registry clear drops candidate references even without armed links" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    const t = try emptyCandidate(&registry);
    try registry.publish(t);
    const Edge = @import("trace_native_registry.zig").PromotedEdge;
    const edges = try testing.allocator.alloc(Edge, 1);
    edges[0] = .{ .parent = t, .child = t, .exit = 0, .kind = .deopt, .arm_kind = .ordinary_guard, .resume_pc = 0, .cell = 0 };
    // Candidate storage is independent from live promotions and armed links.
    registry.native_physical.promotion_candidate = edges;
    registry.clear();
    try testing.expectEqual(@as(usize, 0), registry.native_physical.promotionCandidate().len);
}

test "registry optional index OOM preserves successful publication and swap order" {
    const testing = std.testing;
    var registry = TraceRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.cache.ensureTotalCapacity(testing.allocator, 3);
    try registry.batch_scratch.ensureTotalCapacity(testing.allocator, 3);
    try registry.by_anchor.ensureTotalCapacity(testing.allocator, 3);
    const first = try emptyCandidate(&registry);
    const middle = try emptyCandidate(&registry);
    const last = try emptyCandidate(&registry);
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    registry.gpa = failing.allocator();
    // Cache, anchor index and batch scratch have capacity; only the optional
    // identity index needs allocation.
    registry.publish(first) catch unreachable;
    registry.publish(middle) catch unreachable;
    registry.publish(last) catch unreachable;
    registry.gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), registry.trace_by_id.items.len);
    try testing.expectEqual(first, registry.traceById(first.id).?);
    try testing.expect(registry.retire(middle));
    try testing.expectEqual(first, registry.cache.items[0]);
    try testing.expectEqual(last, registry.cache.items[1]);
    try testing.expectEqual(last, registry.traceById(last.id).?);
}
