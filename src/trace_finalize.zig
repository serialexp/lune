//! Freeze recorder scratch into an owned, unpublished code candidate.
//! No coordinator, registry, recorder, or native-code imports.
const std = @import("std");
const tropt = @import("tropt.zig");
const gc = @import("gc.zig");
const ir = @import("trace_ir.zig");
const types = @import("trace_types.zig");
const code_mod = @import("trace_code.zig");
const TraceCode = code_mod.TraceCode;
const Ref = ir.Ref;
const IrInstr = ir.IrInstr;
const PHI_INTERNAL = ir.PHI_INTERNAL;
const ExitProvenance = types.ExitProvenance;
const ExitProvEntry = types.ExitProvEntry;
const ProgramPoint = types.ProgramPoint;
const exitProvEntryLess = types.exitProvEntryLess;
const EntryGuard = code_mod.EntryGuard;
const EntryGuardType = code_mod.EntryGuardType;
const InputSeed = code_mod.InputSeed;
const trace_snapshot = @import("trace_snapshot.zig");
pub const RecordingCandidate = @import("trace_candidate.zig").RecordingCandidate;

pub const Options = struct {
    optimize: bool = true,
};

/// Words in the widest liveness row: `Proto.num_registers` is a `u16`.
pub const PHI_LIVE_WORDS = (std.math.maxInt(u16) + 64) / 64;

/// Doc 61 §5 (site 2, the dead-φ filter): the registers the loop-close φ set
/// must deliver, as the union of `Proto.reg_live` at every pc where tier-0
/// or a linked trace reads the φ-written register file. Null = keep every φ.
///
/// The φ set is consumed in three places:
///  - the close's resume pc: the anchor for a `.loop` close (the next
///    iteration, and every coarse deopt re-run from the loop header) or the
///    `.link` target;
///  - each numeric-`for` loop-done exit's resume pc. The linked loop-done
///    flush (`irinterp.flushNumericForLoopDone`, nativegen's
///    `emitLinkedLoopDoneSnapshot`) writes the φ set and resumes after the
///    loop. Its guards are exactly the depth-0 `.loop_done` `guard_true`s
///    sourced at a `for_loop` (unrolled mid-trip copies are
///    `.loop_test_copy`; a zero-trip skip is a `guard_false` whose failure
///    enters the loop, an ordinary coarse exit). Taken as live-in at the
///    guard's exit pc, the post-loop pc the flush resumes at. Live-in at the
///    `for_loop` would also keep the loop body's registers, which the flush
///    never hands to;
///  - a composite bridge (doc 17 A-vii-d.1) out of a branch guard whose
///    `CompositeWalk` crosses a `for_loop`. The bridge stands in for that
///    `for_loop`, so `compositeContinueProof` demands φs for the slots it
///    writes, `a` and `a+3`, whether or not they are live; without them the
///    proof fails closed and the edge is lost. Every slot the bridge's
///    successor reads besides those is live at the walk's landing pc, which
///    the exit snapshot covers (`bridgeMatchesExitSnapshot`). Where traces
///    will bind is unknown here, so the walk runs to its end.
///
/// A register dead at all of them is rewritten by tier-0 before any read,
/// so writing it back each iteration is a store nothing observes. Leaving
/// its slab copy stale is sound only where the collector masks the frame
/// (`maskable`); a captured register is live at every pc, so it is kept.
/// An allocating trace filters the same way: masking, not doc 24 D3's
/// full-write-set flush, keeps its roots tier-identical (doc 61 §9b). A
/// precise one keeps every φ anyway, since each slot is an entry slot.
/// Every φ stays when the trace is a one-shot head (its φ rows are the
/// terminal writeback set, doc 44).
/// `rec` is the recorder or a finalize fixture; `loopCloseDefeat` mirrors
/// finalize's filter through this and `phiWritebackKept`.
pub fn phiLiveRow(rec: anytype, buf: *[PHI_LIVE_WORDS]u64) ?[]const u64 {
    if (rec.terminal_close != null) return null;
    const proto = rec.anchor.proto;
    if (!proto.maskable) return null;
    const live = &proto.reg_live;
    std.debug.assert(live.available());
    const resume_pc = rec.link_target orelse rec.anchor.pc;
    if (resume_pc >= proto.code.len) return null;
    const row = buf[0..live.words];
    @memcpy(row, live.row(resume_pc));
    for (rec.exit_prov.items, 0..) |maybe, idx| {
        const gp = switch (maybe orelse continue) {
            .guard => |g| g,
            .link_terminal => continue,
        };
        if (gp.inline_depth != 0 or gp.source_proto_id != proto.id) continue;
        if (gp.source_pc >= proto.code.len) return null;
        const guard = rec.instrs.items[idx];
        switch (gp.role) {
            .loop_done => {
                if (guard.op != .guard_true) continue;
                if (proto.code[gp.source_pc].op != .for_loop) continue;
                const exit_pc = ir.guardExitPc(guard) orelse return null;
                if (exit_pc >= proto.code.len) return null;
                for (row, live.row(exit_pc)) |*w, l| w.* |= l;
            },
            .branch_cond => {
                if (guard.op != .guard_true and guard.op != .guard_false) continue;
                var walk = code_mod.CompositeWalk.init(proto.code, gp.source_pc, gp.polarity) orelse continue;
                while (walk.current()) |pc| {
                    if (pc == rec.anchor.pc or !walk.step()) break;
                }
                const flp = walk.crossed_for_loop orelse continue;
                const a = proto.code[flp].a;
                for ([_]usize{ a, @as(usize, a) + 3 }) |slot| {
                    if (slot / 64 < row.len) row[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
                }
            },
            else => {},
        }
    }
    return row;
}

/// Whether anchor-window slot `slot`, defined by the recording, gets a φ
/// writeback at the close. `live` is `phiLiveRow`'s answer. A slot the trace
/// read at entry is always kept.
pub fn phiWritebackKept(rec: anytype, slot: u16, live: ?[]const u64) bool {
    if (std.mem.indexOfScalar(u16, rec.entry_slots.items, slot) != null) return true;
    const row = live orelse return true;
    if (slot / 64 >= row.len) return true;
    return (row[slot / 64] >> @intCast(slot % 64)) & 1 != 0;
}

/// `rec` is a mutable scratch pointer whose type is inferred at comptime.
/// Structural typing avoids importing the legacy Recorder/coordinator cycle.
/// No pointer into scratch survives. Appends sunk stores, phis and terminal:
/// call once per recording, then reset scratch on success OR failure (no retry).
/// Optimizer OOM falls back to duplication; region metadata and bridge memo
/// allocation failures are fail-soft. Program/constant lifetimes follow TraceCode.
pub fn finalize(gpa: std.mem.Allocator, rec: anytype, options: Options) !RecordingCandidate {
    if (rec.guard_gc_ref) |gr| {
        // Doc 45 D4: a PRECISE recording emits `guard_gc` eagerly after its
        // entry-load prologue, so `aux == 0` is legal for a nonallocating
        // body (it still enforces `!gc_stress` and the due-GC check). Every
        // other recording only creates the guard lazily at its first `.alloc`.
        if (!rec.precise) std.debug.assert(rec.alloc_count > 0);
        rec.instrs.items[@intCast(gr)].aux = @intCast(rec.alloc_count);
    }
    // Doc 45 D3: precise candidates keep a single guest-ordered stream — the
    // recorder refuses every deferral, so nothing may be waiting here.
    if (rec.precise) std.debug.assert(rec.pending_stores.items.len == 0);
    for (rec.pending_stores.items) |ps| {
        try rec.instrs.append(gpa, .{
            .op = ps.op,
            .a = ps.aref,
            .b = ps.value,
            .aux = ps.lane_ord,
            // Doc 56 §4.2: the deferring bytecode's ordinal, so "which sunk
            // stores precede this guard" is `store.ord < guard.ord`.
            .ord = ps.ord,
        });
    }
    // Dead-at-every-resume slots get no φ (doc 61 §5, `phiLiveRow`).
    var live_buf: [PHI_LIVE_WORDS]u64 = undefined;
    const live = phiLiveRow(rec, &live_buf);
    for (rec.reg_map, 0..) |s, slot| {
        if (s.state != .def) continue;
        if (slot >= rec.anchor_num_registers) continue;
        if (!phiWritebackKept(rec, @intCast(slot), live)) continue;
        const steady_phi: Ref = if (rec.peel) |p| blk: {
            if (slot < p.slots.len) {
                if (p.slots[slot].phi_ref) |pr| break :blk pr;
            }
            break :blk 0;
        } else 0;
        try rec.instrs.append(gpa, .{
            .op = .phi,
            .a = steady_phi,
            .b = s.ref,
            .aux = @intCast(slot),
            .ty = rec.instrs.items[s.ref].ty,
        });
    }
    if (rec.terminal_close) |tc| {
        // Doc 44: the one-shot head-trace close — kind tag in `a`, the real
        // resume pc in `aux`.
        try rec.instrs.append(gpa, .{ .op = .terminal, .a = @intFromEnum(tc.kind), .aux = @intCast(tc.resume_pc) });
    } else if (rec.link_target) |lt| {
        try rec.instrs.append(gpa, .{ .op = .link, .a = @intFromEnum(rec.link_kind), .aux = @intCast(lt) });
    } else {
        try rec.instrs.append(gpa, .{ .op = .loop });
    }

    const instrs = rec.instrs.items;
    const consts = rec.consts.items;
    const entry = rec.entry_slots.items;

    // Doc 44: head (terminal-closed) traces cache UNOPTIMIZED in P0, the
    // link-trace precedent — tropt's φ handling is loop-carried-shaped and
    // has not been audited for the one-shot writeback rows.
    // Doc 45 D3: PRECISE candidates take the dupe path too (explicitly
    // identity for snapshots) — snapshot refs are not tropt liveness roots
    // yet and `old_to_new` cannot remap through CSE merges; the optimizer
    // integration (canonical-map remap + liveness extension) is its own
    // increment.
    //
    // Doc 56 §4.2: take ownership of the ordinary recording's sparse exit
    // snapshots BEFORE `tropt`, which roots the refs of the snapshots an exit
    // still uses, remaps them in place, and drops the rest.
    // Fail-soft metadata: precise traces (own snapshots), peeled traces
    // (deferred), an overflowed ordinal space, or an OOM all leave the trace
    // with none — every exit then stays anchor-coherent only.
    var exit_owned: ?trace_snapshot.Builder.Owned = null;
    var exit_by_ord: []ir.SnapIdx = &.{};
    errdefer if (exit_owned) |o| o.deinit(gpa);
    errdefer if (exit_by_ord.len != 0) gpa.free(exit_by_ord);
    if (!rec.precise and rec.peel == null and !rec.exit_ord_overflow and rec.cur_ord != 0 and rec.snap_builder_init and rec.snap_builder.records.items.len != 0) {
        if (rec.snap_builder.finalize(gpa)) |o| {
            if (gpa.dupe(ir.SnapIdx, rec.exit_snap_by_ord.items)) |m| {
                exit_owned = o;
                exit_by_ord = m;
            } else |_| o.deinit(gpa);
        } else |_| {}
    }
    const exit_for_opt: tropt.ExitSnaps = if (exit_owned) |o|
        .{ .snapshots = o.snapshots, .slots = o.snapshot_slots, .by_ord = exit_by_ord }
    else
        .{};

    const fields: tropt.Optimized = if (options.optimize and !rec.precise and rec.link_target == null and rec.peel == null and rec.terminal_close == null)
        tropt.optimize(gpa, instrs, consts, exit_for_opt) catch |e| switch (e) {
            error.OutOfMemory => try tropt.dupe(gpa, instrs, consts, entry),
        }
    else
        try tropt.dupe(gpa, instrs, consts, entry);
    errdefer {
        gpa.free(fields.instrs);
        gpa.free(fields.consts);
        gpa.free(fields.entry_slots);
    }
    defer fields.freeMap(gpa);

    if ((rec.link_target != null) != (rec.pending_link_provenance != null))
        @panic("commit: link_target / pending_link_provenance invariant violated");
    const link_term: ?ExitProvEntry = if (rec.pending_link_provenance) |lp|
        .{ .index = @intCast(fields.instrs.len - 1), .prov = lp }
    else
        null;
    var exit_prov_complete = true;
    var exit_prov_owned: []ExitProvEntry = &.{};
    if (buildExitProv(gpa, rec.exit_prov.items, fields.old_to_new, link_term)) |ok| {
        exit_prov_owned = ok;
    } else |_| {
        exit_prov_complete = false;
    }
    errdefer if (exit_prov_owned.len != 0) gpa.free(exit_prov_owned);

    var rec_path_complete = rec.rec_path_ok;
    const rec_path_owned: []ProgramPoint = if (rec.rec_path_ok and rec.rec_path.items.len != 0)
        (gpa.dupe(ProgramPoint, rec.rec_path.items) catch blk: {
            rec_path_complete = false;
            break :blk &.{};
        })
    else
        &.{};
    errdefer if (rec_path_owned.len != 0) gpa.free(rec_path_owned);

    // The ordinal → source map for the visualiser. Fail-soft and diagnostic:
    // an overflowed ordinal space would map late instructions to the wrong
    // bytecode, so it (like an OOM) commits no map at all.
    const src_by_ord_owned: []ProgramPoint = if (rec.src_by_ord_ok and !rec.exit_ord_overflow and rec.src_by_ord.items.len != 0)
        (gpa.dupe(ProgramPoint, rec.src_by_ord.items) catch &.{})
    else
        &.{};
    errdefer if (src_by_ord_owned.len != 0) gpa.free(src_by_ord_owned);

    assertWellFormed(fields.instrs, fields.consts.len, rec.anchor_num_registers, @as(usize, rec.anchor_num_registers) + rec.input_seeds.items.len, rec.precise);

    var entry_guards: std.ArrayListUnmanaged(EntryGuard) = .empty;
    errdefer entry_guards.deinit(gpa);
    for (fields.instrs, 0..) |ins, i| {
        const egt: ?EntryGuardType = switch (ins.op) {
            .guard_int => .int,
            .guard_float => .float,
            .guard_number => .number,
            .guard_table => .table,
            .guard_is_nil => .nil,
            .guard_is_false => .false_,
            .guard_is_true => .true_,
            else => null,
        };
        if (egt) |ty| {
            const ref: u32 = @intCast(ins.a);
            if (ref < i and fields.instrs[ref].op == .slot_load) {
                const slot: u16 = @intCast(fields.instrs[ref].aux);
                if (slot < rec.anchor_num_registers)
                    try entry_guards.append(gpa, .{ .slot = slot, .ty = ty });
            }
        }
    }
    const guards_owned = try entry_guards.toOwnedSlice(gpa);
    errdefer gpa.free(guards_owned);

    const inputs_owned: []InputSeed = if (rec.input_seeds.items.len == 0)
        &.{}
    else
        try gpa.dupe(InputSeed, rec.input_seeds.items);
    errdefer if (inputs_owned.len != 0) gpa.free(inputs_owned);

    // Doc 48: commit the recorder's lane pins against the COMMITTED index
    // space. tropt compaction is an index-lifetime transition exactly like the
    // peel rewind (codex round-1 blocker): a recorder `guard_ref` must be
    // remapped through `old_to_new`, and a pin whose guard was eliminated is
    // dropped. The dupe path has a null map (identity). Eviction metadata is
    // fail-soft: an OOM leaves the trace pinless, which only suppresses
    // eviction — but a surviving pin must point at a `guard_lane`, asserted.
    var pins_owned: []code_mod.LanePin = &.{};
    if (rec.lane_pins.items.len != 0) {
        var pins: std.ArrayListUnmanaged(code_mod.LanePin) = .empty;
        // A successful toOwnedSlice empties the list, so this deinit is a
        // no-op there; on the append/toOwnedSlice OOM paths it frees the
        // partial buffer (codex round-2 blocker: a failed toOwnedSlice
        // leaves ownership with the list).
        defer pins.deinit(gpa);
        blk: {
            for (rec.lane_pins.items) |pin| {
                const committed: u32 = if (fields.old_to_new) |m|
                    (m[pin.guard_ref] orelse continue)
                else
                    pin.guard_ref;
                std.debug.assert(fields.instrs[committed].op == .guard_lane);
                pins.append(gpa, .{ .guard_ref = committed, .table_id = pin.table_id }) catch break :blk;
            }
            pins_owned = pins.toOwnedSlice(gpa) catch &.{};
        }
    }
    errdefer if (pins_owned.len != 0) gpa.free(pins_owned);

    // Doc 61 §7.1 item 3: every heap value in the FINAL pool, not just the
    // live `konst` users — serializers and non-`konst` readers (`guard_sid`,
    // `sgmatch`, `callee_global` keys) see the whole pool. Correctness
    // metadata: OOM fails the commit.
    var n_heap: usize = 0;
    for (fields.consts) |v| n_heap += @intFromBool(v.isHeap());
    const heap_consts_owned: []u32 = if (n_heap == 0) &.{} else try gpa.alloc(u32, n_heap);
    errdefer if (heap_consts_owned.len != 0) gpa.free(heap_consts_owned);
    {
        var k: usize = 0;
        for (fields.consts, 0..) |v, i| {
            if (!v.isHeap()) continue;
            heap_consts_owned[k] = @intCast(i);
            k += 1;
        }
    }

    var requires_unicode_pin = false;
    for (fields.instrs) |ins| {
        if (ins.op == .supper or ins.op == .slower) requires_unicode_pin = true;
    }

    // Doc 45 D2: a PRECISE candidate takes ownership of its snapshot arrays
    // and must carry VALID correctness metadata — finalization rejects
    // missing/invalid snapshots outright (this is not fail-soft diagnostics).
    // The dupe path above kept instruction indices identity, so the recorded
    // one-based `snap` values and captured refs are final as-is.
    var snap_owned: ?trace_snapshot.Builder.Owned = null;
    errdefer if (snap_owned) |o| o.deinit(gpa);
    // Doc 63 §5.1: host call sites exist only in a precise recording.
    var sites_owned: []ir.HostCallSite = &.{};
    errdefer if (sites_owned.len != 0) gpa.free(sites_owned);
    if (!rec.precise and rec.host_sites.items.len != 0) return error.InvalidSnapshotMetadata;
    if (rec.precise) {
        // Doc 45 D6 (P2): a precise page never closes `.link` (the recorder
        // refuses both link-close paths) and never peels (`maybeEnterPeel`
        // declines precise) — backstop the structural prohibitions here so a
        // future recording path can't silently violate them.
        std.debug.assert(rec.link_target == null);
        std.debug.assert(rec.peel == null);
        const owned = try rec.snap_builder.finalize(gpa);
        snap_owned = owned;
        if (!trace_snapshot.validate(owned.snapshots, owned.snapshot_slots, @intCast(rec.anchor.proto.code.len)))
            return error.InvalidSnapshotMetadata;
        const gr = rec.guard_gc_ref orelse return error.InvalidSnapshotMetadata;
        for (fields.instrs, 0..) |ins, i| {
            if (ins.snap != 0) {
                if (owned.snapshots[ins.snap - 1].register_count != rec.anchor_num_registers)
                    return error.InvalidSnapshotMetadata;
                if (!trace_snapshot.refsDefinedAt(ins.snap, i, owned.snapshots, owned.snapshot_slots))
                    return error.InvalidSnapshotMetadata;
            } else if (ir.requiresPreciseSnapshot(ins.op) and i > @as(usize, @intCast(gr))) {
                // A potentially failing BODY op without a snapshot: only the
                // prologue (entry loads + the eager `guard_gc`) may fail
                // pre-body with entry-replay semantics. Covers every
                // exit-capable body op: the side-exit guards, the fallible
                // helpers, and the fallible effect ops (`tnew`/`tset`, doc
                // 45 D3) — an OOM at a snap-less `tnew` or string helper
                // would have nowhere to raise.
                return error.InvalidSnapshotMetadata;
            }
        }
        if (!hostPlacementValid(fields.instrs, owned.snapshots, rec.host_sites.items))
            return error.InvalidSnapshotMetadata;
        if (rec.host_sites.items.len != 0) sites_owned = try gpa.dupe(ir.HostCallSite, rec.host_sites.items);
    }

    // Doc 56 §4.2: tropt zeroed every ordinal whose exits it all removed
    // (their refs were not rooted, nor remapped); compact the store down to
    // the kept records. Every recorded ordinal names its own record, so
    // "kept == records" means nothing was dropped. Fail-soft: an OOM or an
    // inconsistent map drops them all.
    if (exit_owned) |o| {
        var kept: usize = 0;
        for (exit_by_ord) |si| kept += @intFromBool(si != 0);
        if (kept != o.snapshots.len) {
            const c = trace_snapshot.compactSparse(gpa, o.snapshots, o.snapshot_slots, exit_by_ord) catch null;
            o.deinit(gpa);
            exit_owned = null;
            if (c) |co| {
                if (co.snapshots.len != 0) exit_owned = co;
            }
            if (exit_owned == null) {
                gpa.free(exit_by_ord);
                exit_by_ord = &.{};
            }
        }
    }

    // Doc 56 §4.2: validate the exit snapshots against the COMMITTED stream
    // (after tropt's remap). Any defect drops them all — fail-soft, since an
    // exit without a snapshot merely stays anchor-coherent.
    if (exit_owned) |o| {
        if (!exitSnapshotsValid(fields.instrs, o, exit_by_ord, rec.anchor_num_registers, @intCast(rec.anchor.proto.code.len))) {
            o.deinit(gpa);
            exit_owned = null;
            gpa.free(exit_by_ord);
            exit_by_ord = &.{};
        }
    }

    var code: TraceCode = .{
        .anchor = rec.anchor,
        .instrs = fields.instrs,
        .consts = fields.consts,
        .heap_consts = heap_consts_owned,
        .entry_slots = fields.entry_slots,
        .entry_guards = guards_owned,
        .inputs = inputs_owned,
        .exit_prov = exit_prov_owned,
        .exit_prov_complete = exit_prov_complete,
        .rec_path = rec_path_owned,
        .rec_path_complete = rec_path_complete,
        .src_by_ord = src_by_ord_owned,
        .alloc_bound = rec.alloc_count,
        .requires_unicode_pin = requires_unicode_pin,
        .unrolled_while = rec.unrolled_while,
        .peeled = rec.peel != null,
        .instunrolled = rec.unroll_used,
        // Doc 45 D2: snapshot ownership moves to the code (freed by its
        // deinit, which every candidate error path funnels through). No error
        // return exists past this literal, so the errdefer above cannot
        // double-free.
        .snapshots = if (snap_owned) |o| o.snapshots else &.{},
        .snapshot_slots = if (snap_owned) |o| o.snapshot_slots else &.{},
        .deopt_mode = if (rec.precise) .precise else .entry_replay,
        .host_sites = sites_owned,
        .exit_snapshots = if (exit_owned) |o| o.snapshots else &.{},
        .exit_snapshot_slots = if (exit_owned) |o| o.snapshot_slots else &.{},
        .exit_snap_by_ord = exit_by_ord,
        .lane_pins = pins_owned,
    };
    // First: every classifier below asks it per guard.
    code.buildFrameMemo(gpa);
    buildBridgeCandMemo(gpa, &code);
    // Doc 56 §4.3: each exit's static facts (attachability, resume pc,
    // loop-done and own-loop-test shape), once, from the final code.
    code.buildExitFacts(gpa);
    return RecordingCandidate.init(code, rec.side_src);
}

/// Doc 56 §4.2: an ordinary trace's exit snapshots, checked in the COMMITTED
/// index space (after `tropt`'s remap): structurally sound sparse vectors over
/// the anchor window, a well-formed ordinal table, every op's ordinal in
/// range, and every side-exit guard's snapshot refs defined before the guard
/// (a forward ref would write an undefined value at the exit).
pub fn exitSnapshotsValid(
    instrs: []const IrInstr,
    o: trace_snapshot.Builder.Owned,
    by_ord: []const ir.SnapIdx,
    register_count: u16,
    code_len: u32,
) bool {
    if (!trace_snapshot.validateSparse(o.snapshots, o.snapshot_slots, code_len)) return false;
    for (o.snapshots) |s| {
        if (s.register_count != register_count) return false;
    }
    for (o.snapshot_slots) |ss| {
        if (ss.ref >= instrs.len) return false;
    }
    if (by_ord.len == 0 or by_ord[0] != 0) return false;
    for (by_ord) |si| {
        if (si > o.snapshots.len) return false;
    }
    for (instrs, 0..) |ins, i| {
        if (ins.ord >= by_ord.len) return false;
        if (!ir.isSideExitGuardOp(ins.op)) continue;
        const si = by_ord[ins.ord];
        if (si == 0) continue;
        if (!trace_snapshot.refsDefinedAt(si, i, o.snapshots, o.snapshot_slots)) return false;
    }
    return true;
}

/// Populate `code.bridge_cand` / `code.bridge_cand_built` by evaluating the
/// pure `isCompositeBridgeCandidate` classifier once per instruction index
/// (doc 17 §T.9) — the same classifier native lowering uses. Call once, at
/// commit, after the code is fully populated.
///
/// FAIL-SOFT by design: on OOM the memo is simply left unbuilt and
/// `isBridgeCandidate` falls back to the oracle, never an incomplete bitset.
/// There is deliberately no error return — a commit must never fail because
/// an accelerator could not be allocated.
pub fn buildBridgeCandMemo(gpa: std.mem.Allocator, code: *TraceCode) void {
    if (code.instrs.len == 0) {
        code.bridge_cand_built = true;
        return;
    }
    const bytes = gpa.alloc(u8, (code.instrs.len + 7) / 8) catch return;
    @memset(bytes, 0);
    for (0..code.instrs.len) |i| {
        if (code.classifyBridgeCandidate(i))
            bytes[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
    }
    code.bridge_cand = bytes;
    code.bridge_cand_built = true;
}

/// Remap the recorder's dense, emission-indexed exit-provenance table (A-i.1)
/// into the committed trace's compact, sorted `[]ExitProvEntry`, keyed by
/// committed instruction index. `old_to_new` is `tropt`'s compaction map
/// (emission index → committed index, `null` for a dropped instr); pass `null`
/// for the identity map (the `dupe` path — link + unoptimized traces preserve
/// indices 1:1). Only non-`null` provenance whose instruction survived
/// compaction is carried over (the many-to-one dedup already happened at stamp
/// time).
///
/// `link_terminal` (A-i.4) carries the `.link` terminal's provenance and its
/// committed index. The `.link`/`.loop` terminal is appended directly to
/// `instrs` at commit — it never went through `emit`, so it has NO lockstep
/// `rec_exit_prov` slot; it is injected here as one extra entry. `null` for
/// every non-link trace (a `.loop` terminal is a back-edge, not an exit).
///
/// Returns a static empty slice when there is nothing to carry (no alloc).
/// Caller owns the result.
pub fn buildExitProv(
    gpa: std.mem.Allocator,
    rec_exit_prov: []const ?ExitProvenance,
    old_to_new: ?[]const ?Ref,
    link_terminal: ?ExitProvEntry,
) ![]ExitProvEntry {
    if (old_to_new) |m| std.debug.assert(m.len >= rec_exit_prov.len);
    var count: usize = if (link_terminal != null) 1 else 0;
    for (rec_exit_prov, 0..) |p, i| {
        if (p == null) continue;
        const survived = if (old_to_new) |m| m[i] != null else true;
        if (survived) count += 1;
    }
    if (count == 0) return &.{};
    const out = try gpa.alloc(ExitProvEntry, count);
    errdefer gpa.free(out);
    var k: usize = 0;
    for (rec_exit_prov, 0..) |p, i| {
        const prov = p orelse continue;
        const committed: u32 = if (old_to_new) |m| (m[i] orelse continue) else @intCast(i);
        out[k] = .{ .index = committed, .prov = prov };
        k += 1;
    }
    if (link_terminal) |lt| {
        out[k] = lt;
        k += 1;
    }
    std.debug.assert(k == count);
    // Committed indices are already ascending for guards/fused producers (neither is
    // hoisted into the preheader, so compaction preserves their relative order), but
    // sort defensively so `Trace.provAt`'s binary search is correct regardless of any
    // future LICM change.
    std.mem.sort(ExitProvEntry, out, {}, exitProvEntryLess);
    return out;
}

/// Doc 63 §5.2: the placement rule for host calls and coherent snapshots.
/// Each site's ops form one contiguous run,
/// `guard_native, call_host, guard_host_epoch, host_result × nwanted`, and:
///
/// - the k-th `call_host` names site k, and every site is named once;
/// - `guard_native` exits through the full snapshot S_B, which is the site's
///   `preflush_snap` and resumes at B;
/// - `call_host` exits through a coherent snapshot resuming at B, the
///   guard and the results through coherent snapshots resuming at B + 1;
/// - result k has `aux == k` and a concrete observed type;
/// - the callee, argument and result registers lie inside the window;
/// - no other op references a coherent snapshot.
///
/// So between the call and every coherent exit only loads and compares run,
/// and the slab is exactly tier-0's state there. Assumes `validate` passed
/// and every `snap` is in range (the caller's loop checks both).
pub fn hostPlacementValid(instrs: []const IrInstr, snapshots: []const trace_snapshot.Snapshot, sites: []const ir.HostCallSite) bool {
    var calls: usize = 0;
    var i: usize = 0;
    while (i < instrs.len) : (i += 1) {
        const ins = instrs[i];
        if (ins.snap != 0 and snapshots[ins.snap - 1].coherent and !ir.isHostCoherentOp(ins.op)) return false;
        switch (ins.op) {
            .guard_native => if (i + 1 >= instrs.len or instrs[i + 1].op != .call_host) return false,
            .call_host => {
                const run = hostRunLen(instrs, snapshots, sites, i, calls) orelse return false;
                calls += 1;
                i += run - 1;
            },
            // Only reachable outside a run: a run is skipped whole.
            .guard_host_epoch, .host_result => return false,
            else => {},
        }
    }
    return calls == sites.len;
}

/// The length of the host run whose `call_host` is at `at` (from the
/// `call_host` on), or null when it breaks `hostPlacementValid`'s rule.
fn hostRunLen(instrs: []const IrInstr, snapshots: []const trace_snapshot.Snapshot, sites: []const ir.HostCallSite, at: usize, nth: usize) ?usize {
    const call = instrs[at];
    if (call.a != nth or nth >= sites.len) return null;
    const site = sites[nth];
    if (at == 0) return null;
    const guard = instrs[at - 1];
    if (guard.op != .guard_native or guard.snap == 0 or guard.snap != site.preflush_snap) return null;
    const s_b = snapshots[guard.snap - 1];
    if (s_b.coherent or s_b.resume_pc != site.b_pc) return null;
    const window: u32 = s_b.register_count;
    if (@as(u32, site.a) + 1 + site.nargs > window or @as(u32, site.a) + site.nwanted > window) return null;
    if (!coherentAt(snapshots, call.snap, site.b_pc)) return null;

    const run: usize = 2 + @as(usize, site.nwanted);
    if (at + run > instrs.len) return null;
    const epoch = instrs[at + 1];
    if (epoch.op != .guard_host_epoch or epoch.a != nth or !coherentAt(snapshots, epoch.snap, site.b_pc + 1)) return null;
    for (0..site.nwanted) |k| {
        const r = instrs[at + 2 + k];
        if (r.op != .host_result or r.a != nth or r.aux != @as(i32, @intCast(k))) return null;
        if (r.ty == .unknown or !coherentAt(snapshots, r.snap, site.b_pc + 1)) return null;
    }
    return run;
}

fn coherentAt(snapshots: []const trace_snapshot.Snapshot, snap: ir.SnapIdx, resume_pc: u32) bool {
    if (snap == 0) return false;
    const s = snapshots[snap - 1];
    return s.coherent and s.resume_pc == resume_pc;
}

fn assertWellFormed(instrs: []const IrInstr, consts_len: usize, num_registers: usize, input_limit: usize, precise: bool) void {
    std.debug.assert(instrs.len >= 1);
    const last = instrs.len - 1;
    // The trace terminates in exactly one terminal: `.loop` (root/continuation
    // back-edge), `.link` (continuation hand-off to an inner root, doc 15), or
    // `.terminal` (one-shot close of a head-anchored trace, doc 44).
    std.debug.assert(instrs[last].op == .loop or instrs[last].op == .link or instrs[last].op == .terminal);
    for (instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < input_limit),
            // Doc 43 P5: `uref`'s aux is a synthetic seed slot — same bound as
            // a slot_load (and always >= num_registers, but the tighter check
            // needs the recorder's seed layout, which finalize doesn't carry).
            .uref => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < input_limit),
            // `uload` reads its uref; `ustore` reads uref + value.
            .uload => std.debug.assert(ins.a < i),
            .ustore, .guard_absent => std.debug.assert(ins.a < i and ins.b < i),
            .konst => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len),
            .loop => std.debug.assert(i == last), // the only loop, and it is terminal
            // `.link` (doc 15): terminal hand-off to an inner root. Like `.loop`
            // it is the sole terminal; `aux` is the inner anchor pc, not an
            // operand ref, so nothing to bound-check beyond terminality; `a`
            // is a `LinkKind` tag (doc 56).
            .link => std.debug.assert(i == last and std.enums.fromInt(ir.LinkKind, ins.a) != null),
            // `.terminal` (doc 44): the one-shot head-trace close. Sole
            // terminal; `a` is a TerminalKind tag and `aux` the resume pc —
            // neither is an operand ref.
            .terminal => std.debug.assert(i == last),
            // binary ops read both `a` and `b`.
            .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .eq, .ne, .lt, .le => {
                std.debug.assert(ins.a < i and ins.b < i);
            },
            // unary ops and guards read `a` only.
            .neg, .not, .bnot, .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .guard_func => {
                std.debug.assert(ins.a < i);
            },
            // Doc 57: the primitive pins read `a` only.
            .guard_is_nil, .guard_is_false, .guard_is_true => std.debug.assert(ins.a < i),
            // The step-direction guards read the step `a` only.
            .guard_step_up, .guard_step_down => std.debug.assert(ins.a < i),
            // The overflow guard reads its bound `a` and step `b`.
            .guard_for_nov => std.debug.assert(ins.a < i and ins.b < i),
            // `int_of_float` reads its sole float operand `a` (a prior node).
            .int_of_float => std.debug.assert(ins.a < i),
            // `alen` reads its sole table operand `a` (a prior node).
            .alen => std.debug.assert(ins.a < i),
            // `fsin`/`fcos`/`ffloor`/`fceil` read their sole numeric operand `a` (a prior node).
            .fsin, .fcos, .ffloor, .fceil => std.debug.assert(ins.a < i),
            // Doc 24 D4: `tostr_*` read their guarded numeric operand,
            // `slen`/`guard_string` their string operand — all prior nodes.
            // Doc 26: `supper`/`slower` read their string operand like `srev`.
            .tostr_int, .tostr_num, .slen, .guard_string, .srev, .schar1, .supper, .slower => std.debug.assert(ins.a < i),
            .srep2 => {
                std.debug.assert(ins.a < i);
                std.debug.assert(ins.b < i);
            },
            // ssub's third operand rides `aux` as a Ref (doc 24 codex #4);
            // `scp` shares the three-operand encoding (doc 26 D3), as do
            // doc 30's `sfindp`/`smatch` (subject, init, pattern-in-aux).
            .ssub, .scp, .sfindp, .smatch => {
                std.debug.assert(ins.a < i);
                std.debug.assert(ins.b < i);
                std.debug.assert(ins.aux >= 0 and ins.aux < i);
            },
            // Doc 30 `sgmatch`: `a` = state ref; `aux` = konst-pool id
            // (an immediate, bounds-checked against the pool).
            .sgmatch => {
                std.debug.assert(ins.a < i);
                std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len);
            },
            // Doc 30 projections: `a` = the match op ref; `b` = slot
            // immediate within the scratch geometry (never a ref).
            .scap_int, .scap_str => {
                std.debug.assert(ins.a < i);
                std.debug.assert(@as(usize, ins.b) < gc.MatchScratch.n_slots);
            },
            // Doc 30 str2num: unary on a proven-string ref.
            .str2num_i, .str2num_f => std.debug.assert(ins.a < i),
            // Doc 30 sgm_setpos: state ref + new-pos ref, both prior.
            .sgm_setpos => {
                std.debug.assert(ins.a < i);
                std.debug.assert(ins.b < i);
            },
            // Doc 30 guard_sid: string ref + konst-pool id immediate.
            .guard_sid => {
                std.debug.assert(ins.a < i);
                std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len);
            },
            // `guard_gc` (doc 24 D3): operand-free; `aux` is the allocation
            // bound `A` — a positive count stamped by `commit()`. Doc 45 D4:
            // a PRECISE body emits the guard eagerly, so `aux == 0` is legal
            // there (nonallocating body — the guard still enforces
            // `!gc_stress` and the due-GC check).
            .guard_gc => std.debug.assert(if (precise) ins.aux >= 0 else ins.aux > 0),
            // `guard_builtin` reads the callee ref `a`; `fsqrt` reads its float
            // operand `a` — both prior nodes.
            .guard_builtin, .fsqrt => std.debug.assert(ins.a < i),
            // `aref` pairs (table, index) into an address descriptor;
            // `astore`/`astore_append` read the `aref` (`a`) and the value (`b`).
            // `href` (table, key konst) and `hstore` (href, value) mirror them.
            .aref, .astore, .astore_append, .href, .hstore => std.debug.assert(ins.a < i and ins.b < i),
            // Grid cell access (doc 14, Phase 8): `garow` pairs (table,row),
            // `gcell` pairs (garow,col), `gstore` reads (gcell, value) — all two
            // prior operands. `gload` and the grid guards read one prior node.
            .garow, .gcell, .gstore, .guard_gcol => std.debug.assert(ins.a < i and ins.b < i),
            .gload, .guard_grid, .guard_stride, .guard_gpresent => std.debug.assert(ins.a < i),
            // `aload` and the array-access guards read one prior node
            // (the table value, or the `aref`). `guard_append` reads the `aref`.
            // `hload`/`guard_hash` read the `href` (`a`).
            .aload, .guard_table, .guard_lane, .guard_present, .guard_fits, .guard_append, .hload, .guard_hash => {
                std.debug.assert(ins.a < i);
            },
            // `guard_bounds` carries producer-dispatched semantics (doc 18 D3):
            // tier-1a selects the bounds rule from the producer op, so the
            // producer must be one of exactly two memory ops — `aref` (scalar
            // array key) or `garow` (grid row). Both are canonical-to-self in
            // `tropt` (never folded/CSE'd) and `a` is remapped through
            // compaction, so this holds post-optimization too; pin it so
            // malformed IR fails closed here rather than mis-dispatching.
            .guard_bounds => {
                std.debug.assert(ins.a < i);
                const producer = instrs[ins.a].op;
                std.debug.assert(producer == .aref or producer == .garow);
            },
            // φ: the init `a` is an ordinary backward ref (a < i); the update
            // `b` is the back-edge value and may reference a *later* node, like
            // an `exit_store.ref` — only required to precede the `loop` marker.
            // `aux` is the flush slot (a valid register) or the internal sentinel.
            .phi => {
                std.debug.assert(ins.a < i);
                std.debug.assert(ins.b < last);
                std.debug.assert(ins.aux == PHI_INTERNAL or
                    (ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < num_registers));
                // Doc 39: a slot-bound φ's `a` is either 0 (unused — no
                // steady-state internal φ; the historical value) or the
                // slot's INTERNAL φ (the durable slot↔φ association a
                // peeled trace commits). Unambiguous: instruction 0 can
                // never be a φ (its `a < i` requires i > 0).
                if (ins.aux != PHI_INTERNAL and ins.a != 0) {
                    const assoc = instrs[@intCast(ins.a)];
                    std.debug.assert(assoc.op == .phi and assoc.aux == PHI_INTERNAL);
                }
            },
            // Doc 45 D3 `tnew`: operand-free identity-bearing allocation —
            // only legal in a PRECISE trace (its OOM leg needs the
            // per-bytecode snapshot + `.precise_error` contract; the snap
            // requirement itself is enforced by the finalize loop via
            // `requiresPreciseSnapshot`).
            .tnew => std.debug.assert(precise),
            // Doc 45 D3 `tset`: reserved — nothing may emit it until the
            // effect-ordering increment lands.
            .tset => unreachable,
            // Doc 63 §5.1: precise-only. `guard_native` reads the callee ref
            // and names a constant; the rest carry a site index, which the
            // placement check bounds (an error there, not an assert).
            .guard_native => std.debug.assert(precise and ins.a < i and ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len),
            .call_host, .guard_host_epoch, .host_result => std.debug.assert(precise),
            // Preheader region boundary (Phase E1): a pure marker, no operands.
            // Structural invariants (at most one; before any φ) are asserted in
            // the global pass below.
            .preheader => {},
        }
    }
    // Preheader structural rules (Phase E1 / LICM): at most one marker, and no
    // `phi` may precede it (loop-carried values must run every iteration, but a
    // φ before the marker would be skipped on iterations 2+).
    var preheader_idx: ?usize = null;
    for (instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            std.debug.assert(preheader_idx == null); // at most one
            preheader_idx = i;
        }
    }
    if (preheader_idx) |ph| {
        for (instrs[0..ph]) |ins| std.debug.assert(ins.op != .phi);
    }
}
