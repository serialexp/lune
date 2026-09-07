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
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const Trace = trace_code.TraceCode;
const ir_eval = @import("ir_eval.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const execlog = @import("execlog.zig");
const table = @import("table.zig");
const function = @import("function.zig");
const arr = @import("array.zig");
const fmath = @import("fmath.zig");
const gc = @import("gc.zig");
const stralloc = @import("stralloc.zig");
const string_mod = @import("string.zig");
const string_std = @import("stdlib/string.zig");
const Value = value.Value;

// Private aliases keep the executor implementation concise without re-exporting
// the shared contract from this backend module. Callers import `trace_exec.zig`.
const trace_exec = @import("trace_exec.zig");
const ExecResult = trace_exec.ExecResult;

// [doc 30 §6 named coupling] The tier-1a flush below and nativegen's
// `emitLinkedLoopDoneSnapshot` enumerate the same closed sunk-store inventory.
// The shared eligibility gate is owned by
// `TraceCode.loopDoneSnapshotSupported`; both tiers must consult it.

/// Commit the final numeric-`for` iteration at a loop-done side exit so a linked
/// continuation can start at the post-loop PC without tier-0 replaying that
/// iteration. This is deliberately not part of ordinary `execute`: normal deopt
/// still resumes at the loop header with `regs` untouched.
pub fn flushNumericForLoopDone(t: *const Trace, regs: RegWindow, values: []Value, exit_instr: u32) bool {
    if (exit_instr == std.math.maxInt(u32) or exit_instr >= t.instrs.len) return false;
    const guard = t.instrs[exit_instr];
    if (guard.op != .guard_true) return false;
    const exit_pc = trace_ir.guardExitPc(guard) orelse return false;
    if (exit_pc == 0 or exit_pc > t.anchor.proto.code.len) return false;
    const for_ins = t.anchor.proto.code[trace_ir.guardSourcePc(guard).?];
    if (for_ins.op != .for_loop) return false;
    // Doc 37: reject inlined-callee `for_loop` guards — their `guardSourcePc` is
    // in the callee's proto, not the anchor's. A coincidental pc match would flush
    // the wrong stores.
    if (t.provAt(exit_instr)) |prov| switch (prov) {
        .guard => |gp| if (gp.inline_depth > 0) return false,
        .link_terminal => return false,
    };
    if (!t.loopDoneSnapshotSupported(exit_instr)) return false;

    var si: usize = @intCast(exit_instr + 1);
    while (si < t.instrs.len) : (si += 1) {
        const p = t.instrs[si];
        switch (p.op) {
            .astore => {
                const ar = t.instrs[p.a];
                const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                tbl.array.setInLane(@intCast(values[ar.b].asInt()), values[p.b]);
            },
            .hstore => {
                const hr = t.instrs[p.a];
                const tbl = table.Table.fromHeader(values[hr.a].asHeap());
                tbl.fieldPtr(values[hr.b]).?.* = values[p.b];
            },
            .gstore => {
                // Defensive only today. A linked source-level 2D-grid nest
                // (`m[i][j] = m[i][j] + k`) aborts recording at the fused
                // `get_index2`/`set_index2` opcode before any continuation link is
                // committed, so no linked loop-done flush can currently contain a
                // `gstore`. Keep the commit path functional for the future recorder
                // work that makes fused grid stores linkable.
                const gcell = t.instrs[p.a];
                const ga = t.instrs[gcell.a];
                const tbl = table.Table.fromHeader(values[ga.a].asHeap());
                const row: usize = @intCast(values[ga.b].asInt() - 1);
                const col: usize = @intCast(values[gcell.b].asInt() - 1);
                tbl.array.gridSet(row, col, values[p.b]);
            },
            .phi, .loop, .link => break,
            else => {},
        }
    }

    const visible_var_slot: i32 = @as(i32, @intCast(for_ins.a)) + 3;
    for (t.instrs, 0..) |p, pi| {
        if (p.op != .phi) continue;
        if (p.aux == trace_ir.PHI_INTERNAL) {
            values[pi] = values[@intCast(p.b)];
        } else if (p.aux != visible_var_slot) {
            regs.set(@intCast(p.aux), values[@intCast(p.b)]);
        }
    }
    return true;
}

/// Execute trace `t` from the current frame's register window `regs`, using the
/// caller-owned `values` scratch (indexed by SSA `Ref`; must be at least
/// `t.instrs.len` long — the caller grows/reuses it). Returns `ExecResult` with
/// the number of loop iterations that committed cleanly and, on failure, the
/// index of the failing instruction.
///   * a guard failure / arithmetic error returns with `regs` untouched since the
///     start of the failing iteration (tier-0 re-runs that partial iteration);
///   * a yield of 0 means the very first iteration side-exited (the trace no
///     longer matches the observed types) — the caller uses this for the
///     re-entry penalty.
pub fn execute(t: *const Trace, regs: RegWindow, values: []Value) ExecResult {
    return executeImpl(false, {}, .{}, t, regs, values);
}

/// Doc 24 D5: the executor's VM-side context — what the allocating `.alloc` op
/// arms and the `guard_gc` budget guard need from the host. Injected per call
/// (Rule Z-4: no global heap); the bare default (`.{}`) means "no VM attached"
/// and every allocating arm then fails CLOSED (side-exit) — a hand-built test
/// trace without a heap can never allocate.
pub const ExecCtx = struct {
    heap: ?*gc.Heap = null,
};

/// `execute` with a VM context attached (doc 24): required for traces that
/// contain `.alloc` ops / `guard_gc` — the arms read `ctx.heap` for the
/// budget predicate and the interning bodies. The production dispatcher and
/// the chain driver pass the real heap; `execute` above is the bare twin.
pub fn executeCtx(ctx: ExecCtx, t: *const Trace, regs: RegWindow, values: []Value) ExecResult {
    return executeImpl(false, {}, ctx, t, regs, values);
}

/// Instrumented twin of `executeCtx` (see `executeTraced`).
pub fn executeTracedCtx(ctx: ExecCtx, rec: *execlog.ExecLogRecorder, t: *const Trace, regs: RegWindow, values: []Value) ExecResult {
    return executeImpl(true, rec, ctx, t, regs, values);
}

/// Instrumented twin of `execute`: identical semantics, but drives `rec`
/// (an `*execlog.ExecLogRecorder`) to record this entry's per-iteration events and
/// its exit ramp for the visualizer. `rec` must already be `begin`-ready (targeted
/// at the trace's log); this calls `begin`/`end` around the run. Used only on the
/// instrumented (viz/CLI) path — `execute` above is the untouched JIT fast path.
pub fn executeTraced(rec: *execlog.ExecLogRecorder, t: *const Trace, regs: RegWindow, values: []Value) ExecResult {
    return executeImpl(true, rec, .{}, t, regs, values);
}

/// Test-only adapters: run `execute`/`executeTraced` over a flat `[]Value` register
/// file (the shape the unit tests build), splitting it into the SoA tag/payload lanes
/// the window now requires and scattering the mutated lanes back into `regs` (raw
/// payload bits, no recanonicalization) so post-run assertions see the writeback.
/// A small fixed lane buffer avoids threading an allocator through every test.
pub fn executeValues(t: *const Trace, regs: []Value, values: []Value) ExecResult {
    var tbuf: [256]u8 = undefined;
    var pbuf: [256]u64 = undefined;
    std.debug.assert(regs.len <= tbuf.len);
    for (regs, 0..) |v, i| {
        tbuf[i] = @intFromEnum(v.tag);
        pbuf[i] = v.payload.bits;
    }
    const r = execute(t, RegWindow.of(tbuf[0..regs.len], pbuf[0..regs.len]), values);
    for (regs, 0..) |*v, i| v.* = .{ .tag = @enumFromInt(tbuf[i]), .payload = .{ .bits = pbuf[i] } };
    return r;
}

/// `executeValues` with a VM context (doc 24) — for tests exercising the
/// allocating arms / `guard_gc` over a flat register file.
pub fn executeValuesCtx(ctx: ExecCtx, t: *const Trace, regs: []Value, values: []Value) ExecResult {
    var tbuf: [256]u8 = undefined;
    var pbuf: [256]u64 = undefined;
    std.debug.assert(regs.len <= tbuf.len);
    for (regs, 0..) |v, i| {
        tbuf[i] = @intFromEnum(v.tag);
        pbuf[i] = v.payload.bits;
    }
    const r = executeCtx(ctx, t, RegWindow.of(tbuf[0..regs.len], pbuf[0..regs.len]), values);
    for (regs, 0..) |*v, i| v.* = .{ .tag = @enumFromInt(tbuf[i]), .payload = .{ .bits = pbuf[i] } };
    return r;
}

pub fn executeTracedValues(rec: *execlog.ExecLogRecorder, t: *const Trace, regs: []Value, values: []Value) ExecResult {
    var tbuf: [256]u8 = undefined;
    var pbuf: [256]u64 = undefined;
    std.debug.assert(regs.len <= tbuf.len);
    for (regs, 0..) |v, i| {
        tbuf[i] = @intFromEnum(v.tag);
        pbuf[i] = v.payload.bits;
    }
    const r = executeTraced(rec, t, RegWindow.of(tbuf[0..regs.len], pbuf[0..regs.len]), values);
    for (regs, 0..) |*v, i| v.* = .{ .tag = @enumFromInt(tbuf[i]), .payload = .{ .bits = pbuf[i] } };
    return r;
}

/// The single executor body, `comptime`-specialized over `record`. With
/// `record == false` the `rec` calls are not analyzed (Zig folds the comptime `if`),
/// so `execute` compiles exactly as before — no recorder overhead on the JIT path.
/// With `record == true`, `rec` observes every value, guard outcome, commit, and the
/// terminal side-exit. Recording is observation-only: `regs`/`completed` are
/// byte-identical to the uninstrumented run (the parity canary test asserts this).
fn executeImpl(comptime record: bool, rec: anytype, ctx: ExecCtx, t: *const Trace, regs: RegWindow, values: []Value) ExecResult {
    std.debug.assert(values.len >= t.instrs.len);
    if (record) rec.begin();
    var completed: usize = 0;
    // Phase E1 (LICM): instructions before the `preheader` marker run **once**
    // (on the first pass); their `values[]` persist and are reused every later
    // iteration. `body_start` is the first per-iteration instruction (0 when there
    // is no preheader — the pre-E1 common case, byte-identical to before).
    var body_start: usize = 0;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            body_start = i + 1;
            break;
        }
    }
    const completed_out = iter: while (true) {
        for (t.instrs, 0..) |ins, i| {
            // Skip the run-once preheader region on every iteration after the
            // first: its hoisted values are loop-invariant, so the first pass's
            // `values[]` stay valid (LICM only hoists pure, invariant instrs).
            if (completed > 0 and i < body_start) continue;
            switch (ins.op) {
                // ---- inputs ----
                .slot_load => {
                    values[i] = regs.get(@intCast(ins.aux));
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
                    if (ins.aux == trace_ir.PHI_INTERNAL) {
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
                        // event (the old exit_store produced none).
                        values[i] = regs.get(@intCast(ins.aux));
                    }
                },

                // ---- arithmetic / bitwise / comparisons → the shared evaluator
                //      (`evalBinary`, the *same* code the optimizer folds with).
                //      Any error (only integer //- or %-by-zero is reachable; see
                //      arith.zig) side-exits to tier-0, which re-raises it. ----
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .eq, .ne, .lt, .le => {
                    values[i] = ir_eval.evalBinary(ins.op, values[ins.a], values[ins.b]) catch {
                        if (record) rec.exit(i, .arith, Value.nil());
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    };
                    if (record) rec.value(i, values[i]);
                },

                // ---- unary (shared evaluator too) ----
                .neg, .not, .bnot => {
                    values[i] = ir_eval.evalUnary(ins.op, values[ins.a]) catch {
                        if (record) rec.exit(i, .arith, Value.nil());
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    };
                    if (record) rec.value(i, values[i]);
                },

                // ---- guards: a mismatch side-exits to tier-0 ----
                .guard_int => if (values[ins.a].isInt()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .guard_float => if (values[ins.a].isFloat()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .guard_number => if (values[ins.a].isNumber()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .guard_true => if (values[ins.a].isTruthy()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .guard_false => if (!values[ins.a].isTruthy()) {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },

                // ---- float→int loop-limit specialization ----
                // Convert the (loop-invariant) float limit to its exact integer
                // value, or side-exit if it is not an integer representable in
                // [-2^63, 2^63). `value.floatAsExactInt` is the SAME predicate the
                // native lowering's `cvttsd2si` round-trip implements, so tier-1a and
                // native agree bit-for-bit. The operand is float (a dominating
                // guard_float already side-exited otherwise); be defensive anyway.
                .int_of_float => {
                    const v = values[ins.a];
                    if (v.isFloat()) {
                        if (value.floatAsExactInt(v.asFloat())) |iv| {
                            values[i] = Value.int(iv);
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, v);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },

                // ---- `#t` fast-case border (doc 23 D3) ----
                // Produce `max(asize−1, 0)` when the exact fast case holds (hash
                // empty ∧ presence-bitmap lane ∧ (asize ≤ 1 ∨ present(asize−1))) —
                // the premises under which `Table.length()` returns exactly this
                // value with no trim loop or hash search — else side-exit to
                // tier-0, which owns the general border search (holes, hash
                // borders, grids, in-band lanes).
                .alen => {
                    const tbl = table.Table.fromHeader(values[ins.a].asHeap());
                    const ap = &tbl.array;
                    const fast = tbl.hash.count() == 0 and ap.lane.scalarPresenceLane() and
                        (ap.asize <= 1 or ap.isPresent(ap.asize - 1));
                    if (fast) {
                        values[i] = Value.int(if (ap.asize == 0) 0 else @intCast(ap.asize - 1));
                        if (record) rec.value(i, values[i]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ins.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
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
                // to tier-0 by construction. By the time we run, `guard_bounds` (and
                // `guard_present` for narrow lanes) have already passed, so this hits
                // the array fast path. For `.value`-lane table loads, the subsequent
                // `guard_table` on the result verifies it is a table.
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
                // `astore_append` — the grow analogue of `astore` (the first
                // mid-iteration *length-changing* mutation). The dominating
                // `guard_append` proved `idx==len+1`, `len<cap`, and an empty hash, so
                // the append needs no allocator, no widen, and no `migrateFromHash`:
                // `appendInCap` writes `data[len]` in-lane and bumps `len` by one,
                // byte-identical to what tier-0's `append` does *within capacity* (the
                // realloc/migrate cases were peeled off to a `guard_append` side-exit).
                .astore_append => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    tbl.array.appendInCap(values[ins.b]);
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },

                // ---- flattened-grid cell access path (doc 14, Phase 8) ----
                //
                // `garow` pairs (table, row) and `gcell` pairs (garow, col); both
                // carry no usable Value (the analogue of `aref`). The cell ops walk
                // the chain to recover (table, row, col): `gcell.a` → garow,
                // `garow.a` → table value, `garow.b` → row value, `gcell.b` → col
                // value. Rows/cols are 1-based Lua indices; the grid API is 0-based.
                .garow, .gcell => {
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },
                // Read grid cell `(row,col)` via the exact tier-0 grid reader, so an
                // executed trace reads byte-identical to tier-0. `guard_grid`,
                // `guard_bounds` (row), `guard_gcol` (col), and `guard_gpresent` have
                // all passed, so this hits a present cell of an int- or f64-lane grid.
                // The decoded cell's type is fixed by `grid_elem` (int or float), so
                // unlike `hload` no tag recheck is needed.
                .gload => {
                    const gcell = t.instrs[ins.a];
                    const ga = t.instrs[gcell.a];
                    const tbl = table.Table.fromHeader(values[ga.a].asHeap());
                    const row: usize = @intCast(values[ga.b].asInt() - 1);
                    const col: usize = @intCast(values[gcell.b].asInt() - 1);
                    values[i] = tbl.array.gridGet(row, col);
                    if (record) rec.value(i, values[i]);
                },
                // Write grid cell `(row,col)` in place via the exact tier-0 grid
                // writer. `guard_grid`/`guard_stride`/`guard_bounds`/`guard_gcol`
                // proved the cell is inside the grid (no grow) and `guard_fits` proved
                // the value fits `grid_elem` (no widen), so this neither reshapes nor
                // allocates. `b` is the value. Produces no value (store nil).
                .gstore => {
                    const gcell = t.instrs[ins.a];
                    const ga = t.instrs[gcell.a];
                    const tbl = table.Table.fromHeader(values[ga.a].asHeap());
                    const row: usize = @intCast(values[ga.b].asInt() - 1);
                    const col: usize = @intCast(values[gcell.b].asInt() - 1);
                    tbl.array.gridSet(row, col, values[ins.b]);
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },

                // ---- hash-part (string-keyed) field access path (doc 11) ----
                //
                // `href` carries no usable Value — it only pairs (table, key konst)
                // for the `hload`/`hstore`/`guard_hash` that reference it. Store nil
                // so the SSA slot is defined; it is never read *as a value*. (The hash
                // analogue of `aref`.)
                .href => {
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },
                // Read the hash-part field via the *exact* tier-0 reader
                // (`Table.get`), so an executed trace reads byte-identical to tier-0.
                // `guard_hash` (run before us) proved the key present and the table
                // metatable-free, so this hits the hash-part and returns the present
                // value. (The hash analogue of `aload`.)
                //
                // `hload` is a **typed** load: `ins.ty` is the recorded field type
                // (int/float/bool — the recorder restricts the field to those). Unlike a
                // packed array lane, a hash cell holds a full tagged `Value`, so its
                // runtime type is NOT structurally constrained — a sibling mutation
                // between entries (same `hash.count()`, so `guard_hash` still passes) or
                // the trace's own store of a value whose runtime type drifted could make
                // the cell non-scalar. We therefore tag-check **before logging** and
                // side-exit on mismatch, so a non-scalar never reaches the scalar-only
                // exec log (`UnsupportedEffectResult`) and never feeds the consumer
                // arithmetic. This mirrors the H1 native lowering (load tag, side-exit if
                // ≠ guarded tag, then load payload); the consumer `guard_int`/`guard_float`
                // the recorder still emits is then always satisfied here.
                .hload => {
                    const hr = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[hr.a].asHeap());
                    const fv = tbl.get(values[hr.b]);
                    const type_ok = switch (ins.ty) {
                        .int => fv.isInt(),
                        .float => fv.isFloat(),
                        // doc 43 P1: the bool field's ONLY strict type pin — the
                        // recorder emits no consumer guard for it, so this fused
                        // tag exit is what keeps a bool→heap drift off-trace.
                        .boolean => fv.isBool(),
                        // doc 43 P2: a heap-valued field (function today, table in
                        // P3). "Some heap value" only — the identity/type pin is
                        // the guard the recorder emits right after the load
                        // (`guard_func` proto-id / P3 `guard_table`).
                        .heap => fv.isHeap(),
                        else => false, // int/float/bool/heap fields are recorded
                    };
                    if (!type_ok) {
                        if (record) rec.exit(i, .guard, values[hr.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                    values[i] = fv;
                    if (record) rec.value(i, values[i]);
                },
                // Overwrite the present hash cell in place via `fieldPtr` (NOT
                // `Table.set`, which could migrate/rehash). `guard_hash` proved the key
                // present, so the cell exists and a same-key overwrite changes no
                // structure. `b` is the value (recorder-restricted to int/float).
                // `hstore` produces no value; store nil so the SSA slot is defined.
                // (The hash analogue of `astore`.)
                .hstore => {
                    const hr = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[hr.a].asHeap());
                    tbl.fieldPtr(values[hr.b]).?.* = values[ins.b];
                    values[i] = Value.nil();
                    if (record) rec.value(i, values[i]);
                },
                // The hash-part structural-stability guard: the table is still
                // metatable-free, the recorded key is still present, and the hash
                // population is unchanged (`hash.count() == aux`). Pinning the count
                // catches insert/delete/grow since the cell was resolved; together with
                // the present check it proves the (H1-hoisted) cell pointer is still
                // valid. Any miss side-exits to tier-0 (full dispatch / migrate). `aux`
                // is the recorded population (a small count, like `guard_lane`'s lane).
                .guard_hash => {
                    const hr = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[hr.a].asHeap());
                    if (tbl.metatable == null and tbl.fieldPtr(values[hr.b]) != null and
                        tbl.hash.count() == @as(usize, @intCast(ins.aux)))
                    {
                        if (record) rec.guardPass(i, values[hr.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[hr.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // The slot holds a heap table with NO metatable. Recording aborts
                // on a metatable-bearing table (`trace.AbortReason.has_metatable`),
                // so a trace only models raw array access; if `setmetatable` added a
                // metatable between entries (or this is a different table than the
                // one recorded), the raw `aload`/`astore` would skip
                // `__index`/`__newindex` — so side-exit to tier-0 (full dispatch).
                .guard_table => if (values[ins.a].isHeap() and values[ins.a].heapType() == .table and
                    table.Table.fromHeader(values[ins.a].asHeap()).metatable == null)
                {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Cross-frame tracing: the inlined callee value must still be a Lua
                // closure of the recorded `Proto.id`. `aux` is the id (a stable `u32`,
                // not a pointer — survives keyframe restore). Fails *closed*: any
                // non-closure / wrong-proto callee side-exits to tier-0, which really
                // pushes the call frame and re-runs the iteration. Proto-id identity is
                // sound while in-callee upvalue access still aborts (two closures over
                // one proto are trace-identical when no upvalue is read).
                .guard_func => if (values[ins.a].isHeap() and values[ins.a].heapType() == .function and
                    function.Closure.fromHeader(values[ins.a].asHeap()).proto.id == @as(u32, @bitCast(ins.aux)))
                {
                    if (record) rec.guardPass(i, values[ins.a]);
                } else {
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // ---- pure-builtin inlining (doc 12) ----
                // The seeded callee is still exactly this pure builtin. A reassigned
                // `sqrt` upvalue (now a non-native, or a native with a different/no
                // `pure` tag) side-exits to tier-0 on the SAME iteration as native —
                // `aux` is the `RecordedBuiltin` ordinal, the value must be a `.native`
                // carrying that tag. Identity is the enum, never a pointer (doc 02).
                .guard_builtin => {
                    const v = values[ins.a];
                    const ok = v.isHeap() and v.heapType() == .native and
                        function.Native.fromHeader(v.asHeap()).recorded == @as(function.RecordedBuiltin, @enumFromInt(ins.aux));
                    if (ok) {
                        if (record) rec.guardPass(i, v);
                    } else {
                        if (record) rec.exit(i, .guard, v);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // Leaf pure producer: `@sqrt` of the `guard_float`-pinned operand.
                // `@sqrt(f64)` (here) and native `sqrtsd` are IEEE correctly-rounded
                // and bit-identical under the default MXCSR (round-to-nearest-even).
                // Defensive non-float side-exit (a dominating `guard_float` already
                // side-exited otherwise). `sqrt(-0.0)=-0.0`, `sqrt(<0)=qNaN`.
                .fsqrt => {
                    const v = values[ins.a];
                    if (v.isFloat() or v.isInt()) {
                        // Int operand: the same round-to-nearest promotion the
                        // float binops use (`@floatFromInt` ≡ native `cvtsi2sd`).
                        const x = if (v.isFloat()) v.asFloat() else @as(f64, @floatFromInt(v.asInt()));
                        values[i] = Value.float(@sqrt(x));
                        if (record) rec.value(i, values[i]);
                        continue;
                    }
                    if (record) rec.exit(i, .guard, v);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Leaf pure producers: `math.sin`/`math.cos` of the
                // `guard_float`-pinned operand. Every tier evaluates through the
                // ONE noinline `fmath` kernel, so cross-tier bit-identity holds
                // by construction (doc 23 D4). Same defensive non-float
                // side-exit shape as `.fsqrt`.
                .fsin, .fcos => {
                    const v = values[ins.a];
                    if (v.isFloat() or v.isInt()) {
                        const x = if (v.isFloat()) v.asFloat() else @as(f64, @floatFromInt(v.asInt()));
                        values[i] = Value.float(if (ins.op == .fsin) fmath.sinRuntime(x) else fmath.cosRuntime(x));
                        if (record) rec.value(i, values[i]);
                        continue;
                    }
                    if (record) rec.exit(i, .guard, v);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Doc 35: `math.floor(x)` / `math.ceil(x)` → integer result.
                // Promote int→float if needed (same as fsin/fcos), apply
                // @floor/@ceil, convert to i64 via the shared fmath kernel.
                // Side-exit on out-of-range / NaN / inf (sentinel).
                .ffloor, .fceil => {
                    const v = values[ins.a];
                    if (v.isFloat() or v.isInt()) {
                        const x = if (v.isFloat()) v.asFloat() else @as(f64, @floatFromInt(v.asInt()));
                        const r = if (ins.op == .ffloor) fmath.floorRuntime(x) else fmath.ceilRuntime(x);
                        if (r != fmath.FLOOR_CEIL_SENTINEL) {
                            values[i] = Value.int(r);
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, v);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Doc 24 D3: the allocation-budget entry guard. Passes ⇔
                // `!gc_stress ∧ object_count + A < next_gc` (saturating) — then
                // even the worst case (every call this iteration misses) cannot
                // make a collection due mid-burst, so the D2 id-stream argument
                // holds and loop-header re-entry stays sound. Fails CLOSED with
                // no heap attached (bare test harness): an allocating body
                // never runs detached from a VM. Logs the boolean predicate as
                // its guard value (codex #13 — it has no SSA operand).
                .guard_gc => {
                    const a_bound: usize = @intCast(ins.aux);
                    const pass = if (ctx.heap) |heap|
                        !heap.gc_stress and (heap.object_count +| a_bound) < heap.next_gc
                    else
                        false;
                    if (pass) {
                        if (record) rec.guardPass(i, Value.boolean(true));
                    } else {
                        if (record) rec.exit(i, .guard, Value.boolean(false));
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // Doc 24 D4/D5: allocating interned-string producers. The ONE
                // shared `stralloc` body (render via `io.writeValue` + intern)
                // every tier runs — tier-0's `bToString` composes the same two
                // primitives, so the result is byte-identical by construction.
                // A null return is OOM with a clean id stream (no `link`
                // preceded the fallible step — see stralloc.zig): side-exit at
                // the header and let tier-0's replay re-raise the same OOM at
                // the same logical point. Defensive type side-exit like
                // `.fsqrt` (a dominating `guard_int`/`guard_float` pinned the
                // operand). No-heap (bare harness) fails closed the same way.
                .tostr_int, .tostr_num => {
                    const v = values[ins.a];
                    const type_ok = if (ins.op == .tostr_int) v.isInt() else v.isFloat();
                    if (type_ok) {
                        if (ctx.heap) |heap| {
                            const hdr = if (ins.op == .tostr_int)
                                stralloc.tostrIntRuntime(heap, v.asInt())
                            else
                                stralloc.tostrNumRuntime(heap, v.asFloat());
                            if (hdr) |h| {
                                values[i] = Value.heap(h);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, v);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Doc 24 D4: `#s` of a proven string — the cached code-point
                // count (`cp_len`, the `#s` semantic; NOT bytes). Pure leaf
                // producer; defensive non-string side-exit (the producer or a
                // dominating `guard_string` proves the operand).
                .slen => {
                    const v = values[ins.a];
                    if (v.isHeap() and v.heapType() == .string) {
                        const s = string_mod.String.fromHeader(v.asHeap());
                        values[i] = Value.int(@intCast(s.cp_len));
                        if (record) rec.value(i, values[i]);
                        continue;
                    }
                    if (record) rec.exit(i, .guard, v);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Doc 24 c3: the snew class — allocating string transforms,
                // each through the ONE stralloc shim over the shared
                // `stdlib/string.zig` core tier-0 wraps. Operand types are
                // producer-proven or guard-pinned; any mismatch (or a null
                // return: OOM / out-of-range char, both link-free) is a
                // defensive side-exit and tier-0 replays the iteration.
                .ssub => {
                    const sv = values[ins.a];
                    const iv = values[ins.b];
                    const jv = values[@intCast(ins.aux)];
                    if (sv.isHeap() and sv.heapType() == .string and iv.isInt() and jv.isInt()) {
                        if (ctx.heap) |heap| {
                            if (stralloc.ssubRuntime(heap, sv.asHeap(), iv.asInt(), jv.asInt())) |h| {
                                values[i] = Value.heap(h);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .srev => {
                    const sv = values[ins.a];
                    if (sv.isHeap() and sv.heapType() == .string) {
                        if (ctx.heap) |heap| {
                            if (stralloc.srevRuntime(heap, sv.asHeap())) |h| {
                                values[i] = Value.heap(h);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .schar1 => {
                    const cv = values[ins.a];
                    if (cv.isInt()) {
                        if (ctx.heap) |heap| {
                            if (stralloc.schar1Runtime(heap, cv.asInt())) |h| {
                                values[i] = Value.heap(h);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, cv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .srep2 => {
                    const sv = values[ins.a];
                    const nv = values[ins.b];
                    if (sv.isHeap() and sv.heapType() == .string and nv.isInt()) {
                        if (ctx.heap) |heap| {
                            if (stralloc.srep2Runtime(heap, sv.asHeap(), nv.asInt())) |h| {
                                values[i] = Value.heap(h);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Doc 26 D2: the case-mapping pair — heap-only by the
                // committed-trace pin invariant (D1); the session's Unicode
                // version was pinned before this trace could commit, so the
                // shared caseCore needs no VM. Null (scratch OOM, no link
                // performed) is a defensive side-exit; tier-0 replays.
                .supper, .slower => {
                    const sv = values[ins.a];
                    if (sv.isHeap() and sv.heapType() == .string) {
                        if (ctx.heap) |heap| {
                            const h = if (ins.op == .supper)
                                stralloc.supperRuntime(heap, sv.asHeap())
                            else
                                stralloc.slowerRuntime(heap, sv.asHeap());
                            if (h) |hdr| {
                                values[i] = Value.heap(hdr);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // ---- doc 30: pattern-engine + str2num callouts ----
                // Every arm calls the SAME stralloc shim the native emitter
                // will (P3: one core); a negative status / null / missing
                // heap context side-exits (tier-0 replays the iteration).
                .sfindp => {
                    const sv = values[ins.a];
                    const iv = values[ins.b];
                    const pv = values[@intCast(ins.aux)];
                    if (sv.isHeap() and sv.heapType() == .string and iv.isInt() and
                        pv.isHeap() and pv.heapType() == .string)
                    {
                        const r = stralloc.sfindpRuntime(sv.asHeap(), iv.asInt(), pv.asHeap());
                        if (r >= 1) {
                            values[i] = Value.int(r);
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .smatch => {
                    const sv = values[ins.a];
                    const iv = values[ins.b];
                    const pv = values[@intCast(ins.aux)];
                    if (sv.isHeap() and sv.heapType() == .string and iv.isInt() and
                        pv.isHeap() and pv.heapType() == .string)
                    {
                        if (ctx.heap) |heap| {
                            const st = stralloc.smatchRuntime(heap, sv.asHeap(), iv.asInt(), pv.asHeap());
                            if (st == 0) {
                                // The status is the op's SSA value; it is never
                                // guest-visible (only projections are).
                                values[i] = Value.int(st);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .sgmatch => {
                    const stv = values[ins.a];
                    const expected = t.consts[@intCast(ins.aux)];
                    if (stv.isHeap() and stv.heapType() == .table and
                        expected.isHeap() and expected.heapType() == .string)
                    {
                        if (ctx.heap) |heap| {
                            const st = stralloc.sgmatchRuntime(heap, stv.asHeap(), expected.asHeap());
                            if (st == 0) {
                                values[i] = Value.int(st);
                                if (record) rec.value(i, values[i]);
                                continue;
                            }
                        }
                    }
                    if (record) rec.exit(i, .guard, stv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .scap_int => {
                    // Direct scratch read (the native lowering is a baked
                    // absolute load); no heap context → bail like any other
                    // scratch-touching op (doc 30 M05).
                    if (ctx.heap) |heap| {
                        const w = heap.match_scratch.words[2 * @as(usize, ins.b)];
                        values[i] = Value.int(@bitCast(w));
                        if (record) rec.value(i, values[i]);
                        continue;
                    }
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .scap_str => {
                    if (ctx.heap) |heap| {
                        if (stralloc.scapStrRuntime(heap, @as(i64, ins.b))) |hdr| {
                            values[i] = Value.heap(hdr);
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, values[ins.a]);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .str2num_i, .str2num_f => {
                    const sv = values[ins.a];
                    if (sv.isHeap() and sv.heapType() == .string) {
                        const r = stralloc.str2numRuntime(sv.asHeap());
                        if (ins.op == .str2num_i and r.status == 0) {
                            values[i] = Value.int(@bitCast(r.value));
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                        if (ins.op == .str2num_f and r.status == 1) {
                            values[i] = Value.float(@bitCast(r.value));
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .sgm_setpos => {
                    // The deferred gmatch-cursor commit (doc 30 §6): sits below
                    // every guard, so reaching it means the iteration completed.
                    // Produces no value; nil keeps the SSA slot defined.
                    const stv = values[ins.a];
                    const npv = values[ins.b];
                    if (stv.isHeap() and stv.heapType() == .table and npv.isInt()) {
                        if (stralloc.sgmSetposRuntime(stv.asHeap(), npv.asInt()) == 0) {
                            values[i] = Value.nil();
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, stv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                .guard_sid => {
                    // Interned-identity pin (doc 30 §2a): equal bytes ⇔ same
                    // object within a heap, so identity is a pointer compare
                    // against the konst-pool string.
                    const v = values[ins.a];
                    const expected = t.consts[@intCast(ins.aux)];
                    if (v.isHeap() and expected.isHeap() and v.asHeap() == expected.asHeap()) {
                        if (record) rec.guardPass(i, v);
                    } else {
                        if (record) rec.exit(i, .guard, v);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // Doc 26 D3: single-result codepoint — pure, non-allocating;
                // the shared codepointCore owns the wrap/clamp semantics. An
                // empty range (core → null) side-exits and tier-0's replay
                // produces the nil itself.
                .scp => {
                    const sv = values[ins.a];
                    const iv = values[ins.b];
                    const jv = values[@intCast(ins.aux)];
                    if (sv.isHeap() and sv.heapType() == .string and iv.isInt() and jv.isInt()) {
                        const str = string_mod.String.fromHeader(sv.asHeap());
                        if (string_std.codepointCore(str, iv.asInt(), jv.asInt())) |cp| {
                            values[i] = Value.int(cp);
                            if (record) rec.value(i, values[i]);
                            continue;
                        }
                    }
                    if (record) rec.exit(i, .guard, sv);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
                // Doc 24 D4: the observed value is a heap string (the string
                // analogue of `guard_table`'s type half).
                .guard_string => {
                    const v = values[ins.a];
                    if (v.isHeap() and v.heapType() == .string) {
                        if (record) rec.guardPass(i, v);
                    } else {
                        if (record) rec.exit(i, .guard, v);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // The table's array lane still equals the recorded lane (a
                // monotonic widen would have moved it past `aux`).
                .guard_lane => {
                    const tbl = table.Table.fromHeader(values[ins.a].asHeap());
                    if (@intFromEnum(tbl.array.lane) == ins.aux) {
                        if (record) rec.guardPass(i, values[ins.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ins.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // Producer-dispatched bounds (doc 18 D3): the rule depends on what
                // produced the operand. `.aref` (scalar array key) uses THE shared
                // membership predicate `inArray`; `.garow` (grid row) keeps the
                // grid-row rule (`1 <= row <= rows` — the layout field counts rows
                // for grids, and grids stay 1-based outside; doc 18 D6).
                // `assertWellFormed` pins the producer to exactly these two ops;
                // anything else fails closed as a guard exit.
                .guard_bounds => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    const idx = values[ar.b].asInt();
                    const ok = switch (ar.op) {
                        .aref => arr.ArrayPart.inArray(idx, tbl.array.asize),
                        .garow => idx >= 1 and idx <= @as(i64, @intCast(tbl.array.gridRows())),
                        else => blk: {
                            std.debug.assert(false); // assertWellFormed pins the producer
                            break :blk false; // release: fail closed -> side-exit
                        },
                    };
                    if (ok) {
                        if (record) rec.guardPass(i, values[ar.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ar.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
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
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
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
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // The append precondition (grow analogue of guard_bounds): the hash
                // part is empty (migrate is a no-op), the key is the exact append
                // successor (`idx == asize`, the doc-18 D2.3 identity), and there is
                // capacity to grow without a realloc (`asize < cap`). Any miss
                // side-exits so tier-0 runs the
                // iteration (reallocating / migrating as needed) and the loop re-enters.
                .guard_append => {
                    const ar = t.instrs[ins.a];
                    const tbl = table.Table.fromHeader(values[ar.a].asHeap());
                    const idx = values[ar.b].asInt();
                    const asize: i64 = @intCast(tbl.array.asize);
                    if (tbl.hash.count() == 0 and idx == asize and tbl.array.asize < tbl.array.cap) {
                        if (record) rec.guardPass(i, values[ar.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ar.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },

                // ---- flattened-grid structural guards (doc 14, Phase 8) ----
                //
                // The container is still a grid at the recorded element lane (int or
                // f64). A bare access would have deflated it (`lane != .grid`), and a
                // monotonic widen of the cell lane (e.g. i8→i32) moves `grid_elem`
                // past `aux` — either side-exits to tier-0, where the access runs on
                // the materialised representation.
                .guard_grid => {
                    const tbl = table.Table.fromHeader(values[ins.a].asHeap());
                    if (tbl.array.lane == .grid and @intFromEnum(tbl.array.grid_elem) == ins.aux) {
                        if (record) rec.guardPass(i, values[ins.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ins.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // The grid's column count still equals the recorded stride. A fused
                // store whose column outran `stride` grows it (doc 14 reshape); the
                // recorded address arithmetic (`row*stride + col`) is only valid for
                // the pinned stride, so any change side-exits.
                .guard_stride => {
                    const tbl = table.Table.fromHeader(values[ins.a].asHeap());
                    if (tbl.array.stride == @as(usize, @intCast(ins.aux))) {
                        if (record) rec.guardPass(i, values[ins.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ins.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // The column lands inside the row: `1 <= col <= stride`. Walk
                // `gcell.a` → garow → table for the stride, `gcell.b` for the column.
                .guard_gcol => {
                    const gcell = t.instrs[ins.a];
                    const ga = t.instrs[gcell.a];
                    const tbl = table.Table.fromHeader(values[ga.a].asHeap());
                    const col = values[gcell.b].asInt();
                    if (col >= 1 and col <= @as(i64, @intCast(tbl.array.stride))) {
                        if (record) rec.guardPass(i, values[ga.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ga.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },
                // The addressed cell is present (a hole would read as nil, which the
                // native int path cannot represent — the grid analogue of
                // `guard_present`).
                .guard_gpresent => {
                    const gcell = t.instrs[ins.a];
                    const ga = t.instrs[gcell.a];
                    const tbl = table.Table.fromHeader(values[ga.a].asHeap());
                    const row: usize = @intCast(values[ga.b].asInt() - 1);
                    const col: usize = @intCast(values[gcell.b].asInt() - 1);
                    if (!tbl.array.gridGet(row, col).isNil()) {
                        if (record) rec.guardPass(i, values[ga.a]);
                    } else {
                        if (record) rec.exit(i, .guard, values[ga.a]);
                        break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                    }
                },

                // ---- close: commit the loop-carried writes, then iterate ----
                .loop => {
                    // φ writeback: a slot-bound φ flushes its update to the register
                    // (the carry tier-0 resumes from); an internal φ refreshes its own
                    // carried scratch so the next iteration retains it.
                    flushPhiWriteback(t, regs, values);
                    // Doc 39: a PEELED trace's run-once region is a real tier-0
                    // iteration (the type-stabilizing first pass), so its first
                    // back-edge completes TWO iterations. Sound against every
                    // other use of `completed` in this fn: the run-once skip and
                    // internal-φ init only distinguish 0 vs > 0, and `completed`
                    // becomes nonzero at exactly the same event either way.
                    completed += 1 + @as(usize, @intFromBool(t.peeled and completed == 0));
                    if (record) rec.commit();
                    continue :iter;
                },

                // Preheader region boundary (Phase E1): a pure marker. On the first
                // pass it falls through as a no-op; on later iterations it (and the
                // whole region before it) is skipped by the `body_start` guard above.
                .preheader => {},

                // ---- link: terminal hand-off to an inner root trace (doc 15) ----
                // Phase 3: reaching `.link` is a terminal hand-off, not a loop
                // commit, but the continuation's exit snapshot is the hand-off
                // contract. Flush it before reporting the link exit so the chainer
                // can enter the inner root with `R[a]` / `R[a+3]` (and any other
                // carried slots) byte-identical to the root trace's entry state.
                .link => {
                    flushPhiWriteback(t, regs, values);
                    break :iter ExecResult{ .completed = completed, .exit_instr = @as(u32, @intCast(i)) };
                },
            }
        }
        // A well-formed trace always terminates in `loop` (checked by the
        // commit-time verifier in trace.zig). If one somehow didn't, stop rather
        // than spin — `regs` is whatever the last commit left, which is coherent.
        break :iter ExecResult{ .completed = completed, .exit_instr = std.math.maxInt(u32) };
    };
    if (record) rec.end(completed_out.completed);
    return completed_out;
}

fn flushPhiWriteback(t: *const Trace, regs: RegWindow, values: []Value) void {
    for (t.instrs, 0..) |p, pi| {
        if (p.op != .phi) continue;
        if (p.aux == trace_ir.PHI_INTERNAL) {
            values[pi] = values[@intCast(p.b)];
        } else {
            regs.set(@intCast(p.aux), values[@intCast(p.b)]);
        }
    }
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
const IrInstr = trace_ir.IrInstr;
const IrOp = trace_ir.IrOp;
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
        .entry_guards = &.{},
    };
    var regs = [3]Value{ Value.heap(&t.header), Value.int(start), Value.nil() };
    var values: [13]Value = undefined;
    const result = executeValues(&tr, &regs, &values);
    return .{ .completed = result.completed, .regs = regs };
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
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = @constCast(consts[0..]), .entry_slots = &[_]u16{}, .entry_guards = &.{} };

    var rec = execlog.ExecLogRecorder.init(gpa, 64, 8);
    defer rec.deinit();
    var log = execlog.TraceExecLog{ .trace_id = 0 };
    defer log.deinit(gpa);
    rec.retarget(&log);

    var regs = [3]Value{ Value.heap(&t.header), Value.nil(), Value.int(1) };
    var values: [8]Value = undefined;
    const completed = executeTracedValues(&rec, &tr, &regs, &values).completed;

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
        .entry_guards = &.{},
    };
    // r0 is an int, not a table → guard_table fails on the first iteration.
    var regs = [3]Value{ Value.int(99), Value.int(1), Value.nil() };
    var values: [13]Value = undefined;
    try testing.expectEqual(@as(usize, 0), executeValues(&tr, &regs, &values).completed);
    try testing.expect(regs[0].asInt() == 99); // untouched
}

test "per-guard PC: ExecResult.exit_instr points to the failing guard" {
    // A trace with two guard_int instructions. The second one fails.
    var instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (int)
        .{ .op = .guard_int, .a = 0 }, // %1: guard r0 is int — passes
        .{ .op = .slot_load, .aux = 1 }, // %2: r1 (float → fails guard)
        .{ .op = .guard_int, .a = 2 }, // %3: guard r1 is int — FAILS
        .{ .op = .loop }, // %4 (unreachable)
    };
    const consts = [_]Value{};
    const tr = Trace{
        .anchor = undefined,
        .instrs = &instrs,
        .consts = @constCast(consts[0..]),
        .entry_slots = &[_]u16{},
        .entry_guards = &.{},
    };
    var regs = [_]Value{ Value.int(1), Value.float(3.14) };
    var values: [5]Value = undefined;
    const result = executeValues(&tr, &regs, &values);
    try testing.expectEqual(@as(usize, 0), result.completed);
    // The failing guard is instrs[3] — guard_int on r1
    try testing.expectEqual(@as(u32, 3), result.exit_instr);
    // regs untouched
    try testing.expectEqual(@as(i64, 1), regs[0].asInt());
}

test "per-guard PC: ExecResult.exit_instr on arith error (divide by zero)" {
    // A loop that hits integer division by zero on iteration 2.
    // r2 starts at 1 and decrements → 0, so 5 // r2 becomes DivByZero.
    var instrs = [_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 5
        .{ .op = .slot_load, .aux = 2 }, // %1 = r2 (counter: 1→0)
        .{ .op = .idiv, .a = 0, .b = 1 }, // %2 = 5 // r2
        .{ .op = .konst, .aux = 1 }, // %3 = 1
        .{ .op = .sub, .a = 1, .b = 3 }, // %4 = r2 - 1
        .{ .op = .phi, .a = 0, .b = 4, .aux = 2, .ty = .int }, // %5: r2 ← r2-1
        .{ .op = .loop }, // %6
    };
    const consts = [_]Value{ Value.int(5), Value.int(1) };
    const tr = Trace{
        .anchor = undefined,
        .instrs = &instrs,
        .consts = @constCast(consts[0..]),
        .entry_slots = &[_]u16{},
        .entry_guards = &.{},
    };
    var regs = [_]Value{ Value.nil(), Value.nil(), Value.int(1) };
    var values: [7]Value = undefined;
    const result = executeValues(&tr, &regs, &values);
    // One clean iteration (r2=1 → 5//1=5), then div-by-zero on iter 2 (r2=0).
    try testing.expectEqual(@as(usize, 1), result.completed);
    // The failing instruction is the idiv at index 2.
    try testing.expectEqual(@as(u32, 2), result.exit_instr);
}
