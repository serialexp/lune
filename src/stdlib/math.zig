//! lune stdlib — the `math` library.
//!
//! Pure, deterministic numeric functions (tier `core` in
//! `docs/lua-stdlib-inventory.csv`). Every native here is a *pure host call*:
//! it reads its argument `Value`s and returns a `Value`, touching neither the
//! VM, the heap, nor any host effect — so `ctx` is ignored and this module
//! imports only `value` and `function`, never `interp`. That keeps the library
//! code out of the interpreter core: `interp.base_natives` simply concatenates
//! `math.natives` (and `math.constants`) at comptime.
//!
//! Number semantics follow Lua 5.4's integer/float subtype model (which lune's
//! `Value` already mirrors — `int` and `float` are distinct tags, not a float
//! subtype): `abs`/`max`/`min`/`fmod` preserve the subtype of their result,
//! `floor`/`ceil` yield integers, and the transcendental functions always yield
//! floats.
//!
//! `math.modf` returns *two* values via the native multi-return ABI
//! (`function.NativeMultiFn`): its primary projection is the integral part, and
//! the multi path additionally yields the fractional part.
//!
//! Deferred (need calling-convention or heap support not yet available):
//!   - `math.type`            — returns a *string* ("integer"/"float"/nil), which
//!                              needs heap interning (a `*Vm`).
//!   - `math.frexp`           — returns *two* values (mantissa, exponent); lands
//!                              with the rest of the C99 float helpers.
//!
//! `math.random`/`math.randomseed` are **not** here: they touch VM state (the
//! PRNG and the `.random_seed` effect log), so they live in `interp.zig` as
//! Vm-touching natives (`nativeRandom`/`nativeRandomseed`) but are installed into
//! this `math` table via their registry `.module`/`.field`. lune uses a single
//! `u64` seed (`std.Random.Xoshiro256`), so the draw is Lua-shaped but not
//! PUC-stream-compatible.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");

const Value = value.Value;

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

/// Fetch argument `i` as a number `Value`, or `TypeError` if missing/non-number.
/// Mirrors Lua's "bad argument" arity/type checks (lune surfaces them as a single
/// `TypeError`; `interp.narrowError` maps `error.TypeError` straight across).
fn numArg(args: []const Value, i: usize) error{TypeError}!Value {
    if (i >= args.len or !args[i].isNumber()) return error.TypeError;
    return args[i];
}

/// Convert a finite, in-range float to an integer `Value`; `TypeError` if the
/// value has no exact `i64` representation (Lua: "number has no integer
/// representation"). `2^63` is the first magnitude that overflows `i64`.
fn floatToIntValue(f: f64) error{TypeError}!Value {
    const two_pow_63 = 9223372036854775808.0; // 2^63, exact in f64
    if (!std.math.isFinite(f) or f >= two_pow_63 or f < -two_pow_63) return error.TypeError;
    return Value.int(@intFromFloat(f));
}

// ---------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------

/// `math.abs(x)` — absolute value, preserving subtype. Integer `abs(mininteger)`
/// wraps to `mininteger` (Lua uses wrapping integer negation).
fn mAbs(_: *anyopaque, args: []const Value) anyerror!Value {
    const x = try numArg(args, 0);
    if (x.isInt()) {
        const i = x.asInt();
        return Value.int(if (i < 0) 0 -% i else i);
    }
    return Value.float(@abs(x.asFloat()));
}

/// `math.ceil(x)` — smallest integer >= x, returned as an integer.
fn mCeil(_: *anyopaque, args: []const Value) anyerror!Value {
    const x = try numArg(args, 0);
    if (x.isInt()) return x;
    return floatToIntValue(@ceil(x.asFloat()));
}

/// `math.floor(x)` — largest integer <= x, returned as an integer.
fn mFloor(_: *anyopaque, args: []const Value) anyerror!Value {
    const x = try numArg(args, 0);
    if (x.isInt()) return x;
    return floatToIntValue(@floor(x.asFloat()));
}

/// `math.sqrt(x)` — square root (always float).
fn mSqrt(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(@sqrt((try numArg(args, 0)).toFloat()));
}

/// `math.exp(x)` — e^x (always float).
fn mExp(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(@exp((try numArg(args, 0)).toFloat()));
}

/// `math.log(x [, base])` — logarithm of x in `base` (default natural log).
/// Bases 2 and 10 use the dedicated builtins for accuracy (matching Lua).
fn mLog(_: *anyopaque, args: []const Value) anyerror!Value {
    const x = (try numArg(args, 0)).toFloat();
    if (args.len >= 2 and args[1].isNumber()) {
        const base = args[1].toFloat();
        if (base == 2.0) return Value.float(@log2(x));
        if (base == 10.0) return Value.float(@log10(x));
        return Value.float(@log(x) / @log(base));
    }
    return Value.float(@log(x));
}

/// `math.sin(x)` — sine of x in radians (always float).
fn mSin(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(@sin((try numArg(args, 0)).toFloat()));
}

/// `math.cos(x)` — cosine of x in radians (always float).
fn mCos(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(@cos((try numArg(args, 0)).toFloat()));
}

/// `math.tan(x)` — tangent of x in radians (always float).
fn mTan(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(std.math.tan((try numArg(args, 0)).toFloat()));
}

/// `math.asin(x)` — arc sine, in radians (always float).
fn mAsin(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(std.math.asin((try numArg(args, 0)).toFloat()));
}

/// `math.acos(x)` — arc cosine, in radians (always float).
fn mAcos(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(std.math.acos((try numArg(args, 0)).toFloat()));
}

/// `math.atan(y [, x])` — atan(y/x) in radians, using both signs to pick the
/// quadrant. `x` defaults to 1, so `atan(y)` is the ordinary arctangent.
fn mAtan(_: *anyopaque, args: []const Value) anyerror!Value {
    const y = (try numArg(args, 0)).toFloat();
    const x: f64 = if (args.len >= 2 and args[1].isNumber()) args[1].toFloat() else 1.0;
    return Value.float(std.math.atan2(y, x));
}

/// `math.deg(x)` — convert radians to degrees (always float).
fn mDeg(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float((try numArg(args, 0)).toFloat() * (180.0 / std.math.pi));
}

/// `math.rad(x)` — convert degrees to radians (always float).
fn mRad(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float((try numArg(args, 0)).toFloat() * (std.math.pi / 180.0));
}

/// `math.fmod(x, y)` — remainder of x/y with the quotient truncated toward zero
/// (C `fmod`). Two integers yield an integer remainder (and error on a zero
/// divisor, like Lua); otherwise the computation is in floats.
fn mFmod(_: *anyopaque, args: []const Value) anyerror!Value {
    const x = try numArg(args, 0);
    const y = try numArg(args, 1);
    if (x.isInt() and y.isInt()) {
        const yi = y.asInt();
        if (yi == 0) return error.DivisionByZero;
        if (yi == -1) return Value.int(0); // avoid @rem(minInt, -1) overflow; result is 0
        return Value.int(@rem(x.asInt(), yi));
    }
    return Value.float(@rem(x.toFloat(), y.toFloat()));
}

/// `math.max(x, ...)` — the largest argument, preserving its subtype (the actual
/// `Value` is returned). Needs at least one argument.
fn mMax(_: *anyopaque, args: []const Value) anyerror!Value {
    var best = try numArg(args, 0);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const v = try numArg(args, i);
        if (v.toFloat() > best.toFloat()) best = v;
    }
    return best;
}

/// `math.min(x, ...)` — the smallest argument, preserving its subtype. Needs at
/// least one argument.
fn mMin(_: *anyopaque, args: []const Value) anyerror!Value {
    var best = try numArg(args, 0);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const v = try numArg(args, i);
        if (v.toFloat() < best.toFloat()) best = v;
    }
    return best;
}

/// `math.tointeger(x)` — x as an integer if it has an exact integer value, else
/// `nil`. Unlike most of `math`, a non-number argument is *not* an error: it
/// simply fails (returns nil), matching Lua.
fn mToInteger(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.nil();
    const x = args[0];
    if (x.isInt()) return x;
    if (x.isFloat()) {
        const f = x.asFloat();
        if (std.math.isFinite(f) and f == @trunc(f)) {
            return floatToIntValue(f) catch return Value.nil();
        }
    }
    return Value.nil();
}

/// `math.ult(m, n)` — whether m < n when both integers are read as *unsigned*.
/// Both arguments must be integers (Lua errors otherwise).
fn mUlt(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or !args[0].isInt() or !args[1].isInt()) return error.TypeError;
    const a: u64 = @bitCast(args[0].asInt());
    const b: u64 = @bitCast(args[1].asInt());
    return Value.boolean(a < b);
}

/// The integral and fractional parts of `x`, both as floats (Lua 5.4's
/// `math.modf` always yields floats). The integral part truncates toward zero
/// (C `modf`); the fractional part keeps `x`'s sign. `±inf` has no fractional
/// part (→ `0.0`), matching C `modf`; a `NaN` propagates to both parts.
fn modfParts(x: f64) struct { ip: f64, fp: f64 } {
    const ip = @trunc(x);
    return .{ .ip = ip, .fp = if (std.math.isInf(x)) 0.0 else x - ip };
}

/// `math.modf(x)` — primary projection (the **integral** part) for single-result
/// contexts (`local i = math.modf(x)`). The fractional part is delivered by the
/// multi-return path `mModfN`.
fn mModf1(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value.float(modfParts((try numArg(args, 0)).toFloat()).ip);
}

/// `math.modf(x)` — multi-return: `out[0]` = integral part, `out[1]` = fractional
/// part. Reads `args[0]` **before** writing `out` (the VM aliases `out` over the
/// callee/argument registers — see `function.NativeMultiFn`). Writes only as many
/// results as the caller wants (`out.len`) and returns that count; the VM
/// nil-pads any further requested slots.
fn mModfN(_: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const x = (try numArg(args, 0)).toFloat(); // read all args first (alias contract)
    const parts = modfParts(x);
    if (out.len >= 1) out[0] = Value.float(parts.ip);
    if (out.len >= 2) out[1] = Value.float(parts.fp);
    return @min(@as(usize, 2), out.len);
}

// ---------------------------------------------------------------------------
// Registry — the slices `interp.base_natives` / `base_constants` concatenate.
// ---------------------------------------------------------------------------

/// The `math.*` functions, as registry descriptors. `interp.base_natives`
/// appends this slice; install and keyframe-restore both read it by qualified
/// `name`, so the names here are the serialized identities and must stay unique.
pub const natives = [_]function.BaseNative{
    .{ .name = "math.abs", .func = &mAbs, .module = "math", .field = "abs" },
    .{ .name = "math.ceil", .func = &mCeil, .module = "math", .field = "ceil" },
    .{ .name = "math.floor", .func = &mFloor, .module = "math", .field = "floor" },
    .{ .name = "math.sqrt", .func = &mSqrt, .module = "math", .field = "sqrt", .pure = .sqrt },
    .{ .name = "math.exp", .func = &mExp, .module = "math", .field = "exp" },
    .{ .name = "math.log", .func = &mLog, .module = "math", .field = "log" },
    .{ .name = "math.sin", .func = &mSin, .module = "math", .field = "sin" },
    .{ .name = "math.cos", .func = &mCos, .module = "math", .field = "cos" },
    .{ .name = "math.tan", .func = &mTan, .module = "math", .field = "tan" },
    .{ .name = "math.asin", .func = &mAsin, .module = "math", .field = "asin" },
    .{ .name = "math.acos", .func = &mAcos, .module = "math", .field = "acos" },
    .{ .name = "math.atan", .func = &mAtan, .module = "math", .field = "atan" },
    .{ .name = "math.deg", .func = &mDeg, .module = "math", .field = "deg" },
    .{ .name = "math.rad", .func = &mRad, .module = "math", .field = "rad" },
    .{ .name = "math.fmod", .func = &mFmod, .module = "math", .field = "fmod" },
    .{ .name = "math.modf", .func = &mModf1, .multi = &mModfN, .module = "math", .field = "modf" },
    .{ .name = "math.max", .func = &mMax, .module = "math", .field = "max" },
    .{ .name = "math.min", .func = &mMin, .module = "math", .field = "min" },
    .{ .name = "math.tointeger", .func = &mToInteger, .module = "math", .field = "tointeger" },
    .{ .name = "math.ult", .func = &mUlt, .module = "math", .field = "ult" },
};

/// The `math.*` numeric constants. Non-heap `Value`s, installed as fields of the
/// `math` table by `interp.Vm.installBaseLib`.
pub const constants = [_]function.ModuleConst{
    .{ .module = "math", .field = "pi", .value = Value.float(std.math.pi) },
    .{ .module = "math", .field = "huge", .value = Value.float(std.math.inf(f64)) },
    .{ .module = "math", .field = "maxinteger", .value = Value.int(std.math.maxInt(i64)) },
    .{ .module = "math", .field = "mininteger", .value = Value.int(std.math.minInt(i64)) },
};

// ---------------------------------------------------------------------------
// Tests — pin the numeric semantics (Rule Z-3 / Preference #3).
// ---------------------------------------------------------------------------

const testing = std.testing;
const noctx: *anyopaque = undefined;

fn callOk(f: function.NativeFn, args: []const Value) Value {
    return f(noctx, args) catch unreachable;
}

test "abs preserves subtype and wraps mininteger" {
    try testing.expect(callOk(&mAbs, &.{Value.int(-5)}).asInt() == 5);
    try testing.expect(callOk(&mAbs, &.{Value.int(7)}).asInt() == 7);
    try testing.expect(callOk(&mAbs, &.{Value.float(-2.5)}).asFloat() == 2.5);
    // abs(mininteger) wraps back to mininteger.
    try testing.expect(callOk(&mAbs, &.{Value.int(std.math.minInt(i64))}).asInt() == std.math.minInt(i64));
}

test "floor/ceil return integers" {
    try testing.expect(callOk(&mFloor, &.{Value.float(2.7)}).isInt());
    try testing.expect(callOk(&mFloor, &.{Value.float(2.7)}).asInt() == 2);
    try testing.expect(callOk(&mFloor, &.{Value.float(-2.1)}).asInt() == -3);
    try testing.expect(callOk(&mCeil, &.{Value.float(2.1)}).asInt() == 3);
    try testing.expect(callOk(&mCeil, &.{Value.float(-2.9)}).asInt() == -2);
    // Integer passes through unchanged.
    try testing.expect(callOk(&mFloor, &.{Value.int(9)}).asInt() == 9);
}

test "floor of a huge float has no integer representation" {
    try testing.expectError(error.TypeError, mFloor(noctx, &.{Value.float(1e300)}));
}

test "transcendental functions yield floats" {
    try testing.expectApproxEqAbs(@as(f64, 2.0), callOk(&mSqrt, &.{Value.int(4)}).asFloat(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), callOk(&mExp, &.{Value.float(0.0)}).asFloat(), 1e-12);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, callOk(&mAsin, &.{Value.float(1.0)}).asFloat(), 1e-12);
    try testing.expectApproxEqAbs(std.math.pi / 4.0, callOk(&mAtan, &.{Value.float(1.0)}).asFloat(), 1e-12);
    // atan(y, x) honours the second argument's quadrant.
    try testing.expectApproxEqAbs(3.0 * std.math.pi / 4.0, callOk(&mAtan, &.{ Value.float(1.0), Value.float(-1.0) }).asFloat(), 1e-12);
}

test "log default base is e; explicit bases 2 and 10" {
    try testing.expectApproxEqAbs(@as(f64, 1.0), callOk(&mLog, &.{Value.float(std.math.e)}).asFloat(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3.0), callOk(&mLog, &.{ Value.int(8), Value.int(2) }).asFloat(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.0), callOk(&mLog, &.{ Value.int(100), Value.int(10) }).asFloat(), 1e-12);
}

test "deg/rad round-trip" {
    try testing.expectApproxEqAbs(@as(f64, 180.0), callOk(&mDeg, &.{Value.float(std.math.pi)}).asFloat(), 1e-12);
    try testing.expectApproxEqAbs(std.math.pi, callOk(&mRad, &.{Value.float(180.0)}).asFloat(), 1e-12);
}

test "fmod: integer and float paths, zero divisor errors" {
    try testing.expect(callOk(&mFmod, &.{ Value.int(7), Value.int(3) }).asInt() == 1);
    try testing.expect(callOk(&mFmod, &.{ Value.int(-7), Value.int(3) }).asInt() == -1); // truncated toward zero
    try testing.expectApproxEqAbs(@as(f64, 0.5), callOk(&mFmod, &.{ Value.float(5.5), Value.float(1.0) }).asFloat(), 1e-12);
    try testing.expect(callOk(&mFmod, &.{ Value.int(std.math.minInt(i64)), Value.int(-1) }).asInt() == 0);
    try testing.expectError(error.DivisionByZero, mFmod(noctx, &.{ Value.int(5), Value.int(0) }));
}

test "modf primary projection is the integral part (float)" {
    const ip = callOk(&mModf1, &.{Value.float(3.5)});
    try testing.expect(ip.isFloat() and ip.asFloat() == 3.0);
    const neg = callOk(&mModf1, &.{Value.float(-3.5)});
    try testing.expect(neg.asFloat() == -3.0); // truncates toward zero
    // Integer argument: integral part is that value, as a float.
    try testing.expect(callOk(&mModf1, &.{Value.int(7)}).asFloat() == 7.0);
}

test "modf multi-return writes integral and fractional parts" {
    var out: [2]Value = .{ Value.nil(), Value.nil() };
    const n = mModfN(noctx, &.{Value.float(3.5)}, &out) catch unreachable;
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(out[0].asFloat() == 3.0);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[1].asFloat(), 1e-15);
    // Negative: fractional part keeps the sign.
    _ = mModfN(noctx, &.{Value.float(-3.25)}, &out) catch unreachable;
    try testing.expect(out[0].asFloat() == -3.0);
    try testing.expectApproxEqAbs(@as(f64, -0.25), out[1].asFloat(), 1e-15);
    // ±inf has no fractional part.
    _ = mModfN(noctx, &.{Value.float(std.math.inf(f64))}, &out) catch unreachable;
    try testing.expect(std.math.isInf(out[0].asFloat()) and out[1].asFloat() == 0.0);
}

test "modf multi-return clamps to out.len and returns the written count" {
    var one: [1]Value = .{Value.nil()};
    const n = mModfN(noctx, &.{Value.float(9.75)}, &one) catch unreachable;
    try testing.expectEqual(@as(usize, 1), n); // only the integral part fit
    try testing.expect(one[0].asFloat() == 9.0);
    var none: [0]Value = .{};
    try testing.expectEqual(@as(usize, 0), mModfN(noctx, &.{Value.float(9.75)}, &none) catch unreachable);
}

test "max/min preserve the selected argument's subtype" {
    const mx = callOk(&mMax, &.{ Value.int(3), Value.float(3.5), Value.int(2) });
    try testing.expect(mx.isFloat() and mx.asFloat() == 3.5);
    const mn = callOk(&mMin, &.{ Value.int(3), Value.float(3.5), Value.int(-2) });
    try testing.expect(mn.isInt() and mn.asInt() == -2);
    try testing.expect(callOk(&mMax, &.{Value.int(42)}).asInt() == 42); // single arg
}

test "tointeger: exact floats convert; others fail to nil" {
    try testing.expect(callOk(&mToInteger, &.{Value.float(5.0)}).asInt() == 5);
    try testing.expect(callOk(&mToInteger, &.{Value.int(5)}).asInt() == 5);
    try testing.expect(callOk(&mToInteger, &.{Value.float(5.5)}).isNil());
    try testing.expect(callOk(&mToInteger, &.{Value.boolean(true)}).isNil()); // non-number ⇒ nil, not error
}

test "ult compares as unsigned" {
    // -1 as unsigned is the largest u64, so ult(-1, 1) is false; ult(1, -1) is true.
    try testing.expect(callOk(&mUlt, &.{ Value.int(1), Value.int(-1) }).asBool());
    try testing.expect(!callOk(&mUlt, &.{ Value.int(-1), Value.int(1) }).asBool());
    try testing.expectError(error.TypeError, mUlt(noctx, &.{ Value.float(1.0), Value.int(2) }));
}

test "non-number argument is a TypeError" {
    try testing.expectError(error.TypeError, mSqrt(noctx, &.{Value.nil()}));
    try testing.expectError(error.TypeError, mAbs(noctx, &.{})); // missing arg
}

test "constants carry the expected values" {
    try testing.expectEqual(std.math.maxInt(i64), constants[2].value.asInt());
    try testing.expectEqual(std.math.minInt(i64), constants[3].value.asInt());
    try testing.expect(std.math.isInf(constants[1].value.asFloat()));
    try testing.expectApproxEqAbs(std.math.pi, constants[0].value.asFloat(), 1e-15);
}
