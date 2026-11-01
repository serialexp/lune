//! Doc 56 §4.2 (Phase 1): builds the native EXIT LOCATION MAP
//! (`nativegen_artifact.ExitLocMap`) from the register allocator's output.
//!
//! Pure data extraction. It runs after `analyze`, reads `Alloc` and the
//! proved kinds, and changes nothing the emitter sees, so the compiled code
//! is byte-identical with or without it. What a later exit adapter needs
//! (§4.6), per exit:
//!   1. every value the exit's snapshot restores;
//!   2. every value a sunk store below it reads, through its address token
//!      (`aref`/`href`/`garow`/`gcell`) down to the table, index and value;
//!   3. every carried slot's machine home (the slab is stale for those).
//! The map keeps one row per distinct value; an exit's own view comes from
//! its snapshot plus `ExitLoc.holdsAt`.

const std = @import("std");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const artifact = @import("nativegen_artifact.zig");
const ngalloc = @import("nativegen_alloc.zig");

const Trace = trace_code.TraceCode;
const Kind = artifact.Kind;
const Alloc = ngalloc.Alloc;
const Loc = ngalloc.Loc;
const SlotInfo = ngalloc.SlotInfo;
const ExitLoc = artifact.ExitLoc;
const ExitLocMap = artifact.ExitLocMap;
const CarriedHome = artifact.CarriedHome;

/// Build the map for a compiled ordinary trace. Returns an empty map when
/// there is nothing to describe (precise or peeled traces, which have no
/// exit snapshots by construction, or a trace whose snapshots all went
/// away). Errors only on allocation failure; the caller treats that as
/// "no map" (fail-soft, like the snapshots themselves).
pub fn build(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, alloc: *const Alloc) std.mem.Allocator.Error!ExitLocMap {
    const n = t.instrs.len;
    if (t.deopt_mode == .precise or t.peeled) return .{};
    // `compileImpl` refuses longer bodies; the map stores refs as u16 and
    // keeps `LIVE_WHOLE_BODY` (maxInt) above every real index.
    if (t.exit_snapshots.len == 0 or n == 0 or n >= ExitLoc.LIVE_WHOLE_BODY) return .{};
    std.debug.assert(kinds.len == n and alloc.loc.len == n and alloc.last_use.len == n);

    const fe = ngalloc.firstExit(t) orelse return .{};

    const needed = try gpa.alloc(bool, n);
    defer gpa.free(needed);
    @memset(needed, false);

    // (1) Snapshot refs, and (2) what the sunk stores below the first exit
    // read: the same set the allocator gives shadow cells (`AbiEvict`).
    ngalloc.markExitReads(t, fe, needed);

    // (3) Carried homes: exactly the slots the ordinary deopt flush writes
    // back (`lower`'s `deopt_exit`).
    // A `for` alias is flushed from its index's home.
    var n_carried: usize = 0;
    for (alloc.slots) |s| {
        if (flushedCarried(flushSource(alloc, s), n)) n_carried += 1;
    }
    const carried: []CarriedHome = if (n_carried == 0) &.{} else try gpa.alloc(CarriedHome, n_carried);
    errdefer if (carried.len != 0) gpa.free(carried);
    var ci: usize = 0;
    for (alloc.slots) |s| {
        const src = flushSource(alloc, s);
        if (!flushedCarried(src, n)) continue;
        const lr: usize = @intCast(src.load_ref);
        carried[ci] = .{ .slot = s.slot, .ref = @intCast(lr), .kind = src.kind };
        needed[lr] = true;
        ci += 1;
    }

    var n_values: usize = 0;
    for (needed) |b| n_values += @intFromBool(b);
    const values: []ExitLoc = if (n_values == 0) &.{} else try gpa.alloc(ExitLoc, n_values);
    var vi: usize = 0;
    for (needed, 0..) |b, r| {
        if (!b) continue;
        values[vi] = row(t, kinds, alloc, r);
        vi += 1;
    }
    return .{ .values = values, .carried = carried, .frame_words = frameWords(kinds, alloc) };
}

/// The body's frame in spill words: the allocator's cells plus one
/// boxed-tag cell per `.boxed` value (`boxedTagSpill` numbers them past
/// `spill_count`).
fn frameWords(kinds: []const Kind, alloc: *const Alloc) u32 {
    var boxed: u32 = 0;
    for (kinds) |k| boxed += @intFromBool(k == .boxed);
    return alloc.spill_count + boxed;
}

/// The slot whose home an exit flushes into `s`: its `for` index for an
/// alias (`SlotClass.alias`), else itself.
fn flushSource(alloc: *const Alloc, s: SlotInfo) SlotInfo {
    return if (s.class == .alias) alloc.slots[@intCast(s.alias_of)] else s;
}

fn flushedCarried(s: SlotInfo, n: usize) bool {
    if (s.class != .carried) return false;
    // Mirrors `deopt_exit`: boxed pass-through slots are never flushed, and
    // a steady-φ slot (peeled only) flushes from another place entirely.
    if (s.kind == .boxed or s.kind == .none or s.steady_phi >= 0) return false;
    return s.load_ref >= 0 and @as(usize, @intCast(s.load_ref)) < n;
}

fn row(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, ref: usize) ExitLoc {
    const ins = t.instrs[ref];
    const k = kinds[ref];
    var out: ExitLoc = .{
        .ref = @intCast(ref),
        .live_from = @intCast(ref + 1),
        .live_until = ExitLoc.LIVE_WHOLE_BODY,
        .kind = k,
        .tag = .none,
        .ir_kind = k,
    };
    if (ins.op == .konst) {
        // Rebuilt from the constant table, whatever the body did with it
        // (a snapshot-only konst has kind `.none` and no code at all).
        const ci = std.math.cast(u32, ins.aux) orelse return out;
        if (ci >= t.consts.len) return out;
        out.tag = .konst;
        out.payload = ci;
        return out;
    }
    if (k == .none) {
        // A dead (`.none`) load has no place. An adapter restoring its OWN
        // slot from it still needs to know when that is free: an invariant
        // slot's slab is current (a carried one is written by its home's
        // flush, which `carried` already lists).
        if (ins.op == .slot_load) {
            const sid = alloc.slot_id_of_ref[ref];
            if (sid >= 0) {
                const s = alloc.slots[@intCast(sid)];
                if (s.class == .invariant) out.invariant_slot = s.slot;
            }
        }
        return out;
    }
    if (ins.op == .slot_load) {
        const sid = alloc.slot_id_of_ref[ref];
        if (sid < 0) return out;
        const s = alloc.slots[@intCast(sid)];
        if (s.class.homeless() or s.kind == .none) return out;
        // Doc 57: a home-less pinned slot has no place. Its slab is current
        // (invariant), so an adapter restoring its OWN slot may skip it; any
        // other consumer finds no place and fails closed.
        if (s.pin_only) {
            out.invariant_slot = s.slot;
            return out;
        }
        // A slot home is pinned for the whole body. The one exception is a
        // win-2 in-place update, which the allocator only allows after the
        // last body exit; the home stops holding the entry value there.
        setPlace(&out, s.home);
        // The prologue loads the home, so it holds the iteration-entry
        // value before the `slot_load`'s IR position too (an exit above it
        // still sees — and a carried flush still writes — that value).
        out.live_from = 0;
        // The home is boxed with the SLOT's kind, which is what every flush
        // uses. It differs from the load's own kind for a carried-heap
        // table (`.ptr` load, `.heap` slot: the table changes per
        // iteration, TAG_HEAP either way).
        out.kind = s.kind;
        if (s.class == .invariant) out.invariant_slot = s.slot;
        if (s.coalesced and s.store_ref > 0) out.live_until = @intCast(s.store_ref - 1);
        return out;
    }
    // Any other non-transient value (a φ, …) has no place the map can name.
    if (!ngalloc.isTransient(ins.op)) return out;
    // Nor does a const-key aref: it is an immediate (`prove.arefConstIdx`).
    if (alloc.arefImm(ref) != null) return out;
    // An adapter runs after the exit stub's head, which saved a given-up
    // ABI register to its shadow (`Alloc.exitLoc`).
    setPlace(&out, alloc.exitLoc(alloc.loc[ref]));
    var until: usize = alloc.last_use[ref];
    // At its last use the value's register may be handed straight to the
    // reading instruction's result (win-1 operand reuse). An exit taken by
    // that instruction (e.g. `int_of_float`, `alen`) already sees the new
    // value there, so the old one is held only up to the instruction
    // before.
    if (until > ref and until < t.instrs.len) {
        const j = until;
        if (ngalloc.isTransient(t.instrs[j].op) and kinds[j] != .none and ngalloc.locEql(alloc.loc[j], alloc.loc[ref]))
            until = j - 1;
    }
    out.live_until = @intCast(until);
    return out;
}

fn setPlace(out: *ExitLoc, l: Loc) void {
    switch (l) {
        .reg => |r| {
            // An exit reloads a given-up ABI register before anything
            // reads a value, so `row` maps it to its shadow first.
            std.debug.assert(ngalloc.regBit(r) & ngalloc.ABI_REG_MASK == 0);
            out.tag = .reg;
            out.payload = @intFromEnum(r);
        },
        .xmm => |r| {
            out.tag = .xmm;
            out.payload = @intFromEnum(r);
        },
        .spill => |idx| {
            out.tag = .spill;
            out.payload = idx * 8;
        },
        .slab => |slot| {
            out.tag = .slab;
            out.payload = slot;
        },
        // No snapshot names a flags compare (`isFlagsCompare`), and a
        // konst's row is `.konst` before it gets here.
        .flags, .imm => unreachable,
    }
}
