//! Doc 67 §4.1/§5.2: the slab at a native page's boundaries, described once.
//!
//! The prologue's slab checks and the slab writes of every exit that can
//! jump into another page are listed here. The emitters iterate these
//! descriptions to produce code, and the fact builders
//! (`nativegen_factbuild.zig`) iterate the same descriptions to say what the
//! slab holds. So a page's claims about the slab cannot drift from what its
//! code checks and writes.

const std = @import("std");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const artifact = @import("nativegen_artifact.zig");
const layout = @import("nativegen_layout.zig");
const ngalloc = @import("nativegen_alloc.zig");
const facts = @import("nativegen_facts.zig");

const Trace = trace_code.TraceCode;
const Kind = artifact.Kind;
const Alloc = ngalloc.Alloc;
const SlotInfo = ngalloc.SlotInfo;
const Place = ngalloc.Place;

/// The tag `emit.flushSlot` writes for a value of `kind`. `.boxed` has no
/// static tag: its writes copy a tag snapshotted at entry.
pub fn flushTag(kind: Kind) u8 {
    std.debug.assert(kind != .boxed);
    return switch (kind) {
        .nil => layout.TAG_NIL,
        .bool => layout.TAG_BOOL,
        .float => layout.TAG_FLOAT,
        // `.ptr` (invariant table), `.heap` (per-iteration table — a carried-heap
        // slot's current value or a write-only VALUE_LANE aload result),
        // `.func` (a guard_func-covered closure, flushed by a head trace's φ
        // writeback — doc 44) and `.native` (a guard_builtin-covered builtin,
        // flushed only by the precise snapshot flush) all hold a raw
        // *GcHeader payload and re-box as a heap ref.
        .ptr, .heap, .func, .native => layout.TAG_HEAP,
        else => layout.TAG_INT,
    };
}

/// [RV-1]: the tag the prologue checks for slot `s` before anything reads
/// the slab, or null when it checks none. A write-only slot is never read.
/// A boxed slot's tag is copied at its terminal, whatever it is. Doc 45 D6:
/// a snapshot-only dead-window load (`.none`) has no home, no type and no
/// prologue check — the body never reads it and the exit materializers skip
/// it (its slab slot stays current).
pub fn entryTag(s: SlotInfo) ?u8 {
    if (s.class == .write_only) return null;
    if (s.kind == .boxed or s.kind == .none) return null;
    return switch (s.kind) {
        .ptr, .func, .native => layout.TAG_HEAP, // all invariant heap pointers
        // A carried-heap slot enters holding a table (TAG_HEAP). Its table-type/
        // metatable facts are NOT hoisted here — the dynamic in-body guard_table
        // re-checks the CURRENT table every iteration (doc 22 §A.1).
        .heap => layout.TAG_HEAP,
        .float => layout.TAG_FLOAT,
        // Doc 57: a pinned bool/nil input.
        .bool => layout.TAG_BOOL,
        .nil => layout.TAG_NIL,
        else => layout.TAG_INT,
    };
}

/// Doc 57: the payload an INVARIANT pinned slot's prologue compares once
/// after its tag (the body pin then emits nothing), or null. `Value.boolean`
/// defines all 8 payload bytes as canonical 0/1, so the compare is exact. A
/// carried slot's pin stays a body compare (its value changes per
/// iteration).
pub fn entryPin(s: SlotInfo) ?bool {
    if (entryTag(s) == null) return null;
    if (s.class != .invariant) return null;
    return s.pin;
}

/// An operand of an entry-hoisted guard: a slab slot read at entry, or an
/// int constant.
pub const EntryOperand = union(enum) {
    slot: u16,
    int: i64,
};

/// A `for` guard the prologue checks (doc 67 §4.2, Q1): `op` is
/// `guard_step_up`, `guard_step_down` (operand `a`) or `guard_for_nov`
/// (bound `a`, step `b`).
pub const EntryGuard = struct {
    op: trace_ir.IrOp,
    a: EntryOperand,
    b: ?EntryOperand = null,
};

/// Doc 67 §4.2: whether guard `i` is checked once in the prologue instead of
/// in the body, and against what. It is when it is a step or overflow guard,
/// every operand is an int constant or the `slot_load` of an `.invariant`
/// slot the prologue tag-checks, and at least one operand is a slot. Such a
/// slot holds its entry value for the whole activation, so the prologue's
/// slab read and the body's home read see the same value. A computed operand
/// (an `int_of_float` limit, an internal φ) keeps the guard in the body, and
/// so does an all-constant guard, whose outcome no slab fact describes.
///
/// The one predicate for every consumer: entry facts, prologue emission,
/// body suppression and `opMayExitInBody`. They must agree, or a guard is
/// checked nowhere or a fact is claimed that nothing checked.
pub fn entryGuardHoisted(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, i: usize) ?EntryGuard {
    const ins = t.instrs[i];
    switch (ins.op) {
        .guard_step_up, .guard_step_down => {
            const a = entryOperand(t, kinds, alloc, ins.a) orelse return null;
            if (a != .slot) return null;
            return .{ .op = ins.op, .a = a };
        },
        .guard_for_nov => {
            const a = entryOperand(t, kinds, alloc, ins.a) orelse return null;
            const b = entryOperand(t, kinds, alloc, ins.b) orelse return null;
            if (a != .slot and b != .slot) return null;
            return .{ .op = ins.op, .a = a, .b = b };
        },
        else => return null,
    }
}

fn entryOperand(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, ref: trace_ir.Ref) ?EntryOperand {
    if (ref >= t.instrs.len) return null;
    const ins = t.instrs[ref];
    switch (ins.op) {
        .konst => {
            if (kinds[ref] != .int) return null;
            const v = t.consts[@intCast(ins.aux)];
            if (!v.isInt()) return null;
            return .{ .int = v.asInt() };
        },
        .slot_load => {
            const sid = alloc.slot_id_of_ref[ref];
            if (sid < 0) return null;
            const s = alloc.slots[@intCast(sid)];
            if (s.class != .invariant) return null;
            if (entryTag(s) == null) return null;
            if (kinds[ref] != .int and kinds[ref] != .float) return null;
            return .{ .slot = s.slot };
        },
        else => return null,
    }
}

/// One slab write an exit's materialization performs: slot `slot` gets the
/// value at `place`, tagged `flushTag(kind)`, or for `.boxed` the tag
/// snapshotted from the boxed source `ref`. `ref` is the IR value written,
/// or null for a carried slot's home.
pub const Write = struct {
    slot: u16,
    kind: Kind,
    place: Place,
    ref: ?u32,
};

/// The exit contracts that can jump into another page (doc 67 §5.2).
/// Defined with the fact tables, which are keyed by it.
pub const ExitShape = facts.ExitShape;

/// Call `sink.write(w)` for every slab write exit `exit_instr` of shape
/// `shape` performs, in emission order.
pub fn forEachExitWrite(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, shape: ExitShape, exit_instr: usize, sink: anytype) !void {
    switch (shape) {
        .carried => try carriedWrites(t, alloc, null, sink),
        .writeback => for (alloc.slots) |s| {
            if (s.store_ref < 0) continue;
            const ref: usize = @intCast(s.store_ref);
            try sink.write(.{ .slot = s.slot, .kind = kinds[ref], .place = ngalloc.placeOfRef(alloc, ref), .ref = @intCast(ref) });
        },
        .loop_done_linked => {
            const guard = t.instrs[exit_instr];
            const for_ins = t.anchor.proto.code[trace_ir.guardSourcePc(guard).?];
            const visible_var_slot: i32 = @as(i32, @intCast(for_ins.a)) + 3;
            for (t.instrs) |p| {
                if (p.op != .phi or p.aux == trace_ir.PHI_INTERNAL) continue;
                if (p.aux == visible_var_slot) continue;
                try sink.write(phiWrite(kinds, alloc, p));
            }
        },
        .region_bridge => {
            try carriedWrites(t, alloc, exit_instr, sink);
            var emitted = t.bridgeEmissions(exit_instr);
            while (emitted.next()) |p| try sink.write(phiWrite(kinds, alloc, p));
        },
    }
}

fn phiWrite(kinds: []const Kind, alloc: *const Alloc, p: trace_ir.IrInstr) Write {
    const ref: usize = @intCast(p.b);
    return .{ .slot = @intCast(p.aux), .kind = kinds[ref], .place = ngalloc.placeOfRef(alloc, ref), .ref = @intCast(ref) };
}

/// The carried-home write-back a coarse exit owes the slab. A `.loop` trace
/// keeps each carried slot in its home across local iterations, so until an
/// exit re-boxes it the slab still holds the trace-entry value. `bridge_exit`
/// names an armed composite bridge's guard: the slots its set E commits are
/// skipped, since E overwrites them anyway.
fn carriedWrites(t: *const Trace, alloc: *const Alloc, bridge_exit: ?usize, sink: anytype) !void {
    for (alloc.slots) |s| {
        if (s.class != .carried) continue;
        // Boxed pass-through traces are one-shot. Before their terminal commit the
        // VM slot is still the entry Value byte-for-byte, so a guard exit must not
        // flush a typed approximation (or write anything at all).
        if (s.kind == .boxed) continue;
        if (bridge_exit) |ei| if (t.bridgeEmitsSlot(ei, s.slot)) continue;
        // Doc 39: a steady-φ slot re-boxes from the internal φ's computed home with
        // the STEADY kind — the entry home is stale after the run-once region.
        if (s.steady_phi >= 0) {
            try sink.write(.{ .slot = s.slot, .kind = s.steady_kind, .place = ngalloc.placeOfRef(alloc, @intCast(s.steady_phi)), .ref = @intCast(s.steady_phi) });
        } else {
            try sink.write(.{ .slot = s.slot, .kind = s.kind, .place = ngalloc.slotHomePlace(s), .ref = null });
        }
    }
}
