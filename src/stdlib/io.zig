//! The `io` library (doc 65 Phase 3): file handles, the standard streams, and
//! the default input and output.
//!
//! A handle is a `file` heap object (`file.zig`); the host owns the OS side,
//! keyed by the handle's id (`system.HostSystem`). Every host operation is one
//! effect (doc 65 §4.2): in `off`/`record` the native calls the host and, in
//! `record`, logs what came back; in `replay` it takes the logged result and
//! never touches the host. What the VM decides by itself — a closed handle, a
//! read on a write-only handle, a bad format — is never logged: replay decides
//! it the same way.
//!
//! stdout and stderr are different (§4.3): their writes go to the VM's output
//! seam (`Vm.out`/`Vm.err`, else the process streams), in every mode, and are
//! not effects. stdin is an input like any file.
//!
//! A failure raises by default, or returns Lua's `nil, msg, code` under
//! `--lua-io-errors` (§4.4). Errors Lua raises in both modes (a closed handle,
//! `io.lines` failing to open) raise in both here too. The mode is pinned into
//! the log by the first operation (`interp.noteIoErrorMode`).
//!
//! Reads parse their format in the VM over the host's buffer (`fill`/
//! `consume`), so a line costs one host call, not one per byte. A text read
//! must be valid UTF-8 (D3) and `read(n)` counts code points (Q2); a `b`-mode
//! read returns a byte array and counts bytes (Q1).

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const system = @import("../system.zig");
const table = @import("../table.zig");
const arith = @import("../arith.zig");
const mio = @import("../io.zig");
const File = @import("../file.zig").File;

const Value = value.Value;
const Vm = interp.Vm;
const Table = table.Table;
const ErrorClass = system.ErrorClass;
const OpenMode = system.OpenMode;

/// The hidden module table holding the file methods; the file metatable's
/// `__index` (`Vm.initIoStreams`). A non-identifier name user code can never
/// spell, like `@gmatch_iter`.
pub const methods_module = "@file";

/// The hidden iterator `io.lines`/`file:lines` hand back (a global native,
/// so it is a GC root and keyframe-restorable by name).
const lines_iter_name = "@io_lines_iter";

/// The longest numeral `read("n")` collects (Lua's `L_MAXLENNUM`); a longer
/// one fails the read.
const max_numeral = 200;

/// The most formats one `lines` call takes (Lua's limit).
const max_line_formats = 250;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// Copy `vals` into `out` (as many as fit) and return how many were written.
fn putResults(out: []Value, vals: []const Value) usize {
    const n = @min(out.len, vals.len);
    @memcpy(out[0..n], vals[0..n]);
    return n;
}

/// The 0/1-result projection of a multi-result core, as the registry wants it.
fn single(comptime core: function.NativeMultiFn) function.NativeFn {
    return &struct {
        fn f(ctx: *anyopaque, args: []const Value) anyerror!Value {
            var buf: [1]Value = .{Value.nil()};
            const n = try core(ctx, args, &buf);
            return if (n > 0) buf[0] else Value.nil();
        }
    }.f;
}

// ---------------------------------------------------------------------------
// Handles and failures
// ---------------------------------------------------------------------------

fn fileOf(v: Value) ?*File {
    if (v.isHeap() and v.heapType() == .file) return File.fromHeader(v.asHeap());
    return null;
}

/// A handle an operation may use: open, and — live — backed by the host.
fn usable(vm: *Vm, f: *File) anyerror!*File {
    if (f.closed) return vm.raiseLocatedError("attempt to use a closed file", 1);
    // A handle restored from a keyframe and not reopened (Q7) has nothing
    // behind it on the host. A replay never asks the host, so it carries on.
    if (f.detached and vm.effect_mode != .replay)
        return vm.raiseLocatedError("file handle was not reopened after restore", 1);
    return f;
}

/// Argument `i` (0-based) as a usable handle.
fn fileArg(vm: *Vm, args: []const Value, i: usize) anyerror!*File {
    if (i >= args.len) return vm.badArg(i + 1, "FILE*", null);
    const f = fileOf(args[i]) orelse return vm.badArg(i + 1, "FILE*", args[i]);
    return usable(vm, f);
}

/// A failed operation (§4.4): raise, or return Lua's `nil, msg, code`. The
/// message is mahina's own text — the verb, the handle or path, the class —
/// so a recording replays with the same text anywhere (§4.2). `always_raise`
/// is for the calls Lua raises from too (`io.lines`, `io.input(name)`).
fn failWith(vm: *Vm, out: []Value, verb: []const u8, name: Name, class: ErrorClass, always_raise: bool) anyerror!usize {
    const msg = switch (name) {
        .path => |p| try std.fmt.allocPrint(vm.gpa, "cannot {s} '{s}': {s}", .{ verb, p, class.text() }),
        .stream => |s| try std.fmt.allocPrint(vm.gpa, "cannot {s} {s}: {s}", .{ verb, s, class.text() }),
    };
    defer vm.gpa.free(msg);
    if (always_raise or vm.io_errors == .raise) return vm.raiseLocatedError(msg, 1);
    return putResults(out, &.{ Value.nil(), try vm.heap.internValue(msg), Value.int(@intFromEnum(class)) });
}

/// How a message names what failed: a quoted path, or a stream's name.
const Name = union(enum) {
    path: []const u8,
    stream: []const u8,

    fn of(f: *const File) Name {
        return if (f.kind == .file) .{ .path = f.path } else .{ .stream = f.displayName() };
    }
};

fn fail(vm: *Vm, out: []Value, verb: []const u8, f: *const File, class: ErrorClass) anyerror!usize {
    return failWith(vm, out, verb, Name.of(f), class, false);
}

/// The host, in `off`/`record`. No host system means every operation fails
/// as `other` (a VM that enabled a group with no host behind it).
fn hostSystem(vm: *Vm) ?system.HostSystem {
    return vm.system;
}

/// Log a host operation's outcome (`record`) and commit it: success as `nil`.
fn recordOutcome(vm: *Vm, kind: function.EffectKind, err: ?ErrorClass) anyerror!void {
    try interp.recordHost(vm, kind, if (err) |c| .{ .fail = c } else .{ .value = Value.nil() });
}

/// Replay an `ok_or_fail` operation: its logged failure, or null for success.
fn replayOutcome(vm: *Vm, kind: function.EffectKind) anyerror!?ErrorClass {
    return switch (try interp.replayHost(vm, kind)) {
        .fail => |c| c,
        .value => |v| if (v.isNil()) null else error.EffectKindMismatch,
        .bytes => error.EffectKindMismatch,
    };
}

/// Run an `ok_or_fail` host operation through the record/replay boundary:
/// `live` is called only in `off`/`record`.
fn control(vm: *Vm, kind: function.EffectKind, live: anytype) anyerror!?ErrorClass {
    if (vm.effect_mode == .replay) return replayOutcome(vm, kind);
    const err = try live.run(vm);
    try recordOutcome(vm, kind, err);
    return err;
}

/// Flush stdout before a stdin read (§6), so a prompt is visible.
fn flushStdout(vm: *Vm) void {
    if (vm.out) |w| w.flush() catch {} else mio.flush();
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

/// Parse an `io.open` mode: `r`, `w` or `a`, then an optional `+`, then an
/// optional `b`. Null for anything else.
fn parseMode(s: []const u8) ?OpenMode {
    if (s.len == 0) return null;
    var m: OpenMode = .{ .kind = switch (s[0]) {
        'r' => .read,
        'w' => .write,
        'a' => .append,
        else => return null,
    } };
    var i: usize = 1;
    if (i < s.len and s[i] == '+') {
        m.update = true;
        i += 1;
    }
    if (i < s.len and s[i] == 'b') {
        m.binary = true;
        i += 1;
    }
    return if (i == s.len) m else null;
}

/// Open `path` (or, for a `tmpfile`, an anonymous file) as a new handle
/// through the `file_open` effect. The id is assigned in every mode, failed
/// opens included, so a replay hands out the ids the recording did.
fn openHandle(vm: *Vm, kind: File.Kind, path: []const u8, mode: OpenMode) anyerror!union(enum) { file: *File, fail: ErrorClass } {
    const id = vm.next_file_id;
    vm.next_file_id = std.math.add(system.FileId, id, 1) catch return vm.raiseLocatedError("too many files opened", 1);
    const err: ?ErrorClass = switch (vm.effect_mode) {
        .replay => switch (try interp.replayHost(vm, .file_open)) {
            .fail => |c| c,
            // The id is the VM's own counter; a log naming another one was
            // recorded from a different program.
            .value => |v| if (v.isInt() and v.asInt() == id) null else return error.EffectKindMismatch,
            .bytes => return error.EffectKindMismatch,
        },
        .off, .record => blk: {
            const c: ?ErrorClass = if (hostSystem(vm)) |sys| switch (kind) {
                .tmpfile => if (sys.vtable.tmpfile) |tmp| tmp(sys.ctx, id) else .other,
                else => if (sys.vtable.open) |open| open(sys.ctx, id, path, mode) else .other,
            } else .other;
            try interp.recordHost(vm, .file_open, if (c) |cc| .{ .fail = cc } else .{ .value = Value.int(id) });
            break :blk c;
        },
    };
    if (err) |c| return .{ .fail = c };
    return .{ .file = try vm.heap.newFile(id, kind, mode, path) };
}

/// Open `path` for `io.lines`/`io.input`/`io.output`, which raise on failure
/// in both modes (as Lua's do). Needs the `files` group.
fn openOrRaise(vm: *Vm, path: []const u8, mode: OpenMode) anyerror!*File {
    if (!vm.system_groups.files) {
        const msg = try std.fmt.allocPrint(vm.gpa, "cannot open '{s}': file access is not enabled", .{path});
        defer vm.gpa.free(msg);
        return vm.raiseLocatedError(msg, 1);
    }
    try interp.noteIoErrorMode(vm);
    return switch (try openHandle(vm, .file, path, mode)) {
        .file => |f| f,
        .fail => |c| {
            _ = try failWith(vm, &.{}, "open", .{ .path = path }, c, true);
            unreachable;
        },
    };
}

/// `io.open(filename [, mode])`.
fn ioOpenN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const path = (if (args.len >= 1) interp.strBytes(args[0]) else null) orelse
        return vm.badArg(1, "string", if (args.len >= 1) args[0] else null);
    var mode: OpenMode = .{ .kind = .read };
    if (args.len >= 2 and !args[1].isNil()) {
        const ms = interp.strBytes(args[1]) orelse return vm.badArg(2, "string", args[1]);
        mode = parseMode(ms) orelse return vm.badArgReason(2, "invalid mode");
    }
    try interp.noteIoErrorMode(vm);
    return switch (try openHandle(vm, .file, path, mode)) {
        .file => |f| putResults(out, &.{Value.heap(&f.header)}),
        .fail => |c| failWith(vm, out, "open", .{ .path = path }, c, false),
    };
}

/// `io.tmpfile()`: an anonymous file opened `w+`, removed when closed. Text
/// mode, as a Lua program uses it (C's `tmpfile` is binary, which in mahina
/// would make every read a byte array).
fn ioTmpfileN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    _ = args;
    const vm = vmOf(ctx);
    try interp.noteIoErrorMode(vm);
    return switch (try openHandle(vm, .tmpfile, "", .{ .kind = .write, .update = true })) {
        .file => |f| putResults(out, &.{Value.heap(&f.header)}),
        .fail => |c| failWith(vm, out, "open", .{ .stream = "a temporary file" }, c, false),
    };
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const Format = union(enum) {
    /// `"l"` (`keep` false) or `"L"` (`keep` true).
    line: bool,
    /// `"a"`: the rest of the file.
    all,
    /// `"n"`: a numeral.
    number,
    /// An integer: that many code points (text) or bytes (`b` mode).
    count: u64,
};

/// Argument `argn` (1-based, for messages) as a read format.
fn parseFormat(vm: *Vm, v: Value, argn: usize, binary: bool) anyerror!Format {
    if (v.isNumber()) {
        const n: i64 = if (v.isInt()) v.asInt() else blk: {
            const x = v.asFloat();
            if (!std.math.isFinite(x) or @trunc(x) != x or x < -9.2233720368547758e18 or x >= 9.2233720368547758e18)
                return vm.badArgReason(argn, "number has no integer representation");
            break :blk @intFromFloat(x);
        };
        // Lua converts a negative count to a huge size: read everything.
        return .{ .count = if (n < 0) std.math.maxInt(u64) else @intCast(n) };
    }
    const s = interp.strBytes(v) orelse return vm.badArg(argn, "string", v);
    // Lua 5.4 still accepts the 5.1 spelling with a leading `*`.
    const p = if (s.len > 0 and s[0] == '*') s[1..] else s;
    const f: Format = if (p.len == 0) return vm.badArgReason(argn, "invalid format") else switch (p[0]) {
        'l' => .{ .line = false },
        'L' => .{ .line = true },
        'a' => .all,
        'n' => .number,
        else => return vm.badArgReason(argn, "invalid format"),
    };
    // Q1: a `b`-mode handle reads bytes; lines and numerals are text.
    if (binary and (f == .line or f == .number)) return vm.badArgReason(argn, "format not allowed on a binary file");
    return f;
}

/// One read's outcome. `bytes` borrows `Vm.io_scratch` (a `b`-mode read
/// live) or the effect log (replay); the caller builds a byte array from it
/// before the next read.
const ReadOut = union(enum) {
    value: Value,
    bytes: []const u8,
    fail: ErrorClass,
};

/// The host's read buffer for one handle (`fill`/`consume`).
const Source = struct {
    ctx: *anyopaque,
    fill_fn: *const fn (ctx: *anyopaque, id: system.FileId) system.Result([]const u8),
    consume_fn: *const fn (ctx: *anyopaque, id: system.FileId, n: usize) void,
    id: system.FileId,

    fn of(vm: *Vm, f: *const File) ?Source {
        const sys = hostSystem(vm) orelse return null;
        return .{
            .ctx = sys.ctx,
            .fill_fn = sys.vtable.fill orelse return null,
            .consume_fn = sys.vtable.consume orelse return null,
            .id = f.id,
        };
    }

    fn fill(self: Source) system.Result([]const u8) {
        return self.fill_fn(self.ctx, self.id);
    }
    fn consume(self: Source, n: usize) void {
        self.consume_fn(self.ctx, self.id, n);
    }
};

/// A text result: the bytes as a string, or `not_utf8` (D3).
fn textOut(vm: *Vm, bytes: []const u8) anyerror!ReadOut {
    if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .fail = .not_utf8 };
    return .{ .value = try vm.heap.internValue(bytes) };
}

/// `"l"`/`"L"`: up to and including the next `\n` (kept only for `"L"`), or
/// to the end of the file; `nil` at the end. A line inside one host buffer
/// is interned straight from it.
fn readLine(vm: *Vm, src: Source, keep: bool) anyerror!ReadOut {
    const scratch = &vm.io_scratch;
    scratch.clearRetainingCapacity();
    var any = false;
    while (true) {
        const buf = switch (src.fill()) {
            .ok => |b| b,
            .fail => |c| return .{ .fail = c },
        };
        if (buf.len == 0) break;
        any = true;
        if (std.mem.indexOfScalar(u8, buf, '\n')) |nl| {
            const line = buf[0 .. if (keep) nl + 1 else nl];
            if (scratch.items.len == 0) {
                // The borrowed buffer is valid until the next host call.
                const r = try textOut(vm, line);
                src.consume(nl + 1);
                return r;
            }
            try scratch.appendSlice(vm.gpa, line);
            src.consume(nl + 1);
            break;
        }
        try scratch.appendSlice(vm.gpa, buf);
        src.consume(buf.len);
    }
    if (!any) return .{ .value = Value.nil() };
    return textOut(vm, scratch.items);
}

/// `"a"`: everything left — `""` (or an empty byte array) at the end, never
/// `nil`.
fn readAll(vm: *Vm, src: Source, binary: bool) anyerror!ReadOut {
    const scratch = &vm.io_scratch;
    scratch.clearRetainingCapacity();
    while (true) {
        const buf = switch (src.fill()) {
            .ok => |b| b,
            .fail => |c| return .{ .fail = c },
        };
        if (buf.len == 0) break;
        try scratch.appendSlice(vm.gpa, buf);
        src.consume(buf.len);
    }
    if (binary) return .{ .bytes = scratch.items };
    return textOut(vm, scratch.items);
}

/// An integer count: `n` bytes (`b` mode) or `n` code points (text, Q2),
/// fewer at the end of the file; `nil` when nothing is left. A text read
/// takes whole characters: after the `n`th lead byte it takes that
/// sequence's continuation bytes and stops, without reading ahead (which
/// would block a terminal). `read(0)` tests for the end of the file.
fn readCount(vm: *Vm, src: Source, n: u64, binary: bool) anyerror!ReadOut {
    const scratch = &vm.io_scratch;
    scratch.clearRetainingCapacity();
    if (n == 0) {
        const buf = switch (src.fill()) {
            .ok => |b| b,
            .fail => |c| return .{ .fail = c },
        };
        if (buf.len == 0) return .{ .value = Value.nil() };
        return if (binary) .{ .bytes = scratch.items } else .{ .value = try vm.heap.internValue("") };
    }
    var units: u64 = 0; // bytes, or lead bytes seen
    var pending: usize = 0; // continuation bytes the last lead byte promised
    outer: while (units < n or pending > 0) {
        const buf = switch (src.fill()) {
            .ok => |b| b,
            .fail => |c| return .{ .fail = c },
        };
        if (buf.len == 0) break;
        var i: usize = 0;
        if (binary) {
            i = @intCast(@min(@as(u64, buf.len), n - units));
            units += i;
        } else while (i < buf.len) {
            const b = buf[i];
            if (pending > 0) {
                if (b & 0xC0 == 0x80) {
                    pending -= 1;
                    i += 1;
                    continue;
                }
                // Malformed: the sequence ended early. Validation rejects it.
                pending = 0;
            }
            if (units == n) {
                try scratch.appendSlice(vm.gpa, buf[0..i]);
                src.consume(i);
                break :outer;
            }
            units += 1;
            pending = (std.unicode.utf8ByteSequenceLength(b) catch 1) - 1;
            i += 1;
            if (units == n and pending == 0) break;
        }
        try scratch.appendSlice(vm.gpa, buf[0..i]);
        src.consume(i);
        if (i < buf.len) break;
    }
    if (scratch.items.len == 0) return .{ .value = Value.nil() };
    if (binary) return .{ .bytes = scratch.items };
    return textOut(vm, scratch.items);
}

/// `"n"`: a numeral, read as Lua's `read_number` does — skip whitespace, an
/// optional sign, `0x`, digits, a decimal point, an exponent — then
/// converted as `tonumber` would. `nil` (a failed read, not an error) when
/// the characters are not a number. One byte of lookahead stays unread.
fn readNumber(src: Source) ReadOut {
    var rn: NumberReader = .{ .src = src };
    rn.peek();
    while (rn.c) |c| : (rn.advanceSkip()) {
        if (!std.ascii.isWhitespace(c)) break;
    }
    if (rn.failed) |c| return .{ .fail = c };
    var count: usize = 0;
    var hex = false;
    _ = rn.test2("-+");
    if (rn.test2("00")) {
        if (rn.test2("xX")) hex = true else count = 1;
    }
    count += rn.digits(hex);
    if (rn.test2("..")) count += rn.digits(hex);
    if (count > 0 and rn.test2(if (hex) "pP" else "eE")) {
        _ = rn.test2("-+");
        _ = rn.digits(false);
    }
    if (rn.failed) |c| return .{ .fail = c };
    if (rn.overflow) return .{ .value = Value.nil() };
    return .{ .value = arith.strToNumber(rn.buf[0..rn.len]) };
}

const NumberReader = struct {
    src: Source,
    /// The lookahead byte, or null at the end (or after a failure).
    c: ?u8 = null,
    buf: [max_numeral]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    failed: ?ErrorClass = null,

    fn peek(self: *NumberReader) void {
        self.c = switch (self.src.fill()) {
            .ok => |b| if (b.len == 0) null else b[0],
            .fail => |e| blk: {
                self.failed = e;
                break :blk null;
            },
        };
    }

    /// Drop the lookahead byte without keeping it (whitespace).
    fn advanceSkip(self: *NumberReader) void {
        self.src.consume(1);
        self.peek();
    }

    /// Keep the lookahead byte and read the next; false once the numeral is
    /// too long (Lua's `nextc`).
    fn next(self: *NumberReader) bool {
        if (self.len >= max_numeral) {
            self.overflow = true;
            return false;
        }
        self.buf[self.len] = self.c.?;
        self.len += 1;
        self.advanceSkip();
        return true;
    }

    fn test2(self: *NumberReader, set: *const [2]u8) bool {
        const c = self.c orelse return false;
        if (c == set[0] or c == set[1]) return self.next();
        return false;
    }

    fn digits(self: *NumberReader, hex: bool) usize {
        var n: usize = 0;
        while (self.c) |c| {
            const ok = if (hex) std.ascii.isHex(c) else std.ascii.isDigit(c);
            if (!ok or !self.next()) break;
            n += 1;
        }
        return n;
    }
};

/// One format against the host (`off`/`record`).
fn readLive(vm: *Vm, f: *File, fmt: Format) anyerror!ReadOut {
    const src = Source.of(vm, f) orelse return .{ .fail = .other };
    if (f.kind == .stdin) flushStdout(vm);
    return switch (fmt) {
        .line => |keep| readLine(vm, src, keep),
        .all => readAll(vm, src, f.mode.binary),
        .number => readNumber(src),
        .count => |n| readCount(vm, src, n, f.mode.binary),
    };
}

/// One format through the `file_read_op` effect.
fn readOne(vm: *Vm, f: *File, fmt: Format) anyerror!ReadOut {
    if (vm.effect_mode == .replay) return switch (try interp.replayHost(vm, .file_read_op)) {
        .value => |v| .{ .value = v },
        .bytes => |span| .{ .bytes = vm.effect_log.bytesOf(span) },
        .fail => |c| .{ .fail = c },
    };
    const r = try readLive(vm, f, fmt);
    switch (r) {
        .value => |v| try interp.recordHost(vm, .file_read_op, .{ .value = v }),
        .bytes => |b| try interp.recordHostBytes(vm, .file_read_op, b),
        .fail => |c| try interp.recordHost(vm, .file_read_op, .{ .fail = c }),
    }
    return r;
}

/// A fresh byte array holding `bytes`.
fn byteArray(vm: *Vm, bytes: []const u8) anyerror!Value {
    const t = try vm.heap.newTable();
    try t.initBytes(vm.gpa, bytes);
    return Value.heap(&t.header);
}

/// `file:read(...)` with the formats `fmts` (argument numbers from
/// `argbase + 1`): one result per format, stopping after the first `nil`.
/// `always_raise` is for `lines`, whose read errors raise in both modes.
fn readFormats(vm: *Vm, f: *File, fmts: []const Value, argbase: usize, out: []Value, always_raise: bool) anyerror!usize {
    var parsed_buf: [8]Format = undefined;
    var parsed: std.ArrayList(Format) = .initBuffer(&parsed_buf);
    var heap_parsed: std.ArrayList(Format) = .empty;
    defer heap_parsed.deinit(vm.gpa);
    const list: []const Format = blk: {
        if (fmts.len == 0) {
            parsed.appendAssumeCapacity(.{ .line = false });
            break :blk parsed.items;
        }
        const dst = if (fmts.len <= parsed_buf.len) &parsed else d: {
            try heap_parsed.ensureTotalCapacity(vm.gpa, fmts.len);
            break :d &heap_parsed;
        };
        for (fmts, 0..) |v, i| dst.appendAssumeCapacity(try parseFormat(vm, v, argbase + i + 1, f.mode.binary));
        break :blk dst.items;
    };
    try interp.noteIoErrorMode(vm);
    if (!f.mode.readable()) return failWith(vm, out, "read", Name.of(f), .not_readable, always_raise);
    var n: usize = 0;
    for (list) |fmt| {
        const v: Value = switch (try readOne(vm, f, fmt)) {
            .value => |v| v,
            .bytes => |b| try byteArray(vm, b),
            .fail => |c| return failWith(vm, out, "read", Name.of(f), c, always_raise),
        };
        if (n < out.len) out[n] = v;
        n += 1;
        if (v.isNil()) break;
    }
    return @min(n, out.len);
}

/// `file:read(...)`.
fn fileReadN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const f = try fileArg(vm, args, 0);
    return readFormats(vm, f, args[1..], 1, out, false);
}

/// The default input, usable.
fn defaultInput(vm: *Vm) anyerror!*File {
    const f = vm.io_input orelse return vm.raiseLocatedError("default input file is not set", 1);
    if (f.closed) return vm.raiseLocatedError("default input file is closed", 1);
    return usable(vm, f);
}

/// The default output, usable.
fn defaultOutput(vm: *Vm) anyerror!*File {
    const f = vm.io_output orelse return vm.raiseLocatedError("default output file is not set", 1);
    if (f.closed) return vm.raiseLocatedError("default output file is closed", 1);
    return usable(vm, f);
}

/// `io.read(...)`: `io.input():read(...)`.
fn ioReadN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    return readFormats(vm, try defaultInput(vm), args, 0, out, false);
}

// ---------------------------------------------------------------------------
// lines
// ---------------------------------------------------------------------------
//
// `lines` returns the generic-for triple `(@io_lines_iter, state, nil)`, as
// `gmatch` does: `state` is a plain table `{ [1]=file, [2]=close at the end,
// [3..]=formats }` — serializable and keyframe-restorable, where a closure
// with upvalues would not be. Like `gmatch`, the iterator therefore needs the
// state passed back (`for` does that); calling the iterator alone does not
// work.

fn linesTriple(vm: *Vm, f: *File, close: bool, fmts: []const Value, argbase: usize, out: []Value) anyerror!usize {
    if (fmts.len > max_line_formats) return vm.badArgReason(argbase + max_line_formats + 1, "too many arguments");
    // Check the formats now, so a bad one fails at the call, not the loop.
    for (fmts, 0..) |v, i| _ = try parseFormat(vm, v, argbase + i + 1, f.mode.binary);
    const state = try vm.heap.newTable();
    try state.set(vm.gpa, Value.int(1), Value.heap(&f.header));
    try state.set(vm.gpa, Value.int(2), Value.boolean(close));
    for (fmts, 0..) |v, i| try state.set(vm.gpa, Value.int(@intCast(i + 3)), v);
    const iter = vm.globals.get(try vm.heap.internValue(lines_iter_name));
    // Lua 5.4 adds the file as a fourth (to-be-closed) value when `lines`
    // opened it.
    if (close) return putResults(out, &.{ iter, Value.heap(&state.header), Value.nil(), Value.heap(&f.header) });
    return putResults(out, &.{ iter, Value.heap(&state.header), Value.nil() });
}

/// `file:lines(...)`: iterate `file:read(...)`; the file stays open.
fn fileLinesN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const f = try fileArg(vm, args, 0);
    return linesTriple(vm, f, false, args[1..], 1, out);
}

/// `io.lines([filename, ...])`: with a name, open it, iterate, and close it
/// at the end; without, iterate the default input.
fn ioLinesN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    if (args.len == 0 or args[0].isNil()) {
        return linesTriple(vm, try defaultInput(vm), false, if (args.len > 1) args[1..] else &.{}, 1, out);
    }
    const path = interp.strBytes(args[0]) orelse return vm.badArg(1, "string", args[0]);
    const f = try openOrRaise(vm, path, .{ .kind = .read });
    return linesTriple(vm, f, true, args[1..], 1, out);
}

/// `@io_lines_iter(state)`: the next line(s); at the end, close the file if
/// `lines` opened it and return nothing. A read error raises.
fn linesIterN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const st = (if (args.len >= 1 and args[0].isHeap() and args[0].heapType() == .table)
        Table.fromHeader(args[0].asHeap())
    else
        null) orelse return vm.badArg(1, "table", if (args.len >= 1) args[0] else null);
    const f = fileOf(st.getInt(1)) orelse return vm.raiseLocatedError("lines iterator state is not valid", 1);
    if (f.closed) return vm.raiseLocatedError("file is already closed", 1);
    _ = try usable(vm, f);
    const close = st.getInt(2).isTruthy();
    var fmts_buf: [8]Value = undefined;
    var fmts: std.ArrayList(Value) = .initBuffer(&fmts_buf);
    var heap_fmts: std.ArrayList(Value) = .empty;
    defer heap_fmts.deinit(vm.gpa);
    var k: i64 = 3;
    while (true) : (k += 1) {
        const v = st.getInt(k);
        if (v.isNil()) break;
        if (fmts.items.len < fmts_buf.len) {
            fmts.appendAssumeCapacity(v);
        } else {
            if (heap_fmts.items.len == 0) try heap_fmts.appendSlice(vm.gpa, fmts.items);
            try heap_fmts.append(vm.gpa, v);
        }
    }
    const list = if (heap_fmts.items.len != 0) heap_fmts.items else fmts.items;
    // The results land in a local buffer first: the first one decides
    // whether the loop is over.
    var first: [1]Value = .{Value.nil()};
    const want = if (out.len == 0) first[0..] else out;
    const n = try readFormats(vm, f, list, 0, want, true);
    if (n > 0 and want[0].isTruthy()) return n;
    if (close) _ = try closeHandle(vm, f, &.{}, true);
    return 0;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// The bytes of byte array `t` (`t[1 .. #t]`), borrowed when it is a `u8`
/// run, else gathered into `Vm.io_scratch`. `checkByteArray` has already
/// passed it.
fn byteArrayBytes(vm: *Vm, t: *Table) anyerror![]const u8 {
    if (t.byteRun()) |run| return run;
    const scratch = &vm.io_scratch;
    scratch.clearRetainingCapacity();
    const n = t.length();
    try scratch.ensureTotalCapacity(vm.gpa, @intCast(@max(n, 0)));
    var i: i64 = 1;
    while (i <= n) : (i += 1) scratch.appendAssumeCapacity(@intCast(t.getInt(i).asInt()));
    return scratch.items;
}

/// Raise unless every element of `t[1 .. #t]` is a byte (as `string.decode`
/// does). A `u8` run is one by construction.
fn checkByteArray(vm: *Vm, t: *Table) anyerror!void {
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    if (t.byteRun() != null) return;
    const n = t.length();
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        const v = t.getInt(i);
        if (!v.isInt() or v.asInt() < 0 or v.asInt() > 255)
            return vm.raiseLocatedError("byte array element is not a byte (an integer 0..255)", 1);
    }
}

fn asByteArray(v: Value) ?*Table {
    if (v.isHeap() and v.heapType() == .table) return Table.fromHeader(v.asHeap());
    return null;
}

/// Check `file:write`'s values before anything is written, so a bad one
/// writes nothing: strings and numbers; byte arrays too on a `b`-mode handle
/// (Q1).
fn checkWriteArgs(vm: *Vm, f: *const File, vals: []const Value, argbase: usize) anyerror!void {
    for (vals, 0..) |v, i| {
        if (v.isNumber() or interp.strBytes(v) != null) continue;
        if (f.mode.binary) {
            const t = asByteArray(v) orelse return vm.badArg(argbase + i + 1, "string or byte array", v);
            try checkByteArray(vm, t);
            continue;
        }
        return vm.badArg(argbase + i + 1, "string", v);
    }
}

/// `file:write(...)` on `f`: returns `f`, or the failure.
fn writeValues(vm: *Vm, f: *File, vals: []const Value, argbase: usize, out: []Value) anyerror!usize {
    try checkWriteArgs(vm, f, vals, argbase);
    const self_v = Value.heap(&f.header);
    // A write to stdout/stderr cannot fail and is no effect, so it pins nothing.
    if (f.kind == .stdout or f.kind == .stderr) {
        try writeStdStream(vm, f.kind == .stdout, vals);
        return putResults(out, &.{self_v});
    }
    try interp.noteIoErrorMode(vm);
    switch (f.kind) {
        .stdout, .stderr => unreachable,
        .stdin => return fail(vm, out, "write", f, .not_writable),
        .file, .tmpfile => {},
    }
    if (!f.mode.writable()) return fail(vm, out, "write", f, .not_writable);
    const err = try control(vm, .file_write, struct {
        f: *File,
        vals: []const Value,
        fn run(self: @This(), v: *Vm) anyerror!?ErrorClass {
            return writeLive(v, self.f, self.vals);
        }
    }{ .f = f, .vals = vals });
    if (err) |c| return fail(vm, out, "write", f, c);
    return putResults(out, &.{self_v});
}

/// The host writes, one per value, stopping at the first failure.
fn writeLive(vm: *Vm, f: *const File, vals: []const Value) anyerror!?ErrorClass {
    const sys = hostSystem(vm) orelse return .other;
    const write = sys.vtable.write orelse return .other;
    var buf: [64]u8 = undefined;
    for (vals) |v| {
        const bytes = if (asByteArray(v)) |t| try byteArrayBytes(vm, t) else try interp.coerceConcat(v, &buf);
        if (write(sys.ctx, f.id, bytes)) |c| return c;
    }
    return null;
}

/// stdout/stderr: to the VM's output seam, or the process stream (§4.3).
fn writeStdStream(vm: *Vm, to_stdout: bool, vals: []const Value) anyerror!void {
    const seam = if (to_stdout) vm.out else vm.err;
    const w = seam orelse if (to_stdout) mio.stdout() else mio.stderrWriter();
    var buf: [64]u8 = undefined;
    var newline = false;
    for (vals) |v| {
        const bytes = try interp.coerceConcat(v, &buf);
        try w.writeAll(bytes);
        if (!newline) newline = std.mem.indexOfScalar(u8, bytes, '\n') != null;
    }
    if (seam == null) {
        if (to_stdout) mio.stdoutWrote(newline) else try w.flush();
    }
}

/// `file:write(...)`.
fn fileWriteN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const f = try fileArg(vm, args, 0);
    return writeValues(vm, f, args[1..], 1, out);
}

/// `io.write(...)`: `io.output():write(...)`.
fn ioWriteN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    return writeValues(vm, try defaultOutput(vm), args, 0, out);
}

// ---------------------------------------------------------------------------
// seek, flush, setvbuf, close
// ---------------------------------------------------------------------------

/// `file:seek([whence [, offset]])`: the new position, in bytes.
fn fileSeekN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const f = try fileArg(vm, args, 0);
    var whence: system.Whence = .cur;
    if (args.len >= 2 and !args[1].isNil()) {
        const s = interp.strBytes(args[1]) orelse return vm.badArg(2, "string", args[1]);
        whence = std.meta.stringToEnum(system.Whence, s) orelse return vm.badArgReason(2, "invalid option");
    }
    var offset: i64 = 0;
    if (args.len >= 3 and !args[2].isNil()) {
        if (!args[2].isNumber()) return vm.badArg(3, "number", args[2]);
        offset = if (args[2].isInt()) args[2].asInt() else blk: {
            const x = args[2].asFloat();
            if (!std.math.isFinite(x) or @trunc(x) != x or x < -9.2233720368547758e18 or x >= 9.2233720368547758e18)
                return vm.badArgReason(3, "number has no integer representation");
            break :blk @intFromFloat(x);
        };
    }
    try interp.noteIoErrorMode(vm);
    // stdout/stderr write to the VM's seam, which has no position.
    if (f.kind == .stdout or f.kind == .stderr) return fail(vm, out, "seek", f, .not_seekable);
    const r: system.Result(u64) = switch (vm.effect_mode) {
        .replay => switch (try interp.replayHost(vm, .file_seek)) {
            .value => |v| if (v.isInt() and v.asInt() >= 0) .{ .ok = @intCast(v.asInt()) } else return error.EffectKindMismatch,
            .fail => |c| .{ .fail = c },
            .bytes => return error.EffectKindMismatch,
        },
        .off, .record => blk: {
            const live: system.Result(u64) = if (hostSystem(vm)) |sys|
                if (sys.vtable.seek) |seek| seek(sys.ctx, f.id, whence, offset) else .{ .fail = .other }
            else
                .{ .fail = .other };
            // A position past `maxInt(i64)` cannot be a mahina integer.
            const checked: system.Result(u64) = switch (live) {
                .ok => |pos| if (pos > std.math.maxInt(i64)) .{ .fail = .other } else live,
                .fail => live,
            };
            try interp.recordHost(vm, .file_seek, switch (checked) {
                .ok => |pos| .{ .value = Value.int(@intCast(pos)) },
                .fail => |c| .{ .fail = c },
            });
            break :blk checked;
        },
    };
    return switch (r) {
        .ok => |pos| putResults(out, &.{Value.int(@intCast(pos))}),
        .fail => |c| fail(vm, out, "seek", f, c),
    };
}

/// Flush `f`: the seam for stdout/stderr, the host for a file.
fn flushHandle(vm: *Vm, f: *File, out: []Value) anyerror!usize {
    try interp.noteIoErrorMode(vm);
    switch (f.kind) {
        .stdout => if (vm.out) |w| try w.flush() else mio.flush(),
        .stderr => if (vm.err) |w| try w.flush() else try mio.stderrWriter().flush(),
        .stdin => {},
        .file, .tmpfile => {
            const err = try control(vm, .file_control, struct {
                id: system.FileId,
                fn run(self: @This(), v: *Vm) anyerror!?ErrorClass {
                    const sys = hostSystem(v) orelse return .other;
                    const flush = sys.vtable.flush orelse return .other;
                    return flush(sys.ctx, self.id);
                }
            }{ .id = f.id });
            if (err) |c| return fail(vm, out, "flush", f, c);
        },
    }
    return putResults(out, &.{Value.boolean(true)});
}

/// `file:flush()`.
fn fileFlushN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    return flushHandle(vm, try fileArg(vm, args, 0), out);
}

/// `io.flush()`: `io.output():flush()`.
fn ioFlushN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    _ = args;
    const vm = vmOf(ctx);
    return flushHandle(vm, try defaultOutput(vm), out);
}

/// `file:setvbuf(mode [, size])`: `"no"`, `"full"` or `"line"`. On stdout it
/// sets the process stdout's policy (§6); the seam a host installed is the
/// host's to buffer, and stderr and stdin have nothing to set.
fn fileSetvbufN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const f = try fileArg(vm, args, 0);
    const s = (if (args.len >= 2) interp.strBytes(args[1]) else null) orelse
        return vm.badArg(2, "string", if (args.len >= 2) args[1] else null);
    const mode = std.meta.stringToEnum(system.BufferMode, s) orelse return vm.badArgReason(2, "invalid option");
    var size: usize = 0;
    if (args.len >= 3 and !args[2].isNil()) {
        if (!args[2].isInt() or args[2].asInt() < 0) return vm.badArg(3, "non-negative integer", args[2]);
        size = @intCast(args[2].asInt());
    }
    try interp.noteIoErrorMode(vm);
    switch (f.kind) {
        .stdout => if (vm.out == null) mio.setStdoutBuffering(switch (mode) {
            .no => .none,
            .full => .full,
            .line => .line,
        }),
        .stderr, .stdin => {},
        .file, .tmpfile => {
            const err = try control(vm, .file_control, struct {
                id: system.FileId,
                mode: system.BufferMode,
                size: usize,
                fn run(self: @This(), v: *Vm) anyerror!?ErrorClass {
                    const sys = hostSystem(v) orelse return .other;
                    const setvbuf = sys.vtable.setvbuf orelse return .other;
                    return setvbuf(sys.ctx, self.id, self.mode, self.size);
                }
            }{ .id = f.id, .mode = mode, .size = size });
            if (err) |c| return fail(vm, out, "set the buffering of", f, c);
        },
    }
    return putResults(out, &.{Value.boolean(true)});
}

/// Close `f`. A standard stream cannot be closed (Lua returns `nil, msg`
/// with no code). A file is marked closed whatever the host says, as Lua
/// does.
fn closeHandle(vm: *Vm, f: *File, out: []Value, always_raise: bool) anyerror!usize {
    try interp.noteIoErrorMode(vm);
    if (f.isStdStream()) {
        const msg = "cannot close standard file";
        if (always_raise or vm.io_errors == .raise) return vm.raiseLocatedError(msg, 1);
        return putResults(out, &.{ Value.nil(), try vm.heap.internValue(msg) });
    }
    f.closed = true;
    const err = try control(vm, .file_control, struct {
        id: system.FileId,
        fn run(self: @This(), v: *Vm) anyerror!?ErrorClass {
            const sys = hostSystem(v) orelse return .other;
            const close = sys.vtable.close orelse return .other;
            return close(sys.ctx, self.id);
        }
    }{ .id = f.id });
    if (err) |c| return failWith(vm, out, "close", Name.of(f), c, always_raise);
    return putResults(out, &.{Value.boolean(true)});
}

/// `file:close()`.
fn fileCloseN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    return closeHandle(vm, try fileArg(vm, args, 0), out, false);
}

/// `io.close([file])`: the file, or the default output.
fn ioCloseN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    if (args.len == 0 or args[0].isNil()) return closeHandle(vm, try defaultOutput(vm), out, false);
    return closeHandle(vm, try fileArg(vm, args, 0), out, false);
}

// ---------------------------------------------------------------------------
// input, output, type
// ---------------------------------------------------------------------------

/// `io.input([file])` / `io.output([file])`: with a name, open it (`"r"` or
/// `"w"`) and make it the default; with a handle, make that the default;
/// either way return the current default.
fn setDefault(vm: *Vm, slot: *?*File, args: []const Value, mode: OpenMode, out: []Value) anyerror!usize {
    if (args.len >= 1 and !args[0].isNil()) {
        if (interp.strBytes(args[0])) |path| {
            slot.* = try openOrRaise(vm, path, mode);
        } else {
            slot.* = try fileArg(vm, args, 0);
        }
    }
    const cur = slot.* orelse return putResults(out, &.{Value.nil()});
    return putResults(out, &.{Value.heap(&cur.header)});
}

fn ioInputN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    return setDefault(vm, &vm.io_input, args, .{ .kind = .read }, out);
}

fn ioOutputN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    return setDefault(vm, &vm.io_output, args, .{ .kind = .write }, out);
}

/// `io.type(obj)`: `"file"`, `"closed file"`, or `nil` for anything else.
fn ioType(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len == 0) return vm.badArgReason(1, "value expected");
    const f = fileOf(args[0]) orelse return Value.nil();
    return vm.heap.internValue(if (f.closed) "closed file" else "file");
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

const stdio_or_files: system.Groups = .{ .stdio = true, .files = true };
const files: system.Groups = .{ .files = true };

fn entry(comptime name: []const u8, comptime core: function.NativeMultiFn, comptime module: []const u8, comptime field: []const u8, comptime groups: system.Groups) function.BaseNative {
    return .{ .name = name, .func = single(core), .multi = core, .module = module, .field = field, .groups = groups };
}

pub const natives = [_]function.BaseNative{
    // Output and the handle query every VM has: stdout and stderr write to
    // the VM's output seam, which needs no system group.
    entry("io.write", &ioWriteN, "io", "write", .none),
    entry("io.flush", &ioFlushN, "io", "flush", .none),
    .{ .name = "io.type", .func = &ioType, .module = "io", .field = "type" },
    // The default input and output, which serve stdin and files alike.
    entry("io.read", &ioReadN, "io", "read", stdio_or_files),
    entry("io.lines", &ioLinesN, "io", "lines", stdio_or_files),
    entry("io.input", &ioInputN, "io", "input", stdio_or_files),
    entry("io.output", &ioOutputN, "io", "output", stdio_or_files),
    entry("io.close", &ioCloseN, "io", "close", stdio_or_files),
    // Opening files by name.
    entry("io.open", &ioOpenN, "io", "open", files),
    entry("io.tmpfile", &ioTmpfileN, "io", "tmpfile", files),
    // The handle methods (the file metatable's `__index`). Reachable only
    // through a handle, so ungrouped.
    entry("file.read", &fileReadN, methods_module, "read", .none),
    entry("file.write", &fileWriteN, methods_module, "write", .none),
    entry("file.lines", &fileLinesN, methods_module, "lines", .none),
    entry("file.seek", &fileSeekN, methods_module, "seek", .none),
    entry("file.flush", &fileFlushN, methods_module, "flush", .none),
    entry("file.setvbuf", &fileSetvbufN, methods_module, "setvbuf", .none),
    entry("file.close", &fileCloseN, methods_module, "close", .none),
    // The hidden `lines` iterator.
    .{ .name = lines_iter_name, .func = single(&linesIterN), .multi = &linesIterN },
};
