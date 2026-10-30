//! The `proc` library (doc 75): run another program and get what it did.
//!
//! `proc.run{argv..., cwd=, env=, stdin=, stdout=, stderr=, max_bytes=,
//! timeout=, check=}` is one effect, `proc_run`, like the `io`/`os` host
//! calls (`os.zig`): `off`/`record` ask the host, `record` logs the answer, and
//! `replay` takes it from the log and **never starts the program**. The log
//! holds one byte record per call (how it ended, whether bytes were dropped,
//! the captured streams), or the class of a start failure. The Lua result is
//! built from that record in every mode, so the modes cannot disagree.
//!
//! A program that ends badly raises, by default, a table (`kind`, `code`,
//! `signal`, the captured streams, `message`, and a `__tostring`); `check =
//! false` returns the result instead. A program that cannot be started raises
//! a located string, whatever `check` says.
//!
//! In `record` and `replay` a call that no recording could replay (stdio the
//! program inherits) is fatal before anything runs (`ProcNotRecordable`), and
//! a recording makes room for the worst case first (§5.2).

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const system = @import("../system.zig");
const table = @import("../table.zig");
const io = @import("io.zig");
const base = @import("base.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Table = table.Table;

/// What `max_bytes` is when the call does not say (doc 75 §3.1).
pub const default_max_bytes: usize = 64 * 1024;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

// ---------------------------------------------------------------------------
// The call's options
// ---------------------------------------------------------------------------

const Options = struct {
    argv: std.ArrayList([]const u8) = .empty,
    env: std.ArrayList(system.ProcEnvPair) = .empty,
    has_env: bool = false,
    cwd: ?[]const u8 = null,
    stdin: system.ProcStdin = .empty,
    stdout: system.ProcOut = .capture,
    stderr: system.ProcOut = .capture,
    max_bytes: usize = default_max_bytes,
    timeout_s: ?f64 = null,
    check: bool = true,

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        self.argv.deinit(gpa);
        self.env.deinit(gpa);
    }

    fn request(self: *const Options) system.ProcRequest {
        return .{
            .argv = self.argv.items,
            .cwd = self.cwd,
            .env = if (self.has_env) self.env.items else null,
            .stdin = self.stdin,
            .stdout = self.stdout,
            .stderr = self.stderr,
            .max_bytes = self.max_bytes,
            .timeout_ns = if (self.timeout_s) |s| secondsToNs(s) else null,
        };
    }

    fn capturesStdout(self: *const Options) bool {
        return self.stdout == .capture;
    }

    fn capturesStderr(self: *const Options) bool {
        return self.stderr == .capture;
    }

    /// Whether a recording could replay this call (doc 75 §5): nothing the
    /// program inherits, which only the terminal could hold.
    fn recordable(self: *const Options) bool {
        if (self.stdin == .inherit or self.stdout == .inherit or self.stderr == .inherit) return false;
        return true;
    }
};

fn secondsToNs(s: f64) u64 {
    const ns = s * 1e9;
    if (ns >= 18446744073709551615.0) return std.math.maxInt(u64);
    return @intFromFloat(ns);
}

fn optionError(vm: *Vm, comptime fmt: []const u8, args: anytype) anyerror {
    const msg = try std.fmt.allocPrint(vm.gpa, fmt, args);
    defer vm.gpa.free(msg);
    return vm.badArgReason(1, msg);
}

fn stringField(vm: *Vm, v: Value, name: []const u8) anyerror![]const u8 {
    return interp.strBytes(v) orelse optionError(vm, "'{s}' must be a string, got {s}", .{ name, v.typeName() });
}

fn outMode(vm: *Vm, v: Value, name: []const u8, comptime allow_merge: bool) anyerror!system.ProcOut {
    const s = try stringField(vm, v, name);
    if (std.mem.eql(u8, s, "capture")) return .capture;
    if (std.mem.eql(u8, s, "null")) return .discard;
    if (std.mem.eql(u8, s, "inherit")) return .inherit;
    if (allow_merge and std.mem.eql(u8, s, "merge")) return .merge;
    return optionError(vm, "'{s}' must be \"capture\", \"null\", \"inherit\"{s}, got \"{s}\"", .{
        name, if (allow_merge) " or \"merge\"" else "", s,
    });
}

fn parseStdin(vm: *Vm, v: Value) anyerror!system.ProcStdin {
    if (interp.strBytes(v)) |s| return .{ .bytes = s };
    const t = io.asByteArray(v) orelse return optionError(vm, "'stdin' must be a string, a byte array, {{file = path}} or {{inherit = true}}, got {s}", .{v.typeName()});
    const file = t.get(try vm.heap.internValue("file"));
    if (!file.isNil()) return .{ .file = try stringField(vm, file, "stdin.file") };
    const inherit = t.get(try vm.heap.internValue("inherit"));
    if (inherit.isBool() and inherit.asBool()) return .inherit;
    try io.checkByteArray(vm, t);
    return .{ .bytes = try io.byteArrayBytes(vm, t) };
}

fn parseEnv(vm: *Vm, o: *Options, v: Value) anyerror!void {
    const t = io.asByteArray(v) orelse return optionError(vm, "'env' must be a table of names to strings, got {s}", .{v.typeName()});
    o.has_env = true;
    var ctrl = Value.nil();
    while (try base.tableNext(vm.gpa, t, ctrl)) |kv| {
        ctrl = kv.key;
        const name = interp.strBytes(kv.key) orelse return optionError(vm, "'env' has a key that is not a string", .{});
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null or std.mem.indexOfScalar(u8, name, 0) != null)
            return optionError(vm, "'env' has an invalid variable name '{s}'", .{name});
        const val = interp.strBytes(kv.val) orelse return optionError(vm, "'env.{s}' must be a string, got {s}", .{ name, kv.val.typeName() });
        if (std.mem.indexOfScalar(u8, val, 0) != null) return optionError(vm, "'env.{s}' contains a NUL byte", .{name});
        try o.env.append(vm.gpa, .{ .name = name, .value = val });
    }
}

fn parseOptions(vm: *Vm, args: []const Value, o: *Options) anyerror!void {
    const t = (if (args.len >= 1) io.asByteArray(args[0]) else null) orelse
        return vm.badArg(1, "table", if (args.len >= 1) args[0] else null);
    const n = t.length();
    if (n < 1) return vm.badArgReason(1, "no program: the table needs the program name at [1]");
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        const a = interp.strBytes(t.getInt(i)) orelse return optionError(vm, "argv[{d}] must be a string, got {s}", .{ i, t.getInt(i).typeName() });
        if (std.mem.indexOfScalar(u8, a, 0) != null) return optionError(vm, "argv[{d}] contains a NUL byte", .{i});
        try o.argv.append(vm.gpa, a);
    }
    var ctrl = Value.nil();
    while (try base.tableNext(vm.gpa, t, ctrl)) |kv| {
        ctrl = kv.key;
        if (kv.key.isInt() and kv.key.asInt() >= 1 and kv.key.asInt() <= n) continue;
        const key = interp.strBytes(kv.key) orelse return optionError(vm, "unexpected key of type {s}", .{kv.key.typeName()});
        const v = kv.val;
        if (std.mem.eql(u8, key, "cwd")) {
            o.cwd = try stringField(vm, v, "cwd");
        } else if (std.mem.eql(u8, key, "env")) {
            try parseEnv(vm, o, v);
        } else if (std.mem.eql(u8, key, "stdin")) {
            o.stdin = try parseStdin(vm, v);
        } else if (std.mem.eql(u8, key, "stdout")) {
            o.stdout = try outMode(vm, v, "stdout", false);
        } else if (std.mem.eql(u8, key, "stderr")) {
            o.stderr = try outMode(vm, v, "stderr", true);
        } else if (std.mem.eql(u8, key, "max_bytes")) {
            if (!v.isInt() or v.asInt() < 0) return optionError(vm, "'max_bytes' must be a non-negative integer", .{});
            o.max_bytes = @intCast(v.asInt());
        } else if (std.mem.eql(u8, key, "timeout")) {
            if (v.isBool() and !v.asBool()) {
                o.timeout_s = null;
            } else {
                const s: f64 = if (v.isInt()) @floatFromInt(v.asInt()) else if (v.isFloat()) v.asFloat() else
                    return optionError(vm, "'timeout' must be a number of seconds, or false", .{});
                if (!(s > 0) or !std.math.isFinite(s)) return optionError(vm, "'timeout' must be a positive number of seconds", .{});
                o.timeout_s = s;
            }
        } else if (std.mem.eql(u8, key, "check")) {
            if (!v.isBool()) return optionError(vm, "'check' must be a boolean", .{});
            o.check = v.asBool();
        } else {
            return optionError(vm, "unknown option '{s}'", .{key});
        }
    }
}

// ---------------------------------------------------------------------------
// The log record
// ---------------------------------------------------------------------------

/// One finished program as the log holds it (doc 75 §4), little-endian:
///   u8  how it ended: 0 exited, 1 killed by a signal, 2 timed out
///   u32 the exit status (0 otherwise)
///   u8  flags: bit 0 earlier bytes were dropped, bit 1 stdout was captured,
///       bit 2 stderr was captured
///   u8  signal name length, then its bytes
///   u32 stdout length, then its bytes
///   u32 stderr length, then its bytes
const Ended = enum(u8) { exited = 0, signaled = 1, timed_out = 2 };
const flag_truncated: u8 = 1;
const flag_stdout: u8 = 2;
const flag_stderr: u8 = 4;

/// What the record says, with slices into it.
const Finished = struct {
    ended: Ended,
    code: u32,
    flags: u8,
    signal: []const u8,
    stdout: []const u8,
    stderr: []const u8,

    fn ok(self: Finished) bool {
        return self.ended == .exited and self.code == 0;
    }
};

/// The most a record can need besides the two streams: its fixed fields and a
/// signal name.
const record_overhead: usize = 1 + 4 + 1 + 1 + 24 + 4 + 4;

fn appendU32(gpa: std.mem.Allocator, list: *std.ArrayList(u8), v: u32) !void {
    try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

fn encode(gpa: std.mem.Allocator, o: *const Options, done: system.ProcDone, list: *std.ArrayList(u8)) !void {
    const ended: Ended, const code: u32, const sig: []const u8 = switch (done.status) {
        .exited => |c| .{ .exited, c, "" },
        .signaled => |s| .{ .signaled, 0, s },
        .timed_out => .{ .timed_out, 0, "" },
    };
    var flags: u8 = 0;
    if (done.truncated) flags |= flag_truncated;
    if (o.capturesStdout()) flags |= flag_stdout;
    if (o.capturesStderr()) flags |= flag_stderr;
    try list.append(gpa, @intFromEnum(ended));
    try appendU32(gpa, list, code);
    try list.append(gpa, flags);
    try list.append(gpa, @intCast(sig.len));
    try list.appendSlice(gpa, sig);
    try appendU32(gpa, list, @intCast(done.stdout.len));
    try list.appendSlice(gpa, done.stdout);
    try appendU32(gpa, list, @intCast(done.stderr.len));
    try list.appendSlice(gpa, done.stderr);
}

/// The record's fields, or `EffectKindMismatch` for one this binary did not
/// write.
fn decode(rec: []const u8) !Finished {
    var pos: usize = 0;
    const Rd = struct {
        rec: []const u8,
        pos: *usize,
        fn bytes(self: @This(), n: usize) ![]const u8 {
            if (self.rec.len - self.pos.* < n) return error.EffectKindMismatch;
            const s = self.rec[self.pos.*..][0..n];
            self.pos.* += n;
            return s;
        }
        fn u32le(self: @This()) !u32 {
            return std.mem.readInt(u32, (try self.bytes(4))[0..4], .little);
        }
    };
    const rd: Rd = .{ .rec = rec, .pos = &pos };
    const ended_byte = (try rd.bytes(1))[0];
    const ended = std.enums.fromInt(Ended, ended_byte) orelse return error.EffectKindMismatch;
    const code = try rd.u32le();
    const flags = (try rd.bytes(1))[0];
    const siglen = (try rd.bytes(1))[0];
    const signal = try rd.bytes(siglen);
    const out_len = try rd.u32le();
    const stdout = try rd.bytes(out_len);
    const err_len = try rd.u32le();
    const stderr = try rd.bytes(err_len);
    if (pos != rec.len) return error.EffectKindMismatch;
    if ((ended == .signaled) != (signal.len > 0)) return error.EffectKindMismatch;
    if (!std.unicode.utf8ValidateSlice(signal)) return error.EffectKindMismatch;
    return .{ .ended = ended, .code = code, .flags = flags, .signal = signal, .stdout = stdout, .stderr = stderr };
}

// ---------------------------------------------------------------------------
// The result
// ---------------------------------------------------------------------------

fn put(vm: *Vm, t: *Table, comptime key: []const u8, v: Value) !void {
    try t.set(vm.gpa, try vm.heap.internValue(key), v);
}

fn resultTable(vm: *Vm, f: Finished) anyerror!*Table {
    const t = try vm.heap.newTableSized(7);
    if (f.ended == .exited) try put(vm, t, "code", Value.int(f.code));
    if (f.ended == .signaled) try put(vm, t, "signal", try vm.heap.internValue(f.signal));
    if (f.flags & flag_stdout != 0) try put(vm, t, "stdout", try io.byteArray(vm, f.stdout));
    if (f.flags & flag_stderr != 0) try put(vm, t, "stderr", try io.byteArray(vm, f.stderr));
    try put(vm, t, "ok", Value.boolean(f.ok()));
    try put(vm, t, "truncated", Value.boolean(f.flags & flag_truncated != 0));
    try put(vm, t, "timed_out", Value.boolean(f.ended == .timed_out));
    return t;
}

/// Raise the failure of a program that ended badly: the result's fields plus
/// `kind`, `program` and `message`, with a `__tostring` that gives the message,
/// so an uncaught one still prints (doc 75 §3.3).
fn raiseFailure(vm: *Vm, o: *const Options, f: Finished, t: *Table) anyerror {
    const program = o.argv.items[0];
    const kind: []const u8, const message: []u8 = switch (f.ended) {
        .exited => .{ "exit", try std.fmt.allocPrint(vm.gpa, "command '{s}' exited with status {d}", .{ program, f.code }) },
        .signaled => .{ "signal", try std.fmt.allocPrint(vm.gpa, "command '{s}' was killed by {s}", .{ program, f.signal }) },
        .timed_out => .{ "timeout", try std.fmt.allocPrint(vm.gpa, "command '{s}' timed out after {d} seconds", .{ program, o.timeout_s orelse 0 }) },
    };
    defer vm.gpa.free(message);
    try put(vm, t, "kind", try vm.heap.internValue(kind));
    try put(vm, t, "program", try vm.heap.internValue(program));
    try put(vm, t, "message", try vm.heap.internValue(message));
    const meta = try vm.heap.newTableSized(1);
    const tostring = try vm.heap.newNativeFrom(interp.templateOf("proc.error_tostring"));
    try meta.set(vm.gpa, try vm.heap.internValue("__tostring"), Value.heap(&tostring.header));
    t.metatable = meta;
    vm.pending_error = Value.heap(&t.header);
    return error.LuaError;
}

/// `__tostring` of a failure: its `message`.
fn errorToString(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = (if (args.len >= 1) io.asByteArray(args[0]) else null) orelse return vm.badArg(1, "table", if (args.len >= 1) args[0] else null);
    return t.get(try vm.heap.internValue("message"));
}

// ---------------------------------------------------------------------------
// proc.run
// ---------------------------------------------------------------------------

/// Make room in the recording for this call's worst case before the program
/// runs (doc 75 §5.2): a result that would not fit cannot be refused after
/// the program has already done its work.
fn reserveLog(vm: *Vm, o: *const Options) !void {
    var need: usize = record_overhead + 2;
    if (o.capturesStdout()) need +|= o.max_bytes;
    if (o.capturesStderr()) need +|= o.max_bytes;
    if (vm.effect_log_limit != 0 and vm.effect_log_encoded +| need > vm.effect_log_limit) return error.EffectLogLimit;
}

fn runN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    var o: Options = .{};
    defer o.deinit(vm.gpa);
    try parseOptions(vm, args, &o);

    // A recording is a promise to replay: refuse a call it could not.
    if (vm.effect_mode != .off and !o.recordable()) return error.ProcNotRecordable;
    if (vm.effect_mode == .record) try reserveLog(vm, &o);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(vm.gpa);
    const rec: []const u8 = blk: {
        if (vm.effect_mode == .replay) {
            switch (try interp.replayHost(vm, .proc_run)) {
                .bytes => |span| break :blk vm.effect_log.bytesOf(span),
                .fail => |c| return startFailure(vm, &o, c),
                .value => return error.EffectKindMismatch,
            }
        }
        const result: system.ProcResult = if (vm.system) |sys|
            if (sys.vtable.proc) |run| run(sys.ctx, o.request()) else .{ .fail = .other }
        else
            .{ .fail = .other };
        switch (result) {
            .fail => |c| {
                try interp.recordHost(vm, .proc_run, .{ .fail = c });
                return startFailure(vm, &o, c);
            },
            .done => |done| {
                try encode(vm.gpa, &o, done, &scratch);
                try interp.recordHostBytes(vm, .proc_run, scratch.items);
                break :blk scratch.items;
            },
        }
    };

    const f = try decode(rec);
    const t = try resultTable(vm, f);
    if (o.check and !f.ok()) return raiseFailure(vm, &o, f, t);
    return io.putResults(out, &.{Value.heap(&t.header)});
}

/// A program that could not be started raises whatever `check` says.
fn startFailure(vm: *Vm, o: *const Options, class: system.ErrorClass) anyerror {
    const msg = try std.fmt.allocPrint(vm.gpa, "cannot run '{s}': {s}", .{ o.argv.items[0], class.text() });
    defer vm.gpa.free(msg);
    return vm.raiseLocatedError(msg, 1);
}

pub const natives = [_]function.BaseNative{
    .{ .name = "proc.run", .func = io.single(&runN), .multi = &runN, .module = "proc", .field = "run", .groups = .{ .proc = true } },
    // The `__tostring` of a failure; made by `raiseFailure`, not installed.
    .{ .name = "proc.error_tostring", .func = &errorToString, .manual = true },
};
