//! Tier-0 interpreter — executes register bytecode (`bytecode.zig`).
//!
//! This is the **correctness oracle** for the whole engine: the IR-interpreter
//! (tier-1a) and native codegen (tier-1b) are validated by differential testing
//! *against* this tier (docs/design/00-architecture.md §Testing strategy). So it
//! is written for clarity and obvious-correctness, not speed: a plain
//! `while (true) switch (op)` dispatch loop.
//!
//! Phase 0 proved that guaranteed tail calls (`@call(.always_tail)`) work on the
//! pinned toolchain (LLVM backend), which is the *threaded-dispatch* speed-up we
//! can graft onto this loop later if tier-0 dispatch ever shows up in a profile.
//! It deliberately does not here — tier-0 is the slow, always-correct tier, and
//! a switch is easier to read, extend, and trust as the oracle.
//!
//! The interpreter is built up across the Phase 3 increments. Opcodes whose
//! runtime support has not landed yet return `error.Unimplemented` rather than
//! silently misbehaving.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;

/// Runtime errors surfaced to the host. A superset of `arith.Error` so pure
/// numeric ops coerce in with a bare `try`.
pub const Error = error{
    /// Operand had the wrong type for an operation (e.g. `nil + 1`).
    TypeError,
    /// Integer `//` or `%` by zero.
    DivisionByZero,
    /// An opcode whose runtime support has not been implemented yet.
    Unimplemented,
    /// Allocation failure (register stack, future heap).
    OutOfMemory,
};

/// The tier-0 virtual machine. Owns the resources a running program needs that
/// outlive a single frame; for Increment A that is just the allocator (the heap,
/// globals, and a shared register stack arrive in later increments).
pub const Vm = struct {
    gpa: std.mem.Allocator,
    /// The object heap (strings, tables). Owns every heap value a running
    /// program produces; freed wholesale by `deinit`.
    heap: gc.Heap,

    pub fn init(gpa: std.mem.Allocator) Vm {
        return .{ .gpa = gpa, .heap = gc.Heap.init(gpa) };
    }

    /// Frees the heap and every object on it. Any `Value` returned by `run` that
    /// is a heap reference dangles after this — inspect results first.
    pub fn deinit(self: *Vm) void {
        self.heap.deinit();
    }

    /// Execute a top-level chunk and return its first returned value (`nil` if it
    /// returns nothing or falls off the end via `halt`).
    pub fn run(self: *Vm, proto: *const Proto) Error!Value {
        const regs = try self.gpa.alloc(Value, proto.num_registers);
        defer self.gpa.free(regs);
        @memset(regs, Value.nil());
        return self.execFrame(proto, regs);
    }

    /// Run one activation: interpret `proto.code` over the register window
    /// `regs`. Returns the frame's first returned value.
    fn execFrame(self: *Vm, proto: *const Proto, regs: []Value) Error!Value {
        const code = proto.code;
        var pc: usize = 0;
        while (true) {
            const instr = code[pc];
            pc += 1;
            const a: usize = instr.a;
            switch (instr.op) {
                // ---- loads & moves ----
                .load_nil => regs[a] = Value.nil(),
                .load_bool => regs[a] = Value.boolean(instr.b != 0),
                .load_int => regs[a] = Value.int(instr.aux),
                .load_const => regs[a] = proto.constants[instr.b],
                .move => regs[a] = regs[instr.b],

                // ---- arithmetic (semantics live in arith.zig) ----
                .add => regs[a] = try arith.add(regs[instr.b], regs[instr.c]),
                .sub => regs[a] = try arith.sub(regs[instr.b], regs[instr.c]),
                .mul => regs[a] = try arith.mul(regs[instr.b], regs[instr.c]),
                .div => regs[a] = try arith.div(regs[instr.b], regs[instr.c]),
                .idiv => regs[a] = try arith.floorDiv(regs[instr.b], regs[instr.c]),
                .mod => regs[a] = try arith.mod(regs[instr.b], regs[instr.c]),
                .pow => regs[a] = try arith.pow(regs[instr.b], regs[instr.c]),

                // ---- bitwise ----
                .band => regs[a] = try arith.band(regs[instr.b], regs[instr.c]),
                .bor => regs[a] = try arith.bor(regs[instr.b], regs[instr.c]),
                .bxor => regs[a] = try arith.bxor(regs[instr.b], regs[instr.c]),
                .shl => regs[a] = try arith.shl(regs[instr.b], regs[instr.c]),
                .shr => regs[a] = try arith.shr(regs[instr.b], regs[instr.c]),

                // ---- unary ----
                .neg => regs[a] = try arith.neg(regs[instr.b]),
                .not => regs[a] = Value.boolean(!regs[instr.b].isTruthy()),
                .bnot => regs[a] = try arith.bnot(regs[instr.b]),
                .len => regs[a] = try lenOf(regs[instr.b]),

                // ---- concat ----
                .concat => regs[a] = try self.concat(regs[instr.b], regs[instr.c]),

                // ---- comparisons → boolean register ----
                // `gt`/`ge` reuse `lt`/`le` with operands swapped (a>b ≡ b<a).
                .eq => regs[a] = Value.boolean(arith.eq(regs[instr.b], regs[instr.c])),
                .ne => regs[a] = Value.boolean(!arith.eq(regs[instr.b], regs[instr.c])),
                .lt => regs[a] = Value.boolean(try arith.lt(regs[instr.b], regs[instr.c])),
                .le => regs[a] = Value.boolean(try arith.le(regs[instr.b], regs[instr.c])),
                .gt => regs[a] = Value.boolean(try arith.lt(regs[instr.c], regs[instr.b])),
                .ge => regs[a] = Value.boolean(try arith.le(regs[instr.c], regs[instr.b])),

                // ---- control flow ----
                .jmp => pc = applyJump(pc, instr.aux),
                .jmp_if_false => if (!regs[a].isTruthy()) {
                    pc = applyJump(pc, instr.aux);
                },
                .jmp_if_true => if (regs[a].isTruthy()) {
                    pc = applyJump(pc, instr.aux);
                },

                // ---- tables ----
                .new_table => {
                    const t = try self.heap.newTable();
                    regs[a] = Value.heap(&t.header);
                },
                .get_index => regs[a] = try indexGet(regs[instr.b], regs[instr.c]),
                .set_index => try self.indexSet(regs[a], regs[instr.b], regs[instr.c]),

                // ---- globals / functions (later increments) ----
                .get_global,
                .set_global,
                .closure,
                .get_upval,
                .set_upval,
                .call,
                => return Error.Unimplemented,

                // ---- returns ----
                .ret => return if (instr.b >= 1) regs[a] else Value.nil(),
                .halt => return Value.nil(),
            }
        }
    }

    /// `R[b] .. R[c]` — string concatenation. Strings concatenate directly;
    /// numbers coerce to their text form (Lua-shaped). Anything else errors.
    /// The result is interned.
    fn concat(self: *Vm, a: Value, b: Value) Error!Value {
        var buf_a: [64]u8 = undefined;
        var buf_b: [64]u8 = undefined;
        const sa = try coerceConcat(a, &buf_a);
        const sb = try coerceConcat(b, &buf_b);

        const tmp = try self.gpa.alloc(u8, sa.len + sb.len);
        defer self.gpa.free(tmp);
        @memcpy(tmp[0..sa.len], sa);
        @memcpy(tmp[sa.len..], sb);
        return self.heap.internValue(tmp);
    }

    /// `container[key]`. Only tables are indexable in v1 (no string indexing /
    /// metatables yet).
    fn indexGet(container: Value, key: Value) Error!Value {
        if (container.isHeap() and container.heapType() == .table) {
            return table.Table.fromHeader(container.asHeap()).get(key);
        }
        return Error.TypeError;
    }

    /// `container[key] = val`. The write-barrier seam fires here: a value stored
    /// into a heap container.
    fn indexSet(self: *Vm, container: Value, key: Value, val: Value) Error!void {
        if (container.isHeap() and container.heapType() == .table) {
            const t = table.Table.fromHeader(container.asHeap());
            try t.set(self.gpa, key, val);
            self.heap.writeBarrier(&t.header, val); // no-op until Phase 4
            return;
        }
        return Error.TypeError;
    }
};

/// Coerce a concat operand to bytes: a string's own bytes, or a number formatted
/// into `buf`. Returns a slice valid until `buf` is reused.
fn coerceConcat(v: Value, buf: []u8) Error![]const u8 {
    return switch (v.tag) {
        .heap_ref => if (v.heapType() == .string)
            string.String.fromHeader(v.asHeap()).bytes()
        else
            Error.TypeError,
        .int => std.fmt.bufPrint(buf, "{d}", .{v.asInt()}) catch unreachable,
        .float => std.fmt.bufPrint(buf, "{d}", .{v.asFloat()}) catch unreachable,
        else => Error.TypeError,
    };
}

/// `#v` — length of a string (bytes) or table (border). Other types error.
fn lenOf(v: Value) Error!Value {
    if (v.isHeap()) {
        return switch (v.heapType()) {
            .string => Value.int(@intCast(string.String.fromHeader(v.asHeap()).len)),
            .table => Value.int(table.Table.fromHeader(v.asHeap()).length()),
            else => Error.TypeError,
        };
    }
    return Error.TypeError;
}

/// Apply a relative jump. `pc` has already advanced past the jump instruction,
/// so the offset is measured from the *next* instruction (offset 0 = no-op).
inline fn applyJump(pc: usize, offset: i32) usize {
    const signed: i64 = @as(i64, @intCast(pc)) + offset;
    return @intCast(signed);
}

// ---------------------------------------------------------------------------
// Tests — hand-assembled prototypes (no compiler yet; that is Increment C).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a one-off prototype, run it, and return the first result.
fn runCode(code: []const Instr, constants: []const Value, num_registers: u16) Error!Value {
    const proto = Proto{
        .code = code,
        .constants = constants,
        .num_registers = num_registers,
        .name = "test",
    };
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    return vm.run(&proto);
}

test "arithmetic: (2 + 3) * 4 == 20" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 2),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.add, 0, 0, 1), // r0 = 2 + 3
        Instr.opAx(.load_int, 1, 4),
        Instr.opABC(.mul, 0, 0, 1), // r0 = 5 * 4
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &.{}, 2);
    try testing.expect(r.isInt());
    try testing.expectEqual(@as(i64, 20), r.asInt());
}

test "load_const pulls float literals from the pool" {
    const consts = [_]Value{ Value.float(1.5), Value.float(2.5) };
    const code = [_]Instr{
        Instr.opAB(.load_const, 0, 0),
        Instr.opAB(.load_const, 1, 1),
        Instr.opABC(.add, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &consts, 2);
    try testing.expectEqual(@as(f64, 4.0), r.asFloat());
}

test "comparison writes a boolean; not inverts truthiness" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 3),
        Instr.opAx(.load_int, 1, 5),
        Instr.opABC(.lt, 0, 0, 1), // r0 = 3 < 5 = true
        Instr.opAB(.not, 0, 0), // r0 = not true = false
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &.{}, 2);
    try testing.expect(r.isBool());
    try testing.expectEqual(false, r.asBool());
}

test "gt/ge are lt/le with swapped operands" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.gt, 0, 0, 1), // 5 > 3 = true
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectEqual(true, (try runCode(&code, &.{}, 2)).asBool());
}

test "forward jump skips an instruction" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 1),
        Instr.opJ(.jmp, 1), // skip the next instruction
        Instr.opAx(.load_int, 0, 999), // skipped
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectEqual(@as(i64, 1), (try runCode(&code, &.{}, 1)).asInt());
}

test "conditional jump + back-edge: sum 1..5 == 15" {
    // r0 = i (counter, counts down 5..1), r1 = acc, r2 = scratch
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5), //  0: i = 5
        Instr.opAx(.load_int, 1, 0), //  1: acc = 0
        // loop:
        Instr.opAx(.load_int, 2, 0), //  2: scratch = 0
        Instr.opABC(.le, 2, 0, 2), //  3: scratch = (i <= 0)
        Instr.opAx(.jmp_if_true, 2, 4), //  4: if i<=0 goto end (pc 9)
        Instr.opABC(.add, 1, 1, 0), //  5: acc += i
        Instr.opAx(.load_int, 2, 1), //  6: scratch = 1
        Instr.opABC(.sub, 0, 0, 2), //  7: i -= 1
        Instr.opJ(.jmp, -7), //  8: goto loop (back to pc 2)
        // end:
        Instr.opAB(.ret, 1, 1), //  9: return acc
    };
    const r = try runCode(&code, &.{}, 3);
    try testing.expectEqual(@as(i64, 15), r.asInt());
}

test "type error propagates from a bad operand" {
    const code = [_]Instr{
        Instr.opA(.load_nil, 0),
        Instr.opAx(.load_int, 1, 1),
        Instr.opABC(.add, 0, 0, 1), // nil + 1
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "ret with no values yields nil; halt yields nil" {
    const r0 = try runCode(&[_]Instr{Instr.opAB(.ret, 0, 0)}, &.{}, 1);
    try testing.expect(r0.isNil());
    const r1 = try runCode(&[_]Instr{Instr.op0(.halt)}, &.{}, 1);
    try testing.expect(r1.isNil());
}

test "new_table + set_index + get_index round-trips a value" {
    // local t = {}; t[1] = 42; return t[1]
    const code = [_]Instr{
        Instr.opA(.new_table, 0),
        Instr.opAx(.load_int, 1, 1), // key
        Instr.opAx(.load_int, 2, 42), // value
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opABC(.get_index, 1, 0, 1),
        Instr.opAB(.ret, 1, 1),
    };
    // Result is a scalar int, so the deinit-after-return helper is safe here.
    try testing.expectEqual(@as(i64, 42), (try runCode(&code, &.{}, 3)).asInt());
}

test "#t counts the sequence border" {
    // t = {10, 20, 30}; return #t
    const code = [_]Instr{
        Instr.opA(.new_table, 0),
        Instr.opAx(.load_int, 1, 1), Instr.opAx(.load_int, 2, 10), Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 2), Instr.opAx(.load_int, 2, 20), Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 3), Instr.opAx(.load_int, 2, 30), Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAB(.len, 1, 0),
        Instr.opAB(.ret, 1, 1),
    };
    try testing.expectEqual(@as(i64, 3), (try runCode(&code, &.{}, 3)).asInt());
}

test "indexing a non-table is a type error" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opAx(.load_int, 1, 1),
        Instr.opABC(.get_index, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "concat joins strings and coerces numbers; result is interned" {
    var vm = Vm.init(testing.allocator);
    defer vm.deinit();
    // "x=" .. 42  ->  "x=42"
    const consts = [_]Value{try vm.heap.internValue("x=")};
    const code = [_]Instr{
        Instr.opAB(.load_const, 0, 0),
        Instr.opAx(.load_int, 1, 42),
        Instr.opABC(.concat, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const proto = Proto{ .code = &code, .constants = &consts, .num_registers = 2, .name = "t" };
    const r = try vm.run(&proto); // inspect before deinit (heap result)
    try testing.expect(r.isHeap());
    try testing.expectEqualStrings("x=42", string.String.fromHeader(r.asHeap()).bytes());
}
