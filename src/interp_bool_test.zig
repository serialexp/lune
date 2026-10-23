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

/// Nothing committed carries a contradicted pin: every pinned slot's
/// slot-bound φ, if its update is a konst, carries exactly the pin.
fn expectPinsCarryTheirPin(vm: *Vm) !void {
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

fn countAborts(vm: *Vm, reason: anytype) usize {
    var n: usize = 0;
    for (vm.trace.abort_log.items) |r| {
        if (r.reason == reason) n += 1;
    }
    return n;
}

/// The committed trace with the most extra iterations (doc 57 P3), or null.
fn mostUnrolled(vm: *Vm) ?*const @import("trace.zig").Trace {
    var best: ?*const @import("trace.zig").Trace = null;
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.instunrolled == 0) continue;
        if (best == null or t.code.instunrolled > best.?.code.instunrolled) best = t;
    }
    return best;
}

/// Doc 57 P3 / doc 58: how the copies of an unrolled trace's own loop test are
/// classified.
///  * `flush` — guards that owe the final-iteration flush and drive a resume
///    (`isNumericForLoopDoneGuard`). EXACTLY ONE per unrolled trace: a mid-trip
///    copy classified here would resume after the loop with the trip-start
///    registers and lose the iterations before it (doc 57 P3's hazard).
///  * `own` — guards the structural "this is my loop's test" classifier takes
///    (`isOwnLoopTest`, doc 58). It deliberately matches EVERY copy, because a
///    copy has the same source instruction and its consumers only ever REFUSE
///    things for it (side-trace hotness, prime-side wants, sibling handoffs,
///    legacy strikes) — none of them resumes anywhere, so matching a copy is
///    conservative, not a hazard.
///  * `copies` — mid-trip copies carrying `GuardRole.loop_test_copy`
///    (`isLoopTestCopy`). Doc 58: only numeric `for` copies still carry the
///    role; a `while` condition copy needs none, because the classifier that
///    the role protected (the top-of-trace while-done) is gone.
///  * `branch` — own-loop-test guards a source-branch consumer would take
///    (must stay 0: no prime-side want and no sibling handoff may grow from
///    any copy of a loop's own test).
const LoopTests = struct { flush: usize = 0, own: usize = 0, copies: usize = 0, branch: usize = 0 };

fn loopTests(vm: *Vm, t: *const @import("trace.zig").Trace, src_op: @import("bytecode.zig").OpCode) LoopTests {
    var out: LoopTests = .{};
    for (t.code.instrs, 0..) |ins, i| {
        if (ins.op != .guard_true) continue;
        const src = t.code.anchorSourceInstr(i) orelse continue;
        if (src.op != src_op) continue;
        if (t.code.isNumericForLoopDoneGuard(i)) out.flush += 1;
        if (t.code.isLoopTestCopy(i)) out.copies += 1;
        if (t.code.isOwnLoopTest(i)) {
            out.own += 1;
            if (vm.trace.isSourceBranchGuardExit(t, @intCast(i))) out.branch += 1;
        }
    }
    return out;
}

test "doc 57 P3: a flipped carried bool unrolls into one two-iteration trace (shape B)" {
    // Odd and even trip counts, both entry polarities: an odd count ends the
    // loop at iteration 1's `for` test, which sits mid-trip and must resume
    // by replaying the trip in tier-0 (not by the loop-done flush).
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try expectPinsCarryTheirPin(vm);
            // The close no longer aborts: it records another iteration.
            try testing.expectEqual(@as(usize, 0), countAborts(vm, .type_instability));
            if (!executes(mode)) return;
            const t = mostUnrolled(vm) orelse return error.TestExpectedUnrolledTrace;
            try testing.expectEqual(@as(u8, 1), t.code.instunrolled);
            // Two `for_loop` tests: only the last owes the flush, the first is
            // a mid-trip copy that no branch consumer takes. Both are the
            // loop's own test structurally (doc 58).
            const lt = loopTests(vm, t, .for_loop);
            try testing.expectEqual(LoopTests{ .flush = 1, .own = 2, .copies = 1, .branch = 0 }, lt);
            try expectNativeHolds(vm, mode, &pin_ops);
        }
    };
    try expectProgramTuned(
        \\local function run(n, b)
        \\  local m = 0
        \\  for i = 1, n do b = not b; if b then m = m + 1 end end
        \\  return m
        \\end
        \\print(run(300, false), run(301, false), run(301, true), run(7, false), run(40, true))
    , "150\t151\t150\t4\t20\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 57 P3: an unrolled while's mid-trip condition copies owe no resume" {
    // Iteration 2's condition sits mid-trip. Under doc 38 it could be claimed
    // by the top-of-trace while-done classifier and would then resume after the
    // loop with the trip-start registers, losing iteration 1 (odd counts end
    // there). Doc 58 removes that classifier: no `while` condition guard drives
    // a resume any more, so `flush` is 0 for every copy.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            const t = mostUnrolled(vm) orelse return error.TestExpectedUnrolledTrace;
            try testing.expectEqual(@as(u8, 1), t.code.instunrolled);
            // Doc 58: a `while` condition owes NO flush on any copy (its exit is
            // ordinary), both copies ARE the loop's own test structurally, and
            // neither needs the `.loop_test_copy` role any more. `i < n` is
            // one compare-and-branch (doc 66 P4).
            const lt = loopTests(vm, t, .jlt);
            try testing.expectEqual(LoopTests{ .flush = 0, .own = 2, .copies = 0, .branch = 0 }, lt);
            try expectNativeHolds(vm, mode, &pin_ops);
        }
    };
    try expectProgramTuned(
        \\local function run(n, b)
        \\  local m, i = 0, 0
        \\  while i < n do i = i + 1; b = not b; if b then m = m + 1 end end
        \\  return m
        \\end
        \\print(run(300, false), run(301, false), run(301, true), run(7, false), run(40, true))
    , "150\t151\t150\t4\t20\n", .{ .inspect = Inspect.run });
}

test "doc 57 P3: a nested unrolled while whose loop ends mid-trip chains correctly" {
    // The inner while's trip count varies (5..8) and code follows it, so its
    // loop-done exits CHAIN to a continuation at the post-loop pc. Mutation
    // (checked): with iteration 2's condition classified as the doc 38
    // while-done, that chain resumes after the loop with the trip-start
    // registers and prints 15023 / 14951 instead of 15600.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            try testing.expect(mostUnrolled(vm) != null);
        }
    };
    try expectProgramTuned(
        \\local b = false
        \\local total = 0
        \\for j = 1, 400 do
        \\  local m, i = 0, 0
        \\  local n = 5 + (j % 4)
        \\  while i < n do i = i + 1; b = not b; if b then m = m + 1 end end
        \\  total = total + m * 10 + i
        \\end
        \\print(total)
    , "15600\n", .{ .hotloop = 56, .inspect = Inspect.run });
}

test "doc 57 P3: a nested unrolled for whose loop ends mid-trip chains correctly" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            try testing.expect(mostUnrolled(vm) != null);
        }
    };
    try expectProgramTuned(
        \\local b = false
        \\local total = 0
        \\for j = 1, 400 do
        \\  local m, k = 0, 0
        \\  local n = 5 + (j % 4)
        \\  for i = 1, n do k = i; b = not b; if b then m = m + 1 end end
        \\  total = total + m * 10 + k
        \\end
        \\print(total)
    , "15600\n", .{ .hotloop = 56, .inspect = Inspect.run });
}

test "doc 57 P3: a loop-test copy's exit in link mode resumes the owed trip, not the post-loop pc" {
    // The inner loop unrolls its alternating `b`, so its `for_loop` test has
    // a mid-trip copy. When the trip count is odd that copy fails, an
    // ordinary deopt that still owes the trip's last iteration. The run is
    // in link mode (the inner loop has a continuation), and the chain used
    // to take any such exit as a committed loop-done: it ran the
    // continuation at the post-loop pc and dropped the iteration.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            try testing.expect(mostUnrolled(vm) != null);
        }
    };
    try expectProgramTuned(
        \\local total = 0
        \\for j = 1, 10 do
        \\  local b = false
        \\  local n = j % 5 + 80
        \\  for i = 1, n do
        \\    b = not b
        \\    if b then total = total + i
        \\    else total = total - i end
        \\  end
        \\end
        \\print(total)
    , "-80\n", .{ .inspect = Inspect.run });
}

test "doc 57 P3: a period-3 nil/false/true cycle unrolls twice" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try testing.expectEqual(@as(usize, 0), countAborts(vm, .type_instability));
            if (!executes(mode)) return;
            const t = mostUnrolled(vm) orelse return error.TestExpectedUnrolledTrace;
            try testing.expectEqual(@as(u8, 2), t.code.instunrolled);
            const lt = loopTests(vm, t, .for_loop);
            try testing.expectEqual(LoopTests{ .flush = 1, .own = 3, .copies = 2, .branch = 0 }, lt);
        }
    };
    try expectProgramTuned(
        \\local s = nil
        \\local c = 0
        \\for i = 1, 300 do
        \\  if s == nil then s = false elseif s == false then s = true else s = nil end
        \\  if s then c = c + 1 end
        \\end
        \\print(c)
    , "100\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 57 P3: two flags flipping together unroll once" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try testing.expectEqual(@as(usize, 0), countAborts(vm, .type_instability));
            try expectPinsCarryTheirPin(vm);
            if (!executes(mode)) return;
            const t = mostUnrolled(vm) orelse return error.TestExpectedUnrolledTrace;
            try testing.expectEqual(@as(u8, 1), t.code.instunrolled);
            try expectNativeHolds(vm, mode, &pin_ops);
        }
    };
    try expectProgramTuned(
        \\local b1, b2 = false, true
        \\local m = 0
        \\for i = 1, 301 do
        \\  b1 = not b1; b2 = not b2
        \\  if b1 then m = m + 1 end
        \\  if b2 then m = m + 10 end
        \\end
        \\print(m)
    , "1651\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 57 P3: periods 2 and 3 together (cycle 6) exceed the default budget" {
    // Settling needs 5 extra iterations; `instunroll` = 4 gives up.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try testing.expect(countAborts(vm, .type_instability) >= 1);
            try testing.expect(mostUnrolled(vm) == null);
            try expectPinsCarryTheirPin(vm);
        }
    };
    try expectProgramTuned(
        \\local b, s = false, nil
        \\local c = 0
        \\for i = 1, 300 do
        \\  b = not b
        \\  if s == nil then s = false elseif s == false then s = true else s = nil end
        \\  if b then c = c + 1 end
        \\  if s then c = c + 100 end
        \\end
        \\print(c)
    , "10150\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 57 P3: an unrolled while with a compound condition" {
    // `i < n and flag`: the short-circuit branch targets the end of the
    // condition, not the loop exit, so only the final test is the loop's own.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            try testing.expect(mostUnrolled(vm) != null);
        }
    };
    try expectProgramTuned(
        \\local function run(n, b, flag)
        \\  local m, i = 0, 0
        \\  while i < n and flag do i = i + 1; b = not b; if b then m = m + 1 end end
        \\  return m
        \\end
        \\print(run(300, false, true), run(301, false, true), run(7, true, true), run(5, false, false))
    , "150\t151\t3\t0\n", .{ .inspect = Inspect.run });
}

test "doc 57 P3: a cycle longer than the budget aborts as before" {
    // Budget 1: the period-3 cycle needs 2 extra iterations.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try testing.expect(countAborts(vm, .type_instability) >= 1);
            try testing.expect(mostUnrolled(vm) == null);
            try expectPinsCarryTheirPin(vm);
        }
    };
    try expectProgramTuned(
        \\local s = nil
        \\local c = 0
        \\for i = 1, 300 do
        \\  if s == nil then s = false elseif s == false then s = true else s = nil end
        \\  if s then c = c + 1 end
        \\end
        \\print(c)
    , "100\n", .{ .record_aborts = true, .instunroll = 1, .inspect = Inspect.run });
}

test "doc 57 P3: budget 0 is the pre-P3 abort (shape B)" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try testing.expect(countAborts(vm, .type_instability) >= 1);
            try testing.expect(mostUnrolled(vm) == null);
            try expectPinsCarryTheirPin(vm);
        }
    };
    try expectProgramTuned(
        \\local b = false
        \\local m = 0
        \\for i = 1, 300 do b = not b; if b then m = m + 1 end end
        \\print(m)
    , "150\n", .{ .record_aborts = true, .instunroll = 0, .inspect = Inspect.run });
}

test "doc 57 P3: a pin defeat next to an int/float defeat does not unroll" {
    // `x` enters int and carries float on alternate iterations: another
    // iteration cannot settle an int/float contradiction (Bart: unroll on
    // pin defeats only), so the close aborts without unrolling.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode == .off) return;
            try testing.expect(countAborts(vm, .type_instability) >= 1);
            try testing.expect(mostUnrolled(vm) == null);
        }
    };
    try expectProgramTuned(
        \\local b = false
        \\local x, y = 1, 0
        \\for i = 1, 300 do
        \\  y = y + x
        \\  b = not b
        \\  if b then x = 1 else x = 1.5 end
        \\end
        \\print(y)
    , "374.5\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 57 P3: iteration 2 reads a field iteration 1 stored, and exits after it" {
    // `acc.v` is read-modify-written in both iterations (one sunk store per
    // iteration, forwarded to iteration 2's read). `u[i]` turns float once,
    // failing a guard in whichever iteration reads it: tier-0 replays the
    // trip from its start, so neither sunk store may have landed.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (!executes(mode)) return;
            const t = mostUnrolled(vm) orelse return error.TestExpectedUnrolledTrace;
            try testing.expectEqual(@as(u8, 1), t.code.instunrolled);
        }
    };
    try expectProgramTuned(
        \\local u = {}
        \\for i = 1, 400 do u[i] = 1 end
        \\u[333] = 1.5
        \\local acc = { v = 0 }
        \\local b = false
        \\for i = 1, 400 do
        \\  b = not b
        \\  if b then acc.v = acc.v + u[i] else acc.v = acc.v + 2 * u[i] end
        \\end
        \\print(acc.v)
    , "600.5\n", .{ .inspect = Inspect.run });
}

test "doc 57 P3: array stores in both iterations stay correct" {
    // Iteration 2 reads `t[i - 1]` that iteration 1 stored. Today the
    // recorder cannot prove the keys equal (the `for` step is a register
    // load, not a konst) and aborts `store_fwd_ambiguity`; whatever it does,
    // every tier must agree.
    try expectProgram(
        \\local t, u = {}, {}
        \\for i = 1, 400 do t[i] = 0; u[i] = 1 end
        \\u[333] = 1.5
        \\local b = false
        \\for i = 2, 400 do
        \\  b = not b
        \\  if b then t[i] = t[i - 1] + u[i] else t[i] = t[i - 1] + 2 * u[i] end
        \\end
        \\print(t[400], t[200])
    , "599\t298\n");
}

test "doc 57 P3: a flipping loop inside a function called from a traced loop" {
    // The callee's loop gets its own (unrolled) root; the caller's recording
    // meets it inlined, where no unroll decision is ever taken.
    try expectProgram(
        \\local function f(n, b)
        \\  local m = 0
        \\  for i = 1, n do b = not b; if b then m = m + 1 end end
        \\  return m
        \\end
        \\local s = 0
        \\for j = 1, 200 do s = s + f(3, j % 2 == 0) end
        \\print(s)
    , "300\n");
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
            // to abort `bad_type`), and `not t[i]` as a value a dynamic
            // `not` (as a test it is the load's branch flipped, doc 66).
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
        \\for i = 1, 300 do local n = not t[i] if n then e = e + 1 end end
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
