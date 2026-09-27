//! Doc 56 §4.3 (Phase 2): exit ATTACHABILITY and the RESUME PC.
//!
//! An exit is *attachable* when it could take the resume-coherent path
//! (§4.1): materialize the tier-0 state at a resume pc `P`, then continue
//! at `P` in a side trace or in tier-0. This module answers two pure
//! questions about a committed ordinary trace:
//!   * `classify` — may exit `e` take that path, and if not, why not;
//!   * `resumeOf` — which `P` it resumes at (the branch fix-up included).
//!
//! Both are pure functions of the immutable `TraceCode` (IR, ordinals,
//! exit snapshots, provenance) and its anchor proto's bytecode, so the
//! verdict is computed once at commit (`buildMemo`) and read by later
//! phases; nothing here can drift after commit. The module is inert: no
//! runtime path consults it yet.
//!
//! The rules, each fail-closed (an unknown shape is refused):
//!   1. the trace is ordinary (not precise), not peeled, and loop-anchored
//!      at a raw pc (one-shot head/cont anchors are refused);
//!   2. the exit is a side-exit guard with an ordinal and a snapshot;
//!   3. its provenance is a complete `.guard` entry at inline depth 0 in
//!      the anchor proto, and it is not a numeric-for loop-done exit;
//!   4. provenance, the guard's own pc and the snapshot name the same
//!      bytecode `B`;
//!   5. a branch guard's `B` is `jmp_if_true`/`jmp_if_false`, its polarity
//!      agrees with its op, and the not-taken successor is in range;
//!   6. (Q6) no instruction of `B` before the guard has an effect
//!      (`resumeClass` is not `.neutral`): re-executing `B` from its
//!      boundary snapshot must redo exactly what the trace did;
//!   7. every store after the guard from an EARLIER bytecode (ordinal
//!      below `B`'s — the sunk stores the adapter must apply first) is a
//!      kind the flush emitters model (`astore`/`hstore`/`gstore`/
//!      `ustore`), carries an ordinal, and reads only values computed by
//!      the guard (directly, as a constant, or through an address token
//!      whose own operands are);
//!   8. `P` is not a loop header, and a continuation started at `P`
//!      reaches an enclosing back-edge (`continuationReachesEnclosingBackEdge`,
//!      the loop-done continuation's own gate);
//!   9. `P` is not the CONSUMER half of a multret pair (a `call`/`ret` whose
//!      `b` is `all_results`): tier-0 reads its count from the transient
//!      `Vm.reg_top` its producer stamped, which no snapshot carries.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const trace_types = @import("trace_types.zig");

const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const IrOp = trace_ir.IrOp;
const IrInstr = trace_ir.IrInstr;
const Ref = trace_ir.Ref;
const TraceCode = trace_code.TraceCode;

/// Why an exit is or is not attachable. Reported in `--jit-stats` and the
/// jit-debug probe; tests pin each one.
pub const Verdict = enum(u8) {
    attachable,
    /// Rule 1: a precise or peeled trace, or a one-shot anchor.
    trace_shape,
    /// Rule 2: not a side-exit guard, or no ordinal or snapshot.
    no_snapshot,
    /// Rule 3: provenance incomplete, missing, or not a guard's.
    no_provenance,
    /// Rule 3: inside an inlined frame, or not in the anchor proto.
    inlined,
    /// Rule 3: a numeric-for loop-done exit (the continuation machinery
    /// already owns those).
    loop_done,
    /// Rule 4: provenance, guard pc and snapshot disagree on `B`.
    resume_mismatch,
    /// Rule 5: a branch guard without a clean not-taken successor.
    branch_shape,
    /// Rule 6 (Q6): `B` made an effect before the guard.
    own_effect,
    /// Rule 7: an earlier bytecode's sunk effect the flush does not model.
    store_kind,
    /// Rule 7: a store after the guard with no ordinal.
    store_unordered,
    /// Rule 7: an earlier bytecode's sunk store reads a value the guard
    /// has not computed yet.
    store_operand,
    /// Rule 8: `P` is a loop header (the target would be that loop's root).
    resume_header,
    /// Rule 8: from `P` no enclosing back-edge is reached.
    no_back_edge,
    /// Rule 9: `P` consumes a multret producer's `reg_top`.
    multret_consumer,
};

/// How an IR op behaves when its bytecode is re-executed from the
/// boundary snapshot taken before it (Q6), or skipped past (rule 7).
pub const ResumeClass = enum {
    /// Leaves no guest-visible trace that re-executing its bytecode would
    /// not reproduce: values, loads, guards, address tokens, the pattern
    /// scratch writers, and the interning string producers.
    neutral,
    /// A heap store the flush emitters model (`astore`/`hstore`/`gstore`/
    /// `ustore`).
    flush_store,
    /// Any other effect.
    effect,
    /// Trace structure (φ rows, markers, terminals). Never between a
    /// guard and its own bytecode's start in a well-formed body; treated
    /// as an effect by the Q6 scan and skipped by the store scan.
    structural,
};

/// The Q6 audit, as an exhaustive switch: a new `IrOp` fails to compile
/// until someone decides its class.
///
/// Why each neutral group is safe to precede a failing guard of its own
/// bytecode `B` (tier-0 then re-executes `B` from the boundary snapshot):
///   * pure values, loads, guards, address tokens (`aref`/`href`/`garow`/
///     `gcell`/`uref`): no state change at all;
///   * `smatch`/`sgmatch`: write only `heap.match_scratch`, which only the
///     same bytecode's projections read (`sgmatch` is read-only on the
///     iterator state; its position store is the separate `sgm_setpos`);
///   * the allocating string producers (`tostr_*`, `ssub`, …, `scap_str`):
///     doc 24 D2 — re-running a partial bytecode is id-neutral (its first
///     execution's intern misses become the re-run's hits), and the body's
///     `guard_gc` budget makes a collection before the re-run impossible.
///     This is the same argument today's anchor-coherent exits rely on.
pub fn resumeClass(op: IrOp) ResumeClass {
    return switch (op) {
        .slot_load,
        .konst,
        .add,
        .sub,
        .mul,
        .div,
        .idiv,
        .mod,
        .pow,
        .band,
        .bor,
        .bxor,
        .shl,
        .shr,
        .sar,
        .neg,
        .not,
        .bnot,
        .eq,
        .ne,
        .lt,
        .le,
        .fsqrt,
        .fsin,
        .fcos,
        .ffloor,
        .fceil,
        .int_of_float,
        .alen,
        .slen,
        .scp,
        .sfindp,
        .str2num_i,
        .str2num_f,
        .scap_int,
        => .neutral,
        .guard_int,
        .guard_float,
        .guard_number,
        .guard_true,
        .guard_false,
        .guard_is_nil,
        .guard_is_false,
        .guard_is_true,
        .guard_table,
        .guard_lane,
        .guard_bounds,
        .guard_present,
        .guard_fits,
        .guard_append,
        .guard_func,
        .guard_hash,
        .guard_builtin,
        .guard_grid,
        .guard_stride,
        .guard_gcol,
        .guard_gpresent,
        .guard_string,
        .guard_gc,
        .guard_sid,
        .guard_absent,
        => .neutral,
        .aref, .href, .garow, .gcell, .uref => .neutral,
        .aload, .hload, .gload, .uload => .neutral,
        .smatch, .sgmatch => .neutral,
        .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower, .scap_str => .neutral,
        .astore, .hstore, .gstore, .ustore => .flush_store,
        .astore_append, .sgm_setpos, .tnew, .tset => .effect,
        .loop, .phi, .preheader, .link, .terminal => .structural,
    };
}

/// Doc 56 §4.4 (Phase 3): the runtime state of one exit, one byte per
/// instruction in `TraceRecord.exit_side` (allocated only for traces with an
/// attachable exit). A pure function of the receipt stream: `noteTakenExit`
/// moves `none → wanted` at `hotexit` and `wanted → gave_up` at
/// `hotexit + tryside`; a bound child moves `wanted → attached`.
pub const ExitSide = enum(u8) {
    /// Today's anchor-coherent exit.
    none = 0,
    /// Hot: every firing takes the resume-coherent path, and the dispatcher
    /// records (or binds) a continuation at `P`.
    wanted = 1,
    /// A continuation at `P` serves this exit: every firing takes the
    /// resume-coherent path and chains into it.
    attached = 2,
    /// `tryside` firings passed without a child: back to the default path
    /// and today's routes, for good.
    gave_up = 3,

    /// Whether a firing takes the resume-coherent contract (§4.1).
    pub fn materializes(self: ExitSide) bool {
        return self == .wanted or self == .attached;
    }
};

/// Whether instruction `e`, after the failing exit `gi`, is a sunk store of
/// an EARLIER bytecode that the resume-coherent exit applies (§4.1 step 1):
/// a flush-kind store whose ordinal is set and below the guard's. Stores of
/// `B` itself (re-executed at `P`) and of later bytecodes are never applied.
/// For an attachable exit rule 7 proved every such store is a flush kind
/// with ready operands.
pub fn appliesAtExit(code: *const TraceCode, gi: usize, e: usize) bool {
    if (e <= gi or e >= code.instrs.len) return false;
    const ins = code.instrs[e];
    if (resumeClass(ins.op) != .flush_store) return false;
    return ins.ord != 0 and ins.ord < code.instrs[gi].ord;
}

/// Doc 56 Phase 4: what the NATIVE resume-coherent exit `gi` reads for the
/// stores it applies (`appliesAtExit`), exactly what each store's leaf
/// emitter reads: the address token (an `aref`'s index, an `href`'s cell
/// pointer, a `gcell`'s flat index, a `ustore`'s `uref` cell pointer), the
/// table behind an `aref`/`gcell` (the adapter reloads the array base from
/// it), and the stored value. Calls `sink.need(ref)` per read; a ref may be
/// reported more than once. Constants and `uref`s are reported like any
/// other value; the adapter rebuilds them (constant pool, seed slot), so the
/// allocator need not keep them live. The exit snapshot's refs are the
/// other half of what the exit reads; callers walk those themselves.
///
/// `stores` is `flushStoreIndices(code)`: walking only those keeps a
/// whole-trace pass at O(exits × stores) instead of O(exits × n).
pub fn forEachStoreRead(code: *const TraceCode, gi: usize, stores: []const u32, sink: anytype) void {
    for (stores) |e32| {
        const e: usize = e32;
        if (!appliesAtExit(code, gi, e)) continue;
        const ins = code.instrs[e];
        sink.need(ins.a);
        sink.need(ins.b);
        switch (ins.op) {
            .astore => sink.need(code.instrs[ins.a].a),
            .gstore => sink.need(code.instrs[code.instrs[ins.a].a].a),
            .hstore, .ustore => {},
            else => unreachable, // `appliesAtExit` admits only the four flush stores
        }
    }
}

/// Ascending indices of every `.flush_store` instruction of `code` (the only
/// ones `appliesAtExit` can admit). Caller owns the slice.
pub fn flushStoreIndices(gpa: std.mem.Allocator, code: *const TraceCode) std.mem.Allocator.Error![]u32 {
    var count: usize = 0;
    for (code.instrs) |ins| count += @intFromBool(resumeClass(ins.op) == .flush_store);
    const out = try gpa.alloc(u32, count);
    var k: usize = 0;
    for (code.instrs, 0..) |ins, i| {
        if (resumeClass(ins.op) != .flush_store) continue;
        out[k] = @intCast(i);
        k += 1;
    }
    return out;
}

/// `P` for an exit whose provenance resolves (rules 3–5), or the verdict
/// that stopped it.
pub const Resolved = union(enum) {
    pc: u32,
    refused: Verdict,
};

/// Precomputed per-trace indexes that make `buildMemo` linear-ish. The
/// oracle (`classify`) passes none and scans instead; the verdicts are
/// identical (pinned by a test).
const Ctx = struct {
    /// Ascending indices of every non-`.neutral` instruction.
    effects: ?[]const u32 = null,
    /// One bit per anchor-proto pc: the target of some backward jump.
    headers: ?[]const u8 = null,
};

/// The attachability of instruction `idx` of `code`.
pub fn classify(code: *const TraceCode, idx: usize) Verdict {
    return classifyWith(code, idx, .{});
}

/// The resume pc of an attachable exit; null for every other instruction.
pub fn resumePc(code: *const TraceCode, idx: usize) ?u32 {
    if (!code.exitAttachable(idx)) return null;
    return switch (resumeOf(code, idx)) {
        .pc => |p| p,
        .refused => unreachable, // attachable implies it resolved
    };
}

fn classifyWith(code: *const TraceCode, idx: usize, ctx: Ctx) Verdict {
    if (code.deopt_mode == .precise or code.peeled or trace_code.anchorKind(code.anchor.pc) != .loop)
        return .trace_shape;
    if (code.exitSnapIdx(idx) == null) return .no_snapshot;
    const p = switch (resumeOf(code, idx)) {
        .pc => |p| p,
        .refused => |v| return v,
    };
    if (ownEffect(code, idx, ctx)) return .own_effect;
    if (storeVerdict(code, idx, ctx)) |v| return v;
    const proto = code.anchor.proto;
    if (isMultretConsumer(proto.code[p])) return .multret_consumer;
    if (isLoopHeader(proto, p, ctx.headers)) return .resume_header;
    if (!continuationReachesEnclosingBackEdge(proto, p, code.anchor.pc)) return .no_back_edge;
    return .attachable;
}

/// Rules 3–5: the guard's bytecode `B` and its resume pc `P` — `B` itself
/// for every guard but a branch, the successor NOT taken on the recorded
/// path for a branch (LuaJIT's `rec_comp_fixup`). Requires an exit
/// snapshot (rule 2); callers check that first.
pub fn resumeOf(code: *const TraceCode, idx: usize) Resolved {
    const si = code.exitSnapIdx(idx) orelse return .{ .refused = .no_snapshot };
    if (!code.exit_prov_complete) return .{ .refused = .no_provenance };
    const gp = switch (code.provAt(@intCast(idx)) orelse return .{ .refused = .no_provenance }) {
        .guard => |g| g,
        .link_terminal => return .{ .refused = .no_provenance },
    };
    const proto = code.anchor.proto;
    if (gp.inline_depth != 0 or gp.source_proto_id != proto.id) return .{ .refused = .inlined };
    // A while root's own condition guard is a loop-done too (doc 38 owns
    // it through the `.while_done` chain); an unrolled INNER while's
    // wrong-trip-count guard is not — its back-edge targets the inner
    // header, so `whileLoopDonePostPc` rejects it and it stays attachable.
    if (gp.role == .loop_done or code.isNumericForLoopDoneGuard(idx) or
        code.whileLoopDonePostPc(idx) != null) return .{ .refused = .loop_done };
    const g = code.instrs[idx];
    const b = gp.source_pc;
    if (b >= proto.code.len) return .{ .refused = .resume_mismatch };
    if (trace_ir.guardSourcePc(g)) |sp| {
        if (sp != b) return .{ .refused = .resume_mismatch };
    }
    if (code.exit_snapshots[si - 1].resume_pc != b) return .{ .refused = .resume_mismatch };
    if (gp.role != .branch_cond) return .{ .pc = b };

    const jumps_if_truthy = switch (proto.code[b].op) {
        .jmp_if_true => true,
        .jmp_if_false => false,
        else => return .{ .refused = .branch_shape },
    };
    const recorded_truthy = switch (g.op) {
        .guard_true => true,
        .guard_false => false,
        else => return .{ .refused = .branch_shape },
    };
    // The recorded path jumped iff the op jumps on the truthiness it saw;
    // the exit fires on the other truthiness, so it takes the other edge.
    const jumped = jumps_if_truthy == recorded_truthy;
    const want: trace_types.Polarity = if (jumped) .taken else .fallthrough;
    if (gp.polarity != want) return .{ .refused = .branch_shape };
    const fall: i64 = @as(i64, b) + 1;
    const p: i64 = if (jumped) fall else fall + proto.code[b].aux;
    if (p < 0 or p >= @as(i64, @intCast(proto.code.len))) return .{ .refused = .branch_shape };
    return .{ .pc = @intCast(p) };
}

/// Rule 6 (Q6): an instruction of the guard's own bytecode, before it,
/// that is not `.neutral`. Ordinals are per bytecode execution on the
/// recorded path, so an unrolled copy of the same bytecode never matches.
fn ownEffect(code: *const TraceCode, idx: usize, ctx: Ctx) bool {
    const o = code.instrs[idx].ord;
    if (ctx.effects) |effects| {
        for (effects) |e| {
            if (e >= idx) break;
            if (code.instrs[e].ord == o) return true;
        }
        return false;
    }
    for (code.instrs[0..idx]) |ins| {
        if (ins.ord == o and resumeClass(ins.op) != .neutral) return true;
    }
    return false;
}

/// Rule 7: the stores after the guard that an earlier bytecode deferred.
/// Stores of `B` itself (ordinal equal) and of later bytecodes are never
/// applied at this exit, whatever their kind.
fn storeVerdict(code: *const TraceCode, idx: usize, ctx: Ctx) ?Verdict {
    const o = code.instrs[idx].ord;
    if (ctx.effects) |effects| {
        for (effects) |e| {
            if (e <= idx) continue;
            if (storeRule(code, idx, o, e)) |v| return v;
        }
        return null;
    }
    for (idx + 1..code.instrs.len) |e| {
        if (storeRule(code, idx, o, e)) |v| return v;
    }
    return null;
}

fn storeRule(code: *const TraceCode, idx: usize, o: u16, e: usize) ?Verdict {
    const ins = code.instrs[e];
    const class = resumeClass(ins.op);
    if (class == .neutral or class == .structural) return null;
    if (ins.ord >= o) return null;
    if (ins.ord == 0) return .store_unordered;
    if (class == .effect) return .store_kind;
    if (!operandReady(code, ins.a, idx) or !operandReady(code, ins.b, idx)) return .store_operand;
    return null;
}

/// Whether the value `r` is available when guard `gi` fails: computed
/// before it, a constant, or an address token the adapter can rebuild
/// from operands that are themselves available. A `uref` has no operands:
/// it reloads its cell pointer from the seed slot `aux` in the slab, which
/// the entry wrote and nothing overwrites, so like a `konst` it is always
/// rebuildable.
fn operandReady(code: *const TraceCode, r: Ref, gi: usize) bool {
    if (r < gi) return true;
    if (r >= code.instrs.len) return false;
    const ins = code.instrs[r];
    return switch (ins.op) {
        .konst, .uref => true,
        .aref, .href, .garow, .gcell => ins.a < r and ins.b < r and
            operandReady(code, ins.a, gi) and operandReady(code, ins.b, gi),
        else => false,
    };
}

/// The target of `ins` at `pc` when it is a BACKWARD jump (a loop's
/// back-edge), else null.
fn backEdgeTarget(ins: Instr, pc: usize) ?u32 {
    switch (ins.op) {
        .jmp, .jmp_if_true, .jmp_if_false, .jmp_if_not_nil, .for_loop, .tfor_loop => {},
        else => return null,
    }
    const t: i64 = @as(i64, @intCast(pc)) + 1 + ins.aux;
    if (t < 0 or t > @as(i64, @intCast(pc))) return null;
    return @intCast(t);
}

/// Rule 9: `ins` reads `Vm.reg_top`, which only the instruction right
/// before it (its multret producer) sets — `interp.zig`'s `call` argument
/// count and `ret` result count under `all_results` are the only readers.
/// Resuming there after a materialize would read a stale or garbage top.
fn isMultretConsumer(ins: Instr) bool {
    return switch (ins.op) {
        .call, .ret => ins.b == bytecode.all_results,
        else => false,
    };
}

fn isLoopHeader(proto: *const Proto, p: u32, headers: ?[]const u8) bool {
    if (headers) |h| return (h[p >> 3] >> @intCast(p & 7)) & 1 != 0;
    for (proto.code, 0..) |ins, pc| {
        if (backEdgeTarget(ins, pc) == p) return true;
    }
    return false;
}

/// Doc 15/38: whether a continuation recorded from `start_pc` can close at
/// an enclosing loop's back-edge (one whose target is at or before
/// `inner_anchor`) within a bounded forward scan. Shared by the loop-done
/// continuation arm (`trace_link.maybeArmContinuation`) and rule 8.
pub fn continuationReachesEnclosingBackEdge(proto: *const Proto, start_pc: u32, inner_anchor: u32) bool {
    const scan_limit: usize = @min(proto.code.len, @as(usize, @intCast(start_pc)) + 128);
    var pc: usize = @intCast(start_pc);
    while (pc < scan_limit) : (pc += 1) {
        const ins = proto.code[pc];
        switch (ins.op) {
            .for_loop, .tfor_loop => {
                const target = @as(i64, @intCast(pc)) + 1 + ins.aux;
                if (target >= 0 and target <= @as(i64, @intCast(inner_anchor))) return true;
            },
            // Doc 38: an enclosing WHILE loop's back-edge is a plain backward
            // `jmp`. The scan starts past the inner anchor, so a target at or
            // before it is necessarily backward and enclosing (rule Z-6:
            // while-in-while nests arm continuations like for-in-for ones).
            .jmp => {
                const target = @as(i64, @intCast(pc)) + 1 + ins.aux;
                if (target >= 0 and target <= @as(i64, @intCast(inner_anchor))) return true;
            },
            .ret, .halt => return false,
            else => {},
        }
    }
    return false;
}

/// Compute every exit's verdict once, at commit, into `code.exit_attach`
/// (one bit per instruction). Cost: O(n + proto code + g·s) for n
/// instructions, g side-exit guards and s non-neutral instructions (the
/// stores, a handful per trace), against O(n·g) for the scanning oracle.
///
/// FAIL-SOFT, like `buildBridgeCandMemo`: on OOM the memo stays unbuilt and
/// `TraceCode.exitAttachable` falls back to the oracle, never a partial
/// bitset. A trace with no exit snapshots has no attachable exit and needs
/// no bits.
pub fn buildMemo(gpa: std.mem.Allocator, code: *TraceCode) void {
    std.debug.assert(!code.exit_attach_built and code.exit_attach.len == 0);
    if (code.exit_snapshots.len == 0 or code.instrs.len == 0) {
        code.exit_attach_built = true;
        return;
    }
    const n = code.instrs.len;
    var n_eff: usize = 0;
    for (code.instrs) |ins| n_eff += @intFromBool(resumeClass(ins.op) != .neutral);
    const effects = gpa.alloc(u32, n_eff) catch return;
    defer gpa.free(effects);
    var k: usize = 0;
    for (code.instrs, 0..) |ins, i| {
        if (resumeClass(ins.op) == .neutral) continue;
        effects[k] = @intCast(i);
        k += 1;
    }
    const proto = code.anchor.proto;
    const headers = gpa.alloc(u8, (proto.code.len + 7) / 8) catch return;
    defer gpa.free(headers);
    @memset(headers, 0);
    for (proto.code, 0..) |ins, pc| {
        const t = backEdgeTarget(ins, pc) orelse continue;
        headers[t >> 3] |= @as(u8, 1) << @intCast(t & 7);
    }
    const bits = gpa.alloc(u8, (n + 7) / 8) catch return;
    @memset(bits, 0);
    const ctx: Ctx = .{ .effects = effects, .headers = headers };
    for (0..n) |i| {
        if (classifyWith(code, i, ctx) == .attachable)
            bits[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
    }
    code.exit_attach = bits;
    code.exit_attach_built = true;
}

test {
    _ = @import("trace_exit_attach_test.zig");
}
