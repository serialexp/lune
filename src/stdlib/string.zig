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
//! the end and `sub`/`byte` ranges are clamped, never out-of-bounds. `upper`/
//! `lower` are C-locale ASCII only (`A`–`Z` ↔ `a`–`z`), matching lune's fixed
//! locale (determinism: a mutable locale is explicitly excluded, see the CSV).

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const string_mod = @import("../string.zig");

const Value = value.Value;
const Vm = interp.Vm;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// Fetch argument `i` as string bytes, or `TypeError` if missing/non-string.
fn strArg(args: []const Value, i: usize) error{TypeError}![]const u8 {
    if (i >= args.len) return error.TypeError;
    return interp.strBytes(args[i]) orelse error.TypeError;
}

/// Fetch an optional integer argument (truncating an integral float). Returns
/// `default` when absent; `TypeError` for a present non-number or non-integral
/// float.
fn optIntArg(args: []const Value, i: usize, default: i64) error{TypeError}!i64 {
    if (i >= args.len or args[i].isNil()) return default;
    const v = args[i];
    if (v.isInt()) return v.asInt();
    if (v.isFloat()) {
        const f = v.asFloat();
        if (@trunc(f) != f) return error.TypeError;
        return @intFromFloat(f);
    }
    return error.TypeError;
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
// len / sub / reverse / upper / lower / rep
// ---------------------------------------------------------------------------

/// `string.len(s)` — byte length (same as `#s`).
fn sLen(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = try strArg(args, 0);
    return Value.int(@intCast(s.len));
}

/// `string.sub(s, i [, j])` — substring `s[i..j]`, 1-based inclusive, with Lua's
/// negative-index and clamping rules. `j` defaults to `-1` (end of string).
fn sSub(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(args, 0);
    const len = s.len;

    var i = posRelat(try optIntArg(args, 1, 1), len);
    var j = posRelat(try optIntArg(args, 2, -1), len);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(len))) j = @intCast(len);
    if (i > j) return vm.heap.internValue(""); // empty
    return vm.heap.internValue(s[@intCast(i - 1)..@intCast(j)]);
}

/// `string.reverse(s)` — bytes reversed.
fn sReverse(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(args, 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.resize(vm.gpa, s.len);
    for (s, 0..) |c, k| buf.items[s.len - 1 - k] = c;
    return vm.heap.internValue(buf.items);
}

/// `string.upper(s)` — ASCII uppercase (C locale).
fn sUpper(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return mapCase(ctx, args, std.ascii.toUpper);
}

/// `string.lower(s)` — ASCII lowercase (C locale).
fn sLower(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return mapCase(ctx, args, std.ascii.toLower);
}

fn mapCase(ctx: *anyopaque, args: []const Value, comptime f: fn (u8) u8) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(args, 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    try buf.resize(vm.gpa, s.len);
    for (s, 0..) |c, k| buf.items[k] = f(c);
    return vm.heap.internValue(buf.items);
}

/// `string.rep(s, n [, sep])` — `s` repeated `n` times, joined by `sep`
/// (default ""). `n <= 0` → empty string.
fn sRep(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const s = try strArg(args, 0);
    const n = try optIntArg(args, 1, 0);
    const sep: []const u8 = if (args.len >= 3 and !args[2].isNil())
        (interp.strBytes(args[2]) orelse return error.TypeError)
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
// char / byte
// ---------------------------------------------------------------------------

/// `string.char(...)` — build a string from integer byte values (each 0–255).
fn sChar(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    for (args) |a| {
        const code = try optIntArg(&[_]Value{a}, 0, 0);
        if (code < 0 or code > 255) return error.TypeError; // Lua: "value out of range"
        try buf.append(vm.gpa, @intCast(code));
    }
    return vm.heap.internValue(buf.items);
}

/// `string.byte(s [, i [, j]])` — the numeric codes of `s[i..j]`, one per result
/// (a `multi` native). `i` defaults to 1, `j` to `i`; negative/clamped per Lua.
/// Returns the resolved `[lo, hi]` byte range (1-based inclusive, clamped) or an
/// empty range as `lo > hi`.
fn byteRange(args: []const Value, len: usize) error{TypeError}!struct { lo: usize, hi: usize } {
    const i_raw = try optIntArg(args, 1, 1);
    const j_raw = try optIntArg(args, 2, i_raw);
    var i = posRelat(i_raw, len);
    var j = posRelat(j_raw, len);
    if (i < 1) i = 1;
    if (j > @as(i64, @intCast(len))) j = @intCast(len);
    if (i > j) return .{ .lo = 1, .hi = 0 }; // empty (lo > hi)
    return .{ .lo = @intCast(i), .hi = @intCast(j) };
}

fn sByte1(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = try strArg(args, 0);
    const r = try byteRange(args, s.len);
    if (r.lo > r.hi) return Value.nil();
    return Value.int(@intCast(s[r.lo - 1]));
}

fn sByteN(_: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const s = try strArg(args, 0);
    const r = try byteRange(args, s.len);
    if (r.lo > r.hi) return 0;
    var k: usize = 0;
    while (r.lo + k <= r.hi and k < out.len) : (k += 1) {
        out[k] = Value.int(@intCast(s[r.lo - 1 + k]));
    }
    return k;
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
                const n = try argToInt(arg);
                const ch: u8 = @truncate(@as(u64, @bitCast(n)));
                try emitNumeric(&out, gpa, "", &[_]u8{ch}, .{ .minus = spec.minus, .width = spec.width });
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                if (!arg.isNumber()) return error.TypeError;
                const f = arg.toFloat();
                const neg = std.math.signbit(f) and !std.math.isNan(f);
                const mag = if (neg) -f else f;
                const lower = spec.conv == 'f' or spec.conv == 'e' or spec.conv == 'g';
                const mode: std.fmt.float.Mode = switch (spec.conv) {
                    'e', 'E' => .scientific,
                    else => .decimal,
                };
                // `%f/%e` default to 6 fractional digits; `%g` defaults to shortest.
                const prec: ?usize = spec.precision orelse switch (spec.conv) {
                    'g', 'G' => null,
                    else => 6,
                };
                var rbuf: [512]u8 = undefined;
                const rendered = std.fmt.float.render(&rbuf, mag, .{ .mode = mode, .precision = prec }) catch
                    return error.TypeError;
                // `render` lower-cases the exponent 'e'; upper-case for E/G.
                var body = rendered;
                if (!lower) {
                    for (rbuf[0..rendered.len], 0..) |rc, k| {
                        if (rc == 'e') rbuf[k] = 'E';
                    }
                    body = rbuf[0..rendered.len];
                }
                // Float precision is already applied: pass precision=null to emit.
                var fspec = spec;
                fspec.precision = null;
                try emitNumeric(&out, gpa, signPrefix(neg, spec), body, fspec);
            },
            's' => {
                if (interp.strBytes(arg)) |full| {
                    const body = if (spec.precision) |p| full[0..@min(p, full.len)] else full;
                    try emitString(&out, gpa, body, spec);
                } else if (arg.isNumber()) {
                    var sbuf: [64]u8 = undefined;
                    const full = try interp.coerceConcat(arg, &sbuf);
                    const body = if (spec.precision) |p| full[0..@min(p, full.len)] else full;
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
    const pad: usize = if (spec.width > body.len) spec.width - body.len else 0;
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
    .{ .name = "string.byte", .func = &sByte1, .multi = &sByteN, .module = "string", .field = "byte" },
    .{ .name = "string.format", .func = &sFormat, .module = "string", .field = "format" },
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

test "string.rep with separator and non-positive count" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ab = try sv(&vm, "ab");
    try testing.expectEqualStrings("ababab", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(3) })));
    try testing.expectEqualStrings("ab-ab-ab", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(3), try sv(&vm, "-") })));
    try testing.expectEqualStrings("", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(0) })));
    try testing.expectEqualStrings("", bytesOf(try sRep(@ptrCast(&vm), &.{ ab, Value.int(-2) })));
}

test "string.char builds bytes; rejects out-of-range" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqualStrings("Hi!", bytesOf(try sChar(@ptrCast(&vm), &.{ Value.int(72), Value.int(105), Value.int(33) })));
    try testing.expectError(error.TypeError, sChar(@ptrCast(&vm), &.{Value.int(256)}));
    try testing.expectError(error.TypeError, sChar(@ptrCast(&vm), &.{Value.int(-1)}));
}

test "string.byte: primary projection and multi range" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const abc = try sv(&vm, "ABC");

    // Primary projection: first byte (default i=1).
    try testing.expectEqual(@as(i64, 65), (try sByte1(@ptrCast(&vm), &.{abc})).asInt());
    try testing.expectEqual(@as(i64, 67), (try sByte1(@ptrCast(&vm), &.{ abc, Value.int(-1) })).asInt());

    // Multi: full range.
    var out: [8]Value = undefined;
    const n = try sByteN(@ptrCast(&vm), &.{ abc, Value.int(1), Value.int(3) }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(i64, 65), out[0].asInt());
    try testing.expectEqual(@as(i64, 67), out[2].asInt());

    // Empty range → zero results.
    try testing.expectEqual(@as(usize, 0), try sByteN(@ptrCast(&vm), &.{ abc, Value.int(3), Value.int(1) }, &out));
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
