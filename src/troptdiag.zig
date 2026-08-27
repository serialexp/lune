//! Trace-opportunity detector — a deterministic analysis pass over an optimized
//! trace that scores it against a catalog of "waste signatures" and emits a
//! structured report. New programs *announce* their optimization opportunities
//! without anyone reading disassembly. Even when a flagged instance turns out
//! non-reducible, we learned that for free.
//!
//! See `NOTES_trace_opportunities.md` for the motivation and the full waste-signature
//! catalog. This first cut implements the two measured waste patterns from
//! pi_leibniz: dead carried phis and duplicate carries.
//!
//! The analysis is pure detection — it never mutates the trace. Detection is always
//! safe; only a later *transform* (e.g. dead-phi elimination) needs the soundness
//! proof. Surface behind `--trace-opportunities` (stderr, like `--dump-traces`).

const std = @import("std");
const trace = @import("trace.zig");
const io = @import("io.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");

const IrInstr = trace.IrInstr;
const IrOp = trace.IrOp;
const Ref = trace.Ref;

/// Waste-signature catalog. Each variant identifies one category of redundant or
/// dead computation in a recorded+optimized trace.
pub const Waste = enum {
    /// A slot-bound phi whose flushed register is never read by a slot_load and
    /// is not live-in at the loop anchor (not in entry_slots). The phi's update
    /// chain is computed and flushed to memory every iteration for no consumer.
    dead_carry,
    /// Two slot-bound phis with the same update ref but different flush slots.
    /// Both write the identical value to distinct registers — one is redundant.
    duplicate_carry,
    /// A pure binary or unary instruction whose operands are all loop-invariant
    /// but which sits in the loop body rather than the preheader. The LICM pass
    /// should have hoisted it; its presence here means either the pass missed it
    /// or it was pinned (e.g. idiv/mod can error, so they stay in the body by
    /// design — these are flagged with a qualifier).
    unhoisted_invariant,
    /// Two guards with the same opcode and operand. The earlier guard dominates
    /// the later one, so the later guard is redundant and costs a re-check every
    /// iteration. Post-optimizer this should be rare (the optimizer deduplicates
    /// exact-match guards), so a hit is a strong signal.
    redundant_guard,
};

/// One detected waste site. `instrs` lists the instruction indices (into the
/// trace's `instrs` array) that constitute the waste; the indices are sorted and
/// may be rendered as compact ranges in output. `label` is a human-readable
/// description (allocated with the same allocator passed to `analyze`).
pub const Finding = struct {
    waste: Waste,
    instrs: []Ref,
    label: []const u8,
};

/// Run all waste-signature detectors over an optimized trace. Returns a slice of
/// Findings; each Finding's `instrs` and `label` are owned by the caller (allocated
/// with `gpa`). The returned slice itself is also caller-owned.
pub fn analyze(gpa: std.mem.Allocator, t: *const trace.Trace) ![]Finding {
    var list: std.ArrayListUnmanaged(Finding) = .empty;
    errdefer {
        for (list.items) |f| {
            gpa.free(f.instrs);
            gpa.free(f.label);
        }
        list.deinit(gpa);
    }

    try detectDeadCarries(gpa, t, &list);
    try detectDuplicateCarries(gpa, t, &list);
    try detectUnhoistedInvariants(gpa, t, &list);
    try detectRedundantGuards(gpa, t, &list);

    return list.toOwnedSlice(gpa);
}

/// Free every allocation in `findings` and the slice itself.
pub fn deinitFindings(gpa: std.mem.Allocator, findings: []Finding) void {
    for (findings) |f| {
        gpa.free(f.instrs);
        gpa.free(f.label);
    }
    gpa.free(findings);
}

/// Print findings to `w` in a columnar, human-readable form. Each finding lists
/// the waste signature, a description, and the affected instruction indices as
/// compact ranges (consecutive indices like `%030-%033`, singletons like `%029`).
pub fn writeFindings(w: *io.Writer, _: *const trace.Trace, findings: []const Finding) !void {
    if (findings.len == 0) {
        try w.print("  (no waste detected)\n", .{});
        return;
    }

    for (findings) |f| {
        try w.print("  {s}: {s}\n", .{ @tagName(f.waste), f.label });
        try w.writeAll("    waste: ");
        try writeRefRanges(w, f.instrs);
        try w.print("  ({d} instr(s))\n", .{f.instrs.len});
    }
}

// ---------------------------------------------------------------------------
// Dead-carried-phi detector
// ---------------------------------------------------------------------------

/// Detect slot-bound phis whose flushed register is never read and is not
/// live-in at the loop anchor. Reports the phi plus its exclusive dependency
/// chain (instructions that feed only that phi or other dead-chain instructions).
fn detectDeadCarries(
    gpa: std.mem.Allocator,
    t: *const trace.Trace,
    list: *std.ArrayListUnmanaged(Finding),
) !void {
    const n = t.instrs.len;
    if (n == 0) return;

    // Count uses of each instruction (how many other instructions reference it).
    const uses = try gpa.alloc(u32, n);
    defer gpa.free(uses);
    @memset(uses, 0);
    for (t.instrs) |ins| {
        switch (ins.op) {
            .add, .sub, .mul, .div, .idiv, .mod, .pow,
            .band, .bor, .bxor, .shl, .shr, .sar,
            .eq, .ne, .lt, .le,
            => {
                uses[ins.a] += 1;
                uses[ins.b] += 1;
            },
            .neg, .not, .bnot,
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false,
            .aload,
            .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits,
            .guard_append,
            .int_of_float,
            .guard_func,
            .hload, .guard_hash,
            .guard_builtin, .fsqrt, .fsin, .fcos,
            // Grid-cell ops reading only `a` (doc 14): the cell load and the
            // structural guards that reach the table/cell through the address chain.
            .gload, .guard_grid, .guard_stride, .guard_gpresent,
            .alen,
            => {
                uses[ins.a] += 1;
            },
            // Grid-cell address producers + store + the column guard read both operands
            // (table+row, garow+col, gcell+value, gcell+col).
            .aref, .astore, .astore_append, .href, .hstore,
            .garow, .gcell, .gstore, .guard_gcol => {
                uses[ins.a] += 1;
                uses[ins.b] += 1;
            },
            .phi => {
                uses[ins.b] += 1; // the update is always a use
                if (ins.aux == trace.PHI_INTERNAL) uses[ins.a] += 1; // internal phi uses its init
            },
            // `.link` (doc 15) carries no operand refs (`aux` is the inner anchor pc),
            // so like `.loop`/`.preheader` it contributes no uses.
            .slot_load, .konst, .loop, .preheader, .link => {},
        }
    }

    // Build a set of slots that are read (via slot_load) or live-in (entry_slots).
    // First find the maximum slot index across all sources (entry_slots,
    // slot_load instructions, and phi flush slots).
    var max_slot: i32 = 0;
    for (t.entry_slots) |s| {
        if (@as(i32, @intCast(s)) > max_slot) max_slot = @intCast(s);
    }
    for (t.instrs) |ins| {
        if (ins.op == .slot_load) {
            if (ins.aux > max_slot) max_slot = ins.aux;
        }
        if (ins.op == .phi and ins.aux >= 0) {
            if (ins.aux > max_slot) max_slot = ins.aux;
        }
    }
    max_slot += 1; // convert max index to length
    const live_slots = try gpa.alloc(bool, @intCast(max_slot));
    defer gpa.free(live_slots);
    @memset(live_slots, false);
    for (t.entry_slots) |s| live_slots[@intCast(s)] = true;
    for (t.instrs) |ins| {
        if (ins.op == .slot_load) live_slots[@intCast(ins.aux)] = true;
    }

    // Find dead phis: slot-bound, flush slot not in live_slots.
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        if (live_slots[slot]) continue; // slot is read or live-in — this phi is useful

        // This phi is a dead carry. Compute its exclusive dependency chain.
        var dead_set: std.AutoHashMapUnmanaged(Ref, void) = .empty;
        defer dead_set.deinit(gpa);

        // The phi itself is waste.
        try dead_set.put(gpa, @intCast(i), {});

        // Walk backward from the phi's update, collecting instructions whose
        // *only* consumers (after discounting the dead set) are in the dead set.
        // Iterate to a fixed point.
        var changed = true;
        while (changed) {
            changed = false;
            var j: usize = n;
            while (j > 0) {
                j -= 1;
                if (dead_set.contains(@intCast(j))) continue;
                if (uses[j] == 0) continue; // dead anyway (shouldn't happen post-optimize)

                // Loop/preheader markers have no consumers by definition — skip.
                const op = t.instrs[j].op;
                if (op == .loop or op == .preheader) continue;

                // Any other instruction whose all consumers are in the dead set
                // is exclusive waste. This includes konst/slot_load leaves if
                // they feed only dead instructions.
                if (allConsumersInSet(t.instrs, j, &dead_set)) {
                    try dead_set.put(gpa, @intCast(j), {});
                    changed = true;
                }
            }
        }

        // Build the sorted instrs list.
        var instr_list: std.ArrayListUnmanaged(Ref) = .empty;
        defer instr_list.deinit(gpa);
        {
            var it = dead_set.keyIterator();
            while (it.next()) |r| try instr_list.append(gpa, r.*);
        }
        std.mem.sort(Ref, instr_list.items, {}, comptime std.sort.asc(Ref));

        const owned = try instr_list.toOwnedSlice(gpa);
        const label = try std.fmt.allocPrint(gpa,
            "phi r{d} (%{d:0>3}) → no consumer in trace, not in entry slots",
            .{ slot, i });
        try list.append(gpa, .{ .waste = .dead_carry, .instrs = owned, .label = label });
    }
}

/// Returns true if every consumer of `instrs[idx]` is in `dead_set`.
fn allConsumersInSet(instrs: []const IrInstr, idx: usize, dead_set: *const std.AutoHashMapUnmanaged(Ref, void)) bool {
    var found_consumer = false;
    for (instrs, 0..) |ins, i| {
        const consumes = switch (ins.op) {
            .add, .sub, .mul, .div, .idiv, .mod, .pow,
            .band, .bor, .bxor, .shl, .shr, .sar,
            .eq, .ne, .lt, .le,
            => ins.a == idx or ins.b == idx,
            .neg, .not, .bnot,
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false,
            .aload,
            .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits,
            .guard_append,
            .int_of_float,
            .guard_func,
            .hload, .guard_hash,
            .guard_builtin, .fsqrt, .fsin, .fcos,
            .gload, .guard_grid, .guard_stride, .guard_gpresent,
            .alen,
            => ins.a == idx,
            .aref, .astore, .astore_append, .href, .hstore,
            .garow, .gcell, .gstore, .guard_gcol => ins.a == idx or ins.b == idx,
            .phi => (ins.aux == trace.PHI_INTERNAL and ins.a == idx) or ins.b == idx,
            // `.link` (doc 15) consumes no refs (`aux` is the inner anchor pc).
            .slot_load, .konst, .loop, .preheader, .link => false,
        };
        if (consumes) {
            found_consumer = true;
            if (!dead_set.contains(@intCast(i))) return false;
        }
    }
    return found_consumer;
}

// ---------------------------------------------------------------------------
// Duplicate-carry detector
// ---------------------------------------------------------------------------

/// Detect two (or more) slot-bound phis that flush the same update value to
/// different registers. Only one is needed; the rest are redundant.
fn detectDuplicateCarries(
    gpa: std.mem.Allocator,
    t: *const trace.Trace,
    list: *std.ArrayListUnmanaged(Finding),
) !void {
    // Map update ref → list of (phi_index, flush_slot).
    var by_update: std.AutoHashMapUnmanaged(Ref, std.ArrayListUnmanaged(struct { idx: Ref, slot: i32 })) = .empty;
    defer {
        var it = by_update.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        by_update.deinit(gpa);
    }

    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .phi or ins.aux < 0) continue; // slot-bound only
        const update: Ref = ins.b;
        const gop = try by_update.getOrPut(gpa, update);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{ .idx = @intCast(i), .slot = ins.aux });
    }

    var it = by_update.iterator();
    while (it.next()) |entry| {
        const update = entry.key_ptr.*;
        const group = entry.value_ptr.items;
        if (group.len < 2) continue;

        // All but the first are redundant. (The first is arbitrary; any one
        // suffices — the rest duplicate the same writeback.)
        for (group[1..]) |dup| {
            const first = group[0];
            const owned = try gpa.dupe(Ref, &.{ first.idx, dup.idx });
            const label = try std.fmt.allocPrint(gpa,
                "phi r{d} (%{d:0>3}) and phi r{d} (%{d:0>3}) share update %{d}",
                .{ first.slot, first.idx, dup.slot, dup.idx, update });
            try list.append(gpa, .{ .waste = .duplicate_carry, .instrs = owned, .label = label });
        }
    }
}

// ---------------------------------------------------------------------------
// Unhoisted-invariant detector
// ---------------------------------------------------------------------------

/// Detect pure binary/unary instructions whose operands are all loop-invariant
/// but which sit in the loop body (after the preheader marker, or in a trace
/// with no preheader). The LICM pass should normally hoist these; their presence
/// signals either a genuine hoisting gap or a deliberately pinned op (idiv/mod).
fn detectUnhoistedInvariants(
    gpa: std.mem.Allocator,
    t: *const trace.Trace,
    list: *std.ArrayListUnmanaged(Finding),
) !void {
    const n = t.instrs.len;
    if (n == 0) return;

    // --- find the preheader marker (if any) ---
    const body_start: usize = blk: {
        for (t.instrs, 0..) |ins, i| {
            if (ins.op == .preheader) break :blk i + 1;
        }
        break :blk 0; // no preheader → entire trace is body
    };

    if (body_start >= n) return; // preheader is the last instr → no body

    // --- find carried slots (slots with a slot-bound phi) ---
    var carried_slots: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer carried_slots.deinit(gpa);
    for (t.instrs) |ins| {
        if (ins.op == .phi and ins.aux >= 0) try carried_slots.put(gpa, ins.aux, {});
    }

    // --- classify each instruction as invariant ---
    const inv = try gpa.alloc(bool, n);
    defer gpa.free(inv);
    @memset(inv, false);

    // Forward scan: an instruction is invariant iff it is a konst, an
    // invariant slot_load, or a pure binary/unary over invariant operands.
    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .konst => inv[i] = true,
            .slot_load => inv[i] = !carried_slots.contains(ins.aux),
            .add, .sub, .mul, .div, .idiv, .mod, .pow,
            .band, .bor, .bxor, .shl, .shr, .sar,
            => inv[i] = inv[ins.a] and inv[ins.b],
            .neg, .not, .bnot => inv[i] = inv[ins.a],
            else => {}, // guards, memory, phi, loop, preheader: never invariant
        }
    }

    // --- flag unhoisted invariants in the body ---
    // Only flag *computed* ops (binary/unary) — konst and slot_load are
    // "already hoisted" by being single instructions. Skip idiv/mod (they're
    // deliberately pinned: hoisting could change the error side-exit point).
    for (t.instrs, 0..) |ins, i| {
        if (i < body_start) continue; // already in preheader
        if (!inv[i]) continue;

        switch (ins.op) {
            .add, .sub, .mul, .div, .pow,
            .band, .bor, .bxor, .shl, .shr, .sar,
            .neg, .not, .bnot,
            => {
                const owned = try gpa.dupe(Ref, &.{@intCast(i)});
                const label = try std.fmt.allocPrint(gpa,
                    "{s} %{d} (%{d:0>3}) — all operands invariant, in body",
                    .{ @tagName(ins.op), i, i });
                try list.append(gpa, .{ .waste = .unhoisted_invariant, .instrs = owned, .label = label });
            },
            .idiv, .mod => {
                // Pinned: these can error, so they must stay in the body. Still
                // worth flagging as "could be hoisted if proven non-zero."
                const owned = try gpa.dupe(Ref, &.{@intCast(i)});
                const label = try std.fmt.allocPrint(gpa,
                    "{s} %{d} (%{d:0>3}) — invariant operands, but pinned (may error)",
                    .{ @tagName(ins.op), i, i });
                try list.append(gpa, .{ .waste = .unhoisted_invariant, .instrs = owned, .label = label });
            },
            else => {}, // konst, slot_load: not worth flagging (already cheap)
        }
    }
}

// ---------------------------------------------------------------------------
// Redundant-guard detector
// ---------------------------------------------------------------------------

/// Detect two guards with the same opcode and operand. The earlier guard
/// dominates the later one, making the later re-check redundant. Post-optimizer
/// this should be rare (the optimizer deduplicates exact-match guards), so
/// finding one is a strong signal that something escaped dedup.
fn detectRedundantGuards(
    gpa: std.mem.Allocator,
    t: *const trace.Trace,
    list: *std.ArrayListUnmanaged(Finding),
) !void {
    const n = t.instrs.len;
    if (n == 0) return;

    // Map (op, operand) → first guard index.
    const GuardKey = struct { op: IrOp, a: Ref };
    var seen: std.AutoHashMapUnmanaged(GuardKey, Ref) = .empty;
    defer seen.deinit(gpa);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false,
            .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits,
            => {
                const key = GuardKey{ .op = ins.op, .a = ins.a };
                const gop = try seen.getOrPut(gpa, key);
                if (gop.found_existing) {
                    const first: Ref = gop.value_ptr.*;
                    const owned = try gpa.dupe(Ref, &.{ first, @intCast(i) });
                    const label = try std.fmt.allocPrint(gpa,
                        "{s} %{d} (%{d:0>3}) duplicates %{d} (%{d:0>3})",
                        .{ @tagName(ins.op), i, i, first, first });
                    try list.append(gpa, .{ .waste = .redundant_guard, .instrs = owned, .label = label });
                } else {
                    gop.value_ptr.* = @intCast(i);
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Ref-range formatting
// ---------------------------------------------------------------------------

/// Write a sorted list of refs as compact ranges to `w`. Consecutive indices
/// are collapsed (e.g. `%030-%033`), singletons and non-consecutive indices are
/// separated by `, `.
fn writeRefRanges(w: *io.Writer, refs: []const Ref) !void {
    if (refs.len == 0) return;
    var start: usize = 0;
    while (start < refs.len) {
        if (start > 0) try w.writeAll(", ");
        var end = start;
        while (end + 1 < refs.len and refs[end + 1] == refs[end] + 1) end += 1;
        if (end == start) {
            try w.print("%{d}", .{refs[start]});
        } else {
            try w.print("%{d}-%{d}", .{ refs[start], refs[end] });
        }
        start = end + 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "troptdiag: dead carry — a phi with no slot_load and not in entry_slots is flagged" {
    const gpa = testing.allocator;

    // Build a trace with a dead phi at r4: phi{update=%5 -> r4} but no slot_load r4
    // and r4 not in entry_slots.
    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0 (carried, useful)
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1 (invariant)
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = r0 + r1  (feeds BOTH phis)
        .{ .op = .loop }, // %3
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 2 }, // r0 ← %2 (useful)
        .{ .slot = 4, .ref = 2 }, // r4 ← %2 (DEAD — no slot_load r4, not in entry_slots)
    });
    var entry = [_]u16{0}; // only r0 is live-in
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    // Should find exactly one dead_carry.
    var n_dead: usize = 0;
    for (findings) |f| {
        if (f.waste == .dead_carry) n_dead += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_dead);

    // The dead phi should be the one flushing to r4.
    const dead = for (findings) |f| {
        if (f.waste == .dead_carry) break f;
    } else unreachable;
    try testing.expect(dead.instrs.len >= 1);
    // withPhis: body has 4 instrs (%0-%3), then phis at %4 (r0), %5 (r4), loop at %6.
    // Wait — withPhis places phis at last(3)+0, last(3)+1, loop at last(3)+2.
    // So: %0=slot_load r0, %1=slot_load r1, %2=add, %3=phi r0, %4=phi r4, %5=loop.
    // The dead phi (r4) is at index 4.
    var found_phi4 = false;
    for (dead.instrs) |r| {
        if (r == 4) found_phi4 = true;
    }
    try testing.expect(found_phi4);
}

test "troptdiag: dead carry — exclusive dependency chain is included" {
    const gpa = testing.allocator;

    // A trace where a dead phi's update is computed by an add that feeds ONLY
    // the dead phi. That add should be in the waste range too.
    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0 (useful)
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1
        .{ .op = .konst, .aux = 0, .ty = .int }, // %2 = 1 (feeds dead-only add)
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %3 = r0 + r1 (useful)
        .{ .op = .add, .a = 2, .b = 0, .ty = .int }, // %4 = 1 + r0 (feeds ONLY dead phi)
        .{ .op = .loop }, // %5
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 3 }, // r0 ← %3 (useful)
        .{ .slot = 4, .ref = 4 }, // r4 ← %4 (DEAD)
    });
    var entry = [_]u16{0};
    var consts = [_]value.Value{value.Value.int(1)};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    var n_dead: usize = 0;
    for (findings) |f| {
        if (f.waste == .dead_carry) n_dead += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_dead);

    const dead = for (findings) |f| {
        if (f.waste == .dead_carry) break f;
    } else unreachable;

    // withPhis: body %0-%5 (6 instrs), then phis at %6 (r0→body[3]=%3), %7 (r4→body[4]=%4), loop at %8.
    // Actually: last=5, body[0..4]→out[0..4], out[5]=phi r0, out[6]=phi r4, out[7]=loop.
    // Dead phi at %6; its exclusive feed is body[4]=%4 (1+r0, used only by dead phi).
    // The konst %2 feeds %4 and nothing else → also exclusive.
    try testing.expect(dead.instrs.len >= 3); // phi %6, add %4, konst %2
    var found_phi6 = false;
    var found_add4 = false;
    var found_konst2 = false;
    for (dead.instrs) |r| {
        if (r == 6) found_phi6 = true;
        if (r == 4) found_add4 = true;
        if (r == 2) found_konst2 = true;
    }
    try testing.expect(found_phi6);
    try testing.expect(found_add4);
    try testing.expect(found_konst2);
}

test "troptdiag: live carry — a phi whose slot is read is NOT flagged" {
    const gpa = testing.allocator;

    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0 (carried, read by the add)
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = r0 + r1
        .{ .op = .loop }, // %3
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 2 }, // r0 ← %2
        .{ .slot = 1, .ref = 1 }, // r1 ← %1 (slot_load r1 exists, so this is live)
    });
    var entry = [_]u16{0};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    // No dead carries: r4 has no phi at all, r0 is read, r1 is read.
    for (findings) |f| {
        try testing.expect(f.waste != .dead_carry);
    }
}

test "troptdiag: live carry — a phi whose slot is in entry_slots is NOT flagged" {
    const gpa = testing.allocator;

    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0
        .{ .op = .konst, .aux = 0, .ty = .int }, // %1 = 1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = r0 + 1
        .{ .op = .loop }, // %3
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 2 }, // r0 ← %2
        .{ .slot = 4, .ref = 2 }, // r4 ← %2 (no slot_load r4, BUT r4 in entry_slots)
    });
    var entry = [_]u16{ 0, 4 }; // r4 is live-in at the anchor → NOT dead
    var consts = [_]value.Value{value.Value.int(1)};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    for (findings) |f| {
        try testing.expect(f.waste != .dead_carry);
    }
}

test "troptdiag: duplicate carry — two phis sharing an update are flagged" {
    const gpa = testing.allocator;

    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = r0 + r1
        .{ .op = .loop }, // %3
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 2 }, // r0 ← %2
        .{ .slot = 8, .ref = 2 }, // r8 ← %2 — duplicate! same update as r0's phi
    });
    var entry = [_]u16{0};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    var n_dup: usize = 0;
    for (findings) |f| {
        if (f.waste == .duplicate_carry) n_dup += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_dup);

    const dup = for (findings) |f| {
        if (f.waste == .duplicate_carry) break f;
    } else unreachable;
    // Should list both phi indices.
    try testing.expectEqual(@as(usize, 2), dup.instrs.len);
    // withPhis: body %0-%3, phis at %4 (r0←%2), %5 (r8←%2), loop at %6.
    // Actually: last=3, body[0..2]→out[0..2], out[3]=phi r0, out[4]=phi r8, out[5]=loop.
    try testing.expectEqual(@as(Ref, 3), dup.instrs[0]);
    try testing.expectEqual(@as(Ref, 4), dup.instrs[1]);
}

test "troptdiag: no waste on a clean trace" {
    const gpa = testing.allocator;

    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = r0 + r1
        .{ .op = .loop }, // %3
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 2 }, // r0 ← %2
    });
    var entry = [_]u16{0};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "troptdiag: unhoisted invariant — a pure op over invariants in the body is flagged" {
    const gpa = testing.allocator;

    // Build a trace WITHOUT a preheader marker (raw recorder output).
    // r0 is carried, r1 is invariant. mul r0,r1 is in the body and variant.
    // add konst,konst is invariant and in the body → unhoisted.
    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0 (carried)
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1 (invariant: not carried)
        .{ .op = .konst, .aux = 0, .ty = .int }, // %2 = 2
        .{ .op = .konst, .aux = 1, .ty = .int }, // %3 = 3
        .{ .op = .mul, .a = 0, .b = 1, .ty = .int }, // %4 = r0*r1 (variant: r0 is carried)
        .{ .op = .add, .a = 2, .b = 3, .ty = .int }, // %5 = 2+3 (invariant! both konsts)
        .{ .op = .loop }, // %6
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 4 }, // r0 ← %4
    });
    var entry = [_]u16{0};
    var consts = [_]value.Value{ value.Value.int(2), value.Value.int(3) };
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    // Should find exactly one unhoisted_invariant: the add %5 (2+3).
    var n: usize = 0;
    for (findings) |f| {
        if (f.waste == .unhoisted_invariant) n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);

    const f = for (findings) |ff| {
        if (ff.waste == .unhoisted_invariant) break ff;
    } else unreachable;
    // withPhis: last=6, body[0..5]→out[0..5], out[6]=phi r0, out[7]=loop.
    // add is at body index 5 → out index 5 (before the phi).
    try testing.expectEqual(@as(usize, 1), f.instrs.len);
    try testing.expectEqual(@as(Ref, 5), f.instrs[0]);
}

test "troptdiag: unhoisted invariant — idiv/mod over invariants is flagged as pinned" {
    const gpa = testing.allocator;

    // idiv of two invariant values — it's invariant but pinned (may error).
    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0 (carried)
        .{ .op = .konst, .aux = 0, .ty = .int }, // %1 = 10
        .{ .op = .konst, .aux = 1, .ty = .int }, // %2 = 2
        .{ .op = .idiv, .a = 1, .b = 2, .ty = .int }, // %3 = 10//2 (invariant but pinned)
        .{ .op = .add, .a = 0, .b = 3, .ty = .int }, // %4 = r0 + %3
        .{ .op = .loop }, // %5
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 4 }, // r0 ← %4
    });
    var entry = [_]u16{0};
    var consts = [_]value.Value{ value.Value.int(10), value.Value.int(2) };
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    var n: usize = 0;
    for (findings) |f| {
        if (f.waste == .unhoisted_invariant) n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);

    const f = for (findings) |ff| {
        if (ff.waste == .unhoisted_invariant) break ff;
    } else unreachable;
    // withPhis: last=5, body[0..4]→out[0..4], out[5]=phi r0, out[6]=loop.
    // idiv is at body index 3 → out index 3.
    try testing.expectEqual(@as(Ref, 3), f.instrs[0]);
    try testing.expect(std.mem.indexOf(u8, f.label, "pinned") != null);
}

test "troptdiag: unhoisted invariant — a preheader-marker trace has no unhoisted invariants" {
    const gpa = testing.allocator;

    // Simulate a post-LICM trace: invariant ops are before the preheader marker.
    var instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 1, .ty = .int }, // %0 = r1 (invariant: not carried)
        .{ .op = .konst, .aux = 0, .ty = .int }, // %1 = 2
        .{ .op = .add, .a = 0, .b = 1, .ty = .int }, // %2 = r1+2 (invariant, HOISTED)
        .{ .op = .preheader }, // %3 — marker
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %4 = r0 (carried)
        .{ .op = .add, .a = 2, .b = 4, .ty = .int }, // %5 = (r1+2) + r0 (body)
        .{ .op = .phi, .aux = 0, .b = 5, .ty = .int }, // %6 → r0
        .{ .op = .loop }, // %7
    };
    var entry = [_]u16{0};
    var consts = [_]value.Value{value.Value.int(2)};
    const t = trace.Trace{
        .anchor = .{ .proto = &bytecode.Proto{ .code = &.{}, .name = "t" }, .pc = 5 },
        .instrs = &instrs,
        .consts = &consts,
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    // No unhoisted invariants: the invariant add %2 is before the preheader marker.
    for (findings) |f| {
        try testing.expect(f.waste != .unhoisted_invariant);
    }
}

test "troptdiag: redundant guard — a duplicate type guard on the same operand is flagged" {
    const gpa = testing.allocator;

    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0
        .{ .op = .guard_int, .a = 0 }, // %1 — first guard on r0
        .{ .op = .add, .a = 0, .b = 0, .ty = .int }, // %2 = r0+r0
        .{ .op = .guard_int, .a = 0 }, // %3 — DUPLICATE guard on r0
        .{ .op = .loop }, // %4
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 2 }, // r0 ← %2
    });
    var entry = [_]u16{0};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    var n: usize = 0;
    for (findings) |f| {
        if (f.waste == .redundant_guard) n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);

    const f = for (findings) |ff| {
        if (ff.waste == .redundant_guard) break ff;
    } else unreachable;
    try testing.expectEqual(@as(usize, 2), f.instrs.len);
    // withPhis: last=4, body[0..3]→out[0..3], out[4]=phi r0, out[5]=loop.
    // guard_int is at body indices 1 and 3 → out indices 1 and 3.
    try testing.expectEqual(@as(Ref, 1), f.instrs[0]);
    try testing.expectEqual(@as(Ref, 3), f.instrs[1]);
}

test "troptdiag: redundant guard — different opcodes on the same operand are NOT flagged" {
    const gpa = testing.allocator;

    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    var instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0
        .{ .op = .guard_int, .a = 0 }, // %1 — guard_int on r0
        .{ .op = .guard_true, .a = 0 }, // %2 — guard_true on r0 (different op, NOT duplicate)
        .{ .op = .loop }, // %3
    }, &[_]trace.SlotStore{
        .{ .slot = 0, .ref = 0 }, // r0 ← %0
    });
    var entry = [_]u16{0};
    const t = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry, .entry_guards = &.{},
    };

    const findings = try analyze(gpa, &t);
    defer deinitFindings(gpa, findings);

    for (findings) |f| {
        try testing.expect(f.waste != .redundant_guard);
    }
}

test "troptdiag: writeFindings renders waste to a writer" {
    const gpa = testing.allocator;

    const findings = [_]Finding{
        .{
            .waste = .dead_carry,
            .instrs = try gpa.dupe(Ref, &.{ 30, 31, 32, 33 }),
            .label = try gpa.dupe(u8, "phi r4 (%033) → no consumer in trace, not in entry slots"),
        },
        .{
            .waste = .duplicate_carry,
            .instrs = try gpa.dupe(Ref, &.{ 28, 31 }),
            .label = try gpa.dupe(u8, "phi r3 (%028) and phi r8 (%031) share update %022"),
        },
    };
    defer for (findings) |f| {
        gpa.free(f.instrs);
        gpa.free(f.label);
    };

    var buf: [1024]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    // writeFindings needs a Trace for context; only the proto name matters for the
    // header (we're not printing the header here — just the findings body).
    const proto = bytecode.Proto{ .code = &.{}, .name = "t" };
    const dummy_trace = trace.Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    try writeFindings(&w, &dummy_trace, &findings);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "dead_carry") != null);
    try testing.expect(std.mem.indexOf(u8, text, "%30-%33") != null);
    try testing.expect(std.mem.indexOf(u8, text, "duplicate_carry") != null);
    try testing.expect(std.mem.indexOf(u8, text, "%28, %31") != null);
    try testing.expect(std.mem.indexOf(u8, text, "4 instr(s)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 instr(s)") != null);
}

test "troptdiag: writeRefRanges collapses consecutive and separates non-consecutive" {
    var buf: [256]u8 = undefined;
    var w = io.Writer.fixed(&buf);

    // Mixed: consecutive run, gap, singleton, consecutive pair.
    try writeRefRanges(&w, &.{ 2, 3, 4, 7, 9, 10 });
    try testing.expectEqualStrings("%2-%4, %7, %9-%10", w.buffered());

    // Single element.
    var buf2: [32]u8 = undefined;
    var w2 = io.Writer.fixed(&buf2);
    try writeRefRanges(&w2, &.{5});
    try testing.expectEqualStrings("%5", w2.buffered());

    // Empty.
    var buf3: [32]u8 = undefined;
    var w3 = io.Writer.fixed(&buf3);
    try writeRefRanges(&w3, &.{});
    try testing.expectEqualStrings("", w3.buffered());
}
