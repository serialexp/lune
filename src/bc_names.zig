//! The name of a value in a runtime error, as Lua 5.4 gives it: "attempt to
//! call a nil value (global 'foo')", "(field 'open')", "(method 'read')".
//! Lua derives it from the bytecode (`getobjname`, ldebug.c): find the
//! instruction that put the value in its register and name what it loaded.
//! Lua's `findsetreg` is a forward scan that trusts the compiler's structured
//! jumps. This one checks the CFG: the candidate is the nearest instruction
//! before the faulting pc that may write the register, and it is the value's
//! source only if no jump from outside lands between the two. Then every path
//! into that stretch of code comes through the candidate, and nothing in it
//! writes the register. A loop that reassigns the register after the fault,
//! or a branch that assigns it on one side only, gives no name rather than a
//! wrong one.
//!
//! mahina keeps no local or upvalue names, so a value read from one gets no
//! name (Lua's "local 'f'" / "upvalue 'f'").
//!
//! Cost: per question, a backward scan to the candidate and a pass over the
//! code's jumps (a table lookup per instruction), with no allocation. A
//! caught fault in a loop pays it every time, so it has to stay small next to
//! raising and catching the fault. A `pcall` loop of a million nil calls
//! from a 30-instruction function: 0.17 s before names, 0.29 s with them,
//! `lua5.4` 0.37 s (ReleaseFast, 2026-10-24; `bench/stdlib/pcall_faults.lua`
//! is the standing benchmark). Only `Vm.describeFault` asks, on the error
//! path.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const bc_liveness = @import("bc_liveness.zig");
const string = @import("string.zig");

const Instr = bytecode.Instr;
const Proto = bytecode.Proto;

pub const Origin = struct {
    kind: Kind,
    /// The global's name or the field's key.
    name: []const u8,
    /// For a field or method: the global its table was read from (`io` in
    /// `io.open`), when it was one.
    table_global: ?[]const u8 = null,

    pub const Kind = enum { global, field, method };
};

/// What register `reg` holds just before the instruction at `pc` runs, or
/// null when that can't be named. The names point into the proto's
/// constants. Allocates nothing.
pub fn originOf(proto: *const Proto, pc: u32, reg: u16) ?Origin {
    if (pc >= proto.code.len) return null;
    return origin(proto, pc, reg);
}

/// Where one successor of an opcode goes, as a function of `pc` and `aux`.
const Succ = enum {
    none,
    /// `pc + 1`.
    next,
    /// `pc + 1 + aux`, when inside the code.
    jump,
    /// `pc + 2 + aux`, when it and the jump before it are inside the code
    /// (`for_prep`'s skip, one past its `for_loop`).
    past_jump,
};

/// Per opcode, its two successors' shapes, or null when they fit none and
/// `bc_liveness.successors` must be asked. Derived from that successor model
/// at compile time (two `aux` values tell a jump from anything else), so the
/// two cannot disagree.
const succ_shapes = blk: {
    @setEvalBranchQuota(200_000);
    var t = std.enums.EnumArray(bytecode.OpCode, ?[2]Succ).initFill(null);
    for (std.enums.values(bytecode.OpCode)) |op| {
        // `itern` falls through (doc 66 P1); its effect is out of line, which
        // comptime cannot follow.
        if (op == .itern) {
            t.set(op, .{ .next, .none });
            continue;
        }
        const x = bc_liveness.successors(.{ .op = op, .aux = 7 }, 10, 100);
        const y = bc_liveness.successors(.{ .op = op, .aux = -4 }, 10, 100);
        var shape: [2]Succ = undefined;
        var known = true;
        for (0..2) |i| {
            shape[i] = if (x[i] == null and y[i] == null)
                .none
            else if (x[i] == 11 and y[i] == 11)
                .next
            else if (x[i] == 18 and y[i] == 7)
                .jump
            else if (x[i] == 19 and y[i] == 8)
                .past_jump
            else blk2: {
                known = false;
                break :blk2 .none;
            };
        }
        if (known) t.set(op, shape);
    }
    break :blk t;
};

/// The successors of `ins` at `pc`: `bc_liveness.successors`, from the
/// comptime shapes when the opcode has one.
fn successors(ins: Instr, pc: u32, code_len: usize) [2]?u32 {
    const shape = succ_shapes.get(ins.op) orelse return bc_liveness.successors(ins, pc, code_len);
    const j: i64 = @as(i64, pc) + 1 + ins.aux;
    const end: i64 = @intCast(code_len);
    var targets: [2]?u32 = undefined;
    for (shape, &targets) |s, *t| t.* = switch (s) {
        .none => null,
        .next => if (pc + 1 < code_len) pc + 1 else null,
        .jump => if (j >= 0 and j < end) @intCast(j) else null,
        .past_jump => if (j >= 0 and j + 1 < end) @intCast(j + 1) else null,
    };
    return targets;
}

/// Whether an opcode can leave other than by falling through: a jump, a
/// branch, a loop op, or `ret`/`halt`. A plain table, so `proven`'s walk
/// costs a load per instruction.
const jumps_away = blk: {
    var t = std.enums.EnumArray(bytecode.OpCode, bool).initFill(true);
    for (std.enums.values(bytecode.OpCode)) |op| {
        const s = succ_shapes.get(op) orelse continue;
        t.set(op, !(s[0] == .next and s[1] == .none));
    }
    break :blk t;
};

fn origin(proto: *const Proto, pc: u32, reg: u16) ?Origin {
    const code = proto.code;
    const def = candidate(code, pc, reg) orelse return null;
    const ins = code[def];
    // Only a load is named; the proof is for those alone.
    if (ins.op == .get_global) {
        if (!proven(1, code, .{.{ def, pc }})[0]) return null;
        return .{ .kind = .global, .name = constText(proto, ins.b) orelse return null };
    }
    if (ins.op != .get_field) return null;
    const key = constText(proto, ins.c) orelse return null;
    // `t:m(...)`: the compiler copies `t` to the slot above the call base
    // and reads `m` from that copy, which the call then passes as its first
    // argument. A plain `a.b.c()` can read from the same slot, but the call
    // either passes no argument there or one computed after: the slot's
    // writer at the call must be the one at the lookup.
    const call = code[pc];
    const self_copy: ?u32 = if (ins.b == @as(u32, reg) + 1 and call.op == .call and call.a == reg and call.b != 0)
        if (candidate(code, pc, ins.b)) |at_call| (if (candidate(code, def, ins.b) == at_call) at_call else null) else null
    else
        null;
    // One walk for all the proofs.
    const ok: [3]bool = if (self_copy) |m|
        proven(3, code, .{ .{ def, pc }, .{ m, pc }, .{ m, def } })
    else
        .{ proven(1, code, .{.{ def, pc }})[0], false, false };
    if (!ok[0]) return null;
    var o: Origin = .{ .kind = if (self_copy != null and ok[1] and ok[2]) .method else .field, .name = key };
    if (origin(proto, def, ins.b)) |t| {
        if (t.kind == .global) o.table_global = t.name;
    }
    return o;
}

/// The nearest instruction before `pc` that may write `reg`, or null. None
/// between the two does; whether it is the write that reaches `pc` is
/// `proven`'s question.
fn candidate(code: []const Instr, pc: u32, reg: u16) ?u32 {
    var d = pc;
    while (d > 0) {
        d -= 1;
        if (bc_liveness.mayWrite(code[d], d, code.len, reg)) return d;
    }
    return null;
}

/// For each `{d, pc}`, whether `candidate`'s `d` is the write of its
/// register that reaches `pc` on every path. It is when no jump from outside
/// `[d, pc)` lands in `(d, pc]`: then the only way into that stretch is
/// through `d` (the entry, pc 0, is not in it), so `d` dominates `pc`, and
/// nothing between them writes the register. One walk over the code
/// answers them all.
fn proven(comptime n: usize, code: []const Instr, spans: [n][2]u32) [n]bool {
    var ok: [n]bool = @splat(true);
    for (code, 0..) |ins, i| {
        if (!jumps_away.get(ins.op)) continue;
        const from: u32 = @intCast(i);
        for (successors(ins, from, code.len)) |s| if (s) |t| {
            if (t == from + 1) continue;
            for (spans, &ok) |sp, *k| {
                if (t > sp[0] and t <= sp[1] and (from < sp[0] or from >= sp[1])) k.* = false;
            }
        };
    }
    return ok;
}

test "the comptime successor shapes agree with bc_liveness on every opcode" {
    var shaped: usize = 0;
    for (std.enums.values(bytecode.OpCode)) |op| {
        shaped += @intFromBool(succ_shapes.get(op) != null);
        for ([_]i32{ -30, -11, -1, 0, 1, 5, 18, 40 }) |aux| for ([_]u32{ 0, 10, 19 }) |pc| {
            const ins: Instr = .{ .op = op, .a = 3, .b = 1, .c = 2, .aux = aux };
            const want = bc_liveness.successors(ins, pc, 20);
            const got = successors(ins, pc, 20);
            try testing.expectEqual(want[0], got[0]);
            try testing.expectEqual(want[1], got[1]);
        };
    }
    // Every opcode the compiler emits has a shape (none falls back).
    try testing.expectEqual(std.enums.values(bytecode.OpCode).len, shaped);
}

fn constText(proto: *const Proto, idx: u32) ?[]const u8 {
    if (idx >= proto.constants.len) return null;
    const v = proto.constants[idx];
    if (!(v.isHeap() and v.heapType() == .string)) return null;
    return string.String.fromHeader(v.asHeap()).bytes();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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

/// The callee of the `nth` call (0-based) in the main chunk, named.
fn calleeName(src: [:0]const u8, nth: usize) !?struct { kind: Origin.Kind, text: []const u8 } {
    var c = try compileSrc(src);
    defer c.deinit();
    const code = c.chunk.proto.code;
    var seen: usize = 0;
    for (code, 0..) |ins, pc| {
        if (ins.op != .call) continue;
        if (seen < nth) {
            seen += 1;
            continue;
        }
        const o = originOf(c.chunk.proto, @intCast(pc), ins.a) orelse return null;
        const text = if (o.table_global) |g|
            try std.fmt.allocPrint(testing.allocator, "{s}.{s}", .{ g, o.name })
        else
            try testing.allocator.dupe(u8, o.name);
        return .{ .kind = o.kind, .text = text };
    }
    return error.NoSuchCall;
}

fn expectCallee(src: [:0]const u8, nth: usize, kind: Origin.Kind, text: []const u8) !void {
    const got = (try calleeName(src, nth)) orelse return error.TestExpectedName;
    defer testing.allocator.free(got.text);
    try testing.expectEqual(kind, got.kind);
    try testing.expectEqualStrings(text, got.text);
}

fn expectNoName(src: [:0]const u8, nth: usize) !void {
    if (try calleeName(src, nth)) |got| {
        defer testing.allocator.free(got.text);
        std.debug.print("unexpected name {s} {s}\n", .{ @tagName(got.kind), got.text });
        return error.TestUnexpectedName;
    }
}

test "a global, a field of a global, a nested field and a method are named" {
    try expectCallee("foo()", 0, .global, "foo");
    try expectCallee("local x = io.open(\"a\" or b, \"r\")", 0, .field, "io.open");
    try expectCallee("foo.bar.baz()", 0, .field, "baz");
    try expectCallee("foo.bar.baz(1, 2)", 0, .field, "baz");
    try expectCallee("local t = {} t:m(1)", 0, .method, "m");
    // Lua 5.4 names this one a field too.
    try expectCallee("local t = {} t.m(t)", 0, .field, "m");
    // Arguments with jumps of their own between the lookup and the call.
    try expectCallee("os.date(a and b or c, x > 1 and 2)", 0, .field, "os.date");
}

test "a local and a loop variable get no name" {
    try expectNoName("local f = os.time f()", 0);
    try expectNoName("for _, g in ipairs({}) do g() end", 1);
    try expectNoName("local f = io.open if c then f = os.time end f()", 0);
}

/// Name `reg` before `pc` in hand-built `code` over the constants `a`, `b`.
fn handBuilt(code: []const Instr, pc: u32, reg: u16) !?Origin {
    var vm = try @import("interp.zig").Vm.init(testing.allocator);
    defer vm.deinit();
    const consts = [_]@import("value.zig").Value{ try vm.heap.internValue("a"), try vm.heap.internValue("b") };
    const proto: Proto = .{ .code = code, .constants = &consts, .num_registers = 2 };
    const o = originOf(&proto, pc, reg) orelse return null;
    // The name points into the VM's heap; check it before the VM goes.
    try testing.expectEqualStrings("a", o.name);
    return o;
}

test "one writer on every path is named; two writers, or none on some path, give no name" {
    const I = Instr;
    // r0 = a; call r0
    try testing.expect((try handBuilt(&.{ I.opAB(.get_global, 0, 0), I.opABC(.call, 0, 0, 0), I.op0(.halt) }, 1, 0)) != null);
    // r0 = a; if r1 then r0 = b end; call r0
    try testing.expect((try handBuilt(&.{
        I.opAB(.get_global, 0, 0),
        I.opAx(.jmp_if_false, 1, 1),
        I.opAB(.get_global, 0, 1),
        I.opABC(.call, 0, 0, 0),
        I.op0(.halt),
    }, 3, 0)) == null);
    // r0 = a; loop: call r0; r0 = b; goto loop — the second iteration calls b.
    try testing.expect((try handBuilt(&.{
        I.opAB(.get_global, 0, 0),
        I.opABC(.call, 0, 0, 0),
        I.opAB(.get_global, 0, 1),
        I.opJ(.jmp, -3),
    }, 1, 0)) == null);
    // if r1 then r0 = a end; call r0 — the path that skips it has no writer.
    try testing.expect((try handBuilt(&.{
        I.opAx(.jmp_if_false, 1, 1),
        I.opAB(.get_global, 0, 0),
        I.opABC(.call, 0, 0, 0),
        I.op0(.halt),
    }, 2, 0)) == null);
    // if not r1 then r0 = a end; r1 = 0; call r0 — a jump from before the
    // candidate lands between it and the use.
    try testing.expect((try handBuilt(&.{
        I.opAx(.jmp_if_true, 1, 1),
        I.opAB(.get_global, 0, 0),
        I.opAB(.load_int, 1, 0),
        I.opABC(.call, 0, 0, 0),
        I.op0(.halt),
    }, 3, 0)) == null);
    // A call between the lookup and the use may write every register above
    // its base.
    try testing.expect((try handBuilt(&.{
        I.opAB(.get_global, 1, 0),
        I.opABC(.call, 0, 0, bytecode.all_results),
        I.opABC(.call, 1, 0, 0),
        I.op0(.halt),
    }, 2, 1)) == null);
}
