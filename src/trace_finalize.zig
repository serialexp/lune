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
        });
    }
    for (rec.reg_map, 0..) |s, slot| {
        if (s.state != .def) continue;
        if (slot >= rec.anchor_num_registers) continue;
        // Doc 44: a `.head` trace's φ rows are its TERMINAL writeback set —
        // tier-0 resumes at the ret/self-call, which may read temps above the
        // locals watermark (e.g. the summed result a `ret` returns) — so the
        // watermark filter below must not drop any defined slot.
        if (rec.terminal_close == null and rec.alloc_count == 0 and
            slot >= rec.locals_watermark and std.mem.indexOfScalar(u16, rec.entry_slots.items, @intCast(slot)) == null) continue;
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
        try rec.instrs.append(gpa, .{ .op = .link, .aux = @intCast(lt) });
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
    const fields: tropt.Optimized = if (options.optimize and !rec.precise and rec.link_target == null and rec.peel == null and rec.terminal_close == null)
        tropt.optimize(gpa, instrs, consts) catch |e| switch (e) {
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

    assertWellFormed(fields.instrs, fields.consts.len, rec.anchor_num_registers, @as(usize, rec.anchor_num_registers) + rec.input_seeds.items.len, rec.precise);

    var entry_guards: std.ArrayListUnmanaged(EntryGuard) = .empty;
    errdefer entry_guards.deinit(gpa);
    for (fields.instrs, 0..) |ins, i| {
        const egt: ?EntryGuardType = switch (ins.op) {
            .guard_int => .int,
            .guard_float => .float,
            .guard_number => .number,
            .guard_table => .table,
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
    if (rec.precise) {
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
            } else if (ir.isSideExitGuardOp(ins.op) and i > @as(usize, @intCast(gr))) {
                // A potentially failing BODY op without a snapshot: only the
                // prologue (entry loads + the eager `guard_gc`) may fail
                // pre-body with entry-replay semantics.
                return error.InvalidSnapshotMetadata;
            }
        }
    }

    var code: TraceCode = .{
        .anchor = rec.anchor,
        .instrs = fields.instrs,
        .consts = fields.consts,
        .entry_slots = fields.entry_slots,
        .entry_guards = guards_owned,
        .inputs = inputs_owned,
        .exit_prov = exit_prov_owned,
        .exit_prov_complete = exit_prov_complete,
        .rec_path = rec_path_owned,
        .rec_path_complete = rec_path_complete,
        .alloc_bound = rec.alloc_count,
        .requires_unicode_pin = requires_unicode_pin,
        .unrolled_while = rec.unrolled_while,
        .peeled = rec.peel != null,
        // Doc 45 D2: snapshot ownership moves to the code (freed by its
        // deinit, which every candidate error path funnels through). No error
        // return exists past this literal, so the errdefer above cannot
        // double-free.
        .snapshots = if (snap_owned) |o| o.snapshots else &.{},
        .snapshot_slots = if (snap_owned) |o| o.snapshot_slots else &.{},
        .deopt_mode = if (rec.precise) .precise else .entry_replay,
    };
    buildBridgeCandMemo(gpa, &code);
    return RecordingCandidate.init(code, rec.side_src);
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
            // needs the recorder's watermark, which finalize doesn't carry).
            .uref => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < input_limit),
            // `uload` reads its uref; `ustore` reads uref + value.
            .uload => std.debug.assert(ins.a < i),
            .ustore, .guard_absent => std.debug.assert(ins.a < i and ins.b < i),
            .konst => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len),
            .loop => std.debug.assert(i == last), // the only loop, and it is terminal
            // `.link` (doc 15): terminal hand-off to an inner root. Like `.loop`
            // it is the sole terminal; `aux` is the inner anchor pc, not an
            // operand ref, so nothing to bound-check beyond terminality.
            .link => std.debug.assert(i == last),
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
