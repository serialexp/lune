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

    var first_exit: ?usize = null;
    for (0..n) |i| {
        if (t.exitSnapIdx(i) != null) {
            first_exit = i;
            break;
        }
    }
    const fe = first_exit orelse return .{};

    const needed = try gpa.alloc(bool, n);
    defer gpa.free(needed);
    @memset(needed, false);

    // (1) Snapshot refs. The store holds only snapshots some body exit
    // uses (`tropt` zeroes the rest and finalize compacts them away).
    for (t.exit_snapshot_slots) |ss| {
        if (ss.ref < n) needed[ss.ref] = true;
    }

    // (2) What the sunk stores below the first exit read. `finalize`
    // appends them after every guard, so any of them may belong to an
    // earlier bytecode than some exit above it.
    for (fe + 1..n) |i| {
        const ins = t.instrs[i];
        if (!isSunkStoreOp(ins.op)) continue;
        markStoreRead(t, needed, ins.a, i);
        markStoreRead(t, needed, ins.b, i);
    }

    // (3) Carried homes: exactly the slots the ordinary deopt flush writes
    // back (`lower`'s `deopt_exit`).
    var n_carried: usize = 0;
    for (alloc.slots) |s| {
        if (flushedCarried(s, n)) n_carried += 1;
    }
    const carried: []CarriedHome = if (n_carried == 0) &.{} else try gpa.alloc(CarriedHome, n_carried);
    errdefer if (carried.len != 0) gpa.free(carried);
    var ci: usize = 0;
    for (alloc.slots) |s| {
        if (!flushedCarried(s, n)) continue;
        const lr: usize = @intCast(s.load_ref);
        carried[ci] = .{ .slot = s.slot, .ref = @intCast(lr), .kind = s.kind };
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
    return .{ .values = values, .carried = carried };
}

/// The deferred store ops `finalize` sinks below every guard (the
/// `loopDoneSnapshotSupported` inventory plus `sgm_setpos`).
fn isSunkStoreOp(op: trace_ir.IrOp) bool {
    return switch (op) {
        .astore, .hstore, .ustore, .gstore, .sgm_setpos => true,
        else => false,
    };
}

/// Mark `ref`, read by instruction `reader`, and — when it is an address
/// token — what the store reaches through it: an `aref`'s table and index,
/// an `href`'s table root and key, a `gcell`'s row token and column, a
/// `garow`'s table and row. Refs strictly decrease, so this terminates; the
/// deepest real chain is `gstore → gcell → garow → table`.
fn markStoreRead(t: *const Trace, needed: []bool, ref: usize, reader: usize) void {
    if (ref >= reader) return;
    needed[ref] = true;
    const tok = t.instrs[ref];
    switch (tok.op) {
        .aref, .href, .garow, .gcell => {
            markStoreRead(t, needed, tok.a, ref);
            markStoreRead(t, needed, tok.b, ref);
        },
        else => {},
    }
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
    var out: ExitLoc = .{ .ref = @intCast(ref), .live_until = ExitLoc.LIVE_WHOLE_BODY, .kind = k, .tag = .none };
    if (ins.op == .konst) {
        // Rebuilt from the constant table, whatever the body did with it
        // (a snapshot-only konst has kind `.none` and no code at all).
        const ci = std.math.cast(u32, ins.aux) orelse return out;
        if (ci >= t.consts.len) return out;
        out.tag = .konst;
        out.payload = ci;
        return out;
    }
    if (k == .none) return out;
    if (ins.op == .slot_load) {
        const sid = alloc.slot_id_of_ref[ref];
        if (sid < 0) return out;
        const s = alloc.slots[@intCast(sid)];
        if (s.class == .write_only or s.kind == .none) return out;
        // A slot home is pinned for the whole body. The one exception is a
        // win-2 in-place update, which the allocator only allows after the
        // last body exit; the home stops holding the entry value there.
        setPlace(&out, s.home);
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
    setPlace(&out, alloc.loc[ref]);
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
    }
}
