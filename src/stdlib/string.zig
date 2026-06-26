//! lune stdlib — the `string` library (non-pattern subset).
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
const unicode_case = @import("../gen/unicode_case.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Table = table_mod.Table;
const String = string_mod.String;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// The hidden numeric iterator `gmatch` hands back, mirroring `base.zig`'s
/// `@ipairs_iter`: a non-identifier name user code can never spell, installed as
/// a normal global native (so it is a GC root and keyframe-restorable by name).
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

/// Fetch the native installed under `name` as a callable `Value`.
fn globalNative(vm: *Vm, name: []const u8) anyerror!Value {
    return vm.globals.get(try vm.heap.internValue(name));
}

/// Fetch argument `i` (0-based) as string bytes, or raise the located Lua
/// `bad argument #<i+1> to '<fn>' (string expected, got <type|no value>)`.
fn strArg(vm: *Vm, args: []const Value, i: usize) anyerror![]const u8 {
    if (i >= args.len) return vm.badArg(i + 1, "string", null);
    return interp.strBytes(args[i]) orelse vm.badArg(i + 1, "string", args[i]);
}

/// Fetch an optional integer argument (truncating an integral float). Returns
/// `default` when absent; raises the located Lua bad-argument error for a present
/// non-number, and the "number has no integer representation" reason for a
/// non-integral float.
fn optIntArg(vm: *Vm, args: []const Value, i: usize, default: i64) anyerror!i64 {
    if (i >= args.len or args[i].isNil()) return default;
    const v = args[i];
    if (v.isInt()) return v.asInt();
    if (v.isFloat()) {
        const f = v.asFloat();
        const two_pow_63 = 9223372036854775808.0;
        if (!std.math.isFinite(f) or @trunc(f) != f or f < -two_pow_63 or f >= two_pow_63) {
            return vm.badArgReason(i + 1, "number has no integer representation");
        }
        return @intFromFloat(f);
    }
    return vm.badArg(i + 1, "number", v);
}

/// Lua's `posrelat`: map a possibly-negative 1-based position to an absolute
/// 1-based position against a string of length `len`. A negative `pos` counts
/// from the end (`-1` = last); the result is *not* yet clamped to `[1, len]`.
fn posRelat(pos: i64, len: usize) i64 {
    if (pos >= 0) return pos;
    const l: i64 = @intCast(len);
    if (-pos > l) return 0;
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
/// (Like `strArg`, lune does not coerce a number here; a non-string raises.)
fn strObjArg(vm: *Vm, args: []const Value, i: usize) anyerror!*const String {
    if (i >= args.len) return vm.badArg(i + 1, "string", null);
    const v = args[i];
    if (!v.isHeap() or v.heapType() != .string) return vm.badArg(i + 1, "string", v);
    return String.fromHeader(v.asHeap());
}

/// Count Unicode code points in valid UTF-8 `s` (every non-continuation byte
/// starts a code point). Branch-light; used for code-point-aware field widths in
/// `string.format` so `%Ns`/`%Nc` align by character, consistent with `#s`.
fn cpCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
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

/// Decode the code point starting at byte `off` in valid UTF-8 `s`, returning the
/// scalar value and the byte length of its sequence. Total (U+FFFD / 1-byte step
/// on malformed input, which does not occur for a valid string).
fn decodeAt(s: []const u8, off: usize) struct { cp: u21, len: usize } {
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
    if (code < 0 or code > 0x10FFFF) return vm.badArgReason(argn, "value out of range");
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(code), &tmp) catch
        return vm.badArgReason(argn, "value out of range");
    try buf.appendSlice(vm.gpa, tmp[0..n]);
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
    const clen = s.cpLen();

    var i = posRelat(try optIntArg(vm, args, 1, 1), clen);
    var j = posRelat(try optIntArg(vm, args, 2, -1), clen);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(clen))) j = @intCast(clen);
    if (i > j) return vm.heap.internValue(""); // empty

    const bytes = s.bytes();
    const start = charByteOffset(bytes, @intCast(i));
    const end = charByteOffset(bytes, @intCast(j + 1));
    return vm.heap.internValue(bytes[start..end]);
}

/// `string.reverse(s)` — characters reversed (S-B): each UTF-8 sequence is moved
/// as a unit to its mirrored position, so multibyte characters survive intact.
fn sReverse(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const bytes = s.bytes();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.resize(vm.gpa, bytes.len);

    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(std.unicode.utf8ByteSequenceLength(bytes[off]) catch 1, bytes.len - off);
        const dst = bytes.len - off - n; // mirror this char's bytes (in order)
        @memcpy(buf.items[dst .. dst + n], bytes[off .. off + n]);
        off += n;
    }
    return vm.heap.internValue(buf.items);
}

/// `string.upper(s)` — Unicode simple (1:1) uppercase (default, locale-independent).
fn sUpper(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return mapCaseUnicode(ctx, args, .upper);
}

/// `string.lower(s)` — Unicode simple (1:1) lowercase (default, locale-independent).
fn sLower(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return mapCaseUnicode(ctx, args, .lower);
}

/// Simple case mapping over code points (S-C, design doc 06). ASCII (`< 0x80`) is
/// a branch-free fast path; above it the vendored `unicode_case` table maps one
/// code point to one (count-preserving — simple mapping never changes the code-
/// point count). The active Unicode version is pinned as a session effect
/// (`vm.noteUnicodeVersion`) so the result stays byte-identical on replay even as
/// the table churns. Output is valid UTF-8 by construction (every emitted scalar
/// is re-encoded), so `internValue` needs no re-validation.
fn mapCaseUnicode(ctx: *anyopaque, args: []const Value, comptime kind: enum { upper, lower }) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(vm, args, 0);
    try interp.noteUnicodeVersion(vm);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    var off: usize = 0;
    while (off < s.len) {
        const b = s[off];
        if (b < 0x80) { // ASCII fast path — one byte, one character
            const c = switch (kind) {
                .upper => std.ascii.toUpper(b),
                .lower => std.ascii.toLower(b),
            };
            try buf.append(vm.gpa, c);
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
            try buf.appendSlice(vm.gpa, enc[0..n]);
        } else |_| {
            // The table only ever maps to assigned, non-surrogate scalars, so this
            // is unreachable in practice; on the impossible chance, keep the input
            // sequence verbatim rather than corrupting the string.
            try buf.appendSlice(vm.gpa, s[off .. off + d.len]);
        }
        off += d.len;
    }
    return vm.heap.internValue(buf.items);
}

/// `string.rep(s, n [, sep])` — `s` repeated `n` times, joined by `sep`
/// (default ""). `n <= 0` → empty string.
fn sRep(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(vm, args, 0);
    const n = try optIntArg(vm, args, 1, 0);
    const sep: []const u8 = if (args.len >= 3 and !args[2].isNil())
        (interp.strBytes(args[2]) orelse return vm.badArg(3, "string", args[2]))
    else
        "";
    if (n <= 0) return vm.heap.internValue("");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    const count: usize = @intCast(n);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (k != 0) try buf.appendSlice(vm.gpa, sep);
        try buf.appendSlice(vm.gpa, s);
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
    for (args, 0..) |arg, idx| {
        // `string.char` arguments are mandatory code points: an explicit nil is a
        // bad argument, not a default-to-zero (which would silently emit NUL).
        if (arg.isNil()) return vm.badArg(idx + 1, "number", arg);
        const code = try optIntArg(vm, args, idx, 0); // arg is non-nil → default unused
        try appendCodepoint(vm, idx + 1, code, &buf);
    }
    return vm.heap.internValue(buf.items);
}

/// Resolve a 1-based inclusive **character** range `[i, j]` over `clen` code
/// points, with Lua's negative-index + clamping. `i` defaults to 1, `j` to `i`.
/// An empty range is reported as `lo > hi`.
fn charRange(vm: *Vm, args: []const Value, clen: usize) anyerror!struct { lo: usize, hi: usize } {
    const i_raw = try optIntArg(vm, args, 1, 1);
    const j_raw = try optIntArg(vm, args, 2, i_raw);
    var i = posRelat(i_raw, clen);
    var j = posRelat(j_raw, clen);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(clen))) j = @intCast(clen);
    if (i > j) return .{ .lo = 1, .hi = 0 }; // empty (lo > hi)
    return .{ .lo = @intCast(i), .hi = @intCast(j) };
}

/// `string.codepoint(s [, i [, j]])` — the Unicode scalar values of the
/// characters `s[i..j]`, one integer per result (a `multi` native). Replaces
/// Lua's byte-returning `string.byte` (raw bytes now come from `s:encode()`).
/// `i` defaults to 1, `j` to `i`; positions are **character** indices.
fn sCodepoint1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const r = try charRange(vm, args, s.cpLen());
    if (r.lo > r.hi) return Value.nil();
    const bytes = s.bytes();
    const d = decodeAt(bytes, charByteOffset(bytes, r.lo));
    return Value.int(@intCast(d.cp));
}

fn sCodepointN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const s = try strObjArg(vm, args, 0);
    const r = try charRange(vm, args, s.cpLen());
    if (r.lo > r.hi) return 0;
    const bytes = s.bytes();
    var off = charByteOffset(bytes, r.lo);
    const count = r.hi - r.lo + 1;
    var k: usize = 0;
    while (k < count and k < out.len and off < bytes.len) : (k += 1) {
        const d = decodeAt(bytes, off);
        out[k] = Value.int(@intCast(d.cp));
        off += d.len;
    }
    return k;
}

/// The hidden iterator `s:codes()` hands back, mirroring `@gmatch_iter`: a
/// non-spellable global native that is a GC root and keyframe-restorable by name.
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
    const iter = try globalNative(vm, codes_iter_name);
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
    return globalNative(vm, codes_iter_name);
}

/// `@codes_iter(state)` — decode the character at the stored byte cursor, advance
/// the cursor past it and the emitted-count by one, and return
/// `(charIndex, codepoint)`; 0 results when the cursor reaches the end.
/// `charIndex` is the 1-based character ordinal (threaded in `state[3]`, so each
/// step is O(1)).
fn codesAuxCore(vm: *Vm, args: []const Value, out: *[2]Value) anyerror!usize {
    const st = try tableArg(vm, args, 0);
    const s = interp.strBytes(st.getInt(1)) orelse return error.TypeError;
    const pos_v = st.getInt(2);
    var pos: usize = if (pos_v.isInt() and pos_v.asInt() >= 0) @intCast(pos_v.asInt()) else 0;
    const emitted_v = st.getInt(3);
    const emitted: i64 = if (emitted_v.isInt()) emitted_v.asInt() else 0;
    if (pos >= s.len) return 0; // exhausted

    const d = decodeAt(s, pos);
    pos += d.len;
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

/// A parsed `%`-conversion specifier: `%[-+ 0#][width][.prec]<conv>`.
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

/// Coerce a `string.format` numeric argument to a signed integer, truncating a
/// float toward zero. Errors on a non-number or an out-of-range / non-finite float.
fn argToInt(v: Value) error{TypeError}!i64 {
    switch (v.tag) {
        .int => return v.asInt(),
        .float => {
            const f = v.asFloat();
            if (!std.math.isFinite(f) or f >= 9.223372036854776e18 or f < -9.223372036854776e18) {
                return error.TypeError;
            }
            return @intFromFloat(@trunc(f));
        },
        else => return error.TypeError,
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
// Zig's `std.fmt.float.render` is the digit engine, but its surface differs from
// C in two ways lune must paper over for LuaJIT/printf parity: the scientific
// exponent is bare (`e2`, not `e+02`), and there is no `%g`-style significant-
// digit mode. These helpers bridge both.

/// `%e`/`%E` magnitude: Zig scientific digits with the exponent normalised to a
/// sign and at least two digits (`1.5e2` → `1.500000e+02`). `frac` is the number
/// of fractional digits; `exp_char` is 'e' or 'E'. Writes into `dst`.
fn renderEng(dst: []u8, mag: f64, frac: usize, exp_char: u8) ![]const u8 {
    var tmp: [512]u8 = undefined;
    const sci = std.fmt.float.render(&tmp, mag, .{ .mode = .scientific, .precision = frac }) catch
        return error.TypeError;
    const ei = std.mem.indexOfScalar(u8, sci, 'e') orelse return error.TypeError;
    const mant = sci[0..ei];
    var raw = sci[ei + 1 ..]; // Zig emits an optional '-' then unpadded digits
    var neg = false;
    if (raw.len > 0 and raw[0] == '-') {
        neg = true;
        raw = raw[1..];
    } else if (raw.len > 0 and raw[0] == '+') {
        raw = raw[1..];
    }
    var w: usize = 0;
    @memcpy(dst[w..][0..mant.len], mant);
    w += mant.len;
    dst[w] = exp_char;
    w += 1;
    dst[w] = if (neg) '-' else '+';
    w += 1;
    var pad: usize = if (raw.len < 2) 2 - raw.len else 0; // C: ≥2 exponent digits
    while (pad > 0) : (pad -= 1) {
        dst[w] = '0';
        w += 1;
    }
    @memcpy(dst[w..][0..raw.len], raw);
    w += raw.len;
    return dst[0..w];
}

/// The decimal exponent `%e` with `sig` significant digits would use, for `%g`'s
/// representation choice. Returns 0 on any render hiccup (only reached for finite
/// magnitudes, where render does not fail).
fn floatExp(mag: f64, sig: usize) i32 {
    var tmp: [512]u8 = undefined;
    const sci = std.fmt.float.render(&tmp, mag, .{
        .mode = .scientific,
        .precision = if (sig > 0) sig - 1 else 0,
    }) catch return 0;
    const ei = std.mem.indexOfScalar(u8, sci, 'e') orelse return 0;
    return std.fmt.parseInt(i32, sci[ei + 1 ..], 10) catch 0;
}

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
    const X = floatExp(mag, p);
    var buf: [512]u8 = undefined;
    var body: []const u8 = undefined;
    if (X >= -4 and X < @as(i32, @intCast(p))) {
        const frac: usize = @intCast(@as(i32, @intCast(p)) - 1 - X); // ≥0 since X<P
        body = std.fmt.float.render(&buf, mag, .{ .mode = .decimal, .precision = frac }) catch
            return error.TypeError;
    } else {
        body = try renderEng(&buf, mag, p - 1, exp_char);
    }
    if (hash) {
        @memcpy(dst[0..body.len], body);
        return dst[0..body.len];
    }
    return stripZeros(dst, body);
}

/// `string.format(fmt, ...)` — a focused C-`printf` supporting Lua's conversions:
/// `d i u o x X c` (integers), `f F e E g G` (floats), `s` (strings, precision =
/// max length), `q` (Lua-quoted), and `%%`. Honors the `- + space 0 #` flags,
/// width, and precision.
fn sFormat(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len < 1) return error.TypeError;
    const fmt = interp.strBytes(args[0]) orelse return error.TypeError;

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
        if (i >= fmt.len) return error.TypeError;
        if (fmt[i] == '%') {
            try out.append(gpa, '%');
            i += 1;
            continue;
        }

        var spec: FormatSpec = .{};
        // flags
        flags: while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.minus = true,
                '0' => spec.zero = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.hash = true,
                else => break :flags,
            }
        }
        // width
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
            spec.width = spec.width * 10 + (fmt[i] - '0');
        }
        // precision
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                p = p * 10 + (fmt[i] - '0');
            }
            spec.precision = p;
        }
        if (i >= fmt.len) return error.TypeError;
        spec.conv = fmt[i];
        i += 1;

        // `%%` already handled; every remaining conversion consumes one argument.
        if (argi >= args.len) return error.TypeError;
        const arg = args[argi];
        argi += 1;

        var nbuf: [512]u8 = undefined;
        switch (spec.conv) {
            'd', 'i' => {
                const n = try argToInt(arg);
                const neg = n < 0;
                const un: u64 = @bitCast(n);
                const mag: u64 = if (neg) (~un +% 1) else un; // |n| in two's complement (safe at minInt)
                const digits = std.fmt.bufPrint(&nbuf, "{d}", .{mag}) catch unreachable;
                try emitNumeric(&out, gpa, signPrefix(neg, spec), digits, spec);
            },
            'u' => {
                const n = try argToInt(arg);
                const digits = std.fmt.bufPrint(&nbuf, "{d}", .{@as(u64, @bitCast(n))}) catch unreachable;
                try emitNumeric(&out, gpa, "", digits, spec);
            },
            'o' => {
                const n = try argToInt(arg);
                const digits = std.fmt.bufPrint(&nbuf, "{o}", .{@as(u64, @bitCast(n))}) catch unreachable;
                const prefix: []const u8 = if (spec.hash and !(digits.len == 1 and digits[0] == '0')) "0" else "";
                try emitNumeric(&out, gpa, prefix, digits, spec);
            },
            'x', 'X' => {
                const n = try argToInt(arg);
                const u: u64 = @bitCast(n);
                const digits = if (spec.conv == 'x')
                    std.fmt.bufPrint(&nbuf, "{x}", .{u}) catch unreachable
                else
                    std.fmt.bufPrint(&nbuf, "{X}", .{u}) catch unreachable;
                const prefix: []const u8 = if (spec.hash and u != 0)
                    (if (spec.conv == 'x') "0x" else "0X")
                else
                    "";
                try emitNumeric(&out, gpa, prefix, digits, spec);
            },
            'c' => {
                // S-B: `%c` emits the one-code-point string for this scalar value
                // (UTF-8), not a single truncated byte. Range/surrogate-checked.
                const n = try argToInt(arg);
                if (n < 0 or n > 0x10FFFF) return error.TypeError;
                var tmp: [4]u8 = undefined;
                const ln = std.unicode.utf8Encode(@intCast(n), &tmp) catch return error.TypeError;
                // Route through emitString so the width pads by one **character**
                // (code point), not by the UTF-8 byte length of the encoding.
                try emitString(&out, gpa, tmp[0..ln], .{ .minus = spec.minus, .width = spec.width });
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                if (!arg.isNumber()) return error.TypeError;
                const f = arg.toFloat();
                const neg = std.math.signbit(f) and !std.math.isNan(f);
                const mag = if (neg) -f else f;
                const upper = spec.conv == 'F' or spec.conv == 'E' or spec.conv == 'G';
                var rbuf: [512]u8 = undefined;
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
                } else switch (spec.conv) {
                    'f', 'F' => body = std.fmt.float.render(&rbuf, mag, .{
                        .mode = .decimal,
                        .precision = spec.precision orelse 6,
                    }) catch return error.TypeError,
                    'e', 'E' => body = try renderEng(&rbuf, mag, spec.precision orelse 6, if (upper) 'E' else 'e'),
                    else => { // 'g'/'G': C significant-digit form, default precision 6, min 1
                        const p = blk: {
                            const pp = spec.precision orelse 6;
                            break :blk if (pp == 0) 1 else pp;
                        };
                        body = try renderG(&rbuf, mag, p, if (upper) 'E' else 'e', spec.hash);
                    },
                }
                try emitNumeric(&out, gpa, signPrefix(neg, spec), body, fspec);
            },
            's' => {
                // S-B: `%.Ns` precision counts **code points**, not bytes. For
                // ASCII (incl. coerced numbers) this equals `min(N, len)`.
                if (interp.strBytes(arg)) |full| {
                    const body = if (spec.precision) |p| full[0..charByteOffset(full, p + 1)] else full;
                    try emitString(&out, gpa, body, spec);
                } else if (arg.isNumber()) {
                    var sbuf: [64]u8 = undefined;
                    const full = try interp.coerceConcat(arg, &sbuf);
                    const body = if (spec.precision) |p| full[0..charByteOffset(full, p + 1)] else full;
                    try emitString(&out, gpa, body, spec);
                } else {
                    try formatNonStr(&out, gpa, arg, spec);
                }
            },
            'q' => {
                const s = interp.strBytes(arg) orelse return error.TypeError;
                try out.append(gpa, '"');
                for (s) |qc| switch (qc) {
                    '"' => try out.appendSlice(gpa, "\\\""),
                    '\\' => try out.appendSlice(gpa, "\\\\"),
                    '\n' => try out.appendSlice(gpa, "\\n"),
                    '\r' => try out.appendSlice(gpa, "\\r"),
                    0 => try out.appendSlice(gpa, "\\0"),
                    else => try out.append(gpa, qc),
                };
                try out.append(gpa, '"');
            },
            else => return error.TypeError, // unknown conversion
        }
    }

    return vm.heap.internValue(out.items);
}

/// Emit a string field with width + `-` justification (the `0` flag is ignored
/// for `%s`, matching C/Lua).
fn emitString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, body: []const u8, spec: FormatSpec) !void {
    // S-B: the field width is a **code-point** count (consistent with `#s`), so a
    // multibyte body pads by characters, not bytes.
    const width_units = cpCount(body);
    const pad: usize = if (spec.width > width_units) spec.width - width_units else 0;
    if (spec.minus) {
        try out.appendSlice(gpa, body);
        try appendN(out, gpa, ' ', pad);
    } else {
        try appendN(out, gpa, ' ', pad);
        try out.appendSlice(gpa, body);
    }
}

/// `%s` fallback for nil/boolean (Lua applies `tostring`).
fn formatNonStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: Value, spec: FormatSpec) !void {
    const body: []const u8 = switch (v.tag) {
        .nil => "nil",
        .boolean => if (v.asBool()) "true" else "false",
        else => return error.TypeError,
    };
    const trimmed = if (spec.precision) |p| body[0..@min(p, body.len)] else body;
    try emitString(out, gpa, trimmed, spec);
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
/// result lands on a code-point boundary (`charByteOffset`). `pos == clen + 1`
/// (one past the last char) maps to `s.len` — the empty-match-at-end position.
fn resolveInit(init_raw: i64, s: []const u8) ?usize {
    const clen = cpCount(s);
    var pos = posRelat(init_raw, clen); // 1-based char position (may be 0)
    if (pos < 1) pos = 1;
    if (pos > @as(i64, @intCast(clen)) + 1) return null; // start past end+1
    return charByteOffset(s, @intCast(pos));
}

/// Convert a 0-based byte offset on a code-point boundary in `s` to a 1-based
/// **character** index (S-D boundary translation). `off == s.len` → `cpCount + 1`.
fn byteToChar(s: []const u8, off: usize) usize {
    return cpCount(s[0..off]) + 1;
}

/// Convert capture `i` of a completed match to a `Value`, mirroring
/// `push_onecapture`: index `i >= level` is only valid at `i == 0` (the whole
/// match, taken from `whole`); a position capture becomes a 1-based integer; a
/// string capture is interned.
fn captureValue(vm: *Vm, ms: *const pattern.MatchState, i: usize, whole: ?[2]usize) anyerror!Value {
    if (i >= ms.level) {
        if (i == 0) {
            const w = whole orelse return error.InvalidCapture;
            return vm.heap.internValue(ms.src[w[0]..w[1]]);
        }
        return error.InvalidCapture;
    }
    const cap = ms.captures[i];
    if (cap.len == pattern.cap_unfinished) return error.MalformedPattern;
    if (cap.len == pattern.cap_position) return Value.int(@intCast(byteToChar(ms.src, cap.init)));
    const l: usize = @intCast(cap.len);
    return vm.heap.internValue(ms.src[cap.init .. cap.init + l]);
}

/// Number of capture results a match produces (`push_captures`'s `nlevels`).
fn numCaptures(ms: *const pattern.MatchState, whole: ?[2]usize) usize {
    if (ms.level == 0) return if (whole != null) 1 else 0;
    return ms.level;
}

/// Write every capture value into `buf`, returning the count.
fn writeCaptures(vm: *Vm, ms: *const pattern.MatchState, whole: ?[2]usize, buf: []Value) anyerror!usize {
    const n = numCaptures(ms, whole);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = try captureValue(vm, ms, i, whole);
    return n;
}

// -- find -------------------------------------------------------------------

/// Core of `string.find(s, pat [, init [, plain]])`. Writes results into `buf`
/// and returns the count: `(start, end, captures...)` on a match, or a single
/// `nil` on no match.
fn findCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const s = try strArg(vm, args, 0);
    const pat = try strArg(vm, args, 1);
    const st = resolveInit(try optIntArg(vm, args, 2, 1), s) orelse {
        buf[0] = Value.nil();
        return 1;
    };
    const plain = args.len >= 4 and args[3].isTruthy();

    if (plain or !pattern.hasSpecials(pat)) {
        // Plain substring search (empty needle matches at `st`). Byte offsets are
        // converted to 1-based character indices at the seam (S-D).
        if (pat.len == 0) {
            buf[0] = Value.int(@intCast(byteToChar(s, st)));
            buf[1] = Value.int(@intCast(byteToChar(s, st) - 1));
            return 2;
        }
        if (st <= s.len) {
            // A plain substring of valid UTF-8 lands on a code-point boundary.
            if (std.mem.indexOfPos(u8, s, st, pat)) |q| {
                buf[0] = Value.int(@intCast(byteToChar(s, q)));
                buf[1] = Value.int(@intCast(cpCount(s[0 .. q + pat.len])));
                return 2;
            }
        }
        buf[0] = Value.nil();
        return 1;
    }

    var ms = pattern.MatchState.init(s, pat);
    var pp: usize = 0;
    const anchor = pat.len > 0 and pat[0] == '^';
    if (anchor) pp = 1;
    var sp = st;
    while (true) {
        ms.reset();
        if (try ms.match(sp, pp)) |e| {
            buf[0] = Value.int(@intCast(byteToChar(s, sp)));
            buf[1] = Value.int(@intCast(cpCount(s[0..e])));
            const nc = try writeCaptures(vm, &ms, null, buf[2..]);
            return 2 + nc;
        }
        if (sp >= s.len or anchor) break;
        sp += ms.seqLen(sp);
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
    const s = try strArg(vm, args, 0);
    const pat = try strArg(vm, args, 1);
    const st = resolveInit(try optIntArg(vm, args, 2, 1), s) orelse {
        buf[0] = Value.nil();
        return 1;
    };

    var ms = pattern.MatchState.init(s, pat);
    var pp: usize = 0;
    const anchor = pat.len > 0 and pat[0] == '^';
    if (anchor) pp = 1;
    var sp = st;
    while (true) {
        ms.reset();
        if (try ms.match(sp, pp)) |e| {
            return try writeCaptures(vm, &ms, .{ sp, e }, buf);
        }
        if (sp >= s.len or anchor) break;
        sp += ms.seqLen(sp);
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
    const iter = try globalNative(vm, gmatch_iter_name);
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
    return globalNative(vm, gmatch_iter_name);
}

/// `@gmatch_iter(state)` — LuaJIT's `gmatch_aux`: scan forward from the stored
/// position for the next match, advance the position (forcing progress past an
/// empty match), and return the captures; 0 results when exhausted.
fn gmatchAuxCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const st = try tableArg(vm, args, 0);
    const s = interp.strBytes(st.getInt(1)) orelse return error.TypeError;
    const pat = interp.strBytes(st.getInt(2)) orelse return error.TypeError;
    const pos_v = st.getInt(3);
    var src: usize = if (pos_v.isInt() and pos_v.asInt() >= 0) @intCast(pos_v.asInt()) else 0;

    var ms = pattern.MatchState.init(s, pat);
    while (src <= s.len) : (src += @max(ms.seqLen(src), 1)) {
        ms.reset();
        if (try ms.match(src, 0)) |e| {
            // Ensure progress on an empty match by stepping a whole code point
            // (S-D); `@max(…, 1)` guarantees termination at end-of-string.
            const newpos = if (e == src) e + @max(ms.seqLen(e), 1) else e;
            try st.set(vm.gpa, Value.int(3), Value.int(@intCast(newpos)));
            return try writeCaptures(vm, &ms, .{ src, e }, buf);
        }
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
/// `%1`–`%9` (captures), and `%%`/`%x` (literal).
fn addReplString(vm: *Vm, out: *std.ArrayList(u8), ms: *const pattern.MatchState, repl: []const u8, s_off: usize, e_off: usize) anyerror!void {
    var i: usize = 0;
    while (i < repl.len) : (i += 1) {
        const c = repl[i];
        if (c != '%') {
            try out.append(vm.gpa, c);
            continue;
        }
        i += 1;
        if (i >= repl.len) return error.MalformedPattern; // trailing '%' in replacement
        const d = repl[i];
        if (!std.ascii.isDigit(d)) {
            try out.append(vm.gpa, d); // %% → %, %x → x
        } else if (d == '0') {
            try out.appendSlice(vm.gpa, ms.src[s_off..e_off]); // whole match
        } else {
            const v = try captureValue(vm, ms, d - '1', .{ s_off, e_off });
            try appendValueText(vm, out, v);
        }
    }
}

/// `add_value` for a table replacement: look up `repl[firstCapture]`; a
/// nil/false result keeps the original text.
fn addReplTable(vm: *Vm, out: *std.ArrayList(u8), ms: *const pattern.MatchState, repl: *Table, s_off: usize, e_off: usize) anyerror!void {
    const key = try captureValue(vm, ms, 0, .{ s_off, e_off });
    const v = repl.get(key);
    if (!v.isTruthy()) {
        try out.appendSlice(vm.gpa, ms.src[s_off..e_off]); // keep original
        return;
    }
    if (interp.strBytes(v) != null or v.isNumber()) {
        try appendValueText(vm, out, v);
        return;
    }
    return error.TypeError; // invalid replacement value
}

/// `add_value` for a function replacement: call `repl(captures…)` (the explicit
/// captures, or the whole match when the pattern has none) via `Vm.callValue`. A
/// nil/false result keeps the original text; a string/number substitutes; any
/// other type is an invalid replacement (`TypeError`).
///
/// GC: `captureValue` interns the capture strings with no intervening safepoint,
/// and `callValue` copies them into the rooted VM stack before running `repl`, so
/// a collection triggered inside `repl` cannot sweep them. The result is captured
/// before `callValue` shrinks `stack_top`; everything after is pure native code
/// (no collection), so `rv` stays valid until appended.
fn addReplFunction(vm: *Vm, out: *std.ArrayList(u8), ms: *const pattern.MatchState, repl: Value, s_off: usize, e_off: usize) anyerror!void {
    const ncap: usize = if (ms.level > 0) ms.level else 1;
    var caps: [pattern.max_captures]Value = undefined;
    var k: usize = 0;
    while (k < ncap) : (k += 1) caps[k] = try captureValue(vm, ms, k, .{ s_off, e_off });
    var r: [1]Value = .{Value.nil()};
    const n = try vm.callValue(repl, caps[0..ncap], r[0..1]);
    const rv = if (n >= 1) r[0] else Value.nil();
    if (!rv.isTruthy()) {
        try out.appendSlice(vm.gpa, ms.src[s_off..e_off]); // keep original
        return;
    }
    if (interp.strBytes(rv) != null or rv.isNumber()) {
        try appendValueText(vm, out, rv);
        return;
    }
    return error.TypeError; // invalid replacement value
}

/// Core of `string.gsub(s, pat, repl [, n])` → `(result, count)`. `repl` may be a
/// string/number, a table, or a function (called per match via `Vm.callValue`).
fn gsubCore(vm: *Vm, args: []const Value, buf: *ResultBuf) anyerror!usize {
    const s = try strArg(vm, args, 0);
    const pat = try strArg(vm, args, 1);
    if (args.len < 3) return vm.badArg(3, "string/function/table", null);
    const repl = args[2];

    // Classify the replacement up front (bad kinds error before any work).
    const repl_table: ?*Table = if (repl.isHeap() and repl.heapType() == .table)
        Table.fromHeader(repl.asHeap())
    else
        null;
    const repl_fn: ?Value = if (repl_table == null and repl.isHeap() and
        (repl.heapType() == .function or repl.heapType() == .native)) repl else null;
    if (repl_table == null and repl_fn == null and interp.strBytes(repl) == null and !repl.isNumber())
        return vm.badArg(3, "string/function/table", repl);
    const repl_str: ?[]const u8 = if (repl_table == null and repl_fn == null)
        (interp.strBytes(repl) orelse null)
    else
        null;

    const max_n: i64 = if (args.len >= 4 and !args[3].isNil())
        try optIntArg(vm, args, 3, 0)
    else
        @as(i64, @intCast(s.len + 1));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);

    var ms = pattern.MatchState.init(s, pat);
    var pp: usize = 0;
    const anchor = pat.len > 0 and pat[0] == '^';
    if (anchor) pp = 1;

    var src: usize = 0;
    var count: i64 = 0;
    while (count < max_n) {
        ms.reset();
        const e_opt = try ms.match(src, pp);
        if (e_opt) |e| {
            count += 1;
            if (repl_table) |t| {
                try addReplTable(vm, &out, &ms, t, src, e);
            } else if (repl_fn) |f| {
                try addReplFunction(vm, &out, &ms, f, src, e);
            } else if (repl_str) |r| {
                try addReplString(vm, &out, &ms, r, src, e);
            } else {
                // numeric replacement: coerce to its text, no captures.
                try appendValueText(vm, &out, repl);
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
        } else if (src < s.len) {
            const w = ms.seqLen(src);
            try out.appendSlice(vm.gpa, s[src .. src + w]);
            src += w;
        } else break;
        if (anchor) break;
    }
    try out.appendSlice(vm.gpa, s[src..]); // tail
    buf[0] = try vm.heap.internValue(out.items);
    buf[1] = Value.int(count);
    return 2;
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
/// (an ordinary lune array: a table with integer keys `1..#bytes`, each value an
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
    .{ .name = "string.len", .func = &sLen, .module = "string", .field = "len" },
    .{ .name = "string.sub", .func = &sSub, .module = "string", .field = "sub" },
    .{ .name = "string.reverse", .func = &sReverse, .module = "string", .field = "reverse" },
    .{ .name = "string.upper", .func = &sUpper, .module = "string", .field = "upper" },
    .{ .name = "string.lower", .func = &sLower, .module = "string", .field = "lower" },
    .{ .name = "string.rep", .func = &sRep, .module = "string", .field = "rep" },
    .{ .name = "string.char", .func = &sChar, .module = "string", .field = "char" },
    // S-B (design doc 06): `string.codepoint` (scalar values at character
    // positions) replaces the byte-returning `string.byte`; `string.codes` is the
    // `(index, codepoint)` iterator. Raw bytes now come from `s:encode()`.
    .{ .name = "string.codepoint", .func = &sCodepoint1, .multi = &sCodepointN, .module = "string", .field = "codepoint" },
    .{ .name = "string.codes", .func = &sCodes1, .multi = &sCodesN, .module = "string", .field = "codes" },
    .{ .name = "string.format", .func = &sFormat, .module = "string", .field = "format" },
    // The text↔bytes boundary (design doc 06, S-A). `encode` is a `string` field
    // so `s:encode()` resolves through the string metatable; `decode` is a plain
    // module field (byte arrays have no metatable, so it stays a free function).
    .{ .name = "string.encode", .func = &sEncode, .module = "string", .field = "encode" },
    .{ .name = "string.decode", .func = &sDecode, .module = "string", .field = "decode" },
    .{ .name = "string.find", .func = &sFind1, .multi = &sFindN, .module = "string", .field = "find" },
    .{ .name = "string.match", .func = &sMatch1, .multi = &sMatchN, .module = "string", .field = "match" },
    .{ .name = "string.gmatch", .func = &sGmatch1, .multi = &sGmatchN, .module = "string", .field = "gmatch" },
    .{ .name = "string.gsub", .func = &sGsub1, .multi = &sGsubN, .module = "string", .field = "gsub" },
    // Hidden iterator `gmatch` returns; a bare global like `@ipairs_iter`.
    .{ .name = gmatch_iter_name, .func = &sGmatchAux1, .multi = &sGmatchAuxN },
    // Hidden iterator `s:codes()` returns (S-B); same hidden-global pattern.
    .{ .name = codes_iter_name, .func = &sCodesAux1, .multi = &sCodesAuxN },
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
    try testing.expectError(error.TypeError, sFormat(@ptrCast(&vm), &.{ try sv(&vm, "%y"), Value.int(1) }));
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

    // Function replacement: `sLen` returns the length of its capture argument as
    // a number, which substitutes for each match.
    const lenfn = try function.Native.create(vm.gpa, &sLen, "lenfn");
    defer lenfn.destroy(vm.gpa);
    n = try sGsubN(@ptrCast(&vm), &.{ try sv(&vm, "hello world"), try sv(&vm, "%w+"), Value.heap(&lenfn.header) }, &out);
    try testing.expectEqualStrings("5 5", bytesOf(out[0]));
    try testing.expectEqual(@as(i64, 2), out[1].asInt());
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
