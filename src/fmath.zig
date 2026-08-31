//! Shared transcendental float kernels (doc 23 D4).
//!
//! ONE `noinline` routine per function, used by EVERY tier — tier-0's math
//! builtins (`stdlib/math.zig`), the tier-1a IR arms (`irinterp.zig`), and the
//! native body callout (`nativegen.zig` calls through the same function
//! pointer). Cross-tier bit-identity then holds **by construction**: there is
//! exactly one compiled body of `sin`, so no two inlinings of `@sin` can be
//! lowered differently (vectorized here, libm-called there) and silently
//! disagree in the last ulp. `callconv(.c)` because the native JIT calls it
//! through a raw pointer with SysV argument passing (xmm0 in, xmm0 out).
//!
//! Determinism note (doc 02): these are pure functions of their argument — no
//! errno, no global rounding-mode dependence beyond the default MXCSR mahina
//! never changes — so replay and 8-mode equivalence are safe by the same
//! argument as `fsqrt`'s.

const std = @import("std");

/// `^` / `math.pow` kernel — the single body all tiers execute (tier-0 and
/// the tier-1a fold/eval reach it through `arith.pow`; the native JIT calls
/// it directly as a two-arg body callout). `std.math.pow` is a pure software
/// implementation — deterministic, no libm — and `@setFloatMode(.strict)`
/// matches `arith.zig`'s pin.
pub noinline fn powRuntime(x: f64, y: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    return std.math.pow(f64, x, y);
}

/// Float `%` kernel (doc 25 D2) — Lua's floored float modulo,
/// `x - floor(x/y) * y`, the single body all tiers execute (tier-0 and
/// tier-1a reach it through `arith.mod`'s float path; the native JIT calls it
/// directly as a two-arg body callout). Total: `y == 0` yields NaN through
/// IEEE — no error, no side-exit.
pub noinline fn fmodRuntime(x: f64, y: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    return x - @floor(x / y) * y;
}

/// Float `//` kernel (doc 25 D2) — `floor(x / y)`, the single body all tiers
/// execute (through `arith.floorDiv`'s float path / the native callout).
/// Total: IEEE inf/NaN fall out identically everywhere.
pub noinline fn floordivRuntime(x: f64, y: f64) callconv(.c) f64 {
    @setFloatMode(.strict);
    return @floor(x / y);
}

/// `math.sin` kernel — the single body all tiers execute.
pub noinline fn sinRuntime(x: f64) callconv(.c) f64 {
    return @sin(x);
}

/// `math.cos` kernel — the single body all tiers execute.
pub noinline fn cosRuntime(x: f64) callconv(.c) f64 {
    return @cos(x);
}
