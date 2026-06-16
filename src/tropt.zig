//! Trace optimizer (Phase 6b) — rewrite passes over a recorded trace's linear
//! SSA IR, run **once at commit time** (never in the executor hot loop). It
//! shrinks the per-iteration instruction count the tier-1a IR-interpreter
//! (`irinterp.zig`) walks, without changing observable output.
//!
//! Passes (this increment): **constant folding** (+ elimination of guards that
//! provably always pass and of exact-duplicate guards). CSE and general dead-code
//! elimination land next; the compaction/ref-remap core here already supports
//! them. Type narrowing/unboxing and LICM are deferred (they cross the
//! no-executor-change line — see docs/design/00-architecture.md Phase 6b).
//!
//! ## Why these rewrites are sound (the deopt-reconstruction rule)
//!
//! Under **loop-header re-entry deopt** the executor writes tier-0 registers only
//! at the `loop` close (`exit_stores`), and any side-exit makes tier-0 re-run the
//! whole partial iteration. So deopt reconstruction is independent of the
//! optimized body — it is just "tier-0 reruns the iteration." A rewrite is
//! therefore sound iff (a) every *completed* iteration produces byte-identical
//! `exit_store` values, and (b) it never removes a guard a *type-specialized*
//! instruction relies on. These hold here only while ALL of the following do
//! (Phase 6c fast paths / richer side exits will break several — re-derive then):
//!   1. committed traces have **no side effects** (enforced at record time);
//!   2. every side exit resumes at the **loop header** (no mid-iteration restore
//!      / snapshot observability), so guard *order* doesn't affect output;
//!   3. the executor has **no type-specialized semantics** — every op
//!      re-dispatches on the actual type via `arith.zig`, so dropping a redundant
//!      *type* guard cannot corrupt a fast path (there are none);
//!   4. the shared evaluator (`irinterp.evalBinary`/`evalUnary`) is **total**
//!      (never traps: `arith.zig` wraps integer ops and masks shift counts) and
//!      **reports every runtime error**, so a fold either matches runtime
//!      bit-for-bit or is refused;
//!   5. we **never remove an always-*fail* guard** — only always-*pass* ones and
//!      exact duplicates.
//!
//! Constant folding computes with the *same* evaluator the executor uses, so a
//! folded constant has the exact bits the executor would produce at runtime. A
//! fold that would error (integer `//`/`%` by zero) is **left as a runtime op**
//! so it side-exits and tier-0 raises the identical error — never deleted.

const std = @import("std");
const trace = @import("trace.zig");
const value = @import("value.zig");
const irinterp = @import("irinterp.zig");
const arr = @import("array.zig");

const Value = value.Value;
const IrInstr = trace.IrInstr;
const IrOp = trace.IrOp;
const Ref = trace.Ref;
const ObsType = trace.ObsType;
const SlotStore = trace.SlotStore;

/// The owned, rewritten trace arrays the optimizer (or `dupe`) hands back to
/// `trace.zig`'s `commit`, which stores them in the cached `Trace`.
pub const Optimized = struct {
    instrs: []IrInstr,
    consts: []Value,
    entry_slots: []u16,
    exit_stores: []SlotStore,
};

const OpKind = enum { konst, slot_load, binary, unary, guard, aref, aload, astore, loop };

fn kindOf(op: IrOp) OpKind {
    return switch (op) {
        .konst => .konst,
        .slot_load => .slot_load,
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .eq, .ne, .lt, .le => .binary,
        .neg, .not, .bnot => .unary,
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false => .guard,
        // Array-access guards reuse the guard machinery: kept as side-effecting
        // roots, deduped by (op, operand-ref), operand marked/remapped via `a`.
        .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits => .guard,
        // Packed-array address + load: memory ops, conservatively canonical to
        // themselves (never folded, never CSE'd) so a later store can't be
        // reordered past them. DCE'd if not reachable from a live root.
        .aref => .aref,
        .aload => .aload,
        .astore => .astore,
        .loop => .loop,
    };
}

/// Does the guard `ins` provably pass when its operand is the constant `v`?
/// (Used to drop always-pass guards. An always-*fail* guard returns false and is
/// kept — never silently removed.) `guard_fits` is lane-dependent, so it reads
/// `ins.aux` (the recorded lane ordinal). The remaining array-access guards
/// (`guard_table`/`guard_lane`/`guard_bounds`/`guard_present`) only ever guard a
/// table value or an `aref` — never a constant — so a constant operand can't
/// reach them in an honest trace; we conservatively return `false` (keep the
/// guard) rather than reasoning about it.
fn guardConstPasses(ins: IrInstr, v: Value) bool {
    return switch (ins.op) {
        .guard_int => v.isInt(),
        .guard_float => v.isFloat(),
        .guard_number => v.isNumber(),
        .guard_true => v.isTruthy(),
        .guard_false => !v.isTruthy(),
        // The value still fits the recorded narrow lane (a const value here is
        // the bool lane's `astore` constant, e.g. `false`). Lane from `aux`.
        .guard_fits => arr.ArrayPart.laneFits(@enumFromInt(ins.aux), v),
        else => false,
    };
}

/// CSE key for a pure value-producing op (konst is excluded — not CSE'd here).
/// Operand-order sensitive (no commutative canonicalization) and includes `ty`
/// so a future type-sensitive executor can't be tricked by a merge.
const CseKey = struct { op: IrOp, a: Ref, b: Ref, aux: i32, ty: ObsType };
const GuardKey = struct { op: IrOp, a: Ref };

/// The unoptimized path: dupe the recorder's arrays verbatim into owned slices
/// (the `config.optimize == false` case, and the fallback if `optimize` OOMs).
pub fn dupe(
    gpa: std.mem.Allocator,
    instrs: []const IrInstr,
    consts: []const Value,
    entry_slots: []const u16,
    exit: []const SlotStore,
) !Optimized {
    const out_instrs = try gpa.dupe(IrInstr, instrs);
    errdefer gpa.free(out_instrs);
    const out_consts = try gpa.dupe(Value, consts);
    errdefer gpa.free(out_consts);
    const out_entry = try gpa.dupe(u16, entry_slots);
    errdefer gpa.free(out_entry);
    const out_exit = try gpa.dupe(SlotStore, exit);
    return .{ .instrs = out_instrs, .consts = out_consts, .entry_slots = out_entry, .exit_stores = out_exit };
}

/// Rewrite a freshly-recorded trace body (terminated by `loop`) into a smaller,
/// behaviourally-identical one. Borrows the inputs; returns freshly-allocated
/// owned slices. Runs one forward fold/CSE-tagging stage, one backward liveness
/// stage, and one compaction (which *is* the ref-remap — refs are instruction
/// indices, so removal/replacement renumbers).
pub fn optimize(
    gpa: std.mem.Allocator,
    instrs: []const IrInstr,
    consts: []const Value,
    exit: []const SlotStore,
) !Optimized {
    const n = instrs.len;
    std.debug.assert(n >= 1 and instrs[n - 1].op == .loop);

    // --- per-ref working tables (freed after; not in the executor hot path) ---
    const const_val = try gpa.alloc(?Value, n);
    defer gpa.free(const_val);
    @memset(const_val, null);
    const canon = try gpa.alloc(Ref, n); // the canonical ref each value resolves to
    defer gpa.free(canon);
    const fold_aux = try gpa.alloc(?i32, n); // if folded: the new konst's const-pool index
    defer gpa.free(fold_aux);
    @memset(fold_aux, null);
    const dead = try gpa.alloc(bool, n); // a guard proven redundant (dropped)
    defer gpa.free(dead);
    @memset(dead, false);
    for (0..n) |i| canon[i] = @intCast(i);

    // The const pool grows as folds intern new constants; start from the input.
    var out_consts: std.ArrayListUnmanaged(Value) = .empty;
    defer out_consts.deinit(gpa);
    try out_consts.appendSlice(gpa, consts);

    var cse: std.AutoHashMapUnmanaged(CseKey, Ref) = .empty;
    defer cse.deinit(gpa);
    var guards: std.AutoHashMapUnmanaged(GuardKey, void) = .empty;
    defer guards.deinit(gpa);

    // --- forward: fold + CSE-tagging + guard elimination ---
    for (instrs, 0..) |ins, i| {
        switch (kindOf(ins.op)) {
            .konst => const_val[i] = consts[@intCast(ins.aux)],
            .slot_load => {}, // a loop-variant input: not constant, canonical to itself
            .binary => {
                const a2 = canon[ins.a];
                const b2 = canon[ins.b];
                if (const_val[a2]) |va| if (const_val[b2]) |vb| {
                    if (irinterp.evalBinary(ins.op, va, vb)) |res| {
                        const aux: i32 = @intCast(out_consts.items.len);
                        try out_consts.append(gpa, res);
                        fold_aux[i] = aux;
                        const_val[i] = res;
                        continue; // becomes a konst; do not CSE as a binary op
                    } else |_| {} // fold would error → leave as a runtime op
                };
                const key = CseKey{ .op = ins.op, .a = a2, .b = b2, .aux = ins.aux, .ty = ins.ty };
                if (cse.get(key)) |c| {
                    canon[i] = c;
                } else try cse.put(gpa, key, @intCast(i));
            },
            .unary => {
                const a2 = canon[ins.a];
                if (const_val[a2]) |va| {
                    if (irinterp.evalUnary(ins.op, va)) |res| {
                        const aux: i32 = @intCast(out_consts.items.len);
                        try out_consts.append(gpa, res);
                        fold_aux[i] = aux;
                        const_val[i] = res;
                        continue;
                    } else |_| {}
                }
                const key = CseKey{ .op = ins.op, .a = a2, .b = 0, .aux = ins.aux, .ty = ins.ty };
                if (cse.get(key)) |c| {
                    canon[i] = c;
                } else try cse.put(gpa, key, @intCast(i));
            },
            .guard => {
                const a2 = canon[ins.a];
                if (const_val[a2]) |cv| {
                    if (guardConstPasses(ins, cv)) {
                        dead[i] = true; // always-passes on a constant → drop
                        continue;
                    }
                    // always-fails: keep it (defensive; honest recording never
                    // produces this since the guard pins the observed type).
                }
                const gk = GuardKey{ .op = ins.op, .a = a2 };
                if (guards.contains(gk)) {
                    dead[i] = true; // exact-duplicate guard, earlier copy dominates
                } else try guards.put(gpa, gk, {});
            },
            // Memory ops are left verbatim: canonical to themselves, no fold/CSE.
            // `aload` is never CSE'd (each is its own canonical ref), so an
            // `astore` between two reads of the same slot cannot let the later
            // read reuse the earlier (pre-store) value — the alias-barrier
            // property holds for free. `astore` is effectful: never folded, never
            // CSE'd, kept as a root by the liveness pass below (I1).
            .aref, .aload, .astore => {},
            .loop => {},
        }
    }

    // --- backward liveness from explicit roots ---
    // Roots: the `loop` terminator, every kept guard (side-effecting), and the
    // canonical ref behind every exit_store (forgetting these would strip the
    // loop-carried computation and resume tier-0 with stale registers).
    const live = try gpa.alloc(bool, n);
    defer gpa.free(live);
    @memset(live, false);
    live[n - 1] = true; // loop
    for (instrs, 0..) |ins, i| {
        const k = kindOf(ins.op);
        // Kept guards and every `astore` are side-effecting roots (I1: an
        // `astore` and its feeding `aref` must never be DCE'd).
        if ((k == .guard and !dead[i]) or k == .astore) live[i] = true;
    }
    for (exit) |st| live[canon[st.ref]] = true;
    {
        var i = n;
        while (i > 0) {
            i -= 1;
            if (!live[i]) continue;
            const ins = instrs[i];
            // Only canonical, emittable instrs are ever marked live (roots use
            // `canon[...]`; propagation marks `canon[operand]`), so canon[i]==i.
            if (fold_aux[i] != null) continue; // now a konst: no operands to keep alive
            switch (kindOf(ins.op)) {
                .binary => {
                    live[canon[ins.a]] = true;
                    live[canon[ins.b]] = true;
                },
                .unary, .guard, .aload => live[canon[ins.a]] = true,
                // `aref` (table+index) and `astore` (aref+value) both keep two
                // operands alive.
                .aref, .astore => {
                    live[canon[ins.a]] = true;
                    live[canon[ins.b]] = true;
                },
                .konst, .slot_load, .loop => {},
            }
        }
    }

    // --- compaction (== the ref-remap) ---
    const new_index = try gpa.alloc(Ref, n);
    defer gpa.free(new_index);

    var out_instrs: std.ArrayListUnmanaged(IrInstr) = .empty;
    defer out_instrs.deinit(gpa);
    var out_entry: std.ArrayListUnmanaged(u16) = .empty;
    defer out_entry.deinit(gpa);

    for (instrs, 0..) |ins, i| {
        if (canon[i] != i) continue; // CSE-redirected → not emitted
        if (dead[i]) continue; // dropped guard → not emitted
        if (!live[i]) continue; // dead value → not emitted (loop & kept guards are live)
        new_index[i] = @intCast(out_instrs.items.len);
        var out = ins;
        if (fold_aux[i]) |aux| {
            out = .{ .op = .konst, .aux = aux, .ty = ins.ty };
        } else switch (kindOf(ins.op)) {
            .binary => {
                out.a = new_index[canon[ins.a]];
                out.b = new_index[canon[ins.b]];
            },
            .unary, .guard, .aload => out.a = new_index[canon[ins.a]],
            .aref, .astore => {
                out.a = new_index[canon[ins.a]];
                out.b = new_index[canon[ins.b]];
            },
            .slot_load => try out_entry.append(gpa, @intCast(ins.aux)),
            .konst, .loop => {},
        }
        try out_instrs.append(gpa, out);
    }

    var out_exit: std.ArrayListUnmanaged(SlotStore) = .empty;
    defer out_exit.deinit(gpa);
    for (exit) |st| try out_exit.append(gpa, .{ .slot = st.slot, .ref = new_index[canon[st.ref]] });

    // Transfer ownership; errdefer frees the already-owned slices if a later
    // toOwnedSlice OOMs, so we never leak on the failure path.
    const final_instrs = try out_instrs.toOwnedSlice(gpa);
    errdefer gpa.free(final_instrs);
    const final_consts = try out_consts.toOwnedSlice(gpa);
    errdefer gpa.free(final_consts);
    const final_entry = try out_entry.toOwnedSlice(gpa);
    errdefer gpa.free(final_entry);
    const final_exit = try out_exit.toOwnedSlice(gpa);
    return .{ .instrs = final_instrs, .consts = final_consts, .entry_slots = final_entry, .exit_stores = final_exit };
}

// ---------------------------------------------------------------------------
// Tests — hand-built IR (compiler-independent: the source compiler already
// constant-folds literal subexpressions, so a real program never feeds the
// trace recorder a `konst op konst`; we exercise the passes directly here).
// The end-to-end *transparency* of the optimizer — that optimized output equals
// unoptimized output equals tier-0 on real programs — is the 8-way `expectProgram`
// matrix in interp.zig. These tests pin the structural rewrites instead.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn freeOpt(gpa: std.mem.Allocator, o: *Optimized) void {
    gpa.free(o.instrs);
    gpa.free(o.consts);
    gpa.free(o.entry_slots);
    gpa.free(o.exit_stores);
}

fn countOp(instrs: []const IrInstr, op: IrOp) usize {
    var c: usize = 0;
    for (instrs) |ins| {
        if (ins.op == op) c += 1;
    }
    return c;
}

test "tropt: a constant subexpression folds to one konst and its operands die" {
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 2
        .{ .op = .konst, .aux = 1 }, // %1 = 3
        .{ .op = .add, .a = 0, .b = 1 }, // %2 = 2 + 3  → folds to 5
        .{ .op = .slot_load, .aux = 0 }, // %3 = r0      (loop-variant input)
        .{ .op = .add, .a = 3, .b = 2 }, // %4 = r0 + 5
        .{ .op = .loop }, // %5
    };
    const consts = [_]Value{ Value.int(2), Value.int(3) };
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 4 }};
    var opt = try optimize(gpa, &instrs, &consts, &exit);
    defer freeOpt(gpa, &opt);

    // %2 folded to a konst; %0 and %1 fed only the fold, so DCE drops them.
    // Survivors: konst(5), slot_load r0, add, loop.
    try testing.expectEqual(@as(usize, 4), opt.instrs.len);
    try testing.expectEqual(IrOp.konst, opt.instrs[0].op);
    try testing.expectEqual(@as(i64, 5), opt.consts[@intCast(opt.instrs[0].aux)].asInt());
    try testing.expectEqual(IrOp.loop, opt.instrs[3].op);
    // The loop-carried writeback still tracks the live `add`.
    try testing.expectEqual(@as(Ref, 2), opt.exit_stores[0].ref);
}

test "tropt: a guard on a proven-constant value is dropped; a guard on a live value is kept" {
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 5 (int)
        .{ .op = .guard_int, .a = 0 }, // %1 — always passes on a const int → drop
        .{ .op = .slot_load, .aux = 0 }, // %2 = r0
        .{ .op = .guard_int, .a = 2 }, // %3 — guards a runtime value → keep
        .{ .op = .add, .a = 0, .b = 2 }, // %4
        .{ .op = .loop }, // %5
    };
    const consts = [_]Value{Value.int(5)};
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 4 }};
    var opt = try optimize(gpa, &instrs, &consts, &exit);
    defer freeOpt(gpa, &opt);

    try testing.expectEqual(@as(usize, 5), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .guard_int));
}

test "tropt: an exact-duplicate guard is dropped (the earlier copy dominates)" {
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0
        .{ .op = .guard_int, .a = 0 }, // %1
        .{ .op = .guard_int, .a = 0 }, // %2 — duplicate → drop
        .{ .op = .add, .a = 0, .b = 0 }, // %3
        .{ .op = .loop }, // %4
    };
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 3 }};
    var opt = try optimize(gpa, &instrs, &.{}, &exit);
    defer freeOpt(gpa, &opt);

    try testing.expectEqual(@as(usize, 4), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .guard_int));
}

test "tropt: a guard_fits on a constant value uses laneFits (never the type-guard table)" {
    // Regression: the bool-lane `astore` value is the *constant* `false`, so its
    // `guard_fits` is the first guard whose operand is constant. The forward pass
    // must evaluate it via `laneFits(lane, v)` — routing it through the type-guard
    // `guardSatisfied` table (guard_int/…) hit `else => unreachable` and crashed
    // the optimizer at commit time. A fitting const drops the guard; a non-fitting
    // one is kept (always-fail, defensively retained).
    const gpa = testing.allocator;
    const bool_lane: i32 = @intFromEnum(arr.Lane.boolean);

    // false fits the bool lane → guard_fits is proven-pass → dropped.
    {
        const instrs = [_]IrInstr{
            .{ .op = .konst, .aux = 0 }, // %0 = false
            .{ .op = .guard_fits, .a = 0, .aux = bool_lane }, // %1 — always passes → drop
            .{ .op = .slot_load, .aux = 0 }, // %2 = r0 (keep something live)
            .{ .op = .loop }, // %3
        };
        const consts = [_]Value{Value.boolean(false)};
        const exit = [_]SlotStore{.{ .slot = 0, .ref = 2 }};
        var opt = try optimize(gpa, &instrs, &consts, &exit);
        defer freeOpt(gpa, &opt);
        try testing.expectEqual(@as(usize, 0), countOp(opt.instrs, .guard_fits));
    }

    // An int into the bool lane does NOT fit → guard_fits is kept (it would
    // side-exit at runtime; honest recording never emits this, but the optimizer
    // must not silently drop a possibly-failing guard).
    {
        const instrs = [_]IrInstr{
            .{ .op = .konst, .aux = 0 }, // %0 = 5
            .{ .op = .guard_fits, .a = 0, .aux = bool_lane }, // %1 — always fails → keep
            .{ .op = .loop }, // %2
        };
        const consts = [_]Value{Value.int(5)};
        const exit = [_]SlotStore{.{ .slot = 0, .ref = 0 }};
        var opt = try optimize(gpa, &instrs, &consts, &exit);
        defer freeOpt(gpa, &opt);
        try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .guard_fits));
    }
}

test "tropt: a repeated subexpression is CSE'd to a single instruction" {
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0
        .{ .op = .slot_load, .aux = 1 }, // %1 = r1
        .{ .op = .add, .a = 0, .b = 1 }, // %2 = r0 + r1
        .{ .op = .add, .a = 0, .b = 1 }, // %3 = r0 + r1  → canon to %2
        .{ .op = .add, .a = 2, .b = 3 }, // %4 = %2 + %3
        .{ .op = .loop }, // %5
    };
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 4 }};
    var opt = try optimize(gpa, &instrs, &.{}, &exit);
    defer freeOpt(gpa, &opt);

    // %3 vanishes; %4's two operands now both resolve to the surviving add.
    try testing.expectEqual(@as(usize, 5), opt.instrs.len);
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .add));
    const last_add = opt.instrs[3];
    try testing.expectEqual(IrOp.add, last_add.op);
    try testing.expectEqual(last_add.a, last_add.b);
}

test "tropt: a dead computation (and its now-unused input) is eliminated" {
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0
        .{ .op = .slot_load, .aux = 1 }, // %1 = r1  (feeds only the dead add)
        .{ .op = .add, .a = 0, .b = 1 }, // %2 — result never used → dead
        .{ .op = .mul, .a = 0, .b = 0 }, // %3 = r0 * r0  (the live result)
        .{ .op = .loop }, // %4
    };
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 3 }};
    var opt = try optimize(gpa, &instrs, &.{}, &exit);
    defer freeOpt(gpa, &opt);

    // Survivors: slot_load r0, mul, loop. r1's slot_load dies with the dead add,
    // so the rebuilt entry snapshot loses it too.
    try testing.expectEqual(@as(usize, 3), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), opt.entry_slots.len);
    try testing.expectEqual(@as(u16, 0), opt.entry_slots[0]);
}

test "tropt: a fold that would error (int //-by-zero) is left as a runtime op, never deleted" {
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 1
        .{ .op = .konst, .aux = 1 }, // %1 = 0
        .{ .op = .idiv, .a = 0, .b = 1 }, // %2 = 1 // 0  → DivisionByZero, NOT folded
        .{ .op = .loop }, // %3
    };
    const consts = [_]Value{ Value.int(1), Value.int(0) };
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 2 }};
    var opt = try optimize(gpa, &instrs, &consts, &exit);
    defer freeOpt(gpa, &opt);

    // The idiv stays (so it side-exits at runtime and tier-0 re-raises); its const
    // operands stay live to feed it.
    try testing.expectEqual(@as(usize, 4), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .idiv));
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .konst));
}

/// Build `konst a; konst b; <op> 0 1; loop` (exit r0 ← the op) and return the
/// folded constant. Asserts the op folded to exactly one konst.
fn foldBinaryConst(gpa: std.mem.Allocator, op: IrOp, a: Value, b: Value) !Value {
    const instrs = [_]IrInstr{
        .{ .op = .konst, .aux = 0 },
        .{ .op = .konst, .aux = 1 },
        .{ .op = op, .a = 0, .b = 1 },
        .{ .op = .loop },
    };
    const consts = [_]Value{ a, b };
    const exit = [_]SlotStore{.{ .slot = 0, .ref = 2 }};
    var opt = try optimize(gpa, &instrs, &consts, &exit);
    defer freeOpt(gpa, &opt);
    try testing.expectEqual(@as(usize, 2), opt.instrs.len); // konst + loop
    try testing.expectEqual(IrOp.konst, opt.instrs[0].op);
    return opt.consts[@intCast(opt.instrs[0].aux)];
}

test "tropt: folding poison constants matches the shared evaluator and never traps" {
    const gpa = testing.allocator;

    // Shift count |n| >= 64 masks to 0 in arith.zig — not UB, not a trap.
    {
        const got = try foldBinaryConst(gpa, .shl, Value.int(1), Value.int(100));
        const want = try irinterp.evalBinary(.shl, Value.int(1), Value.int(100));
        try testing.expect(got.eql(want));
    }
    // NaN == NaN: folds to whatever arith.eq decides, bit-identical to runtime.
    {
        const nan = Value.float(std.math.nan(f64));
        const got = try foldBinaryConst(gpa, .eq, nan, nan);
        const want = try irinterp.evalBinary(.eq, nan, nan);
        try testing.expect(got.eql(want));
    }
    // INT64_MIN // -1 wraps (no SIGFPE); the fold must match the evaluator.
    {
        const lo = Value.int(std.math.minInt(i64));
        const got = try foldBinaryConst(gpa, .idiv, lo, Value.int(-1));
        const want = try irinterp.evalBinary(.idiv, lo, Value.int(-1));
        try testing.expect(got.eql(want));
    }
}
