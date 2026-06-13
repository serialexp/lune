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
    std.debug.assert(values.len >= t.instrs.len);
    var completed: usize = 0;
    iter: while (true) {
        for (t.instrs, 0..) |ins, i| {
            switch (ins.op) {
                // ---- inputs ----
                .slot_load => values[i] = regs[@intCast(ins.aux)],
                .konst => values[i] = t.consts[@intCast(ins.aux)],

                // ---- arithmetic (same arith.zig as tier-0; error => side-exit) ----
                .add => values[i] = arith.add(values[ins.a], values[ins.b]) catch return completed,
                .sub => values[i] = arith.sub(values[ins.a], values[ins.b]) catch return completed,
                .mul => values[i] = arith.mul(values[ins.a], values[ins.b]) catch return completed,
                .div => values[i] = arith.div(values[ins.a], values[ins.b]) catch return completed,
                .idiv => values[i] = arith.floorDiv(values[ins.a], values[ins.b]) catch return completed,
                .mod => values[i] = arith.mod(values[ins.a], values[ins.b]) catch return completed,
                .pow => values[i] = arith.pow(values[ins.a], values[ins.b]) catch return completed,

                // ---- bitwise ----
                .band => values[i] = arith.band(values[ins.a], values[ins.b]) catch return completed,
                .bor => values[i] = arith.bor(values[ins.a], values[ins.b]) catch return completed,
                .bxor => values[i] = arith.bxor(values[ins.a], values[ins.b]) catch return completed,
                .shl => values[i] = arith.shl(values[ins.a], values[ins.b]) catch return completed,
                .shr => values[i] = arith.shr(values[ins.a], values[ins.b]) catch return completed,

                // ---- unary ----
                .neg => values[i] = arith.neg(values[ins.a]) catch return completed,
                .not => values[i] = Value.boolean(!values[ins.a].isTruthy()),
                .bnot => values[i] = arith.bnot(values[ins.a]) catch return completed,

                // ---- comparisons → boolean (mirror tier-0 exactly) ----
                .eq => values[i] = Value.boolean(arith.eq(values[ins.a], values[ins.b])),
                .ne => values[i] = Value.boolean(!arith.eq(values[ins.a], values[ins.b])),
                .lt => values[i] = Value.boolean(arith.lt(values[ins.a], values[ins.b]) catch return completed),
                .le => values[i] = Value.boolean(arith.le(values[ins.a], values[ins.b]) catch return completed),

                // ---- guards: a mismatch side-exits to tier-0 ----
                .guard_int => if (!values[ins.a].isInt()) return completed,
                .guard_float => if (!values[ins.a].isFloat()) return completed,
                .guard_number => if (!values[ins.a].isNumber()) return completed,
                .guard_true => if (!values[ins.a].isTruthy()) return completed,
                .guard_false => if (values[ins.a].isTruthy()) return completed,

                // ---- close: commit the loop-carried writes, then iterate ----
                .loop => {
                    for (t.exit_stores) |st| regs[st.slot] = values[st.ref];
                    completed += 1;
                    continue :iter;
                },
            }
        }
        // A well-formed trace always terminates in `loop` (checked by the
        // commit-time verifier in trace.zig). If one somehow didn't, stop rather
        // than spin — `regs` is whatever the last commit left, which is coherent.
        return completed;
    }
}
