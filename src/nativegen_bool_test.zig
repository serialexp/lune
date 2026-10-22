//! Doc 57 P2: native value pins (`guard_is_nil/false/true`), `not` and bool
//! `eq`/`ne`. Hand-built IR, run through the tier-1a oracle and native on the
//! same register files (`expectMatch`), plus `analyze` shape checks.

const std = @import("std");
const nativegen = @import("nativegen.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const Value = value.Value;
const Trace = @import("trace_code.zig").TraceCode;
const testing = std.testing;
const I = trace.IrInstr;

const ngalloc = @import("nativegen_alloc.zig");
const Kind = nativegen.Kind;
const SlotClass = nativegen.SlotClass;
const analyze = nativegen.analyze;
const proveKinds = nativegen.proveKinds;
const is_x64_linux = nativegen.is_x64_linux;

const util = @import("nativegen_testutil.zig");
const expectMatch = util.expectMatch;
const expectBail = util.expectBail;

/// Prove + analyze `t`; the caller owns the returned allocation.
fn analyzed(t: *const Trace, kinds: []Kind, slot_of: []i32) !nativegen.Alloc {
    try testing.expect(proveKinds(testing.allocator, t, kinds, slot_of));
    return analyze(testing.allocator, t, kinds, slot_of) orelse error.AnalyzeBailed;
}

fn slotInfo(al: *const nativegen.Alloc, slot: u16) !ngalloc.SlotInfo {
    for (al.slots) |s| if (s.slot == slot) return s;
    return error.NoSuchSlot;
}

// r0 = flag (pinned true), r1 = i, r2 = limit. `for i..limit` with only the
// pin reading the flag: the shape-A loop after the recorder's fold.
var pin_true_instrs = [_]I{
    .{ .op = .slot_load, .aux = 0 }, // 0: flag
    .{ .op = .guard_is_true, .a = 0 }, // 1
    .{ .op = .slot_load, .aux = 1 }, // 2: i
    .{ .op = .slot_load, .aux = 2 }, // 3: limit
    .{ .op = .guard_int, .a = 2 }, // 4
    .{ .op = .guard_int, .a = 3 }, // 5
    .{ .op = .konst, .aux = 0 }, // 6: 1
    .{ .op = .add, .a = 2, .b = 6 }, // 7: i + 1
    .{ .op = .le, .a = 7, .b = 3 }, // 8
    .{ .op = .guard_true, .a = 8 }, // 9
    .{ .op = .phi, .b = 7, .aux = 1 }, // 10
    .{ .op = .loop }, // 11
};
var one_const = [_]Value{Value.int(1)};

test "doc 57 native: an invariant bool pin is prologue-only and home-less (pin_only)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &pin_true_instrs, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };

    var kinds: [pin_true_instrs.len]Kind = undefined;
    var slot_of: [pin_true_instrs.len]i32 = undefined;
    var al = try analyzed(&t, &kinds, &slot_of);
    defer al.deinit(testing.allocator);
    try testing.expectEqual(Kind.bool, kinds[0]);
    const s = try slotInfo(&al, 0);
    try testing.expectEqual(SlotClass.invariant, s.class);
    try testing.expectEqual(@as(?bool, true), s.pin);
    try testing.expect(s.pin_only);
    try testing.expect(ngalloc.pinHoisted(&t, al.slots, al.slot_id_of_ref, 0));
    // The hoisted pin has no body exit.
    try testing.expect(!ngalloc.opMayExitInBody(&t, &kinds, al.slots, al.slot_id_of_ref, 1));

    // Pinned value: the loop runs. Anything else fails the prologue (the
    // oracle fails the pin on iteration 1) — including the other bool, a
    // truthy int and nil.
    try expectMatch(&t, &.{ Value.boolean(true), Value.int(0), Value.int(20) });
    try expectMatch(&t, &.{ Value.boolean(false), Value.int(0), Value.int(20) });
    try expectMatch(&t, &.{ Value.int(1), Value.int(0), Value.int(20) });
    try expectMatch(&t, &.{ Value.nil(), Value.int(0), Value.int(20) });
}

test "doc 57 native: a nil pin checks the tag only" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = pin_true_instrs;
    instrs[1].op = .guard_is_nil;
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };

    var kinds: [instrs.len]Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var al = try analyzed(&t, &kinds, &slot_of);
    defer al.deinit(testing.allocator);
    try testing.expectEqual(Kind.nil, kinds[0]);
    try testing.expect((try slotInfo(&al, 0)).pin_only);

    try expectMatch(&t, &.{ Value.nil(), Value.int(0), Value.int(20) });
    try expectMatch(&t, &.{ Value.boolean(false), Value.int(0), Value.int(20) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(0), Value.int(20) });
}

test "doc 57 native: a pinned slot another slot copies keeps a home and flushes exactly" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // `y = flag` each iteration: the φ writeback reads the pinned load, so it
    // needs a home (not pin_only), and the write-only commit boxes TAG_BOOL.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: flag
        .{ .op = .guard_is_false, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 1 }, // 2: i
        .{ .op = .slot_load, .aux = 2 }, // 3: limit
        .{ .op = .guard_int, .a = 2 }, // 4
        .{ .op = .guard_int, .a = 3 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 2, .b = 6 }, // 7
        .{ .op = .le, .a = 7, .b = 3 }, // 8
        .{ .op = .guard_true, .a = 8 }, // 9
        .{ .op = .phi, .b = 7, .aux = 1 }, // 10
        .{ .op = .phi, .b = 0, .aux = 3 }, // 11: r3 = flag
        .{ .op = .loop }, // 12
    };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };

    var kinds: [instrs.len]Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var al = try analyzed(&t, &kinds, &slot_of);
    defer al.deinit(testing.allocator);
    const s = try slotInfo(&al, 0);
    try testing.expectEqual(@as(?bool, false), s.pin);
    try testing.expect(!s.pin_only);

    try expectMatch(&t, &.{ Value.boolean(false), Value.int(0), Value.int(20), Value.int(7) });
    try expectMatch(&t, &.{ Value.boolean(true), Value.int(0), Value.int(20), Value.int(7) });
}

test "doc 57 native: a carried bool pin is a per-iteration body compare" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // `if not b ... end; b = (i + 1 >= 5)`: b is pinned false at its read and
    // carried as a compare result. The pin fails once i + 1 reaches 5 — a
    // mid-run body exit that must flush b's TAG_BOOL home exactly.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: b
        .{ .op = .guard_is_false, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 1 }, // 2: i
        .{ .op = .slot_load, .aux = 2 }, // 3: limit
        .{ .op = .guard_int, .a = 2 }, // 4
        .{ .op = .guard_int, .a = 3 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 2, .b = 6 }, // 7: i + 1
        .{ .op = .konst, .aux = 1 }, // 8: 5
        .{ .op = .le, .a = 8, .b = 7 }, // 9: 5 <= i + 1
        .{ .op = .le, .a = 7, .b = 3 }, // 10
        .{ .op = .guard_true, .a = 10 }, // 11
        .{ .op = .phi, .b = 9, .aux = 0 }, // 12: b = …
        .{ .op = .phi, .b = 7, .aux = 1 }, // 13
        .{ .op = .loop }, // 14
    };
    var consts = [_]Value{ Value.int(1), Value.int(5) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    var kinds: [instrs.len]Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var al = try analyzed(&t, &kinds, &slot_of);
    defer al.deinit(testing.allocator);
    const s = try slotInfo(&al, 0);
    try testing.expectEqual(SlotClass.carried, s.class);
    try testing.expectEqual(Kind.bool, s.kind);
    try testing.expect(!s.pin_only);
    try testing.expect(!ngalloc.pinHoisted(&t, al.slots, al.slot_id_of_ref, 0));
    try testing.expect(ngalloc.opMayExitInBody(&t, &kinds, al.slots, al.slot_id_of_ref, 1));

    // Exits mid-run at the body pin (i + 1 = 5 made b true).
    try expectMatch(&t, &.{ Value.boolean(false), Value.int(0), Value.int(20) });
    // Runs to the limit before b turns (limit 3 < 5).
    try expectMatch(&t, &.{ Value.boolean(false), Value.int(0), Value.int(3) });
    // Fails at once: the entry value is `true`, or not a bool at all.
    try expectMatch(&t, &.{ Value.boolean(true), Value.int(0), Value.int(20) });
    try expectMatch(&t, &.{ Value.int(0), Value.int(0), Value.int(20) });
}

test "doc 57 native: not and bool eq/ne compute canonical 0/1 results" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // x = i + 1 < 3; r3 = not x; r4 = (not x) == true; r5 = x ~= not x.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 1 }, // 0: i
        .{ .op = .slot_load, .aux = 2 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .konst, .aux = 0 }, // 4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // 5: i + 1
        .{ .op = .konst, .aux = 1 }, // 6: 3
        .{ .op = .lt, .a = 5, .b = 6 }, // 7: x
        .{ .op = .not, .a = 7 }, // 8
        .{ .op = .konst, .aux = 2 }, // 9: true
        .{ .op = .eq, .a = 8, .b = 9 }, // 10
        .{ .op = .ne, .a = 7, .b = 8 }, // 11
        .{ .op = .le, .a = 5, .b = 1 }, // 12
        .{ .op = .guard_true, .a = 12 }, // 13
        .{ .op = .phi, .b = 5, .aux = 1 }, // 14
        .{ .op = .phi, .b = 8, .aux = 3 }, // 15
        .{ .op = .phi, .b = 10, .aux = 4 }, // 16
        .{ .op = .phi, .b = 11, .aux = 5 }, // 17
        .{ .op = .loop }, // 18
    };
    var consts = [_]Value{ Value.int(1), Value.int(3), Value.boolean(true) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    var kinds: [instrs.len]Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var al = try analyzed(&t, &kinds, &slot_of);
    defer al.deinit(testing.allocator);
    try testing.expectEqual(Kind.bool, kinds[8]);
    try testing.expectEqual(Kind.bool, kinds[10]);
    try testing.expectEqual(Kind.bool, kinds[11]);

    const nil = Value.nil();
    // Final iteration has x false: r3 = true, r4 = true, r5 = true.
    try expectMatch(&t, &.{ nil, Value.int(0), Value.int(10), nil, nil, nil });
    // One iteration with x true: r3 = false, r4 = false, r5 = true.
    try expectMatch(&t, &.{ nil, Value.int(0), Value.int(1), nil, nil, nil });
}

test "doc 57 native: malformed pins and unstable carried bools bail" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var es = [_]u16{};
    {
        // A bool pin on an int-guarded load cannot be discharged.
        var instrs = pin_true_instrs;
        instrs[1] = .{ .op = .guard_int, .a = 0 };
        var bad = [_]I{ instrs[0], instrs[1], .{ .op = .guard_is_true, .a = 0 }, .{ .op = .loop } };
        const t = Trace{ .anchor = undefined, .instrs = &bad, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };
        var kinds: [bad.len]Kind = undefined;
        var slot_of: [bad.len]i32 = undefined;
        try testing.expect(!proveKinds(testing.allocator, &t, &kinds, &slot_of));
    }
    {
        // Two different pins on one load.
        var bad = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_is_true, .a = 0 },
            .{ .op = .guard_is_false, .a = 0 },
            .{ .op = .loop },
        };
        const t = Trace{ .anchor = undefined, .instrs = &bad, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };
        var kinds: [bad.len]Kind = undefined;
        var slot_of: [bad.len]i32 = undefined;
        try testing.expect(!proveKinds(testing.allocator, &t, &kinds, &slot_of));
    }
    {
        // A carried pinned bool whose update is an int: RV-3 refuses it.
        var bad = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: b
            .{ .op = .guard_is_true, .a = 0 }, // 1
            .{ .op = .konst, .aux = 0 }, // 2: 1
            .{ .op = .phi, .b = 2, .aux = 0 }, // 3: b = 1
            .{ .op = .loop },
        };
        const t = Trace{ .anchor = undefined, .instrs = &bad, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
    {
        // A nil pin on a carried slot: a `.nil` is never carried.
        var bad = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: x
            .{ .op = .guard_is_nil, .a = 0 }, // 1
            .{ .op = .phi, .b = 0, .aux = 0 }, // 2: x = x
            .{ .op = .loop },
        };
        const t = Trace{ .anchor = undefined, .instrs = &bad, .consts = &one_const, .entry_slots = &es, .entry_guards = &.{} };
        try expectBail(&t);
    }
}

// A compare whose one reader is the guard right after it lowers to `cmp` +
// one `jcc` (`Loc.flags`, `ngalloc.isFlagsCompare`). `c = (i + 1) OP k` (or
// `k OP (i + 1)` when `swap`), guarded by `pol`, inside `for i..limit`.
fn flagsLoop(op: trace.IrOp, pol: trace.IrOp, swap: bool) [13]I {
    const l: u16 = if (swap) 6 else 5;
    const r: u16 = if (swap) 5 else 6;
    return .{
        .{ .op = .slot_load, .aux = 1 }, // 0: i
        .{ .op = .slot_load, .aux = 2 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .konst, .aux = 0 }, // 4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // 5: i + 1
        .{ .op = .konst, .aux = 1 }, // 6: k
        .{ .op = op, .a = l, .b = r }, // 7: the compare
        .{ .op = pol, .a = 7 }, // 8
        .{ .op = .le, .a = 5, .b = 1 }, // 9
        .{ .op = .guard_true, .a = 9 }, // 10
        .{ .op = .phi, .b = 5, .aux = 1 }, // 11
        .{ .op = .loop }, // 12
    };
}

test "native: a compare read only by the next guard lives in the flags" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const nil = Value.nil();
    for ([_]trace.IrOp{ .eq, .ne, .lt, .le }) |op| {
        for ([_]trace.IrOp{ .guard_true, .guard_false }) |pol| {
            for ([_]bool{ false, true }) |swap| {
                var instrs = flagsLoop(op, pol, swap);
                var consts = [_]Value{ Value.int(1), Value.int(7) };
                var es = [_]u16{};
                const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

                var kinds: [instrs.len]Kind = undefined;
                var slot_of: [instrs.len]i32 = undefined;
                var al = try analyzed(&t, &kinds, &slot_of);
                defer al.deinit(testing.allocator);
                try testing.expect(al.loc[7] == .flags);
                // The loop's own `le` (9) is fused as well.
                try testing.expect(al.loc[9] == .flags);

                // Starting points on both sides of k and at it, so each
                // guard passes for a while, fails at once, or never fails.
                for ([_]i64{ -3, 5, 6, 7, 30 }) |start| {
                    try expectMatch(&t, &.{ nil, Value.int(start), Value.int(12) });
                }
            }
        }
    }
}

test "native: a float order compare lives in the flags and keeps NaN false" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const nil = Value.nil();
    for ([_]trace.IrOp{ .lt, .le, .eq }) |op| {
        for ([_]trace.IrOp{ .guard_true, .guard_false }) |pol| {
            // r3 OP r4 over two invariant floats, guarded, inside `for i..limit`.
            var instrs = [_]I{
                .{ .op = .slot_load, .aux = 1 }, // 0: i
                .{ .op = .slot_load, .aux = 2 }, // 1: limit
                .{ .op = .guard_int, .a = 0 }, // 2
                .{ .op = .guard_int, .a = 1 }, // 3
                .{ .op = .slot_load, .aux = 3 }, // 4: x
                .{ .op = .slot_load, .aux = 4 }, // 5: y
                .{ .op = .guard_float, .a = 4 }, // 6
                .{ .op = .guard_float, .a = 5 }, // 7
                .{ .op = op, .a = 4, .b = 5 }, // 8
                .{ .op = pol, .a = 8 }, // 9
                .{ .op = .konst, .aux = 0 }, // 10: 1
                .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
                .{ .op = .le, .a = 11, .b = 1 }, // 12
                .{ .op = .guard_true, .a = 12 }, // 13
                .{ .op = .phi, .b = 11, .aux = 1 }, // 14
                .{ .op = .loop }, // 15
            };
            var consts = [_]Value{Value.int(1)};
            var es = [_]u16{};
            const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

            var kinds: [instrs.len]Kind = undefined;
            var slot_of: [instrs.len]i32 = undefined;
            var al = try analyzed(&t, &kinds, &slot_of);
            defer al.deinit(testing.allocator);
            // A float `==` needs ZF and PF, so it keeps its bool.
            try testing.expectEqual(op != .eq, al.loc[8] == .flags);

            const nan = std.math.nan(f64);
            const pairs = [_][2]f64{ .{ 1.5, 2.5 }, .{ 2.5, 2.5 }, .{ 3.5, 2.5 }, .{ nan, 2.5 }, .{ 2.5, nan }, .{ -0.0, 0.0 } };
            for (pairs) |xy| {
                try expectMatch(&t, &.{ nil, Value.int(0), Value.int(5), Value.float(xy[0]), Value.float(xy[1]) });
            }
        }
    }
}

test "native: a compare with another reader keeps its bool" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const nil = Value.nil();
    // `flagsLoop`, with the compare also written back to r3 by a φ.
    var base = flagsLoop(.lt, .guard_true, false);
    var instrs: [14]I = undefined;
    @memcpy(instrs[0..12], base[0..12]);
    instrs[12] = .{ .op = .phi, .b = 7, .aux = 3 };
    instrs[13] = .{ .op = .loop };
    var consts = [_]Value{ Value.int(1), Value.int(7) };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    var kinds: [instrs.len]Kind = undefined;
    var slot_of: [instrs.len]i32 = undefined;
    var al = try analyzed(&t, &kinds, &slot_of);
    defer al.deinit(testing.allocator);
    try testing.expect(al.loc[7] != .flags);
    for ([_]i64{ 0, 6, 30 }) |start| {
        try expectMatch(&t, &.{ nil, Value.int(start), Value.int(12), nil });
    }
}
