//! Numeric semantics — the arithmetic and comparison rules that "fix the guard
//! set" for the JIT (docs/design/00-architecture.md §Value representation, Phase
//! 1). Decisions locked here:
//!
//!   * **`i64` overflow wraps** (two's complement). Branchless, deterministic,
//!     and trace-stable — an `i64` op never changes type or traps, so the only
//!     guards arithmetic needs are the operand type guards. (Trap and
//!     promote-to-float were both rejected for the JIT; see the doc.)
//!   * **Mixed `i64`/`f64` promotes to `f64`**; the result is `f64`.
//!   * **`/` is always float division** (`int / int` → `f64`).
//!   * **`//` is integer floor-division** when both are `i64` (Lua-shaped),
//!     float `floor(a/b)` otherwise. Integer `//` (and `%`) by zero errors.
//!   * **`%` is floored modulo** (result takes the divisor's sign), Lua-style.
//!
//! These functions operate on dynamically-typed `Value`s and return
//! `error.TypeError` for non-numeric operands (string/table operators come with
//! those types later). They are pure — no allocation, no VM state — which is why
//! their shape is pinned with tests now.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

pub const Error = error{
    /// An operand was not a number (and no operator overload applies in v1).
    TypeError,
    /// Integer `//` or `%` with a zero divisor.
    DivisionByZero,
};

inline fn bothInt(a: Value, b: Value) bool {
    return a.isInt() and b.isInt();
}

inline fn requireNumbers(a: Value, b: Value) Error!void {
    if (!a.isNumber() or !b.isNumber()) return Error.TypeError;
}

/// `a + b`. Integer add wraps; mixed/float add is IEEE.
pub fn add(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    if (bothInt(a, b)) return Value.int(a.asInt() +% b.asInt());
    return Value.float(a.toFloat() + b.toFloat());
}

/// `a - b`. Integer subtract wraps.
pub fn sub(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    if (bothInt(a, b)) return Value.int(a.asInt() -% b.asInt());
    return Value.float(a.toFloat() - b.toFloat());
}

/// `a * b`. Integer multiply wraps.
pub fn mul(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    if (bothInt(a, b)) return Value.int(a.asInt() *% b.asInt());
    return Value.float(a.toFloat() * b.toFloat());
}

/// `-a`. Integer negate wraps (`-minInt == minInt`).
pub fn neg(a: Value) Error!Value {
    return switch (a.tag) {
        .int => Value.int(0 -% a.asInt()),
        .float => Value.float(-a.asFloat()),
        else => Error.TypeError,
    };
}

/// `a / b` — **always float division**. `int / int` yields `f64`; division by
/// zero follows IEEE (`±inf` / `nan`), it does not error.
pub fn div(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    return Value.float(a.toFloat() / b.toFloat());
}

/// `a // b` — floor division. Integer result when both are integers (errors on
/// a zero divisor); otherwise `floor(a/b)` as a float.
pub fn floorDiv(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    if (bothInt(a, b)) {
        const x = a.asInt();
        const y = b.asInt();
        if (y == 0) return Error.DivisionByZero;
        // Only overflowing case is minInt // -1 == 2^63, which wraps to minInt.
        if (x == std.math.minInt(i64) and y == -1) return Value.int(x);
        return Value.int(@divFloor(x, y));
    }
    return Value.float(@floor(a.toFloat() / b.toFloat()));
}

/// `a % b` — floored modulo (result takes the sign of `b`), Lua-style. Integer
/// modulo by zero errors; float modulo by zero yields `nan` (no error).
pub fn mod(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    if (bothInt(a, b)) {
        const y = b.asInt();
        if (y == 0) return Error.DivisionByZero;
        // @mod is floored modulo in Zig; minInt % -1 == 0 (no overflow).
        return Value.int(@mod(a.asInt(), y));
    }
    const x = a.toFloat();
    const y = b.toFloat();
    // Lua float modulo: a - floor(a/b)*b.
    return Value.float(x - @floor(x / y) * y);
}

/// `a ^ b` — exponentiation, **always float** (Lua-shaped). `2 ^ 2` is `4.0`.
pub fn pow(a: Value, b: Value) Error!Value {
    try requireNumbers(a, b);
    return Value.float(std.math.pow(f64, a.toFloat(), b.toFloat()));
}

// ---- bitwise ----
//
// Bitwise operators act on the 64-bit two's-complement pattern of integer
// operands. v1 requires **integer** operands (a float with an integral value is
// not yet coerced — that convenience is deferred); non-integers error with
// `TypeError`. Shifts are *logical* (zero-filled) and Lua-style: a shift count
// outside [-63, 63] shifts every bit out and yields 0; a negative count shifts
// the other direction.

inline fn requireInts(a: Value, b: Value) Error!void {
    if (!a.isInt() or !b.isInt()) return Error.TypeError;
}

/// `a & b` (bitwise and).
pub fn band(a: Value, b: Value) Error!Value {
    try requireInts(a, b);
    return Value.int(a.asInt() & b.asInt());
}

/// `a | b` (bitwise or).
pub fn bor(a: Value, b: Value) Error!Value {
    try requireInts(a, b);
    return Value.int(a.asInt() | b.asInt());
}

/// `a ~ b` (bitwise xor) — binary `~`.
pub fn bxor(a: Value, b: Value) Error!Value {
    try requireInts(a, b);
    return Value.int(a.asInt() ^ b.asInt());
}

/// `~a` (bitwise not) — unary `~`.
pub fn bnot(a: Value) Error!Value {
    if (!a.isInt()) return Error.TypeError;
    return Value.int(~a.asInt());
}

/// Logical left shift of the 64-bit pattern `x` by `n` bits, Lua-style: `n < 0`
/// shifts right, `|n| >= 64` yields 0.
fn shiftLeft(x: i64, n: i64) i64 {
    if (n <= -64 or n >= 64) return 0;
    const ux: u64 = @bitCast(x);
    if (n >= 0) return @bitCast(ux << @intCast(n));
    return @bitCast(ux >> @intCast(-n));
}

/// Logical right shift of the 64-bit pattern `x` by `n` bits, Lua-style: `n < 0`
/// shifts left, `|n| >= 64` yields 0. Written directly (not via `-n`) so a
/// `minInt` count cannot overflow the negation.
fn shiftRight(x: i64, n: i64) i64 {
    if (n <= -64 or n >= 64) return 0;
    const ux: u64 = @bitCast(x);
    if (n >= 0) return @bitCast(ux >> @intCast(n));
    return @bitCast(ux << @intCast(-n));
}

/// `a << b` (logical left shift, Lua semantics).
pub fn shl(a: Value, b: Value) Error!Value {
    try requireInts(a, b);
    return Value.int(shiftLeft(a.asInt(), b.asInt()));
}

/// `a >> b` (logical right shift, Lua semantics).
pub fn shr(a: Value, b: Value) Error!Value {
    try requireInts(a, b);
    return Value.int(shiftRight(a.asInt(), b.asInt()));
}

// ---- comparisons ----

/// `a < b` for numbers. A `NaN` operand makes this false. Non-numbers error
/// (string ordering comes with the string type).
pub fn lt(a: Value, b: Value) Error!bool {
    try requireNumbers(a, b);
    return value.compareNumeric(a, b) == .lt;
}

/// `a <= b` for numbers. A `NaN` operand makes this false.
pub fn le(a: Value, b: Value) Error!bool {
    try requireNumbers(a, b);
    const o = value.compareNumeric(a, b);
    return o == .lt or o == .eq;
}

/// `a == b`. Never errors: different types are simply unequal. Numbers compare
/// across the int/float boundary by exact value.
pub fn eq(a: Value, b: Value) bool {
    return a.eql(b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "add: integer add stays integer" {
    const r = try add(Value.int(2), Value.int(3));
    try expect(r.isInt());
    try expectEqual(@as(i64, 5), r.asInt());
}

test "add: i64 overflow wraps (no trap, no promote)" {
    const r = try add(Value.int(std.math.maxInt(i64)), Value.int(1));
    try expect(r.isInt());
    try expectEqual(std.math.minInt(i64), r.asInt());
}

test "mul: i64 overflow wraps" {
    const r = try mul(Value.int(std.math.maxInt(i64)), Value.int(2));
    try expect(r.isInt());
    try expectEqual(@as(i64, -2), r.asInt());
}

test "neg: wraps at minInt and negates floats" {
    const r = try neg(Value.int(std.math.minInt(i64)));
    try expectEqual(std.math.minInt(i64), r.asInt());
    const f = try neg(Value.float(2.5));
    try expectEqual(@as(f64, -2.5), f.asFloat());
}

test "mixed arithmetic promotes to f64" {
    const r = try add(Value.int(1), Value.float(2.0));
    try expect(r.isFloat());
    try expectEqual(@as(f64, 3.0), r.asFloat());
    const s = try sub(Value.float(5.0), Value.int(2));
    try expectEqual(@as(f64, 3.0), s.asFloat());
}

test "div is always float division" {
    const r = try div(Value.int(7), Value.int(2));
    try expect(r.isFloat());
    try expectEqual(@as(f64, 3.5), r.asFloat());
    // division by zero is IEEE inf, not an error.
    const inf = try div(Value.int(1), Value.int(0));
    try expect(std.math.isInf(inf.asFloat()));
}

test "floorDiv: integer floor semantics and sign" {
    try expectEqual(@as(i64, 3), (try floorDiv(Value.int(7), Value.int(2))).asInt());
    // floored, not truncated: -7 // 2 == -4
    try expectEqual(@as(i64, -4), (try floorDiv(Value.int(-7), Value.int(2))).asInt());
    try expectEqual(@as(i64, -4), (try floorDiv(Value.int(7), Value.int(-2))).asInt());
    // mixed yields a float floor
    const m = try floorDiv(Value.int(7), Value.float(2.0));
    try expect(m.isFloat());
    try expectEqual(@as(f64, 3.0), m.asFloat());
}

test "floorDiv: integer zero divisor errors; minInt//-1 wraps" {
    try expectError(Error.DivisionByZero, floorDiv(Value.int(1), Value.int(0)));
    const w = try floorDiv(Value.int(std.math.minInt(i64)), Value.int(-1));
    try expectEqual(std.math.minInt(i64), w.asInt());
}

test "mod: floored modulo takes divisor sign" {
    try expectEqual(@as(i64, 1), (try mod(Value.int(7), Value.int(3))).asInt());
    // sign follows divisor: -7 % 3 == 2, 7 % -3 == -2
    try expectEqual(@as(i64, 2), (try mod(Value.int(-7), Value.int(3))).asInt());
    try expectEqual(@as(i64, -2), (try mod(Value.int(7), Value.int(-3))).asInt());
    try expectError(Error.DivisionByZero, mod(Value.int(1), Value.int(0)));
}

test "mod: float modulo follows Lua a - floor(a/b)*b" {
    const r = try mod(Value.float(5.5), Value.float(2.0));
    try expectEqual(@as(f64, 1.5), r.asFloat());
}

test "pow is always float exponentiation" {
    const r = try pow(Value.int(2), Value.int(10));
    try expect(r.isFloat());
    try expectEqual(@as(f64, 1024.0), r.asFloat());
    const h = try pow(Value.int(2), Value.float(-1.0));
    try expectEqual(@as(f64, 0.5), h.asFloat());
}

test "bitwise and/or/xor/not on integers" {
    try expectEqual(@as(i64, 0b1000), (try band(Value.int(0b1100), Value.int(0b1010))).asInt());
    try expectEqual(@as(i64, 0b1110), (try bor(Value.int(0b1100), Value.int(0b1010))).asInt());
    try expectEqual(@as(i64, 0b0110), (try bxor(Value.int(0b1100), Value.int(0b1010))).asInt());
    try expectEqual(@as(i64, -1), (try bnot(Value.int(0))).asInt());
    try expectError(Error.TypeError, band(Value.int(1), Value.float(2.0)));
    try expectError(Error.TypeError, bnot(Value.float(1.0)));
}

test "shifts are logical and Lua-style (negative count, overshift to zero)" {
    try expectEqual(@as(i64, 0b100000), (try shl(Value.int(0b1), Value.int(5))).asInt());
    // negative count on shl shifts right
    try expectEqual(@as(i64, 0b1), (try shl(Value.int(0b100000), Value.int(-5))).asInt());
    // logical right shift fills with zero (not arithmetic): -1 >> 63 == 1
    try expectEqual(@as(i64, 1), (try shr(Value.int(-1), Value.int(63))).asInt());
    // overshift in either direction yields 0
    try expectEqual(@as(i64, 0), (try shl(Value.int(-1), Value.int(64))).asInt());
    try expectEqual(@as(i64, 0), (try shr(Value.int(-1), Value.int(100))).asInt());
    // a minInt shift count must not overflow when shifting the other way
    try expectEqual(@as(i64, 0), (try shr(Value.int(1), Value.int(std.math.minInt(i64)))).asInt());
}

test "type errors on non-numbers" {
    try expectError(Error.TypeError, add(Value.nil(), Value.int(1)));
    try expectError(Error.TypeError, lt(Value.boolean(true), Value.int(1)));
    try expectError(Error.TypeError, neg(Value.nil()));
}

test "comparisons: cross-type and NaN" {
    try expect(try lt(Value.int(1), Value.float(1.5)));
    try expect(try le(Value.int(2), Value.float(2.0)));
    try expect(!try lt(Value.float(2.0), Value.int(2)));
    // NaN makes every ordering false
    try expect(!try lt(Value.float(std.math.nan(f64)), Value.int(0)));
    try expect(!try le(Value.float(std.math.nan(f64)), Value.int(0)));
}

test "comparisons: large integers beyond f64 precision are exact" {
    const big: i64 = (1 << 53) + 1; // not exactly representable as f64
    const two53: f64 = @floatFromInt(@as(i64, 1) << 53);
    // big > 2^53 even though both round to the same f64 under naive conversion
    try expect(try lt(Value.float(two53), Value.int(big)));
    try expect(!eq(Value.int(big), Value.float(two53)));
}
