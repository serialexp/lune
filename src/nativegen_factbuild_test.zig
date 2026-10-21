//! Doc 67 P0: the fact tables built from real `proveKinds` + `analyze`
//! results on hand-built traces.

const std = @import("std");
const testing = std.testing;
const value = @import("value.zig");
const bytecode = @import("bytecode.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const artifact = @import("nativegen_artifact.zig");
const prove = @import("nativegen_prove.zig");
const ngalloc = @import("nativegen_alloc.zig");
const boundary = @import("nativegen_boundary.zig");
const factbuild = @import("nativegen_factbuild.zig");
const slab_facts = @import("nativegen_facts.zig");
const layout = @import("nativegen_layout.zig");

const Value = value.Value;
const I = trace_ir.IrInstr;
const Trace = trace_code.TraceCode;
const Kind = artifact.Kind;
const Fact = slab_facts.Fact;
const PageFacts = slab_facts.PageFacts;

const Analyzed = struct {
    kinds: []Kind,
    slot_of: []i32,
    alloc: ngalloc.Alloc,

    fn init(t: *const Trace) !Analyzed {
        const gpa = testing.allocator;
        const kinds = try gpa.alloc(Kind, t.instrs.len);
        errdefer gpa.free(kinds);
        const slot_of = try gpa.alloc(i32, t.instrs.len);
        errdefer gpa.free(slot_of);
        if (!prove.proveKinds(gpa, t, kinds, slot_of)) return error.ProveFailed;
        const alloc = ngalloc.analyze(gpa, t, kinds, slot_of) orelse return error.AnalyzeBailed;
        return .{ .kinds = kinds, .slot_of = slot_of, .alloc = alloc };
    }

    fn deinit(self: *Analyzed) void {
        self.alloc.deinit(testing.allocator);
        testing.allocator.free(self.kinds);
        testing.allocator.free(self.slot_of);
    }

    fn facts(self: *const Analyzed, t: *const Trace) !PageFacts {
        return factbuild.buildChecked(testing.allocator, t, self.kinds, &self.alloc, factbuild.BUDGET_BYTES);
    }
};

fn expectFacts(want: []const Fact, got: []const Fact) !void {
    var sorted: [32]Fact = undefined;
    @memcpy(sorted[0..want.len], want);
    const canon = slab_facts.canonicalize(sorted[0..want.len]);
    try testing.expectEqual(canon.len, got.len);
    for (canon, got) |w, g| try testing.expect(w.order(g) == .eq);
}

const INT = layout.TAG_INT;
const FLOAT = layout.TAG_FLOAT;

/// A one-shot `.link` page, spectral's `a` shape: slot 0 enters a float and
/// leaves the int 0; slot 1 is only read; slot 3 is write-only.
var oneshot_code = [_]bytecode.Instr{.{ .op = .jmp }};
var oneshot_proto = bytecode.Proto{ .code = &oneshot_code, .num_registers = 4, .name = "facts-oneshot" };
var oneshot_consts = [_]Value{Value.int(0)};
var oneshot_instrs = [_]I{
    .{ .op = .slot_load, .aux = 0 },
    .{ .op = .guard_float, .a = 0 },
    .{ .op = .slot_load, .aux = 1 },
    .{ .op = .guard_int, .a = 2 },
    .{ .op = .konst, .aux = 0 },
    .{ .op = .slot_load, .aux = 2 },
    .{ .op = .guard_int, .a = 5 },
    .{ .op = .add, .a = 5, .b = 2, .ty = .int },
    .{ .op = .phi, .b = 4, .aux = 0 },
    .{ .op = .phi, .b = 7, .aux = 3 },
    .{ .op = .link },
};

fn oneshotTrace() Trace {
    return .{
        .anchor = .{ .proto = &oneshot_proto, .pc = trace_code.FUNC_HEAD_PC, .proto_id = oneshot_proto.id },
        .instrs = &oneshot_instrs,
        .consts = &oneshot_consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
}

test "facts: a one-shot writeback kills the tags it overwrites and keeps untouched slots" {
    const t = oneshotTrace();
    var an = try Analyzed.init(&t);
    defer an.deinit();
    var pf = try an.facts(&t);
    defer pf.deinit(testing.allocator);

    try expectFacts(&.{ Fact.tag(0, FLOAT), Fact.tag(1, INT), Fact.tag(2, INT) }, pf.entry());
    const wb = pf.exitFacts(.writeback, @intCast(oneshot_instrs.len - 1)).?;
    try expectFacts(&.{
        Fact.tag(0, INT),  Fact.exact(0, Value.int(0)),
        Fact.tag(1, INT),  Fact.tag(2, INT),
        Fact.tag(3, INT),
    }, wb);
    // The entry float is gone: a child checking it keeps its check.
    try testing.expect(!slab_facts.proves(wb, &.{Fact.tag(0, FLOAT)}));
    // The constant decides the step facts about slot 0.
    try testing.expect(slab_facts.proves(wb, &.{ Fact.tag(0, INT), Fact.stepDown(0) }));
    try testing.expect(!slab_facts.proves(wb, &.{Fact.stepUp(0)}));
    // Its guard exits flush no carried home (a one-shot page has none), so
    // their list is the entry list. No loop-done or bridge lists.
    try testing.expectEqual(@as(usize, 2), pf.exits.len);
    try expectFacts(pf.entry(), pf.exitFacts(.carried, 1).?);
}

/// A one-shot page that checks `nov(bound, step)` and then overwrites only
/// the step.
var nov_consts = [_]Value{Value.int(5)};
var nov_instrs = [_]I{
    .{ .op = .slot_load, .aux = 0 },
    .{ .op = .guard_int, .a = 0 },
    .{ .op = .slot_load, .aux = 1 },
    .{ .op = .guard_int, .a = 2 },
    .{ .op = .guard_for_nov, .a = 0, .b = 2 },
    .{ .op = .konst, .aux = 0 },
    .{ .op = .phi, .b = 5, .aux = 1 },
    .{ .op = .link },
};

test "facts: a write to either nov operand kills the nov fact" {
    const t = Trace{
        .anchor = .{ .proto = &oneshot_proto, .pc = trace_code.FUNC_HEAD_PC, .proto_id = oneshot_proto.id },
        .instrs = &nov_instrs,
        .consts = &nov_consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    var an = try Analyzed.init(&t);
    defer an.deinit();
    var pf = try an.facts(&t);
    defer pf.deinit(testing.allocator);
    try expectFacts(&.{ Fact.tag(0, INT), Fact.tag(1, INT), Fact.novSlots(0, 1) }, pf.entry());
    const wb = pf.exitFacts(.writeback, @intCast(nov_instrs.len - 1)).?;
    try expectFacts(&.{ Fact.tag(0, INT), Fact.tag(1, INT), Fact.exact(1, Value.int(5)) }, wb);
    // Slot 0's value is unknown, so the constant step alone decides nothing.
    try testing.expect(!slab_facts.proves(wb, &.{Fact.novSlots(1, 0)}));
}

test "facts: a precise page keeps its entry facts and has no exit lists" {
    var t = oneshotTrace();
    var an = try Analyzed.init(&t);
    defer an.deinit();
    t.deopt_mode = .precise;
    var pf = try an.facts(&t);
    defer pf.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), pf.entry_len);
    try testing.expectEqual(@as(usize, 0), pf.exits.len);
}

/// A `.loop` page: slot 0 carried, slots 1 (step) and 2 (limit) invariant.
var loop_code = [_]bytecode.Instr{.{ .op = .jmp }};
var loop_proto = bytecode.Proto{ .code = &loop_code, .num_registers = 3, .name = "facts-loop" };
var loop_consts = [_]Value{Value.int(7)};
var loop_instrs = [_]I{
    .{ .op = .slot_load, .aux = 0 },
    .{ .op = .guard_int, .a = 0 },
    .{ .op = .slot_load, .aux = 1 },
    .{ .op = .guard_int, .a = 2 },
    .{ .op = .slot_load, .aux = 2 },
    .{ .op = .guard_int, .a = 4 },
    .{ .op = .guard_step_up, .a = 2 }, // 6: hoisted, slot 1
    .{ .op = .guard_for_nov, .a = 4, .b = 2 }, // 7: hoisted, slots 2 + 1
    .{ .op = .konst, .aux = 0 },
    .{ .op = .guard_for_nov, .a = 8, .b = 2 }, // 9: hoisted, 7 + slot 1
    .{ .op = .lt, .a = 0, .b = 4 },
    .{ .op = .guard_true, .a = 10 },
    .{ .op = .add, .a = 0, .b = 2, .ty = .int },
    .{ .op = .guard_step_up, .a = 12 }, // 13: computed operand, stays in the body
    .{ .op = .guard_for_nov, .a = 8, .b = 8 }, // 14: constants only, stays in the body
    .{ .op = .phi, .b = 12, .aux = 0 },
    .{ .op = .loop },
};

test "facts: entry-hoisted for guards, and the carried exit of a loop page" {
    const t = Trace{
        .anchor = .{ .proto = &loop_proto, .pc = 0, .proto_id = loop_proto.id },
        .instrs = &loop_instrs,
        .consts = &loop_consts,
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    var an = try Analyzed.init(&t);
    defer an.deinit();
    try testing.expect(boundary.entryGuardHoisted(&t, an.kinds, &an.alloc, 6) != null);
    try testing.expect(boundary.entryGuardHoisted(&t, an.kinds, &an.alloc, 13) == null);
    try testing.expect(boundary.entryGuardHoisted(&t, an.kinds, &an.alloc, 14) == null);

    var pf = try an.facts(&t);
    defer pf.deinit(testing.allocator);
    const entry = [_]Fact{
        Fact.tag(0, INT),        Fact.tag(1, INT),        Fact.tag(2, INT),
        Fact.stepUp(1),          Fact.novSlots(2, 1),     Fact.novConst(1, 7),
    };
    try expectFacts(&entry, pf.entry());
    // The carried flush rewrites slot 0 with its home's tag and nothing
    // about its value; the invariant facts pass through.
    const carried = pf.exitFacts(.carried, 11).?;
    try expectFacts(&entry, carried);
    try testing.expect(pf.exitFacts(.carried, 0).?.ptr == carried.ptr);
}

test "facts: an over-budget page and an allocation failure both fail closed" {
    const t = oneshotTrace();
    var an = try Analyzed.init(&t);
    defer an.deinit();
    try testing.expectError(error.OverBudget, factbuild.buildChecked(testing.allocator, &t, an.kinds, &an.alloc, 64));
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, tr: *const Trace, kinds: []const Kind, alloc: *const ngalloc.Alloc) !void {
            var pf = try factbuild.buildChecked(gpa, tr, kinds, alloc, factbuild.BUDGET_BYTES);
            pf.deinit(gpa);
        }
    }.run, .{ &t, an.kinds, &an.alloc });
}
