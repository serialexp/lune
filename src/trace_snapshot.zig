//! Precise-deopt snapshots (doc 45 D2) — executor-independent types,
//! ownership, admission budgets, validation and pure ref remapping.
//!
//! A `Snapshot` describes the complete register state of the trace anchor's
//! CURRENT physical activation at one guest-bytecode boundary: `resume_pc` is
//! the guest PC to resume at, and `slots_begin/slots_len` name a shared vector
//! of `SnapshotSlot`s in the trace's flat `snapshot_slots` array. For a
//! precise (v1) trace the vector is FULL — every physical register in the
//! anchor window appears exactly once, ascending, including dead temporaries
//! (`slots_len == register_count == anchor.proto.num_registers`); unwritten
//! slots reference entry `slot_load`s. The `slot` field exists so a future
//! sparse form is a validation change, not a schema change.
//!
//! Ownership: `TraceCode` owns both arrays (`snapshots`, `snapshot_slots`),
//! freed in its deinit and every candidate error path. The recorder builds
//! them through `Builder` — allocator-injected reusable scratch (Z-4), reset
//! between recordings, NO per-iteration allocation, and deterministic
//! admission budgets that depend only on the recorded maps (never available
//! memory or addresses). Identical vectors are interned; exceeding any budget
//! is admission refusal (`error.SnapshotLimit` → the recorder aborts with its
//! dedicated `snapshot_limit` reason — no partial candidate ever publishes).
//!
//! `IrInstr.snap` uses 0 for entry replay; POSITIVE values are one-based
//! indexes into `TraceCode.snapshots` (doc 45 D2).

const std = @import("std");
const trace_ir = @import("trace_ir.zig");

pub const Ref = trace_ir.Ref;
pub const SnapIdx = trace_ir.SnapIdx;

/// How a trace's guard failures restore guest state (doc 45 D2).
/// `entry_replay` is the legacy contract: re-run the iteration from the
/// trace-entry keyframe (sound only while every recorded effect is
/// replay-idempotent). `precise` restores from per-bytecode snapshots and
/// resumes mid-iteration — required the moment a trace records an effect
/// that must EXECUTE ONCE (table allocation, general stores).
pub const DeoptMode = enum(u8) { entry_replay = 0, precise = 1 };

/// One per-bytecode deopt record. Two PCs may SHARE a slot vector (interning)
/// while remaining distinct records.
pub const Snapshot = struct {
    /// Guest PC to resume at: the CURRENT instruction for a failing
    /// precondition (never a branch target, no sub-bytecode resume).
    resume_pc: u32,
    /// First `SnapshotSlot` of this record's vector in the flat array.
    slots_begin: u32,
    /// Vector length. u32 deliberately (Opus r5): the per-candidate slot
    /// budget is 65536, which overflows u16.
    slots_len: u32,
    /// The anchor window width this vector covers (`proto.num_registers`).
    register_count: u16,
};

/// One captured register: physical `slot` (activation-relative) → the IR ref
/// holding its value at the snapshot boundary.
pub const SnapshotSlot = struct {
    slot: u16,
    ref: Ref,
};

/// Deterministic admission budgets (doc 45 D2). Defaults are the contract
/// values; tests inject smaller ones to exercise exact-boundary and one-over
/// refusal without building 65k-slot fixtures.
pub const Budget = struct {
    /// Distinct interned slot VECTORS per candidate (not records).
    max_vectors: u32 = 256,
    /// `Snapshot` records per candidate.
    max_records: u32 = 2000,
    /// Flat `SnapshotSlot` entries per candidate, including scratch.
    max_slots: u32 = 65536,
};

fn slotVecEql(a: []const SnapshotSlot, b: []const SnapshotSlot) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.slot != y.slot or x.ref != y.ref) return false;
    }
    return true;
}

pub const Error = error{
    /// A deterministic admission budget was exceeded — the recorder must
    /// abort this candidate with its `snapshot_limit` reason.
    SnapshotLimit,
} || std.mem.Allocator.Error;

/// Recorder-side snapshot accumulator. Reusable across recordings via
/// `reset()`; owns nothing after `finalize` hands the arrays to the trace.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    budget: Budget,
    records: std.ArrayListUnmanaged(Snapshot) = .empty,
    slots: std.ArrayListUnmanaged(SnapshotSlot) = .empty,
    /// One entry per DISTINCT interned vector: its (begin, len) in `slots`.
    /// Bounded by `budget.max_vectors` (≤256), so intern lookup is a linear
    /// scan over same-length candidates — bounded, allocation-free and
    /// deterministic.
    vectors: std.ArrayListUnmanaged(struct { begin: u32, len: u32 }) = .empty,

    pub fn init(gpa: std.mem.Allocator, budget: Budget) Builder {
        return .{ .gpa = gpa, .budget = budget };
    }

    pub fn deinit(self: *Builder) void {
        self.records.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.vectors.deinit(self.gpa);
    }

    /// Drop all accumulated state, keeping capacity (the "reusable lists" of
    /// D2 — a discarded candidate costs no reallocation on the next one).
    pub fn reset(self: *Builder) void {
        self.records.clearRetainingCapacity();
        self.slots.clearRetainingCapacity();
        self.vectors.clearRetainingCapacity();
    }

    /// Append one snapshot record whose vector is `slots` (full window,
    /// ascending — the caller builds it in bounded scratch). Interns the
    /// vector: an identical existing vector is shared, a novel one is copied
    /// into the flat array. Returns the ONE-BASED index for `IrInstr.snap`.
    /// Budget overflow → `error.SnapshotLimit`; the check happens BEFORE any
    /// allocation (doc 45 D2).
    pub fn add(self: *Builder, resume_pc: u32, register_count: u16, vec: []const SnapshotSlot) Error!SnapIdx {
        if (self.records.items.len >= self.budget.max_records) return error.SnapshotLimit;

        const begin_len: struct { u32, u32 } = blk: {
            // Intern: reuse an existing identical vector when present.
            for (self.vectors.items) |v| {
                if (v.len != vec.len) continue;
                const existing = self.slots.items[v.begin..][0..v.len];
                if (slotVecEql(existing, vec)) break :blk .{ v.begin, v.len };
            }
            // Novel vector: budget checks BEFORE the copy.
            if (self.vectors.items.len >= self.budget.max_vectors) return error.SnapshotLimit;
            if (self.slots.items.len + vec.len > self.budget.max_slots) return error.SnapshotLimit;
            const begin: u32 = @intCast(self.slots.items.len);
            try self.slots.appendSlice(self.gpa, vec);
            try self.vectors.append(self.gpa, .{ .begin = begin, .len = @intCast(vec.len) });
            break :blk .{ begin, @as(u32, @intCast(vec.len)) };
        };

        try self.records.append(self.gpa, .{
            .resume_pc = resume_pc,
            .slots_begin = begin_len[0],
            .slots_len = begin_len[1],
            .register_count = register_count,
        });
        return @intCast(self.records.items.len); // one-based
    }

    /// Hand the accumulated arrays to the trace as owned slices (the builder
    /// stays reusable — `reset()` for the next candidate). The caller frees
    /// both via the same allocator (TraceCode.deinit / candidate error paths).
    pub fn finalize(self: *Builder, gpa: std.mem.Allocator) std.mem.Allocator.Error!Owned {
        const snaps = try gpa.dupe(Snapshot, self.records.items);
        errdefer gpa.free(snaps);
        const slots = try gpa.dupe(SnapshotSlot, self.slots.items);
        return .{ .snapshots = snaps, .snapshot_slots = slots };
    }

    pub const Owned = struct {
        snapshots: []Snapshot,
        snapshot_slots: []SnapshotSlot,

        pub fn deinit(self: Owned, gpa: std.mem.Allocator) void {
            gpa.free(self.snapshots);
            gpa.free(self.snapshot_slots);
        }
    };
};

/// Structural validation shared by finalization and deserialization (doc 45
/// D2/D8): every record's vector must lie inside the flat array; a precise
/// (full-window) vector covers every physical register exactly once in
/// ascending order; `resume_pc` must be inside the anchor proto's code.
/// Returns false rather than an error — callers translate into their own
/// abort/reject path (finalization aborts recording, the decoder rejects the
/// file). Ref-definedness at each USE site needs the instruction index and is
/// checked separately by `refsDefinedAt`.
pub fn validate(
    snapshots: []const Snapshot,
    snapshot_slots: []const SnapshotSlot,
    code_len: u32,
) bool {
    for (snapshots) |s| {
        if (s.resume_pc >= code_len) return false;
        if (s.slots_begin > snapshot_slots.len) return false;
        if (snapshot_slots.len - s.slots_begin < s.slots_len) return false;
        if (s.slots_len != s.register_count) return false; // v1: full window only
        const vec = snapshot_slots[s.slots_begin..][0..s.slots_len];
        for (vec, 0..) |slot, k| {
            // Full window, ascending, exactly once → slot k names register k.
            if (slot.slot != k) return false;
        }
    }
    return true;
}

/// Every ref a snapshot captures must already be defined when the op that
/// carries it can fail: `ref < use_index` (a forward ref would read an
/// undefined value at the exit — doc 45 D8 rejects it). `snap` is the
/// one-based `IrInstr.snap` value; 0 (entry replay) is trivially valid.
pub fn refsDefinedAt(
    snap: SnapIdx,
    use_index: usize,
    snapshots: []const Snapshot,
    snapshot_slots: []const SnapshotSlot,
) bool {
    if (snap == 0) return true;
    if (snap > snapshots.len) return false;
    const s = snapshots[snap - 1];
    const vec = snapshot_slots[s.slots_begin..][0..s.slots_len];
    for (vec) |slot| {
        if (slot.ref >= use_index) return false;
    }
    return true;
}

/// Pure ref remapping for the optimizer (doc 45 D2/D8: serialized snapshot
/// refs are committed IR refs, never pointers): after tropt renumbers the
/// instruction stream, every captured ref is rewritten through `new_index`
/// (indexed by the CANONICAL old ref, matching tropt's operand remap). The
/// slot structure is untouched.
pub fn remapRefs(snapshot_slots: []SnapshotSlot, canon: []const Ref, new_index: []const Ref) void {
    for (snapshot_slots) |*slot| {
        slot.ref = new_index[canon[slot.ref]];
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fullVec(buf: []SnapshotSlot, refs: []const Ref) []SnapshotSlot {
    for (refs, 0..) |r, k| buf[k] = .{ .slot = @intCast(k), .ref = r };
    return buf[0..refs.len];
}

test "builder interns identical vectors and keeps distinct records" {
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    var buf: [4]SnapshotSlot = undefined;

    const s1 = try b.add(7, 3, fullVec(&buf, &.{ 0, 1, 2 }));
    const s2 = try b.add(9, 3, fullVec(&buf, &.{ 0, 1, 2 })); // same vector, new pc
    const s3 = try b.add(9, 3, fullVec(&buf, &.{ 0, 1, 5 })); // new vector

    try testing.expectEqual(@as(SnapIdx, 1), s1);
    try testing.expectEqual(@as(SnapIdx, 2), s2);
    try testing.expectEqual(@as(SnapIdx, 3), s3);
    try testing.expectEqual(@as(usize, 3), b.records.items.len);
    // Two distinct vectors → 6 flat slots, not 9.
    try testing.expectEqual(@as(usize, 6), b.slots.items.len);
    try testing.expectEqual(b.records.items[0].slots_begin, b.records.items[1].slots_begin);
    try testing.expect(b.records.items[2].slots_begin != b.records.items[0].slots_begin);
    // Distinct records survive interning (the 256 limit is on vectors).
    try testing.expectEqual(@as(u32, 7), b.records.items[0].resume_pc);
    try testing.expectEqual(@as(u32, 9), b.records.items[1].resume_pc);
}

test "budgets refuse at exactly one-over, and interning does not charge the vector budget" {
    var buf: [4]SnapshotSlot = undefined;

    // max_records: 2 admitted, third refused.
    {
        var b = Builder.init(testing.allocator, .{ .max_records = 2 });
        defer b.deinit();
        _ = try b.add(0, 1, fullVec(&buf, &.{0}));
        _ = try b.add(1, 1, fullVec(&buf, &.{0}));
        try testing.expectError(error.SnapshotLimit, b.add(2, 1, fullVec(&buf, &.{0})));
    }
    // max_vectors: two DISTINCT vectors with a shared third add fine at
    // limit 2; a novel third vector refuses.
    {
        var b = Builder.init(testing.allocator, .{ .max_vectors = 2 });
        defer b.deinit();
        _ = try b.add(0, 1, fullVec(&buf, &.{7}));
        _ = try b.add(1, 1, fullVec(&buf, &.{8}));
        _ = try b.add(2, 1, fullVec(&buf, &.{7})); // interned — no new vector
        try testing.expectError(error.SnapshotLimit, b.add(3, 1, fullVec(&buf, &.{9})));
    }
    // max_slots: exact fill passes, one-over refuses BEFORE any partial copy.
    {
        var b = Builder.init(testing.allocator, .{ .max_slots = 4 });
        defer b.deinit();
        _ = try b.add(0, 2, fullVec(&buf, &.{ 1, 2 }));
        _ = try b.add(1, 2, fullVec(&buf, &.{ 3, 4 })); // exactly 4 flat slots
        try testing.expectError(error.SnapshotLimit, b.add(2, 2, fullVec(&buf, &.{ 5, 6 })));
        try testing.expectEqual(@as(usize, 4), b.slots.items.len); // no partial copy
    }
}

test "reset reuses capacity and clears interning" {
    var b = Builder.init(testing.allocator, .{ .max_vectors = 1 });
    defer b.deinit();
    var buf: [4]SnapshotSlot = undefined;
    _ = try b.add(0, 2, fullVec(&buf, &.{ 1, 2 }));
    try testing.expectError(error.SnapshotLimit, b.add(1, 2, fullVec(&buf, &.{ 3, 4 })));
    b.reset();
    // After reset the vector budget is available again.
    _ = try b.add(0, 2, fullVec(&buf, &.{ 3, 4 }));
    try testing.expectEqual(@as(usize, 1), b.records.items.len);
}

test "finalize hands owned copies; builder remains reusable" {
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    var buf: [4]SnapshotSlot = undefined;
    _ = try b.add(4, 2, fullVec(&buf, &.{ 9, 10 }));
    const owned = try b.finalize(testing.allocator);
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), owned.snapshots.len);
    try testing.expectEqual(@as(usize, 2), owned.snapshot_slots.len);
    b.reset();
    _ = try b.add(5, 1, fullVec(&buf, &.{0}));
    // The owned copy is unaffected by later builder use.
    try testing.expectEqual(@as(u32, 4), owned.snapshots[0].resume_pc);
}

test "validate enforces bounds, full ascending window and resume pc" {
    const slots = [_]SnapshotSlot{
        .{ .slot = 0, .ref = 3 },
        .{ .slot = 1, .ref = 4 },
    };
    const good = [_]Snapshot{.{ .resume_pc = 5, .slots_begin = 0, .slots_len = 2, .register_count = 2 }};
    try testing.expect(validate(&good, &slots, 10));
    // resume_pc out of code.
    const bad_pc = [_]Snapshot{.{ .resume_pc = 10, .slots_begin = 0, .slots_len = 2, .register_count = 2 }};
    try testing.expect(!validate(&bad_pc, &slots, 10));
    // Vector escapes the flat array (overflow-safe form).
    const bad_range = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 1, .slots_len = 2, .register_count = 2 }};
    try testing.expect(!validate(&bad_range, &slots, 10));
    const bad_begin = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 3, .slots_len = 0, .register_count = 0 }};
    try testing.expect(!validate(&bad_begin, &slots, 10));
    // Sparse vector (len != register_count) is not v1-valid.
    const sparse = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 1, .register_count = 2 }};
    try testing.expect(!validate(&sparse, &slots, 10));
    // Non-ascending / duplicated slot.
    const dup_slots = [_]SnapshotSlot{ .{ .slot = 1, .ref = 3 }, .{ .slot = 1, .ref = 4 } };
    const dup = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 2 }};
    try testing.expect(!validate(&dup, &dup_slots, 10));
}

test "refsDefinedAt rejects forward refs and out-of-range snap indexes" {
    const slots = [_]SnapshotSlot{
        .{ .slot = 0, .ref = 3 },
        .{ .slot = 1, .ref = 7 },
    };
    const snaps = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 2 }};
    try testing.expect(refsDefinedAt(0, 0, &snaps, &slots)); // entry replay: always
    try testing.expect(refsDefinedAt(1, 8, &snaps, &slots)); // 3,7 < 8
    try testing.expect(!refsDefinedAt(1, 7, &snaps, &slots)); // ref 7 not yet defined
    try testing.expect(!refsDefinedAt(2, 100, &snaps, &slots)); // no such record
}

test "remapRefs rewrites through canon + new_index, structure untouched" {
    var slots = [_]SnapshotSlot{
        .{ .slot = 0, .ref = 2 },
        .{ .slot = 1, .ref = 3 },
    };
    // canon: 3 aliases 1 (CSE); new_index: 1→0, 2→1.
    const canon = [_]Ref{ 0, 1, 2, 1 };
    const new_index = [_]Ref{ 0, 0, 1, 0 };
    remapRefs(&slots, &canon, &new_index);
    try testing.expectEqual(@as(Ref, 1), slots[0].ref); // 2 → canon 2 → new 1
    try testing.expectEqual(@as(Ref, 0), slots[1].ref); // 3 → canon 1 → new 0
    try testing.expectEqual(@as(u16, 0), slots[0].slot);
    try testing.expectEqual(@as(u16, 1), slots[1].slot);
}
