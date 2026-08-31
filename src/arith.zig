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
//! **Floating-point determinism (docs/design/02-determinism.md §FP).** Every
//! function that does float math pins `@setFloatMode(.strict)`. Zig's default is
//! already strict (it does *not* enable fast-math under `ReleaseFast`), so this
//! is a deliberate, self-documenting guard: it forbids contraction/reassociation
//! (e.g. FMA) regardless of build mode, keeping results bit-stable so a trace,
//! the IR-interpreter, and a future replay all compute byte-identical floats.
//! Cross-platform bit-identity is a separate, still-open question (doc 02);
//! this only pins same-target determinism.
//!
//! These functions operate on dynamically-typed `Value`s and return
//! `error.TypeError` for operands the operator doesn't accept. Arithmetic is
//! numbers-only; the ordering comparisons (`lt`/`le`) additionally accept two
//! strings (lexicographic byte order, deterministic and locale-free) and reject a
//! mixed string/number pair, as Lua does. They are pure — no allocation, no VM
//! state — which is why their shape is pinned with tests now.

const std = @import("std");
const fmath = @import("fmath.zig");
const value = @import("value.zig");
const string = @import("string.zig");
const Value = value.Value;

/// The UTF-8 byte slice of a string `Value`, or `null` if it isn't a string.
/// Used only by the ordering comparisons (`lt`/`le`) — strings order
/// lexicographically by byte, which is deterministic and locale-free. The
/// trace recorder aborts a compare whose operands aren't numbers (`recCompare`
/// in `trace.zig`), so string ordering only ever runs on tier-0/1a, never inside
/// native trace code.
inline fn strBytes(v: Value) ?[]const u8 {
    if (v.isHeap() and v.heapType() == .string) return string.String.fromHeader(v.asHeap()).bytes();
    return null;
}

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
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    if (bothInt(a, b)) return Value.int(a.asInt() +% b.asInt());
    return Value.float(a.toFloat() + b.toFloat());
}

/// `a - b`. Integer subtract wraps.
pub fn sub(a: Value, b: Value) Error!Value {
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    if (bothInt(a, b)) return Value.int(a.asInt() -% b.asInt());
    return Value.float(a.toFloat() - b.toFloat());
}

/// `a * b`. Integer multiply wraps.
pub fn mul(a: Value, b: Value) Error!Value {
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    if (bothInt(a, b)) return Value.int(a.asInt() *% b.asInt());
    return Value.float(a.toFloat() * b.toFloat());
}

/// `-a`. Integer negate wraps (`-minInt == minInt`).
pub fn neg(a: Value) Error!Value {
    @setFloatMode(.strict);
    return switch (a.tag) {
        .int => Value.int(0 -% a.asInt()),
        .float => Value.float(-a.asFloat()),
        else => Error.TypeError,
    };
}

/// `a / b` — **always float division**. `int / int` yields `f64`; division by
/// zero follows IEEE (`±inf` / `nan`), it does not error.
pub fn div(a: Value, b: Value) Error!Value {
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    return Value.float(a.toFloat() / b.toFloat());
}

/// `a // b` — floor division. Integer result when both are integers (errors on
/// a zero divisor); otherwise `floor(a/b)` as a float.
pub fn floorDiv(a: Value, b: Value) Error!Value {
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    if (bothInt(a, b)) {
        const x = a.asInt();
        const y = b.asInt();
        if (y == 0) return Error.DivisionByZero;
        // Only overflowing case is minInt // -1 == 2^63, which wraps to minInt.
        if (x == std.math.minInt(i64) and y == -1) return Value.int(x);
        return Value.int(@divFloor(x, y));
    }
    // Through the ONE noinline kernel so tier-0, tier-1a, and the native
    // JIT's float callout are bit-identical by construction (doc 25 D2).
    return Value.float(fmath.floordivRuntime(a.toFloat(), b.toFloat()));
}

/// `a % b` — floored modulo (result takes the sign of `b`), Lua-style. Integer
/// modulo by zero errors; float modulo by zero yields `nan` (no error).
pub fn mod(a: Value, b: Value) Error!Value {
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    if (bothInt(a, b)) {
        const y = b.asInt();
        if (y == 0) return Error.DivisionByZero;
        // `x % -1 == 0` for EVERY x under floored modulo — and the previous
        // `@mod` claim ("minInt % -1 == 0, no overflow") was FALSE: @mod
        // lowers to hardware idiv, which #DE-traps on (minInt, -1). Found by
        // the doc-25 native-lowering pair test; `minInt % -1` crashed tier-0
        // with SIGFPE until this special case (Lua 5.4 handles it the same
        // way in luaV_mod).
        if (y == -1) return Value.int(0);
        return Value.int(@mod(a.asInt(), y));
    }
    // Lua float modulo, `a - floor(a/b)*b` — through the ONE noinline kernel
    // so all three tiers share a single compiled body (doc 25 D2).
    return Value.float(fmath.fmodRuntime(a.toFloat(), b.toFloat()));
}

/// `a ^ b` — exponentiation, **always float** (Lua-shaped). `2 ^ 2` is `4.0`.
/// Evaluates through the ONE noinline `fmath.powRuntime` body so tier-0, the
/// tier-1a evaluator/const-folder, and the native JIT's `.pow` callout are
/// bit-identical by construction (doc 23 D4).
pub fn pow(a: Value, b: Value) Error!Value {
    @setFloatMode(.strict);
    try requireNumbers(a, b);
    return Value.float(fmath.powRuntime(a.toFloat(), b.toFloat()));
}

// ---- bitwise ----
//
// Bitwise operators act on the 64-bit two's-complement pattern of integer
// operands. mahina requires **integer** operands and — unlike Lua 5.4 —
// deliberately does NOT coerce a float, even one with an integral value (e.g.
// `3.0 & 1` errors). Keeping the numeric tower strict here avoids an implicit
// float→int convenience; any non-integer operand errors with `TypeError`, which
// the VM renders as "number has no integer representation" (a float) or "attempt
// to perform bitwise operation on a <type> value" (a non-number). Shifts are
// *logical* (zero-filled) and Lua-style: a shift count outside [-63, 63] shifts
// every bit out and yields 0; a negative count shifts the other direction.

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

/// Arithmetic (sign-extending) right shift of `x` by `n` bits. `n < 0` shifts
/// left (logical); a right shift by `|n| >= 64` saturates to the sign fill
/// (`-1` for negative `x`, `0` otherwise) rather than `0`. The positive leg
/// uses Zig's signed `>>`, which is arithmetic. Written directly (not via `-n`)
/// so a `minInt` count cannot overflow the negation.
fn shiftRightArith(x: i64, n: i64) i64 {
    if (n >= 63) return x >> 63; // full sign fill (clamp the count to 63)
    if (n >= 0) return x >> @intCast(n);
    if (n <= -64) return 0;
    const ux: u64 = @bitCast(x);
    return @bitCast(ux << @intCast(-n));
}

/// `a ~>> b` (arithmetic right shift, sign-extending). mahina-only operator
/// (LuaJIT 3.0 syntax); 64-bit width like the rest of mahina's bitwise set.
pub fn sar(a: Value, b: Value) Error!Value {
    try requireInts(a, b);
    return Value.int(shiftRightArith(a.asInt(), b.asInt()));
}

// ---- comparisons ----

/// `a < b`. Numbers compare by value (a `NaN` operand makes this false); two
/// strings compare lexicographically by byte (`std.mem.order`). A mixed
/// string/number pair errors, exactly as Lua does ("attempt to compare").
pub fn lt(a: Value, b: Value) Error!bool {
    if (a.isNumber() and b.isNumber()) return value.compareNumeric(a, b) == .lt;
    if (strBytes(a)) |sa| if (strBytes(b)) |sb| return std.mem.order(u8, sa, sb) == .lt;
    return Error.TypeError;
}

/// `a <= b`. Numbers compare by value (a `NaN` operand makes this false); two
/// strings compare lexicographically by byte. A mixed string/number pair errors.
pub fn le(a: Value, b: Value) Error!bool {
    if (a.isNumber() and b.isNumber()) {
        const o = value.compareNumeric(a, b);
        return o == .lt or o == .eq;
    }
    if (strBytes(a)) |sa| if (strBytes(b)) |sb| return std.mem.order(u8, sa, sb) != .gt;
    return Error.TypeError;
}

/// `a == b`. Never errors: different types are simply unequal. Numbers compare
/// across the int/float boundary by exact value.
pub fn eq(a: Value, b: Value) bool {
    return a.eql(b);
}

/// The `tonumber(v[, base])` conversion core — the ONE implementation shared by
/// the stdlib native (`stdlib/basic.zig` `bToNumber`) and the trace recorder's
/// konst fold (doc 23 D2), so the two can never disagree. Pure and total: any
/// unconvertible input yields `nil`, never an error, and nothing is allocated
/// (results are ints/floats/nil; a string input is only *read*). `base_arg`
/// mirrors the native's argument handling exactly: `null` means the 1-arg form;
/// a non-number base falls through to the 1-arg auto path (matching the
/// native's `args[1].isNumber()` gate); a numeric base outside 2..36 → nil.
/// The whitespace set `tonumber` trims before parsing: C `isspace`, which is
/// what both Lua 5.4 (`l_str2int`/`l_str2d` skip `lisspace`) and LuaJIT
/// (`lj_strscan` skips `LJ_CHAR_SPACE`) use. Verified empirically 2026-08-29:
/// with only " \t\n\r" mahina rejected "\x0B10"/"\x0C10" that both engines
/// accept — the one acceptance gap on the 77-case three-engine probe matrix.
const tonumber_trim = " \t\n\r\x0B\x0C"; // space \t \n \r \v \f

pub fn toNumber(v: Value, base_arg: ?Value) Value {
    // Explicit base form: string interpreted as an integer in that base.
    if (base_arg) |bv| if (bv.isNumber()) {
        const base_i = bv.toFloat();
        if (base_i < 2 or base_i > 36) return Value.nil();
        const base: u8 = @intFromFloat(base_i);
        const s = strBytes(v) orelse return Value.nil();
        const t = std.mem.trim(u8, s, tonumber_trim);
        if (t.len == 0) return Value.nil();
        const parsed = std.fmt.parseInt(i64, t, base) catch return Value.nil();
        return Value.int(parsed);
    };

    switch (v.tag) {
        .int, .float => return v,
        else => {},
    }
    const s = strBytes(v) orelse return Value.nil();
    const t = std.mem.trim(u8, s, tonumber_trim);
    if (t.len == 0) return Value.nil();
    if (fastDecInt(t)) |iv| return Value.int(iv); // doc 29 B(a): the common shape
    if (std.fmt.parseInt(i64, t, 0)) |iv| {
        return Value.int(iv);
    } else |_| {}
    if (std.fmt.parseFloat(f64, t)) |fv| {
        return Value.float(fv);
    } else |_| {}
    return Value.nil();
}

/// Doc 29 B, grammar option (a): the plain-decimal-integer fast path.
///
/// Claims ONLY strings where `std.fmt.parseInt(i64, t, 0)` succeeds with the
/// same value — optional single sign then 1..19 pure ASCII digits in i64
/// range — and returns null for everything else (underscores, prefixes,
/// decimal points, exponents, ≥20 digit runs incl. leading-zero shapes,
/// out-of-range values), which then takes the untouched std.fmt pipeline.
/// Routing and int/float tags are therefore preserved BY CONSTRUCTION (codex
/// review Blocker #1 of doc 29): the fast path is a strict subset of the
/// integer lane, never a re-implementation of its grammar.
fn fastDecInt(t: []const u8) ?i64 {
    var i: usize = 0;
    var negative = false;
    switch (t[0]) { // caller guarantees t.len > 0
        '+' => i = 1,
        '-' => {
            negative = true;
            i = 1;
        },
        else => {},
    }
    if (i >= t.len) return null; // bare sign
    var x: u64 = 0;
    var digits: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c < '0' or c > '9') return null; // any non-digit → slow path
        digits += 1;
        // ≥20 digits could overflow u64 accumulation AND covers the
        // leading-zeros-still-int shapes ("00…01") — let parseInt decide.
        if (digits > 19) return null;
        x = x * 10 + (c - '0');
    }
    const min_mag: u64 = 1 << 63; // |i64 min|
    if (negative) {
        if (x > min_mag) return null; // parseInt overflows → parseFloat lane
        if (x == min_mag) return std.math.minInt(i64);
        return -@as(i64, @intCast(x));
    }
    if (x > std.math.maxInt(i64)) return null;
    return @intCast(x);
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
    // x % -1 == 0 for every x — including minInt, which SIGFPE'd through
    // @mod/idiv before the -1 special case (doc 25 pre-existing-bug find).
    try expectEqual(@as(i64, 0), (try mod(Value.int(7), Value.int(-1))).asInt());
    try expectEqual(@as(i64, 0), (try mod(Value.int(std.math.minInt(i64)), Value.int(-1))).asInt());
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

test "arithmetic right shift (~>>) sign-extends" {
    // positive operand: identical to logical shr
    try expectEqual(@as(i64, 0b1), (try sar(Value.int(0b100000), Value.int(5))).asInt());
    // negative operand fills with the sign bit (1s), unlike logical shr
    try expectEqual(@as(i64, -1), (try sar(Value.int(-1), Value.int(63))).asInt());
    try expectEqual(@as(i64, -1), (try sar(Value.int(-1), Value.int(1))).asInt());
    try expectEqual(@as(i64, -2), (try sar(Value.int(-4), Value.int(1))).asInt());
    // overshift right saturates to the sign fill, not zero
    try expectEqual(@as(i64, -1), (try sar(Value.int(-1), Value.int(100))).asInt());
    try expectEqual(@as(i64, 0), (try sar(Value.int(1), Value.int(64))).asInt());
    try expectEqual(@as(i64, 0), (try sar(Value.int(std.math.maxInt(i64)), Value.int(100))).asInt());
    // negative count shifts left (logical), |n| >= 64 -> 0
    try expectEqual(@as(i64, 0b100000), (try sar(Value.int(0b1), Value.int(-5))).asInt());
    try expectEqual(@as(i64, 0), (try sar(Value.int(-1), Value.int(-64))).asInt());
    // minInt shift count must not overflow the negation
    try expectEqual(@as(i64, 0), (try sar(Value.int(1), Value.int(std.math.minInt(i64)))).asInt());
    // minInt operand: -1 fill saturates
    try expectEqual(@as(i64, -1), (try sar(Value.int(std.math.minInt(i64)), Value.int(63))).asInt());
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

/// Doc 29 B(a): the fast path must be a STRICT SUBSET of the parseInt lane —
/// whenever it claims a (pre-trimmed) string, parseInt(i64, t, 0) succeeds
/// with the identical value. Routing/tag preservation follows: the composed
/// pipeline (fast → parseInt → parseFloat) is then extensionally equal to
/// the old one (parseInt → parseFloat).
fn checkFastSubset(t: []const u8) !void {
    if (t.len == 0) return; // toNumber nil-checks before the fast path
    if (fastDecInt(t)) |got| {
        const want = std.fmt.parseInt(i64, t, 0) catch {
            std.debug.print("fastDecInt claimed \"{s}\" but parseInt rejects it\n", .{t});
            return error.TestUnexpectedResult;
        };
        try expectEqual(want, got);
    }
}

test "doc 29 B(a): fastDecInt is a subset of parseInt — directed families" {
    // Every doc-29 B edge family, incl. the codex Blocker #1 shapes.
    const cases = [_][]const u8{
        "0",                       "1",                    "42",                   "00420",
        "9223372036854775807",     "-9223372036854775808", "9223372036854775808", // +max overflows → must NOT be claimed
        "-9223372036854775809", // < min → parseInt overflow → float lane
        "18446744073709551616", // > u64
        "0000000000000000000001", // 22 digits, leading zeros: int 1 via slow path
        "1_000",                   "1__0",                 "_10_",                 "10_",
        "0x10",                    "0X10",                 "0b101",                "0o17",
        "0x_10",                   "1e5",                  "1.0",                  "1.",
        ".5",                      "-0",                   "+0",                   "-0.0",
        "-0e0",                    "inf",                  "-inf",                 "infinity",
        "nan",                     "+",                    "-",                    "",
        "0x",                      "0b",                   "1e999",                "abc",
        "12a",                     "a12",                  "1 2",                  "٤٢", // non-ASCII digits
    };
    for (cases) |t| try checkFastSubset(t);
    // Claim-coverage pins: the shapes the fast path exists for ARE claimed.
    try expectEqual(@as(?i64, 420), fastDecInt("00420"));
    try expectEqual(@as(?i64, -7), fastDecInt("-7"));
    try expectEqual(@as(?i64, 7), fastDecInt("+7"));
    try expectEqual(@as(?i64, std.math.maxInt(i64)), fastDecInt("9223372036854775807"));
    try expectEqual(@as(?i64, std.math.minInt(i64)), fastDecInt("-9223372036854775808"));
    try expectEqual(@as(?i64, null), fastDecInt("9223372036854775808"));
    try expectEqual(@as(?i64, null), fastDecInt("1_0"));
    try expectEqual(@as(?i64, null), fastDecInt("0x10"));
}

test "doc 29 B(a): fastDecInt subset — pseudo-exhaustive short strings" {
    // Every string of length 1..4 over an adversarial alphabet: signs,
    // digits, separators, prefixes, float markers. 13^4 ≈ 28.6k checks.
    const alpha = "0189+-_.exX bo";
    var buf: [4]u8 = undefined;
    for (alpha) |a| {
        buf[0] = a;
        try checkFastSubset(buf[0..1]);
        for (alpha) |b| {
            buf[1] = b;
            try checkFastSubset(buf[0..2]);
            for (alpha) |c| {
                buf[2] = c;
                try checkFastSubset(buf[0..3]);
                for (alpha) |d| {
                    buf[3] = d;
                    try checkFastSubset(buf[0..4]);
                }
            }
        }
    }
}

test "doc 29 B(a): toNumber end-to-end routing unchanged on the matrix" {
    // The composed pipeline through the public entry: tags and values.
    const h = std.math.inf(f64);
    const Exp = union(enum) { int: i64, float: f64, nil };
    const cases = [_]struct { s: []const u8, want: Exp }{
        .{ .s = "42", .want = .{ .int = 42 } },
        .{ .s = " 42 ", .want = .{ .int = 42 } }, // trim (via caller) — tested below raw
        // C-isspace trim parity with Lua 5.4 + LuaJIT (2026-08-29 probe):
        // \v and \f trim like space/tab; both engines accept all four shapes.
        .{ .s = "\x0B10", .want = .{ .int = 10 } },
        .{ .s = "\x0C10", .want = .{ .int = 10 } },
        .{ .s = "10\x0B", .want = .{ .int = 10 } },
        .{ .s = " \x0B\x0C 10 \x0C\x0B ", .want = .{ .int = 10 } },
        .{ .s = "00420", .want = .{ .int = 420 } },
        .{ .s = "1_000", .want = .{ .int = 1000 } }, // std.fmt artifact, grammar (a) freezes it
        .{ .s = "0o17", .want = .{ .int = 15 } },
        .{ .s = "0b101", .want = .{ .int = 5 } },
        .{ .s = "0x10", .want = .{ .int = 16 } },
        .{ .s = "1e5", .want = .{ .float = 1e5 } },
        .{ .s = "1.0", .want = .{ .float = 1.0 } },
        .{ .s = "-0", .want = .{ .int = 0 } },
        .{ .s = "-0.0", .want = .{ .float = -0.0 } },
        .{ .s = "9223372036854775808", .want = .{ .float = 9223372036854775808.0 } },
        .{ .s = "0000000000000000000001", .want = .{ .int = 1 } },
        .{ .s = "inf", .want = .{ .float = h } },
        .{ .s = "1e999", .want = .{ .float = h } },
        .{ .s = "zz", .want = .nil },
        .{ .s = "", .want = .nil },
    };
    for (cases) |tc| {
        // Reproduce toNumber's string arm on raw bytes (strBytes needs a heap
        // Value; the arm's logic below the strBytes call is what we pin).
        const t = std.mem.trim(u8, tc.s, tonumber_trim);
        const got: Exp = blk: {
            if (t.len == 0) break :blk .nil;
            if (fastDecInt(t)) |iv| break :blk .{ .int = iv };
            if (std.fmt.parseInt(i64, t, 0)) |iv| break :blk .{ .int = iv } else |_| {}
            if (std.fmt.parseFloat(f64, t)) |fv| break :blk .{ .float = fv } else |_| {}
            break :blk .nil;
        };
        switch (tc.want) {
            .int => |w| try expectEqual(w, got.int),
            .nil => try expect(got == .nil),
            .float => |w| {
                try expect(got == .float);
                // bit-exact incl. -0.0
                try expectEqual(@as(u64, @bitCast(w)), @as(u64, @bitCast(got.float)));
            },
        }
    }
}
