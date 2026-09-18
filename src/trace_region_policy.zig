//! Logical region state and observer ownership. No coordinator or physical mutation authority.
const std = @import("std");
const region = @import("trace_region.zig");
const types = @import("trace_types.zig");
const RegionId = region.RegionId;
const RegionKey = region.RegionKey;
const RegionDef = region.RegionDef;
const RegionAccum = region.RegionAccum;
const RegionContext = region.RegionContext;
const RegionInternMap = region.RegionInternMap;
const ObserverFast = region.ObserverFast;
const ObserverHot = region.ObserverHot;
const ObserverSpan = region.ObserverSpan;
const ExitKey = types.ExitKey;
const StructuralEdgeId = types.StructuralEdgeId;
pub const MemberAccum = struct { key: RegionKey, accum: *RegionAccum };

pub const RegionPolicy = struct {
    const observer = @import("trace_region_observer.zig");
    pub const regionMemberPoint = observer.regionMemberPoint;
    pub const qualifiedActiveMember = observer.qualifiedActiveMember;
    pub const refreshActCache = observer.refreshActCache;
    pub const observeFast = observer.observeFast;
    pub const nextDeparture = observer.nextDeparture;

    /// Pure ephemeral structural-edge cache (doc 17 §A3.3 / §A8-ii, A-ii.2):
    /// `{Trace.id, exit_instr} → StructuralEdgeId`. Rebuilt WHOLESALE from the current
    /// cache at every commit AND every retirement (never surgically mutated), dropped
    /// in `clearCache`, freed in `deinit`. NOT a source of truth — consumed by the
    /// region classifier and region-bridge validation (`validateRegionBridge`).
    /// A rebuild reserves capacity BEFORE clearing the prior snapshot, so a
    /// commit-path OOM RETAINS it and a retirement-path OOM fail-closes to EMPTY
    /// (both region-neutral: an empty cache arms nothing).
    edge_cache: std.AutoHashMapUnmanaged(ExitKey, StructuralEdgeId) = .empty,
    /// Discovered region definitions keyed by interned `RegionId` (doc 17 §A3.1 /
    /// §A8-ii, A-ii.4). **Proto/VM-lifetime**: accumulated as traces commit, NEVER
    /// cleaned by `removeTrace` (a GC-physical retire must not diverge
    /// `gc_stress on/off`), cleared ONLY wholesale in `clearCache` (the epoch boundary
    /// where protos may be freed). Owns each `RegionDef`'s `members`/`member_points`.
    /// Consumed by the arming path (`armable` flips, `edgeMemberOfRegion`).
    region_defs: std.AutoHashMapUnmanaged(RegionId, RegionDef) = .empty,
    /// Invalidation generation for `Trace.region_memo_*` (freeze-after-qualify,
    /// task #70). Bumped at EVERY `region_defs` mutation — new/updated defs and
    /// every `armable` flip — so per-trace footprint-membership memos never
    /// outlive the def state they were computed against. Starts at 1 so a fresh
    /// trace's memo gen 0 can never spuriously match.
    region_defs_gen: u32 = 1,
    /// Single-slot cache of the qualified-live-activation resolution inside
    /// `qualifiedActiveMember` (task #70 seam work): the `activeRegionFor` map
    /// iteration + `region_profit.getPtr` + qualification check for one
    /// `call_seq`. `act_cache_gen == 0` means invalid; it is zeroed by
    /// `refreshObserverFast` (the single hook every `region_profit` mutation
    /// already runs through, so the cached `accum` pointer can never dangle) and
    /// by the `useful_window_seen` flip (which changes the cached verdict without
    /// mutating the map). The `region_defs_gen` half of the key covers footprint
    /// changes.
    act_cache_seq: u64 = 0,
    act_cache_gen: u32 = 0,
    act_cache: ?MemberAccum = null,
    /// Interns a region's canonical sorted INTERNAL edge SET → its `RegionId` (same
    /// Proto/VM lifetime as `region_defs`). Hash-bucketed; a hit confirmed by
    /// element-wise set equality (collision mints a distinct id).
    region_intern: RegionInternMap = .empty,
    /// Next `RegionId` to mint (monotonic; mirrors `next_trace_id`). A discovery pass
    /// that OOMs before publishing does NOT bump it — the tentative ids it staged are
    /// simply never used (ids need only be unique, not contiguous).
    next_region_id: u64 = 0,
    /// Physical classification index (doc 17 §A3.1 / §A3.3): a concrete trace exit
    /// `{Trace.id, exit_instr}` → the regions it belongs to (internal edges + boundary
    /// exits that LEAVE the region from a member anchor). **Physical + transient**:
    /// WHOLESALE-rebuilt per discovery pass AND per `removeTrace` from the surviving
    /// cache; excludes `armable == false` regions. Owns each `[]RegionId`. Queried by
    /// `classifyExit`, whose result feeds `tryArmRegionBridge`. A retirement-rebuild
    /// OOM publishes EMPTY (fail-closed — the prior set references a dead trace).
    source_exit_regions: std.AutoHashMapUnmanaged(ExitKey, []RegionId) = .empty,
    /// Physical classification index (doc 17 §A3.1): a concrete `Trace.id` → the
    /// regions entered by landing in it (destination of an internal edge; physical
    /// members only). Same lifetime/rebuild/ownership rules as `source_exit_regions`.
    dest_entry_regions: std.AutoHashMapUnmanaged(u32, []RegionId) = .empty,
    /// A-iv: persistent across physical trace retirement/re-arm, bounded by live
    /// activation lifetime and cleared on activation death / restore / epoch end.
    /// Opening a logical region is the only operation that may grow this map;
    /// the per-op observer only probes/removes existing entries.
    region_profit: std.AutoHashMapUnmanaged(RegionKey, RegionAccum) = .empty,
    region_context: ?RegionContext = null,
    /// A-vii-e.1: single-accumulator observer fast path (see `ObserverFast`).
    observer_fast: ?ObserverFast = null,
    /// A-vii-e.2: inline hot-span cache over `observer_fast` (see `ObserverHot`).
    observer_hot: ObserverHot = .{},
    /// Inert diagnostics used by the A-iv guards to prove full-window and
    /// remainder flushes occurred. No tiering path consumes either counter.
    region_profit_flushes: u64 = 0,
    region_profit_flushed_work: u64 = 0,

    /// Allocation-free requests. The coordinator applies recovery, or demotion
    /// before a strike, then any resulting gate/condemn/disarm in that order.
    pub const WindowDecision = union(enum) {
        none,
        recover: types.AnchorKey,
        strike: types.AnchorKey,
    };

    pub fn flushWindow(self: *RegionPolicy, key: RegionKey, work: u64, min_useful: u64) WindowDecision {
        if (work == 0) return .none;
        self.region_profit_flushes +|= 1;
        self.region_profit_flushed_work +|= work;
        const def = self.region_defs.get(key.region_id) orelse return .none;
        if (work >= min_useful) return .{ .recover = def.owner };
        if (self.region_profit.getPtr(key)) |accum| {
            accum.frozen = false;
            accum.useful_streak = 0;
        }
        return .{ .strike = def.owner };
    }

    pub fn beginCredit(accum: *RegionAccum, work: usize) void {
        accum.barren_run = 0;
        accum.outer_traversals +|= @intCast(work);
    }

    pub const CreditDecision = struct {
        window: WindowDecision,
        clear_members: bool,
    };

    /// One bounded decision per full window; no action queue grows with work.
    /// Caller applies each decision before requesting the next window.
    pub fn nextCreditWindow(self: *RegionPolicy, key: RegionKey, accum: *RegionAccum, n: u64, freeze_windows: u64, gates_empty: bool) ?CreditDecision {
        if (n == 0 or accum.outer_traversals - accum.window_base < n) return null;
        if (accum.frozen and gates_empty) {
            self.region_profit_flushes +|= 1;
            self.region_profit_flushed_work +|= n;
            accum.useful_streak +|= 1;
            accum.window_base += n;
            return .{ .window = .none, .clear_members = false };
        }
        const window = self.flushWindow(key, n, n);
        const qualify = !accum.useful_window_seen;
        if (qualify) {
            self.act_cache_gen = 0;
            self.act_cache = null;
        }
        accum.useful_window_seen = true;
        accum.window_base += n;
        accum.useful_streak +|= 1;
        if (accum.useful_streak >= freeze_windows) accum.frozen = true;
        return .{ .window = window, .clear_members = qualify };
    }

    pub fn barrenReceipt(self: *RegionPolicy, key: RegionKey, accum: *RegionAccum, max_barren_run: u64, min_useful: u64) WindowDecision {
        accum.barren_run +|= 1;
        if (accum.barren_run < max_barren_run) return .none;
        accum.barren_run = 0;
        return self.flushWindow(key, 1, min_useful);
    }

    pub const Selection = union(enum) { done: ?RegionKey, close: RegionKey, invalidate: RegionId };
    pub const SelectionCursor = struct { invalidation_index: usize = 0 };
    pub fn chooseSource(self: *RegionPolicy, gpa: std.mem.Allocator, candidates: []const RegionId, ctx: RegionContext, cursor: *SelectionCursor) Selection {
        if (self.activeRegionFor(ctx.call_seq)) |active| {
            const live = if (self.region_defs.get(active.region_id)) |d| d.armable else false;
            if (!live) return .{ .close = active };
            for (candidates) |id| if (id == active.region_id) return .{ .done = active };
            if (candidates.len == 0) return .{ .done = null };
            return .{ .close = active };
        }
        return self.selectCandidates(gpa, candidates, ctx, cursor);
    }
    fn selectCandidates(self: *RegionPolicy, gpa: std.mem.Allocator, candidates: []const RegionId, ctx: RegionContext, cursor: *SelectionCursor) Selection {
        if (candidates.len == 1) {
            if (self.openCollision(candidates[0], ctx)) |key| return .{ .close = key };
            return .{ .done = self.openRegion(gpa, candidates[0], ctx) };
        }
        if (cursor.invalidation_index < candidates.len) {
            const id = candidates[cursor.invalidation_index];
            cursor.invalidation_index += 1;
            return .{ .invalidate = id };
        }
        return .{ .done = null };
    }
    pub fn applyDestination(self: *RegionPolicy, gpa: std.mem.Allocator, selected: *?RegionKey, candidates: []const RegionId, deferred: bool, ctx: RegionContext, cursor: *SelectionCursor) Selection {
        if (deferred) return .{ .done = null };
        if (selected.*) |source| {
            for (candidates) |id| if (id == source.region_id) return .{ .done = source };
            selected.* = null;
            return .{ .close = source };
        }
        return self.selectCandidates(gpa, candidates, ctx, cursor);
    }
    pub fn openCollision(self: *const RegionPolicy, id: RegionId, ctx: RegionContext) ?RegionKey {
        const def = self.region_defs.get(id) orelse return null;
        if (!def.armable) return null;
        var it = self.region_profit.keyIterator();
        while (it.next()) |key| {
            if (key.activation != ctx.call_seq or key.region_id == id) continue;
            const old = self.region_defs.get(key.region_id) orelse continue;
            if (std.meta.eql(old.owner, def.owner)) return key.*;
        }
        return null;
    }
    /// Caller applies close effects for openCollision before publishing.
    pub fn openRegion(self: *RegionPolicy, gpa: std.mem.Allocator, id: RegionId, ctx: RegionContext) ?RegionKey {
        const def = self.region_defs.get(id) orelse return null;
        if (!def.armable) return null;
        std.debug.assert(self.openCollision(id, ctx) == null);
        const key: RegionKey = .{ .region_id = id, .activation = ctx.call_seq };
        // getOrPut may grow even for an existing key: borrowed pointers die first.
        self.act_cache_gen = 0;
        self.act_cache = null;
        const gop = self.region_profit.getOrPut(gpa, key) catch return null;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .root_frame_depth = ctx.depth, .root_call_seq = ctx.call_seq };
            self.refreshObserverFast(gpa);
        }
        return key;
    }
    pub const Close = struct { work: u64, window: WindowDecision };
    pub fn beginClose(self: *RegionPolicy, key: RegionKey, min_useful: u64) ?Close {
        const accum = self.region_profit.get(key) orelse return null;
        const work = accum.outer_traversals - accum.window_base;
        return .{ .work = work, .window = self.flushWindow(key, work, min_useful) };
    }
    /// Called only after window and physical demotion effects have completed.
    pub fn finishClose(self: *RegionPolicy, gpa: std.mem.Allocator, key: RegionKey) void {
        _ = self.region_profit.remove(key);
        self.refreshObserverFast(gpa);
    }
    pub fn invalidateRegion(self: *RegionPolicy, id: RegionId) bool {
        const def = self.region_defs.getPtr(id) orelse return false;
        def.armable = false;
        def.tombstoned = true;
        // Doc 52 P1: the recurrence proof dies with the region (the
        // eligibility gate already excludes tombstoned defs; cleared for the
        // same reason as the tier-flip reset — stale evidence must not read
        // as live in dumps or a future un-tombstone path).
        def.recurrence_len = 0;
        def.recurrence_streak = 0;
        def.recurrence_probe_charges = 0;
        self.region_defs_gen +%= 1;
        if (self.region_defs_gen == 0) self.region_defs_gen = 1;
        return true;
    }
    pub fn nextInvalidated(self: *const RegionPolicy, id: RegionId) ?RegionKey {
        var it = self.region_profit.keyIterator();
        while (it.next()) |key| if (key.region_id == id) return key.*;
        return null;
    }
    pub fn nextActivation(self: *RegionPolicy, seq: u64) ?RegionKey {
        if (self.activeRegionFor(seq)) |key| return key;
        if (self.region_context) |ctx| {
            if (ctx.call_seq == seq) self.region_context = null;
        }
        return null;
    }
    pub fn resetProfit(self: *RegionPolicy, gpa: std.mem.Allocator) void {
        self.region_profit.clearRetainingCapacity();
        self.region_context = null;
        self.freeObserverFast(gpa);
    }
    pub fn setContext(self: *RegionPolicy, depth: u32, seq: u64) void {
        self.region_context = .{ .depth = depth, .call_seq = seq };
    }
    /// True iff a concrete receipt is provably a no-op end to end, so the
    /// coordinator may skip the whole classify/choose/credit/destination
    /// pipeline: with all three maps empty, `classifyExit` yields no candidates
    /// (`source_exit_regions`), `activeRegionFor` yields no activation
    /// (`region_profit` — so nothing to close, credit, or barren-consume), and
    /// `applyDestination` finds no entry candidates (`dest_entry_regions` — so
    /// nothing to open or invalidate). Pure function of deterministic policy
    /// state; three O(1) size loads. This is the per-row cost floor for every
    /// program that has no live armable region — the common case — measured at
    /// ~1M no-op pipeline runs per scimark-fft execution without it.
    pub fn receiptsInert(self: *const RegionPolicy) bool {
        return self.region_profit.count() == 0 and
            self.source_exit_regions.count() == 0 and
            self.dest_entry_regions.count() == 0;
    }

    /// Resolved logical membership, with no registry or physical trace reference.
    /// The single consumed bit is the exclusive legacy profitability boundary.
    pub const Receipt = struct { selected: ?RegionKey, unclassified_member: ?RegionKey, work: usize };
    pub const ReceiptDecision = struct { effective: ?RegionKey, consumed: bool = false, credit: bool = false, barren: bool = false };
    pub fn accountRegionProfit(self: *RegionPolicy, receipt: Receipt) ReceiptDecision {
        const effective = receipt.selected orelse receipt.unclassified_member;
        var result: ReceiptDecision = .{ .effective = effective };
        const key = effective orelse return result;
        const accum = self.region_profit.get(key) orelse return result;
        result.credit = receipt.work != 0;
        result.barren = receipt.work == 0 and accum.useful_window_seen;
        result.consumed = result.credit or result.barren;
        return result;
    }

    const topology = @import("trace_region_topology.zig");

    pub fn previousTopology(self: *const RegionPolicy) topology.Previous {
        return .{ .intern = &self.region_intern, .defs = &self.region_defs, .next_id = self.next_region_id };
    }

    pub fn publishEdges(self: *RegionPolicy, gpa: std.mem.Allocator, edges: topology.EdgeMap) void {
        self.edge_cache.deinit(gpa);
        self.edge_cache = edges;
    }

    pub fn clearEdges(self: *RegionPolicy) void {
        self.edge_cache.clearRetainingCapacity();
    }

    /// Epoch teardown: coordinator demotes physical sets before this call.
    pub fn clearEpochTopology(self: *RegionPolicy, gpa: std.mem.Allocator) void {
        var it = self.region_defs.valueIterator();
        while (it.next()) |def| {
            gpa.free(def.members);
            gpa.free(def.member_points);
            region.freeRegionBridges(gpa, def.bridges);
        }
        self.region_defs.clearRetainingCapacity();
        self.region_defs_gen +%= 1;
        if (self.region_defs_gen == 0) self.region_defs_gen = 1;
        self.region_intern.clear(gpa);
        self.clearPhysicalIndices(gpa);
    }

    pub fn resetDiagnostics(self: *RegionPolicy) void {
        self.region_profit_flushes = 0;
        self.region_profit_flushed_work = 0;
    }

    pub fn clearPhysicalIndices(self: *RegionPolicy, gpa: std.mem.Allocator) void {
        region.freeRegionSetMap(ExitKey, &self.source_exit_regions, gpa);
        region.freeRegionSetMap(u32, &self.dest_entry_regions, gpa);
        self.source_exit_regions = .empty;
        self.dest_entry_regions = .empty;
    }

    /// Last fallible step; changes capacity only, never logical contents or ids.
    pub fn reserveTopology(self: *RegionPolicy, gpa: std.mem.Allocator, staged: *const topology.Rebuild) !void {
        try self.region_intern.reserve(gpa, staged.staged_interns.items.len);
        try self.region_defs.ensureUnusedCapacity(gpa, @intCast(staged.staged_defs.items.len));
    }

    /// Coordinator must demote physical sets BEFORE this infallible ownership transfer.
    pub fn publishTopology(self: *RegionPolicy, gpa: std.mem.Allocator, staged: *topology.Rebuild) void {
        for (staged.staged_interns.items) |s| self.region_intern.internAssumeCapacity(s.edges, s.id);
        staged.staged_interns.clearRetainingCapacity();
        for (staged.staged_defs.items) |s| self.region_defs.putAssumeCapacity(s.id, s.def);
        staged.staged_defs.clearRetainingCapacity();
        for (staged.staged_owner_updates.items) |u| {
            if (self.region_defs.getPtr(u.id)) |d| d.owner = u.owner;
        }
        for (staged.staged_armable_updates.items) |u| {
            if (self.region_defs.getPtr(u.id)) |d| {
                d.armable = u.armable;
                d.fallback_owner = u.fallback_owner;
                d.dormant = u.dormant;
                if (u.reset_learning) {
                    // Election tier flipped primary↔fallback: stale fallback
                    // evidence must not survive into (or return from) a
                    // primary-owned phase.
                    d.instability = 0;
                    d.no_candidate_runs = 0;
                    d.admission_failures = 0;
                    d.receipts_debit = 0;
                    d.transitions_credit = 0;
                    // Doc 52 P1: the recurrence proof is fallback evidence of
                    // the same class — signature, streak, and probe budget
                    // all reset with the tier flip.
                    d.recurrence_len = 0;
                    d.recurrence_streak = 0;
                    d.recurrence_probe_charges = 0;
                }
            }
        }
        for (staged.staged_bridge_updates.items) |u| {
            const d = self.region_defs.getPtr(u.id).?;
            region.freeRegionBridges(gpa, d.bridges);
            d.bridges = u.bridges;
        }
        staged.staged_bridge_updates.clearRetainingCapacity();
        for (staged.staged_tombstones.items) |id| {
            if (self.region_defs.getPtr(id)) |d| {
                d.armable = false;
                d.tombstoned = true;
            }
        }
        self.next_region_id = staged.next_id;
        self.region_defs_gen +%= 1;
        if (self.region_defs_gen == 0) self.region_defs_gen = 1;
        self.clearPhysicalIndices(gpa);
        self.source_exit_regions = staged.source;
        self.dest_entry_regions = staged.dest;
        staged.source = .empty;
        staged.dest = .empty;
    }

    pub fn deinit(self: *RegionPolicy, gpa: std.mem.Allocator) void {
        self.edge_cache.deinit(gpa); // A-ii.2 (values are plain structs; no per-entry free)
        // A-ii.4: region model. `region_defs` values own members/member_points; the
        // intern map owns its edge slices; the physical indices own their []RegionId.
        var rd_it = self.region_defs.valueIterator();
        while (rd_it.next()) |d| {
            gpa.free(d.members);
            gpa.free(d.member_points);
            region.freeRegionBridges(gpa, d.bridges);
        }
        self.region_defs.deinit(gpa);
        self.region_intern.deinit(gpa);
        region.freeRegionSetMap(ExitKey, &self.source_exit_regions, gpa);
        region.freeRegionSetMap(u32, &self.dest_entry_regions, gpa);
        self.region_profit.deinit(gpa);
        self.freeObserverFast(gpa); // A-vii-e.1: owned bitset copies
    }
    pub fn freeObserverFast(self: *RegionPolicy, gpa: std.mem.Allocator) void {
        // Every `region_profit` mutation funnels through here (refreshObserverFast
        // and resetRegionProfit both call it) — the cached `accum` pointer in
        // `act_cache` must not survive any of them (see `act_cache_*`).
        self.act_cache_gen = 0;
        self.act_cache = null;
        // The inline cache borrows a span's `words`, so it dies with the owner —
        // unconditionally, even when there is nothing to free (a null
        // `observer_fast` still means "no valid hot span").
        self.observer_hot = .{};
        if (self.observer_fast) |f| {
            for (f.spans) |s| gpa.free(s.words);
            gpa.free(f.spans);
            self.observer_fast = null;
        }
    }

    /// A-vii-e.1: rebuild the observer fast path from the current single
    /// accumulator (null it otherwise). Cold path — runs only when the
    /// `region_profit` map mutates. See `ObserverFast` for the contract.
    pub fn refreshObserverFast(self: *RegionPolicy, gpa: std.mem.Allocator) void {
        self.freeObserverFast(gpa);
        if (self.region_profit.count() != 1) return;
        var it = self.region_profit.iterator();
        const entry = it.next().?;
        const def = self.region_defs.get(entry.key_ptr.region_id) orelse return; // slow path closes it
        const points = def.member_points; // sorted by (proto_id, source_pc), deduped
        if (points.len == 0) return;
        // Group by consecutive proto_id runs. Discovery publishes member_points
        // sorted by (proto_id, source_pc), but hand-built test defs may not be —
        // so take min/max per run instead of first/last, and let the probe below
        // check every span (a non-contiguous proto grouping just yields more
        // spans, never a wrong verdict).
        var nspans: usize = 1;
        for (points[1..], points[0 .. points.len - 1]) |cur, prev| {
            if (cur.proto_id != prev.proto_id) nspans += 1;
        }
        const spans = gpa.alloc(ObserverSpan, nspans) catch return;
        var filled: usize = 0;
        var i: usize = 0;
        while (i < points.len) {
            const pid = points[i].proto_id;
            var j = i;
            var base = points[i].source_pc;
            var max_pc = base;
            while (j < points.len and points[j].proto_id == pid) : (j += 1) {
                base = @min(base, points[j].source_pc);
                max_pc = @max(max_pc, points[j].source_pc);
            }
            // Size the bitset in u64 (codex e.1 review, MAJOR): `(limit - base) + 63`
            // in u32 overflows for a near-maxInt(u32) pc range, and even a
            // non-overflowing pathological range (hand-built defs; real member pcs
            // are bounded by proto code length) would allocate an absurd bitset.
            // Cap the per-proto range; over the cap (or at the u32 wrap point) the
            // cache stays null and the slow path runs — same verdicts either way.
            const range: u64 = @as(u64, max_pc) - base + 1;
            const observer_span_max_range: u64 = 1 << 22; // 4M pcs → 512 KiB bitset, far above any real proto
            if (range > observer_span_max_range or max_pc == std.math.maxInt(u32)) {
                for (spans[0..filled]) |s| gpa.free(s.words);
                gpa.free(spans);
                return;
            }
            const limit = max_pc + 1;
            const nwords: usize = @intCast((range + 63) / 64);
            const words = gpa.alloc(u64, nwords) catch {
                for (spans[0..filled]) |s| gpa.free(s.words);
                gpa.free(spans);
                return;
            };
            @memset(words, 0);
            for (points[i..j]) |pp| {
                const off = pp.source_pc - base;
                words[off >> 6] |= @as(u64, 1) << @intCast(off & 63);
            }
            spans[filled] = .{ .proto_id = pid, .base_pc = base, .limit_pc = limit, .words = words };
            filled += 1;
            i = j;
        }
        self.observer_fast = .{
            .key = entry.key_ptr.*,
            .root_frame_depth = entry.value_ptr.root_frame_depth,
            .root_call_seq = entry.value_ptr.root_call_seq,
            .spans = spans,
        };
    }

    // pub for trace_link.zig (file-split pass)
    pub fn activeRegionFor(self: *const RegionPolicy, activation: u64) ?RegionKey {
        var best: ?RegionKey = null;
        var it = self.region_profit.keyIterator();
        while (it.next()) |key| {
            if (key.activation != activation) continue;
            if (best == null or @intFromEnum(key.region_id) < @intFromEnum(best.?.region_id))
                best = key.*;
        }
        return best;
    }
};

test "policy window missing definition is diagnostic only; zero is inert" {
    var policy: RegionPolicy = .{};
    defer policy.deinit(std.testing.allocator);
    const key: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 2 };
    try std.testing.expect(policy.flushWindow(key, 0, 4) == .none);
    try std.testing.expectEqual(@as(u64, 0), policy.region_profit_flushes);
    try std.testing.expect(policy.flushWindow(key, 3, 4) == .none);
    try std.testing.expectEqual(@as(u64, 3), policy.region_profit_flushed_work);
}

test "policy credits bounded windows and qualification without allocation" {
    var policy: RegionPolicy = .{};
    defer policy.deinit(std.testing.allocator);
    const key: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 2 };
    var accum: RegionAccum = .{ .root_frame_depth = 1, .root_call_seq = 2 };
    RegionPolicy.beginCredit(&accum, 9);
    const first = policy.nextCreditWindow(key, &accum, 4, 2, true).?;
    try std.testing.expect(first.clear_members);
    try std.testing.expect(!accum.frozen);
    const second = policy.nextCreditWindow(key, &accum, 4, 2, true).?;
    try std.testing.expect(!second.clear_members);
    try std.testing.expect(accum.frozen);
    try std.testing.expect(policy.nextCreditWindow(key, &accum, 4, 2, true) == null);
    try std.testing.expectEqual(@as(u64, 8), accum.window_base);
    try std.testing.expectEqual(@as(u64, 2), policy.region_profit_flushes);
    try std.testing.expect(policy.barrenReceipt(key, &accum, 2, 4) == .none);
    try std.testing.expectEqual(@as(u64, 1), accum.barren_run);
    RegionPolicy.beginCredit(&accum, 1);
    try std.testing.expectEqual(@as(u64, 0), accum.barren_run);
}

fn testDefinition(owner: types.AnchorKey) RegionDef {
    return .{ .members = &.{}, .member_points = &.{}, .owner = owner, .classifier = .{ .kind = .self_loop, .member_count = 1 }, .armable = true };
}

test "policy receipt consumed bit exclusively selects regional or legacy pricing" {
    var policy: RegionPolicy = .{};
    defer policy.deinit(std.testing.allocator);
    const key: RegionKey = .{ .region_id = @enumFromInt(1), .activation = 2 };
    try policy.region_profit.put(std.testing.allocator, key, .{ .root_frame_depth = 1, .root_call_seq = 2 });
    for ([_]bool{ false, true }) |qualified| {
        policy.region_profit.getPtr(key).?.useful_window_seen = qualified;
        for ([_]bool{ false, true }) |classified| {
            for ([_]usize{ 0, 1 }) |work| {
                const decision = policy.accountRegionProfit(.{
                    .selected = if (classified) key else null,
                    .unclassified_member = if (classified) null else key,
                    .work = work,
                });
                try std.testing.expectEqual(key, decision.effective.?);
                try std.testing.expectEqual(work != 0, decision.credit);
                try std.testing.expectEqual(work == 0 and qualified, decision.barren);
                try std.testing.expectEqual(work != 0 or qualified, decision.consumed);
                try std.testing.expect(!(decision.credit and decision.barren));
            }
        }
    }
    const missing = policy.accountRegionProfit(.{ .selected = null, .unclassified_member = null, .work = 9 });
    try std.testing.expect(!missing.consumed and !missing.credit and !missing.barren);
    const stale = policy.accountRegionProfit(.{ .selected = .{ .region_id = @enumFromInt(99), .activation = 2 }, .unclassified_member = key, .work = 9 });
    try std.testing.expect(!stale.consumed); // selected wins; never silently prices a different member
}

test "policy source and destination request close before replacement opens" {
    const gpa = std.testing.allocator;
    var policy: RegionPolicy = .{};
    defer policy.deinit(gpa);
    var proto: @import("bytecode.zig").Proto = undefined; // identity only; never dereferenced
    const first: RegionId = @enumFromInt(1);
    const second: RegionId = @enumFromInt(2);
    try policy.region_defs.put(gpa, first, testDefinition(.{ .proto = &proto, .pc = 0 }));
    try policy.region_defs.put(gpa, second, testDefinition(.{ .proto = &proto, .pc = 0 }));
    const ctx: RegionContext = .{ .depth = 1, .call_seq = 7 };
    const initial = policy.openRegion(gpa, first, ctx).?;
    var cursor: RegionPolicy.SelectionCursor = .{};
    try std.testing.expect(policy.chooseSource(gpa, &.{}, ctx, &cursor).done == null);
    try std.testing.expectEqual(initial, policy.chooseSource(gpa, &.{second}, ctx, &cursor).close);
    try std.testing.expectEqual(initial, policy.activeRegionFor(ctx.call_seq).?);
    try std.testing.expectEqual(@as(u32, 1), policy.region_profit.count());
    _ = policy.beginClose(initial, 4).?;
    policy.finishClose(gpa, initial);
    const replacement = policy.chooseSource(gpa, &.{second}, ctx, &cursor).done.?;
    try std.testing.expectEqual(second, replacement.region_id);
    var selected: ?RegionKey = replacement;
    try std.testing.expect(policy.applyDestination(gpa, &selected, &.{first}, true, ctx, &cursor).done == null);
    try std.testing.expectEqual(replacement, selected.?); // deferred destination preserves source
    try std.testing.expectEqual(replacement, policy.applyDestination(gpa, &selected, &.{first}, false, ctx, &cursor).close);
    try std.testing.expect(selected == null);
    try std.testing.expectEqual(replacement, policy.activeRegionFor(ctx.call_seq).?);
    policy.finishClose(gpa, replacement);
    try std.testing.expectEqual(first, policy.applyDestination(gpa, &selected, &.{first}, false, ctx, &cursor).done.?.region_id);
    policy.resetProfit(gpa);
    cursor = .{};
    try std.testing.expectEqual(second, policy.chooseSource(gpa, &.{ second, first }, ctx, &cursor).invalidate);
    try std.testing.expectEqual(first, policy.chooseSource(gpa, &.{ second, first }, ctx, &cursor).invalidate);
    try std.testing.expect(policy.chooseSource(gpa, &.{ second, first }, ctx, &cursor).done == null);
}

test "policy open OOM invalidates cached accumulator before attempted map growth" {
    const gpa = std.testing.allocator;
    var policy: RegionPolicy = .{};
    defer policy.deinit(gpa);
    var proto: @import("bytecode.zig").Proto = undefined;
    const id: RegionId = @enumFromInt(1);
    try policy.region_defs.put(gpa, id, testDefinition(.{ .proto = &proto, .pc = 0 }));
    const initial = policy.openRegion(gpa, id, .{ .depth = 1, .call_seq = 1 }).?;
    policy.region_profit.getPtr(initial).?.useful_window_seen = true;
    // Fill existing capacity without allocating, until the next open must grow.
    var fail = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0, .resize_fail_index = 0 });
    var seq: u64 = 2;
    while (true) : (seq += 1) {
        policy.refreshActCache(1);
        try std.testing.expect(policy.act_cache != null);
        if (policy.openRegion(fail.allocator(), id, .{ .depth = 1, .call_seq = seq }) == null) break;
    }
    try std.testing.expect(fail.has_induced_failure);
    try std.testing.expect(policy.act_cache == null);
    try std.testing.expectEqual(@as(u32, 0), policy.act_cache_gen);
    try std.testing.expect(policy.activeRegionFor(seq) == null);
    policy.refreshActCache(1);
    try std.testing.expectEqual(initial, policy.act_cache.?.key);
    try std.testing.expectEqual(policy.region_profit.getPtr(initial).?, policy.act_cache.?.accum);
    policy.finishClose(gpa, initial);
    try std.testing.expect(policy.act_cache == null);
}
