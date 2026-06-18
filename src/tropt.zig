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
/// `trace.zig`'s `commit`, which stores them in the cached `Trace`. The
/// loop-carried writebacks live in the instruction stream as slot-bound `phi`
/// nodes (they used to be a separate `exit_stores` list).
pub const Optimized = struct {
    instrs: []IrInstr,
    consts: []Value,
    entry_slots: []u16,
};

const OpKind = enum { konst, slot_load, binary, unary, cvt, guard, aref, aload, astore, loop, phi, preheader };

fn kindOf(op: IrOp) OpKind {
    return switch (op) {
        .konst => .konst,
        .slot_load => .slot_load,
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .eq, .ne, .lt, .le => .binary,
        .neg, .not, .bnot => .unary,
        // `int_of_float`: a value producer that ALSO side-exits. Its own `cvt` kind
        // so it is a liveness root (its side-exit must survive DCE) yet still emits
        // a value (the int limit) the body's compare consumes — and is invariant-
        // hoistable (its result depends only on the loop-invariant float limit).
        .int_of_float => .cvt,
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false => .guard,
        // Array-access guards reuse the guard machinery: kept as side-effecting
        // roots, deduped by (op, operand-ref), operand marked/remapped via `a`.
        // `guard_append` is the grow analogue of `guard_bounds`; it reads `len`/`cap`
        // (which `astore_append` writes), so classifying it `.guard` keeps it a
        // side-effecting root that is never hoisted above the store.
        .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits, .guard_append => .guard,
        // Packed-array address + load: memory ops, conservatively canonical to
        // themselves (never folded, never CSE'd) so a later store can't be
        // reordered past them. DCE'd if not reachable from a live root.
        .aref => .aref,
        .aload => .aload,
        // `astore_append` is the grow analogue of `astore`: an effectful, never-DCE'd
        // alias/CSE barrier. Same `.astore` kind (reads `a`=aref + `b`=value).
        .astore, .astore_append => .astore,
        .loop => .loop,
        // Loop-carried value: a root (the carry); canonical to itself (never
        // folded/CSE'd). Keeps both operands live; `b` is a forward (back-edge)
        // ref, remapped by a fixup after compaction.
        .phi => .phi,
        // Preheader marker (Phase E1): a structural boundary. Never present in a
        // freshly-recorded trace (the recorder emits none); the LICM pass below
        // *synthesizes* it during compaction. Mapped for switch-exhaustiveness.
        .preheader => .preheader,
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
) !Optimized {
    const out_instrs = try gpa.dupe(IrInstr, instrs);
    errdefer gpa.free(out_instrs);
    const out_consts = try gpa.dupe(Value, consts);
    errdefer gpa.free(out_consts);
    const out_entry = try gpa.dupe(u16, entry_slots);
    return .{ .instrs = out_instrs, .consts = out_consts, .entry_slots = out_entry };
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
            // `int_of_float`: canonical to itself — never folded (its operand is the
            // loop-invariant float limit slot_load, never a constant) and never CSE'd
            // (at most one per trace). Kept as a side-effecting root by the liveness
            // pass below, like a guard, since it can side-exit.
            .cvt => {},
            // Memory ops are left verbatim: canonical to themselves, no fold/CSE.
            // `aload` is never CSE'd (each is its own canonical ref), so an
            // `astore` between two reads of the same slot cannot let the later
            // read reuse the earlier (pre-store) value — the alias-barrier
            // property holds for free. `astore` is effectful: never folded, never
            // CSE'd, kept as a root by the liveness pass below (I1).
            .aref, .aload, .astore => {},
            .loop => {},
            // φ is a loop-carried root: canonical to itself, never folded/CSE'd.
            .phi => {},
            // Never present in the recorder's input (synthesized at compaction).
            .preheader => {},
        }
    }

    // --- backward liveness from explicit roots ---
    // Roots: the `loop` terminator, every kept guard (side-effecting), and every
    // `phi` (the loop carry / deopt writeback — forgetting one would strip the
    // loop-carried computation and resume tier-0 with stale registers).
    const live = try gpa.alloc(bool, n);
    defer gpa.free(live);
    @memset(live, false);
    live[n - 1] = true; // loop
    for (instrs, 0..) |ins, i| {
        const k = kindOf(ins.op);
        // Kept guards and every `astore` are side-effecting roots (I1: an
        // `astore` and its feeding `aref` must never be DCE'd). Every φ is a root:
        // it is the loop carry / the deopt writeback, never dead.
        // `.cvt` (int_of_float) is a side-effecting root: it can side-exit, so it must
        // never be DCE'd even if its value looked dead — exactly like a kept guard.
        if ((k == .guard and !dead[i]) or k == .astore or k == .phi or k == .cvt) live[i] = true;
        // A φ's back-edge update `b` may be a FORWARD ref (`b > i`) —
        // `assertWellFormed` permits it (only φ.b may point past its own index),
        // and an internal SR φ's `update = add(φ, Δ)` necessarily does. The single
        // backward propagation pass below sweeps high→low, so it would pass `b`
        // *before* the φ marks it live and never revisit `b`'s operands, dropping
        // them as dead → wild refs after compaction. Pre-mark every φ.b live here
        // (canon is final) so the backward pass propagates `b`'s operands when it
        // reaches `b`. For a backward `b` (every E0 φ) this is a redundant no-op.
        if (ins.op == .phi) live[canon[ins.b]] = true;
    }
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
                .unary, .cvt, .guard, .aload => live[canon[ins.a]] = true,
                // `aref` (table+index) and `astore` (aref+value) both keep two
                // operands alive.
                .aref, .astore => {
                    live[canon[ins.a]] = true;
                    live[canon[ins.b]] = true;
                },
                // φ always keeps its back-edge update `b` alive. The init `a` is a
                // real ref only for an *internal* φ (the preheader value); a
                // slot-bound φ's init is implicit (`regs[slot]`), so `a` is 0/unused.
                .phi => {
                    live[canon[ins.b]] = true;
                    if (ins.aux == trace.PHI_INTERNAL) live[canon[ins.a]] = true;
                },
                .konst, .slot_load, .loop, .preheader => {},
            }
        }
    }

    // --- LICM (Phase E1): mark the loop-invariant computation to hoist ---
    //
    // A tier-0 slot is *carried* iff some φ flushes to it (`aux >= 0`): its
    // register changes across iterations, so its `slot_load` is loop-variant.
    // Every *other* slot_load reads a value fixed for the whole loop. A value is
    // **invariant** iff it is a `konst`, an invariant `slot_load`, a folded
    // constant, or a pure op (binary/unary) over invariant operands. An invariant
    // *computed* op (`hoist[i]`) is worth moving into a run-once preheader region;
    // its invariant operand cone moves with it. Guards/memory/φ are never hoisted
    // in this first cut (a guard on an invariant value is cheap and re-checking it
    // each iteration is harmless; hoisting it is a later refinement).
    //
    // Soundness: a preheader value is computed once and reused. Because it is pure
    // and depends only on invariants, the iteration-1 value is bit-identical to
    // what re-evaluating it each iteration would yield. A preheader op that would
    // *error* (e.g. a type mismatch the body's guard catches) is evaluated before
    // that guard, but the executor side-exits on the error with the SAME
    // `completed` count tier-0 reaches, and tier-0 re-runs the partial iteration —
    // so the observable result is unchanged (see `irinterp.zig`'s deopt contract).
    var carried_slots: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer carried_slots.deinit(gpa);
    for (instrs) |ins| {
        if (ins.op == .phi and ins.aux >= 0) try carried_slots.put(gpa, ins.aux, {});
    }

    const inv = try gpa.alloc(bool, n);
    defer gpa.free(inv);
    @memset(inv, false);
    const hoist = try gpa.alloc(bool, n);
    defer gpa.free(hoist);
    @memset(hoist, false);
    for (instrs, 0..) |ins, i| {
        if (canon[i] != i or dead[i]) continue; // only canonical survivors carry inv
        if (fold_aux[i] != null) {
            inv[i] = true; // folded → becomes a konst → invariant (not a hoist target)
            continue;
        }
        switch (kindOf(ins.op)) {
            .konst => inv[i] = true,
            .slot_load => inv[i] = !carried_slots.contains(ins.aux),
            .binary => {
                // `idiv`/`mod` can raise DivisionByZero mid-iteration. Treat them
                // (and therefore anything that consumes them) as NON-invariant, so
                // they stay in the body and side-exit at the exact point tier-0
                // re-raises — never hoisted into the run-once preheader. (Mirrors
                // the folder's "evalBinary error → leave as a runtime op" rule.)
                // Every other binary op is total (wraps/masks) or only TypeErrors
                // on a wrong-typed operand the body's guard catches first, so
                // hoisting it preserves the deopt outcome.
                if (ins.op == .idiv or ins.op == .mod) {
                    inv[i] = false;
                } else {
                    inv[i] = inv[canon[ins.a]] and inv[canon[ins.b]];
                    hoist[i] = inv[i];
                }
            },
            .unary => {
                inv[i] = inv[canon[ins.a]];
                hoist[i] = inv[i];
            },
            // `int_of_float`: invariant iff its float-limit operand is (it always is —
            // a guard_float-covered loop-invariant slot_load). Hoisting moves its single
            // side-exit to the run-once preheader; sound because the OUTCOME is loop-
            // invariant — pass or side-exit at completed=0 is identical whether the op
            // runs once in the preheader or every iteration in the body (same deopt
            // outcome, per the LICM soundness note above). Hoisting it (and its operand
            // cone) means one conversion per entry instead of per iteration.
            .cvt => {
                inv[i] = inv[canon[ins.a]];
                hoist[i] = inv[i];
            },
            // Guards, memory ops, the loop terminator, φ: not invariant-hoistable.
            .guard, .aref, .aload, .astore, .loop, .phi, .preheader => {},
        }
    }

    // Preheader membership = every `hoist` op plus its transitive invariant operand
    // cone. One backward pass suffices (operands precede their use): seed `hoist`,
    // then pull each preheader op's operands (all invariant by construction) in.
    const in_pre = try gpa.alloc(bool, n);
    defer gpa.free(in_pre);
    @memset(in_pre, false);
    {
        var i = n;
        while (i > 0) {
            i -= 1;
            if (canon[i] != i or dead[i] or !live[i]) continue;
            if (hoist[i]) in_pre[i] = true;
            if (!in_pre[i]) continue;
            switch (kindOf(instrs[i].op)) {
                .binary => {
                    in_pre[canon[instrs[i].a]] = true;
                    in_pre[canon[instrs[i].b]] = true;
                },
                .unary, .cvt => in_pre[canon[instrs[i].a]] = true,
                else => {}, // konst / invariant slot_load: leaf of the cone
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
    // φ `b` is a back-edge (forward) ref: its target's `new_index` is not yet known
    // when the φ is emitted. Record (emitted-position, old-canonical-b) pairs and
    // patch them once every `new_index` is assigned.
    var phi_fixups: std.ArrayListUnmanaged(struct { pos: usize, b: Ref }) = .empty;
    defer phi_fixups.deinit(gpa);

    // Emit order: every preheader survivor first (in index order, so SSA holds
    // within the region), then the synthesized `preheader` marker, then the body.
    // A body op may reference a preheader op (assigned a lower `new_index` in the
    // first pass) or an earlier body op — both are emitted before it, so the
    // ref-remap stays valid. The marker is emitted only when the preheader is
    // non-empty, keeping a no-invariant trace byte-identical to pre-E1.
    const MARKER = std.math.maxInt(usize);
    var order: std.ArrayListUnmanaged(usize) = .empty;
    defer order.deinit(gpa);
    var n_pre: usize = 0;
    for (0..n) |i| {
        if (canon[i] != i or dead[i] or !live[i]) continue;
        if (in_pre[i]) {
            try order.append(gpa, i);
            n_pre += 1;
        }
    }
    if (n_pre > 0) try order.append(gpa, MARKER);
    for (0..n) |i| {
        if (canon[i] != i or dead[i] or !live[i]) continue;
        if (!in_pre[i]) try order.append(gpa, i);
    }

    for (order.items) |entry| {
        if (entry == MARKER) {
            try out_instrs.append(gpa, .{ .op = .preheader });
            continue;
        }
        const i = entry;
        const ins = instrs[i];
        new_index[i] = @intCast(out_instrs.items.len);
        var out = ins;
        if (fold_aux[i]) |aux| {
            out = .{ .op = .konst, .aux = aux, .ty = ins.ty };
        } else switch (kindOf(ins.op)) {
            .binary => {
                out.a = new_index[canon[ins.a]];
                out.b = new_index[canon[ins.b]];
            },
            .unary, .cvt, .guard, .aload => out.a = new_index[canon[ins.a]],
            .aref, .astore => {
                out.a = new_index[canon[ins.a]];
                out.b = new_index[canon[ins.b]];
            },
            .phi => {
                // init `a` is a real backward ref only for an internal φ (remap
                // now); a slot-bound φ's `a` is unused (kept 0). Update `b` is the
                // forward back-edge → defer to the fixup pass below.
                out.a = if (ins.aux == trace.PHI_INTERNAL) new_index[canon[ins.a]] else 0;
                try phi_fixups.append(gpa, .{ .pos = out_instrs.items.len, .b = canon[ins.b] });
            },
            .slot_load => try out_entry.append(gpa, @intCast(ins.aux)),
            // `.preheader` is never an input op (the MARKER sentinel emits the
            // marker above); kept for switch-exhaustiveness.
            .konst, .loop, .preheader => {},
        }
        try out_instrs.append(gpa, out);
    }
    // Patch each φ's back-edge ref now that every survivor has a `new_index`.
    for (phi_fixups.items) |f| out_instrs.items[f.pos].b = new_index[f.b];

    // Transfer ownership; errdefer frees the already-owned slices if a later
    // toOwnedSlice OOMs, so we never leak on the failure path.
    const final_instrs = try out_instrs.toOwnedSlice(gpa);
    errdefer gpa.free(final_instrs);
    const final_consts = try out_consts.toOwnedSlice(gpa);
    errdefer gpa.free(final_consts);
    const final_entry = try out_entry.toOwnedSlice(gpa);
    return .{ .instrs = final_instrs, .consts = final_consts, .entry_slots = final_entry };
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
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 2
        .{ .op = .konst, .aux = 1 }, // %1 = 3
        .{ .op = .add, .a = 0, .b = 1 }, // %2 = 2 + 3  → folds to 5
        .{ .op = .slot_load, .aux = 0 }, // %3 = r0      (loop-variant input)
        .{ .op = .add, .a = 3, .b = 2 }, // %4 = r0 + 5
        .{ .op = .loop }, // %5
    }, &[_]SlotStore{.{ .slot = 0, .ref = 4 }});
    const consts = [_]Value{ Value.int(2), Value.int(3) };
    var opt = try optimize(gpa, &instrs, &consts);
    defer freeOpt(gpa, &opt);

    // %2 folded to a konst; %0 and %1 fed only the fold, so DCE drops them.
    // Survivors: konst(5), slot_load r0, add, φ(r0), loop.
    try testing.expectEqual(@as(usize, 5), opt.instrs.len);
    try testing.expectEqual(IrOp.konst, opt.instrs[0].op);
    try testing.expectEqual(@as(i64, 5), opt.consts[@intCast(opt.instrs[0].aux)].asInt());
    try testing.expectEqual(IrOp.loop, opt.instrs[4].op);
    // The loop-carried writeback (slot-bound φ) still tracks the live `add` (now %2).
    try testing.expectEqual(IrOp.phi, opt.instrs[3].op);
    try testing.expectEqual(@as(Ref, 2), opt.instrs[3].b);
}

test "tropt: a φ with a FORWARD back-edge update keeps the update's operands live" {
    // Regression (E0 review, Codex+Antigravity): an internal φ placed *before* its
    // `update = add(φ, Δ)` has a forward `b` (`b > i`), which `assertWellFormed`
    // permits. The single backward liveness pass must not sweep past the update and
    // drop its operands. Here `konst 2` (%3) feeds ONLY the internal φ's update
    // (%5); with the bug it is dropped and %5.b points at a wild ref.
    const gpa = testing.allocator;
    const instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0 (basic IV input)
        .{ .op = .phi, .a = 0, .b = 5, .aux = trace.PHI_INTERNAL, .ty = .int }, // %1 internal φ, FORWARD b=%5
        .{ .op = .konst, .aux = 0 }, // %2 = 1  (feeds the r0 carry)
        .{ .op = .konst, .aux = 1 }, // %3 = 2  (feeds ONLY the internal φ update)
        .{ .op = .add, .a = 0, .b = 2 }, // %4 = r0 + 1   (slot-bound carry update)
        .{ .op = .add, .a = 1, .b = 3 }, // %5 = φ  + 2   (internal φ update; %1.b target)
        .{ .op = .phi, .a = 0, .b = 4, .aux = 0, .ty = .int }, // %6 slot-bound φ → r0
        .{ .op = .loop }, // %7
    };
    const consts = [_]Value{ Value.int(1), Value.int(2) };
    var opt = try optimize(gpa, &instrs, &consts);
    defer freeOpt(gpa, &opt);

    // Both konsts survive (the bug would drop konst 2), both adds survive, both φs.
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .konst));
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .add));
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .phi));
    // The internal φ's forward update `b` resolves to a live `add` whose operands
    // are both in range (no wild ref from a dropped operand).
    for (opt.instrs, 0..) |ins, i| {
        if (ins.op != .phi or ins.aux != trace.PHI_INTERNAL) continue;
        try testing.expect(ins.b < opt.instrs.len - 1); // forward, < loop
        const upd = opt.instrs[ins.b];
        try testing.expectEqual(IrOp.add, upd.op);
        try testing.expect(upd.a < ins.b and upd.b < ins.b); // operands backward & valid
        try testing.expectEqual(IrOp.konst, opt.instrs[upd.b].op); // konst 2 alive
        try testing.expectEqual(@as(i64, 2), opt.consts[@intCast(opt.instrs[upd.b].aux)].asInt());
        _ = i;
    }
}

test "tropt: a guard on a proven-constant value is dropped; a guard on a live value is kept" {
    const gpa = testing.allocator;
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 5 (int)
        .{ .op = .guard_int, .a = 0 }, // %1 — always passes on a const int → drop
        .{ .op = .slot_load, .aux = 0 }, // %2 = r0
        .{ .op = .guard_int, .a = 2 }, // %3 — guards a runtime value → keep
        .{ .op = .add, .a = 0, .b = 2 }, // %4
        .{ .op = .loop }, // %5
    }, &[_]SlotStore{.{ .slot = 0, .ref = 4 }});
    const consts = [_]Value{Value.int(5)};
    var opt = try optimize(gpa, &instrs, &consts);
    defer freeOpt(gpa, &opt);

    // Survivors: konst(5), slot_load r0, guard_int, add, φ(r0), loop.
    try testing.expectEqual(@as(usize, 6), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .guard_int));
}

test "tropt: an exact-duplicate guard is dropped (the earlier copy dominates)" {
    const gpa = testing.allocator;
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0
        .{ .op = .guard_int, .a = 0 }, // %1
        .{ .op = .guard_int, .a = 0 }, // %2 — duplicate → drop
        .{ .op = .add, .a = 0, .b = 0 }, // %3
        .{ .op = .loop }, // %4
    }, &[_]SlotStore{.{ .slot = 0, .ref = 3 }});
    var opt = try optimize(gpa, &instrs, &.{});
    defer freeOpt(gpa, &opt);

    // Survivors: slot_load r0, guard_int, add, φ(r0), loop.
    try testing.expectEqual(@as(usize, 5), opt.instrs.len);
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
        const instrs = trace.withPhis(&[_]IrInstr{
            .{ .op = .konst, .aux = 0 }, // %0 = false
            .{ .op = .guard_fits, .a = 0, .aux = bool_lane }, // %1 — always passes → drop
            .{ .op = .slot_load, .aux = 0 }, // %2 = r0 (keep something live)
            .{ .op = .loop }, // %3
        }, &[_]SlotStore{.{ .slot = 0, .ref = 2 }});
        const consts = [_]Value{Value.boolean(false)};
        var opt = try optimize(gpa, &instrs, &consts);
        defer freeOpt(gpa, &opt);
        try testing.expectEqual(@as(usize, 0), countOp(opt.instrs, .guard_fits));
    }

    // An int into the bool lane does NOT fit → guard_fits is kept (it would
    // side-exit at runtime; honest recording never emits this, but the optimizer
    // must not silently drop a possibly-failing guard).
    {
        const instrs = trace.withPhis(&[_]IrInstr{
            .{ .op = .konst, .aux = 0 }, // %0 = 5
            .{ .op = .guard_fits, .a = 0, .aux = bool_lane }, // %1 — always fails → keep
            .{ .op = .loop }, // %2
        }, &[_]SlotStore{.{ .slot = 0, .ref = 0 }});
        const consts = [_]Value{Value.int(5)};
        var opt = try optimize(gpa, &instrs, &consts);
        defer freeOpt(gpa, &opt);
        try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .guard_fits));
    }
}

test "tropt: a repeated subexpression is CSE'd to a single instruction" {
    const gpa = testing.allocator;
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0
        .{ .op = .slot_load, .aux = 1 }, // %1 = r1
        .{ .op = .add, .a = 0, .b = 1 }, // %2 = r0 + r1
        .{ .op = .add, .a = 0, .b = 1 }, // %3 = r0 + r1  → canon to %2
        .{ .op = .add, .a = 2, .b = 3 }, // %4 = %2 + %3
        .{ .op = .loop }, // %5
    }, &[_]SlotStore{.{ .slot = 0, .ref = 4 }});
    var opt = try optimize(gpa, &instrs, &.{});
    defer freeOpt(gpa, &opt);

    // %3 vanishes; %4's two operands now both resolve to the surviving add.
    // Survivors: slot_load r0, slot_load r1, add, add, φ(r0), loop.
    try testing.expectEqual(@as(usize, 6), opt.instrs.len);
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .add));
    const last_add = opt.instrs[3];
    try testing.expectEqual(IrOp.add, last_add.op);
    try testing.expectEqual(last_add.a, last_add.b);
}

test "tropt: a dead computation (and its now-unused input) is eliminated" {
    const gpa = testing.allocator;
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0 = r0
        .{ .op = .slot_load, .aux = 1 }, // %1 = r1  (feeds only the dead add)
        .{ .op = .add, .a = 0, .b = 1 }, // %2 — result never used → dead
        .{ .op = .mul, .a = 0, .b = 0 }, // %3 = r0 * r0  (the live result)
        .{ .op = .loop }, // %4
    }, &[_]SlotStore{.{ .slot = 0, .ref = 3 }});
    var opt = try optimize(gpa, &instrs, &.{});
    defer freeOpt(gpa, &opt);

    // Survivors: slot_load r0, mul, φ(r0), loop. r1's slot_load dies with the dead
    // add, so the rebuilt entry snapshot loses it too.
    try testing.expectEqual(@as(usize, 4), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), opt.entry_slots.len);
    try testing.expectEqual(@as(u16, 0), opt.entry_slots[0]);
}

test "tropt: a fold that would error (int //-by-zero) is left as a runtime op, never deleted" {
    const gpa = testing.allocator;
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .konst, .aux = 0 }, // %0 = 1
        .{ .op = .konst, .aux = 1 }, // %1 = 0
        .{ .op = .idiv, .a = 0, .b = 1 }, // %2 = 1 // 0  → DivisionByZero, NOT folded
        .{ .op = .loop }, // %3
    }, &[_]SlotStore{.{ .slot = 0, .ref = 2 }});
    const consts = [_]Value{ Value.int(1), Value.int(0) };
    var opt = try optimize(gpa, &instrs, &consts);
    defer freeOpt(gpa, &opt);

    // The idiv stays (so it side-exits at runtime and tier-0 re-raises); its const
    // operands stay live to feed it. Survivors: konst, konst, idiv, φ(r0), loop.
    try testing.expectEqual(@as(usize, 5), opt.instrs.len);
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .idiv));
    try testing.expectEqual(@as(usize, 2), countOp(opt.instrs, .konst));
}

/// Build `konst a; konst b; <op> 0 1; loop` (exit r0 ← the op) and return the
/// folded constant. Asserts the op folded to exactly one konst.
fn foldBinaryConst(gpa: std.mem.Allocator, op: IrOp, a: Value, b: Value) !Value {
    const instrs = trace.withPhis(&[_]IrInstr{
        .{ .op = .konst, .aux = 0 },
        .{ .op = .konst, .aux = 1 },
        .{ .op = op, .a = 0, .b = 1 },
        .{ .op = .loop },
    }, &[_]SlotStore{.{ .slot = 0, .ref = 2 }});
    const consts = [_]Value{ a, b };
    var opt = try optimize(gpa, &instrs, &consts);
    defer freeOpt(gpa, &opt);
    try testing.expectEqual(@as(usize, 3), opt.instrs.len); // konst + φ + loop
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

// ---------------------------------------------------------------------------
// E1 — preheader region + LICM. The structural test pins the rewrite (an
// invariant subexpression moves before a `preheader` marker); the differential
// test is the *behavioural* gate (optimized vs unoptimized execute byte-
// identically over a bounded loop). The end-to-end tier-0-vs-optimized gate
// lives in interp.zig's `expectProgram` matrix; this is the committable,
// compiler-independent IR-level proof that hoisting is value-preserving.
// ---------------------------------------------------------------------------

/// `acc = acc + a*b; counter -= 1` with `a`(r0), `b`(r1) invariant; `acc`(r2),
/// `counter`(r3) carried; `1 // counter` (r4 = junk) side-exits via DivByZero
/// when the counter reaches 0, giving a bounded loop. The `a*b` (`mul`) is the
/// sole loop invariant — LICM must hoist it into a preheader. Returns the
/// `withPhis`-shaped *unoptimized* IR plus its const pool.
fn licmInvariantMulTrace() struct { instrs: [13]IrInstr, consts: [1]Value } {
    return .{
        .instrs = trace.withPhis(&[_]IrInstr{
            .{ .op = .slot_load, .aux = 0, .ty = .int }, // %0 = r0 (a)   invariant
            .{ .op = .slot_load, .aux = 1, .ty = .int }, // %1 = r1 (b)   invariant
            .{ .op = .slot_load, .aux = 2, .ty = .int }, // %2 = r2 (acc) carried
            .{ .op = .slot_load, .aux = 3, .ty = .int }, // %3 = r3 (cnt) carried
            .{ .op = .konst, .aux = 0, .ty = .int }, // %4 = 1
            .{ .op = .mul, .a = 0, .b = 1, .ty = .int }, // %5 = a*b   INVARIANT → hoist
            .{ .op = .idiv, .a = 4, .b = 3, .ty = .int }, // %6 = 1 // cnt (exits at cnt==0)
            .{ .op = .add, .a = 2, .b = 5, .ty = .int }, // %7 = acc + a*b
            .{ .op = .sub, .a = 3, .b = 4, .ty = .int }, // %8 = cnt - 1
            .{ .op = .loop }, // %9
        }, &[_]SlotStore{
            .{ .slot = 2, .ref = 7 }, // acc   ← %7
            .{ .slot = 3, .ref = 8 }, // cnt   ← %8
            .{ .slot = 4, .ref = 6 }, // r4    ← %6 (keeps the idiv live)
        }),
        .consts = [_]Value{Value.int(1)},
    };
}

test "tropt E1: a loop-invariant subexpression is hoisted before a preheader marker" {
    const gpa = testing.allocator;
    var t = licmInvariantMulTrace();
    var opt = try optimize(gpa, &t.instrs, &t.consts);
    defer freeOpt(gpa, &opt);

    // Exactly one preheader marker and one `mul`, and the `mul` precedes the
    // marker — i.e. it now runs once in the preheader region, not per-iteration.
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .preheader));
    try testing.expectEqual(@as(usize, 1), countOp(opt.instrs, .mul));
    var marker: ?usize = null;
    var mul_idx: ?usize = null;
    for (opt.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) marker = i;
        if (ins.op == .mul) mul_idx = i;
    }
    try testing.expect(mul_idx.? < marker.?);
    // Nothing was deleted — LICM is pure motion, so the only structural change
    // vs the unoptimized trace is the added marker (one extra instruction).
    try testing.expectEqual(t.instrs.len + 1, opt.instrs.len);
}

test "tropt E1: hoisting preserves behaviour (optimized ≡ unoptimized over a bounded loop)" {
    const gpa = testing.allocator;
    var t = licmInvariantMulTrace();
    var opt = try optimize(gpa, &t.instrs, &t.consts);
    defer freeOpt(gpa, &opt);

    // Drive both traces from the same entry state. a=3, b=4, acc=0, cnt=5, r4=0.
    // Each clean iteration: acc += 12, cnt -= 1; the 6th reads cnt==0 → DivByZero
    // side-exit. Expect 5 commits, acc=60, cnt=0 in BOTH the unoptimized and the
    // LICM-optimized run — a divergence would mean the hoist changed a value.
    const unopt = trace.Trace{ .anchor = undefined, .instrs = &t.instrs, .consts = &t.consts, .entry_slots = &.{}, .entry_guards = &.{} };
    const opted = trace.Trace{ .anchor = undefined, .instrs = opt.instrs, .consts = opt.consts, .entry_slots = opt.entry_slots, .entry_guards = &.{} };

    var regs_u = [5]Value{ Value.int(3), Value.int(4), Value.int(0), Value.int(5), Value.int(0) };
    var regs_o = regs_u;
    var vals_u: [16]Value = undefined;
    var vals_o: [16]Value = undefined;
    const done_u = irinterp.execute(&unopt, &regs_u, &vals_u).completed;
    const done_o = irinterp.execute(&opted, &regs_o, &vals_o).completed;

    try testing.expectEqual(@as(usize, 5), done_u);
    try testing.expectEqual(done_u, done_o);
    try testing.expectEqual(@as(i64, 60), regs_u[2].asInt());
    try testing.expectEqual(@as(i64, 0), regs_u[3].asInt());
    for (regs_u, regs_o) |u, o| try testing.expect(u.eql(o));
}
