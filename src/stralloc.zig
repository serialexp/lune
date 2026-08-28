//! Shared string JIT runtime shims (doc 24 D5 — arc B; doc 26).
//!
//! ONE `noinline` routine per string IR op, used by every JIT tier: the
//! tier-1a IR arms (`irinterp.zig`) call them as Zig functions, and the native
//! body callouts (`nativegen.zig`) call the SAME routines through raw pointers
//! with SysV argument passing. Tier-0's `bToString` (`stdlib/basic.zig`) is the
//! composition of the same two primitives these bodies compose — `io.writeValue`
//! (the one renderer) followed by `Heap.intern` (the one interning path) — so
//! the produced bytes and the interned object are identical across tiers by
//! construction.
//!
//! Two classes live here (doc 26 review m4 — the audit rules below scope to
//! the first): the allocating `.alloc`-op producers (`tostr_*`, the snew
//! class, `supper`/`slower`), and ONE non-allocating reader — `scpRuntime` —
//! which shares the shim discipline (same shared-core identity, same
//! C-ABI/side-exit protocol) but performs no allocation and never links.
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
    const r = string_std.reverseCore(heap, str) catch return null;
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
    const r = string_std.rep2Core(heap, str, n) catch return null;
    return &r.header;
}

/// `supper` body: `string.upper(s)` via the shared `caseCore` (doc 26 D2).
/// Deliberately heap-only — the Unicode-version pin is a committed-trace
/// invariant (doc 26 D1), never re-derived on trace.
pub noinline fn supperRuntime(heap: *gc.Heap, s: *object.GcHeader) callconv(.c) ?*object.GcHeader {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.caseCore(heap, str, .upper) catch return null;
    return &r.header;
}

/// `slower` body: `string.lower(s)`, ditto.
pub noinline fn slowerRuntime(heap: *gc.Heap, s: *object.GcHeader) callconv(.c) ?*object.GcHeader {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.caseCore(heap, str, .lower) catch return null;
    return &r.header;
}

/// `scp` body: single-result `string.codepoint(s, i, j)` via the shared
/// `codepointCore` (doc 26 D3) — the non-allocating reader. Returns the scalar
/// (0…0x10FFFF; U+0000 is a REAL result) or **−1** as the empty-range sentinel
/// (unreachable as a scalar) — the trace side-exits and tier-0's replay
/// produces the nil itself. No heap argument, no link, no error path.
pub noinline fn scpRuntime(s: *object.GcHeader, i: i64, j: i64) callconv(.c) i64 {
    const str = string_mod.String.fromHeader(s);
    return string_std.codepointCore(str, i, j) orelse -1;
}

// ---------------------------------------------------------------------------
// Doc 30: the pattern-callout shims. Same shim discipline as above; the match
// ops are allocation-free (they only write the heap's `match_scratch`),
// `scapStrRuntime` is the ONE allocating projection (≤1 link, null = OOM —
// the snew protocol), and every matcher/protocol failure crosses the ABI as
// a distinct negative status (doc 30 M03), never a Zig error.
// ---------------------------------------------------------------------------

const table_mod = @import("table.zig");
const arith = @import("arith.zig");

/// `smatch` body (find/match flavor): locate + scratch fill. Status result:
/// 0 = matched (projections may read scratch), negative = side-exit.
pub noinline fn smatchRuntime(heap: *gc.Heap, s: *object.GcHeader, init_raw: i64, pat: *object.GcHeader) callconv(.c) i64 {
    return string_std.smatchCore(
        heap,
        string_mod.String.fromHeader(s),
        init_raw,
        string_mod.String.fromHeader(pat).bytes(),
    );
}

/// `sfindp` body: plain-substring find. `>= 1` = matched 1-based char index
/// (the end index is recorder arithmetic), negative = side-exit. Heap-free.
pub noinline fn sfindpRuntime(s: *object.GcHeader, init_raw: i64, pat: *object.GcHeader) callconv(.c) i64 {
    return string_std.sfindPlainCore(
        string_mod.String.fromHeader(s),
        init_raw,
        string_mod.String.fromHeader(pat).bytes(),
    );
}

/// `sgmatch` body (doc 30 §6): one composite gmatch-iterator step. READ-ONLY
/// on the state; the pos advance is `sgm_setpos`. `expected_pat` is the
/// record-time pattern (resolved from the konst pool by the emitter) — the
/// shim's identity check replaces `guard_sid` here (round-2 B02).
pub noinline fn sgmatchRuntime(heap: *gc.Heap, state: *object.GcHeader, expected_pat: *object.GcHeader) callconv(.c) i64 {
    const v = Value.heap(state);
    if (v.heapType() != .table) return string_std.MatchStatus.bad_type;
    return string_std.sgmatchCore(
        heap,
        table_mod.Table.fromHeader(state),
        string_mod.String.fromHeader(expected_pat),
    );
}

/// `scap_str` body: intern the span in scratch slot `slot`. Null = OOM.
pub noinline fn scapStrRuntime(heap: *gc.Heap, slot: i64) callconv(.c) ?*object.GcHeader {
    const r = string_std.scapStrCore(heap, @intCast(slot)) orelse return null;
    return &r.header;
}

/// `sgm_setpos` body: commit the gmatch cursor into the state's slot 3 —
/// the deferred store, sunk below every guard (doc 30 §6). Re-verifies the
/// B03 cell shape; 0 = written, negative = side-exit (nothing written).
pub noinline fn sgmSetposRuntime(state: *object.GcHeader, pos: i64) callconv(.c) i64 {
    const t = table_mod.Table.fromHeader(state);
    return if (t.setInLaneValueInt(3, pos)) string_std.MatchStatus.ok else string_std.MatchStatus.bad_layout;
}

/// The `str2num_*` two-register result (SysV: rax = status, rdx = value).
/// status 0 = int (value: i64 bits), 1 = float (value: f64 bits), −1 = not a
/// number (tier-0's replay produces the nil / raises itself).
pub const Str2NumResult = extern struct { status: i64, value: u64 };

/// `str2num_i` / `str2num_f` body: the ONE `arith.toNumber` core on a string
/// operand — tier-0, the recorder's konst fold, and the trace can never
/// disagree (doc 30 §4). Heap-free, pure.
pub noinline fn str2numRuntime(s: *object.GcHeader) callconv(.c) Str2NumResult {
    const v = arith.toNumber(Value.heap(s), null);
    return switch (v.tag) {
        .int => .{ .status = 0, .value = @bitCast(v.asInt()) },
        .float => .{ .status = 1, .value = @bitCast(v.asFloat()) },
        else => .{ .status = -1, .value = 0 },
    };
}
