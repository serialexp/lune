//! Doc 58 §4.8: the dominator tree of one proto's bytecode CFG, rooted at
//! pc 0 — computed once at compile time into `Proto.dom` (`bytecode.DomTree`),
//! exactly as `bc_liveness` fills `Proto.reg_live`.
//!
//! Built with Cooper–Harvey–Kennedy ("A Simple, Fast Dominance Algorithm"):
//! number the pcs reachable from pc 0 in DFS postorder, then iterate
//! `idom(b) = ⋂ idom-chains of b's processed predecessors` in reverse postorder
//! until nothing changes — two or three passes on the reducible CFGs the
//! compiler emits. A DFS of the resulting tree gives every pc an interval, so
//! `a dom b` is interval containment.
//!
//! Successors come from `bc_liveness.successors`, the same graph liveness is
//! computed on. A dropped successor (a jump outside the code) leads to no
//! instruction, so it can never hide a path to a real pc — dominance over the
//! remaining graph is exact for every executable path. A pc unreachable from
//! pc 0 dominates nothing and is dominated by nothing, so a query about dead
//! code never succeeds vacuously (codex review of §4.8, finding 2).
//!
//! Cost: O(n · passes) time. The result is two `u32` arrays of `code.len` from
//! `alloc` (the compile arena in production); all working state is one
//! `scratch` allocation freed before return. The successor model is evaluated
//! once per pc into a flat array, not once per pass.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const bc_liveness = @import("bc_liveness.zig");

const Instr = bytecode.Instr;
const DomTree = bytecode.DomTree;
const none = DomTree.none;
/// DFS mark for a pc pushed but not yet numbered.
const on_stack = none - 1;

pub fn compute(alloc: std.mem.Allocator, scratch: std.mem.Allocator, code: []const Instr) std.mem.Allocator.Error!DomTree {
    const n = code.len;
    // Postorder and tree numbers (up to 2n) must stay below the two marks.
    if (n == 0 or n >= on_stack / 2) return .{};

    const pre = try alloc.alloc(u32, n);
    errdefer alloc.free(pre);
    const post = try alloc.alloc(u32, n);
    errdefer alloc.free(post);
    @memset(pre, none);
    @memset(post, none);

    // Scratch, one allocation: succ[2n], po_of[n], pc_of_po[n], stack_pc[n],
    // stack_k[n], idom[n], pred_off[n + 1], preds[2n], cursor[n + 1].
    const tmp = try scratch.alloc(u32, 12 * n + 2);
    defer scratch.free(tmp);
    var rest = tmp;
    const succ = take(&rest, 2 * n);
    const po_of = take(&rest, n);
    const pc_of_po = take(&rest, n);
    const stack_pc = take(&rest, n);
    const stack_k = take(&rest, n);
    const idom = take(&rest, n);
    const pred_off = take(&rest, n + 1);
    const preds = take(&rest, 2 * n);
    const cursor = take(&rest, n + 1);

    // 0. The successor model, once per pc (`none` = no edge).
    for (code, 0..) |instr, pc| {
        const s = bc_liveness.successors(instr, @intCast(pc), n);
        succ[2 * pc] = s[0] orelse none;
        succ[2 * pc + 1] = s[1] orelse none;
    }

    // 1. DFS postorder from pc 0. Each pc is pushed at most once, so the
    //    stack never exceeds n.
    @memset(po_of, none);
    var count: u32 = 0;
    var sp: usize = 1;
    stack_pc[0] = 0;
    stack_k[0] = 0;
    po_of[0] = on_stack;
    while (sp > 0) {
        const top = sp - 1;
        const pc = stack_pc[top];
        const k = stack_k[top];
        if (k < 2) {
            stack_k[top] = k + 1;
            const s = succ[2 * pc + k];
            if (s != none and po_of[s] == none) {
                po_of[s] = on_stack;
                stack_pc[sp] = s;
                stack_k[sp] = 0;
                sp += 1;
            }
            continue;
        }
        po_of[pc] = count;
        pc_of_po[count] = pc;
        count += 1;
        sp -= 1;
    }
    const r: usize = count; // reachable pcs; pc 0 has postorder r − 1

    // 2. Predecessors in postorder numbering (CSR). Every successor of a
    //    reachable pc is reachable, so every edge lands in range.
    @memset(pred_off[0 .. r + 1], 0);
    for (pc_of_po[0..r]) |pc| {
        for (succ[2 * pc ..][0..2]) |s| {
            if (s != none) pred_off[po_of[s] + 1] += 1;
        }
    }
    for (1..r + 1) |i| pred_off[i] += pred_off[i - 1];
    @memcpy(cursor[0 .. r + 1], pred_off[0 .. r + 1]);
    for (pc_of_po[0..r], 0..) |pc, po| {
        for (succ[2 * pc ..][0..2]) |s| {
            if (s == none) continue;
            const t = po_of[s];
            preds[cursor[t]] = @intCast(po);
            cursor[t] += 1;
        }
    }

    // 3. Cooper–Harvey–Kennedy over reverse postorder. A DFS parent has a
    //    higher postorder number than its child, so every non-root pc has a
    //    predecessor processed before it in the first pass.
    @memset(idom[0..r], none);
    const root: u32 = @intCast(r - 1);
    idom[root] = root;
    var changed = true;
    while (changed) {
        changed = false;
        var b: u32 = root;
        while (b > 0) {
            b -= 1;
            var new: u32 = none;
            for (preds[pred_off[b]..pred_off[b + 1]]) |p| {
                if (idom[p] == none) continue;
                new = if (new == none) p else intersect(idom[0..r], new, p);
            }
            if (new != idom[b]) {
                idom[b] = new;
                changed = true;
            }
        }
    }

    // 4. Dominator-tree children (CSR, reusing the predecessor arrays), then a
    //    DFS assigning each pc its [pre, post] interval.
    const child_off = pred_off;
    const children = preds;
    @memset(child_off[0 .. r + 1], 0);
    for (0..r - 1) |b| child_off[idom[b] + 1] += 1;
    for (1..r + 1) |i| child_off[i] += child_off[i - 1];
    @memcpy(cursor[0 .. r + 1], child_off[0 .. r + 1]);
    for (0..r - 1) |b| {
        children[cursor[idom[b]]] = @intCast(b);
        cursor[idom[b]] += 1;
    }
    var clock: u32 = 0;
    sp = 1;
    stack_pc[0] = root; // postorder numbers on this stack
    stack_k[0] = child_off[root];
    pre[pc_of_po[root]] = clock;
    clock += 1;
    while (sp > 0) {
        const top = sp - 1;
        const node = stack_pc[top];
        const k = stack_k[top];
        if (k < child_off[node + 1]) {
            stack_k[top] = k + 1;
            const c = children[k];
            pre[pc_of_po[c]] = clock;
            clock += 1;
            stack_pc[sp] = c;
            stack_k[sp] = child_off[c];
            sp += 1;
            continue;
        }
        post[pc_of_po[node]] = clock;
        clock += 1;
        sp -= 1;
    }
    return .{ .pre = pre, .post = post };
}

/// Free a tree `compute` allocated from `alloc` (not needed for the arena).
pub fn free(alloc: std.mem.Allocator, tree: DomTree) void {
    alloc.free(tree.pre);
    alloc.free(tree.post);
}

fn intersect(idom: []const u32, a0: u32, b0: u32) u32 {
    var a = a0;
    var b = b0;
    while (a != b) {
        while (a < b) a = idom[a];
        while (b < a) b = idom[b];
    }
    return a;
}

fn take(rest: *[]u32, len: usize) []u32 {
    const s = rest.*[0..len];
    rest.* = rest.*[len..];
    return s;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn ins(op: bytecode.OpCode, a: u16, aux: i32) Instr {
    return .{ .op = op, .a = a, .aux = aux };
}

fn computeT(code: []const Instr) !DomTree {
    return compute(testing.allocator, testing.allocator, code);
}

test "straight line: each pc dominates everything after it" {
    const code = [_]Instr{ ins(.load_int, 0, 0), ins(.load_int, 1, 0), ins(.ret, 0, 0) };
    const d = try computeT(&code);
    defer free(testing.allocator, d);
    for (0..3) |a| for (0..3) |b| {
        try testing.expectEqual(a <= b, d.dominates(@intCast(a), @intCast(b)));
    };
}

test "diamond: neither arm dominates the join; the fork dominates all" {
    // 0: jmp_if_false → 3; 1: then; 2: jmp → 4; 3: else; 4: join (ret)
    const code = [_]Instr{
        ins(.jmp_if_false, 0, 2),
        ins(.load_int, 1, 0),
        ins(.jmp, 0, 1),
        ins(.load_int, 1, 0),
        ins(.ret, 0, 0),
    };
    const d = try computeT(&code);
    defer free(testing.allocator, d);
    for (0..5) |b| try testing.expect(d.dominates(0, @intCast(b)));
    try testing.expect(!d.dominates(1, 4));
    try testing.expect(!d.dominates(3, 4));
    try testing.expect(!d.dominates(1, 3));
    try testing.expect(d.dominates(1, 2));
}

test "unreachable pcs dominate nothing and are dominated by nothing" {
    // 0: jmp → 2; 1: dead (with an out-of-range jump); 2: ret.
    const code = [_]Instr{ ins(.jmp, 0, 1), ins(.jmp, 0, 50), ins(.ret, 0, 0) };
    const d = try computeT(&code);
    defer free(testing.allocator, d);
    try testing.expect(!d.reachable(1));
    try testing.expect(!d.dominates(1, 1));
    try testing.expect(!d.dominates(0, 1));
    try testing.expect(!d.dominates(1, 2));
    try testing.expect(d.dominates(0, 2));
    try testing.expect(!d.dominates(0, 3)); // out of range
}

test "empty code and a hand-built proto have no dominance at all" {
    const d = try computeT(&.{});
    try testing.expect(!d.available());
    try testing.expect(!d.dominates(0, 0));
    const hand: bytecode.Proto = .{ .code = &.{ins(.ret, 0, 0)} };
    try testing.expect(!hand.dom.available());
    try testing.expect(!hand.dom.dominates(0, 0));
}

// Compiler-shaped CFGs (codex review of §4.8, finding 4): the compiler fills
// `Proto.dom`, and the gates of real loops come from real compiler output.

const Compiled = struct {
    vm: @import("interp.zig").Vm,
    chunk: @import("compiler.zig").Chunk,

    fn deinit(self: *Compiled) void {
        self.chunk.deinit();
        self.vm.deinit();
    }
};

fn compileSrc(src: [:0]const u8) !Compiled {
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try @import("parser.zig").parse(testing.allocator, src, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());
    var vm = try @import("interp.zig").Vm.init(testing.allocator);
    errdefer vm.deinit();
    const chunk = try @import("compiler.zig").compile(testing.allocator, vm.heap, src, tree.root, &diags);
    try testing.expect(!diags.hasErrors());
    return .{ .vm = vm, .chunk = chunk };
}

/// The headers of every loop in `code`, in back-edge order.
fn loopHeaders(code: []const Instr, out: []u32) []u32 {
    var n: usize = 0;
    for (code, 0..) |i, pc| {
        if (bytecode.loopHeaderOf(i, pc)) |h| {
            out[n] = h;
            n += 1;
        }
    }
    return out[0..n];
}

test "sequential loops in a repeat: the first loop's gate dominates the second; a zero-trip header does not" {
    var c = try compileSrc(
        \\local s = 0
        \\repeat
        \\  for i = 1, 3 do s = s + i end
        \\  for j = 1, 3 do s = s + j end
        \\until s > 100
        \\return s
    );
    defer c.deinit();
    const proto = c.chunk.proto;
    const d = proto.dom;
    try testing.expect(d.available());
    var buf: [8]u32 = undefined;
    const hs = loopHeaders(proto.code, &buf);
    try testing.expectEqual(@as(usize, 3), hs.len); // repeat, for A, for B
    // In pc order: the repeat's marker opens the loop, then the two numeric
    // `for`s (the repeat's closer is a `jmp_if_false`, not a back-edge).
    const rep = hs[0];
    const a = hs[1];
    const b = hs[2];
    try testing.expectEqual(bytecode.OpCode.loop, proto.code[rep - 1].op);
    const gate_a = bytecode.loopGateOf(proto, a).?;
    const gate_b = bytecode.loopGateOf(proto, b).?;
    try testing.expectEqual(bytecode.OpCode.for_prep, proto.code[gate_a].op);
    try testing.expectEqual(a - 1, gate_a);
    try testing.expect(d.dominates(gate_a, b));
    try testing.expect(d.dominates(gate_a, gate_b));
    try testing.expect(!d.dominates(gate_b, a));
    // The zero-trip path skips A's header, so the header is not a gate.
    try testing.expect(!d.dominates(a, b));
    // The repeat's marker gates everything in its body.
    const gate_rep = bytecode.loopGateOf(proto, rep).?;
    try testing.expectEqual(rep - 1, gate_rep);
    try testing.expect(d.dominates(gate_rep, a) and d.dominates(gate_rep, b));
}

test "loops in sibling branches: neither gate dominates the other's header" {
    var c = try compileSrc(
        \\local s = 0
        \\while s < 100 do
        \\  if s % 2 == 0 then
        \\    for i = 1, 3 do s = s + i end
        \\  else
        \\    for j = 1, 3 do s = s + j end
        \\  end
        \\end
        \\return s
    );
    defer c.deinit();
    const proto = c.chunk.proto;
    const d = proto.dom;
    var buf: [8]u32 = undefined;
    const hs = loopHeaders(proto.code, &buf);
    try testing.expectEqual(@as(usize, 3), hs.len); // while, for A, for B
    const w = hs[0];
    const a = hs[1];
    const b = hs[2];
    try testing.expect(bytecode.isWhileHeader(proto, w));
    const gate_w = bytecode.loopGateOf(proto, w).?;
    const gate_a = bytecode.loopGateOf(proto, a).?;
    const gate_b = bytecode.loopGateOf(proto, b).?;
    try testing.expect(!d.dominates(gate_a, b));
    try testing.expect(!d.dominates(gate_b, a));
    try testing.expect(d.dominates(gate_w, a) and d.dominates(gate_w, b));
}

test "nested protos get their own tree; a generic for's gate is its tfor_loop" {
    var c = try compileSrc(
        \\local function f(t)
        \\  local s = 0
        \\  for _, v in ipairs(t) do s = s + v end
        \\  return s
        \\end
        \\return f({1, 2, 3})
    );
    defer c.deinit();
    const child = c.chunk.proto.protos[0];
    try testing.expect(child.dom.available());
    var buf: [4]u32 = undefined;
    const hs = loopHeaders(child.code, &buf);
    try testing.expectEqual(@as(usize, 1), hs.len);
    const gate = bytecode.loopGateOf(child, hs[0]).?;
    try testing.expectEqual(bytecode.OpCode.tfor_loop, child.code[gate].op);
    // The gate runs before the body's first iteration (the forward `jmp`
    // enters the test block), so it dominates the header.
    try testing.expect(child.dom.dominates(gate, hs[0]));
}
