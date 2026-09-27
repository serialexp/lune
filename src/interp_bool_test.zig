//! Doc 57 (native booleans): value-specialized nil/true/false inputs.
//!
//! Every test runs the full `expectProgramTuned` matrix (tier-0, record-only,
//! tier-1a with and without the optimizer, native — each with and without GC
//! stress), so a wrong fold, a missing pin or a bad prologue diverges from
//! tier-0's output. The `inspect` callbacks pin the recorded SHAPE on the legs
//! that execute traces: which pins exist and which consumers folded away.
//! Shared harness lives in `interp_testutil.zig`.

const std = @import("std");
const interp = @import("interp.zig");
const testing = std.testing;
const trace_ir = @import("trace_ir.zig");
const array = @import("array.zig");

const Vm = interp.Vm;
const IrOp = trace_ir.IrOp;
const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;
const expectProgramTuned = util.expectProgramTuned;
const TraceMode = util.TraceMode;

fn executes(mode: TraceMode) bool {
    return mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
}

/// Occurrences of `op` across every committed trace.
fn countOp(vm: *Vm, op: IrOp) usize {
    var n: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        for (t.code.instrs) |ins| {
            if (ins.op == op) n += 1;
        }
    }
    return n;
}

/// Occurrences of `op` whose operand `a` is a `slot_load`.
fn countOpOnSlotLoad(vm: *Vm, op: IrOp) usize {
    var n: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        for (t.code.instrs) |ins| {
            if (ins.op == op and t.code.instrs[ins.a].op == .slot_load) n += 1;
        }
    }
    return n;
}

/// Doc 57 P2: on the native leg, every committed trace holding one of `ops`
/// must have compiled to machine code (and at least one such trace exists).
fn expectNativeHolds(vm: *Vm, mode: TraceMode, ops: []const IrOp) !void {
    if (mode != .record_execute_native) return;
    var holders: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const holds = for (t.code.instrs) |ins| {
            if (std.mem.indexOfScalar(IrOp, ops, ins.op) != null) break true;
        } else false;
        if (!holds) continue;
        holders += 1;
        try testing.expect(t.native == .compiled);
    }
    try testing.expect(holders >= 1);
}

const pin_ops = [_]IrOp{ .guard_is_nil, .guard_is_false, .guard_is_true };

test "doc 57: an invariant bool input is pinned and its branch folds (shape A)" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            try expectNativeHolds(vm, mode, &pin_ops);
            if (!executes(mode)) return;
            try testing.expect(countOpOnSlotLoad(vm, .guard_is_true) >= 1);
            // The `if flag` left no truthiness test on the input: the pin is
            // the only check, and the branch folded to the recorded side.
            try testing.expectEqual(@as(usize, 0), countOpOnSlotLoad(vm, .guard_true));
            try testing.expectEqual(@as(usize, 0), countOpOnSlotLoad(vm, .guard_false));
        }
    };
    try expectProgramTuned(
        \\local flag = true
        \\local n = 0
        \\for i = 1, 300 do if flag then n = n + 1 end end
        \\print(n)
    , "300\n", .{ .inspect = Inspect.run });
}

test "doc 57: a flag that changes value between entries takes the other specialization" {
    // Each call enters the same loop anchor with a different `flag`. The pin
    // is an entry-fingerprint guard, so a trace for `true` must never run on
    // a `false` entry (and vice versa) — the outputs would swap signs.
    try expectProgram(
        \\local function run(flag)
        \\  local n = 0
        \\  for i = 1, 200 do if flag then n = n + 1 else n = n - 1 end end
        \\  return n
        \\end
        \\print(run(true), run(false), run(true), run(false))
    , "200\t-200\t200\t-200\n");
}

test "doc 57: a flag that changes type between entries exits its pin" {
    // A table is truthy like `true` but fails the strict pin; nil is falsy.
    try expectProgram(
        \\local function run(flag)
        \\  local n = 0
        \\  for i = 1, 200 do if flag then n = n + 1 else n = n - 1 end end
        \\  return n
        \\end
        \\print(run(true), run({}), run(nil), run(false), run(0))
    , "200\t200\t-200\t-200\t200\n");
}

test "doc 57: a flipped carried bool is refused at close (shape B, until P3)" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            // The pin on `b`'s entry value contradicts the value it carries
            // around the back-edge, so the close aborts instead of committing
            // a trace that exits every second iteration.
            var unstable: usize = 0;
            for (vm.trace.abort_log.items) |r| {
                if (r.reason == .type_instability) unstable += 1;
            }
            try testing.expect(unstable >= 1);
            // And nothing committed carries a contradicted pin: every pinned
            // slot's slot-bound φ, if any, carries the same konst.
            for (vm.trace.registry.cache.items) |t| {
                for (t.code.instrs) |ins| {
                    const pin = trace_ir.primPinValue(ins.op) orelse continue;
                    const src = t.code.instrs[ins.a];
                    if (src.op != .slot_load) continue;
                    for (t.code.instrs) |phi| {
                        if (phi.op != .phi or phi.aux != src.aux) continue;
                        const upd = t.code.instrs[phi.b];
                        if (upd.op != .konst) continue;
                        try testing.expect(t.code.consts[@intCast(upd.aux)].eql(pin));
                    }
                }
            }
        }
    };
    try expectProgramTuned(
        \\local b = false
        \\local m = 0
        \\for i = 1, 300 do b = not b; if b then m = m + 1 end end
        \\print(m)
    , "150\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 57: a carried bool from a compare keeps a real per-iteration pin" {
    // `b` enters `false`, is read by the `if`, then rewritten by a compare.
    // The pin stays a live check on the carried value (it holds `true` on
    // iterations 2..100, so those take the other path). Native keeps it as a
    // body compare on the carried GP home.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            try expectNativeHolds(vm, mode, &pin_ops);
        }
    };
    try expectProgramTuned(
        \\local b = false
        \\local c = 0
        \\for i = 1, 300 do
        \\  if b then c = c + 1 end
        \\  b = i < 100
        \\end
        \\print(c)
    , "99\n", .{ .inspect = Inspect.run });
}

test "doc 57: bool-lane loads compare and negate as dynamic booleans (shapes D, E)" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            // `t[i] == true` records an `eq` over the bool-lane load (it used
            // to abort `bad_type`), and `not t[i]` a dynamic `not`.
            var eq_on_load: usize = 0;
            var not_on_load: usize = 0;
            for (vm.trace.registry.cache.items) |t| {
                for (t.code.instrs) |ins| {
                    const bool_load = struct {
                        fn is(instrs: []const trace_ir.IrInstr, r: trace_ir.Ref) bool {
                            const x = instrs[r];
                            return x.op == .aload and x.aux == @intFromEnum(array.Lane.boolean);
                        }
                    }.is;
                    if ((ins.op == .eq or ins.op == .ne) and (bool_load(t.code.instrs, ins.a) or bool_load(t.code.instrs, ins.b)))
                        eq_on_load += 1;
                    if (ins.op == .not and bool_load(t.code.instrs, ins.a)) not_on_load += 1;
                }
            }
            try testing.expect(eq_on_load >= 1);
            try testing.expect(not_on_load >= 1);
            try expectNativeHolds(vm, mode, &.{ .not, .eq, .ne });
        }
    };
    try expectProgramTuned(
        \\local t = {}
        \\for i = 1, 300 do t[i] = (i % 2 == 0) end
        \\local d, e, f = 0, 0, 0
        \\for i = 1, 300 do if t[i] == true then d = d + 1 end end
        \\for i = 1, 300 do if not t[i] then e = e + 1 end end
        \\for i = 1, 300 do if t[i] ~= false then f = f + 1 end end
        \\print(d, e, f)
    , "150\t150\t150\n", .{ .inspect = Inspect.run });
}

test "doc 57: a bool input stored into a bool lane stores the pinned konst (shape F)" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            try expectNativeHolds(vm, mode, &pin_ops);
            if (!executes(mode)) return;
            try testing.expect(countOpOnSlotLoad(vm, .guard_is_true) >= 1);
            try testing.expect(countOpOnSlotLoad(vm, .guard_is_false) >= 1);
            // No store takes the raw input: each stores the konst.
            for (vm.trace.registry.cache.items) |t| {
                for (t.code.instrs) |ins| {
                    if (ins.op != .astore and ins.op != .astore_append) continue;
                    if (ins.aux != @intFromEnum(array.Lane.boolean)) continue;
                    try testing.expect(t.code.instrs[ins.b].op != .slot_load);
                }
            }
        }
    };
    try expectProgramTuned(
        \\local p, q = {}, {}
        \\local yes, no = true, false
        \\for i = 1, 300 do p[i] = yes end
        \\for i = 1, 300 do q[i] = false end
        \\for i = 1, 300 do q[i] = no end
        \\local n = 0
        \\for i = 1, 300 do if p[i] and not q[i] then n = n + 1 end end
        \\print(n)
    , "300\n", .{ .inspect = Inspect.run });
}

test "doc 57: equality folds on pinned inputs (x == nil, x == 1, x == 's', bool == bool)" {
    try expectProgram(
        \\local flag, z = true, nil
        \\local a, b, c, d, e = 0, 0, 0, 0, 0
        \\for i = 1, 300 do
        \\  if flag == nil then a = a + 1 end
        \\  if flag ~= 1 then b = b + 1 end
        \\  if flag == "s" then c = c + 1 end
        \\  if flag == true then d = d + 1 end
        \\  if z == nil then e = e + 1 end
        \\end
        \\print(a, b, c, d, e)
    , "0\t300\t0\t300\t300\n");
}

test "doc 57: a nil input is pinned and folds" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            try expectNativeHolds(vm, mode, &pin_ops);
            if (!executes(mode)) return;
            try testing.expect(countOpOnSlotLoad(vm, .guard_is_nil) >= 1);
        }
    };
    try expectProgramTuned(
        \\local z = nil
        \\local n = 0
        \\for i = 1, 300 do if z then n = n - 1 else n = n + 1 end end
        \\print(n)
    , "300\n", .{ .inspect = Inspect.run });
}

test "doc 57: type/tostring/math.type of a pinned input fold" {
    try expectProgram(
        \\local flag, z = false, nil
        \\local s = ""
        \\for i = 1, 300 do
        \\  s = type(flag) .. tostring(flag) .. type(z) .. tostring(z) .. tostring(math.type(flag))
        \\end
        \\print(s)
    , "booleanfalsenilnilnil\n");
}

test "doc 57: a bool input stored into a hash field and a closed upvalue" {
    try expectProgram(
        \\local function mk()
        \\  local u = false
        \\  return function(v) u = v end, function() return u end
        \\end
        \\local set, get = mk()
        \\local h = { f = false }
        \\local flag = true
        \\local n = 0
        \\for i = 1, 300 do
        \\  h.f = flag
        \\  set(flag)
        \\  if h.f then n = n + 1 end
        \\end
        \\print(n, h.f, get())
    , "300\ttrue\ttrue\n");
}
