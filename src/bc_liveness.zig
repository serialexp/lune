//! Doc 56 §4.2: tier-0 bytecode REGISTER LIVENESS, per proto, per pc.
//!
//! An exit snapshot resuming tier-0 at pc `P` must restore every register
//! tier-0 may still READ from `P` onward. It must not pin the rest: a
//! snapshot ref is an optimizer liveness root, so capturing a dead local
//! would stop `tropt` from deleting the dead computation in every trace.
//! LuaJIT answers the same question per snapshot with a bounded forward scan
//! (`snap_usedef`, lj_snap.c:208). We answer it once per proto, at compile
//! time, with a standard backward dataflow over the bytecode CFG:
//!
//!     live_in[pc]  = use[pc] ∪ (live_out[pc] − kill[pc]) ∪ captured
//!     live_out[pc] = ∪ live_in[s]  for every successor s of pc
//!
//! iterated to a fixpoint (a monotone lattice, so it terminates; on the
//! structured CFGs the compiler emits it takes loop-nesting-depth + 2
//! backward sweeps).
//!
//! Soundness is one-sided: a spurious "live" only costs a DCE opportunity,
//! a spurious "dead" would let an exit leave a stale value that tier-0 then
//! reads. So every uncertain case errs live:
//!   * a register captured by any child closure (`UpvalDesc.in_stack`) is
//!     live at EVERY pc — an open upvalue aliases the register, and any call
//!     may read it through the closure;
//!   * a multret CONSUMER (`call`/`ret` with `b == all_results`) reads
//!     `R[a..num_registers)`;
//!   * writes whose extent is dynamic (`call` with `c == all_results`,
//!     `vararg_spread`) or conditional (`for_loop`'s `R[a+3]`,
//!     `tfor_loop`'s `R[a+2]`) kill nothing;
//!   * the patched-image opcodes (`jfor_loop`, `jloop`, `jfunc_head`,
//!     `jcont`), which canonical `Proto.code` never contains, make every
//!     register live at that pc.
//!
//! Memory: `code.len * ceil(num_registers / 64)` words. A proto above
//! `max_table_words` gets no table (`RegLiveness.available() == false`) —
//! its traces then carry no exit snapshots, which is fail-soft (exits stay
//! anchor-coherent) and never costs codegen.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const Instr = bytecode.Instr;
const Proto = bytecode.Proto;
const RegLiveness = bytecode.RegLiveness;

/// 2 MiB of `u64` per proto. A 2,000-instruction proto with 100 registers
/// needs 4,000 words; only a pathological proto reaches this.
pub const max_table_words: usize = 1 << 18;

/// One instruction's dataflow effect. Register ranges are half-open and
/// clamped to the proto's window by the caller.
const Effect = struct {
    uses: [4]u16 = undefined,
    n_uses: u8 = 0,
    /// `R[range_lo..range_hi)` is read too: a call/return window (exact
    /// width when fixed; `to_top` for a multret consumer, which reads up to
    /// the dynamic top — the window top, conservatively).
    range_lo: u32 = 0,
    range_hi: u32 = 0,
    kill_lo: u16 = 0,
    kill_hi: u16 = 0,
    succ: [2]?u32 = .{ null, null },
    /// A register written only along that successor edge (a loop op's
    /// taken back-edge): it is dead on entry to that edge, and ONLY that
    /// edge — the other successor's liveness of it is untouched.
    edge_kill: [2]?u16 = .{ null, null },
    /// Every register is live here (unexpected patched opcode).
    all_live: bool = false,

    fn use(self: *Effect, r: u32) void {
        if (r > std.math.maxInt(u16)) return; // out of any window: ignore
        self.uses[self.n_uses] = @intCast(r);
        self.n_uses += 1;
    }

    /// A register operand carried in `aux` (`get_index2`/`set_index2`). The
    /// compiler only writes a register there; a negative one is malformed
    /// code, answered the safe way (every register live) rather than with
    /// an `@intCast` that is UB in ReleaseFast or a silently dropped use.
    fn useAux(self: *Effect, aux: i32) void {
        if (aux < 0) {
            self.all_live = true;
            return;
        }
        self.use(@intCast(aux));
    }

    fn useRange(self: *Effect, lo: u32, hi: u32) void {
        self.range_lo = lo;
        self.range_hi = hi;
    }

    fn kill(self: *Effect, lo: u32, hi: u32) void {
        self.kill_lo = @intCast(@min(lo, std.math.maxInt(u16)));
        self.kill_hi = @intCast(@min(hi, std.math.maxInt(u16)));
    }
};

/// `Effect.range_hi` for a multret consumer: through the window top.
const to_top: u32 = std.math.maxInt(u32);

fn jumpTarget(pc: u32, aux: i32, code_len: usize) ?u32 {
    const t: i64 = @as(i64, pc) + 1 + aux;
    if (t < 0 or t >= @as(i64, @intCast(code_len))) return null;
    return @intCast(t);
}

/// The CFG successors of `ins` at `pc` — the one successor model, shared with
/// `bc_dom` (doc 58 §4.8) so dominance and liveness see the same graph. A
/// null entry is no edge (none, a `ret`/`halt`, or a target outside the code,
/// which leads to no instruction).
pub fn successors(ins: Instr, pc: u32, code_len: usize) [2]?u32 {
    return effectOf(ins, pc, code_len).succ;
}

fn effectOf(ins: Instr, pc: u32, code_len: usize) Effect {
    var e: Effect = .{};
    const next: ?u32 = if (pc + 1 < code_len) pc + 1 else null;
    const a: u32 = ins.a;
    switch (ins.op) {
        .load_nil,
        .load_bool,
        .load_int,
        .load_const,
        .new_table,
        .get_global,
        .get_upval,
        .vararg_first,
        .vararg_len,
        .closure, // its captures are `captured`, live everywhere
        => {
            e.kill(a, a + 1);
            e.succ[0] = next;
        },
        .move, .neg, .not, .bnot, .len, .vararg_get => {
            e.use(ins.b);
            e.kill(a, a + 1);
            e.succ[0] = next;
        },
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .concat, .eq, .ne, .lt, .le, .gt, .ge, .get_index => {
            e.use(ins.b);
            e.use(ins.c);
            e.kill(a, a + 1);
            e.succ[0] = next;
        },
        .get_index2 => {
            e.use(ins.b);
            e.use(ins.c);
            e.useAux(ins.aux);
            e.kill(a, a + 1);
            e.succ[0] = next;
        },
        .set_index => {
            e.use(a);
            e.use(ins.b);
            e.use(ins.c);
            e.succ[0] = next;
        },
        .set_index2 => {
            e.use(a);
            e.use(ins.b);
            e.use(ins.c);
            e.useAux(ins.aux);
            e.succ[0] = next;
        },
        .set_global, .set_upval => {
            e.use(a);
            e.succ[0] = next;
        },
        .close_upvalues => e.succ[0] = next, // reads captured regs only
        // Doc 58: a loop marker reads and writes nothing and always falls
        // through; its `aux` is the loop's exit offset, not a branch.
        .loop => e.succ[0] = next,
        .jmp => e.succ[0] = jumpTarget(pc, ins.aux, code_len),
        .jmp_if_false, .jmp_if_true, .jmp_if_not_nil => {
            e.use(a);
            e.succ = .{ next, jumpTarget(pc, ins.aux, code_len) };
        },
        .for_prep => {
            // Reads idx/limit/step, rewrites idx (a use too, so no kill
            // matters). ALWAYS jumps to its `for_loop` (`opForPrep` never
            // falls through): a fall-through edge would leak the body's
            // upward-exposed uses — e.g. an inner loop's variable — into
            // the enclosing loop as spuriously live.
            e.use(a);
            e.use(a + 1);
            e.use(a + 2);
            e.succ[0] = jumpTarget(pc, ins.aux, code_len);
        },
        .for_loop => {
            // `R[a+3]` (the loop variable) is written only on the taken edge.
            e.use(a);
            e.use(a + 1);
            e.use(a + 2);
            e.succ = .{ next, jumpTarget(pc, ins.aux, code_len) };
            e.edge_kill[1] = @intCast(@min(a + 3, std.math.maxInt(u16)));
        },
        .tfor_loop => {
            // `R[a+2]` (the control slot) is written only on the taken edge.
            e.use(a + 3);
            e.succ = .{ next, jumpTarget(pc, ins.aux, code_len) };
            e.edge_kill[1] = @intCast(@min(a + 2, std.math.maxInt(u16)));
        },
        .call => {
            // Callee + args: exactly `b` of them, or up to the top (multret).
            e.useRange(a, if (ins.b == bytecode.all_results) to_top else a + 1 + @as(u32, ins.b));
            if (ins.c != bytecode.all_results) e.kill(a, a + @as(u32, ins.c));
            e.succ[0] = next;
        },
        .ret => {
            e.useRange(a, if (ins.b == bytecode.all_results) to_top else a + @as(u32, ins.b));
            // No successor: the frame is gone.
        },
        .vararg_spread => e.succ[0] = next, // dynamic extent: kill nothing
        .halt => {},
        .jfor_loop, .jloop, .jfunc_head, .jcont => {
            e.all_live = true;
            e.succ[0] = next;
        },
    }
    return e;
}

/// Compute `proto`-shaped liveness for `code` over a `num_registers` window.
/// `children` are the protos `closure` instantiates (their `in_stack`
/// upvalues name this frame's captured registers). The table is allocated
/// from `alloc` (the compile arena in production). Returns an unavailable
/// table (`words == 0`) for an empty window or over `max_table_words`.
pub fn compute(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    code: []const Instr,
    num_registers: u16,
    children: []const *const Proto,
) std.mem.Allocator.Error!RegLiveness {
    if (num_registers == 0 or code.len == 0) return .{};
    const words: usize = (@as(usize, num_registers) + 63) / 64;
    if (code.len > max_table_words / words) return .{};

    const bits = try alloc.alloc(u64, code.len * words);
    errdefer alloc.free(bits);
    @memset(bits, 0);

    // Scratch: the captured mask, the valid-register mask, and one row.
    const tmp = try scratch.alloc(u64, words * 3);
    defer scratch.free(tmp);
    const captured = tmp[0..words];
    const valid = tmp[words .. 2 * words];
    const row = tmp[2 * words .. 3 * words];
    @memset(captured, 0);
    @memset(valid, 0);
    {
        var r: u32 = 0;
        while (r < num_registers) : (r += 1) setBit(valid, r);
    }
    for (children) |child| {
        for (child.upvalues) |uv| {
            if (uv.in_stack and uv.index < num_registers) setBit(captured, uv.index);
        }
    }

    // Effects are re-decoded on each use rather than cached: an `Effect`
    // array is ~48 bytes per instruction of fresh memory, and page-faulting
    // it in cost more than the decode it saved.
    const n = code.len;

    // Predecessor lists (CSR): `preds[pred_off[pc]..pred_off[pc+1]]`.
    const pred_off = try scratch.alloc(u32, n + 1);
    defer scratch.free(pred_off);
    @memset(pred_off, 0);
    for (code, 0..) |ins, i| {
        for (effectOf(ins, @intCast(i), n).succ) |s| {
            if (s) |sp| pred_off[sp + 1] += 1;
        }
    }
    for (1..n + 1) |i| pred_off[i] += pred_off[i - 1];
    const preds = try scratch.alloc(u32, pred_off[n]);
    defer scratch.free(preds);
    {
        const fill = try scratch.alloc(u32, n);
        defer scratch.free(fill);
        @memcpy(fill, pred_off[0..n]);
        for (code, 0..) |ins, i| {
            for (effectOf(ins, @intCast(i), n).succ) |s| {
                if (s) |sp| {
                    preds[fill[sp]] = @intCast(i);
                    fill[sp] += 1;
                }
            }
        }
    }

    // Worklist as a bitset, drained in rounds of DESCENDING pc (the natural
    // order for a backward problem on the compiler's forward-laid-out code).
    // Round 1 visits every pc once — an ordinary backward sweep. After that
    // only a pc whose successor's row changed is revisited, and a change
    // flowing to a LOWER pc is picked up later in the same round, so a
    // back-edge's new bits cross the loop body once per round instead of
    // spawning a fresh wave per change. Measured on a 40-deep nest of
    // 12,383 bytecodes: 13,551 visits (1.1 per pc) over 41 cheap rounds,
    // where naive whole-code re-sweeping cost +40% compile time (Rule #20).
    const qwords = (n + 63) / 64;
    const queued = try scratch.alloc(u64, qwords);
    defer scratch.free(queued);
    @memset(queued, ~@as(u64, 0));
    if (n % 64 != 0) queued[qwords - 1] = (@as(u64, 1) << @intCast(n % 64)) - 1;
    var pending = true;
    while (pending) {
        pending = false;
        var w = qwords;
        while (w > 0) {
            w -= 1;
            while (queued[w] != 0) {
                const b: u6 = @intCast(63 - @clz(queued[w]));
                queued[w] &= ~(@as(u64, 1) << b);
                const i: usize = w * 64 + b;
                if (visit(i, code, bits, words, row, valid, captured, num_registers)) {
                    for (preds[pred_off[i]..pred_off[i + 1]]) |p| {
                        queued[p / 64] |= @as(u64, 1) << @intCast(p % 64);
                        // A higher pc in an already-drained word waits for
                        // the next round.
                        if (p / 64 > w) pending = true;
                    }
                }
            }
        }
    }
    return .{ .words = @intCast(words), .bits = bits };
}

/// Recompute `live_in[i]` into `bits`; true when it changed.
fn visit(
    i: usize,
    code: []const Instr,
    bits: []u64,
    words: usize,
    row: []u64,
    valid: []const u64,
    captured: []const u64,
    num_registers: u16,
) bool {
    const e = effectOf(code[i], @intCast(i), code.len);
    if (e.all_live) {
        @memcpy(row, valid);
    } else {
        @memset(row, 0);
        for (e.succ, e.edge_kill) |s, ek| {
            const sp = s orelse continue;
            const src = bits[@as(usize, sp) * words ..][0..words];
            for (row, src, 0..) |*d, v, wi| {
                var m = v;
                // Edge-local kill: masked from THIS successor's row only.
                if (ek) |r| {
                    if (r / 64 == wi) m &= ~(@as(u64, 1) << @intCast(r % 64));
                }
                d.* |= m;
            }
        }
        var k: u32 = e.kill_lo;
        while (k < e.kill_hi and k < num_registers) : (k += 1) clearBit(row, k);
        for (e.uses[0..e.n_uses]) |u| {
            if (u < num_registers) setBit(row, u);
        }
        var r: u32 = e.range_lo;
        while (r < e.range_hi and r < num_registers) : (r += 1) setBit(row, r);
        for (row, captured) |*d, c| d.* |= c;
    }
    const dst = bits[i * words ..][0..words];
    if (std.mem.eql(u64, dst, row)) return false;
    @memcpy(dst, row);
    return true;
}

fn setBit(ws: []u64, r: u32) void {
    ws[r / 64] |= @as(u64, 1) << @intCast(r % 64);
}

fn clearBit(ws: []u64, r: u32) void {
    ws[r / 64] &= ~(@as(u64, 1) << @intCast(r % 64));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn liveSet(l: RegLiveness, pc: u32, n: u16) u64 {
    var m: u64 = 0;
    var r: u16 = 0;
    while (r < n) : (r += 1) {
        if (l.liveIn(pc, r)) m |= @as(u64, 1) << @intCast(r);
    }
    return m;
}

fn computeT(code: []const Instr, n: u16, children: []const *const Proto) !RegLiveness {
    return compute(testing.allocator, testing.allocator, code, n, children);
}

fn freeT(l: RegLiveness) void {
    if (l.bits.len != 0) testing.allocator.free(l.bits);
}

test "straight line: a value is live from its def to its last use, a dead def never" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 2), // 0
        Instr.opAx(.load_int, 1, 3), // 1
        Instr.opAx(.load_int, 3, 9), // 2  r3: never read
        Instr.opABC(.add, 2, 0, 1), // 3
        Instr.opAB(.ret, 2, 1), // 4
    };
    const l = try computeT(&code, 4, &.{});
    defer freeT(l);
    try testing.expect(l.available());
    try testing.expectEqual(@as(u64, 0b0000), liveSet(l, 0, 4));
    try testing.expectEqual(@as(u64, 0b0001), liveSet(l, 1, 4));
    try testing.expectEqual(@as(u64, 0b0011), liveSet(l, 2, 4));
    try testing.expectEqual(@as(u64, 0b0011), liveSet(l, 3, 4)); // r3 dead
    try testing.expectEqual(@as(u64, 0b0100), liveSet(l, 4, 4));
}

test "loop: loop-carried and control slots stay live across the back-edge; a body temp does not" {
    // r0 acc, r1..r4 for-slots (idx, limit, step, var), r5 body temp.
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 0), // 0 acc = 0
        Instr.opAx(.load_int, 1, 1), // 1
        Instr.opAx(.load_int, 2, 10), // 2
        Instr.opAx(.load_int, 3, 1), // 3
        Instr.opAx(.for_prep, 1, 3), // 4 → for_loop at 8
        Instr.opABC(.mul, 5, 4, 4), // 5 t = i*i
        Instr.opABC(.add, 0, 0, 5), // 6 acc += t
        Instr.opAx(.load_int, 5, 0), // 7 t = 0 (dead store)
        Instr.opAx(.for_loop, 1, -4), // 8 → body at 5
        Instr.opAB(.ret, 0, 1), // 9
    };
    const l = try computeT(&code, 6, &.{});
    defer freeT(l);
    // At the body head: acc + idx/limit/step + the loop var are live.
    try testing.expectEqual(@as(u64, 0b011111), liveSet(l, 5, 6));
    // After `acc += t`, t is dead (overwritten, then overwritten again by
    // the next iteration's mul) — and the loop var r4 is dead too (the
    // next iteration's for_loop rewrites it before the body reads it).
    try testing.expectEqual(@as(u64, 0b001111), liveSet(l, 7, 6));
    try testing.expectEqual(@as(u64, 0b001111), liveSet(l, 8, 6));
    try testing.expectEqual(@as(u64, 0b000001), liveSet(l, 9, 6));
}

test "nested loops: outer control slots live through the inner nest; the inner loop var only inside it" {
    // r0 acc; outer for-slots r1..r4; inner for-slots r5..r8.
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 0), // 0
        Instr.opAx(.load_int, 1, 1), // 1
        Instr.opAx(.load_int, 2, 3), // 2
        Instr.opAx(.load_int, 3, 1), // 3
        Instr.opAx(.for_prep, 1, 7), // 4 → 12
        Instr.opABC(.add, 0, 0, 4), // 5 outer body: acc += i
        Instr.opAx(.load_int, 5, 1), // 6
        Instr.opAx(.load_int, 6, 2), // 7
        Instr.opAx(.load_int, 7, 1), // 8
        Instr.opAx(.for_prep, 5, 1), // 9 → 11
        Instr.opABC(.add, 0, 0, 8), // 10 inner body: acc += j
        Instr.opAx(.for_loop, 5, -2), // 11 → 10
        Instr.opAx(.for_loop, 1, -8), // 12 → 5
        Instr.opAB(.ret, 0, 1), // 13
    };
    const l = try computeT(&code, 9, &.{});
    defer freeT(l);
    try testing.expectEqual(@as(u64, 0x1EF), liveSet(l, 10, 9)); // no r4
    try testing.expectEqual(@as(u64, 0x0EF), liveSet(l, 11, 9)); // r8 edge-killed
    try testing.expectEqual(@as(u64, 0x00F), liveSet(l, 12, 9));
    // The inner loop var r8 never leaks into the outer body (no for_prep
    // fall-through edge).
    try testing.expectEqual(@as(u64, 0x01F), liveSet(l, 5, 9));
    try testing.expectEqual(@as(u64, 0x00F), liveSet(l, 6, 9));
}

test "a register captured by a child closure is live at every pc" {
    const child = Proto{ .code = &.{}, .upvalues = &.{.{ .in_stack = true, .index = 1 }} };
    const children = [_]*const Proto{&child};
    const code = [_]Instr{
        Instr.opAx(.load_int, 1, 5), // 0
        Instr.opAB(.closure, 0, 0), // 1
        Instr.opAB(.ret, 0, 1), // 2
    };
    const l = try computeT(&code, 2, &children);
    defer freeT(l);
    try testing.expect(l.liveIn(0, 1));
    try testing.expect(l.liveIn(2, 1));
}

test "multret consumers read to the window top; dynamic producers kill nothing" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 4, 7), // 0 r4 = 7
        Instr.opABC(.call, 1, 0, bytecode.all_results), // 1 producer: kills nothing
        Instr.opABC(.call, 0, bytecode.all_results, 1), // 2 consumer: reads r0..
        Instr.opAB(.ret, 0, 1), // 3
    };
    const l = try computeT(&code, 5, &.{});
    defer freeT(l);
    try testing.expectEqual(@as(u64, 0b11111), liveSet(l, 2, 5));
    // The producer reads r1 (callee) only, yet r4 survives it: its write
    // extent is dynamic, so it cannot be proven to overwrite r4.
    try testing.expect(l.liveIn(1, 4));
    try testing.expect(l.liveIn(1, 0));
}

test "fixed-arity call reads callee + args and kills exactly its results" {
    const code = [_]Instr{
        Instr.opABC(.call, 1, 2, 1), // 0 r1 = r1(r2, r3)
        Instr.opAB(.ret, 1, 1), // 1
    };
    const l = try computeT(&code, 5, &.{});
    defer freeT(l);
    try testing.expectEqual(@as(u64, 0b01110), liveSet(l, 0, 5));
    try testing.expectEqual(@as(u64, 0b00010), liveSet(l, 1, 5));
}

test "a wide fixed-arity call or return reads exactly its window, never up to the top" {
    // `io.write(a, b, c, d, e)`: callee + 5 args = 6 registers, wider than
    // the single-register use list. Registers above the window stay dead —
    // reading "to the top" there once made every temp live program-wide.
    const call = [_]Instr{
        Instr.opABC(.call, 1, 5, 0), // 0 r1(r2..r6), no results
        Instr.opAB(.ret, 0, 0), // 1
    };
    const lc = try computeT(&call, 12, &.{});
    defer freeT(lc);
    try testing.expectEqual(@as(u64, 0b0000_0111_1110), liveSet(lc, 0, 12));
    const ret = [_]Instr{
        Instr.opAB(.ret, 2, 6), // 0 return r2..r7
    };
    const lr = try computeT(&ret, 12, &.{});
    defer freeT(lr);
    try testing.expectEqual(@as(u64, 0b0000_1111_1100), liveSet(lr, 0, 12));
}

test "a two-level index reads its aux register; a malformed negative aux makes everything live" {
    const ok = [_]Instr{
        .{ .op = .get_index2, .a = 0, .b = 1, .c = 2, .aux = 3 }, // 0 r0 = r1[r2][r3]
        Instr.opAB(.ret, 0, 1), // 1
    };
    const l = try computeT(&ok, 6, &.{});
    defer freeT(l);
    try testing.expectEqual(@as(u64, 0b001110), liveSet(l, 0, 6));
    const bad = [_]Instr{
        .{ .op = .get_index2, .a = 0, .b = 1, .c = 2, .aux = -1 }, // 0
        Instr.opAB(.ret, 0, 1), // 1
    };
    const lb = try computeT(&bad, 6, &.{});
    defer freeT(lb);
    try testing.expectEqual(@as(u64, 0b111111), liveSet(lb, 0, 6));
}

test "conditional branches union both successors" {
    const code = [_]Instr{
        Instr.opAx(.jmp_if_false, 0, 2), // 0 → 3
        Instr.opAB(.move, 3, 1), // 1
        Instr.opJ(.jmp, 1), // 2 → 4
        Instr.opAB(.move, 3, 2), // 3
        Instr.opAB(.ret, 3, 1), // 4
    };
    const l = try computeT(&code, 4, &.{});
    defer freeT(l);
    try testing.expectEqual(@as(u64, 0b0111), liveSet(l, 0, 4));
    try testing.expectEqual(@as(u64, 0b0010), liveSet(l, 1, 4));
    try testing.expectEqual(@as(u64, 0b0100), liveSet(l, 3, 4));
}

test "doc 58: a loop marker falls through; its exit offset is not a branch" {
    // `while r0 do r2 = r1 end return r2`, with the marker's `aux` pointing
    // at the exit (pc 5). Were `aux` read as a branch, r1 would be live at
    // the marker only through the body, and r2 would leak live into pc 2
    // from the exit path.
    const code = [_]Instr{
        Instr.opAx(.jmp_if_false, 0, 3), // 0 → 4
        .{ .op = .loop, .aux = 2 }, // 1   exit = 1 + 1 + 2 = 4
        Instr.opAB(.move, 2, 1), // 2
        Instr.opJ(.jmp, -4), // 3 → 0
        Instr.opAB(.ret, 2, 1), // 4
    };
    const l = try computeT(&code, 3, &.{});
    defer freeT(l);
    // At the marker: r0 (the next condition) and r1 (the body) are live;
    // r2 is not, because the body writes it before anything reads it.
    try testing.expectEqual(@as(u64, 0b011), liveSet(l, 1, 3));
    try testing.expectEqual(@as(u64, 0b011), liveSet(l, 2, 3));
    try testing.expectEqual(@as(u64, 0b100), liveSet(l, 4, 3));
}

test "wide windows span several words; an over-budget proto gets no table" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 130, 1), // 0
        Instr.opAB(.move, 70, 130), // 1
        Instr.opAB(.ret, 70, 1), // 2
    };
    const l = try computeT(&code, 200, &.{});
    defer freeT(l);
    try testing.expectEqual(@as(u32, 4), l.words);
    try testing.expect(l.liveIn(1, 130));
    try testing.expect(!l.liveIn(1, 70));
    try testing.expect(l.liveIn(2, 70));
    try testing.expect(!l.liveIn(2, 130));

    // 65,535 registers = 1,024 words per pc: 257 pcs exceed 2^18 words.
    const big = try testing.allocator.alloc(Instr, 257);
    defer testing.allocator.free(big);
    @memset(big, Instr.op0(.halt));
    const none = try computeT(big, std.math.maxInt(u16), &.{});
    try testing.expect(!none.available());
    try testing.expect(!(try computeT(&code, 0, &.{})).available());
}
