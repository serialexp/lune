//! Doc 67 §4.1/§5: build a compiled page's fact tables from the slab
//! descriptions in `nativegen_boundary.zig`, while `kinds` and the
//! allocation are alive.
//!
//! The entry list is what the prologue checks: each [RV-1] tag, each
//! invariant pin, each entry-hoisted `for` guard. An armable exit's list is
//! the transfer of §5.1,
//!
//!     F(P, e) = gen(e) ∪ { f ∈ E(P) : no slot f mentions is in W(e) },
//!
//! where `W(e)` and `gen(e)` come from the exit's write list. That rests on
//! the invariant that a native body writes the slab only in exit
//! materialization, plus the `.loop` back-edge's commit of `write_only`
//! slots, about which no entry fact exists (asserted in `entryFacts`).
//!
//! Fail-closed: any overflow, a page over `BUDGET_BYTES`, or OOM yields no
//! tables, and a page without tables proves nothing.

const std = @import("std");
const value = @import("value.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const artifact = @import("nativegen_artifact.zig");
const ngalloc = @import("nativegen_alloc.zig");
const boundary = @import("nativegen_boundary.zig");
const facts = @import("nativegen_facts.zig");

const Trace = trace_code.TraceCode;
const Kind = artifact.Kind;
const Alloc = ngalloc.Alloc;
const Fact = facts.Fact;
const PageFacts = facts.PageFacts;
const ExitShape = facts.ExitShape;
const Value = value.Value;

/// Doc 67 §5.3: the most a page's tables may occupy.
pub const BUDGET_BYTES: usize = 64 * 1024;

pub const Error = error{ OutOfMemory, Overflow, OverBudget };

/// The page's tables, or null when building them failed (fail-closed).
pub fn build(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, alloc: *const Alloc) ?PageFacts {
    return buildChecked(gpa, t, kinds, alloc, BUDGET_BYTES) catch null;
}

/// `build` with the failure kept and the budget given, for tests.
pub fn buildChecked(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, budget: usize) Error!PageFacts {
    // Pass 1: the armable exits and an upper bound on the facts.
    var nexits: usize = 0;
    const entry_bound = try entryBound(t, kinds, alloc);
    var bound: usize = entry_bound;
    {
        var it = ExitIterator.init(t);
        while (it.next()) |x| {
            var counter: GenCounter = .{ .t = t };
            try boundary.forEachExitWrite(t, kinds, alloc, x.shape, x.exit_instr, &counter);
            bound = try std.math.add(usize, bound, try std.math.add(usize, entry_bound, counter.n));
            nexits += 1;
        }
    }
    const bytes = try std.math.add(usize, try std.math.mul(usize, bound, @sizeOf(Fact)), try std.math.mul(usize, nexits, @sizeOf(PageFacts.ExitRow)));
    if (bytes > budget) return error.OverBudget;
    // Every cursor below is a u32.
    if (bound > std.math.maxInt(u32)) return error.Overflow;

    // Pass 2: fill. Entry list first, then one list per exit.
    var buf = try gpa.alloc(Fact, bound);
    errdefer gpa.free(buf);
    const exits = try gpa.alloc(PageFacts.ExitRow, nexits);
    errdefer gpa.free(exits);

    const entry_len = entryFacts(t, kinds, alloc, buf[0..entry_bound]);
    const entry = buf[0..entry_len];
    var cursor: usize = entry_len;

    var writes: std.ArrayList(boundary.Write) = .empty;
    defer writes.deinit(gpa);
    var killed: std.ArrayList(u16) = .empty;
    defer killed.deinit(gpa);

    var it = ExitIterator.init(t);
    var xi: usize = 0;
    while (it.next()) |x| : (xi += 1) {
        writes.clearRetainingCapacity();
        try boundary.forEachExitWrite(t, kinds, alloc, x.shape, x.exit_instr, WriteCollector{ .gpa = gpa, .list = &writes });
        const start = cursor;
        cursor += try transfer(gpa, t, entry, writes.items, &killed, buf[cursor..]);
        const list = facts.canonicalize(buf[start..cursor]);
        cursor = start + list.len;
        exits[xi] = .{
            .shape = x.shape,
            .exit_instr = if (x.shape == .carried) PageFacts.CARRIED_EXIT else @intCast(x.exit_instr),
            .start = @intCast(start),
            .len = @intCast(list.len),
        };
    }
    std.debug.assert(xi == nexits);

    buf = try gpa.realloc(buf, cursor);
    return .{ .facts = buf, .entry_len = @intCast(entry_len), .exits = exits };
}

/// The armable exits, in `PageFacts.exits` order: the carried contract
/// once, the `.link` terminal, then the loop-done exits and bridge
/// candidates by instruction. Peeled pages skip their carried flush when no
/// local iteration completed, so its writes are not static. Precise pages
/// exit through their own materializers and are never chain sources. Both
/// get no exit lists (doc 67 §5.2).
const ExitIterator = struct {
    t: *const Trace,
    shape: ExitShape = .carried,
    i: usize = 0,
    none: bool,

    const Exit = struct { shape: ExitShape, exit_instr: usize };

    fn init(t: *const Trace) ExitIterator {
        return .{ .t = t, .none = t.peeled or t.deopt_mode == .precise or t.instrs.len == 0 };
    }

    fn next(self: *ExitIterator) ?Exit {
        if (self.none) return null;
        const t = self.t;
        const n = t.instrs.len;
        while (true) switch (self.shape) {
            .carried => {
                self.shape = .writeback;
                return .{ .shape = .carried, .exit_instr = 0 };
            },
            .writeback => {
                self.shape = .loop_done_linked;
                if (t.instrs[n - 1].op == .link) return .{ .shape = .writeback, .exit_instr = n - 1 };
            },
            .loop_done_linked => {
                while (self.i < n) {
                    const i = self.i;
                    self.i += 1;
                    if (t.isNumericForLoopDoneGuard(i) and t.linkedLoopDoneEmitted(i))
                        return .{ .shape = .loop_done_linked, .exit_instr = i };
                }
                self.shape = .region_bridge;
                self.i = 0;
            },
            .region_bridge => {
                while (self.i < n) {
                    const i = self.i;
                    self.i += 1;
                    if (!t.isNumericForLoopDoneGuard(i) and t.isBridgeCandidate(i))
                        return .{ .shape = .region_bridge, .exit_instr = i };
                }
                return null;
            },
        };
    }
};

/// Counts the facts an exit's writes generate (`transfer`'s gen step).
const GenCounter = struct {
    t: *const Trace,
    n: usize = 0,
    pub fn write(self: *GenCounter, w: boundary.Write) !void {
        if (w.kind == .boxed) return;
        self.n += 1;
        if (exactOf(self.t, w, boundary.flushTag(w.kind)) != null) self.n += 1;
    }
};

const WriteCollector = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayList(boundary.Write),
    pub fn write(self: WriteCollector, w: boundary.Write) !void {
        try self.list.append(self.gpa, w);
    }
};

/// The number of entry facts before canonicalization: what `entryFacts`
/// writes.
fn entryBound(t: *const Trace, kinds: []const Kind, alloc: *const Alloc) Error!usize {
    var n: usize = 0;
    for (alloc.slots) |s| {
        if (boundary.entryTag(s) != null) n += 1;
        if (boundary.entryPin(s) != null) n += 1;
    }
    for (0..t.instrs.len) |i| {
        if (boundary.entryGuardHoisted(t, kinds, alloc, i) != null) n = try std.math.add(usize, n, 1);
    }
    return n;
}

/// Write the page's entry facts into `out` (sized by `entryBound`) and
/// return the canonical length.
fn entryFacts(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, out: []Fact) usize {
    var n: usize = 0;
    for (alloc.slots) |s| {
        if (boundary.entryTag(s)) |tag| {
            out[n] = Fact.tag(s.slot, tag);
            n += 1;
        }
        if (boundary.entryPin(s)) |p| {
            out[n] = Fact.pin(s.slot, p);
            n += 1;
        }
    }
    for (0..t.instrs.len) |i| {
        const g = boundary.entryGuardHoisted(t, kinds, alloc, i) orelse continue;
        out[n] = switch (g.op) {
            .guard_step_up => Fact.stepUp(g.a.slot),
            .guard_step_down => Fact.stepDown(g.a.slot),
            .guard_for_nov => switch (g.a) {
                .slot => |x| switch (g.b.?) {
                    .slot => |y| Fact.novSlots(x, y),
                    .int => |k| Fact.novConst(x, k),
                },
                .int => |k| Fact.novConst(g.b.?.slot, k),
            },
            else => unreachable,
        };
        n += 1;
    }
    // §5.1: the `.loop` back-edge writes the `write_only` slots, so no entry
    // fact may be about one.
    if (std.debug.runtime_safety) for (alloc.slots) |s| {
        if (s.class != .write_only) continue;
        for (out[0..n]) |f| std.debug.assert(!f.mentions(s.slot));
    };
    return facts.canonicalize(out[0..n]).len;
}

/// `F(P, e)` for an exit with write list `writes`, unsorted, into `out`
/// (room for `|entry|` plus what `GenCounter` counts). Sorts `writes`.
/// Returns the length.
fn transfer(
    gpa: std.mem.Allocator,
    t: *const Trace,
    entry: []const Fact,
    writes: []boundary.Write,
    killed: *std.ArrayList(u16),
    out: []Fact,
) Error!usize {
    // W(e), sorted. A slot written twice keeps only its last write's facts,
    // so the writes are ordered by slot with ties in emission order.
    killed.clearRetainingCapacity();
    for (writes) |w| try killed.append(gpa, w.slot);
    std.mem.sort(u16, killed.items, {}, std.sort.asc(u16));
    std.mem.sort(boundary.Write, writes, {}, struct {
        fn lt(_: void, lhs: boundary.Write, rhs: boundary.Write) bool {
            return lhs.slot < rhs.slot;
        }
    }.lt);

    var n: usize = 0;
    for (entry) |f| {
        if (inSorted(killed.items, f.a)) continue;
        if (f.kind == .nov and !f.b_const and inSorted(killed.items, f.b)) continue;
        out[n] = f;
        n += 1;
    }
    for (writes, 0..) |w, i| {
        // `std.mem.sort` is stable (block sort), so the last of a slot's run
        // is its last write.
        if (i + 1 < writes.len and writes[i + 1].slot == w.slot) continue;
        // A `.boxed` write copies a tag snapshotted at entry: it proves
        // nothing and only kills.
        if (w.kind == .boxed) continue;
        const tag = boundary.flushTag(w.kind);
        out[n] = Fact.tag(w.slot, tag);
        n += 1;
        if (exactOf(t, w, tag)) |v| {
            out[n] = Fact.exact(w.slot, v);
            n += 1;
        }
    }
    return n;
}

/// The value a write of a scalar constant puts in the slab: the flush tag
/// and the constant's payload bits.
fn exactOf(t: *const Trace, w: boundary.Write, tag: u8) ?Value {
    const ref = w.ref orelse return null;
    const ins = t.instrs[ref];
    if (ins.op != .konst) return null;
    switch (w.kind) {
        .int, .float, .bool, .nil => {},
        else => return null,
    }
    return .{ .tag = @enumFromInt(tag), .payload = .{ .bits = t.consts[@intCast(ins.aux)].payload.bits } };
}

fn inSorted(xs: []const u16, x: u16) bool {
    return std.sort.binarySearch(u16, xs, x, struct {
        fn cmp(key: u16, item: u16) std.math.Order {
            return std.math.order(key, item);
        }
    }.cmp) != null;
}
