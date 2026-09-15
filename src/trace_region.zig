//! The region data model: the types the region-accounting layer is built out of.
//!
//! A *region* is a strongly-connected component of the structural trace graph
//! that contains a cycle — the guest-logical unit the exit-branch-patching gate
//! reasons about. This module owns the vocabulary (identity, discovery output,
//! per-activation accumulator, observer caches) and nothing else.
//!
//! SCOPE, deliberately: the region *policy* — `openRegion`, `closeRegion`,
//! `flushRegionWindow`, `accountRegionProfit`, `rebuildRegions`,
//! `validateRegionBridge` and the rest — stays on `TraceState` in `trace.zig`.
//! Those functions reach into `penalty`, `gate`, `promoted_sets`, `gateAnchor`,
//! `condemnProvenanceEdgesAt` and `disarmAllLinks`; at this revision the region
//! layer IS the tiering policy layer, and there is no boundary to cut along
//! without changing behaviour. Extracting the state-free data model is the part
//! that can be done as a pure move, so it is the part that was done.

const std = @import("std");
const trace_types = @import("trace_types.zig");

const StructuralEdgeId = trace_types.StructuralEdgeId;
const ProgramPoint = trace_types.ProgramPoint;
const AnchorKey = trace_types.AnchorKey;

// ---------------------------------------------------------------------------
// Region model (doc 17 §A3.3 / §A3.5 / §A8-ii, A-ii.4)
//
// A *region* is a strongly-connected component of the structural trace graph
// (`StructuralEdgeId` edges over `{proto_id, pc}` anchor nodes) that contains a
// cycle — the guest-logical unit the exit-branch-patching gate reasons about. A-ii
// made discovery/classification queryable; A-iv consumes it only into transient
// `region_profit`. No selection/gating path reads that accumulator yet.
// ---------------------------------------------------------------------------

/// Opaque interned handle for a region (doc 17 §A3.3): assigned sequentially by the
/// intern map, NEVER a bare hash. Interned on the region's canonical sorted INTERNAL
/// `StructuralEdgeId` set, so a re-recorded logically-identical region (new
/// `Trace.id`s) re-interns to the SAME id.
pub const RegionId = enum(u64) { _ };

/// Per-activation identity and accounting payload for doc 17 A-iv/A-vii. The map
/// is transient tiering state: it is never serialized. As of A-vii-c the window
/// flushes drive the penalty/gate state machine (keyed by the region OWNER
/// anchor); the accumulator itself is still never a selection input.
pub const RegionKey = struct {
    region_id: RegionId,
    activation: u64,
};

pub const RegionAccum = struct {
    outer_traversals: u64 = 0,
    window_base: u64 = 0,
    root_frame_depth: u32,
    root_call_seq: u64,
    /// A-vii qualification latch (doc 17 §A8-iii seam): true once this activation
    /// has committed at least one complete `N = min_useful` window. Structural
    /// eligibility (`RegionDef.armable`) is not profitability — A-vii-d's arm site
    /// requires BOTH. Activation-local: a fresh `openRegion` starts false.
    useful_window_seen: bool = false,
    /// Gate-fix arc (2026-08-12): consecutive CONSUMED zero-work receipts since
    /// the last credited work. At `config.max_barren_run` the streak flushes a
    /// synthetic low-yield verdict (`noteBarrenConsumed`) so a qualified
    /// activation that decays into barren-only execution is still priced.
    barren_run: u32 = 0,
    /// Freeze-after-qualify (task #70): consecutive USEFUL window flushes since
    /// the last strike. At `config.freeze_windows` the activation FREEZES —
    /// `replayLedger` stops running the full classify/choose/destination
    /// pipeline per ledger row for member→member transitions and just credits
    /// this accumulator directly (see the frozen fast path there). Any strike
    /// (`flushRegionWindow` low-yield, incl. the barren-run synthetic verdict)
    /// unfreezes and zeroes the streak, so a decaying region drops straight
    /// back to full pricing. Pure function of the receipt stream — every mode
    /// freezes/unfreezes on the same receipt.
    useful_streak: u32 = 0,
    frozen: bool = false,
};

/// Destination knowledge carried by a concrete trace receipt. A selected trace
/// is classified through `dest_entry_regions`; `.deferred` deliberately retains
/// the source accumulator until a later receipt/program-point resolves departure.
pub const RegionDestination = union(enum) {
    deferred,
    known_trace: u32,
    terminal_outside,
};

pub const RegionContext = struct {
    depth: u32,
    call_seq: u64,
};

/// A-vii-e.1: one proto's membership bitset for the observer fast path. Bit
/// `pc - base_pc` of `words` is set iff `{proto_id, pc}` is a member point of
/// the cached region. `words` is owned by TraceState (copied out of the def's
/// `member_points` at refresh time — never borrows def memory, so a later
/// `clearCache` def free cannot dangle it).
pub const ObserverSpan = struct {
    proto_id: u32,
    base_pc: u32,
    /// Exclusive pc bound (`base_pc + range`); pcs outside [base, limit) are
    /// non-members without touching `words`.
    limit_pc: u32,
    words: []u64,
};

/// A-vii-e.1: the single-accumulator fast path for `observeRegionProgramPoint`.
/// The observer runs PER INTERPRETED INSTRUCTION whenever `region_profit` is
/// non-empty — with A-vii-d's armable regions that is essentially the whole
/// run, and the original hashmap-iterator + linear `member_points` scan
/// measured 49% of nsieve wall time. This cache turns the survive verdict
/// (the overwhelmingly common one) into two integer compares and a bit test.
/// Valid only while `region_profit.count() == 1`; rebuilt by
/// `refreshObserverFast` at every map mutation (openRegion / closeRegion /
/// resetRegionProfit — the three funnels; clearCache resets via the third).
/// Pure accelerator: any refresh failure leaves it null and the observer takes
/// the original slow scan with identical semantics, so an OOM here cannot
/// diverge replay.
pub const ObserverFast = struct {
    key: RegionKey,
    root_frame_depth: u32,
    root_call_seq: u64,
    spans: []ObserverSpan,
};

/// A-vii-e.2: the INLINE half of the observer fast path. `ObserverFast` removed
/// the hashmap walk but left the per-instruction *call*, and on nsieve that call
/// is the dominant cost of the whole run — `perf annotate` attributes ~70% of
/// `observeRegionProgramPoint`'s 43.5% to its prologue/epilogue (`push rbp` + five
/// callee-saved pushes + `sub rsp, 0x68`, sized by the cold slow path), not to the
/// verdict, which is a few compares and a `btq`.
///
/// So cache the ONE span the last survive verdict resolved through, keyed by the
/// exact query that produced it (`proto_id`, `depth`, `call_seq`). `observeFast`
/// re-checks all three plus the membership bit inline; the predicate in
/// `observeRegionProgramPoint` is a pure function of those inputs and the
/// `ObserverFast` cache, so identical inputs re-derive the identical verdict.
/// Only a `true` needs to be sound — a `false` merely falls through to the real
/// observer, which decides. Invalidated wholesale by `freeObserverFast` (the sole
/// owner of the borrowed `words`), so it can neither dangle nor go stale.
pub const ObserverHot = struct {
    /// Borrowed from the owning `ObserverFast` span; null = cache cold.
    words: ?[*]const u64 = null,
    proto_id: u32 = 0,
    base_pc: u32 = 0,
    /// `limit_pc - base_pc`, precomputed so the probe is one unsigned compare.
    span_pcs: u32 = 0,
    depth: u32 = 0,
    call_seq: u64 = 0,
};

fn regionIdLess(_: void, a: RegionId, b: RegionId) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

/// Minimal region shape descriptor (doc 17 §A8-ii). A-vii reads `kind` to pick the
/// arming strategy; `member_count` is the anchor-node count of the cycle.
pub const RegionClassifier = struct {
    kind: enum { self_loop, cross_trace_cycle },
    member_count: u32,
};

/// Discovery-owned arm-time proof for one bridge-capable internal region edge.
/// The descriptor and both slot sets are canonical-sorted and owned by RegionDef.
pub const RegionBridgeDef = struct {
    edge: StructuralEdgeId,
    successor: AnchorKey,
    required_slots: []u16,
    invariant_slots: []u16,
};

/// A discovered region definition (doc 17 §A3.1 / §A3.5). Proto/VM-lifetime: kept in
/// `region_defs`, NEVER retirement-cleaned, cleared only on `clearCache`. Owns its
/// `members`/`member_points`/`bridges` slices.
pub const RegionDef = struct {
    /// The region's INTERNAL edges only (both endpoints in the SCC), canonical-sorted
    /// and deduped — the identity basis interned to the `RegionId`. Owned.
    members: []StructuralEdgeId,
    /// Membership program-point SET (doc 17 §A3.5): the union of member traces'
    /// recorded `{proto_id, source_pc}` paths (A-ii.3) plus each internal edge's
    /// validated handoff endpoints, sorted + deduped. Owned. A-iv's tier-0 region
    /// observer keys on this; A-ii uses it for the def-consistency rebind check.
    member_points: []ProgramPoint,
    /// Gate/penalty blast-radius key = the region's loop-root `{proto, root_pc}`
    /// (doc 17 §A2.6). Borrows a `*Proto` that outlives the region (proto lifetime ≥
    /// trace lifetime; both bounded by the `clearCache` epoch that frees `region_defs`).
    owner: AnchorKey,
    classifier: RegionClassifier,
    /// Bridge-capable internal edges and their whole-cycle liveness proofs. Owned;
    /// rebuilt on every successful discovery pass, including a same-id re-record.
    bridges: []RegionBridgeDef = &.{},
    /// Live arming eligibility, RECOMPUTED at every discovery rebind (A-vii-d.0):
    /// `armable = owner-unique ∧ membership-complete ∧ !tombstoned`. Recomputation
    /// is what makes armability reachable at all — a cycle is necessarily minted
    /// BEFORE its external-entry side trace records (the cycle triggers minting;
    /// the entry arrives later by hotguard), so first sight is always
    /// owner-not-unique and a frozen first-sight bit could never rise. Only
    /// `tombstoned` is sticky. The classification-index build excludes
    /// `armable == false` regions.
    armable: bool,
    /// The fail-closed sticky bit (split out of `armable` by A-vii-d.0): set by the
    /// runtime tombstone (`invalidateRegion` — validation failure, classification
    /// ambiguity, gate) AND by a def-inconsistent or truncated rebind (§A3.5
    /// finding 3). Never cleared for the lifetime of the `RegionId`; while set,
    /// recomputation can never re-arm the region. Distinguishes "the graph was
    /// incomplete when we looked" (recoverable) from "this region misbehaved"
    /// (permanent).
    tombstoned: bool = false,
    /// Doc 47 Increment B: true when the owner was elected by the CLOSED-SCC
    /// fallback tier (the unique loop-root destination of a continuation
    /// `.link_terminal` back-edge) rather than the primary external-entry /
    /// enclosing predicate. Refreshed per rebind alongside `armable`. Consumed
    /// by `applyWindowDecision`: a fallback-elected region that strikes out at
    /// `max_penalty` is TOMBSTONED (one-shot, back to the pre-inc-B status quo
    /// for that region) instead of repeatedly gating its owner anchor and
    /// tearing down every armed link — a dispatcher-entered closed cycle has no
    /// future entry edge that could ever change its yield, so low yield means
    /// the election itself was unprofitable (measured: fft's dual=1 butterfly
    /// phases, +96% wall from repeated gate+disarmAllLinks cycles).
    fallback_owner: bool = false,
    /// Doc 47 Increment B follow-up (demand-driven admission): a fallback-elected
    /// region mints DORMANT — excluded from the source/dest receipt maps so
    /// `receiptsInert()` keeps short-circuiting and receipts pay nothing for it.
    /// `tryDormantAdmission` clears the bit (once, per region lifetime, modulo an
    /// election-tier flip which resets all fallback learning) when a full-cap
    /// `.yielded` ledger proves a promotable set for the region — the exact
    /// evidence that the arming can amortize its per-receipt accounting tax.
    /// Measured: spectral-norm minted 2 armable-but-never-promoting regions and
    /// paid +16% wall in per-receipt classify/credit with zero payoff.
    dormant: bool = false,
    /// Saturating count of promotions destroyed by an `.unfreeze` demotion (a
    /// window strike killing a live promotion — "we paid to patch, then
    /// immediately unpatched"). Decremented when a promotion instead survives to
    /// a clean `.region_close` lifecycle demotion. At
    /// `config.region_instability_tombstone` a fallback region is invalidated:
    /// promote/demote oscillation (scimark-lu: 175k cycles/run at ~35
    /// transitions per burst, +28% wall) costs more than the drains it saves.
    instability: u8 = 0,
    /// Saturating count of full-cap `.yielded` ledgers observed for this ACTIVE,
    /// frozen fallback region that produced no promotable candidate — the
    /// region was admitted on good evidence but its physical topology stopped
    /// being promotable. At `config.region_no_candidate_tombstone`, invalidate.
    no_candidate_runs: u8 = 0,
    /// Deterministic net-work ledger, DEBIT side: lifetime count of priced
    /// receipts — the unit the region accounting tax is actually paid in
    /// (classify/choose/open per receipt). Charged in `chargePayoffReceipt`
    /// whenever this region is the effective activation for a receipt (or
    /// the min-id open activation for an unresolved one). NEVER reset by a
    /// promotion — "promotion occurred" and "promotion repaid the
    /// accumulated cost" are different facts (grid_matmul: 203 steady
    /// promotions, net-negative anyway). Windows and activations were both
    /// tried and rejected as the unit: scimark-lu's surviving region runs
    /// tiny activations whose windows never complete, keeping both proxies
    /// at zero while paying 12% wall in the per-receipt pipeline.
    receipts_debit: u64 = 0,
    /// Deterministic net-work ledger, CREDIT side: lifetime silent
    /// transitions suppressed by this region's promoted sets, rolled up at
    /// the burst drain (`driveSilentBurst`). Once `receipts_debit` passes
    /// the `region_payoff_receipts` minimum sample, the region survives only
    /// while `transitions_credit × region_profit_weight ≥ receipts_debit` —
    /// cumulative deterministic benefit must keep repaying cumulative
    /// accounting cost, or the region is invalidated.
    transitions_credit: u64 = 0,
    /// Saturating count of failed dormant-admission probes. At
    /// `config.region_admission_probe_cap` the region stops being probed —
    /// terminal dormancy, bounding probe cost on shapes that never qualify.
    admission_failures: u8 = 0,
};

pub fn freeRegionBridges(gpa: std.mem.Allocator, bridges: []RegionBridgeDef) void {
    for (bridges) |b| {
        gpa.free(b.required_slots);
        gpa.free(b.invariant_slots);
    }
    gpa.free(bridges);
}

pub fn cloneRegionBridges(gpa: std.mem.Allocator, src: []const RegionBridgeDef) ![]RegionBridgeDef {
    const out = try gpa.alloc(RegionBridgeDef, src.len);
    errdefer gpa.free(out);
    var initialized: usize = 0;
    errdefer for (out[0..initialized]) |b| {
        gpa.free(b.required_slots);
        gpa.free(b.invariant_slots);
    };
    for (src, out) |s, *d| {
        const required = try gpa.dupe(u16, s.required_slots);
        const invariants = gpa.dupe(u16, s.invariant_slots) catch |err| {
            gpa.free(required);
            return err;
        };
        d.* = .{
            .edge = s.edge,
            .successor = s.successor,
            .required_slots = required,
            .invariant_slots = invariants,
        };
        initialized += 1;
    }
    return out;
}

/// Interns a canonical-sorted `[]StructuralEdgeId` SET → a stable `RegionId`
/// (doc 17 §A3.3 / §A8-ii, A-ii.4). Hand-written (not `AutoHashMap`) because the key
/// is a variable-length slice compared by ELEMENT-WISE `StructuralEdgeId.eql` over the
/// sorted set — `std.mem.eql` would compare the padded tagged-union bytes. The 64-bit
/// fold of the per-edge hashes only selects the bucket; every hit is confirmed by set
/// equality, and a genuine hash collision (equal fold, unequal set) mints a DISTINCT
/// id. Owns a copy of each interned sorted slice. Buckets are `foldedHash → head entry
/// index`, chained intrusively through `Entry.next`, so a `internAssumeCapacity` after
/// `reserve(n)` is infallible (the transactional-publish requirement, §A8-ii).
pub const RegionInternMap = struct {
    pub const empty: RegionInternMap = .{};

    const Entry = struct { edges: []StructuralEdgeId, id: RegionId, next: i64 = -1 };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    buckets: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn foldHash(edges: []const StructuralEdgeId) u64 {
        var h = std.hash.Wyhash.init(0);
        for (edges) |e| {
            const eh = e.hash();
            h.update(std.mem.asBytes(&eh));
        }
        return h.final();
    }

    fn setsEqual(a: []const StructuralEdgeId, b: []const StructuralEdgeId) bool {
        if (a.len != b.len) return false;
        for (a, b) |ae, be| {
            if (!ae.eql(be)) return false;
        }
        return true;
    }

    /// Read-only lookup: the interned id for this sorted set, or null if absent. Used
    /// by discovery to distinguish rebind (existing id) from first-sight WITHOUT
    /// mutating (mutation is deferred to the infallible publish phase).
    pub fn lookup(self: *const RegionInternMap, edges: []const StructuralEdgeId) ?RegionId {
        const h = foldHash(edges);
        var idx: i64 = if (self.buckets.get(h)) |x| @intCast(x) else return null;
        while (idx >= 0) {
            const e = self.entries.items[@intCast(idx)];
            if (setsEqual(e.edges, edges)) return e.id;
            idx = e.next;
        }
        return null;
    }

    /// Reserve capacity for `n` new interns so the matching `internAssumeCapacity`
    /// calls are infallible (transactional publish). `n` is an upper bound —
    /// intra-pass hash collisions reuse a bucket slot.
    pub fn reserve(self: *RegionInternMap, gpa: std.mem.Allocator, n: usize) !void {
        try self.entries.ensureUnusedCapacity(gpa, n);
        try self.buckets.ensureUnusedCapacity(gpa, @intCast(n));
    }

    /// Insert a NEW region (caller has confirmed via `lookup` that it is absent) with
    /// a caller-owned duped edge slice + assigned id. Infallible after a covering
    /// `reserve`. Takes ownership of `owned_edges`.
    pub fn internAssumeCapacity(self: *RegionInternMap, owned_edges: []StructuralEdgeId, id: RegionId) void {
        const h = foldHash(owned_edges);
        const new_idx: u32 = @intCast(self.entries.items.len);
        const head: i64 = if (self.buckets.get(h)) |x| @intCast(x) else -1;
        self.entries.appendAssumeCapacity(.{ .edges = owned_edges, .id = id, .next = head });
        self.buckets.putAssumeCapacity(h, new_idx);
    }

    pub fn clear(self: *RegionInternMap, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.edges);
        self.entries.clearRetainingCapacity();
        self.buckets.clearRetainingCapacity();
    }

    pub fn deinit(self: *RegionInternMap, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.edges);
        self.entries.deinit(gpa);
        self.buckets.deinit(gpa);
    }
};

pub fn programPointLess(_: void, a: ProgramPoint, b: ProgramPoint) bool {
    if (a.proto_id != b.proto_id) return a.proto_id < b.proto_id;
    return a.source_pc < b.source_pc;
}

pub fn programPointsEqual(a: []const ProgramPoint, b: []const ProgramPoint) bool {
    if (a.len != b.len) return false;
    for (a, b) |ae, be| {
        if (ae.proto_id != be.proto_id or ae.source_pc != be.source_pc) return false;
    }
    return true;
}

pub fn appendUniqueSlot(list: *std.ArrayListUnmanaged(u16), gpa: std.mem.Allocator, slot: u16) !bool {
    for (list.items) |s| if (s == slot) return false;
    try list.append(gpa, slot);
    return true;
}

/// A physical classification index `K → sorted []RegionId` (doc 17 §A3.1). Wholesale-
/// rebuilt per discovery pass; owns each value slice. `freeRegionSetMap` releases the
/// per-entry slices + the map backing.
pub fn freeRegionSetMap(comptime K: type, map: *std.AutoHashMapUnmanaged(K, []RegionId), gpa: std.mem.Allocator) void {
    var it = map.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    map.deinit(gpa);
}

/// Scratch accumulator for a physical classification index during discovery: appends
/// `RegionId`s per key (deduped), then `finalize`s into an owned-slice map.
pub fn RegionSetBuilder(comptime K: type) type {
    return struct {
        const Self = @This();
        m: std.AutoHashMapUnmanaged(K, std.ArrayListUnmanaged(RegionId)) = .empty,

        pub fn add(self: *Self, gpa: std.mem.Allocator, key: K, id: RegionId) !void {
            const gop = try self.m.getOrPut(gpa, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |x| {
                if (x == id) return; // dedup
            }
            try gop.value_ptr.append(gpa, id);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            var it = self.m.valueIterator();
            while (it.next()) |v| v.deinit(gpa);
            self.m.deinit(gpa);
        }

        /// Materialize into an owned-slice map with each id list sorted. Fallible; the
        /// caller's `errdefer freeRegionSetMap` covers a mid-materialize OOM.
        pub fn finalize(self: *Self, gpa: std.mem.Allocator) !std.AutoHashMapUnmanaged(K, []RegionId) {
            var out: std.AutoHashMapUnmanaged(K, []RegionId) = .empty;
            errdefer freeRegionSetMap(K, &out, gpa);
            try out.ensureUnusedCapacity(gpa, self.m.count());
            var it = self.m.iterator();
            while (it.next()) |e| {
                std.mem.sort(RegionId, e.value_ptr.items, {}, regionIdLess);
                const owned = try gpa.dupe(RegionId, e.value_ptr.items);
                out.putAssumeCapacity(e.key_ptr.*, owned);
            }
            return out;
        }
    };
}
