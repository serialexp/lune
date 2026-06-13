//! The object heap — allocates heap objects, threads them onto an intrusive
//! list, and owns the string interning table.
//!
//! There is **no collector yet** (that is Phase 4). What lives here now is the
//! machinery a non-moving collector needs to be grafted on without disturbing
//! allocation sites:
//!
//!   * Every object is linked through its `GcHeader.next` into one intrusive
//!     list, so a future sweep can walk every live object. `deinit` already does
//!     exactly that walk to free everything (and to keep tests leak-clean).
//!   * Strings are **interned** here: identical bytes yield the identical object,
//!     so string equality and table keys are pointer comparisons.
//!   * `writeBarrier` exists as a **no-op call site** at every "store a heap
//!     value into a heap object" point (see `interp.zig`), so the generational
//!     barrier in Phase 4 is a body to fill in, not a hunt for sites
//!     (docs/design/03-gc-memory.md).
//!
//! Allocation goes through an injected allocator (Z-4); wrap it in
//! `mem.TrackingAllocator` to measure a script's heap footprint.

const std = @import("std");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const value = @import("value.zig");
const GcHeader = object.GcHeader;
const String = string.String;
const Table = table.Table;
const Value = value.Value;

pub const Heap = struct {
    gpa: std.mem.Allocator,
    /// Intrusive singly-linked list of every live object (newest first).
    objects: ?*GcHeader = null,
    /// Number of live objects (informational until the collector lands).
    object_count: usize = 0,
    /// Interning table: content bytes → the unique `String`. Keys are the
    /// interned strings' own bytes (stable for the object's lifetime).
    interned: std.StringHashMapUnmanaged(*String) = .empty,

    pub fn init(gpa: std.mem.Allocator) Heap {
        return .{ .gpa = gpa };
    }

    /// Free every object and the interning table. After this the heap is unusable.
    pub fn deinit(self: *Heap) void {
        var it = self.objects;
        while (it) |h| {
            const next = h.next;
            destroyObject(self.gpa, h);
            it = next;
        }
        self.objects = null;
        self.object_count = 0;
        self.interned.deinit(self.gpa);
    }

    fn link(self: *Heap, h: *GcHeader) void {
        h.next = self.objects;
        self.objects = h;
        self.object_count += 1;
    }

    /// Allocate a fresh empty table and register it with the heap.
    pub fn newTable(self: *Heap) std.mem.Allocator.Error!*Table {
        const t = try Table.create(self.gpa);
        self.link(&t.header);
        return t;
    }

    /// Intern `content`: return the existing object for these bytes, or allocate,
    /// register, and return a new one. The returned string's bytes are a copy —
    /// `content` need not outlive the call.
    pub fn intern(self: *Heap, content: []const u8) std.mem.Allocator.Error!*String {
        if (self.interned.get(content)) |existing| return existing;
        const s = try String.create(self.gpa, content);
        errdefer s.destroy(self.gpa); // map.put may fail before we link it
        try self.interned.put(self.gpa, s.bytes(), s);
        self.link(&s.header);
        return s;
    }

    /// Convenience: intern `content` and wrap it as a `Value`.
    pub fn internValue(self: *Heap, content: []const u8) std.mem.Allocator.Error!Value {
        const s = try self.intern(content);
        return Value.heap(&s.header);
    }

    /// Write barrier — invoked whenever a heap `Value` is stored into a heap
    /// `container`. A deliberate **no-op** in Phase 3; Phase 4's generational /
    /// incremental collector fills in the body (remember-set insert, card mark,
    /// or grey-stack push) without any call site moving. See
    /// docs/design/03-gc-memory.md §Barriers.
    pub inline fn writeBarrier(self: *Heap, container: *GcHeader, stored: Value) void {
        _ = self;
        _ = container;
        _ = stored;
    }
};

/// Free one object according to its concrete type.
fn destroyObject(gpa: std.mem.Allocator, h: *GcHeader) void {
    switch (h.type) {
        .string => String.fromHeader(h).destroy(gpa),
        .table => Table.fromHeader(h).destroy(gpa),
        // typed_array (Phase 9b), function (Increment D), host (embedding) are
        // not heap-allocated here yet.
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
