//! mahina stdlib — the `string` library (non-pattern subset).
//!
//! Pure, deterministic byte operations (tier `core`): `len`, `sub`, `byte`,
//! `char`, `rep`, `reverse`, `upper`, `lower`, and the `printf`-style `format`.
//! Every result string is built into bounded stack scratch or a `vm.gpa`
//! `ArrayList(u8)` and then **interned** through `vm.heap.internValue` — the one
//! deterministic string-construction primitive. No host effects, no recorder, no
//! safepoint interaction: determinism-invisible like `stdlib/math.zig`.
//!
//! `format` (and its `printf` helpers) was relocated here verbatim from
//! `interp.zig`'s bench stdlib, keeping its serialized identity `"string.format"`
//! so keyframe restore is unaffected. The two genuinely-shared coercion helpers it
//! leans on (`interp.coerceConcat` for `%s` on a number, `interp.strBytes` for the
//! string args) stay in `interp.zig` and are referenced qualified — the same
//! coupling `stdlib/table.zig` already uses.
//!
//! Index semantics follow Lua 5.4 (`lstrlib.c`): negative positions count from
//! the end and `sub`/`codepoint` ranges are clamped, never out-of-bounds.
//! `upper`/`lower` (S-C) do Unicode **simple (1:1)** case mapping — default,
//! locale-independent — via the vendored, version-pinned `gen/unicode_case`
//! table, with a branch-free ASCII fast path. The active Unicode version is pinned
//! per session as the `unicode_version` effect (determinism: a mutable locale is
//! still excluded — see the CSV).

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const string_mod = @import("../string.zig");
const table_mod = @import("../table.zig");
const pattern = @import("pattern.zig");
const decimal = @import("decimal.zig");
const io = @import("../io.zig");
const byte_ops = @import("../bytes.zig");
const gc = @import("../gc.zig");
const native_act = @import("../native_act.zig");
const ByteBuf = @import("../bytebuf.zig").ByteBuf;
const RegWindow = @import("../regwindow.zig").RegWindow;
const unicode_case = @import("../gen/unicode_case.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Table = table_mod.Table;
const String = string_mod.String;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// The hidden iterator `gmatch` hands back, like `base.zig`'s `@ipairs_iter`:
/// a serialized identity, no global (`Vm.libNative`).
const gmatch_iter_name = "@gmatch_iter";

/// Fetch argument `i` (0-based) as a table, or raise the located Lua
/// `bad argument #<i+1> to '<fn>' (table expected, got <type|no value>)`.
fn tableArg(vm: *Vm, args: []const Value, i: usize) anyerror!*Table {
    if (i >= args.len) return vm.badArg(i + 1, "table", null);
    const v = args[i];
    if (!v.isHeap() or v.heapType() != .table) return vm.badArg(i + 1, "table", v);
    const t = Table.fromHeader(v.asHeap());
    // Gate (doc 14): grids are touched only by fused `a[i][j]`; a bare stdlib op
    // deflates the grid back to real row tables first.
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    return t;
}

/// Fetch argument `i` (0-based) as string bytes, or raise the located Lua
/// `bad argument #<i+1> to '<fn>' (string expected, got <type|no value>)`.
fn strArg(vm: *Vm, args: []const Value, i: usize) anyerror![]const u8 {
    if (i >= args.len) return vm.badArg(i + 1, "string", null);
    return interp.strBytes(args[i]) orelse vm.badArg(i + 1, "string", args[i]);
}

/// Lua's `posrelat`: map a possibly-negative 1-based position to an absolute
/// 1-based position against a string of length `len`. A negative `pos` counts
/// from the end (`-1` = last); the result is *not* yet clamped to `[1, len]`.
fn posRelat(pos: i64, len: usize) i64 {
    if (pos >= 0) return pos;
    const l: i64 = @intCast(len);
    // `pos < -l`, not `-pos > l`: negating minInt overflows.
    if (pos < -l) return 0;
    return l + pos + 1;
}

// ---------------------------------------------------------------------------
// UTF-8 / code-point helpers (S-B, design doc 06)
//
// Strings are code-point-native: `len`/`sub`/`reverse`/`codepoint`/`codes` index
// by character. These helpers translate between 1-based character positions and
// byte offsets over a string's (valid) UTF-8 buffer. They are total — on the
// stray non-UTF-8 byte (which cannot enter a string post-S-B) they degrade to a
// 1-byte step / U+FFFD rather than erroring, so no operation can trap on data.
// ---------------------------------------------------------------------------

/// Fetch argument `i` (0-based) as a heap `String` object — for code-point-aware
/// operations that need the cached code-point count and the UTF-8 byte buffer.
/// (Like `strArg`, mahina does not coerce a number here; a non-string raises.)
fn strObjArg(vm: *Vm, args: []const Value, i: usize) anyerror!*const String {
    if (i >= args.len) return vm.badArg(i + 1, "string", null);
    const v = args[i];
    if (!v.isHeap() or v.heapType() != .string) return vm.badArg(i + 1, "string", v);
    return String.fromHeader(v.asHeap());
}

/// Count Unicode code points in valid UTF-8 `s` (every non-continuation byte
/// starts a code point). Branch-light; used for code-point-aware field widths in
/// `string.format` so `%Ns`/`%Nc` align by character, consistent with `#s`.
///
/// This byte-slice form (and `charByteOffset` below) stays as the general
/// implementation AND the reference the doc-28 tests compare the `*String`
/// fast forms against. New code at a core boundary wants the `*String` forms —
/// they consult the cached `cp_len` instead of scanning.
fn cpCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// doc 28 L1 — String-aware seam helpers.
//
// A `*String` caches `cp_len` and the EXACT all-ASCII bit (`String.isAscii`,
// one fused construction-time scan; sound for any bytes — see doc 28 §2 on why
// `cp_len == len` is NOT the predicate). For an ASCII string every char↔byte
// conversion is the identity. These helpers are the one place that fact is
// applied; the byte-slice forms above remain the general path (and the tests'
// reference implementations).
// ---------------------------------------------------------------------------

/// Pure-ASCII proof — the cached exact bit.
inline fn isAscii(s: *const String) bool {
    return s.isAscii();
}

/// `charByteOffset` on a `*String`: 1-based character `ci` → 0-based byte
/// offset. ASCII: the identity `ci - 1`, clamped exactly like the scan
/// (`ci <= 1` → 0; `ci == cp_len + 1` → len; beyond → len).
fn charByteOffsetS(s: *const String, ci: usize) usize {
    if (isAscii(s)) return @min(ci -| 1, s.len);
    return charByteOffset(s.bytes(), ci);
}

/// `byteToChar` on a `*String`: 0-based byte boundary → 1-based char index.
fn byteToCharS(s: *const String, off: usize) usize {
    std.debug.assert(off <= s.len);
    if (isAscii(s)) return off + 1;
    return cpCount(s.bytes()[0..off]) + 1;
}

/// `cpCount` of the prefix `s.bytes()[0..end]` on a `*String`.
fn cpCountPrefixS(s: *const String, end: usize) usize {
    std.debug.assert(end <= s.len);
    if (isAscii(s)) return end;
    return cpCount(s.bytes()[0..end]);
}

/// Byte end of "at most `count` characters" of `s` — the `%.Ns` precision
/// seam. `count` is clamped to `cp_len` BEFORE any arithmetic, so a huge
/// parsed precision cannot overflow `count + 1`.
fn charPrefixEndS(s: *const String, count: usize) usize {
    const n = @min(count, s.cp_len);
    if (isAscii(s)) return n;
    return charByteOffset(s.bytes(), n + 1);
}

/// The `*const String` behind a string `Value`, or null. The object form of
/// `interp.strBytes` — seam consumers want the object (cached `cp_len`), not
/// the degraded byte slice.
fn strObjOf(v: Value) ?*const String {
    if (!v.isHeap() or v.heapType() != .string) return null;
    return String.fromHeader(v.asHeap());
}

/// Byte offset at which the 1-based character `ci` starts in `s`. `ci` may be
/// `cp_len + 1` (one past the end → returns `s.len`), so the character range
/// `[i, j]` maps to bytes `[charByteOffset(i), charByteOffset(j + 1)]`. `ci <= 1`
/// is the start.
fn charByteOffset(s: []const u8, ci: usize) usize {
    if (ci <= 1) return 0;
    var skip = ci - 1;
    var off: usize = 0;
    while (skip > 0 and off < s.len) : (skip -= 1) {
        const n = std.unicode.utf8ByteSequenceLength(s[off]) catch 1;
        off += @min(n, s.len - off);
    }
    return off;
}

/// A decoded code point: the scalar and its UTF-8 sequence length.
const Decoded = struct { cp: u21, len: usize };

/// Decode the code point starting at byte `off` in valid UTF-8 `s`, returning the
/// scalar value and the byte length of its sequence. Total (U+FFFD / 1-byte step
/// on malformed input, which does not occur for a valid string).
fn decodeAt(s: []const u8, off: usize) Decoded {
    const n = std.unicode.utf8ByteSequenceLength(s[off]) catch 1;
    const end = @min(off + n, s.len);
    const cp = std.unicode.utf8Decode(s[off..end]) catch 0xFFFD;
    return .{ .cp = cp, .len = end - off };
}

/// Append the UTF-8 encoding of code point `code` (argument `argn`, 1-based, for
/// error messages) to `buf`. Rejects negatives, values `> 0x10FFFF`, and
/// surrogate halves (`utf8Encode` errors on the latter two) with the located
/// `bad argument #argn ... (value out of range)`.
fn appendCodepoint(vm: *Vm, argn: usize, code: i64, buf: *std.ArrayList(u8)) anyerror!void {
    var tmp: [4]u8 = undefined;
    const n = encodeCodepoint(code, &tmp) orelse
        return vm.badArgReason(argn, "value out of range");
    try buf.appendSlice(vm.gpa, tmp[0..n]);
}

// ---------------------------------------------------------------------------
// snew-class heap-only cores (doc 24 D5 — arc B c3)
//
// ONE transform body per allocating string builtin, shared by every tier:
// the tier-0 natives below wrap these (argument parsing + error location stay
// in the wrappers), and the JIT callouts (`src/stralloc.zig`) call the SAME
// functions through C-ABI shims — so the produced bytes, the interned object,
// and the allocation count are identical across tiers by construction.
//
// Audit rule (doc 24 D5): each core performs at most ONE `Heap.link` (the
// single `intern`; an intern hit performs zero), and no `link` precedes a
// fallible step (scratch allocation happens BEFORE the intern; `Heap.intern`
// itself is transactional). Scratch comes from `heap.gpa` — the same gpa the
// tier-0 wrappers use (`Vm.initBare` feeds both from one allocator).
// ---------------------------------------------------------------------------

/// `string.sub` core: character-position substring with Lua's negative-index
/// and clamping rules (never errors). Interns a subslice directly — no scratch.
pub fn subCore(heap: *gc.Heap, s: *const String, i_arg: i64, j_arg: i64) std.mem.Allocator.Error!*String {
    const clen = s.cpLen();
    var i = posRelat(i_arg, clen);
    var j = posRelat(j_arg, clen);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(clen))) j = @intCast(clen);
    if (i > j) return heap.internKnown("", .{ .cp_len = 0, .ascii = true }); // empty
    const bytes = s.bytes();
    // doc 28 §6: the slice's character count is `j - i + 1` by DEFINITION of a
    // character-position substring — known for both paths, no recount on miss.
    const known_cp: usize = @intCast(j - i + 1);
    if (isAscii(s)) {
        // doc 28 L1: chars ARE bytes — the two boundary scans collapse to a
        // direct slice (1-based inclusive [i, j] → bytes [i-1, j)). `i >= 1`
        // and `j <= clen == len` hold from the clamps above. A slice of an
        // ASCII string is ASCII.
        return heap.internKnown(bytes[@intCast(i - 1)..@intCast(j)], .{ .cp_len = known_cp, .ascii = true });
    }
    const start = charByteOffset(bytes, @intCast(i));
    const end = charByteOffset(bytes, @intCast(j + 1));
    // ASCII bit of a general substring is NOT inferable (a slice of a multibyte
    // string may be pure ASCII) — left null, derived by the scan.
    return heap.internKnown(bytes[start..end], .{ .cp_len = known_cp });
}

/// `string.reverse` core: characters reversed, each UTF-8 sequence moved as a
/// unit. Scratch resize is the only fallible step and precedes the intern.
/// Takes the `*String` (doc 28 L1) so the ASCII block path (c3b) can prove
/// itself from `cp_len`.
pub fn reverseCore(heap: *gc.Heap, s: *const String) std.mem.Allocator.Error!*String {
    const bytes = s.bytes();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(heap.gpa);
    try buf.resize(heap.gpa, bytes.len);
    if (isAscii(s)) {
        // doc 28 §4 L2: every char is one byte — a plain byte reverse, no
        // per-character sequence-length decode.
        for (bytes, 0..) |b, k| buf.items[bytes.len - 1 - k] = b;
    } else {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(std.unicode.utf8ByteSequenceLength(bytes[off]) catch 1, bytes.len - off);
            const dst = bytes.len - off - n; // mirror this char's bytes (in order)
            @memcpy(buf.items[dst .. dst + n], bytes[off .. off + n]);
            off += n;
        }
    }
    // doc 28 §6: a reversal is a byte permutation, and BOTH caches are pure
    // per-byte properties — count of non-continuation bytes and absence of
    // bytes ≥ 0x80 are preserved for ANY input bytes. Exact, not just valid-UTF-8.
    return heap.internKnown(buf.items, .{ .cp_len = s.cpLen(), .ascii = s.isAscii() });
}

/// Encode one code point to UTF-8, or null when out of range (negative,
/// `> 0x10FFFF`, or a surrogate half). The ONE validation+encode body behind
/// both tier-0 `string.char` (via `appendCodepoint`) and the JIT's
/// `char1Core` — keep them in lockstep by construction.
fn encodeCodepoint(code: i64, out: *[4]u8) ?usize {
    if (code < 0 or code > 0x10FFFF) return null;
    return std.unicode.utf8Encode(@intCast(code), out) catch null;
}

/// 1-argument `string.char` core. `error.OutOfRange` means tier-0 would raise
/// `bad argument` for this value — the JIT side-exits (no link happened) and
/// tier-0's replay raises the located error itself.
pub fn char1Core(heap: *gc.Heap, code: i64) (error{OutOfRange} || std.mem.Allocator.Error)!*String {
    var tmp: [4]u8 = undefined;
    const n = encodeCodepoint(code, &tmp) orelse return error.OutOfRange;
    // doc 28 §6: one scalar in, one character out; ASCII iff the scalar is.
    return heap.internKnown(tmp[0..n], .{ .cp_len = 1, .ascii = code < 0x80 });
}

/// 2-argument `string.rep` core (no separator). `n <= 0` → the empty string.
/// Scratch growth is fallible and precedes the intern; a pathological `n`
/// OOMs here, side-exits, and tier-0's replay re-raises the same OOM.
/// Takes the `*String` (doc 28 §6): repetition multiplies the character count
/// exactly and preserves the ASCII bit — both are per-byte properties, so this
/// holds for ANY bytes, not just valid UTF-8.
pub fn rep2Core(heap: *gc.Heap, str: *const String, n: i64) (error{TooLarge} || std.mem.Allocator.Error)!*String {
    if (n <= 0) return heap.internKnown("", .{ .cp_len = 0, .ascii = true });
    const bytes = str.bytes();
    const total = repBytes(bytes.len, n, 0) orelse return error.TooLarge;
    var buf: std.ArrayList(u8) = try .initCapacity(heap.gpa, total);
    defer buf.deinit(heap.gpa);
    const count: usize = @intCast(n);
    var k: usize = 0;
    while (k < count) : (k += 1) buf.appendSliceAssumeCapacity(bytes);
    // Checked multiply: overflow → null (recount), NEVER a wrapped claim.
    const known_cp: ?usize = std.math.mul(usize, str.cpLen(), count) catch null;
    return heap.internKnown(buf.items, .{ .cp_len = known_cp, .ascii = str.isAscii() });
}

/// The byte length of `n > 0` copies of a `len`-byte string joined by a
/// `sep_len`-byte separator, or null when it is past the largest string
/// (Lua's "resulting string too large"). The bound is the same on every
/// target, `maxInt(i64)`, then capped to the address space.
fn repBytes(len: usize, n: i64, sep_len: usize) ?usize {
    const count: u64 = @intCast(n);
    const body = std.math.mul(u64, len, count) catch return null;
    const seps = std.math.mul(u64, sep_len, count - 1) catch return null;
    const total = std.math.add(u64, body, seps) catch return null;
    if (total > std.math.maxInt(i64) or total > std.math.maxInt(usize)) return null;
    return @intCast(total);
}

// ---------------------------------------------------------------------------
// len / sub / reverse / upper / lower / rep
// ---------------------------------------------------------------------------

/// `string.len(s)` — number of code points (same as `#s`, S-B). O(1) via the
/// cached count.
fn sLen(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const s = try strObjArg(vmOf(ctx), args, 0);
    return Value.int(@intCast(s.cpLen()));
}

/// `string.sub(s, i [, j])` — substring `s[i..j]` by **character** position
/// (S-B), 1-based inclusive, with Lua's negative-index and clamping rules. `j`
/// defaults to `-1` (last character). The character range is mapped to byte
/// offsets on code-point boundaries, so the result is valid UTF-8.
fn sSub(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const i = try vm.intArg(args, 1);
    const j = try vm.optIntArg(args, 2, -1);
    const r = try subCore(vm.heap, s, i, j);
    return Value.heap(&r.header);
}

/// `string.reverse(s)` — characters reversed (S-B): each UTF-8 sequence is moved
/// as a unit to its mirrored position, so multibyte characters survive intact.
fn sReverse(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const r = try reverseCore(vm.heap, s);
    return Value.heap(&r.header);
}

/// `string.upper(s)` — Unicode simple (1:1) uppercase (default, locale-independent).
fn sUpper(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return mapCaseUnicode(ctx, args, .upper);
}

/// `string.lower(s)` — Unicode simple (1:1) lowercase (default, locale-independent).
fn sLower(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return mapCaseUnicode(ctx, args, .lower);
}

/// The case-mapping direction, shared by `caseCore` and its tier-0 wrapper
/// (a NAMED type so both signatures denote the same comptime enum).
pub const CaseKind = enum { upper, lower };

/// Simple case-mapping core (S-C, design doc 06) — the ONE compiled body every
/// tier shares (doc 26 D2): tier-0 wraps it below, the JIT calls it through
/// `stralloc.supperRuntime`/`slowerRuntime`. ASCII (`< 0x80`) is a branch-free
/// fast path; above it the vendored `unicode_case` table maps one code point to
/// one (count-preserving — simple mapping never changes the code-point count).
/// Output is valid UTF-8 by construction (every emitted scalar is re-encoded),
/// so `intern` needs no re-validation. Audit (doc 24 D5): scratch growth is the
/// only fallible step and precedes the single `intern` — **≤ 1 `Heap.link` per
/// call** (an intern hit links zero). Deliberately heap-only: the session's
/// Unicode-version pin is NOT this core's business — tier-0's wrapper performs
/// it, and a committed trace implies it already happened (doc 26 D1).
pub fn caseCore(heap: *gc.Heap, str: *const String, comptime kind: CaseKind) std.mem.Allocator.Error!*String {
    const s = str.bytes();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(heap.gpa);
    if (isAscii(str)) {
        // doc 28 §4 L2: ASCII maps byte-for-byte — ONE resize (the per-char
        // append/grow discipline of the general loop was ~15% of str_manip)
        // and a straight byte map the compiler can vectorize. Result: same
        // length, same character count, still ASCII.
        try buf.resize(heap.gpa, s.len);
        for (s, buf.items) |b, *d| d.* = switch (kind) {
            .upper => std.ascii.toUpper(b),
            .lower => std.ascii.toLower(b),
        };
        return heap.internKnown(buf.items, .{ .cp_len = str.cpLen(), .ascii = true });
    }
    var off: usize = 0;
    while (off < s.len) {
        const b = s[off];
        if (b < 0x80) { // ASCII fast path — one byte, one character
            const c = switch (kind) {
                .upper => std.ascii.toUpper(b),
                .lower => std.ascii.toLower(b),
            };
            try buf.append(heap.gpa, c);
            off += 1;
            continue;
        }
        const d = decodeAt(s, off);
        const mapped = switch (kind) {
            .upper => unicode_case.toUpper(d.cp),
            .lower => unicode_case.toLower(d.cp),
        };
        var enc: [4]u8 = undefined;
        if (std.unicode.utf8Encode(mapped, &enc)) |n| {
            try buf.appendSlice(heap.gpa, enc[0..n]);
        } else |_| {
            // The table only ever maps to assigned, non-surrogate scalars, so this
            // is unreachable in practice; on the impossible chance, keep the input
            // sequence verbatim rather than corrupting the string.
            try buf.appendSlice(heap.gpa, s[off .. off + d.len]);
        }
        off += d.len;
    }
    // doc 28 §6: simple 1:1 mapping is count-preserving (documented contract
    // above; holds for the verbatim fallback too), so the count carries over.
    // The ASCII bit does NOT (simple case mapping can cross the boundary —
    // U+212A KELVIN SIGN lowers to plain 'k') — left null, derived by scan.
    // Reachable inputs are valid UTF-8 (S-B: effect-log-parked invalid bytes
    // are never program-visible), which the count-preservation relies on.
    return heap.internKnown(buf.items, .{ .cp_len = str.cpLen() });
}

/// Tier-0 `string.upper`/`string.lower`: pin the Unicode version as a session
/// effect (`vm.noteUnicodeVersion` — so the result stays byte-identical on
/// replay even as the table churns; the pin is committed BEFORE the core can
/// OOM in scratch, part of the doc 26 D1 proof), then run the shared core.
fn mapCaseUnicode(ctx: *anyopaque, args: []const Value, comptime kind: CaseKind) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    // The version pin runs for ASCII inputs too (doc 28 §4) — it is a session
    // effect; forking it on the data would fork replay.
    try interp.noteUnicodeVersion(vm);
    const r = try caseCore(vm.heap, s, kind);
    return Value.heap(&r.header);
}

/// `string.rep(s, n [, sep])` — `s` repeated `n` times, joined by `sep`
/// (default ""). `n <= 0` → empty string.
fn sRep(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const sobj = try strObjArg(vm, args, 0);
    const s = sobj.bytes();
    const n = try vm.intArg(args, 1);
    const sep: []const u8 = if (args.len >= 3 and !args[2].isNil())
        (interp.strBytes(args[2]) orelse return vm.badArg(3, "string", args[2]))
    else
        "";
    if (sep.len == 0) { // the recordable 2-arg shape shares the ONE core
        const r = rep2Core(vm.heap, sobj, n) catch |e| return switch (e) {
            error.TooLarge => vm.raiseLocatedError("resulting string too large", 1),
            error.OutOfMemory => e,
        };
        return Value.heap(&r.header);
    }
    if (n <= 0) return vm.heap.internValue("");

    const total = repBytes(s.len, n, sep.len) orelse return vm.raiseLocatedError("resulting string too large", 1);
    var buf: std.ArrayList(u8) = try .initCapacity(vm.gpa, total);
    defer buf.deinit(vm.gpa);
    const count: usize = @intCast(n);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (k != 0) buf.appendSliceAssumeCapacity(sep);
        buf.appendSliceAssumeCapacity(s);
    }
    return vm.heap.internValue(buf.items);
}

// ---------------------------------------------------------------------------
// char / codepoint / codes  (S-B: code points, not bytes)
// ---------------------------------------------------------------------------

/// `string.char(...)` — build a string from integer **code points** (each
/// `0..0x10FFFF`, surrogates rejected), encoding each to UTF-8. (Was: byte
/// values 0–255. The byte-building role now lives in `string.decode` of an
/// integer array; design doc 06.)
fn sChar(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    for (0..args.len) |idx| {
        // Mandatory code points: an explicit nil is a bad argument, not a
        // default-to-zero (which would silently emit NUL).
        try appendCodepoint(vm, idx + 1, try vm.intArg(args, idx), &buf);
    }
    return vm.heap.internValue(buf.items);
}

/// Resolve a 1-based inclusive **character** range `[i, j]` over `clen` code
/// points, with Lua's negative-index + clamping. `i` defaults to 1, `j` to `i`.
/// An empty range is reported as `lo > hi`.
fn charRange(vm: *Vm, args: []const Value, clen: usize) anyerror!struct { lo: usize, hi: usize } {
    const i_raw = try vm.optIntArg(args, 1, 1);
    const j_raw = try vm.optIntArg(args, 2, i_raw);
    var i = posRelat(i_raw, clen);
    var j = posRelat(j_raw, clen);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(clen))) j = @intCast(clen);
    if (i > j) return .{ .lo = 1, .hi = 0 }; // empty (lo > hi)
    return .{ .lo = @intCast(i), .hi = @intCast(j) };
}

/// Single-result `string.codepoint` core (doc 26 D3) — the ONE body owning the
/// full range logic (`posRelat` wrap, clamping, empty check) and the decode,
/// shared by tier-0's `sCodepoint1` below and the JIT's `stralloc.scpRuntime`.
/// `i`/`j` are the raw (possibly negative) character positions AFTER any tier-0
/// argument defaulting/coercion. Returns the scalar at the clamped `lo`, or
/// null when the range is empty (`lo > hi` — tier-0 renders that as nil; the
/// JIT side-exits). Pure and non-allocating.
pub fn codepointCore(s: *const String, i_arg: i64, j_arg: i64) ?i64 {
    const clen = s.cpLen();
    var i = posRelat(i_arg, clen);
    var j = posRelat(j_arg, clen);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(clen))) j = @intCast(clen);
    if (i > j) return null; // empty range
    const bytes = s.bytes();
    // doc 28 L1: for ASCII the byte at `i - 1` IS the code point.
    if (isAscii(s)) return bytes[@intCast(i - 1)];
    const d = decodeAt(bytes, charByteOffset(bytes, @intCast(i)));
    return @intCast(d.cp);
}

/// `string.codepoint(s [, i [, j]])` — the Unicode scalar values of the
/// characters `s[i..j]`, one integer per result (a `multi` native). Replaces
/// Lua's byte-returning `string.byte` (raw bytes now come from `s:encode()`).
/// `i` defaults to 1, `j` to `i`; positions are **character** indices. The
/// single-result path (0/1 wanted results) parses/coerces arguments and
/// delegates the semantics to `codepointCore`.
fn sCodepoint1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const i_raw = try vm.optIntArg(args, 1, 1);
    const j_raw = try vm.optIntArg(args, 2, i_raw);
    const cp = codepointCore(s, i_raw, j_raw) orelse return Value.nil();
    return Value.int(cp);
}

fn sCodepointN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const r = try charRange(vm, args, s.cpLen());
    if (r.lo > r.hi) return 0;
    const bytes = s.bytes();
    const count = r.hi - r.lo + 1;
    // More results than the whole stack holds: Lua's checkstack message.
    // Fewer, but more than `out` holds, is the VM's call (`NativeMultiFn`).
    if (count > vm.regCapacity()) return vm.raiseLocatedError("stack overflow (string slice too long)", 1);
    var k: usize = 0;
    if (isAscii(s)) {
        // doc 28 L1: bytes are the code points; no decode loop.
        while (k < count and k < out.len) : (k += 1)
            out[k] = Value.int(bytes[r.lo - 1 + k]);
        return count;
    }
    var off = charByteOffset(bytes, r.lo);
    while (k < count and k < out.len) : (k += 1) {
        const d = decodeAt(bytes, off);
        out[k] = Value.int(@intCast(d.cp));
        off += d.len;
    }
    return count;
}

/// The hidden iterator `s:codes()` hands back, like `@gmatch_iter`.
const codes_iter_name = "@codes_iter";

/// `s:codes()` — returns the generic-for triple `(@codes_iter, state, nil)`,
/// where `state` is a plain table `{ [1]=s, [2]=byteCursor, [3]=charsEmitted }`
/// the iterator mutates (the `gmatch` shape — serializable, unlike a
/// closure-with-upvalue). Each step yields `(charIndex, codepoint)` with
/// `charIndex` 1-based, stopping at end of string. O(n) total (the char counter
/// is threaded, not recomputed).
fn sCodesN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    _ = try strObjArg(vm, args, 0); // type-check subject
    const iter = vm.libNative(.codes_iter);
    const state = try vm.heap.newTable();
    try state.set(vm.gpa, Value.int(1), args[0]); // subject string Value
    try state.set(vm.gpa, Value.int(2), Value.int(0)); // 0-based byte cursor
    try state.set(vm.gpa, Value.int(3), Value.int(0)); // code points emitted so far
    const triple = [3]Value{ iter, Value.heap(&state.header), Value.nil() };
    return copyOut(&triple, out);
}

fn sCodes1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    // Degenerate single-result projection: just the iterator (state is lost).
    const vm = vmOf(ctx);
    _ = try strObjArg(vm, args, 0);
    return vm.libNative(.codes_iter);
}

/// `@codes_iter(state)` — decode the character at the stored byte cursor, advance
/// the cursor past it and the emitted-count by one, and return
/// `(charIndex, codepoint)`; 0 results when the cursor reaches the end.
/// `charIndex` is the 1-based character ordinal (threaded in `state[3]`, so each
/// step is O(1)).
fn codesAuxCore(vm: *Vm, args: []const Value, out: *[2]Value) anyerror!usize {
    const st = try tableArg(vm, args, 0);
    // The OBJECT, not the degraded bytes (doc 28 L1): `isAscii` skips the decode.
    const sobj = strObjOf(st.getInt(1)) orelse return error.TypeError;
    const s = sobj.bytes();
    const pos_v = st.getInt(2);
    var pos: usize = if (pos_v.isInt() and pos_v.asInt() >= 0) @intCast(pos_v.asInt()) else 0;
    const emitted_v = st.getInt(3);
    const emitted: i64 = if (emitted_v.isInt()) emitted_v.asInt() else 0;
    if (pos >= s.len) return 0; // exhausted

    const d: Decoded = if (isAscii(sobj))
        .{ .cp = s[pos], .len = 1 }
    else
        decodeAt(s, pos);
    pos += d.len;
    // The state is a table the caller passed: it may be frozen (doc 76 §5).
    if (st.isReadonly()) return vm.readonlyError();
    try st.set(vm.gpa, Value.int(2), Value.int(@intCast(pos)));
    try st.set(vm.gpa, Value.int(3), Value.int(emitted + 1));
    out[0] = Value.int(emitted + 1); // 1-based character ordinal
    out[1] = Value.int(@intCast(d.cp));
    return 2;
}

fn sCodesAux1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var out: [2]Value = undefined;
    const n = try codesAuxCore(vmOf(ctx), args, &out);
    return if (n == 0) Value.nil() else out[0];
}

fn sCodesAuxN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    var pair: [2]Value = undefined;
    const n = try codesAuxCore(vmOf(ctx), args, &pair);
    return copyOut(pair[0..n], out);
}

// ---------------------------------------------------------------------------
// format — relocated from interp.zig (name kept: "string.format")
// ---------------------------------------------------------------------------

/// A conversion specifier `%[flags][width][.prec]<conv>` that `parseSpec` has
/// checked against its conversion's rules (Lua's `checkformat`).
const FormatSpec = struct {
    minus: bool = false, // '-' left-justify
    zero: bool = false, // '0' zero-pad
    plus: bool = false, // '+' force sign on positives
    space: bool = false, // ' ' leading space on positives
    hash: bool = false, // '#' alternate form (o/x/X)
    width: usize = 0,
    precision: ?usize = null,
    conv: u8 = 0,
};

fn appendN(out: *std.ArrayList(u8), gpa: std.mem.Allocator, byte: u8, n: usize) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) try out.append(gpa, byte);
}

/// Emit a numeric field: optional `prefix` (sign and/or `0x`), then `digits`,
/// applying integer `precision` (minimum digit count → zero-extend) and field
/// `width` with the `-`/`0` flags. Used by both integer and float conversions
/// (floats pass `precision == null`, having already rendered their fraction).
fn emitNumeric(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    prefix: []const u8,
    digits: []const u8,
    spec: FormatSpec,
) !void {
    var zext: usize = 0; // precision-driven zero extension of the digits
    if (spec.precision) |p| {
        if (digits.len < p) zext = p - digits.len;
    }
    const body_len = prefix.len + zext + digits.len;
    const pad: usize = if (spec.width > body_len) spec.width - body_len else 0;
    // C/Lua: the `0` flag is ignored when an explicit precision is given for ints.
    const zero_pad = spec.zero and !spec.minus and spec.precision == null;

    if (spec.minus) {
        try out.appendSlice(gpa, prefix);
        try appendN(out, gpa, '0', zext);
        try out.appendSlice(gpa, digits);
        try appendN(out, gpa, ' ', pad);
    } else if (zero_pad) {
        try out.appendSlice(gpa, prefix);
        try appendN(out, gpa, '0', pad);
        try appendN(out, gpa, '0', zext);
        try out.appendSlice(gpa, digits);
    } else {
        try appendN(out, gpa, ' ', pad);
        try out.appendSlice(gpa, prefix);
        try appendN(out, gpa, '0', zext);
        try out.appendSlice(gpa, digits);
    }
}

fn signPrefix(neg: bool, spec: FormatSpec) []const u8 {
    if (neg) return "-";
    if (spec.plus) return "+";
    if (spec.space) return " ";
    return "";
}

// --- C-`printf` float bodies (magnitude only; sign/width applied later) --------
//
// The digit engine is `decimal.zig`, which converts the double EXACTLY (see its
// header for why `std.fmt.float.render` cannot be used here: it is Ryu-shortest,
// so it double-rounds and breaks ties the wrong way). These helpers add the
// pieces C has and the engine deliberately leaves to the caller: `%g`'s
// significant-digit form and its trailing-zero stripping.

/// Magnitude-body scratch. A `%f` body is at most 309 integer digits (1e308)
/// plus the requested precision; a double's expansion terminates by 1074
/// fractional digits, so nothing past that can be anything but zeros.
const float_body_max = 1400;

/// Copy `s` into `dst`, stripping trailing fractional zeros (and a then-trailing
/// '.') while preserving any exponent suffix — C `%g` without the `#` flag.
fn stripZeros(dst: []u8, s: []const u8) []const u8 {
    const ei = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
    var end = ei;
    if (std.mem.indexOfScalar(u8, s[0..ei], '.') != null) {
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
    }
    var w: usize = 0;
    @memcpy(dst[w..][0..end], s[0..end]);
    w += end;
    const exp = s[ei..];
    @memcpy(dst[w..][0..exp.len], exp);
    w += exp.len;
    return dst[0..w];
}

/// `%g`/`%G` magnitude: C's significant-digit form. With precision `P` (already
/// defaulted/clamped to ≥1 by the caller), pick `%e` when the decimal exponent X
/// is `< -4` or `>= P`, else `%f`, then strip trailing zeros unless `hash`.
fn renderG(dst: []u8, mag: f64, p: usize, exp_char: u8, hash: bool) ![]const u8 {
    const X = decimal.decimalExponent(mag, p);
    var buf: [float_body_max]u8 = undefined;
    var body: []const u8 = undefined;
    if (X >= -4 and X < @as(i32, @intCast(p))) {
        const frac: usize = @intCast(@as(i32, @intCast(p)) - 1 - X); // ≥0 since X<P
        body = decimal.fixed(&buf, mag, frac) catch return error.TypeError;
    } else {
        body = decimal.scientific(&buf, mag, p - 1, exp_char) catch return error.TypeError;
    }
    if (hash) {
        @memcpy(dst[0..body.len], body);
        return dst[0..body.len];
    }
    return stripZeros(dst, body);
}

/// Flag bits, and Lua's flag sets per conversion (`lstrlib.c` `L_FMTFLAGS*`).
const f_minus: u8 = 1;
const f_zero: u8 = 2;
const f_plus: u8 = 4;
const f_space: u8 = 8;
const f_hash: u8 = 16;
const flags_float = f_minus | f_plus | f_hash | f_zero | f_space; // a A e E f g G
const flags_hex = f_minus | f_hash | f_zero; // o x X
const flags_int = f_minus | f_plus | f_zero | f_space; // d i
const flags_uint = f_minus | f_zero; // u
const flags_char = f_minus; // c p s

/// A flag byte's bit, 0 for any other byte.
const flag_bit = blk: {
    var t: [256]u8 = @splat(0);
    t['-'] = f_minus;
    t['0'] = f_zero;
    t['+'] = f_plus;
    t[' '] = f_space;
    t['#'] = f_hash;
    break :blk t;
};

/// The bytes Lua's `getformat` spans before the conversion: flags, digits, `.`.
const spec_byte = blk: {
    var t: [256]bool = @splat(false);
    for ("-+#0 123456789.") |c| t[c] = true;
    break :blk t;
};

/// Lua's `MAX_FORMAT - 10`: a spec whose flags, width, precision and
/// conversion run this long is "invalid format (too long)".
const max_spec_len = 22;

/// A spec as `sFormat` reads it, before its conversion is known: the
/// flags as bits, the width and precision, and whether its shape is one
/// `checkformat` can accept (each number at most two digits, nothing after).
const SpecRead = struct {
    flags: u8 = 0,
    width: usize = 0,
    precision: ?usize = null,
    well_formed: bool = true,
};

/// Lua's `checkformat` on a read spec: every flag in `allowed`, a
/// precision only where `precision_ok`. Reading every flag first and then
/// checking the set accepts exactly what Lua's `strspn` over the allowed
/// flags does: a disallowed flag fails either way.
inline fn checkSpec(vm: *Vm, sr: SpecRead, allowed: u8, precision_ok: bool, span: []const u8, conv: u8) anyerror!FormatSpec {
    if (!sr.well_formed or sr.flags & ~allowed != 0 or (sr.precision != null and !precision_ok))
        return specError(vm, .specification, span, conv);
    return .{
        .minus = sr.flags & f_minus != 0,
        .zero = sr.flags & f_zero != 0,
        .plus = sr.flags & f_plus != 0,
        .space = sr.flags & f_space != 0,
        .hash = sr.flags & f_hash != 0,
        .width = sr.width,
        .precision = sr.precision,
    };
}

/// Read up to two digits at `fmt[i.*]` (Lua's `get2digits`); a third makes
/// the spec malformed.
inline fn specNumber(fmt: []const u8, i: *usize, well_formed: *bool) usize {
    var n: usize = 0;
    var nd: usize = 0;
    while (i.* < fmt.len and fmt[i.*] >= '0' and fmt[i.*] <= '9') : (i.* += 1) {
        if (nd < 2) n = n * 10 + (fmt[i.*] - '0');
        nd += 1;
    }
    if (nd > 2) well_formed.* = false;
    return n;
}

/// Raise one of Lua's two spec errors, naming the spec as written
/// (`'%' ++ span ++ conv`; a format that ends inside a spec has no `conv`).
fn specError(vm: *Vm, comptime kind: enum { specification, conversion }, span: []const u8, conv: u8) anyerror {
    var buf: [96]u8 = undefined;
    const conv_s: []const u8 = if (conv == 0) "" else &.{conv};
    const msg = switch (kind) {
        .specification => std.fmt.bufPrint(&buf, "invalid conversion specification: '%{s}{s}'", .{ span, conv_s }),
        .conversion => std.fmt.bufPrint(&buf, "invalid conversion '%{s}{s}' to 'format'", .{ span, conv_s }),
    } catch unreachable; // span < max_spec_len
    return vm.raiseLocatedError(msg, 1);
}

/// `luaL_checknumber` for `format`'s float conversions (`arg` is present).
fn formatNumArg(vm: *Vm, arg: Value, argn: usize) anyerror!f64 {
    if (!arg.isNumber()) return vm.badArg(argn, "number", arg);
    return arg.toFloat();
}

/// C's `#` flag on `%f`/`%e`/`%g`: the body always has a decimal point, put
/// before the exponent when there is one.
fn forcePoint(dst: []u8, body: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, body, '.') != null) return body;
    const ei = std.mem.indexOfAny(u8, body, "eE") orelse body.len;
    @memcpy(dst[0..ei], body[0..ei]);
    dst[ei] = '.';
    @memcpy(dst[ei + 1 ..][0 .. body.len - ei], body[ei..]);
    return dst[0 .. body.len + 1];
}

/// C's `%a` magnitude body after the `0x`: a finite non-negative `mag` as
/// `h.hhhp±d`, the form glibc's `printf` writes. A normal number leads with
/// `1`, a subnormal with `0` and exponent -1022. With no `precision` the
/// 13 fraction digits lose their trailing zeros; with one (at most 13 here,
/// `hexFloatInto` pads past that) they round to nearest-even, and a carry
/// can raise the leading digit to `2`. `hash` keeps the point even with no
/// fraction digits.
fn hexFloatBody(dst: *[32]u8, mag: f64, precision: ?usize, upper: bool, hash: bool) []const u8 {
    std.debug.assert(precision == null or precision.? <= 13);
    const bits: u64 = @bitCast(mag);
    const exp_bits: u64 = (bits >> 52) & 0x7ff;
    var frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var lead: u8 = if (exp_bits == 0) 0 else 1;
    const e: i64 = if (exp_bits == 0) (if (frac == 0) 0 else -1022) else @as(i64, @intCast(exp_bits)) - 1023;

    var ndigits: usize = 13;
    if (precision) |pr| {
        if (pr < 13) {
            const shift: u6 = @intCast((13 - pr) * 4);
            const rem = frac & ((@as(u64, 1) << shift) - 1);
            const half = @as(u64, 1) << (shift - 1);
            frac >>= shift;
            // Ties go to even; with no fraction digits the last kept
            // digit is the leading one.
            const odd = if (pr == 0) lead & 1 == 1 else frac & 1 == 1;
            if (rem > half or (rem == half and odd)) frac += 1;
            if (frac >> @intCast(pr * 4) != 0) {
                frac &= (@as(u64, 1) << @intCast(pr * 4)) - 1;
                lead += 1;
            }
            ndigits = pr;
        }
    } else {
        while (ndigits > 0 and frac & 0xf == 0) : (ndigits -= 1) frac >>= 4;
    }

    const hex = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var w: usize = 0;
    dst[w] = '0' + lead;
    w += 1;
    if (ndigits > 0 or hash) {
        dst[w] = '.';
        w += 1;
    }
    var d = ndigits;
    while (d > 0) : (d -= 1) {
        dst[w] = hex[@intCast((frac >> @intCast((d - 1) * 4)) & 0xf)];
        w += 1;
    }
    const tail = std.fmt.bufPrint(dst[w..], "{c}{s}{d}", .{ @as(u8, if (upper) 'P' else 'p'), if (e < 0) "-" else "+", @abs(e) }) catch unreachable;
    return dst[0 .. w + tail.len];
}

/// `hexFloatBody` into `buf`, for any precision: past 13 digits the 13
/// exact ones are followed by zeros (up to 99 of them).
fn hexFloatInto(buf: []u8, mag: f64, precision: ?usize, upper: bool, hash: bool) []const u8 {
    var small: [32]u8 = undefined;
    const pr = precision orelse return copyInto(buf, hexFloatBody(&small, mag, null, upper, hash));
    if (pr <= 13) return copyInto(buf, hexFloatBody(&small, mag, pr, upper, hash));
    const body = hexFloatBody(&small, mag, 13, upper, hash);
    const p_at = std.mem.indexOfAny(u8, body, "pP").?;
    var w: usize = 0;
    @memcpy(buf[w..][0..p_at], body[0..p_at]);
    w += p_at;
    @memset(buf[w..][0 .. pr - 13], '0');
    w += pr - 13;
    @memcpy(buf[w..][0 .. body.len - p_at], body[p_at..]);
    return buf[0 .. w + body.len - p_at];
}

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Lua's `addquoted`: `"`, `\` and newline are backslash-escaped (a newline
/// as `\` plus a real newline), every other control byte as `\ddd`, padded
/// to three digits when a digit follows so it reads back the same.
fn addQuoted(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s, 0..) |c, k| {
        if (c == '"' or c == '\\' or c == '\n') {
            try out.append(gpa, '\\');
            try out.append(gpa, c);
        } else if (c < 0x20 or c == 0x7f) {
            var ebuf: [8]u8 = undefined;
            const digit_next = k + 1 < s.len and std.ascii.isDigit(s[k + 1]);
            const esc = if (digit_next)
                std.fmt.bufPrint(&ebuf, "\\{d:0>3}", .{c}) catch unreachable
            else
                std.fmt.bufPrint(&ebuf, "\\{d}", .{c}) catch unreachable;
            try out.appendSlice(gpa, esc);
        } else try out.append(gpa, c);
    }
    try out.append(gpa, '"');
}

/// Lua's `addliteral` (`%q`): a string quoted, an integer in decimal (the
/// minimum integer in hex, since `-9223372036854775808` reads back as a
/// float), a float in hex so it reads back exactly (inf as `1e9999`, NaN
/// as `(0/0)`), nil and booleans as their names. Nothing else has a literal.
fn addLiteral(vm: *Vm, out: *std.ArrayList(u8), arg: Value, argn: usize) anyerror!void {
    const gpa = vm.gpa;
    if (interp.strBytes(arg)) |s| return addQuoted(out, gpa, s);
    var buf: [48]u8 = undefined;
    switch (arg.tag) {
        .int => {
            const n = arg.asInt();
            const text = if (n == std.math.minInt(i64))
                "0x8000000000000000"
            else
                std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            try out.appendSlice(gpa, text);
        },
        .float => {
            const f = arg.asFloat();
            if (std.math.isNan(f)) return out.appendSlice(gpa, "(0/0)");
            if (std.math.isInf(f)) return out.appendSlice(gpa, if (f > 0) "1e9999" else "-1e9999");
            if (std.math.signbit(f)) try out.append(gpa, '-');
            try out.appendSlice(gpa, "0x");
            try out.appendSlice(gpa, hexFloatInto(&buf, @abs(f), null, false, false));
        },
        .nil => try out.appendSlice(gpa, "nil"),
        .boolean => try out.appendSlice(gpa, if (arg.asBool()) "true" else "false"),
        else => return vm.badArgReason(argn, "value has no literal form"),
    }
}

/// `string.format(fmt, ...)`, Lua 5.4's `str_format`: the conversions
/// `d i u c o x X a A f e E g G p q s` and `%%`. Each spec is checked against
/// its conversion's flags, with a width and precision of at most two digits
/// (`invalid conversion specification`); an unknown conversion is `invalid
/// conversion '%…' to 'format'`. Integer conversions take
/// `luaL_checkinteger` (an integral float is fine, 3.5 is not), `%s` takes
/// any value through `__tostring` as `tostring` does, and `%c` writes a code
/// point as UTF-8 (mahina's strings are UTF-8), padding by characters.
fn sFormat(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len < 1) return vm.badArg(1, "string", null);
    const fmt = interp.strBytes(args[0]) orelse return vm.badArg(1, "string", args[0]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    const gpa = vm.gpa;

    var argi: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        i += 1; // consume '%'
        if (i < fmt.len and fmt[i] == '%') {
            try out.append(gpa, '%');
            i += 1;
            continue;
        }

        // As in Lua, the argument is checked before the spec is read.
        if (argi >= args.len) return vm.badArgReason(argi + 1, "no value");
        const arg = args[argi];
        const argn = argi + 1;
        argi += 1;

        // Lua's `getformat`: the spec spans flag, digit and '.' bytes; the
        // byte after it is the conversion (none if the format ends there).
        // Read flags, width and precision in the same pass; whatever else
        // the span holds (`%5-d`, `%1.2.3f`) makes it malformed.
        const span_start = i;
        var sr: SpecRead = .{};
        while (i < fmt.len and flag_bit[fmt[i]] != 0) : (i += 1) sr.flags |= flag_bit[fmt[i]];
        sr.width = specNumber(fmt, &i, &sr.well_formed);
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            sr.precision = specNumber(fmt, &i, &sr.well_formed);
        }
        while (i < fmt.len and spec_byte[fmt[i]]) : (i += 1) sr.well_formed = false;
        const span = fmt[span_start..i];
        if (span.len + 1 >= max_spec_len) return vm.raiseLocatedError("invalid format (too long)", 1);
        const conv: u8 = if (i < fmt.len) fmt[i] else 0;
        i += 1;

        var nbuf: [512]u8 = undefined;
        switch (conv) {
            'd', 'i' => {
                const n = try vm.intArg(args, argn - 1);
                const spec = try checkSpec(vm, sr, flags_int, true, span, conv);
                const neg = n < 0;
                const un: u64 = @bitCast(n);
                const mag: u64 = if (neg) (~un +% 1) else un; // |n| in two's complement (safe at minInt)
                const digits = std.fmt.bufPrint(&nbuf, "{d}", .{mag}) catch unreachable;
                try emitNumeric(&out, gpa, signPrefix(neg, spec), digits, spec);
            },
            'u' => {
                const n = try vm.intArg(args, argn - 1);
                const spec = try checkSpec(vm, sr, flags_uint, true, span, conv);
                const digits = std.fmt.bufPrint(&nbuf, "{d}", .{@as(u64, @bitCast(n))}) catch unreachable;
                try emitNumeric(&out, gpa, "", digits, spec);
            },
            'o' => {
                const n = try vm.intArg(args, argn - 1);
                const spec = try checkSpec(vm, sr, flags_hex, true, span, conv);
                const digits = std.fmt.bufPrint(&nbuf, "{o}", .{@as(u64, @bitCast(n))}) catch unreachable;
                const prefix: []const u8 = if (spec.hash and !(digits.len == 1 and digits[0] == '0')) "0" else "";
                try emitNumeric(&out, gpa, prefix, digits, spec);
            },
            'x', 'X' => {
                const n = try vm.intArg(args, argn - 1);
                const spec = try checkSpec(vm, sr, flags_hex, true, span, conv);
                const u: u64 = @bitCast(n);
                const digits = if (conv == 'x')
                    std.fmt.bufPrint(&nbuf, "{x}", .{u}) catch unreachable
                else
                    std.fmt.bufPrint(&nbuf, "{X}", .{u}) catch unreachable;
                const prefix: []const u8 = if (spec.hash and u != 0)
                    (if (conv == 'x') "0x" else "0X")
                else
                    "";
                try emitNumeric(&out, gpa, prefix, digits, spec);
            },
            'c' => {
                const spec = try checkSpec(vm, sr, flags_char, false, span, conv);
                // S-B: `%c` emits the one-code-point string for this scalar value
                // (UTF-8), not a single truncated byte.
                const n = try vm.intArg(args, argn - 1);
                if (n < 0 or n > 0x10FFFF) return vm.badArgReason(argn, "value out of range");
                var tmp: [4]u8 = undefined;
                const ln = std.unicode.utf8Encode(@intCast(n), &tmp) catch return vm.badArgReason(argn, "value out of range");
                // Route through emitString so the width pads by one **character**
                // (code point), not by the UTF-8 byte length of the encoding.
                try emitString(&out, gpa, tmp[0..ln], 1, .{ .minus = spec.minus, .width = spec.width });
            },
            'a', 'A' => {
                const spec = try checkSpec(vm, sr, flags_float, true, span, conv);
                const f = try formatNumArg(vm, arg, argn);
                const upper = conv == 'A';
                const neg = std.math.signbit(f) and !std.math.isNan(f);
                const mag = @abs(f);
                var fspec = spec;
                fspec.precision = null;
                var pbuf: [3]u8 = undefined;
                var plen: usize = 0;
                const sign = signPrefix(neg, spec);
                @memcpy(pbuf[0..sign.len], sign);
                plen = sign.len;
                const body = if (std.math.isNan(mag) or std.math.isInf(mag)) blk: {
                    fspec.zero = false;
                    break :blk if (std.math.isNan(mag)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
                } else blk: {
                    pbuf[plen] = '0';
                    pbuf[plen + 1] = if (upper) 'X' else 'x';
                    plen += 2;
                    break :blk hexFloatInto(&nbuf, mag, spec.precision, upper, spec.hash);
                };
                try emitNumeric(&out, gpa, pbuf[0..plen], body, fspec);
            },
            'f', 'e', 'E', 'g', 'G' => {
                const f = try formatNumArg(vm, arg, argn);
                const spec = try checkSpec(vm, sr, flags_float, true, span, conv);
                const neg = std.math.signbit(f) and !std.math.isNan(f);
                const mag = if (neg) -f else f;
                const upper = conv == 'E' or conv == 'G';
                var rbuf: [float_body_max]u8 = undefined;
                var body: []const u8 = undefined;
                // C renders inf/nan as letters (no digits); the `0` flag is
                // ignored for them (space-pad only).
                var fspec = spec;
                fspec.precision = null;
                if (std.math.isNan(mag)) {
                    body = if (upper) "NAN" else "nan";
                    fspec.zero = false;
                } else if (std.math.isInf(mag)) {
                    body = if (upper) "INF" else "inf";
                    fspec.zero = false;
                } else {
                    switch (conv) {
                        'f' => body = decimal.fixed(&rbuf, mag, spec.precision orelse 6) catch
                            return error.TypeError,
                        'e', 'E' => body = decimal.scientific(&rbuf, mag, spec.precision orelse 6, if (upper) 'E' else 'e') catch
                            return error.TypeError,
                        else => { // 'g'/'G': C significant-digit form, default precision 6, min 1
                            const pr = blk: {
                                const pp = spec.precision orelse 6;
                                break :blk if (pp == 0) 1 else pp;
                            };
                            body = try renderG(&rbuf, mag, pr, if (upper) 'E' else 'e', spec.hash);
                        },
                    }
                    if (spec.hash) body = forcePoint(&nbuf, body);
                }
                try emitNumeric(&out, gpa, signPrefix(neg, spec), body, fspec);
            },
            'p' => {
                const spec = try checkSpec(vm, sr, flags_char, false, span, conv);
                // Lua prints the object's address; mahina its stable id, the
                // same one `tostring` shows. A value with no identity (a
                // number, boolean or nil) is "(null)", as in Lua.
                const text = switch (arg.tag) {
                    .heap_ref => std.fmt.bufPrint(&nbuf, "0x{x}", .{arg.asHeap().id}) catch unreachable,
                    .row_view => std.fmt.bufPrint(&nbuf, "0x{x}#{d}", .{ arg.rowViewParent().id, arg.rowViewRow() }) catch unreachable,
                    else => "(null)",
                };
                try emitString(&out, gpa, text, text.len, spec);
            },
            'q' => {
                if (span.len != 0) return vm.raiseLocatedError("specifier '%q' cannot have modifiers", 1);
                try addLiteral(vm, &out, arg, argn);
            },
            's' => {
                // `luaL_tolstring`: `__tostring` first, then the value's own text.
                const sobj: ?*const String = if (try vm.metaToString(arg)) |ts| strObjOf(ts) else strObjOf(arg);
                var tbuf: [128]u8 = undefined;
                const full = if (sobj) |so| so.bytes() else plainText(&tbuf, arg);
                if (span.len == 0) {
                    try out.appendSlice(gpa, full);
                    continue;
                }
                if (std.mem.indexOfScalar(u8, full, 0) != null) return vm.badArgReason(argn, "string contains zeros");
                const spec = try checkSpec(vm, sr, flags_char, true, span, conv);
                if (spec.precision == null and full.len >= 100) {
                    // As in Lua: too long to pad, so it is kept whole.
                    try out.appendSlice(gpa, full);
                    continue;
                }
                // S-B: `%.Ns` precision counts **code points**, not bytes.
                // doc 28 c2: a string's character count is its cached
                // `cp_len` (clamped precision via `charPrefixEndS`), so
                // emitString never rescans. The rendering of a value with no
                // string (a number, `table: 0x…`) is ASCII: chars ARE bytes.
                if (sobj) |so| {
                    if (spec.precision) |pr| {
                        try emitString(&out, gpa, full[0..charPrefixEndS(so, pr)], @min(pr, so.cpLen()), spec);
                    } else {
                        try emitString(&out, gpa, full, so.cpLen(), spec);
                    }
                } else {
                    const body = if (spec.precision) |pr| full[0..@min(pr, full.len)] else full;
                    try emitString(&out, gpa, body, body.len, spec);
                }
            },
            else => return specError(vm, .conversion, span, conv),
        }
    }

    return vm.heap.internValue(out.items);
}

/// `tostring`'s text for a value with no `__tostring` and no string of its
/// own: a number, nil, a boolean, or the `kind: 0x<id>` of an object.
fn plainText(buf: *[128]u8, v: Value) []const u8 {
    var w = io.Writer.fixed(buf);
    io.writeValue(&w, v) catch unreachable; // bounded: scalars and identity forms
    return w.buffered();
}

/// Emit a string field with width + `-` justification (the `0` flag is ignored
/// for `%s`, matching C/Lua). S-B: the field width is a **code-point** count
/// (consistent with `#s`), so a multibyte body pads by characters, not bytes.
/// `body_cp` is that character count, supplied by the CALLER (doc 28 c2): every
/// call site already knows it — the cached `cp_len`, a clamped precision, one
/// for `%c`, or `body.len` for an ASCII-by-construction coercion — so the old
/// per-field O(len) `cpCount` rescan is gone. Asserted against the rescan in
/// safe builds.
fn emitString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, body: []const u8, body_cp: usize, spec: FormatSpec) !void {
    if (std.debug.runtime_safety) std.debug.assert(body_cp == cpCount(body));
    const pad: usize = if (spec.width > body_cp) spec.width - body_cp else 0;
    if (spec.minus) {
        try out.appendSlice(gpa, body);
        try appendN(out, gpa, ' ', pad);
    } else {
        try appendN(out, gpa, ' ', pad);
        try out.appendSlice(gpa, body);
    }
}

// ---------------------------------------------------------------------------
// Pattern matching — find / match / gmatch / gsub (engine in pattern.zig)
// ---------------------------------------------------------------------------
//
// The matcher itself is pure (`pattern.MatchState`); these wrappers handle the
// `Value`/heap/interning side and the multi-result ABI. Every capture is built
// into a local buffer first (never directly into `out`, which aliases `args`),
// then copied — so the aliasing contract is satisfied trivially. Capture index
// resolution and the `gsub` advance loop follow LuaJIT's `lib_string.c`.

/// Local result buffer: 2 (find's start/end) + up to `max_captures`.
const ResultBuf = [pattern.max_captures + 2]Value;

/// Resolve Lua's `init` argument (a 1-based **character** index, S-D) to a 0-based
/// **byte** offset into `s`, or `null` if it lands past the end (→ no match).
/// Negative counts back from the end in characters; `0`/positive are 1-based; the
/// result lands on a code-point boundary. `pos == cp_len + 1` (one past the last
/// char) maps to `s.len` — the empty-match-at-end position. Takes the `*String`
/// (doc 28 c2): the character length is the cached `cp_len` (this was an O(len)
/// `cpCount` scan per find/match call) and an ASCII subject converts by identity.
pub fn resolveInit(init_raw: i64, s: *const String) ?usize {
    const clen = s.cpLen();
    var pos = posRelat(init_raw, clen); // 1-based char position (may be 0)
    if (pos < 1) pos = 1;
    if (pos > @as(i64, @intCast(clen)) + 1) return null; // start past end+1
    return charByteOffsetS(s, @intCast(pos));
}

/// Convert capture `i` of a completed match to a `Value`, mirroring
/// `push_onecapture`: index `i >= level` is only valid at `i == 0` (the whole
/// match, taken from `whole`); a position capture becomes a 1-based integer; a
/// string capture is interned. `subj` is the subject `String` OBJECT whose bytes
/// `ms.src` views (doc 28 c2): a position capture's byte→char conversion was an
/// O(prefix) `cpCount` scan per capture; with the object it reads the cached
/// ASCII bit and collapses to `+1` on the common all-ASCII subject.
fn captureValue(vm: *Vm, ms: *const pattern.MatchState, subj: *const String, i: usize, whole: ?[2]usize) anyerror!Value {
    std.debug.assert(ms.src.ptr == subj.bytes().ptr and ms.src.len == subj.len);
    if (i >= ms.level) {
        if (i == 0) if (whole) |w| return vm.heap.internValue(ms.src[w[0]..w[1]]);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "invalid capture index %{d}", .{i + 1}) catch unreachable;
        return vm.raiseLocatedError(msg, 1);
    }
    const cap = ms.captures[i];
    if (cap.len == pattern.cap_unfinished) return vm.raiseLocatedError("unfinished capture", 1);
    if (cap.len == pattern.cap_position) return Value.int(@intCast(byteToCharS(subj, cap.init)));
    const l: usize = @intCast(cap.len);
    return vm.heap.internValue(ms.src[cap.init .. cap.init + l]);
}

/// Raise a matcher error as the message Lua gives for it.
fn raisePatternError(vm: *Vm, ms: *const pattern.MatchState, e: pattern.Error) interp.Error {
    var buf: [64]u8 = undefined;
    return vm.raiseLocatedError(pattern.message(e, ms, &buf), 1);
}

/// Number of capture results a match produces (`push_captures`'s `nlevels`).
fn numCaptures(ms: *const pattern.MatchState, whole: ?[2]usize) usize {
    if (ms.level == 0) return if (whole != null) 1 else 0;
    return ms.level;
}

/// Write every capture value into `buf`, returning the count.
fn writeCaptures(vm: *Vm, ms: *const pattern.MatchState, subj: *const String, whole: ?[2]usize, buf: []Value) anyerror!usize {
    const n = numCaptures(ms, whole);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = try captureValue(vm, ms, subj, i, whole);
    return n;
}

// -- find -------------------------------------------------------------------

/// Core of `string.find(s, pat [, init [, plain]])`. Writes results into `buf`
/// and returns the count: `(start, end, captures...)` on a match, or a single
/// `nil` on no match.
fn findCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const sobj = try strObjArg(vm, args, 0);
    const s = sobj.bytes();
    const pat = try strArg(vm, args, 1);
    const st = resolveInit(try vm.optIntArg(args, 2, 1), sobj) orelse {
        buf[0] = Value.nil();
        return 1;
    };
    const plain = args.len >= 4 and args[3].isTruthy();

    if (plain or !pattern.hasSpecials(pat)) {
        // Plain substring search (empty needle matches at `st`). Byte offsets are
        // converted to 1-based character indices at the seam (S-D).
        if (pat.len == 0) {
            buf[0] = Value.int(@intCast(byteToCharS(sobj, st)));
            buf[1] = Value.int(@intCast(byteToCharS(sobj, st) - 1));
            return 2;
        }
        if (st <= s.len) {
            // A plain substring of valid UTF-8 lands on a code-point boundary.
            if (byte_ops.find(s, st, pat)) |q| {
                buf[0] = Value.int(@intCast(byteToCharS(sobj, q)));
                buf[1] = Value.int(@intCast(cpCountPrefixS(sobj, q + pat.len)));
                return 2;
            }
        }
        buf[0] = Value.nil();
        return 1;
    }

    // Doc 30 P3: the shared locate core — the same loop the recorder's
    // outcome computation and the native `smatch` shim run.
    var ms = pattern.MatchState.init(s, pat);
    if (pattern.locateMatch(&ms, st, true) catch |e| return raisePatternError(vm, &ms, e)) |span| {
        buf[0] = Value.int(@intCast(byteToCharS(sobj, span.start)));
        buf[1] = Value.int(@intCast(cpCountPrefixS(sobj, span.end)));
        const nc = try writeCaptures(vm, &ms, sobj, null, buf[2..]);
        return 2 + nc;
    }
    buf[0] = Value.nil();
    return 1;
}

fn sFind1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var buf: ResultBuf = undefined;
    _ = try findCore(vmOf(ctx), args, &buf);
    return buf[0];
}

fn sFindN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    var buf: ResultBuf = undefined;
    const n = try findCore(vmOf(ctx), args, &buf);
    return copyOut(buf[0..n], out);
}

// -- match ------------------------------------------------------------------

/// Core of `string.match(s, pat [, init])`: the captures (or the whole match if
/// the pattern has none), or a single `nil`.
fn matchCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const sobj = try strObjArg(vm, args, 0);
    const s = sobj.bytes();
    const pat = try strArg(vm, args, 1);
    const st = resolveInit(try vm.optIntArg(args, 2, 1), sobj) orelse {
        buf[0] = Value.nil();
        return 1;
    };

    // Doc 30 P3: the shared locate core.
    var ms = pattern.MatchState.init(s, pat);
    if (pattern.locateMatch(&ms, st, true) catch |e| return raisePatternError(vm, &ms, e)) |span| {
        return try writeCaptures(vm, &ms, sobj, .{ span.start, span.end }, buf);
    }
    buf[0] = Value.nil();
    return 1;
}

fn sMatch1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var buf: ResultBuf = undefined;
    _ = try matchCore(vmOf(ctx), args, &buf);
    return buf[0];
}

fn sMatchN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    var buf: ResultBuf = undefined;
    const n = try matchCore(vmOf(ctx), args, &buf);
    return copyOut(buf[0..n], out);
}

// -- gmatch -----------------------------------------------------------------
//
// `gmatch(s, pat)` returns the generic-for triple `(@gmatch_iter, state, nil)`,
// where `state` is a plain table `{ [1]=s, [2]=pat, [3]=pos }` the iterator
// mutates — serializable and keyframe-restorable, where a closure-with-upvalue
// would not be. (This makes `gmatch` a 3-tuple rather than Lua's lone closure: a
// deliberate "Lua-shaped" divergence, invisible to `for w in gmatch(...)`.)

fn sGmatchN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    _ = try strArg(vm, args, 0); // type-check subject
    _ = try strArg(vm, args, 1); // type-check pattern
    const iter = vm.libNative(.gmatch_iter);
    const state = try vm.heap.newTable();
    try state.set(vm.gpa, Value.int(1), args[0]); // subject string Value
    try state.set(vm.gpa, Value.int(2), args[1]); // pattern string Value
    try state.set(vm.gpa, Value.int(3), Value.int(0)); // 0-based scan offset
    const triple = [3]Value{ iter, Value.heap(&state.header), Value.nil() };
    return copyOut(&triple, out);
}

fn sGmatch1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    // Degenerate single-result projection: just the iterator (state is lost).
    const vm = vmOf(ctx);
    _ = try strArg(vm, args, 0);
    _ = try strArg(vm, args, 1);
    return vm.libNative(.gmatch_iter);
}

/// `@gmatch_iter(state)` — LuaJIT's `gmatch_aux`: scan forward from the stored
/// position for the next match, advance the position (forcing progress past an
/// empty match), and return the captures; 0 results when exhausted.
fn gmatchAuxCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const st = try tableArg(vm, args, 0);
    // B03-shape fast path (the tier-0 twin of the JIT callout's layout
    // check, doc 30 §6): the compiler-built state `{[1]=s,[2]=pat,[3]=pos}`
    // is an in-lane `.value` array covering keys 1..3, and the cursor
    // read→match→write round-trip is this iterator's loop-carried chain —
    // resolve the three slots directly and write the cursor back
    // allocation-free, skipping three generic `getInt` calls and the
    // generic `Table.set` (normalizeKey/NaN/widen/migrate) per token.
    // Semantics are identical by construction: for an in-array key `getInt`
    // IS the lane read (never the hash), `inLaneValueAt(3)` non-null
    // implies keys 1..2 are in-array too (asize > 3), and any layout the
    // lane can't answer for — user-built state, hash-resident keys,
    // narrowed lane, grid — falls back to the generic reads/write.
    const in_lane = st.inLaneValueAt(3);
    // Recover the subject as its `String` OBJECT (doc 28 c2), not a degraded
    // byte slice — capture conversion downstream wants the cached ASCII bit.
    const sobj = strObjOf(if (in_lane != null) st.inLaneValueAt(1).? else st.getInt(1)) orelse return error.TypeError;
    const s = sobj.bytes();
    const pat = interp.strBytes(if (in_lane != null) st.inLaneValueAt(2).? else st.getInt(2)) orelse return error.TypeError;
    const pos_v = in_lane orelse st.getInt(3);
    const src: usize = if (pos_v.isInt() and pos_v.asInt() >= 0) @intCast(pos_v.asInt()) else 0;

    // Doc 30 P3: the shared locate core, gmatch flavor (no anchor consumption
    // — a leading '^' stays a literal item, exactly as this always ran).
    var ms = pattern.MatchState.init(s, pat);
    if (pattern.locateMatch(&ms, src, false) catch |e| return raisePatternError(vm, &ms, e)) |span| {
        // Ensure progress on an empty match by stepping a whole code point
        // (S-D); `@max(…, 1)` guarantees termination at end-of-string.
        const newpos = if (span.end == span.start) span.end + @max(ms.seqLen(span.end), 1) else span.end;
        // In-lane cursor write; the generic set covers a non-int cell (a
        // user overwrote `state[3]`) and the no-fast-path layouts. The state
        // is a table the caller passed: it may be frozen (doc 76 §5).
        if (st.isReadonly()) return vm.readonlyError();
        if (in_lane == null or !st.setInLaneValueInt(3, @intCast(newpos)))
            try st.set(vm.gpa, Value.int(3), Value.int(@intCast(newpos)));
        return try writeCaptures(vm, &ms, sobj, .{ span.start, span.end }, buf);
    }
    return 0; // exhausted
}

fn sGmatchAux1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var buf: ResultBuf = undefined;
    const n = try gmatchAuxCore(vmOf(ctx), args, &buf);
    return if (n == 0) Value.nil() else buf[0];
}

fn sGmatchAuxN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    var buf: ResultBuf = undefined;
    const n = try gmatchAuxCore(vmOf(ctx), args, &buf);
    return copyOut(buf[0..n], out);
}

// -- doc 30: the pattern-callout cores (heap-only; no *Vm) ------------------
//
// One core per JIT op, shared with the C-ABI shims in `stralloc.zig` and
// (at record time) the trace recorder's outcome computation. All of them are
// allocation-free except `scapStrCore` (≤1 `Heap.link` via `intern`). Errors
// never cross the ABI: every `pattern.Error` and every protocol failure is a
// distinct negative status (doc 30 M03) — the trace side-exits and tier-0's
// replay of the iteration raises or branches exactly as the program dictates.

comptime {
    // The scratch geometry in gc.zig hardcodes 32 (gc deliberately does not
    // import stdlib); pin the cross-module agreement here.
    std.debug.assert(gc.MatchScratch.n_slots == 3 + pattern.max_captures + 1);
    std.debug.assert(gc.MatchScratch.slot_next_pos == 3 + pattern.max_captures);
}

/// Doc 30 M03: the negative status channel. `>= 1` is `sfindp`'s matched
/// char index; `0` is the match ops' OK; everything below is a side-exit.
pub const MatchStatus = struct {
    pub const ok: i64 = 0;
    pub const no_match: i64 = -1;
    pub const malformed: i64 = -2;
    pub const invalid_capture: i64 = -3;
    pub const too_many_captures: i64 = -4;
    pub const too_complex: i64 = -5;
    /// sgmatch: `state[2]` is not the record-time pattern (identity check).
    pub const pattern_mismatch: i64 = -6;
    /// sgmatch: `state[3]` is not an in-lane `.value` int cell (B03), or the
    /// `sgm_setpos` re-verification failed.
    pub const bad_layout: i64 = -7;
    /// A runtime type the tier-0 wrapper would raise on (non-string subject
    /// or pattern, non-table state).
    pub const bad_type: i64 = -8;
    /// `resolveInit` → null (init past end+1): tier-0 returns nil.
    pub const bad_init: i64 = -9;
};

fn matchStatusOf(e: pattern.Error) i64 {
    return switch (e) {
        error.PatternEndsWithEscape,
        error.MissingBracket,
        error.MissingBalanceArgs,
        error.MissingFrontierSet,
        error.InvalidPatternCapture,
        => MatchStatus.malformed,
        error.InvalidCaptureIndex => MatchStatus.invalid_capture,
        error.TooManyCaptures => MatchStatus.too_many_captures,
        error.PatternTooComplex => MatchStatus.too_complex,
    };
}

/// Write a completed match into the heap's match scratch (doc 30 §3 layout).
/// `char_ends` selects the find-flavor `slot_start`/`slot_end` character
/// indices (an O(prefix) count on a non-ASCII subject — gmatch's tier-0
/// never computes them, so its flavor skips them and those slots stay stale).
fn fillMatchScratch(heap: *gc.Heap, ms: *const pattern.MatchState, sobj: *const String, span: pattern.Span, char_ends: bool) i64 {
    const sc = &heap.match_scratch;
    sc.subj = @intFromPtr(sobj);
    if (char_ends) {
        sc.words[2 * gc.MatchScratch.slot_start] = byteToCharS(sobj, span.start);
        sc.words[2 * gc.MatchScratch.slot_end] = cpCountPrefixS(sobj, span.end);
    }
    sc.words[2 * gc.MatchScratch.slot_whole] = span.start;
    sc.words[2 * gc.MatchScratch.slot_whole + 1] = span.end - span.start;
    var i: usize = 0;
    while (i < ms.level) : (i += 1) {
        const cap = ms.captures[i];
        const w = 2 * (gc.MatchScratch.slot_cap0 + i);
        if (cap.len == pattern.cap_unfinished) return MatchStatus.malformed;
        if (cap.len == pattern.cap_position) {
            // Int slot: the 1-based char position (`push_onecapture`).
            sc.words[w] = byteToCharS(sobj, cap.init);
            sc.words[w + 1] = 0;
        } else {
            // Span slot: (byte_init, byte_len) into `subj`.
            sc.words[w] = cap.init;
            sc.words[w + 1] = @intCast(cap.len);
        }
    }
    return MatchStatus.ok;
}

/// Doc 30 `smatch` core (find/match flavor): locate from `init_raw` honoring
/// a leading '^', fill scratch. Allocation-free; status result.
pub fn smatchCore(heap: *gc.Heap, sobj: *const String, init_raw: i64, pat: []const u8) i64 {
    const st = resolveInit(init_raw, sobj) orelse return MatchStatus.bad_init;
    var ms = pattern.MatchState.init(sobj.bytes(), pat);
    const span = (pattern.locateMatch(&ms, st, true) catch |e| return matchStatusOf(e)) orelse
        return MatchStatus.no_match;
    return fillMatchScratch(heap, &ms, sobj, span, true);
}

/// Doc 30 `sfindp` core: plain-substring find (find's no-specials bypass).
/// Returns the 1-based char index of the match start (>= 1) or a negative
/// status; the end index is recorder arithmetic (`start + cpLen(pat) - 1`,
/// konst-folded — the empty pattern's `(st, st-1)` shape falls out of the
/// same formula with `cpLen == 0`). Heap-free: no scratch, no allocation.
pub fn sfindPlainCore(sobj: *const String, init_raw: i64, pat: []const u8) i64 {
    const st = resolveInit(init_raw, sobj) orelse return MatchStatus.bad_init;
    const s = sobj.bytes();
    if (pat.len == 0) return @intCast(byteToCharS(sobj, st));
    if (st <= s.len) {
        // A plain substring of valid UTF-8 lands on a code-point boundary.
        if (byte_ops.find(s, st, pat)) |q| return @intCast(byteToCharS(sobj, q));
    }
    return MatchStatus.no_match;
}

/// Doc 30 `sgmatch` core (§6): one composite iterator step. READ-ONLY on the
/// state (round-2 B01 — the pos advance is `sgm_setpos`'s deferred store):
/// verifies the pattern identity against the record-time expectation
/// (round-2 B02) and the B03 slot-3 layout, then locates from the stored pos
/// and fills scratch including `slot_next_pos` (the empty-match bump rule,
/// verbatim from `gmatchAuxCore`).
pub fn sgmatchCore(heap: *gc.Heap, state: *Table, expected_pat: *const String) i64 {
    const sobj = strObjOf(state.getInt(1)) orelse return MatchStatus.bad_type;
    const pv = state.getInt(2);
    if (!pv.isHeap() or pv.asHeap() != &expected_pat.header) return MatchStatus.pattern_mismatch;
    const pos = state.inLaneValueIntCell(3) orelse return MatchStatus.bad_layout;
    // Tier-0 clamps a negative pos to 0; that shape is only reachable by a
    // user poking a hand-built state, so fail closed instead of mirroring.
    if (pos < 0) return MatchStatus.bad_layout;
    const s = sobj.bytes();
    const upos: usize = @intCast(pos);
    var ms = pattern.MatchState.init(s, expected_pat.bytes());
    const span = (pattern.locateMatch(&ms, upos, false) catch |e| return matchStatusOf(e)) orelse
        return MatchStatus.no_match; // exhausted → the for-in loop's end
    const newpos = if (span.end == span.start) span.end + @max(ms.seqLen(span.end), 1) else span.end;
    const rc = fillMatchScratch(heap, &ms, sobj, span, false);
    if (rc != MatchStatus.ok) return rc;
    heap.match_scratch.words[2 * gc.MatchScratch.slot_next_pos] = newpos;
    return MatchStatus.ok;
}

/// Doc 30 `scap_str` core: intern the byte span in scratch slot `slot`.
/// ≤1 `Heap.link` (intern hit: 0, miss: 1). Fails link-free either way (the
/// id stream stays clean): `error.OutOfMemory` from the intern, or
/// `error.StaleScratch` from the defense-in-depth checks below — the stralloc
/// shim's OOM and decline arms respectively.
pub fn scapStrCore(heap: *gc.Heap, slot: usize) (error{StaleScratch} || std.mem.Allocator.Error)!*String {
    std.debug.assert(slot < gc.MatchScratch.n_slots);
    const sc = &heap.match_scratch;
    // Defense in depth (doc 30 c3): a legitimately recorded trace's scap
    // always follows a status-checked smatch/sgmatch in the SAME iteration,
    // so the scratch is this fill's. But "never trust the IR" — a hand-built
    // or corrupted trace could project from virgin scratch (subj == 0) or a
    // slot the latest fill didn't touch (a stale span against a shorter
    // subject). Both collapse to the decline side-exit arm: no link happened,
    // the id stream is clean, tier-0 replays the iteration and produces the
    // real value (or raise) itself.
    if (sc.subj == 0) return error.StaleScratch;
    const sobj: *const String = @ptrFromInt(sc.subj);
    const init: usize = @intCast(sc.words[2 * slot]);
    const len: usize = @intCast(sc.words[2 * slot + 1]);
    const b = sobj.bytes();
    if (init > b.len or len > b.len - init) return error.StaleScratch;
    return heap.intern(b[init .. init + len]);
}

// -- gsub -------------------------------------------------------------------

/// Append a `Value` (string or number) as text to `out`.
fn appendValueText(vm: *Vm, out: *std.ArrayList(u8), v: Value) anyerror!void {
    if (interp.strBytes(v)) |b| {
        try out.appendSlice(vm.gpa, b);
        return;
    }
    var nb: [64]u8 = undefined;
    try out.appendSlice(vm.gpa, try interp.coerceConcat(v, &nb));
}

/// `add_s`: expand a string/number replacement, resolving `%0` (whole match),
/// `%1`–`%9` (captures) and `%%`. A `%` before anything else, or at the end,
/// is an error, as in Lua 5.4.
fn addReplString(vm: *Vm, out: *std.ArrayList(u8), ms: *const pattern.MatchState, subj: *const String, repl: []const u8, s_off: usize, e_off: usize) anyerror!void {
    var i: usize = 0;
    while (i < repl.len) : (i += 1) {
        const c = repl[i];
        if (c != '%') {
            try out.append(vm.gpa, c);
            continue;
        }
        i += 1;
        const d = if (i < repl.len) repl[i] else 0;
        if (d == '%') {
            try out.append(vm.gpa, '%');
        } else if (!std.ascii.isDigit(d)) {
            return vm.raiseLocatedError("invalid use of '%' in replacement string", 1);
        } else if (d == '0') {
            try out.appendSlice(vm.gpa, ms.src[s_off..e_off]); // whole match
        } else {
            const v = try captureValue(vm, ms, subj, d - '1', .{ s_off, e_off });
            try appendValueText(vm, out, v);
        }
    }
}

/// `add_value` for a table replacement: look up `repl[firstCapture]`; a
/// nil/false result keeps the original text.
fn addReplTable(vm: *Vm, out: *std.ArrayList(u8), ms: *const pattern.MatchState, subj: *const String, repl: *Table, s_off: usize, e_off: usize) anyerror!void {
    const key = try captureValue(vm, ms, subj, 0, .{ s_off, e_off });
    const v = repl.get(key);
    if (!v.isTruthy()) {
        try out.appendSlice(vm.gpa, ms.src[s_off..e_off]); // keep original
        return;
    }
    if (interp.strBytes(v) != null or v.isNumber()) {
        try appendValueText(vm, out, v);
        return;
    }
    return invalidReplacement(vm, v.typeNameId());
}

/// The captures a function replacement is called with: the explicit ones, or
/// the whole match when the pattern has none. Written to `caps`; returns how
/// many.
///
/// GC: `captureValue` interns the capture strings with no intervening
/// safepoint, and the caller puts them in rooted registers (or `callValue`
/// copies them into the rooted VM stack) before anything can collect.
fn functionCaps(vm: *Vm, ms: *const pattern.MatchState, subj: *const String, s_off: usize, e_off: usize, caps: *[pattern.max_captures]Value) anyerror!usize {
    const ncap: usize = if (ms.level > 0) ms.level else 1;
    var k: usize = 0;
    while (k < ncap) : (k += 1) caps[k] = try captureValue(vm, ms, subj, k, .{ s_off, e_off });
    return ncap;
}

/// `add_value` for a function replacement, given what `repl` returned: a
/// nil/false result keeps the original text `matched`; a string/number
/// substitutes; any other type is an invalid replacement.
fn addFunctionResult(vm: *Vm, out: *std.ArrayList(u8), matched: []const u8, rv: Value) anyerror!void {
    if (!rv.isTruthy()) {
        try out.appendSlice(vm.gpa, matched); // keep original
        return;
    }
    if (interp.strBytes(rv) != null or rv.isNumber()) {
        try appendValueText(vm, out, rv);
        return;
    }
    return invalidReplacement(vm, rv.typeNameId());
}

/// Lua's `add_value` error for a table or function replacement's truthy
/// value that is neither a string nor a number. Takes the type, not the
/// value: passing the `Value` made `gsubCore` copy each looked-up value
/// through a stack slot, a store-forwarding stall that cost a table
/// replacement ~9% in cycles.
noinline fn invalidReplacement(vm: *Vm, type_name: Value.TypeName) anyerror {
    @branchHint(.cold);
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid replacement value (a {s})", .{@tagName(type_name)}) catch unreachable;
    return vm.raiseLocatedError(msg, 1);
}

/// What `gsub` does with a match, by the kind of its replacement. The loop
/// is specialised on it, so the string and table paths carry nothing of the
/// function path's state.
const GsubKind = enum { string, table, number, function };

/// A `gsub` call's operands, once classified.
const GsubJob = struct {
    sobj: *const String,
    pat: []const u8,
    /// The replacement as given: the callee of a `.function`, the number of
    /// a `.number`.
    repl: Value,
    table: ?*Table,
    text: ?[]const u8,
};

/// Where a `gsub` stands between two replacement calls (doc 68 §7.4): the
/// source position, matches counted, the limit, and the end of the match a
/// pending call answers. The matcher's own state is rebuilt per match; the
/// captures are the call's arguments. The output so far is a `ByteBuf`.
const GsubState = struct {
    src: usize = 0,
    count: i64 = 0,
    max_n: i64,
    /// The end of the match the replacement call in flight answers, or -1.
    pending_end: i64 = -1,

    const word_count = 4;
    comptime {
        std.debug.assert(word_count <= native_act.max_words);
    }

    fn toWords(self: GsubState) [native_act.max_words]i64 {
        var w: [native_act.max_words]i64 = @splat(0);
        w[0] = @intCast(self.src);
        w[1] = self.count;
        w[2] = self.max_n;
        w[3] = self.pending_end;
        return w;
    }

    fn fromWords(w: *const [native_act.max_words]i64) GsubState {
        return .{ .src = @intCast(w[0]), .count = w[1], .max_n = w[2], .pending_end = w[3] };
    }

    fn store(self: GsubState, regs: RegWindow, at: usize) void {
        const w = self.toWords();
        for (w[0..word_count], at..) |x, r| regs.setInt(r, x);
    }

    fn load(regs: RegWindow, at: usize) GsubState {
        var w: [native_act.max_words]i64 = @splat(0);
        for (w[0..word_count], at..) |*x, r| x.* = regs.get(r).asInt();
        return fromWords(&w);
    }
};

/// The `gsub` advance loop (`str_gsub`), from `st` until the subject is done
/// (null) or, for a function replacement, a match needs its call: then the
/// captures are in `caps`, `st` stands at the match with its end pending, and
/// the capture count is returned. `answer` is what that call returned, when
/// resuming. Both the Zig native and its activation (`gsubStep`) run it, so
/// there is one definition of how a match advances.
inline fn gsubLoop(comptime kind: GsubKind, vm: *Vm, job: *const GsubJob, out: *std.ArrayList(u8), st: *GsubState, caps: *[pattern.max_captures]Value, answer: ?Value) anyerror!?usize {
    const s = job.sobj.bytes();
    var ms = pattern.MatchState.init(s, job.pat);
    var pp: usize = 0;
    const anchor = job.pat.len > 0 and job.pat[0] == '^';
    if (anchor) pp = 1;

    var src = st.src;
    var count = st.count;
    const max_n = st.max_n;
    var answered: ?usize = null;
    if (answer != null) {
        comptime std.debug.assert(kind == .function);
        std.debug.assert(st.pending_end >= 0);
        answered = @intCast(st.pending_end);
    }
    while (answered != null or count < max_n) {
        var e: usize = undefined;
        if (answered) |pe| {
            // The call for the match at `src..pe` has answered.
            answered = null;
            e = pe;
            try addFunctionResult(vm, out, s[src..e], answer.?);
        } else {
            ms.reset();
            const e_opt = ms.match(src, pp) catch |err| return raisePatternError(vm, &ms, err);
            if (e_opt) |m_end| {
                count += 1;
                e = m_end;
                switch (kind) {
                    .table => try addReplTable(vm, out, &ms, job.sobj, job.table.?, src, e),
                    .function => {
                        const ncap = try functionCaps(vm, &ms, job.sobj, src, e, caps);
                        st.* = .{ .src = src, .count = count, .max_n = max_n, .pending_end = @intCast(e) };
                        return ncap;
                    },
                    .string => try addReplString(vm, out, &ms, job.sobj, job.text.?, src, e),
                    // numeric replacement: coerce to its text, no captures.
                    .number => try appendValueText(vm, out, job.repl),
                }
            } else if (src < s.len) {
                const w = ms.seqLen(src);
                try out.appendSlice(vm.gpa, s[src .. src + w]);
                src += w;
                if (anchor) break;
                continue;
            } else break;
        }
        if (e > src) {
            src = e;
        } else if (src < s.len) {
            // Empty match: copy the unmatched code point whole (S-D) so we
            // never splice a partial UTF-8 sequence.
            const w = ms.seqLen(src);
            try out.appendSlice(vm.gpa, s[src .. src + w]);
            src += w;
        } else break;
        if (anchor) break;
    }
    try out.appendSlice(vm.gpa, s[src..]); // tail
    st.* = .{ .src = src, .count = count, .max_n = max_n };
    return null;
}

/// Core of `string.gsub(s, pat, repl [, n])` → `(result, count)`. `repl` may be a
/// string/number, a table, or a function. A function replacement runs in Zig
/// until a match needs its call, then becomes an activation (doc 68 §7.4): it
/// hands its output so far, as a `ByteBuf`, and its state to `error.ActivateNative`'s
/// handler, so the calls are ordinary frames a coroutine can yield in.
fn gsubCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const sobj = try strObjArg(vm, args, 0);
    const pat = try strArg(vm, args, 1);
    if (args.len < 3) return vm.badArg(3, "string/function/table", null);
    const repl = args[2];

    // Classify the replacement up front (bad kinds error before any work).
    const repl_table: ?*Table = if (repl.isHeap() and repl.heapType() == .table)
        Table.fromHeader(repl.asHeap())
    else
        null;
    const is_fn = repl_table == null and repl.isHeap() and
        (repl.heapType() == .function or repl.heapType() == .native);
    if (repl_table == null and !is_fn and interp.strBytes(repl) == null and !repl.isNumber())
        return vm.badArg(3, "string/function/table", repl);
    const repl_str: ?[]const u8 = if (repl_table == null and !is_fn)
        (interp.strBytes(repl) orelse null)
    else
        null;

    const max_n: i64 = if (args.len >= 4 and !args[3].isNil())
        try vm.optIntArg(args, 3, 0)
    else
        @as(i64, @intCast(sobj.len + 1));

    const job: GsubJob = .{ .sobj = sobj, .pat = pat, .repl = repl, .table = repl_table, .text = repl_str };
    var st: GsubState = .{ .max_n = max_n };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var caps: [pattern.max_captures]Value = undefined;

    if (is_fn) {
        if (try gsubLoop(.function, vm, &job, &out, &st, &caps, null) != null) {
            // A match needs its call. Rewind to before it: the activation's
            // first step finds the match again (one extra match per `gsub`,
            // not per match), because its captures are the call's
            // arguments and can't travel in a seed.
            st.count -= 1;
            st.pending_end = -1;
            const bb = try vm.heap.newByteBuf(out);
            out = .empty; // the buffer owns it now
            vm.act_seed = .{ .kind = .gsub, .words = st.toWords(), .values = .{ Value.heap(&bb.header), Value.nil() } };
            return error.ActivateNative;
        }
    } else if (repl_table != null) {
        _ = try gsubLoop(.table, vm, &job, &out, &st, &caps, null);
    } else if (repl_str != null) {
        _ = try gsubLoop(.string, vm, &job, &out, &st, &caps, null);
    } else {
        _ = try gsubLoop(.number, vm, &job, &out, &st, &caps, null);
    }
    buf[0] = try vm.heap.internValue(out.items);
    buf[1] = Value.int(st.count);
    return 2;
}

/// The operands of a `gsub` that has become an activation, as its registers
/// hold them: `gsubCore` checked them before it escalated.
fn gsubJobOf(s: Value, pat: Value, repl: Value) GsubJob {
    return .{
        .sobj = String.fromHeader(s.asHeap()),
        .pat = interp.strBytes(pat).?,
        .repl = repl,
        .table = null,
        .text = null,
    };
}

/// One step of `gsub`'s activation (doc 68 §7.4): `R[0..4]` are its
/// arguments, `R[4]` the output buffer (nil before the first step, which
/// takes the native's seed), then the state. Runs to the next match that
/// needs its call, laid out in the call area as the callee and the
/// captures, or to the end, leaving the result and the count there.
pub fn gsubStep(vm: *Vm, regs: RegWindow) interp.Error!native_act.Next {
    const at = native_act.wordReg(.gsub);
    const c = native_act.callReg(.gsub);
    var st: GsubState = undefined;
    var answer: ?Value = null;
    if (regs.get(at).isNil()) {
        const seed = vm.takeActSeed();
        std.debug.assert(seed.kind == .gsub);
        st = GsubState.fromWords(&seed.words);
        regs.set(at, seed.values[0]);
    } else {
        st = GsubState.load(regs, at + 1);
        answer = regs.get(c);
    }
    const bb = ByteBuf.fromHeader(regs.get(at).asHeap());
    const job = gsubJobOf(regs.get(0), regs.get(1), regs.get(2));
    var caps: [pattern.max_captures]Value = undefined;
    const call = gsubLoop(.function, vm, &job, &bb.list, &st, &caps, answer) catch |e| return interp.narrowError(e);
    vm.heap.chargeByteBuf(bb);
    if (call) |ncap| {
        st.store(regs, at + 1);
        regs.set(c, job.repl);
        for (caps[0..ncap], c + 1..) |v, r| regs.set(r, v);
        vm.setActArgsEnd(c + 1 + ncap);
        return .call;
    }
    // Interned before the result is stored: the register that held the
    // callee's answer is the first to be overwritten.
    const result = try vm.heap.internValue(bb.bytes());
    regs.set(c, result);
    regs.setInt(c + 1, st.count);
    return .done;
}

/// `string.gsub` called from Zig (`Vm.callValue`), where no activation can be
/// pushed: it finishes from the state the native left, making its calls
/// through `callValue` (`Vm.activationSync`).
pub fn gsubSync(vm: *Vm, seed: native_act.Seed, args: []const Value, results_out: []Value) interp.Error!usize {
    std.debug.assert(seed.kind == .gsub);
    var st = GsubState.fromWords(&seed.words);
    // The buffer was only the seed's carrier: take its bytes into a Zig
    // list, which nothing can sweep while the calls run.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    try out.appendSlice(vm.gpa, ByteBuf.fromHeader(seed.values[0].asHeap()).bytes());
    const job = gsubJobOf(args[0], args[1], args[2]);
    var caps: [pattern.max_captures]Value = undefined;
    var answer: ?Value = null;
    while (gsubLoop(.function, vm, &job, &out, &st, &caps, answer) catch |e| return interp.narrowError(e)) |ncap| {
        var r: [1]Value = .{Value.nil()};
        const n = try vm.callValue(job.repl, caps[0..ncap], r[0..1]);
        answer = if (n >= 1) r[0] else Value.nil();
    }
    const result: [2]Value = .{ try vm.heap.internValue(out.items), Value.int(st.count) };
    return copyOut(&result, results_out);
}

fn sGsub1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var buf: ResultBuf = undefined;
    _ = try gsubCore(vmOf(ctx), args, &buf);
    return buf[0];
}

fn sGsubN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    var buf: ResultBuf = undefined;
    const n = try gsubCore(vmOf(ctx), args, &buf);
    return copyOut(buf[0..n], out);
}



/// Copy `src` results into `out` (capped at `out.len`), returning the count
/// written. The VM nil-pads `out[count..]`.
fn copyOut(src: []const Value, out: []Value) usize {
    const w = @min(src.len, out.len);
    var i: usize = 0;
    while (i < w) : (i += 1) out[i] = src[i];
    return w;
}

// ---------------------------------------------------------------------------
// encode / decode — the text↔bytes boundary (design doc 06, chunk S-A)
// ---------------------------------------------------------------------------

/// `string.encode(s)` / `s:encode()` — a string's UTF-8 bytes as a **byte array**
/// (an ordinary mahina array: a table with integer keys `1..#bytes`, each value an
/// integer `0..255`). Total: a valid string always has valid UTF-8 bytes, so this
/// never fails. On all-ASCII content the result array is bit-identical to the
/// string's bytes (the boundary is the identity function below U+0080).
///
/// Strings are interned-by-bytes and the byte buffer is exactly the thing we copy
/// out, so this is a plain byte→int fan-out — no recorder, no effect, deterministic.
fn sEncode(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(vm, args, 0);
    const t = try vm.heap.newTable();
    for (s, 0..) |b, i| {
        try t.set(vm.gpa, Value.int(@intCast(i + 1)), Value.int(@intCast(b)));
    }
    return Value.heap(&t.header);
}

/// `string.decode(bytes)` — interpret a **byte array** (a table whose sequence
/// part holds integers `0..255`) as text, returning the interned string. This is
/// the one *fallible* constructor: malformed UTF-8 raises a **catchable** error
/// (so `pcall(string.decode, junk)` is the "try to read these bytes as text"
/// idiom). A free function — byte arrays are plain tables with no metatable, so
/// there is no `bytes:decode()`.
///
/// The sequence is `bytes[1 .. #bytes]`; each element must be an integer in
/// `0..255` (a hole or non-integer is a catchable error, since it is not a byte).
/// All-ASCII input cannot fail (the bytes already are valid UTF-8).
fn sDecode(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const n = t.length();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        const v = t.getInt(i);
        if (!v.isInt()) return vm.raiseLocatedError("byte array contains a non-integer element", 1);
        const code = v.asInt();
        if (code < 0 or code > 255) return vm.raiseLocatedError("byte array element out of range (0..255)", 1);
        try buf.append(vm.gpa, @intCast(code));
    }
    if (!std.unicode.utf8ValidateSlice(buf.items)) return vm.raiseLocatedError("invalid UTF-8 in byte array", 1);
    return vm.heap.internValue(buf.items);
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const natives = [_]function.BaseNative{
    .{ .name = "string.len", .func = &sLen, .module = "string", .field = "len", .recorded = .len, .fast = .len },
    .{ .name = "string.sub", .func = &sSub, .module = "string", .field = "sub", .recorded = .sub },
    .{ .name = "string.reverse", .func = &sReverse, .module = "string", .field = "reverse", .recorded = .reverse },
    .{ .name = "string.upper", .func = &sUpper, .module = "string", .field = "upper", .recorded = .upper },
    .{ .name = "string.lower", .func = &sLower, .module = "string", .field = "lower", .recorded = .lower },
    .{ .name = "string.rep", .func = &sRep, .module = "string", .field = "rep", .recorded = .rep },
    .{ .name = "string.char", .func = &sChar, .module = "string", .field = "char", .recorded = .char },
    // S-B (design doc 06): `string.codepoint` (scalar values at character
    // positions) replaces the byte-returning `string.byte`; `string.codes` is the
    // `(index, codepoint)` iterator. Raw bytes now come from `s:encode()`.
    .{ .name = "string.codepoint", .func = &sCodepoint1, .multi = &sCodepointN, .module = "string", .field = "codepoint", .recorded = .codepoint },
    .{ .name = "string.codes", .func = &sCodes1, .multi = &sCodesN, .module = "string", .field = "codes" },
    .{ .name = "string.format", .func = &sFormat, .module = "string", .field = "format" },
    // The text↔bytes boundary (design doc 06, S-A). `encode` is a `string` field
    // so `s:encode()` resolves through the string metatable; `decode` is a plain
    // module field (byte arrays have no metatable, so it stays a free function).
    .{ .name = "string.encode", .func = &sEncode, .module = "string", .field = "encode" },
    .{ .name = "string.decode", .func = &sDecode, .module = "string", .field = "decode" },
    .{ .name = "string.find", .func = &sFind1, .multi = &sFindN, .module = "string", .field = "find", .recorded = .find },
    .{ .name = "string.match", .func = &sMatch1, .multi = &sMatchN, .module = "string", .field = "match", .recorded = .match },
    .{ .name = "string.gmatch", .func = &sGmatch1, .multi = &sGmatchN, .module = "string", .field = "gmatch" },
    .{ .name = "string.gsub", .func = &sGsub1, .multi = &sGsubN, .module = "string", .field = "gsub" },
    // Hidden iterator `gmatch` returns; a bare global like `@ipairs_iter`.
    .{ .name = gmatch_iter_name, .func = &sGmatchAux1, .multi = &sGmatchAuxN, .recorded = .gmatch_iter, .manual = true, .slot = .gmatch_iter },
    // Hidden iterator `s:codes()` returns (S-B); same hidden-global pattern.
    .{ .name = codes_iter_name, .func = &sCodesAux1, .multi = &sCodesAuxN, .manual = true, .slot = .codes_iter },
};

// ---------------------------------------------------------------------------
// Tests — direct native invocation against a live `Vm` (heap + allocator).
// Behavioural coverage across all execution modes lives in `interp.zig`'s
// `expectProgram` e2e suite; these pin the byte-level index/format edges a
// source program can't assert as precisely.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sv(vm: *Vm, s: []const u8) !Value {
    return vm.heap.internValue(s);
}
fn bytesOf(v: Value) []const u8 {
    return interp.strBytes(v).?;
}

test "doc 28 L1: String-aware seam helpers agree with the byte-scan references on every boundary" {
    // The byte-slice forms (`charByteOffset`, `cpCount`, `byteToChar`) are the
    // reference implementations; the `*String` fast forms must agree with them
    // at EVERY boundary for both an ASCII subject (fast path taken) and a
    // multibyte subject (general path — trivially equal, pinned anyway so a
    // future edit can't fork them).
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const subjects = [_][]const u8{ "", "a", "hello", "héllo", "😀", "ab😀cd" };
    for (subjects) |bytes| {
        const s = try vm.heap.intern(bytes);
        // charByteOffsetS across ci = 0 .. cp_len + 2 (incl. one-past-end and beyond).
        var ci: usize = 0;
        while (ci <= s.cpLen() + 2) : (ci += 1)
            try testing.expectEqual(charByteOffset(bytes, ci), charByteOffsetS(s, ci));
        // byteToCharS / cpCountPrefixS at every code-point boundary incl. len.
        var off: usize = 0;
        while (true) {
            try testing.expectEqual(cpCount(bytes[0..off]) + 1, byteToCharS(s, off));
            try testing.expectEqual(cpCount(bytes[0..off]), cpCountPrefixS(s, off));
            if (off >= bytes.len) break;
            off += decodeAt(bytes, off).len;
        }
        // charPrefixEndS: "at most count chars" for count = 0 .. cp_len + 1,
        // plus the huge-count clamp that motivates it (no overflow).
        var count: usize = 0;
        while (count <= s.cpLen() + 1) : (count += 1)
            try testing.expectEqual(charByteOffset(bytes, @min(count, s.cpLen()) + 1), charPrefixEndS(s, count));
        try testing.expectEqual(bytes.len, charPrefixEndS(s, std.math.maxInt(usize)));
    }
}

test "doc 28 L1: sub/codepoint fast paths — ASCII answers equal the general path's on shared vectors" {
    // Same call shapes on an ASCII subject and on a multibyte subject whose
    // FIRST five characters coincide ("héllo" vs "hello" differ at char 2) —
    // pinning that clamping/negative-index behaviour did not fork.
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const a = try vm.heap.intern("hello"); // ASCII: fast paths taken
    const u = try vm.heap.intern("h\xC3\xA9llo"); // "héllo": general path
    const shapes = [_][2]i64{
        .{ 1, -1 }, .{ 2, 4 },   .{ -3, -1 }, .{ -100, 100 },
        .{ 4, 2 },  .{ 5, 5 },   .{ 6, 6 },   .{ 0, 3 },
        .{ -5, 1 }, .{ 1, 100 },
    };
    for (shapes) |sh| {
        // sub: character-count parity (bytes differ at the é, counts must not).
        const ra = try subCore(vm.heap, a, sh[0], sh[1]);
        const ru = try subCore(vm.heap, u, sh[0], sh[1]);
        try testing.expectEqual(ru.cpLen(), ra.cpLen());
        // codepoint: present/absent parity, and equality wherever the chars agree.
        const ca = codepointCore(a, sh[0], sh[1]);
        const cu = codepointCore(u, sh[0], sh[1]);
        try testing.expectEqual(cu == null, ca == null);
        if (ca != null and cu != null and cu.? != 0xE9)
            try testing.expectEqual(cu.?, ca.?);
    }
    // Direct fast-path values.
    try testing.expectEqualStrings("ell", (try subCore(vm.heap, a, 2, 4)).bytes());
    try testing.expectEqual(@as(?i64, 'o'), codepointCore(a, -1, -1));
    try testing.expectEqual(@as(?i64, null), codepointCore(a, 6, 6));
}

test "doc 28 c3b: known-facts producers — caches correct on both block and general paths (asserts armed)" {
    // Every core below now CLAIMS character facts at intern time; in this safe
    // build a wrong claim traps (createWithHashKnown / hit-path asserts), so
    // merely running these vectors is the contract check. Assert the caches
    // and dedup identity on top.
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const heap = vm.heap;

    // rep2Core, multibyte source: cp multiplies exactly, bit stays clear.
    const r1 = try rep2Core(heap, try heap.intern("héé"), 3);
    try testing.expectEqual(@as(usize, 9), r1.cpLen());
    try testing.expect(!r1.isAscii());
    try testing.expectEqualStrings("hééhééhéé", r1.bytes());
    // ASCII source: bit stays set; dedup against a plain intern of same bytes.
    const r2 = try rep2Core(heap, try heap.intern("ab"), 2);
    try testing.expect(r2.isAscii());
    try testing.expectEqual(r2, try heap.intern("abab"));
    // n <= 0 → the known-empty.
    try testing.expectEqual(@as(usize, 0), (try rep2Core(heap, try heap.intern("x"), 0)).cpLen());

    // caseCore ASCII block path (resize-once map) vs general path result caches.
    const lo_ascii = try caseCore(heap, try heap.intern("MiXed ascii!"), .lower);
    try testing.expectEqualStrings("mixed ascii!", lo_ascii.bytes());
    try testing.expect(lo_ascii.isAscii());
    const up_gen = try caseCore(heap, try heap.intern("héLLo"), .upper); // general path
    try testing.expectEqualStrings("HÉLLO", up_gen.bytes());
    try testing.expectEqual(@as(usize, 5), up_gen.cpLen()); // count-preserving claim held
    try testing.expect(!up_gen.isAscii()); // derived by scan (claim was null)
    // Case-crossing mapping: KELVIN SIGN (U+212A, 3 bytes) lowers to ASCII 'k' —
    // the reason the general path must NOT claim the bit; the scan sets it.
    const kelvin = try caseCore(heap, try heap.intern("\u{212A}"), .lower);
    try testing.expectEqualStrings("k", kelvin.bytes());
    try testing.expect(kelvin.isAscii());

    // reverseCore: both paths, permutation-preserved caches, char1Core facts.
    const v1 = try reverseCore(heap, try heap.intern("abc")); // block path
    try testing.expectEqualStrings("cba", v1.bytes());
    try testing.expect(v1.isAscii());
    const v2 = try reverseCore(heap, try heap.intern("ab😀cd")); // general
    try testing.expectEqualStrings("dc😀ba", v2.bytes());
    try testing.expectEqual(@as(usize, 5), v2.cpLen());
    try testing.expect(!v2.isAscii());
    try testing.expect((try char1Core(heap, 'x')).isAscii());
    const w = try char1Core(heap, 0x1F600);
    try testing.expectEqual(@as(usize, 1), w.cpLen());
    try testing.expect(!w.isAscii());
}

test "string.len / sub with negative & clamped indices" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const hello = try sv(&vm, "hello");

    try testing.expectEqual(@as(i64, 5), (try sLen(@ptrCast(&vm), &.{hello})).asInt());

    try testing.expectEqualStrings("ell", bytesOf(try sSub(@ptrCast(&vm), &.{ hello, Value.int(2), Value.int(4) })));
    // j defaults to -1 (end).
    try testing.expectEqualStrings("llo", bytesOf(try sSub(@ptrCast(&vm), &.{ hello, Value.int(-3) })));
    // i clamps up to 1, j clamps down to len.
    try testing.expectEqualStrings("hello", bytesOf(try sSub(@ptrCast(&vm), &.{ hello, Value.int(-100), Value.int(100) })));
    // i > j → empty.
    try testing.expectEqualStrings("", bytesOf(try sSub(@ptrCast(&vm), &.{ hello, Value.int(4), Value.int(2) })));
}

test "string.reverse / upper / lower (ASCII)" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqualStrings("cba", bytesOf(try sReverse(@ptrCast(&vm), &.{try sv(&vm, "abc")})));
    try testing.expectEqualStrings("AB9C", bytesOf(try sUpper(@ptrCast(&vm), &.{try sv(&vm, "aB9c")})));
    try testing.expectEqualStrings("ab9c", bytesOf(try sLower(@ptrCast(&vm), &.{try sv(&vm, "aB9C")})));
}

test "string.upper / lower: Unicode simple (1:1) case mapping (S-C)" {
    // The generated table: a couple of direct scalar maps (é<->É, Greek Α<->α).
    try testing.expectEqual(@as(u21, 0x00C9), unicode_case.toUpper(0x00E9)); // é -> É
    try testing.expectEqual(@as(u21, 0x03B1), unicode_case.toLower(0x0391)); // Α -> α
    try testing.expectEqual(@as(u21, 0x00DF), unicode_case.toUpper(0x00DF)); // ß: no simple upper -> itself
    try testing.expectEqual(@as(u21, 0x0041), unicode_case.toUpper(0x0041)); // ASCII unaffected by the table

    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // Latin-1 + ASCII mix; Greek; mixed scripts. Count-preserving.
    try testing.expectEqualStrings("CAFÉ", bytesOf(try sUpper(@ptrCast(&vm), &.{try sv(&vm, "café")})));
    try testing.expectEqualStrings("café", bytesOf(try sLower(@ptrCast(&vm), &.{try sv(&vm, "CAFÉ")})));
    try testing.expectEqualStrings("αβγ", bytesOf(try sLower(@ptrCast(&vm), &.{try sv(&vm, "ΑΒΓ")})));
    try testing.expectEqualStrings("ΑΒΓ", bytesOf(try sUpper(@ptrCast(&vm), &.{try sv(&vm, "αβγ")})));
    // Simple mapping: characters with no simple case map are unchanged.
    try testing.expectEqualStrings("ß", bytesOf(try sUpper(@ptrCast(&vm), &.{try sv(&vm, "ß")})));
    try testing.expectEqualStrings("ﬀ", bytesOf(try sUpper(@ptrCast(&vm), &.{try sv(&vm, "ﬀ")})));
    // Code-point count is preserved (simple mapping is 1:1).
    const up = try sUpper(@ptrCast(&vm), &.{try sv(&vm, "héllo")});
    try testing.expectEqual(string_mod.String.fromHeader(up.asHeap()).cpLen(), @as(usize, 5));
}

test "string.rep with separator and non-positive count" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ab = try sv(&vm, "ab");
    try testing.expectEqualStrings("ababab", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(3) })));
    try testing.expectEqualStrings("ab-ab-ab", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(3), try sv(&vm, "-") })));
    try testing.expectEqualStrings("", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(0) })));
    try testing.expectEqualStrings("", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(-2) })));
}

test "string.char builds from code points (S-B); rejects surrogates/over-range" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // ASCII unchanged.
    try testing.expectEqualStrings("Hi!", bytesOf(try sChar(@ptrCast(&vm), &.{ Value.int(72), Value.int(105), Value.int(33) })));
    // 256 (U+0100 Ā) is now a valid CODE POINT → 2 UTF-8 bytes (was out of range).
    try testing.expectEqualStrings("Ā", bytesOf(try sChar(@ptrCast(&vm), &.{Value.int(0x100)})));
    // U+1F600 (😀) → 4 bytes.
    try testing.expectEqualStrings("😀", bytesOf(try sChar(@ptrCast(&vm), &.{Value.int(0x1F600)})));
    // Surrogate half, over-range, and negative are rejected.
    try testing.expectError(error.LuaError, sChar(@ptrCast(&vm), &.{Value.int(0xD800)}));
    try testing.expectError(error.LuaError, sChar(@ptrCast(&vm), &.{Value.int(0x110000)}));
    try testing.expectError(error.LuaError, sChar(@ptrCast(&vm), &.{Value.int(-1)}));
    // An explicit nil argument is a bad argument (not a silent default-to-NUL).
    try testing.expectError(error.LuaError, sChar(@ptrCast(&vm), &.{Value.nil()}));
    try testing.expectError(error.LuaError, sChar(@ptrCast(&vm), &.{ Value.int(65), Value.nil(), Value.int(66) }));
}

test "string.codepoint: scalar values at character positions (S-B)" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const s = try sv(&vm, "héllo"); // h é l l o — 5 chars, 6 bytes

    // Primary projection: scalar at char 1 (default), and char 2 = 'é' = U+00E9.
    try testing.expectEqual(@as(i64, 'h'), (try sCodepoint1(@ptrCast(&vm), &.{s})).asInt());
    try testing.expectEqual(@as(i64, 0xE9), (try sCodepoint1(@ptrCast(&vm), &.{ s, Value.int(2) })).asInt());
    try testing.expectEqual(@as(i64, 'o'), (try sCodepoint1(@ptrCast(&vm), &.{ s, Value.int(-1) })).asInt());

    // Multi: full range → 5 scalar values (the 'é' counts as one character).
    var out: [8]Value = undefined;
    const n = try sCodepointN(@ptrCast(&vm), &.{ s, Value.int(1), Value.int(5) }, &out);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(i64, 'h'), out[0].asInt());
    try testing.expectEqual(@as(i64, 0xE9), out[1].asInt());
    try testing.expectEqual(@as(i64, 'o'), out[4].asInt());

    // Empty range → zero results.
    try testing.expectEqual(@as(usize, 0), try sCodepointN(@ptrCast(&vm), &.{ s, Value.int(3), Value.int(1) }, &out));
}

test "string.sub / reverse by code point (S-B)" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const s = try sv(&vm, "héllo");
    // sub(2,2) is the single character 'é' (2 bytes), not a half-sequence.
    try testing.expectEqualStrings("é", bytesOf(try sSub(@ptrCast(&vm), &.{ s, Value.int(2), Value.int(2) })));
    try testing.expectEqualStrings("éllo", bytesOf(try sSub(@ptrCast(&vm), &.{ s, Value.int(2) })));
    try testing.expectEqualStrings("llo", bytesOf(try sSub(@ptrCast(&vm), &.{ s, Value.int(-3) })));
    // reverse keeps multibyte characters intact.
    try testing.expectEqualStrings("olléh", bytesOf(try sReverse(@ptrCast(&vm), &.{s})));
    try testing.expectEqualStrings("😀ba", bytesOf(try sReverse(@ptrCast(&vm), &.{try sv(&vm, "ab😀")})));
}

test "string.len counts code points (S-B)" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 5), (try sLen(@ptrCast(&vm), &.{try sv(&vm, "héllo")})).asInt());
    try testing.expectEqual(@as(i64, 3), (try sLen(@ptrCast(&vm), &.{try sv(&vm, "ab😀")})).asInt());
}

test "string.format: integer/float/string/quote specs" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const f = try sv(&vm, "[%5d][%-5d][%05.2f][%x][%s][%q]");
    const r = try sFormat(@ptrCast(&vm), &.{ f, Value.int(42), Value.int(42), Value.float(3.14159), Value.int(255), try sv(&vm, "hi"), try sv(&vm, "a\"b") });
    try testing.expectEqualStrings("[   42][42   ][03.14][ff][hi][\"a\\\"b\"]", bytesOf(r));
    // Unknown conversion errors.
    try testing.expectError(error.LuaError, sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%y"), Value.int(1) }));
}

test "string.format: %s and %c field width pad by code points (S-B)" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // "é" is one code point (2 UTF-8 bytes): %3s right-justifies to width 3 with
    // two spaces (not one), and %-3s left-justifies with two trailing spaces.
    try testing.expectEqualStrings("  é", bytesOf(try sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%3s"), try sv(&vm, "é") })));
    try testing.expectEqualStrings("é  ", bytesOf(try sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%-3s"), try sv(&vm, "é") })));
    // "héllo" is 5 code points → width 5 needs no padding even though it's 6 bytes.
    try testing.expectEqualStrings("héllo", bytesOf(try sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%5s"), try sv(&vm, "héllo") })));
    // %.2s precision counts code points (already covered by sSub semantics).
    try testing.expectEqualStrings("hé", bytesOf(try sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%.2s"), try sv(&vm, "héllo") })));
    // %3c of a 4-byte emoji pads to width 3 (one character + two spaces).
    try testing.expectEqualStrings("  😀", bytesOf(try sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%3c"), Value.int(0x1F600) })));
    try testing.expectEqualStrings("😀  ", bytesOf(try sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%-3c"), Value.int(0x1F600) })));
}

test "string.format: C-style %e/%g (exponent, sig-digit selection, strip) match printf" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const big = 66666.66666666667;
    const Case = struct { spec: []const u8, v: f64, want: []const u8 };
    // Every `want` was cross-checked byte-for-byte against LuaJIT's printf.
    const cases = [_]Case{
        // %e/%E: always-signed exponent, ≥2 digits.
        .{ .spec = "%e", .v = 1.5, .want = "1.500000e+00" },
        .{ .spec = "%e", .v = 0.0001234, .want = "1.234000e-04" },
        .{ .spec = "%E", .v = 1e20, .want = "1.000000E+20" },
        .{ .spec = "%.3e", .v = big, .want = "6.667e+04" },
        .{ .spec = "%012.4e", .v = big, .want = "006.6667e+04" },
        // %g/%G: significant-digit selection (%e vs %f) + trailing-zero strip.
        .{ .spec = "%g", .v = big, .want = "66666.7" },
        .{ .spec = "%g", .v = 0.00001234, .want = "1.234e-05" },
        .{ .spec = "%g", .v = 123456789.0, .want = "1.23457e+08" },
        .{ .spec = "%g", .v = 100.0, .want = "100" },
        .{ .spec = "%g", .v = 0.5, .want = "0.5" },
        .{ .spec = "%.15g", .v = 123456789.0, .want = "123456789" },
        .{ .spec = "%.3g", .v = big, .want = "6.67e+04" },
        .{ .spec = "%G", .v = 1e20, .want = "1E+20" },
        // %#g keeps the trailing zeros %g would strip.
        .{ .spec = "%#g", .v = 1.0, .want = "1.00000" },
        // inf/nan render as letters; the `0` flag is ignored (space-pad).
        .{ .spec = "%f", .v = std.math.inf(f64), .want = "inf" },
        .{ .spec = "%E", .v = std.math.inf(f64), .want = "INF" },
        .{ .spec = "%08.2f", .v = std.math.inf(f64), .want = "     inf" },
    };
    for (cases) |c| {
        const r = try sFormat(@ptrCast(&vm), &.{ try sv(&vm, c.spec), Value.float(c.v) });
        try testing.expectEqualStrings(c.want, bytesOf(r));
    }
}

// -- pattern wrappers (engine itself is tested in pattern.zig) ---------------

test "string.find: indices, captures, plain, init, no-match" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var out: [6]Value = undefined;

    // (start, end) of a plain-by-default search (no specials in "lo").
    var n = try sFindN(@ptrCast(&vm), &.{ try sv(&vm, "hello"), try sv(&vm, "lo") }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 4), out[0].asInt());
    try testing.expectEqual(@as(i64, 5), out[1].asInt());

    // Captures returned after (start, end).
    n = try sFindN(@ptrCast(&vm), &.{ try sv(&vm, "k=v"), try sv(&vm, "(%w+)=(%w+)") }, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(i64, 1), out[0].asInt());
    try testing.expectEqual(@as(i64, 3), out[1].asInt());
    try testing.expectEqualStrings("k", bytesOf(out[2]));
    try testing.expectEqualStrings("v", bytesOf(out[3]));

    // plain=true treats a special char literally; init skips the leading dot.
    n = try sFindN(@ptrCast(&vm), &.{ try sv(&vm, "a.b.c"), try sv(&vm, "."), Value.int(3), Value.boolean(true) }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 4), out[0].asInt());

    // No match → single nil.
    n = try sFindN(@ptrCast(&vm), &.{ try sv(&vm, "abc"), try sv(&vm, "x") }, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(out[0].isNil());
}

test "string.match: captures, whole match, anchors" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var out: [4]Value = undefined;

    // Two captures.
    var n = try sMatchN(@ptrCast(&vm), &.{ try sv(&vm, "  key = val"), try sv(&vm, "(%w+)%s*=%s*(%w+)") }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("key", bytesOf(out[0]));
    try testing.expectEqualStrings("val", bytesOf(out[1]));

    // No captures → whole match (single result).
    n = try sMatchN(@ptrCast(&vm), &.{ try sv(&vm, "2026-06"), try sv(&vm, "%d+") }, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("2026", bytesOf(out[0]));

    // Single projection mirrors the first result.
    try testing.expectEqualStrings("2026", bytesOf(try sMatch1(@ptrCast(&vm), &.{ try sv(&vm, "2026-06"), try sv(&vm, "%d+") })));
}

test "string.gsub: string repl with %1, count, table repl, anchor" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var out: [2]Value = undefined;

    // %1 capture reference + substitution count.
    var n = try sGsubN(@ptrCast(&vm), &.{ try sv(&vm, "x=1, y=2"), try sv(&vm, "(%w+)=(%w+)"), try sv(&vm, "%2=%1") }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("1=x, 2=y", bytesOf(out[0]));
    try testing.expectEqual(@as(i64, 2), out[1].asInt());

    // Table replacement; missing keys keep the original text.
    const map = try vm.heap.newTable();
    try map.set(vm.gpa, try sv(&vm, "name"), try sv(&vm, "Lua"));
    n = try sGsubN(@ptrCast(&vm), &.{ try sv(&vm, "$name $x"), try sv(&vm, "%$(%w+)"), Value.heap(&map.header) }, &out);
    try testing.expectEqualStrings("Lua $x", bytesOf(out[0]));
    try testing.expectEqual(@as(i64, 2), out[1].asInt());

    // Anchor matches at most once; n caps substitutions.
    n = try sGsubN(@ptrCast(&vm), &.{ try sv(&vm, "aaa"), try sv(&vm, "^a"), try sv(&vm, "A") }, &out);
    try testing.expectEqualStrings("Aaa", bytesOf(out[0]));
    try testing.expectEqual(@as(i64, 1), out[1].asInt());

    // A function replacement leaves the native at its first match that needs
    // the call (doc 68 §7.4): the output before it in a buffer, the state
    // rewound to before the match, for the activation (or `gsubSync`) to carry
    // on from. `interp_stdlib_test.zig` runs the whole thing.
    const lenfn = try function.Native.create(vm.gpa, &sLen, "lenfn");
    defer lenfn.destroy(vm.gpa);
    try testing.expectError(error.ActivateNative, sGsubN(@ptrCast(&vm), &.{ try sv(&vm, "ab cd"), try sv(&vm, "%w+"), Value.heap(&lenfn.header) }, &out));
    const seed = vm.takeActSeed();
    try testing.expectEqual(native_act.Kind.gsub, seed.kind);
    try testing.expectEqual(@as(i64, 0), seed.words[0]); // src: before the first match
    try testing.expectEqual(@as(i64, 0), seed.words[1]); // count
    try testing.expectEqual(@as(i64, -1), seed.words[3]); // nothing pending
    try testing.expectEqualStrings("", ByteBuf.fromHeader(seed.values[0].asHeap()).bytes());
}

test "@gmatch_iter walks the state table and stops when exhausted" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();

    const st = try vm.heap.newTable();
    try st.set(vm.gpa, Value.int(1), try sv(&vm, "a b c"));
    try st.set(vm.gpa, Value.int(2), try sv(&vm, "%a"));
    try st.set(vm.gpa, Value.int(3), Value.int(0));
    const stv = Value.heap(&st.header);

    var out: [2]Value = undefined;
    const want = [_][]const u8{ "a", "b", "c" };
    for (want) |w| {
        const n = try sGmatchAuxN(@ptrCast(&vm), &.{stv}, &out);
        try testing.expectEqual(@as(usize, 1), n);
        try testing.expectEqualStrings(w, bytesOf(out[0]));
    }
    // Exhausted → 0 results.
    try testing.expectEqual(@as(usize, 0), try sGmatchAuxN(@ptrCast(&vm), &.{stv}, &out));
}

test "S-D: find/match/gmatch/gsub report and accept CHARACTER indices (multibyte)" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var out: [6]Value = undefined;

    // "héllo": h(1) é(2) l(3) l(4) o(5) — 5 chars, 6 bytes (é is 2 bytes).
    const hello = try sv(&vm, "héllo");

    // find returns a CHARACTER start/end: 'l' is char 3, not byte 4.
    var n = try sFindN(@ptrCast(&vm), &.{ hello, try sv(&vm, "l") }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 3), out[0].asInt());
    try testing.expectEqual(@as(i64, 3), out[1].asInt());

    // find result composes with char-indexed sub: sub(start,end) == match.
    n = try sFindN(@ptrCast(&vm), &.{ hello, try sv(&vm, "llo") }, &out);
    try testing.expectEqual(@as(i64, 3), out[0].asInt());
    try testing.expectEqual(@as(i64, 5), out[1].asInt());
    try testing.expectEqualStrings("llo", bytesOf(try sSub(@ptrCast(&vm), &.{ hello, out[0], out[1] })));

    // `.` matches a whole multibyte code point; find spans it as one character.
    n = try sFindN(@ptrCast(&vm), &.{ hello, try sv(&vm, "h(.)") }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(i64, 1), out[0].asInt()); // start char
    try testing.expectEqual(@as(i64, 2), out[1].asInt()); // end char (the 'é')
    try testing.expectEqualStrings("é", bytesOf(out[2])); // capture is the whole code point

    // Position capture `()` reports a CHARACTER index.
    n = try sMatchN(@ptrCast(&vm), &.{ hello, try sv(&vm, "l()") }, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i64, 4), out[0].asInt()); // position after first 'l' = char 4

    // `init` is a 1-based CHARACTER index: starting the scan at char 3 skips 'é'.
    n = try sFindN(@ptrCast(&vm), &.{ try sv(&vm, "é=é"), try sv(&vm, "é"), Value.int(2) }, &out);
    try testing.expectEqual(@as(i64, 3), out[0].asInt()); // the second 'é' is char 3

    // gmatch over a multibyte string yields char-aligned whole code points.
    const st = try vm.heap.newTable();
    try st.set(vm.gpa, Value.int(1), try sv(&vm, "áéí"));
    try st.set(vm.gpa, Value.int(2), try sv(&vm, "."));
    try st.set(vm.gpa, Value.int(3), Value.int(0));
    const stv = Value.heap(&st.header);
    const want = [_][]const u8{ "á", "é", "í" };
    var gout: [2]Value = undefined;
    for (want) |w| {
        const gn = try sGmatchAuxN(@ptrCast(&vm), &.{stv}, &gout);
        try testing.expectEqual(@as(usize, 1), gn);
        try testing.expectEqualStrings(w, bytesOf(gout[0]));
    }
    try testing.expectEqual(@as(usize, 0), try sGmatchAuxN(@ptrCast(&vm), &.{stv}, &gout));

    // gsub: "." matches each code point once → 5 replacements over "héllo".
    var g2: [2]Value = undefined;
    const gn = try sGsubN(@ptrCast(&vm), &.{ hello, try sv(&vm, "."), try sv(&vm, "x") }, &g2);
    try testing.expectEqual(@as(usize, 2), gn);
    try testing.expectEqualStrings("xxxxx", bytesOf(g2[0]));
    try testing.expectEqual(@as(i64, 5), g2[1].asInt());

    // gsub with no match copies the multibyte tail intact (never splits a char).
    _ = try sGsubN(@ptrCast(&vm), &.{ hello, try sv(&vm, "z"), try sv(&vm, "Q") }, &g2);
    try testing.expectEqualStrings("héllo", bytesOf(g2[0]));
    try testing.expectEqual(@as(i64, 0), g2[1].asInt());
}

// --- encode / decode (S-A boundary) ----------------------------------------

/// Read a decoded byte array's sequence into a freshly-allocated slice the caller
/// frees, so a test can assert the exact `(len, bytes)`.
fn arrBytes(v: Value) ![]u8 {
    const t = Table.fromHeader(v.asHeap());
    const n: usize = @intCast(t.length());
    const out = try testing.allocator.alloc(u8, n);
    for (0..n) |i| out[i] = @intCast(t.getInt(@intCast(i + 1)).asInt());
    return out;
}

test "string.encode: ASCII is the identity byte sequence; multibyte is UTF-8" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();

    // ASCII: "Hi" → {72, 105}, bit-identical to the bytes.
    const ascii = try arrBytes(try sEncode(@ptrCast(&vm), &.{try sv(&vm, "Hi")}));
    defer testing.allocator.free(ascii);
    try testing.expectEqualSlices(u8, &.{ 72, 105 }, ascii);

    // Multibyte: "é" (U+00E9) → its 2 UTF-8 bytes {0xC3, 0xA9}.
    const e = try arrBytes(try sEncode(@ptrCast(&vm), &.{try sv(&vm, "é")}));
    defer testing.allocator.free(e);
    try testing.expectEqualSlices(u8, &.{ 0xC3, 0xA9 }, e);

    // Empty string → empty array.
    const empty = try arrBytes(try sEncode(@ptrCast(&vm), &.{try sv(&vm, "")}));
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "string.decode: round-trips encode, validates, and is catchably fallible" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();

    // Round-trip: decode(encode(s)) == s, by interned-pointer identity.
    const s = try sv(&vm, "héllo wörld");
    const decoded = try sDecode(@ptrCast(&vm), &.{try sEncode(@ptrCast(&vm), &.{s})});
    try testing.expectEqual(s.asHeap(), decoded.asHeap()); // same interned object
    try testing.expectEqualStrings("héllo wörld", bytesOf(decoded));

    // Build a byte array by hand and decode it.
    const t = try vm.heap.newTable();
    try t.set(vm.gpa, Value.int(1), Value.int(72));
    try t.set(vm.gpa, Value.int(2), Value.int(105));
    try testing.expectEqualStrings("Hi", bytesOf(try sDecode(@ptrCast(&vm), &.{Value.heap(&t.header)})));

    // Invalid UTF-8 (lone continuation byte 0xA9) → catchable LuaError.
    const bad = try vm.heap.newTable();
    try bad.set(vm.gpa, Value.int(1), Value.int(0xA9));
    try testing.expectError(error.LuaError, sDecode(@ptrCast(&vm), &.{Value.heap(&bad.header)}));

    // Out-of-range element → catchable LuaError.
    const oor = try vm.heap.newTable();
    try oor.set(vm.gpa, Value.int(1), Value.int(256));
    try testing.expectError(error.LuaError, sDecode(@ptrCast(&vm), &.{Value.heap(&oor.header)}));

    // Non-integer element → catchable LuaError.
    const nonint = try vm.heap.newTable();
    try nonint.set(vm.gpa, Value.int(1), try sv(&vm, "x"));
    try testing.expectError(error.LuaError, sDecode(@ptrCast(&vm), &.{Value.heap(&nonint.header)}));

    // Non-table argument → bad argument (also LuaError).
    try testing.expectError(error.LuaError, sDecode(@ptrCast(&vm), &.{Value.int(5)}));
}

// ---------------------------------------------------------------------------
// Doc 30 c1 — the pattern-callout cores, exercised directly (no VM, no IR).
// ---------------------------------------------------------------------------

const t30 = std.testing;

test "doc 30: smatchCore fills scratch — spans, char indices, captures" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("key=val x=1");
    const st = string_mod.String; // brevity
    _ = st;

    // Two span captures.
    try t30.expectEqual(MatchStatus.ok, smatchCore(&heap, subj, 1, "(%a+)=(%a+)"));
    const sc = &heap.match_scratch;
    try t30.expectEqual(@intFromPtr(subj), sc.subj);
    try t30.expectEqual(@as(u64, 1), sc.words[2 * gc.MatchScratch.slot_start]); // char 1
    try t30.expectEqual(@as(u64, 7), sc.words[2 * gc.MatchScratch.slot_end]); // "key=val"
    try t30.expectEqual(@as(u64, 0), sc.words[2 * gc.MatchScratch.slot_whole]);
    try t30.expectEqual(@as(u64, 7), sc.words[2 * gc.MatchScratch.slot_whole + 1]);
    // capture 0 = "key" (0,3), capture 1 = "val" (4,3)
    try t30.expectEqual(@as(u64, 0), sc.words[2 * (gc.MatchScratch.slot_cap0 + 0)]);
    try t30.expectEqual(@as(u64, 3), sc.words[2 * (gc.MatchScratch.slot_cap0 + 0) + 1]);
    try t30.expectEqual(@as(u64, 4), sc.words[2 * (gc.MatchScratch.slot_cap0 + 1)]);
    try t30.expectEqual(@as(u64, 3), sc.words[2 * (gc.MatchScratch.slot_cap0 + 1) + 1]);

    // init continues the search (1-based char): from char 5, match "x=1".
    try t30.expectEqual(MatchStatus.ok, smatchCore(&heap, subj, 5, "(%a+)=(%d+)"));
    try t30.expectEqual(@as(u64, 9), sc.words[2 * gc.MatchScratch.slot_start]);

    // Position capture -> int slot (1-based char position).
    try t30.expectEqual(MatchStatus.ok, smatchCore(&heap, subj, 1, "e()y"));
    try t30.expectEqual(@as(u64, 3), sc.words[2 * (gc.MatchScratch.slot_cap0 + 0)]);

    // Statuses: no match / bad init / malformed at runtime (census-bypassed).
    try t30.expectEqual(MatchStatus.no_match, smatchCore(&heap, subj, 1, "%d%d"));
    try t30.expectEqual(MatchStatus.bad_init, smatchCore(&heap, subj, 99, "%a"));
    try t30.expectEqual(MatchStatus.malformed, smatchCore(&heap, subj, 1, "%"));
    try t30.expectEqual(MatchStatus.malformed, smatchCore(&heap, subj, 1, "[ab"));
}

test "doc 30: smatchCore char indices on a multibyte subject" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("ré=sumé"); // chars: r é = s u m é
    // '.' steps a whole code point (S-D); %a is ASCII-only and would NOT
    // match 'é'. The capture "ré" is 3 BYTES but chars 1..2.
    try t30.expectEqual(MatchStatus.ok, smatchCore(&heap, subj, 1, "(r.)="));
    const sc = &heap.match_scratch;
    // Whole match "ré=" -> start char 1, end char 3; capture span is bytes.
    try t30.expectEqual(@as(u64, 1), sc.words[2 * gc.MatchScratch.slot_start]);
    try t30.expectEqual(@as(u64, 3), sc.words[2 * gc.MatchScratch.slot_end]);
    try t30.expectEqual(@as(u64, 0), sc.words[2 * (gc.MatchScratch.slot_cap0 + 0)]);
    try t30.expectEqual(@as(u64, 3), sc.words[2 * (gc.MatchScratch.slot_cap0 + 0) + 1]); // "ré" = 3 bytes
}

test "doc 30: scapStrCore interns the span (identity with the intern table)" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("key=val");
    try t30.expectEqual(MatchStatus.ok, smatchCore(&heap, subj, 1, "(%a+)=(%a+)"));
    const c0 = try scapStrCore(&heap, gc.MatchScratch.slot_cap0 + 0);
    const c1 = try scapStrCore(&heap, gc.MatchScratch.slot_cap0 + 1);
    const whole = try scapStrCore(&heap, gc.MatchScratch.slot_whole);
    // Interning: the projections ARE the canonical objects for those bytes.
    try t30.expectEqual(try heap.intern("key"), c0);
    try t30.expectEqual(try heap.intern("val"), c1);
    try t30.expectEqual(try heap.intern("key=val"), whole);
}

test "doc 30: sfindPlainCore start index and statuses" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("hello world");
    try t30.expectEqual(@as(i64, 7), sfindPlainCore(subj, 1, "world"));
    try t30.expectEqual(@as(i64, 7), sfindPlainCore(subj, 7, "world"));
    try t30.expectEqual(MatchStatus.no_match, sfindPlainCore(subj, 8, "world"));
    try t30.expectEqual(MatchStatus.no_match, sfindPlainCore(subj, 1, "zzz"));
    try t30.expectEqual(MatchStatus.bad_init, sfindPlainCore(subj, 13, "w"));
    // Empty pattern: matched at init (end = start-1 falls out of recorder
    // arithmetic with cpLen == 0).
    try t30.expectEqual(@as(i64, 3), sfindPlainCore(subj, 3, ""));
    try t30.expectEqual(@as(i64, 12), sfindPlainCore(subj, 12, "")); // end+1 position
    // Multibyte: char indices, not bytes.
    const msubj = try heap.intern("ré=s");
    try t30.expectEqual(@as(i64, 3), sfindPlainCore(msubj, 1, "=s"));
}

/// Build the compiler-shaped gmatch state `{ [1]=subj, [2]=pat, [3]=pos }`.
fn makeGmatchState(heap: *gc.Heap, subj: *String, pat: *String, pos: i64) !*Table {
    const t = try heap.newTable();
    try t.set(std.testing.allocator, Value.int(1), Value.heap(@constCast(&subj.header)));
    try t.set(std.testing.allocator, Value.int(2), Value.heap(@constCast(&pat.header)));
    try t.set(std.testing.allocator, Value.int(3), Value.int(pos));
    return t;
}

test "doc 30: sgmatchCore — read-only step, next_pos, exhaustion, statuses" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("aa,b,,cc");
    const pat = try heap.intern("[^,]+");
    const state = try makeGmatchState(&heap, subj, pat, 0);
    const sc = &heap.match_scratch;

    // Step 1: "aa" at (0,2), next_pos 2; the state's pos is NOT advanced.
    try t30.expectEqual(MatchStatus.ok, sgmatchCore(&heap, state, pat));
    try t30.expectEqual(@as(u64, 0), sc.words[2 * gc.MatchScratch.slot_whole]);
    try t30.expectEqual(@as(u64, 2), sc.words[2 * gc.MatchScratch.slot_whole + 1]);
    try t30.expectEqual(@as(u64, 2), sc.words[2 * gc.MatchScratch.slot_next_pos]);
    try t30.expectEqual(@as(i64, 0), state.inLaneValueIntCell(3).?); // READ-ONLY (round-2 B01)

    // Re-running without advancing yields the SAME token (replay idempotence).
    try t30.expectEqual(MatchStatus.ok, sgmatchCore(&heap, state, pat));
    try t30.expectEqual(@as(u64, 0), sc.words[2 * gc.MatchScratch.slot_whole]);

    // Advance via the deferred-store helper (what sgm_setpos lowers to).
    try t30.expect(state.setInLaneValueInt(3, @intCast(sc.words[2 * gc.MatchScratch.slot_next_pos])));
    try t30.expectEqual(MatchStatus.ok, sgmatchCore(&heap, state, pat));
    try t30.expectEqual(@as(u64, 3), sc.words[2 * gc.MatchScratch.slot_whole]); // "b"
    try t30.expectEqual(@as(u64, 1), sc.words[2 * gc.MatchScratch.slot_whole + 1]);

    // Exhaustion: pos at end and no token left -> no_match (for-in loop end).
    try t30.expect(state.setInLaneValueInt(3, 8));
    try t30.expectEqual(MatchStatus.no_match, sgmatchCore(&heap, state, pat));
    // pos past the end (empty-match bump at EOS shape).
    try t30.expect(state.setInLaneValueInt(3, 9));
    try t30.expectEqual(MatchStatus.no_match, sgmatchCore(&heap, state, pat));

    // Pattern-identity mismatch (poked state[2], round-2 B02).
    const other = try heap.intern("%d+");
    try t30.expect(state.setInLaneValueInt(3, 0));
    try t30.expectEqual(MatchStatus.pattern_mismatch, sgmatchCore(&heap, state, other));

    // Non-string subject (poked state[1]).
    const bad = try heap.newTable();
    try bad.set(std.testing.allocator, Value.int(1), Value.int(7));
    try bad.set(std.testing.allocator, Value.int(2), Value.heap(@constCast(&pat.header)));
    try bad.set(std.testing.allocator, Value.int(3), Value.int(0));
    try t30.expectEqual(MatchStatus.bad_type, sgmatchCore(&heap, bad, pat));
}

test "doc 30: sgmatchCore B03 layout checks — hash-resident / non-int / missing [3]" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("x y");
    const pat = try heap.intern("%a+");

    // [3] holds a float -> bad_layout.
    const t_f = try heap.newTable();
    try t_f.set(std.testing.allocator, Value.int(1), Value.heap(@constCast(&subj.header)));
    try t_f.set(std.testing.allocator, Value.int(2), Value.heap(@constCast(&pat.header)));
    try t_f.set(std.testing.allocator, Value.int(3), Value.float(0.0));
    try t30.expectEqual(MatchStatus.bad_layout, sgmatchCore(&heap, t_f, pat));

    // [3] missing entirely -> bad_layout.
    const t_m = try heap.newTable();
    try t_m.set(std.testing.allocator, Value.int(1), Value.heap(@constCast(&subj.header)));
    try t_m.set(std.testing.allocator, Value.int(2), Value.heap(@constCast(&pat.header)));
    try t30.expectEqual(MatchStatus.bad_layout, sgmatchCore(&heap, t_m, pat));

    // Negative pos (user poke; tier-0 would clamp — we fail closed).
    const t_n = try makeGmatchState(&heap, @constCast(subj), @constCast(pat), -1);
    try t30.expectEqual(MatchStatus.bad_layout, sgmatchCore(&heap, t_n, pat));
}

test "doc 30: sgmatchCore empty-match bump (progress rule, S-D step)" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const subj = try heap.intern("aé");
    const pat = try heap.intern("x*"); // empty match everywhere
    const state = try makeGmatchState(&heap, subj, pat, 0);
    const sc = &heap.match_scratch;
    // Empty match at 0 -> bump by 1 (ASCII 'a').
    try t30.expectEqual(MatchStatus.ok, sgmatchCore(&heap, state, pat));
    try t30.expectEqual(@as(u64, 1), sc.words[2 * gc.MatchScratch.slot_next_pos]);
    // Empty match at 1 -> bump by the whole code point 'é' (2 bytes).
    try t30.expect(state.setInLaneValueInt(3, 1));
    try t30.expectEqual(MatchStatus.ok, sgmatchCore(&heap, state, pat));
    try t30.expectEqual(@as(u64, 3), sc.words[2 * gc.MatchScratch.slot_next_pos]);
    // Empty match at end-of-string -> bump to len+1 (the exhaustion cursor).
    try t30.expect(state.setInLaneValueInt(3, 3));
    try t30.expectEqual(MatchStatus.ok, sgmatchCore(&heap, state, pat));
    try t30.expectEqual(@as(u64, 4), sc.words[2 * gc.MatchScratch.slot_next_pos]);
    try t30.expect(state.setInLaneValueInt(3, 4));
    try t30.expectEqual(MatchStatus.no_match, sgmatchCore(&heap, state, pat));
}

test "doc 30: table B03 helpers — inLaneValueIntCell / setInLaneValueInt" {
    var heap = gc.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const s = try heap.intern("s");
    const t = try makeGmatchState(&heap, s, s, 7);
    try t30.expectEqual(@as(i64, 7), t.inLaneValueIntCell(3).?);
    try t30.expect(t.setInLaneValueInt(3, 42));
    try t30.expectEqual(@as(i64, 42), t.inLaneValueIntCell(3).?);
    try t30.expectEqual(Value.int(42), t.getInt(3)); // visible through the normal read path
    // Out-of-extent key and non-int cell refuse.
    try t30.expect(t.inLaneValueIntCell(99) == null);
    try t30.expect(!t.setInLaneValueInt(99, 1));
    try t30.expect(t.inLaneValueIntCell(1) == null); // holds a string
    try t30.expect(!t.setInLaneValueInt(1, 1));
}
