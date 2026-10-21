//! Doc 67 §4.1/§6: the slab-fact algebra (`nativegen_facts.zig`):
//! identity, canonical order, `proves` and its one entailment rule.

const std = @import("std");
const testing = std.testing;
const facts = @import("nativegen_facts.zig");
const layout = @import("nativegen_layout.zig");
const Value = @import("value.zig").Value;

const Fact = facts.Fact;

fn canon(buf: []Fact) []const Fact {
    return facts.canonicalize(buf);
}

test "facts: nov is one fact in either operand order" {
    try testing.expectEqual(std.math.Order.eq, Fact.novSlots(5, 6).order(Fact.novSlots(6, 5)));
    var have = [_]Fact{Fact.novSlots(6, 5)};
    const need = [_]Fact{Fact.novSlots(5, 6)};
    try testing.expect(facts.proves(canon(&have), &need));
    // A slot pair and a slot-constant pair are different facts.
    try testing.expect(Fact.novSlots(5, 6).order(Fact.novConst(5, 6)) != .eq);
}

test "facts: canonicalize sorts and drops duplicates" {
    var buf = [_]Fact{
        Fact.tag(3, layout.TAG_INT),
        Fact.stepUp(2),
        Fact.tag(1, layout.TAG_FLOAT),
        Fact.tag(3, layout.TAG_INT),
        Fact.novSlots(4, 1),
    };
    const c = canon(&buf);
    try testing.expectEqual(@as(usize, 4), c.len);
    for (c[1..], 0..) |f, i| try testing.expectEqual(std.math.Order.lt, c[i].order(f));
}

test "facts: proves needs every fact, and nothing proves a missing one" {
    var have_buf = [_]Fact{ Fact.tag(1, layout.TAG_INT), Fact.tag(2, layout.TAG_FLOAT), Fact.stepUp(2) };
    const have = canon(&have_buf);
    try testing.expect(facts.proves(have, &.{}));
    var need_ok = [_]Fact{ Fact.tag(2, layout.TAG_FLOAT), Fact.stepUp(2) };
    try testing.expect(facts.proves(have, canon(&need_ok)));
    // Same slot, other tag.
    var need_tag = [_]Fact{Fact.tag(1, layout.TAG_FLOAT)};
    try testing.expect(!facts.proves(have, canon(&need_tag)));
    // Same slot, other direction.
    var need_dir = [_]Fact{Fact.stepDown(2)};
    try testing.expect(!facts.proves(have, canon(&need_dir)));
    // A slot the parent says nothing about.
    var need_slot = [_]Fact{Fact.tag(9, layout.TAG_INT)};
    try testing.expect(!facts.proves(have, canon(&need_slot)));
    // An empty parent table proves only the empty requirement.
    try testing.expect(!facts.proves(&.{}, canon(&need_ok)));
}

test "facts: an exact value decides tag, pin, direction and overflow" {
    var have_buf = [_]Fact{
        Fact.exact(1, Value.int(1)),
        Fact.exact(2, Value.int(std.math.maxInt(i64))),
        Fact.exact(3, Value.boolean(true)),
        Fact.exact(4, Value.float(std.math.nan(f64))),
        Fact.exact(5, Value.float(-0.0)),
        Fact.exact(6, Value.int(-3)),
    };
    const have = canon(&have_buf);
    const yes = [_]Fact{
        Fact.tag(1, layout.TAG_INT),
        Fact.stepUp(1),
        Fact.pin(3, true),
        Fact.tag(3, layout.TAG_BOOL),
        // Lua 5.4: a NaN or -0.0 step counts down.
        Fact.stepDown(4),
        Fact.stepDown(5),
        Fact.stepDown(6),
        Fact.novConst(2, 0),
        Fact.novConst(2, -1),
        Fact.novSlots(2, 6),
        Fact.novSlots(1, 6),
    };
    for (yes) |f| {
        const one = [_]Fact{f};
        if (!facts.proves(have, &one)) {
            std.debug.print("not entailed: {any}\n", .{f});
            return error.TestUnexpectedResult;
        }
    }
    const no = [_]Fact{
        Fact.tag(1, layout.TAG_FLOAT),
        Fact.stepDown(1),
        Fact.stepUp(4),
        Fact.stepUp(5),
        Fact.pin(3, false),
        // A boolean is not a number: no direction.
        Fact.stepUp(3),
        Fact.stepDown(3),
        // maxinteger + 1 overflows, and maxinteger + maxinteger does too.
        Fact.novConst(2, 1),
        Fact.novSlots(1, 2),
        // A float is not an int operand of `nov`.
        Fact.novConst(4, 0),
        // The second operand is unknown.
        Fact.novSlots(1, 9),
    };
    for (no) |f| {
        const one = [_]Fact{f};
        if (facts.proves(have, &one)) {
            std.debug.print("wrongly entailed: {any}\n", .{f});
            return error.TestUnexpectedResult;
        }
    }
}

test "facts: a write kills exactly the facts that mention its slot" {
    try testing.expect(Fact.tag(3, layout.TAG_INT).mentions(3));
    try testing.expect(!Fact.tag(3, layout.TAG_INT).mentions(4));
    try testing.expect(Fact.novSlots(3, 7).mentions(7));
    try testing.expect(Fact.novSlots(3, 7).mentions(3));
    // A constant operand is not a slot.
    try testing.expect(!Fact.novConst(3, 7).mentions(7));
}
