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

    /// Doc 56 §4.2: append one SPARSE exit snapshot (only the slots the
    /// recording has written, ascending). Unlike `add`, interning compares
    /// against the MOST RECENT vector only: consecutive guard-bearing
    /// bytecodes that wrote nothing in between share a vector, and the cost
    /// is O(len) per call rather than O(vectors × len) — an ordinary trace
    /// can carry hundreds of exit snapshots, and recording cost must not
    /// grow quadratically with trace length (Rule #20). `max_vectors` is
    /// not consulted (records bound vectors); `max_records`/`max_slots` are,
    /// before any allocation. Returns the one-based record index.
    pub fn addSparse(self: *Builder, resume_pc: u32, register_count: u16, vec: []const SnapshotSlot) Error!SnapIdx {
        if (self.records.items.len >= self.budget.max_records) return error.SnapshotLimit;
        const begin_len: struct { u32, u32 } = blk: {
            if (self.vectors.items.len != 0) {
                const v = self.vectors.items[self.vectors.items.len - 1];
                if (v.len == vec.len and slotVecEql(self.slots.items[v.begin..][0..v.len], vec))
                    break :blk .{ v.begin, v.len };
            }
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

    /// A rewind point (doc 56 §4.2): the builder's lengths at some moment of
    /// recording. `truncate` drops everything added after it, so a recorder
    /// rewind (doc 47's peel fallback) can discard the snapshots of the
    /// truncated IR without discarding the earlier, still-valid ones.
    pub const Mark = struct { records: u32, slots: u32, vectors: u32 };

    pub fn mark(self: *const Builder) Mark {
        return .{
            .records = @intCast(self.records.items.len),
            .slots = @intCast(self.slots.items.len),
            .vectors = @intCast(self.vectors.items.len),
        };
    }

    /// Drop every record, vector and slot added after `m` (keeps capacity).
    pub fn truncate(self: *Builder, m: Mark) void {
        std.debug.assert(m.records <= self.records.items.len);
        std.debug.assert(m.slots <= self.slots.items.len);
        std.debug.assert(m.vectors <= self.vectors.items.len);
        self.records.items.len = m.records;
        self.slots.items.len = m.slots;
        self.vectors.items.len = m.vectors;
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

/// Doc 56 §4.2: structural validation of SPARSE exit snapshots. Each
/// record's vector lies inside the flat array, names strictly ascending
/// slots below `register_count` (each at most once), and resumes inside the
/// anchor proto's code. Returns false rather than an error (the finalizer
/// drops the exit snapshots — they are fail-soft metadata, never a reason to
/// refuse a trace).
pub fn validateSparse(
    snapshots: []const Snapshot,
    snapshot_slots: []const SnapshotSlot,
    code_len: u32,
) bool {
    for (snapshots) |s| {
        if (s.resume_pc >= code_len) return false;
        if (s.slots_begin > snapshot_slots.len) return false;
        if (snapshot_slots.len - s.slots_begin < s.slots_len) return false;
        const vec = snapshot_slots[s.slots_begin..][0..s.slots_len];
        for (vec, 0..) |slot, k| {
            if (slot.slot >= s.register_count) return false;
            if (k != 0 and vec[k - 1].slot >= slot.slot) return false;
        }
    }
    return true;
}

/// Doc 56 §4.2: keep only the records `by_ord` still names (`tropt` zeroes
/// the ordinals whose every exit it removed), in ordinal order, and renumber
/// `by_ord` to the compacted records. A vector shared by a run of kept
/// records stays shared (vectors are only ever shared by consecutive
/// records — `Builder.addSparse`). Returns null, touching nothing, when
/// `by_ord` names a record outside `snapshots` or a vector outside
/// `snapshot_slots` (the caller drops the exit snapshots — fail-soft
/// metadata); `by_ord` is rewritten only after both allocations succeed, so
/// an error leaves it untouched too. Nothing kept → empty slices, no
/// allocation. O(ordinals + kept slots).
pub fn compactSparse(
    gpa: std.mem.Allocator,
    snapshots: []const Snapshot,
    snapshot_slots: []const SnapshotSlot,
    by_ord: []SnapIdx,
) std.mem.Allocator.Error!?Builder.Owned {
    var n_recs: usize = 0;
    var n_slots: usize = 0;
    var last: ?Snapshot = null;
    for (by_ord) |si| {
        if (si == 0) continue;
        if (si > snapshots.len) return null;
        const r = snapshots[si - 1];
        if (r.slots_begin > snapshot_slots.len or snapshot_slots.len - r.slots_begin < r.slots_len) return null;
        n_recs += 1;
        if (last) |l| if (l.slots_begin == r.slots_begin and l.slots_len == r.slots_len) continue;
        last = r;
        n_slots += r.slots_len;
    }
    if (n_recs == 0) return .{ .snapshots = &.{}, .snapshot_slots = &.{} };
    const out_snaps = try gpa.alloc(Snapshot, n_recs);
    errdefer gpa.free(out_snaps);
    const out_slots = try gpa.alloc(SnapshotSlot, n_slots);
    var k: usize = 0;
    var pos: u32 = 0;
    var new_begin: u32 = 0;
    last = null;
    for (by_ord) |*si| {
        if (si.* == 0) continue;
        const r = snapshots[si.* - 1];
        const shared = if (last) |l| l.slots_begin == r.slots_begin and l.slots_len == r.slots_len else false;
        if (!shared) {
            @memcpy(out_slots[pos..][0..r.slots_len], snapshot_slots[r.slots_begin..][0..r.slots_len]);
            new_begin = pos;
            pos += r.slots_len;
            last = r;
        }
        out_snaps[k] = .{ .resume_pc = r.resume_pc, .slots_begin = new_begin, .slots_len = r.slots_len, .register_count = r.register_count };
        k += 1;
        si.* = @intCast(k);
    }
    return .{ .snapshots = out_snaps, .snapshot_slots = out_slots };
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

test "addSparse shares only an identical PREVIOUS vector and keeps records distinct" {
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    const v1 = [_]SnapshotSlot{ .{ .slot = 2, .ref = 5 }, .{ .slot = 7, .ref = 9 } };
    const v2 = [_]SnapshotSlot{.{ .slot = 2, .ref = 6 }};
    const empty = [_]SnapshotSlot{};

    try testing.expectEqual(@as(SnapIdx, 1), try b.addSparse(3, 8, &v1));
    try testing.expectEqual(@as(SnapIdx, 2), try b.addSparse(4, 8, &v1)); // shares
    try testing.expectEqual(@as(usize, 2), b.slots.items.len);
    try testing.expectEqual(b.records.items[0].slots_begin, b.records.items[1].slots_begin);

    _ = try b.addSparse(5, 8, &v2); // novel
    try testing.expectEqual(@as(usize, 3), b.slots.items.len);
    // v1 again is NOT interned against the older copy (last-vector-only).
    _ = try b.addSparse(6, 8, &v1);
    try testing.expectEqual(@as(usize, 5), b.slots.items.len);

    // An empty vector (nothing written yet) is a legal record.
    _ = try b.addSparse(0, 8, &empty);
    try testing.expectEqual(@as(u32, 0), b.records.items[4].slots_len);
    try testing.expectEqual(@as(usize, 5), b.records.items.len);
    try testing.expectEqual(@as(u32, 6), b.records.items[3].resume_pc);

    const owned = try b.finalize(testing.allocator);
    defer owned.deinit(testing.allocator);
    try testing.expect(validateSparse(owned.snapshots, owned.snapshot_slots, 10));
}

test "addSparse refuses at max_records / max_slots before any copy, ignores max_vectors" {
    const a = [_]SnapshotSlot{ .{ .slot = 0, .ref = 1 }, .{ .slot = 1, .ref = 2 } };
    const c = [_]SnapshotSlot{ .{ .slot = 0, .ref = 3 }, .{ .slot = 1, .ref = 4 } };
    {
        var b = Builder.init(testing.allocator, .{ .max_records = 2 });
        defer b.deinit();
        _ = try b.addSparse(0, 2, &a);
        _ = try b.addSparse(1, 2, &a);
        try testing.expectError(error.SnapshotLimit, b.addSparse(2, 2, &a));
    }
    {
        var b = Builder.init(testing.allocator, .{ .max_slots = 4 });
        defer b.deinit();
        _ = try b.addSparse(0, 2, &a);
        _ = try b.addSparse(1, 2, &c); // exactly 4
        _ = try b.addSparse(2, 2, &c); // shared with previous → no slot charge
        try testing.expectError(error.SnapshotLimit, b.addSparse(3, 2, &a));
        try testing.expectEqual(@as(usize, 4), b.slots.items.len);
        try testing.expectEqual(@as(usize, 3), b.records.items.len);
    }
    {
        var b = Builder.init(testing.allocator, .{ .max_vectors = 1 });
        defer b.deinit();
        _ = try b.addSparse(0, 2, &a);
        _ = try b.addSparse(1, 2, &c);
        _ = try b.addSparse(2, 2, &a);
        try testing.expectEqual(@as(usize, 3), b.records.items.len);
    }
}

test "mark/truncate drops only what came after the mark" {
    var b = Builder.init(testing.allocator, .{});
    defer b.deinit();
    const a = [_]SnapshotSlot{.{ .slot = 0, .ref = 1 }};
    const c = [_]SnapshotSlot{.{ .slot = 0, .ref = 2 }};
    _ = try b.addSparse(0, 2, &a);
    const m = b.mark();
    _ = try b.addSparse(1, 2, &a); // shared
    _ = try b.addSparse(2, 2, &c); // novel
    b.truncate(m);
    try testing.expectEqual(@as(usize, 1), b.records.items.len);
    try testing.expectEqual(@as(usize, 1), b.slots.items.len);
    try testing.expectEqual(@as(usize, 1), b.vectors.items.len);
    // Sharing resumes against the surviving last vector.
    try testing.expectEqual(@as(SnapIdx, 2), try b.addSparse(3, 2, &a));
    try testing.expectEqual(@as(usize, 1), b.slots.items.len);
}

test "validateSparse accepts ascending subsets, rejects disorder, dups, range and pc" {
    const slots = [_]SnapshotSlot{
        .{ .slot = 1, .ref = 3 },
        .{ .slot = 4, .ref = 4 },
    };
    const good = [_]Snapshot{
        .{ .resume_pc = 5, .slots_begin = 0, .slots_len = 2, .register_count = 5 },
        .{ .resume_pc = 6, .slots_begin = 1, .slots_len = 1, .register_count = 5 },
        .{ .resume_pc = 7, .slots_begin = 2, .slots_len = 0, .register_count = 5 },
    };
    try testing.expect(validateSparse(&good, &slots, 10));
    // Slot 4 is outside a 4-register window.
    const narrow = [_]Snapshot{.{ .resume_pc = 5, .slots_begin = 0, .slots_len = 2, .register_count = 4 }};
    try testing.expect(!validateSparse(&narrow, &slots, 10));
    // resume_pc out of code.
    const bad_pc = [_]Snapshot{.{ .resume_pc = 10, .slots_begin = 0, .slots_len = 2, .register_count = 5 }};
    try testing.expect(!validateSparse(&bad_pc, &slots, 10));
    // Vector escapes the flat array.
    const bad_range = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 1, .slots_len = 2, .register_count = 5 }};
    try testing.expect(!validateSparse(&bad_range, &slots, 10));
    const bad_begin = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 3, .slots_len = 0, .register_count = 5 }};
    try testing.expect(!validateSparse(&bad_begin, &slots, 10));
    // Descending and duplicated slots.
    const desc_slots = [_]SnapshotSlot{ .{ .slot = 4, .ref = 3 }, .{ .slot = 1, .ref = 4 } };
    const dup_slots = [_]SnapshotSlot{ .{ .slot = 1, .ref = 3 }, .{ .slot = 1, .ref = 4 } };
    const two = [_]Snapshot{.{ .resume_pc = 0, .slots_begin = 0, .slots_len = 2, .register_count = 5 }};
    try testing.expect(!validateSparse(&two, &desc_slots, 10));
    try testing.expect(!validateSparse(&two, &dup_slots, 10));
}

test "compactSparse keeps the named records in order, keeps runs shared, renumbers by_ord" {
    const gpa = testing.allocator;
    // Records 1 and 2 share vector [0,2); record 3 owns [2,3).
    const snaps = [_]Snapshot{
        .{ .resume_pc = 4, .slots_begin = 0, .slots_len = 2, .register_count = 8 },
        .{ .resume_pc = 5, .slots_begin = 0, .slots_len = 2, .register_count = 8 },
        .{ .resume_pc = 6, .slots_begin = 2, .slots_len = 1, .register_count = 8 },
    };
    const slots = [_]SnapshotSlot{ .{ .slot = 0, .ref = 7 }, .{ .slot = 3, .ref = 8 }, .{ .slot = 5, .ref = 9 } };

    // Drop the FIRST of the shared run: its partner still owns the vector.
    var by_ord = [_]SnapIdx{ 0, 0, 2, 0, 3 };
    const o = (try compactSparse(gpa, &snaps, &slots, &by_ord)).?;
    defer o.deinit(gpa);
    try testing.expectEqualSlices(SnapIdx, &.{ 0, 0, 1, 0, 2 }, &by_ord);
    try testing.expectEqual(@as(usize, 2), o.snapshots.len);
    try testing.expectEqualSlices(SnapshotSlot, &slots, o.snapshot_slots);
    try testing.expectEqual(@as(u32, 5), o.snapshots[0].resume_pc);
    try testing.expectEqual(@as(u32, 0), o.snapshots[0].slots_begin);
    try testing.expectEqual(@as(u32, 2), o.snapshots[1].slots_begin);

    // Keep the whole shared run: the vector is copied once, not twice.
    var by_ord2 = [_]SnapIdx{ 0, 1, 2 };
    const o2 = (try compactSparse(gpa, &snaps, &slots, &by_ord2)).?;
    defer o2.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), o2.snapshot_slots.len);
    try testing.expectEqual(o2.snapshots[0].slots_begin, o2.snapshots[1].slots_begin);

    // Nothing kept → empty, no allocation; an out-of-range record → null,
    // with by_ord untouched.
    var none = [_]SnapIdx{ 0, 0 };
    const o3 = (try compactSparse(gpa, &snaps, &slots, &none)).?;
    try testing.expectEqual(@as(usize, 0), o3.snapshots.len);
    var bad = [_]SnapIdx{ 0, 4 };
    try testing.expect((try compactSparse(gpa, &snaps, &slots, &bad)) == null);
    try testing.expectEqualSlices(SnapIdx, &.{ 0, 4 }, &bad);
}
