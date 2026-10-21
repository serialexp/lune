//! Doc 67 §4.1: slab facts. A fact is a predicate on the register slab
//! (`tags[]`, `payloads[]`) that names no trace-local ref, so two compiled
//! pages can compare them. A page's ENTRY facts are what its prologue
//! checks. An armable exit's facts are what the slab is proven to satisfy
//! when that exit jumps through its slot. An arm may target a child's
//! proven entry only when the parent exit's facts prove every child entry
//! fact (`proves`).
//!
//! Pure data and logic: no IR. The builders live in
//! `nativegen_factbuild.zig`. The numeric rules are the tiers' own
//! (`arith.forStepAscending`, `trace_ir.forNoOverflow`), so a fact can
//! never disagree with the guard it stands for.

const std = @import("std");
const value = @import("value.zig");
const arith = @import("arith.zig");
const trace_ir = @import("trace_ir.zig");

const Value = value.Value;

pub const FactKind = enum(u8) {
    /// `tags[a] == byte`.
    tag,
    /// `payloads[a]` is the canonical boolean `byte` (0/1): doc 57's pin.
    pin,
    /// Lua 5.4's `0 < step` for the number in slot `a`, read with its tag.
    step_up,
    /// The complement of `step_up` for a number: negative, zero or NaN.
    step_down,
    /// The int add `a + b` does not overflow. `b` is a slot, or the
    /// constant `k` when `b_const`.
    nov,
    /// Slot `a` holds exactly the value with tag `byte` and payload bits
    /// `k`. Only exit tables hold it; `proves` evaluates the other kinds
    /// against it.
    exact,
};

pub const Fact = struct {
    kind: FactKind,
    byte: u8 = 0,
    b_const: bool = false,
    a: u16,
    b: u16 = 0,
    k: i64 = 0,

    pub fn tag(slot: u16, t: u8) Fact {
        return .{ .kind = .tag, .a = slot, .byte = t };
    }
    pub fn pin(slot: u16, b: bool) Fact {
        return .{ .kind = .pin, .a = slot, .byte = @intFromBool(b) };
    }
    pub fn stepUp(slot: u16) Fact {
        return .{ .kind = .step_up, .a = slot };
    }
    pub fn stepDown(slot: u16) Fact {
        return .{ .kind = .step_down, .a = slot };
    }
    /// `nov` over two slots. The add commutes, so the lower slot comes
    /// first and the two orders are one fact.
    pub fn novSlots(x: u16, y: u16) Fact {
        return .{ .kind = .nov, .a = @min(x, y), .b = @max(x, y) };
    }
    /// `nov` over a slot and a constant. A slot always comes first.
    pub fn novConst(slot: u16, k: i64) Fact {
        return .{ .kind = .nov, .a = slot, .b_const = true, .k = k };
    }
    pub fn exact(slot: u16, v: Value) Fact {
        return .{ .kind = .exact, .a = slot, .byte = @intFromEnum(v.tag), .k = @bitCast(v.payload.bits) };
    }

    /// The total order `proves` and the tables sort by: kind, first operand,
    /// second operand, constant, then the byte. Equality is all of them.
    pub fn order(lhs: Fact, rhs: Fact) std.math.Order {
        if (lhs.kind != rhs.kind) return std.math.order(@intFromEnum(lhs.kind), @intFromEnum(rhs.kind));
        if (lhs.a != rhs.a) return std.math.order(lhs.a, rhs.a);
        if (lhs.b_const != rhs.b_const) return std.math.order(@intFromBool(lhs.b_const), @intFromBool(rhs.b_const));
        if (lhs.b != rhs.b) return std.math.order(lhs.b, rhs.b);
        if (lhs.k != rhs.k) return std.math.order(lhs.k, rhs.k);
        return std.math.order(lhs.byte, rhs.byte);
    }

    pub fn lessThan(_: void, lhs: Fact, rhs: Fact) bool {
        return lhs.order(rhs) == .lt;
    }

    /// Whether the fact mentions `slot`, so a write to it kills the fact.
    pub fn mentions(self: Fact, slot: u16) bool {
        return self.a == slot or (self.kind == .nov and !self.b_const and self.b == slot);
    }
};

// Doc 67 §5.3: a fixed-size record of at most 32 bytes.
comptime {
    std.debug.assert(@sizeOf(Fact) <= 32);
}

/// The slab write contracts of the exits that can jump into another page
/// (doc 67 §5.2). `nativegen_boundary.forEachExitWrite` lists each one's
/// writes.
pub const ExitShape = enum(u8) {
    /// An ordinary coarse exit (`deopt_exit`) and its silent duplicate:
    /// the carried homes. The same for every exit of a page.
    carried,
    /// A one-shot terminal (`.link`, and the head `.terminal`): every slot
    /// with a store, with the store's kind.
    writeback,
    /// The linked numeric-for loop-done exit: the slot-bound φs except the
    /// loop's visible variable.
    loop_done_linked,
    /// An armed composite bridge: the carried homes it does not overwrite,
    /// then its set E.
    region_bridge,
};

/// Doc 67 §5.3: a compiled page's fact tables. `facts` holds the entry list
/// first, then one list per armable exit; `exits` locates each exit's list.
/// Every list is canonical. Built by `nativegen_factbuild.build`; owned by
/// the `CompiledTrace`.
pub const PageFacts = struct {
    facts: []Fact,
    entry_len: u32,
    /// Sorted by `(shape, exit_instr)`. A `.carried` row has `exit_instr`
    /// `CARRIED_EXIT`: one list serves every ordinary exit.
    exits: []ExitRow,

    pub const CARRIED_EXIT: u32 = std.math.maxInt(u32);

    pub const ExitRow = struct {
        shape: ExitShape,
        exit_instr: u32,
        start: u32,
        len: u32,

        fn order(lhs: ExitRow, rhs: ExitRow) std.math.Order {
            if (lhs.shape != rhs.shape) return std.math.order(@intFromEnum(lhs.shape), @intFromEnum(rhs.shape));
            return std.math.order(lhs.exit_instr, rhs.exit_instr);
        }
    };

    /// What the page's prologue checks.
    pub fn entry(self: *const PageFacts) []const Fact {
        return self.facts[0..self.entry_len];
    }

    /// What the slab satisfies when exit `exit_instr`, taken with write
    /// contract `shape`, jumps through its slot. Null when the page has no
    /// table for that exit, which proves nothing.
    pub fn exitFacts(self: *const PageFacts, shape: ExitShape, exit_instr: u32) ?[]const Fact {
        const key: ExitRow = .{ .shape = shape, .exit_instr = if (shape == .carried) CARRIED_EXIT else exit_instr, .start = 0, .len = 0 };
        const i = std.sort.binarySearch(ExitRow, self.exits, key, struct {
            fn cmp(k: ExitRow, item: ExitRow) std.math.Order {
                return k.order(item);
            }
        }.cmp) orelse return null;
        const row = self.exits[i];
        return self.facts[row.start..][0..row.len];
    }

    pub fn bytes(self: *const PageFacts) usize {
        return self.facts.len * @sizeOf(Fact) + self.exits.len * @sizeOf(ExitRow);
    }

    pub fn deinit(self: *PageFacts, gpa: std.mem.Allocator) void {
        gpa.free(self.facts);
        gpa.free(self.exits);
        self.* = undefined;
    }
};

/// Sort `facts` and drop duplicates in place. Returns the canonical prefix.
pub fn canonicalize(facts: []Fact) []Fact {
    std.mem.sort(Fact, facts, {}, Fact.lessThan);
    var n: usize = 0;
    for (facts) |f| {
        if (n > 0 and facts[n - 1].order(f) == .eq) continue;
        facts[n] = f;
        n += 1;
    }
    return facts[0..n];
}

/// Whether the canonical list `have` proves every fact of the canonical
/// list `need`. A fact is proven when `have` holds it, or when `exact`
/// facts in `have` decide it true (the one entailment rule, doc 67 §6).
pub fn proves(have: []const Fact, need: []const Fact) bool {
    return firstUnproven(have, need) == null;
}

/// The first fact of `need` that `have` does not prove, or null when it
/// proves them all.
pub fn firstUnproven(have: []const Fact, need: []const Fact) ?Fact {
    for (need) |f| {
        if (contains(have, f)) continue;
        if (entailed(have, f)) continue;
        return f;
    }
    return null;
}

fn contains(have: []const Fact, f: Fact) bool {
    return std.sort.binarySearch(Fact, have, f, struct {
        fn cmp(key: Fact, item: Fact) std.math.Order {
            return key.order(item);
        }
    }.cmp) != null;
}

/// The `exact` fact about `slot` in `have`, if any. The `exact` facts sort
/// together and by slot, and a canonical table holds at most one per slot.
fn exactOf(have: []const Fact, slot: u16) ?Value {
    const i = std.sort.binarySearch(Fact, have, slot, struct {
        fn cmp(key: u16, item: Fact) std.math.Order {
            if (item.kind != .exact) return std.math.order(@intFromEnum(FactKind.exact), @intFromEnum(item.kind));
            return std.math.order(key, item.a);
        }
    }.cmp) orelse return null;
    const e = have[i];
    return .{ .tag = @enumFromInt(e.byte), .payload = .{ .bits = @bitCast(e.k) } };
}

fn entailed(have: []const Fact, f: Fact) bool {
    const v = exactOf(have, f.a) orelse return false;
    return switch (f.kind) {
        .tag => @intFromEnum(v.tag) == f.byte,
        .pin => v.tag == .boolean and v.payload.bits == f.byte,
        .step_up => v.isNumber() and arith.forStepAscending(v),
        .step_down => v.isNumber() and !arith.forStepAscending(v),
        .nov => blk: {
            if (!v.isInt()) break :blk false;
            const w: Value = if (f.b_const) Value.int(f.k) else exactOf(have, f.b) orelse break :blk false;
            break :blk w.isInt() and trace_ir.forNoOverflow(v, w);
        },
        // A child never requires `exact`.
        .exact => false,
    };
}
