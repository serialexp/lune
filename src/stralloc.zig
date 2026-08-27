//! Shared allocating string-producer bodies (doc 24 D5 — arc B).
//!
//! ONE `noinline` routine per `.alloc` IR op, used by every JIT tier: the
//! tier-1a IR arms (`irinterp.zig`) call them as Zig functions, and the native
//! body callouts (`nativegen.zig`) call the SAME routines through raw pointers
//! with SysV argument passing. Tier-0's `bToString` (`stdlib/basic.zig`) is the
//! composition of the same two primitives these bodies compose — `io.writeValue`
//! (the one renderer) followed by `Heap.intern` (the one interning path) — so
//! the produced bytes and the interned object are identical across tiers by
//! construction.
//!
//! **Callout audit rule (doc 24 D5):** every routine here performs **at most
//! one `Heap.link`** per call — an intern *hit* performs zero (`Heap.intern`
//! returns the existing object before any allocation), a *miss* exactly one.
//! The allocation bound `A` a trace's `guard_gc` carries counts one per
//! `.alloc` op on that contract; a helper that could link more than once must
//! be split (or its op must carry its own bound) before it lands here.
//!
//! **Error protocol (doc 24 D5):** the C-ABI result is a nullable `*GcHeader` —
//! non-null on success, null on OOM. No `link` ever precedes a fallible step:
//! `Heap.intern`'s miss path is transactional (string allocation and table
//! growth both happen BEFORE any heap mutation — see gc.zig), and the render
//! into the fixed stack buffer cannot fail for scalars. So a null return
//! guarantees a clean id stream, the trace side-exits at the loop header, and
//! tier-0's replay re-raises the same OOM at the same logical point.
//!
//! Determinism note (doc 02/24): rendering is pure text production and
//! interning is a pure function of (strtab contents, bytes) — allocation
//! *count* is the only observable, and the D2 id-stream lemma covers it.

const std = @import("std");
const gc = @import("gc.zig");
const object = @import("object.zig");
const io = @import("io.zig");
const value = @import("value.zig");

const Value = value.Value;

/// Render a scalar exactly as tier-0's `bToString` does (the shared
/// `io.writeValue` renderer, bounded stack buffer) and intern the bytes.
/// Returns null on OOM — no `link` was performed (see the module doc).
inline fn tostrScalar(heap: *gc.Heap, v: Value) ?*object.GcHeader {
    // Non-string renderings are bounded: scalars are <~32 bytes. Same bound
    // as `bToString`'s buffer.
    var buf: [128]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    io.writeValue(&w, v) catch unreachable; // fixed buffer is large enough
    const s = heap.intern(w.buffered()) catch return null;
    return &s.header;
}

/// `tostr_int` body: the interned decimal rendering of an int.
pub noinline fn tostrIntRuntime(heap: *gc.Heap, x: i64) callconv(.c) ?*object.GcHeader {
    return tostrScalar(heap, Value.int(x));
}

/// `tostr_num` body: the interned rendering of a float.
pub noinline fn tostrNumRuntime(heap: *gc.Heap, x: f64) callconv(.c) ?*object.GcHeader {
    return tostrScalar(heap, Value.float(x));
}

// ---------------------------------------------------------------------------
// The snew class (doc 24 c3): C-ABI shims over the ONE heap-only core per
// transform in `stdlib/string.zig` — the same functions tier-0's natives wrap.
// Null collapses BOTH failure arms of the doc 24 D5 tagged result (`oom` and
// `vm_error`) because they are operationally identical here: no `Heap.link`
// preceded the failure (each core's audit note), so the trace side-exits with
// a clean id stream and tier-0's replay of the iteration re-raises the same
// OOM or the same located `bad argument` error itself. The distinction the
// design draws matters only to a consumer that wanted to react differently —
// no tier does.
// ---------------------------------------------------------------------------

const string_std = @import("stdlib/string.zig");
const string_mod = @import("string.zig");

/// `ssub` body: `string.sub(s, i, j)` by character position, Lua clamping.
pub noinline fn ssubRuntime(heap: *gc.Heap, s: *object.GcHeader, i: i64, j: i64) callconv(.c) ?*object.GcHeader {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.subCore(heap, str, i, j) catch return null;
    return &r.header;
}

/// `srev` body: `string.reverse(s)`, characters mirrored as UTF-8 units.
pub noinline fn srevRuntime(heap: *gc.Heap, s: *object.GcHeader) callconv(.c) ?*object.GcHeader {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.reverseCore(heap, str.bytes()) catch return null;
    return &r.header;
}

/// `schar1` body: 1-argument `string.char(c)`. Out-of-range → null (tier-0
/// replays and raises the located error).
pub noinline fn schar1Runtime(heap: *gc.Heap, code: i64) callconv(.c) ?*object.GcHeader {
    const r = string_std.char1Core(heap, code) catch return null;
    return &r.header;
}

/// `srep2` body: 2-argument `string.rep(s, n)`.
pub noinline fn srep2Runtime(heap: *gc.Heap, s: *object.GcHeader, n: i64) callconv(.c) ?*object.GcHeader {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.rep2Core(heap, str.bytes(), n) catch return null;
    return &r.header;
}
