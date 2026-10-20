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
//! **Error protocol (doc 24 D5, doc 45 D5):** the C-ABI result is a
//! `StrResult` word — the `*GcHeader` on success; on failure a small value
//! that tells the two failure arms apart: the `table_runtime.Status` ordinal
//! of an OOM, or 0 for a *decline* (a case tier-0 handles itself — an
//! out-of-range codepoint's located raise). No
//! `link` ever precedes a fallible step: `Heap.intern`'s miss path is
//! transactional (string allocation and table growth both happen BEFORE any
//! heap mutation — see gc.zig), and the render into the fixed stack buffer
//! cannot fail for scalars. So a failure guarantees a clean id stream. An
//! ordinary trace side-exits on either arm and tier-0 replays the iteration.
//! A precise trace (doc 45) side-exits a decline as `.precise_resume`, but
//! raises an OOM as `.precise_error` at the op — execute-once, never retried
//! (D5): a replay would run the allocation a second time, and under a
//! transient OOM succeed where tier-0 raised.
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
const Status = @import("table_runtime.zig").Status;

/// The allocating shims' one-word result (SysV: rax). Exactly one of three
/// shapes (module doc), told apart by magnitude:
/// - success: the `*GcHeader` itself — aligned, so `>= fail_limit`;
/// - OOM: `Status.out_of_memory`'s ordinal;
/// - decline: 0 — tier-0 replays the op.
/// A failure word IS the `runtime_error` to raise (0 = none), so the native
/// precise stub stores it into `NativeResult.runtime_error` verbatim. One
/// word keeps the success path the bare pointer return: a two-register
/// `{hdr, status}` result cost ~3 shim + 1 native instructions per call
/// (+0.4–0.9% instructions on the string benches) for a status read only on
/// failure. The residual is one instruction per call — LLVM speculates the
/// OOM word into rax before the branch (a `@branchHint(.cold)` does not stop
/// it); str_manip measured +0.2% instructions.
pub const StrResult = enum(usize) {
    decline = 0,
    oom = @intFromEnum(Status.out_of_memory),
    _,

    /// Every word below this is a failure; every `*GcHeader` is at or above.
    pub const fail_limit: usize = @alignOf(object.GcHeader);
    comptime {
        // Every Status a shim can report must sit below the pointer range.
        // The shims report only OOM. The other statuses (doc 63's host
        // statuses among them) never travel in a StrResult, and on wasm32
        // (`fail_limit` 4) `stack_overflow` would not fit.
        for ([_]StrResult{ .decline, .oom }) |r| std.debug.assert(@intFromEnum(r) < fail_limit);
    }

    pub inline fn ok(h: *object.GcHeader) StrResult {
        return @enumFromInt(@intFromPtr(h));
    }
    pub inline fn hdr(r: StrResult) ?*object.GcHeader {
        const w = @intFromEnum(r);
        return if (w >= fail_limit) @ptrFromInt(w) else null;
    }
    /// The failure's `table_runtime.Status` ordinal (0 for a decline).
    pub inline fn runtimeError(r: StrResult) u32 {
        std.debug.assert(@intFromEnum(r) < fail_limit);
        return @intCast(@intFromEnum(r));
    }
};

/// Render a scalar exactly as tier-0's `bToString` does (the shared
/// `io.writeValue` renderer, bounded stack buffer) and intern the bytes.
/// OOM leaves no `link` performed (see the module doc).
inline fn tostrScalar(heap: *gc.Heap, v: Value) StrResult {
    // Non-string renderings are bounded: scalars are <~32 bytes. Same bound
    // as `bToString`'s buffer.
    var buf: [128]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    io.writeValue(&w, v) catch unreachable; // fixed buffer is large enough
    const s = heap.intern(w.buffered()) catch return .oom;
    return .ok(&s.header);
}

/// `tostr_int` body: the interned decimal rendering of an int.
pub noinline fn tostrIntRuntime(heap: *gc.Heap, x: i64) callconv(.c) StrResult {
    return tostrScalar(heap, Value.int(x));
}

/// `tostr_num` body: the interned rendering of a float.
pub noinline fn tostrNumRuntime(heap: *gc.Heap, x: f64) callconv(.c) StrResult {
    return tostrScalar(heap, Value.float(x));
}

// ---------------------------------------------------------------------------
// The snew class (doc 24 c3): C-ABI shims over the ONE heap-only core per
// transform in `stdlib/string.zig` — the same functions tier-0's natives wrap.
// The two failure arms of the doc 24 D5 tagged result stay distinct in the
// `StrResult`: `oom` (a precise trace raises it in place — doc 45 D5) and
// `vm_error`, which crosses as a decline. Neither performed a `Heap.link`
// (each core's audit note), so the id stream is clean either way, and on a
// decline tier-0's replay raises the same located `bad argument` error itself.
// ---------------------------------------------------------------------------

const string_std = @import("stdlib/string.zig");
const string_mod = @import("string.zig");

/// `ssub` body: `string.sub(s, i, j)` by character position, Lua clamping.
pub noinline fn ssubRuntime(heap: *gc.Heap, s: *object.GcHeader, i: i64, j: i64) callconv(.c) StrResult {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.subCore(heap, str, i, j) catch return .oom;
    return .ok(&r.header);
}

/// `srev` body: `string.reverse(s)`, characters mirrored as UTF-8 units.
pub noinline fn srevRuntime(heap: *gc.Heap, s: *object.GcHeader) callconv(.c) StrResult {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.reverseCore(heap, str) catch return .oom;
    return .ok(&r.header);
}

/// `schar1` body: 1-argument `string.char(c)`. Out-of-range → decline (tier-0
/// replays and raises the located error).
pub noinline fn schar1Runtime(heap: *gc.Heap, code: i64) callconv(.c) StrResult {
    const r = string_std.char1Core(heap, code) catch |e| return switch (e) {
        error.OutOfRange => .decline,
        error.OutOfMemory => .oom,
    };
    return .ok(&r.header);
}

/// `srep2` body: 2-argument `string.rep(s, n)`.
pub noinline fn srep2Runtime(heap: *gc.Heap, s: *object.GcHeader, n: i64) callconv(.c) StrResult {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.rep2Core(heap, str, n) catch return .oom;
    return .ok(&r.header);
}

/// `supper` body: `string.upper(s)` via the shared `caseCore` (doc 26 D2).
/// Deliberately heap-only — the Unicode-version pin is a committed-trace
/// invariant (doc 26 D1), never re-derived on trace.
pub noinline fn supperRuntime(heap: *gc.Heap, s: *object.GcHeader) callconv(.c) StrResult {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.caseCore(heap, str, .upper) catch return .oom;
    return .ok(&r.header);
}

/// `slower` body: `string.lower(s)`, ditto.
pub noinline fn slowerRuntime(heap: *gc.Heap, s: *object.GcHeader) callconv(.c) StrResult {
    const str = string_mod.String.fromHeader(s);
    const r = string_std.caseCore(heap, str, .lower) catch return .oom;
    return .ok(&r.header);
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
// `scapStrRuntime` is the ONE allocating projection (≤1 link, the snew
// `StrResult` protocol), and every matcher/protocol failure crosses the ABI as
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

/// `scap_str` body: intern the span in scratch slot `slot`. A stale scratch
/// (the core's defense in depth) declines; an intern OOM is `.oom`.
pub noinline fn scapStrRuntime(heap: *gc.Heap, slot: i64) callconv(.c) StrResult {
    const r = string_std.scapStrCore(heap, @intCast(slot)) catch |e| return switch (e) {
        error.StaleScratch => .decline,
        error.OutOfMemory => .oom,
    };
    return .ok(&r.header);
}

test "doc 45 D5: scapStrRuntime maps stale scratch to decline and an intern OOM to oom" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const slot: i64 = gc.MatchScratch.slot_cap0;
    // Virgin scratch: no fill to project from — tier-0 handles it.
    try std.testing.expectEqual(StrResult.decline, scapStrRuntime(&heap, slot));
    const subj = try heap.intern("key=val");
    try std.testing.expectEqual(string_std.MatchStatus.ok, string_std.smatchCore(&heap, subj, 1, "(%a+)=(%a+)"));
    // An intern miss under a failed allocation is an OOM, never a decline.
    var failing = std.testing.FailingAllocator.init(heap.gpa, .{ .fail_index = 0 });
    const real = heap.gpa;
    heap.gpa = failing.allocator();
    const r_oom = scapStrRuntime(&heap, slot);
    heap.gpa = real;
    try std.testing.expectEqual(StrResult.oom, r_oom);
    try std.testing.expectEqual(@as(u32, @intFromEnum(Status.out_of_memory)), r_oom.runtimeError());
    const got = scapStrRuntime(&heap, slot).hdr().?;
    try std.testing.expectEqual(&(try heap.intern("key")).header, got);
}

/// `sgm_setpos` body: commit the gmatch cursor into the state's slot 3 —
/// the deferred store, sunk below every guard (doc 30 §6). Re-verifies the
/// B03 cell shape; 0 = written, negative = side-exit (nothing written).
pub noinline fn sgmSetposRuntime(state: *object.GcHeader, pos: i64) callconv(.c) i64 {
    // Type-check INSIDE the shim (doc 30 c3): the native path proves only
    // `.heap`/`.ptr` on the state operand, so `Table.fromHeader` on a
    // non-table would be UB — fail closed with bad_type instead (nothing
    // written; tier-0 replays).
    if (Value.heap(state).heapType() != .table) return string_std.MatchStatus.bad_type;
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
