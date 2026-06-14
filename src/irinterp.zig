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
//! (`trace.zig`'s `commit` fills `exit_stores` from every register the trace
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

                // ---- close: commit the loop-carried writes, then iterate ----
                .loop => {
                    for (t.exit_stores) |st| regs[st.slot] = values[st.ref];
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
