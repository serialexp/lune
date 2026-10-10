//! Trace-graph identities: the guest-logical names for a trace's exits, anchors
//! and structural edges.
//!
//! A leaf module by construction — it owns no runtime state and imports nothing
//! but `std` and `bytecode.Proto`. Both `trace.zig` (which re-exports every
//! public name here, so existing `trace.GuardProvenance` spellings still work)
//! and `trace_region.zig` depend on it; it depends on neither.
//!
//! Moved out of `trace.zig` verbatim. The doc comments are the substance — they
//! record why guard identity is keyed on guest provenance rather than IR
//! position, and why the order/hash functions are field-wise.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const Proto = bytecode.Proto;

// ---------------------------------------------------------------------------
// GuardProvenance (doc 17, §A4 / landing step A-i / 9-B)
//
// The guest-logical identity of a trace exit, stamped at emission and remapped
// through `tropt` to committed-instruction indices. The Part-A region-accounting
// classifier keys on this, NOT on IR position: recording is guest-value-dependent
// (`guardNum` picks int/float by observed value, `recBranch` picks true/false by
// taken path, the realized guard subset varies by heap shape, LICM/CSE shift
// positions) and `guardExitPc` cannot even supply a PC for array/table/grid
// guards. See the H-1c grounding for the closed role/operand vocabulary and why
// `occurrence` was dropped (the physical exit → provenance map is many-to-one).
// This is transient JIT-tiering metadata: a side table, never an `IrInstr` field
// (which would bump the wire schema, `traceser.zig`), never a `.snapshot` root.
// ---------------------------------------------------------------------------

/// One inlined call edge in a guard's inline-path prefix (H-1a). `path` is an
/// ordered *sequence* (recursion to `MAX_INLINE_DEPTH` is reachable), so the two
/// guards from `f(a); f(b)` inlined at distinct call sites get distinct identity.
pub const CallEdge = struct { caller_proto_id: u32, call_pc: u32 };

/// Which of a branch guard's two out-edges the recording committed to. A *static*
/// property of the recorded trace (not an observed value): `recBranch` emits
/// `guard_true`/`guard_false` by the taken path, and those are opposite CFG edges
/// of the region (nsieve's edge 1 = `skip.guard_false`, edge 4 = `cont.guard_true`
/// fail). `.neutral` for every non-branch guard. (Round-1 review, BLOCKER 1.)
pub const Polarity = enum(u8) { neutral, taken, fallthrough };

/// Closed structural vocabulary of guard *roles* (H-1c). NOT the IR op enum — the
/// op is a runtime *view* of the same site (`guard_int`/`guard_float` are both
/// `operand_type`; `guard_true`/`guard_false` are both `branch_cond`). A recording
/// realizes a runtime-selected *subset* of an opcode's static slot list, but each
/// realized role is stable across re-recording of the same-shaped trace.
pub const GuardRole = enum(u8) {
    operand_type, // arith/compare/eq/bitwise/neg/bnot operand; numeric-for control reg
    branch_cond, // jmp_if_true/false condition
    limit_int, // for_loop/for_prep float-limit → int specialization (int_of_float)
    loop_done, // for_loop / for_prep-first-iter continuation test (guard_true)
    container_type, // get/set_index container tag (guard_table)
    container_lane, // array element-lane (guard_lane)
    key_type, // array/grid index type (guard_int / guard_float on the key)
    key_int, // get/set_index integral-float key → int narrowing (int_of_float)
    operand_int, // mixed numeric compare: integral float narrowed to exact int
    bounds, // array/grid bounds check (guard_bounds)
    present, // array/grid presence (guard_present / guard_gpresent)
    element_type, // .value-lane loaded element (fused: guard_table on the load)
    append_precond, // array append precondition (guard_append)
    value_fits, // narrow-lane store fits (guard_fits)
    hash_struct, // const-key hash table structure (guard_hash)
    value_type, // hash store value / hload'd field type
    field_type, // fused native hload producer-exit
    grid_shape, // grid table shape (guard_grid)
    grid_stride, // grid stride (guard_stride)
    row_type, // grid row index type
    col_type, // grid column index type
    row_bounds, // grid row in [1,rows] (guard_bounds on garow)
    col_bounds, // grid column resolution / in [1,stride] (guard_gcol)
    callee_identity, // closure identity (call / get_upval / get_global — guard_func)
    callee_pure, // pure-builtin identity (guard_builtin)
    border, // `#t` fast-case border computable (alen's own producer-exit)
    alias_disambig, // store-forwarding key/table alias disambiguation (ne guard)
    /// Doc 57 P3: a copy of the trace's OWN loop test that an instability
    /// unroll left in the middle of the trip — a non-final iteration's
    /// numeric `for_loop` continue test, or a later iteration's `while`
    /// condition. It is an ordinary coarse exit: no loop-done classifier,
    /// no branch consumer, no exit attach (`TraceCode.isLoopTestCopy`).
    loop_test_copy,
};

/// Static register designator for the guarded operand (H-1c). Covers `a`/`b`/`c`,
/// the derived numeric-for control offsets `a+1`/`a+2`, register-valued `aux`
/// (grid col/value), the loaded value of a fused producer-exit, and `none` for
/// guards with no register operand (bounds/present/loop_done). Re-recording-stable:
/// it tracks the *source* register, not the normalized IR operand (the `recCompare`
/// gt/ge swap happens after emission, so `operand` still names the source reg).
pub const OperandDesig = enum(u8) { none, a, b, c, a1, a2, aux, loaded, a3 };

/// The guest-static identity of a materialized guard exit (H-1c: `occurrence`
/// dropped — unrolled physical copies deliberately share one tag, which is correct
/// for the consumer: every copy is the same guest check, exits to the same guest PC).
/// `path[0..inline_depth]` is the inline call-edge prefix; the leaf is
/// `{source_proto_id, source_pc}` (`source_pc = cur_pc − 1`).
pub const GuardProvenance = struct {
    path: [MAX_INLINE_DEPTH]CallEdge = undefined,
    inline_depth: u8 = 0,
    source_proto_id: u32,
    source_pc: u32,
    role: GuardRole,
    operand: OperandDesig,
    polarity: Polarity = .neutral,
};

/// The inline-path leaf of a `.link` terminal (edge 2). Same shape as a guard's
/// path prefix + leaf, minus role/operand/polarity — a `.link` is not a guard.
pub const LinkTerminalProvenance = struct {
    path: [MAX_INLINE_DEPTH]CallEdge = undefined,
    inline_depth: u8 = 0,
    source_proto_id: u32,
    source_pc: u32,
};

/// Provenance of a trace exit. Most exits are guards; edge 2 exits through a
/// `.link` terminal (not a guard — synthesized at commit from `recForPrepLink`,
/// `trace.zig` §3.3, round-6/7), so that variant carries only the path + leaf.
pub const ExitProvenance = union(enum) {
    guard: GuardProvenance,
    link_terminal: LinkTerminalProvenance,
};

/// A committed-trace exit-provenance entry: the *committed* instruction index the
/// exit is at, plus its provenance. `Trace.exit_prov` is a slice of these sorted
/// by `index` (alloc-once at commit; guards are a minority of instrs), queried via
/// `Trace.provAt`. Built by remapping the recorder's dense lockstep table through
/// `tropt`'s compaction map (A-i.1).
pub const ExitProvEntry = struct { index: u32, prov: ExitProvenance };

pub fn exitProvEntryLess(_: void, a: ExitProvEntry, b: ExitProvEntry) bool {
    return a.index < b.index;
}

/// Physical classification key for the region-accounting layer (doc 17 §A3.3): a
/// concrete trace exit = `{Trace.id, exit_instr}`. `accountRegionProfit` receives
/// an `?ExitKey` — real guard/`.link_terminal` receipts carry the key; synthetic
/// scalar-burst / prologue-fail events with no real instruction index pass `null`.
/// Inert in A-ii (the profit half is a no-op; nothing constructs a non-null key
/// until A-iv threads it per-site — §A8-ii).
pub const ExitKey = struct { trace_id: u32, exit_instr: u32 };

/// Doc 44 D12a (A2): a descent-bottom failer `ExitKey` pinned to the leaf
/// activation it deopted in. See `TraceState.pending_descent_fail`.
pub const DescentFailCarry = struct { exit: ExitKey, call_seq: u64 };

/// A recorded guest program-point `{proto_id, source_pc}` (doc 17 §A3.5 / §A8-ii,
/// A-ii.3). `Trace.rec_path` is the ordered sequence captured one-per-`recordInstr`;
/// A-ii.4 unions member traces' paths into each `RegionDef`'s membership set. Keyed
/// by `proto.id` (guest-logical), `source_pc = recording pc − 1` (post-increment,
/// matching `guardSourcePc` / the A-i `cur_pc −| 1` discipline).
pub const ProgramPoint = struct { proto_id: u32, source_pc: u32 };

/// The persistent, guest-logical identity of a structural trace-graph edge (doc 17
/// §A3.3 / §A8-ii, A-ii.2): a source anchor `{proto_id, pc}`, the exit's
/// `ExitProvenance` (A-i), and the successor anchor `{proto_id, pc}`. Keyed by
/// `proto.id` (guest-logical), never a `*Proto`, so a re-recorded logically-identical
/// edge (new `Trace.id`) computes the same id. Anchors are `{proto, pc}` — a bare
/// `succ_pc` would alias successors at the same PC in different protos.
///
/// `order`/`eql`/`hash` are **field-wise** honoring `inline_depth` (only
/// `path[0..inline_depth]` is live): `ExitProvenance` is a padded tagged union with a
/// fixed-size `path` array + an inactive arm, so `std.mem.asBytes`/full-union `eql`
/// would compare garbage (round-11/12 review).
pub const StructuralEdgeId = struct {
    anchor_proto_id: u32,
    anchor_pc: u32,
    exit: ExitProvenance,
    succ_anchor_proto_id: u32,
    succ_anchor_pc: u32,

    pub fn order(a: StructuralEdgeId, b: StructuralEdgeId) std.math.Order {
        switch (std.math.order(a.anchor_proto_id, b.anchor_proto_id)) {
            .eq => {},
            else => |o| return o,
        }
        switch (std.math.order(a.anchor_pc, b.anchor_pc)) {
            .eq => {},
            else => |o| return o,
        }
        switch (exitOrder(a.exit, b.exit)) {
            .eq => {},
            else => |o| return o,
        }
        switch (std.math.order(a.succ_anchor_proto_id, b.succ_anchor_proto_id)) {
            .eq => {},
            else => |o| return o,
        }
        return std.math.order(a.succ_anchor_pc, b.succ_anchor_pc);
    }

    pub fn eql(a: StructuralEdgeId, b: StructuralEdgeId) bool {
        return a.order(b) == .eq;
    }

    /// Strict-less-than for `std.sort` (context-free comparator form).
    pub fn lessThan(_: void, a: StructuralEdgeId, b: StructuralEdgeId) bool {
        return a.order(b) == .lt;
    }

    pub fn hash(e: StructuralEdgeId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&e.anchor_proto_id));
        h.update(std.mem.asBytes(&e.anchor_pc));
        hashExit(&h, e.exit);
        h.update(std.mem.asBytes(&e.succ_anchor_proto_id));
        h.update(std.mem.asBytes(&e.succ_anchor_pc));
        return h.final();
    }
};

fn u32Order(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Field-wise canonical order over the live inline path prefix (both depths already
/// proven equal by the caller before it reaches here).
fn pathOrder(a: []const CallEdge, b: []const CallEdge) std.math.Order {
    for (a, b) |ae, be| {
        switch (u32Order(ae.caller_proto_id, be.caller_proto_id)) {
            .eq => {},
            else => |o| return o,
        }
        switch (u32Order(ae.call_pc, be.call_pc)) {
            .eq => {},
            else => |o| return o,
        }
    }
    return .eq;
}

pub fn exitOrder(a: ExitProvenance, b: ExitProvenance) std.math.Order {
    const at: u8 = @intFromEnum(std.meta.activeTag(a));
    const bt: u8 = @intFromEnum(std.meta.activeTag(b));
    switch (std.math.order(at, bt)) {
        .eq => {},
        else => |o| return o,
    }
    switch (a) {
        .guard => |ag| {
            const bg = b.guard;
            switch (u32Order(ag.source_proto_id, bg.source_proto_id)) {
                .eq => {},
                else => |o| return o,
            }
            switch (u32Order(ag.source_pc, bg.source_pc)) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(@intFromEnum(ag.role), @intFromEnum(bg.role))) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(@intFromEnum(ag.operand), @intFromEnum(bg.operand))) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(@intFromEnum(ag.polarity), @intFromEnum(bg.polarity))) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(ag.inline_depth, bg.inline_depth)) {
                .eq => {},
                else => |o| return o,
            }
            return pathOrder(ag.path[0..ag.inline_depth], bg.path[0..bg.inline_depth]);
        },
        .link_terminal => |al| {
            const bl = b.link_terminal;
            switch (u32Order(al.source_proto_id, bl.source_proto_id)) {
                .eq => {},
                else => |o| return o,
            }
            switch (u32Order(al.source_pc, bl.source_pc)) {
                .eq => {},
                else => |o| return o,
            }
            switch (std.math.order(al.inline_depth, bl.inline_depth)) {
                .eq => {},
                else => |o| return o,
            }
            return pathOrder(al.path[0..al.inline_depth], bl.path[0..bl.inline_depth]);
        },
    }
}

fn hashExit(h: *std.hash.Wyhash, exit: ExitProvenance) void {
    const tag: u8 = @intFromEnum(std.meta.activeTag(exit));
    h.update(std.mem.asBytes(&tag));
    switch (exit) {
        .guard => |g| {
            h.update(std.mem.asBytes(&g.source_proto_id));
            h.update(std.mem.asBytes(&g.source_pc));
            const role: u8 = @intFromEnum(g.role);
            const operand: u8 = @intFromEnum(g.operand);
            const polarity: u8 = @intFromEnum(g.polarity);
            h.update(std.mem.asBytes(&role));
            h.update(std.mem.asBytes(&operand));
            h.update(std.mem.asBytes(&polarity));
            h.update(std.mem.asBytes(&g.inline_depth));
            for (g.path[0..g.inline_depth]) |ce| {
                h.update(std.mem.asBytes(&ce.caller_proto_id));
                h.update(std.mem.asBytes(&ce.call_pc));
            }
        },
        .link_terminal => |l| {
            h.update(std.mem.asBytes(&l.source_proto_id));
            h.update(std.mem.asBytes(&l.source_pc));
            h.update(std.mem.asBytes(&l.inline_depth));
            for (l.path[0..l.inline_depth]) |ce| {
                h.update(std.mem.asBytes(&ce.caller_proto_id));
                h.update(std.mem.asBytes(&ce.call_pc));
            }
        },
    }
}

/// Identifies a trace anchor: a loop header at byte-`pc` within a `Proto`. Loop
/// headers are the only root-trace anchors in Phase 5a (hot side exits seed side
/// traces later).
///
/// The `proto` pointer is *borrowed*, not owned: a cached `Trace` keeps it live
/// only by assumption. In the VM that holds — a hot proto is reachable from a
/// live closure for as long as code can branch to its loop, so it outlives any
/// trace anchored in it. Tests that free the compiled chunk must therefore do so
/// *after* inspecting the cache (see `interp.zig`'s `runForTrace`). When cache
/// invalidation lands (a later phase) this is where proto liveness gets pinned
/// down properly.
pub const AnchorKey = struct { proto: *const Proto, pc: u32 };

/// Hash context for `AnchorKey` maps. These are probed on every tier-0
/// back-edge and return (`hasTrace`, the gate map), so the key gets a
/// two-multiply mix rather than `AutoContext`'s Wyhash pass over its bytes.
/// Pointer-based like `AutoContext` and `hotIndex`: the maps are
/// runtime-only state and traces are output-transparent, so the address
/// dependence changes timing, never results. The final xor-shift spreads the
/// product's high bits into the low bits the table indexes with; the high 7
/// bits stay strong for the metadata fingerprint.
pub const AnchorKeyContext = struct {
    pub fn hash(_: AnchorKeyContext, k: AnchorKey) u64 {
        var h: u64 = @intFromPtr(k.proto);
        h ^= @as(u64, k.pc) *% 0x9E3779B97F4A7C15;
        h *%= 0xD6E8FEB86659FD93;
        return h ^ (h >> 32);
    }
    pub fn eql(_: AnchorKeyContext, a: AnchorKey, b: AnchorKey) bool {
        return a.proto == b.proto and a.pc == b.pc;
    }
};

/// An unmanaged hash map keyed by `AnchorKey` (see `AnchorKeyContext`).
pub fn AnchorMap(comptime V: type) type {
    return std.HashMapUnmanaged(AnchorKey, V, AnchorKeyContext, std.hash_map.default_max_load_percentage);
}

/// The steps of a batch retirement (doc 61 §7.1 item 5, `removeTraces`).
pub const RetireStep = enum {
    /// Doomed traces marked.
    mark,
    /// Provenance edges scanned.
    provenance_edges,
    /// Execution logs scanned.
    exec_logs,
    /// Parked-proof edges scanned.
    parked_proofs,
    /// Promoted-set edges scanned or torn down.
    promoted_sets,
    /// Armed links scanned.
    armed_links,
    /// Promoted-set lookups for a surviving parent's reset slot.
    set_lookups,
    /// Doomed traces unpublished (entry patch, id index, anchor list).
    unpublish,
    /// Cache entries compacted.
    compact,
    /// Doomed anchors checked for reopening.
    reopen,
    /// Doomed records destroyed.
    destroy,
};

/// Items each retirement step visited, summed over every batch. Doc 61 asks
/// for counts, not times: each step must stay linear in what it scans.
/// Tests read it; nothing steers on it.
pub const RetireWork = std.EnumArray(RetireStep, u64);

/// Maximum nesting of inlined Lua calls a single trace may carry (cross-frame
/// tracing). Bounds the recorder's grown `reg_map` window and the depth of leaf
/// inlining. Down-recursion (the same proto re-inlined) is Phase 3; until then a
/// call beyond this depth aborts cleanly (`AbortReason.too_deep`) and tier-0 owns
/// the loop.
pub const MAX_INLINE_DEPTH = 3;
