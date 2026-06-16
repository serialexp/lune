//! Tier-1a trace IR-interpreter — *executes* recorded traces (Phase 6).
//!
//! Phase 5 records hot loops into a linear SSA trace IR (`trace.zig`) but tier-0
//! still does all the work. This module runs that IR directly: given a cached
//! `Trace` and the current frame's register window, it executes the loop body
//! repeatedly, computing into a private SSA value array and writing the tier-0
//! registers back **only** at a clean loop close. On any guard failure (or an
//! arithmetic error) it *side-exits*: it returns, leaving `regs` exactly as they
//! were at the start of the current iteration, and tier-0 resumes at the loop
//! header to re-execute that one partial iteration.
//!
//! ## Why this deopt is sound (loop-header re-entry)
//!
//! The recorder writes loop-carried registers only at the atomic loop close
//! (`trace.zig`'s `commit` emits a slot-bound `phi` for every register the trace
//! *defined*). This executor mirrors that: `regs` is mutated only at the `loop`
//! marker. So at the *start* of every iteration the register file is already a
//! coherent tier-0 state for the loop header. A side-exit mid-iteration therefore
//! needs no per-guard snapshot — discard the SSA scratch, return, and tier-0
//! recomputes the partial iteration from `anchor.pc`. This is correct **because a
//! committed trace contains no side effects**: any `print`/host call aborts
//! recording (`host_barrier`), and tables/globals/calls abort (`nyi_opcode` /
//! `cross_frame`). Re-executing the partial iteration recomputes only pure
//! register values — never a doubled effect. (See docs/design/01-trace-lifecycle.md.)
//!
//! ## Byte-identical results
//!
//! Every arithmetic/comparison op calls the *same* `arith.zig` function tier-0
//! uses — that shared implementation is the guarantee that an executed trace
//! produces output indistinguishable from tier-0 (the `expectProgram` matrix in
//! `interp.zig` is the oracle). i64 arithmetic wraps (never traps, never changes
//! type), so the only mid-trace error possible is integer `//`/`%` by zero, which
//! side-exits and lets tier-0 raise the identical `DivisionByZero`.
//!
//! ## GC
//!
//! `execute` runs **no GC safepoint** — a committed trace allocates nothing, so
//! no collection is ever needed mid-trace. That is exactly what makes the
//! caller-owned `values` scratch safe without rooting it: any live heap value in
//! `values` is also reachable via `regs` (not overwritten until commit) or via
//! the GC-rooted const pool (`trace.zig` consts), and any stale ref left after a
//! side-exit is never dereferenced (linear SSA: every value is recomputed before
//! use on the next entry).

const std = @import("std");
const trace = @import("trace.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const execlog = @import("execlog.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const Value = value.Value;
const Trace = trace.Trace;

/// Execute trace `t` from the current frame's register window `regs`, using the
/// caller-owned `values` scratch (indexed by SSA `Ref`; must be at least
/// `t.instrs.len` long — the caller grows/reuses it). Returns the number of loop
/// iterations that committed cleanly (the *yield*). On return `regs` is coherent
/// for tier-0 to resume at `t.anchor.pc`:
///   * a guard failure / arithmetic error returns with `regs` untouched since the
///     start of the failing iteration (tier-0 re-runs that partial iteration);
///   * a yield of 0 means the very first iteration side-exited (the trace no
///     longer matches the observed types) — the caller uses this for the
///     re-entry penalty.
pub fn execute(t: *const Trace, regs: []Value, values: []Value) usize {
    return executeImpl(false, {}, t, regs, values);
}

/// Instrumented twin of `execute`: identical semantics, but drives `rec`
/// (an `*execlog.ExecLogRecorder`) to record this entry's per-iteration events and
/// its exit ramp for the visualizer. `rec` must already be `begin`-ready (targeted
/// at the trace's log); this calls `begin`/`end` around the run. Used only on the
/// instrumented (viz/CLI) path — `execute` above is the untouched JIT fast path.
pub fn executeTraced(rec: *execlog.ExecLogRecorder, t: *const Trace, regs: []Value, values: []Value) usize {
    return executeImpl(true, rec, t, regs, values);
}

/// The single executor body, `comptime`-specialized over `record`. With
/// `record == false` the `rec` calls are not analyzed (Zig folds the comptime `if`),
/// so `execute` compiles exactly as before — no recorder overhead on the JIT path.
/// With `record == true`, `rec` observes every value, guard outcome, commit, and the
/// terminal side-exit. Recording is observation-only: `regs`/`completed` are
/// byte-identical to the uninstrumented run (the parity canary test asserts this).
fn executeImpl(comptime record: bool, rec: anytype, t: *const Trace, regs: []Value, values: []Value) usize {
    std.debug.assert(values.len >= t.instrs.len);
    if (record) rec.begin();
    var completed: usize = 0;
    const completed_out = iter: while (true) {
        for (t.instrs, 0..) |ins, i| {
            switch (ins.op) {
                // ---- inputs ----
                .slot_load => {
                    values[i] = regs[@intCast(ins.aux)];
                    if (record) rec.value(i, values[i]);
                },
                .konst => {
                    values[i] = t.consts[@intCast(ins.aux)];
                    if (record) rec.value(i, values[i]);
                },

                // ---- loop-carried value (φ) ----
                // A slot-bound φ reads its register every iteration — identical to
                // the `slot_load` it replaces, because the carry round-trips through
                // `regs[slot]` (tier-0 seeds it on entry; the `.loop` flush updates it
                // thereafter). An *internal* φ (no backing register) takes its init on
                // the first iteration and keeps the value the back-edge carried into it
                // on every subsequent one.
                .phi => {
                    if (ins.aux == trace.PHI_INTERNAL) {
                        if (completed == 0) values[i] = values[@intCast(ins.a)];
                        // else: retain the value the previous `.loop` carried in.
                        // An internal φ is a real computed scalar the body consumes
                        // (e.g. SR's `denom`); log it like any other value.
                        if (record) rec.value(i, values[i]);
                    } else {
                        // A slot-bound φ is loop-carry bookkeeping — exactly what the
                        // old `exit_stores` list was. The body reads the register via
                        // its `slot_load`, never this φ node, so the φ value is dead
                        // except as the back-edge writeback. Emit NO exec-log value
                        // event (the old exit_store produced none): keeping no-op
                        // parity AND ensuring a carried *heap* slot never feeds the
                        // scalar-only exec-log encoder (`UnsupportedEffectResult`).
                        values[i] = regs[@intCast(ins.aux)];
                    }
                },

                // ---- arithmetic / bitwise / comparisons → the shared evaluator
                //      (`evalBinary`, the *same* code the optimizer folds with).
                //      Any error (only integer //- or %-by-zero is reachable; see
                //      arith.zig) side-exits to tier-0, which re-raises it. ----
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .eq, .ne, .lt, .le => {
                    values[i] = evalBinary(ins.op, values[ins.a], values[ins.b]) catch {
                        if (record) rec.exit(i, .arith, Value.nil());
                        break :iter completed;
                    };
                    if (record) rec.value(i, values[i]);
                },

                // ---- unary (shared evaluator too) ----
                .neg, .not, .bnot => {
                    values[i] = evalUnary(ins.op, values[ins.a]) catch {
                        if (record) rec.exit(i, .arith, Value.nil());
                        break :iter completed;
                    };
                    if (record) rec.value(i, values[i]);
                },

                // ---- guards: a mismatch side-exits to tier-0 ----
                .guard_int => if (values[ins.a].isInt()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter completed;
                },
                .guard_float => if (values[ins.a].isFloat()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter completed;
                },
                .guard_number => if (values[ins.a].isNumber()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter completed;
                },
                .guard_true => if (values[ins.a].isTruthy()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter completed;
                },
                .guard_false => if (!values[ins.a].isTruthy()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter completed;
                },

                // ---- lane-aware packed-array read path (Phase B) ----
                //
                // `aref` carries no usable Value — it only pairs (table, index)
                // for the `aload`/guards that reference it. Store nil so the SSA
                // slot is defined; it is never read *as a value*.
                .aref => {
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },
                // Decode the packed slot to a logical Value via the *exact* tier-0
                // reader (`Table.getInt`), so an executed trace reads byte-identical
                // to tier-0 by construction. By the time we run, `guard_bounds` and
                // `guard_present` have already passed, so this hits the array fast
                // path and returns a present element (never a hash fallback / nil).
                .aload => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    values[i] = tbl.getInt(values[ar.b].asInt());
                    if (record) rec.value(i, values[i]);
                },
                // `astore` — the FIRST mid-iteration heap mutation in the system
                // (see docs/design/02-determinism.md). Encode `b` into the packed
                // slot addressed by the `aref` in `a`. By the time we run, the
                // store has been recorded only for an in-bounds (`guard_bounds`)
                // in-lane (`guard_lane`) value, so the in-place encode neither
                // grows nor widens nor allocates. `astore` produces no value; store
                // nil so the SSA slot is defined but it is never read as a value.
                .astore => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    tbl.array.setInLane(@intCast(values[ar.b].asInt()), values[ins.b]);
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },
                // The slot holds a heap table.
                .guard_table => if (values[ins.a].isHeap() and values[ins.a].heapType() == .table) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter completed;
                },
                // The table's array lane still equals the recorded lane (a
                // monotonic widen would have moved it past `aux`).
                .guard_lane => {
                    const tbl = table.Table.fromHeader(values[ins.a].asHeap());
                    if (@intFromEnum(tbl.array.lane) == ins.aux) {
                        if (record) rec.guardPass(i, values[ins.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ins.a]);
                        break :iter completed;
                    }
                },
                // The index lands in the dense array part: `(index-1) <u len`.
                .guard_bounds => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    const idx = values[ar.b].asInt();
                    if (idx >= 1 and idx <= @as(i64, @intCast(tbl.array.len))) {
                        if (record) rec.guardPass(i, values[ar.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ar.a]);
                        break :iter completed;
                    }
                },
                // The slot is present (a narrow-lane hole would read as nil, which
                // the native int/bool path cannot represent).
                .guard_present => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    if (!tbl.getInt(values[ar.b].asInt()).isNil()) {
                        if (record) rec.guardPass(i, values[ar.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ar.a]);
                        break :iter completed;
                    }
                },
                // The value still fits the recorded int lane (emitted before an
                // int-lane `astore`). An out-of-range / non-int value would force a
                // tier-0 lane widen, which neither this in-place encode nor the
                // native store can do — so side-exit and let tier-0 re-run + widen.
                .guard_fits => {
                    const lane: arr.Lane = @enumFromInt(ins.aux);
                    if (arr.ArrayPart.laneFits(lane, values[ins.a])) {
                        if (record) rec.guardPass(i, values[ins.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ins.a]);
                        break :iter completed;
                    }
                },

                // ---- close: commit the loop-carried writes, then iterate ----
                .loop => {
                    // φ writeback: a slot-bound φ flushes its update to the register
                    // (the carry tier-0 resumes from); an internal φ refreshes its own
                    // carried scratch so the next iteration retains it.
                    for (t.instrs, 0..) |p, pi| {
                        if (p.op != .phi) continue;
                        if (p.aux == trace.PHI_INTERNAL) {
                            values[pi] = values[@intCast(p.b)];
                        } else {
                            regs[@intCast(p.aux)] = values[@intCast(p.b)];
                        }
                    }
                    completed += 1;
                    if (record) rec.commit();
                    continue :iter;
                },
            }
        }
        // A well-formed trace always terminates in `loop` (checked by the
        // commit-time verifier in trace.zig). If one somehow didn't, stop rather
        // than spin — `regs` is whatever the last commit left, which is coherent.
        break :iter completed;
    };
    if (record) rec.end(completed_out);
    return completed_out;
}

/// Evaluate a binary IR op (arithmetic / bitwise / comparison) over two values,
/// using the *exact* `arith.zig` functions tier-0 uses. This is the single
/// evaluator shared by the executor (above) and the trace optimizer's constant
/// folder (`tropt.zig`) — so a folded constant has byte-identical bits to what
/// the executor would compute at runtime, by construction. It is **total**: it
/// only ever returns `arith.Error` (`TypeError` / `DivisionByZero`), never traps
/// (arith.zig wraps integer ops and masks shift counts), so the folder can call
/// it on any constants and merely refuse to fold on error. `op` must be one of
/// the binary ops in the `execute` switch above (else unreachable).
pub fn evalBinary(op: trace.IrOp, a: Value, b: Value) arith.Error!Value {
    return switch (op) {
        .add => arith.add(a, b),
        .sub => arith.sub(a, b),
        .mul => arith.mul(a, b),
        .div => arith.div(a, b),
        .idiv => arith.floorDiv(a, b),
        .mod => arith.mod(a, b),
        .pow => arith.pow(a, b),
        .band => arith.band(a, b),
        .bor => arith.bor(a, b),
        .bxor => arith.bxor(a, b),
        .shl => arith.shl(a, b),
        .shr => arith.shr(a, b),
        .eq => Value.boolean(arith.eq(a, b)),
        .ne => Value.boolean(!arith.eq(a, b)),
        .lt => Value.boolean(try arith.lt(a, b)),
        .le => Value.boolean(try arith.le(a, b)),
        else => unreachable,
    };
}

/// Evaluate a unary IR op (`neg`/`not`/`bnot`). Shared by the executor and the
/// folder, same contract as `evalBinary`. `not` is defined over Lua truthiness
/// (no type guard, like tier-0). `op` must be a unary op (else unreachable).
pub fn evalUnary(op: trace.IrOp, a: Value) arith.Error!Value {
    return switch (op) {
        .neg => arith.neg(a),
        .not => Value.boolean(!a.isTruthy()),
        .bnot => arith.bnot(a),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Tests — the lane-aware packed-array READ path (Phase B2).
//
// Native codegen auto-bails on any `aref`-bearing trace (`proveKinds` rejects
// the unknown ops), so B2 has no tier-1a-vs-tier-1b comparison yet — that is
// B2c. These hand-built traces validate the *oracle*: that `irinterp.execute`
// reads `t[k]` byte-identically to the tier-0 reader (`Table.getInt`), with the
// read guards (`guard_table`/`guard_lane`/`guard_bounds`/`guard_present`)
// side-exiting exactly when tier-0 would diverge.
// ---------------------------------------------------------------------------

const testing = std.testing;
const IrInstr = trace.IrInstr;
const IrOp = trace.IrOp;
const Table = table.Table;

/// Build a single-anchor trace that scans `t[r1], t[r1+1], …` accumulating into
/// registers, terminating when an index runs past the dense run. Register window:
///   r0 = table · r1 = running index · r2 = last value loaded
/// Each iteration:
///   load+guard the table, `aref` the current index, bounds/present-guard it,
///   `aload` the slot, advance the index by 1, commit (value→r2, index+1→r1).
/// A side-exit (bounds/present miss) leaves `regs` at the last clean commit — so
/// `completed` is the number of present in-bounds slots scanned, exactly what a
/// tier-0 re-run would reproduce.
fn scanTrace(lane_ord: i32) [13]IrInstr {
    return .{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0 (table)
        .{ .op = .guard_table, .a = 0 }, // %1 = guard %0 is a table
        .{ .op = .guard_lane, .a = 0, .aux = lane_ord }, // %2 = guard lane
        .{ .op = .slot_load, .aux = 1 }, // %3 = r1 (index)
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane_ord }, // %4 = &t[index]
        .{ .op = .guard_bounds, .a = 4 }, // %5 = guard (index-1) <u len
        .{ .op = .guard_present, .a = 4 }, // %6 = guard slot present
        .{ .op = .aload, .a = 4, .aux = lane_ord }, // %7 = t[index]
        .{ .op = .konst, .aux = 0 }, // %8 = 1
        .{ .op = .add, .a = 3, .b = 8 }, // %9 = index + 1
        // Loop-carried writebacks as slot-bound φ: advance r1 (index+1) and stash
        // r2 (the loaded value). These subsume what `exit_stores` listed.
        .{ .op = .phi, .a = 0, .b = 9, .aux = 1 }, // %10: r1 ← %9
        .{ .op = .phi, .a = 0, .b = 7, .aux = 2 }, // %11: r2 ← %7
        .{ .op = .loop }, // %12
    };
}

const scan_consts = [_]Value{Value.int(1)};

fn runScan(t: *Table, start: i64) struct { completed: usize, regs: [3]Value } {
    var instrs = scanTrace(@intFromEnum(t.array.lane));
    const tr = Trace{
        .anchor = undefined,
        .instrs = &instrs,
        .consts = @constCast(scan_consts[0..]),
        .entry_slots = &[_]u16{},
    };
    var regs = [3]Value{ Value.heap(&t.header), Value.int(start), Value.nil() };
    var values: [13]Value = undefined;
    const completed = execute(&tr, &regs, &values);
    return .{ .completed = completed, .regs = regs };
}

test "B2 read path: scan a bool lane matches tier-0 getInt, hole/bounds side-exit" {
    const gpa = testing.allocator;
    const t = try Table.create(gpa);
    defer t.destroy(gpa);

    // nsieve's sieve: p[2..K] = true, all booleans → a narrow boolean lane.
    const K: i64 = 64;
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(@import("array.zig").Lane.boolean, t.array.lane);

    // Start at 2 (the first present slot): the scan runs to the end of the dense
    // run, side-exiting when the index passes `len`.
    const from2 = runScan(t, 2);
    try testing.expectEqual(@as(usize, @intCast(K - 1)), from2.completed); // indices 2..K
    try testing.expect(from2.regs[2].isBool() and from2.regs[2].asBool() == true); // last load
    // Re-entry coherence: r1 sits one past the last committed index (= K+1),
    // exactly where tier-0 resumes the partial (out-of-bounds) iteration.
    try testing.expectEqual(@as(i64, K + 1), from2.regs[1].asInt());
    // Every loaded value equals the tier-0 reader, by construction.
    i = 2;
    while (i <= K) : (i += 1) try testing.expect(t.getInt(i).asBool() == true);

    // Start at 1: key 1 is a hole (a narrow-lane absent slot) — `guard_present`
    // side-exits on the very first iteration, mirroring tier-0 reading nil there.
    const from1 = runScan(t, 1);
    try testing.expectEqual(@as(usize, 0), from1.completed);
    try testing.expect(from1.regs[1].asInt() == 1); // regs untouched (no clean commit)
    try testing.expect(from1.regs[2].isNil());

    // Start past the dense run: `guard_bounds` side-exits immediately.
    const fromHi = runScan(t, K + 5);
    try testing.expectEqual(@as(usize, 0), fromHi.completed);
}

test "E0 review: a slot-bound φ carrying a HEAP value emits no exec-log value event" {
    // Regression (E0 review, Antigravity P0): a slot-bound φ executes mid-trace and
    // reads its register. The old `exit_stores` carry emitted NO exec-log value
    // event; the φ must match that — otherwise a loop-carried *heap* slot would feed
    // the scalar-only exec-log encoder a heap Value (`UnsupportedEffectResult`).
    const gpa = testing.allocator;
    const t = try Table.create(gpa);
    defer t.destroy(gpa);

    // r0 = a heap table (write-only: overwritten with int 5 each iteration).
    // r2 = a guard counter (1 → 0) so iteration 2's `5 // r2` divides by zero and
    // side-exits, after exactly one clean commit in which the φ carried the table.
    var instrs = [_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 5      (the new r0 value)
        .{ .op = .slot_load, .aux = 2 }, // %1 = r2  (counter)
        .{ .op = .konst, .aux = 1 }, // %2 = 1
        .{ .op = .idiv, .a = 0, .b = 1 }, // %3 = 5 // r2 → DivByZero on iter 2 (exit)
        .{ .op = .sub, .a = 1, .b = 2 }, // %4 = r2 - 1
        .{ .op = .phi, .a = 0, .b = 0, .aux = 0, .ty = .heap }, // %5: r0 ← %0 (carries HEAP iter 1)
        .{ .op = .phi, .a = 0, .b = 4, .aux = 2, .ty = .int }, // %6: r2 ← %4
        .{ .op = .loop }, // %7
    };
    const consts = [_]Value{ Value.int(5), Value.int(1) };
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = @constCast(consts[0..]), .entry_slots = &[_]u16{} };

    var rec = execlog.ExecLogRecorder.init(gpa, 64, 8);
    defer rec.deinit();
    var log = execlog.TraceExecLog{ .trace_id = 0 };
    defer log.deinit(gpa);
    rec.retarget(&log);

    var regs = [3]Value{ Value.heap(&t.header), Value.nil(), Value.int(1) };
    var values: [8]Value = undefined;
    const completed = executeTraced(&rec, &tr, &regs, &values);

    // Exactly one clean commit (iter 1), then the divide-by-zero side-exit on iter 2.
    try testing.expectEqual(@as(usize, 1), completed);
    try testing.expectEqual(@as(i64, 5), regs[0].asInt()); // carry flushed r0 ← 5

    // The crux: NO recorded event carries a heap value, so serialization can't hit
    // `UnsupportedEffectResult`. (The φ at %5 read the heap table but logged nothing.)
    try testing.expectEqual(@as(usize, 1), log.entries.items.len);
    for (log.entries.items[0].events) |ev| try testing.expect(!ev.value.isHeap());
}

test "B2 read path: guard_table side-exits when the slot is not a table" {
    const gpa = testing.allocator;
    const t = try Table.create(gpa);
    defer t.destroy(gpa);
    try t.set(gpa, Value.int(1), Value.boolean(true));
    try t.set(gpa, Value.int(2), Value.boolean(true));

    var instrs = scanTrace(@intFromEnum(t.array.lane));
    const tr = Trace{
        .anchor = undefined,
        .instrs = &instrs,
        .consts = @constCast(scan_consts[0..]),
        .entry_slots = &[_]u16{},
    };
    // r0 is an int, not a table → guard_table fails on the first iteration.
    var regs = [3]Value{ Value.int(99), Value.int(1), Value.nil() };
    var values: [13]Value = undefined;
    try testing.expectEqual(@as(usize, 0), execute(&tr, &regs, &values));
    try testing.expect(regs[0].asInt() == 99); // untouched
}
