//! Pure IR evaluation shared by execution and constant folding.
//! Depends on language semantics and IR vocabulary, never on execution or lifecycle.

const ir = @import("trace_ir.zig");
const arith = @import("arith.zig");
const Value = @import("value.zig").Value;

test "IR evaluator preserves wrapping, floor division, and error semantics" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(i64, -9223372036854775808), (try evalBinary(.add, Value.int(9223372036854775807), Value.int(1))).asInt());
    try testing.expectEqual(@as(i64, -3), (try evalBinary(.idiv, Value.int(-7), Value.int(3))).asInt());
    try testing.expectError(error.DivisionByZero, evalBinary(.idiv, Value.int(1), Value.int(0)));
    try testing.expectError(error.TypeError, evalUnary(.neg, Value.nil()));
    try testing.expectEqual(Value.boolean(true).payload.bits, (try evalUnary(.not, Value.nil())).payload.bits);
}

test "IR evaluator preserves mixed numeric tags and signed zero bits" {
    const testing = @import("std").testing;
    const mixed = try evalBinary(.add, Value.int(2), Value.float(0.5));
    try testing.expectEqual(Value.float(2.5).tag, mixed.tag);
    try testing.expectEqual(Value.float(2.5).payload.bits, mixed.payload.bits);
    const negative_zero = try evalUnary(.neg, Value.float(0.0));
    try testing.expectEqual(Value.float(-0.0).tag, negative_zero.tag);
    try testing.expectEqual(Value.float(-0.0).payload.bits, negative_zero.payload.bits);
    const exact = try evalBinary(.eq, Value.int(9007199254740993), Value.float(9007199254740992.0));
    try testing.expectEqual(Value.boolean(false).tag, exact.tag);
    try testing.expectEqual(Value.boolean(false).payload.bits, exact.payload.bits);
}

/// Evaluate a binary IR op (arithmetic / bitwise / comparison) over two values,
/// using the *exact* `arith.zig` functions tier-0 uses. This is the single
/// evaluator shared by the executor and the trace optimizer's constant
/// folder (`tropt.zig`) — so a folded constant has byte-identical bits to what
/// the executor would compute at runtime, by construction. It is **total**: it
/// only ever returns `arith.Error` (`TypeError` / `DivisionByZero`), never traps
/// (arith.zig wraps integer ops and masks shift counts), so the folder can call
/// it on any constants and merely refuse to fold on error. `op` must be one of
/// the binary ops in the executor switch (else unreachable).
pub fn evalBinary(op: ir.IrOp, a: Value, b: Value) arith.Error!Value {
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
        .sar => arith.sar(a, b),
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
pub fn evalUnary(op: ir.IrOp, a: Value) arith.Error!Value {
    return switch (op) {
        .neg => arith.neg(a),
        .not => Value.boolean(!a.isTruthy()),
        .bnot => arith.bnot(a),
        else => unreachable,
    };
}
