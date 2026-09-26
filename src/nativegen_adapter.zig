//! Doc 56 §4.6.1 (Phase 4): native EXIT ADAPTERS.
//!
//! An adapter is what a native attachable exit runs instead of the ordinary
//! anchor-coherent exit once it is wanted or attached: it makes the slab the
//! tier-0 state at the exit's resume pc `P` — exactly what tier-1a's
//! `irinterp.materializeExitSide` does — and leaves through the exit's
//! exit-side cell in the parent's `slots`. Built after the parent was
//! compiled, from the exit location map alone (the allocator's output is
//! gone by then), so it is never a recompile of the parent.
//!
//! The sequence, in the order tier-1a's materializer defines:
//!   1. every sunk store of an EARLIER bytecode (`appliesAtExit`), in stream
//!      order, through the body's own leaf emitters;
//!   2. every carried home (the slab is stale for those; the ordinary exit's
//!      `deopt_exit` writes the same homes);
//!   3. the exit snapshot's slots, overriding step 2;
//!   4. `completed`, reason `.exit_side`, an `.exit_side` ledger row, the
//!      final trace id, then `jmp` through the exit's exit-side cell in the
//!      parent's `slots`: the runtime while unarmed, the child's
//!      `ordinary_entry` once armed (Phase 5; a full ledger yields to the
//!      runtime instead, and a jump into a child resets `exit_reason`).
//!
//! The leaf emitters read a value's place through an `Alloc`. The adapter
//! builds a synthetic one: `loc` from the map rows; `slot_id_of_ref` all
//! `-1`, so array bases are reloaded from the table instead of a hoisted
//! base register (the same pointer during a native run, the B5 invariant);
//! and a `kinds` slice from the rows' `ir_kind`. A constant or a `uref` a
//! store reads is rebuilt into a spill cell above the parent's frame (the
//! constant pool; the seed slot the entry wrote, which nothing overwrites),
//! so every operand has an ordinary place.
//!
//! Register discipline: an adapter only writes rax, rcx, the XMM scratch
//! pair and memory. Every value place is an allocatable register or a spill
//! cell, so nothing it reads is clobbered before it is read.

const std = @import("std");
const x64 = @import("x64.zig");
const trace_code = @import("trace_code.zig");
const trace_exec = @import("trace_exec.zig");
const artifact = @import("nativegen_artifact.zig");
const ngalloc = @import("nativegen_alloc.zig");
const emit = @import("nativegen_emit.zig");
const mcode = @import("nativegen_mcode.zig");
const exit_attach = @import("trace_exit_attach.zig");

const Trace = trace_code.TraceCode;
const Kind = artifact.Kind;
const ExitLoc = artifact.ExitLoc;
const ExitLocMap = artifact.ExitLocMap;
const ExitAdapter = artifact.ExitAdapter;
const CompiledTrace = artifact.CompiledTrace;
const NativeResult = artifact.NativeResult;
const McodeArena = mcode.McodeArena;
const Loc = ngalloc.Loc;
const Alloc = ngalloc.Alloc;

/// Why an adapter was not built (the exit then keeps the ordinary exit).
/// Counted per reason in `--jit-stats`; tests pin each one.
pub const Refusal = enum(u8) {
    /// The page has no exit-side stub for this exit: compiled without the
    /// option, not frameless, or the exit is not attachable.
    no_stub,
    /// No exit snapshot, or an empty exit location map.
    no_map,
    /// A value the adapter reads is not held at the exit (its life ended
    /// before it, it is placed after it, or it has no place at all).
    not_held,
    /// A restored value of a kind no slot flush can box.
    kind,
    /// Staging the constants would pass the trampoline's `SPILL_MAX`.
    spill,
    /// Emitting or mapping the code failed (other than out of memory).
    emit,
    /// Allocation failed (reported by the caller: `build`/`publish` return
    /// `error.OutOfMemory` itself).
    out_of_memory,
};

/// A refusal and, when one value caused it, that value's IR ref (for the
/// `exit-adapter:` probe).
pub const Refused = struct {
    why: Refusal,
    ref: ?u32 = null,

    fn at(why: Refusal, ref: usize) Refused {
        return .{ .why = why, .ref = @intCast(ref) };
    }
};

pub const Built = union(enum) {
    adapter: ExitAdapter,
    refused: Refused,
};

/// Build the adapter of attachable exit `gi` of `t` (compiled as `trace_id`,
/// with exit location map `map`). `target` is the exit's exit-side cell in
/// the parent's `slots` (`CompiledTrace.exitSideSlot`): the adapter ends by
/// jumping through it. Errors only on allocation failure.
pub fn build(gpa: std.mem.Allocator, arena: *McodeArena, t: *const Trace, trace_id: u32, map: *const ExitLocMap, gi: usize, target: *const usize) std.mem.Allocator.Error!Built {
    if (comptime !mcode.is_x64_linux) return .{ .refused = .{ .why = .no_stub } };
    const si = t.exitSnapIdx(gi) orelse return .{ .refused = .{ .why = .no_map } };
    if (map.values.len == 0) return .{ .refused = .{ .why = .no_map } };
    const tr = arena.ensureTrampoline() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = .{ .why = .emit } },
    };

    var a = x64.Assembler.init(gpa);
    defer a.deinit();
    if (try emitAdapter(gpa, &a, t, trace_id, map, gi, si, target, tr.shared_exit)) |r| return .{ .refused = r };
    a.resolve();
    const page = arena.alloc(a.code.items) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = .{ .why = .emit } },
    };
    return .{ .adapter = .{ .exit = @intCast(gi), .page = page } };
}

/// Publish exit `gi`'s adapter in `ct`'s exit-side cell, building it the
/// first time. A page keeps its adapters until it dies, so re-publishing
/// after a clear reuses the one already built.
pub fn publish(arena: *McodeArena, t: *const Trace, trace_id: u32, ct: *CompiledTrace, gi: u32) std.mem.Allocator.Error!?Refused {
    if (gi >= ct.exit_side_cells.len or !t.exitAttachable(gi)) return .{ .why = .no_stub };
    const cell = ct.exitSideSlot(gi) orelse return .{ .why = .no_stub };
    if (ct.exitAdapter(gi)) |ad| {
        ct.exit_side_cells[gi] = @intFromPtr(ad.page.code.ptr);
        return null;
    }
    switch (try build(ct.gpa, arena, t, trace_id, &ct.exit_locs, gi, &ct.slots[cell])) {
        .refused => |r| return r,
        .adapter => |ad| {
            ct.exit_adapters.append(ct.gpa, ad) catch |e| {
                var owned = ad;
                owned.deinit();
                return e;
            };
            ct.exit_side_cells[gi] = @intFromPtr(ad.page.code.ptr);
            return null;
        },
    }
}

/// Send exit `gi` back to the ordinary exit (the adapter stays built).
pub fn unpublish(ct: *CompiledTrace, gi: u32) void {
    if (gi < ct.exit_side_cells.len) ct.exit_side_cells[gi] = 0;
}

/// Marks what the applied stores read (`exit_attach.forEachStoreRead`).
const NeedMarker = struct {
    needed: []bool,
    pub fn need(self: NeedMarker, ref: usize) void {
        self.needed[ref] = true;
    }
};

/// Emit the adapter body into `a`. Returns the refusal, or null when the
/// whole sequence was emitted.
fn emitAdapter(
    gpa: std.mem.Allocator,
    a: *x64.Assembler,
    t: *const Trace,
    trace_id: u32,
    map: *const ExitLocMap,
    gi: usize,
    si: usize,
    target: *const usize,
    shared_exit: usize,
) !?Refused {
    const n = t.instrs.len;
    const loc = try gpa.alloc(Loc, n);
    defer gpa.free(loc);
    for (loc) |*l| l.* = .{ .spill = 0 }; // never read: only placed refs are
    const kinds = try gpa.alloc(Kind, n);
    defer gpa.free(kinds);
    @memset(kinds, .none);
    const slot_id_of_ref = try gpa.alloc(i32, n);
    defer gpa.free(slot_id_of_ref);
    @memset(slot_id_of_ref, -1);
    const needed = try gpa.alloc(bool, n);
    defer gpa.free(needed);
    @memset(needed, false);
    const stores = try exit_attach.flushStoreIndices(gpa, t);
    defer gpa.free(stores);

    // Place every value the applied stores read. Constants and `uref`s are
    // staged into fresh cells above the frame first (rax only, before any
    // store runs).
    exit_attach.forEachStoreRead(t, gi, stores, NeedMarker{ .needed = needed });
    var next_spill: u32 = map.frame_words;
    for (needed, 0..) |want, ref| {
        if (!want) continue;
        const ins = t.instrs[ref];
        const row = map.find(ref);
        switch (ins.op) {
            .konst, .uref => {
                if (next_spill >= mcode.SPILL_MAX) return .at(.spill, ref);
                const disp: i32 = @as(i32, @intCast(next_spill)) * 8;
                if (ins.op == .konst) {
                    const bits = t.consts[@intCast(ins.aux)].payload.bits;
                    try a.movRegImm64(.rax, @bitCast(bits));
                } else {
                    try a.movRegMem(.rax, .rsi, @as(i32, @intCast(ins.aux)) * 8);
                }
                try a.movMemReg(.rsp, disp, .rax);
                loc[ref] = .{ .spill = next_spill };
                next_spill += 1;
                // A `uref` is a cell pointer, only ever a store's base (read
                // through `refBaseReg`, which ignores kinds); a constant keeps
                // the kind the body gave it, which the store emitters branch
                // on when it is the stored value.
                if (ins.op == .uref) {
                    kinds[ref] = .ptr;
                } else {
                    const r = row orelse return .at(.not_held, ref);
                    if (r.ir_kind == .none) return .at(.kind, ref);
                    kinds[ref] = r.ir_kind;
                }
            },
            else => {
                const r = map.at(ref, gi) orelse return .at(.not_held, ref);
                loc[ref] = placeOf(r) orelse return .at(.not_held, ref);
                kinds[ref] = r.ir_kind;
            },
        }
    }
    const alloc: Alloc = .{
        .loc = loc,
        .last_use = &.{},
        .slot_id_of_ref = slot_id_of_ref,
        .slots = &.{},
        .spill_count = next_spill,
        .used_callee_saved = 0,
    };

    // 1. The earlier bytecodes' sunk stores, in stream order.
    for (stores) |e32| {
        const e: usize = e32;
        if (!exit_attach.appliesAtExit(t, gi, e)) continue;
        const ins = t.instrs[e];
        switch (ins.op) {
            .astore => try emit.emitAStore(a, t, kinds, &alloc, ins),
            .hstore, .ustore => try emit.emitHStore(a, kinds, &alloc, ins),
            .gstore => try emit.emitGStore(a, t, &alloc, ins),
            else => unreachable, // `appliesAtExit` admits only the flush stores
        }
    }

    // 2. The carried homes (what `deopt_exit` writes).
    for (map.carried) |c| {
        const r = map.at(c.ref, gi) orelse return .at(.not_held, c.ref);
        const place = placeOf(r) orelse return .at(.not_held, c.ref);
        const k = flushKind(c.kind) orelse return .at(.kind, c.ref);
        try emit.flushSlot(a, @as(i32, c.slot), k, ngalloc.locToPlace(place));
    }

    // 3. The exit snapshot's slots, which override step 2.
    const s = t.exit_snapshots[si - 1];
    for (t.exit_snapshot_slots[s.slots_begin..][0..s.slots_len]) |ss| {
        const ref: usize = ss.ref;
        const rins = t.instrs[ref];
        if (rins.op == .konst) {
            // The compile-time Value, as the precise materializer writes it
            // (heap constants are trace-rooted and never move).
            const v = t.consts[@intCast(rins.aux)];
            try a.movByteMemImm(.rdi, @as(i32, ss.slot), @intFromEnum(v.tag));
            try a.movRegImm64(.rax, @bitCast(v.payload.bits));
            try a.movMemReg(.rsi, @as(i32, ss.slot) * 8, .rax);
            continue;
        }
        const r = map.find(ref) orelse return .at(.not_held, ref);
        // Restored from its own invariant load: nothing in the body writes
        // the slot, so the slab is current.
        if (r.invariant_slot == ss.slot) continue;
        if (r.tag == .none and rins.op == .slot_load and ownCarried(map, ss.slot, ref)) {
            // A dead load of a carried slot, restoring that slot: its value
            // is the home step 2 already wrote.
            continue;
        }
        if (!r.holdsAt(gi)) return .at(.not_held, ref);
        const place = placeOf(r) orelse return .at(.not_held, ref);
        const k = flushKind(r.kind) orelse return .at(.kind, ref);
        try emit.flushSlot(a, @as(i32, ss.slot), k, ngalloc.locToPlace(place));
    }

    // 4. The tail. `exit_instr` was written by the exit's own mini-stub.
    // The row reads its reason from `exit_reason`, so `.exit_side` is
    // written before the append.
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(trace_exec.ExitReason.exit_side));
    try emit.emitLedgerAppend(a, trace_id, .exit_side);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    // Doc 56 Phase 5: the exit-side cell holds `shared_exit` (unarmed) or
    // the armed child's `ordinary_entry`. A full ledger turns an armed jump
    // into a yield (row `.yielded`, rax = shared_exit), exactly like every
    // other chain source.
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(target))));
    try a.movRegMem(.rax, .rax, 0);
    try emit.emitForcedYieldCheck(a, shared_exit);
    // Into a child: its later rows and exits read `exit_reason`, which
    // every ordinary exit leaves at the wrapper's `.normal` — restore it.
    // The runtime path (unarmed or yield) keeps `.exit_side`.
    const out = try a.label();
    try a.movRegImm64(.rcx, @bitCast(@as(u64, shared_exit)));
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.e, out);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(trace_exec.ExitReason.normal));
    a.bind(out);
    try a.jmpReg(.rax);
    return null;
}

/// Whether `ref` is the entry load of carried slot `slot` (its home is
/// flushed in step 2).
fn ownCarried(map: *const ExitLocMap, slot: u16, ref: usize) bool {
    for (map.carried) |c| {
        if (c.slot == slot and c.ref == ref) return true;
    }
    return false;
}

fn placeOf(r: ExitLoc) ?Loc {
    return switch (r.tag) {
        .reg => .{ .reg = @enumFromInt(r.payload) },
        .xmm => .{ .xmm = @enumFromInt(r.payload) },
        .spill => .{ .spill = r.payload / 8 },
        .konst, .none => null,
    };
}

/// The kind a slot flush boxes a value with, or null when it cannot. The
/// precise materializer's set: `.native` is a raw `*GcHeader` like `.func`
/// and boxes as a heap ref.
fn flushKind(k: Kind) ?Kind {
    return switch (k) {
        .int, .bool, .float, .ptr, .heap, .func => k,
        .native => .heap,
        .none, .aref, .href, .boxed, .nil => null,
    };
}

test {
    _ = @import("nativegen_adapter_test.zig");
}
