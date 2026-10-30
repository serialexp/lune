//! The `proc` library (doc 75): run other programs and get what they did.
//!
//! `proc.run({argv..., cwd=, env=, stdin=, stdout=, stderr=, max_bytes=,
//! timeout=, check=})` runs one program; `proc.pipe({{argv...}, {argv...},
//! ...options})` runs a pipeline with the same options for the whole of it
//! (§3.6). Both are one effect, `proc_run`, like the `io`/`os` host calls
//! (`os.zig`): `off`/`record` ask the host, `record` logs the answer, and
//! `replay` takes it from the log and **never starts a program**. The log
//! holds one byte record per call (how each stage ended, whether bytes were
//! dropped, the captured streams, or which stage could not be started). The
//! Lua result is built from that record in every mode, so the modes cannot
//! disagree.
//!
//! A program that ends badly raises, by default, a table (`kind`, `code`,
//! `signal`, the captured streams, `message`, and a `__tostring`); `check =
//! false` returns the result instead. A pipeline fails like `pipefail`: the
//! raised table describes its rightmost failing stage. A program that cannot
//! be started raises a located string, whatever `check` says.
//!
//! In `record` and `replay` a call that no recording could replay (stdio the
//! programs inherit) is fatal before anything runs (`ProcNotRecordable`), and
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
    /// The programs in order; each slice is owned (`gpa`).
    stages: std.ArrayList([]const []const u8) = .empty,
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
        for (self.stages.items) |argv| gpa.free(argv);
        self.stages.deinit(gpa);
        self.env.deinit(gpa);
    }

    fn request(self: *const Options) system.ProcRequest {
        return .{
            .stages = self.stages.items,
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
    /// programs inherit, which only the terminal could hold. Every stage
    /// shares these settings, so checking them checks every stage.
    fn recordable(self: *const Options) bool {
        if (self.stdin == .inherit or self.stdout == .inherit or self.stderr == .inherit) return false;
        return true;
    }

    /// The program name of stage `i`.
    fn program(self: *const Options, i: usize) []const u8 {
        return self.stages.items[i][0];
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

/// The strings of `t[1..n]` as one stage's argv. `label` names it in errors.
fn parseArgv(vm: *Vm, o: *Options, t: *Table, label: []const u8, stage: ?i64) anyerror!void {
    const n = t.length();
    if (n < 1) {
        if (stage) |i| return optionError(vm, "stage {d} has no program: it needs the program name at [1]", .{i});
        return vm.badArgReason(1, "no program: the table needs the program name at [1]");
    }
    var ctrl = Value.nil();
    while (try base.tableNext(vm.gpa, t, ctrl)) |kv| {
        ctrl = kv.key;
        if (kv.key.isInt() and kv.key.asInt() >= 1 and kv.key.asInt() <= n) continue;
        if (stage != null) return optionError(vm, "stage {d} has an unexpected key; a stage is just its argv", .{stage.?});
    }
    const argv = try vm.gpa.alloc([]const u8, @intCast(n));
    errdefer vm.gpa.free(argv);
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        const a = interp.strBytes(t.getInt(i)) orelse return optionError(vm, "{s}[{d}] must be a string, got {s}", .{ label, i, t.getInt(i).typeName() });
        if (std.mem.indexOfScalar(u8, a, 0) != null) return optionError(vm, "{s}[{d}] contains a NUL byte", .{ label, i });
        argv[@intCast(i - 1)] = a;
    }
    try o.stages.append(vm.gpa, argv);
}

/// The options both calls share: every key of `t` outside its array part
/// `1..n`.
fn parseCommon(vm: *Vm, o: *Options, t: *Table, n: i64) anyerror!void {
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

/// `proc.run`'s table: one program's argv, plus options.
fn parseRun(vm: *Vm, args: []const Value, o: *Options) anyerror!void {
    const t = (if (args.len >= 1) io.asByteArray(args[0]) else null) orelse
        return vm.badArg(1, "table", if (args.len >= 1) args[0] else null);
    try parseArgv(vm, o, t, "argv", null);
    try parseCommon(vm, o, t, t.length());
}

/// `proc.pipe`'s table: the stages' argv tables, plus options for the whole.
fn parsePipe(vm: *Vm, args: []const Value, o: *Options) anyerror!void {
    const t = (if (args.len >= 1) io.asByteArray(args[0]) else null) orelse
        return vm.badArg(1, "table", if (args.len >= 1) args[0] else null);
    const n = t.length();
    if (n < 1) return vm.badArgReason(1, "no stages: the table needs a table of argv for each stage at [1]");
    if (n > max_stages) return optionError(vm, "a pipeline has at most {d} stages", .{max_stages});
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        const st = io.asByteArray(t.getInt(i)) orelse return optionError(vm, "stage {d} must be a table of strings, got {s}", .{ i, t.getInt(i).typeName() });
        var label_buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "stage {d}", .{i}) catch "stage";
        try parseArgv(vm, o, st, label, i);
    }
    try parseCommon(vm, o, t, n);
}

// ---------------------------------------------------------------------------
// The log record
// ---------------------------------------------------------------------------

/// One call as the log holds it (doc 75 §4), little-endian. First a tag byte:
///   0 the programs ran:
///     u8  stages
///     u8  flags: bit 0 earlier bytes were dropped, bit 1 stdout was
///         captured, bit 2 stderr was captured, bit 3 the timeout expired
///     u32 stdout length, then its bytes
///     per stage:
///       u8  how it ended: 0 exited, 1 killed by a signal
///       u32 the exit status (0 for a signal)
///       u8  signal name length, then its bytes
///       u32 stderr length, then its bytes
///   1 a stage could not be started:
///     u8  which stage
///     u8  the error class
const tag_done: u8 = 0;
const tag_start_failed: u8 = 1;
const flag_truncated: u8 = 1;
const flag_stdout: u8 = 2;
const flag_stderr: u8 = 4;
const flag_timed_out: u8 = 8;

const max_stages = system.proc_max_stages;

/// One stage as the record says, with slices into it.
const Stage = struct {
    signaled: bool,
    code: u32,
    signal: []const u8,
    stderr: []const u8,
};

/// A call whose programs ran, as the record says.
const Finished = struct {
    n: usize,
    timed_out: bool,
    truncated: bool,
    stdout_captured: bool,
    stderr_captured: bool,
    stdout: []const u8,
    stages: [max_stages]Stage,

    /// A stage whose exit is not a failure: it succeeded, or a stage that
    /// something downstream stopped reading from (`yes | head`) died of
    /// SIGPIPE.
    fn stageOk(self: *const Finished, i: usize) bool {
        const st = self.stages[i];
        if (!st.signaled) return st.code == 0;
        return i + 1 < self.n and std.mem.eql(u8, st.signal, "SIGPIPE");
    }

    /// The rightmost stage that failed, as `pipefail` reports it.
    fn failing(self: *const Finished) ?usize {
        var i = self.n;
        while (i > 0) {
            i -= 1;
            if (!self.stageOk(i)) return i;
        }
        return null;
    }

    fn ok(self: *const Finished) bool {
        return !self.timed_out and self.failing() == null;
    }
};

/// What a decoded record is.
const Decoded = union(enum) {
    done: Finished,
    start_failed: struct { stage: usize, class: system.ErrorClass },
};

/// The most a record can need besides the streams: its header, and per stage
/// its fixed fields and a signal name.
fn recordOverhead(stages: usize) usize {
    return 1 + 1 + 1 + 4 + stages * (1 + 4 + 1 + 24 + 4);
}

fn appendU32(gpa: std.mem.Allocator, list: *std.ArrayList(u8), v: u32) !void {
    try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

fn encodeFailure(gpa: std.mem.Allocator, fail: system.ProcFail, list: *std.ArrayList(u8)) !void {
    try list.append(gpa, tag_start_failed);
    try list.append(gpa, @intCast(fail.stage));
    try list.append(gpa, @intFromEnum(fail.class));
}

fn encode(gpa: std.mem.Allocator, o: *const Options, done: system.ProcDone, list: *std.ArrayList(u8)) !void {
    var flags: u8 = 0;
    if (done.truncated) flags |= flag_truncated;
    if (o.capturesStdout()) flags |= flag_stdout;
    if (o.capturesStderr()) flags |= flag_stderr;
    if (done.timed_out) flags |= flag_timed_out;
    try list.append(gpa, tag_done);
    try list.append(gpa, @intCast(done.stages.len));
    try list.append(gpa, flags);
    try appendU32(gpa, list, @intCast(done.stdout.len));
    try list.appendSlice(gpa, done.stdout);
    for (done.stages) |st| {
        const signaled: u8, const code: u32, const sig: []const u8 = switch (st.status) {
            .exited => |c| .{ 0, c, "" },
            .signaled => |name| .{ 1, 0, name },
        };
        try list.append(gpa, signaled);
        try appendU32(gpa, list, code);
        try list.append(gpa, @intCast(sig.len));
        try list.appendSlice(gpa, sig);
        try appendU32(gpa, list, @intCast(st.stderr.len));
        try list.appendSlice(gpa, st.stderr);
    }
}

/// The record's fields, or `EffectKindMismatch` for one this binary did not
/// write, or that is not about `stages` programs.
fn decode(rec: []const u8, stages: usize) !Decoded {
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
        fn u8le(self: @This()) !u8 {
            return (try self.bytes(1))[0];
        }
        fn u32le(self: @This()) !u32 {
            return std.mem.readInt(u32, (try self.bytes(4))[0..4], .little);
        }
    };
    const rd: Rd = .{ .rec = rec, .pos = &pos };
    const tag = try rd.u8le();
    if (tag == tag_start_failed) {
        const stage = try rd.u8le();
        const class = std.enums.fromInt(system.ErrorClass, try rd.u8le()) orelse return error.EffectKindMismatch;
        if (pos != rec.len or stage >= stages) return error.EffectKindMismatch;
        return .{ .start_failed = .{ .stage = stage, .class = class } };
    }
    if (tag != tag_done) return error.EffectKindMismatch;
    const n = try rd.u8le();
    if (n != stages) return error.EffectKindMismatch;
    const flags = try rd.u8le();
    const stdout = try rd.bytes(try rd.u32le());
    var f: Finished = .{
        .n = n,
        .timed_out = flags & flag_timed_out != 0,
        .truncated = flags & flag_truncated != 0,
        .stdout_captured = flags & flag_stdout != 0,
        .stderr_captured = flags & flag_stderr != 0,
        .stdout = stdout,
        .stages = undefined,
    };
    for (f.stages[0..n]) |*st| {
        const signaled = try rd.u8le();
        if (signaled > 1) return error.EffectKindMismatch;
        const code = try rd.u32le();
        const signal = try rd.bytes(try rd.u8le());
        const stderr = try rd.bytes(try rd.u32le());
        if ((signaled == 1) != (signal.len > 0)) return error.EffectKindMismatch;
        if (!std.unicode.utf8ValidateSlice(signal)) return error.EffectKindMismatch;
        st.* = .{ .signaled = signaled == 1, .code = code, .signal = signal, .stderr = stderr };
    }
    if (pos != rec.len) return error.EffectKindMismatch;
    return .{ .done = f };
}

// ---------------------------------------------------------------------------
// The result
// ---------------------------------------------------------------------------

fn put(vm: *Vm, t: *Table, comptime key: []const u8, v: Value) !void {
    try t.set(vm.gpa, try vm.heap.internValue(key), v);
}

/// How stage `i` ended and what it wrote to stderr, into `t`.
fn putStage(vm: *Vm, t: *Table, f: *const Finished, i: usize) !void {
    const st = f.stages[i];
    if (!st.signaled) try put(vm, t, "code", Value.int(st.code)) else try put(vm, t, "signal", try vm.heap.internValue(st.signal));
    if (f.stderr_captured) try put(vm, t, "stderr", try io.byteArray(vm, st.stderr));
}

/// A call's result. The table speaks for stage `focus` (a returned result:
/// the last stage; a raised failure: the failing one): its `code` or
/// `signal`, and for a single program its `stderr`. A timeout leaves out
/// `code` and `signal`: how the killed program ended is not the point.
/// A pipeline also lists its `stages`.
fn resultTable(vm: *Vm, f: *const Finished, focus: usize, pipeline: bool, root_stderr: bool) anyerror!*Table {
    const t = try vm.heap.newTableSized(8);
    if (!f.timed_out) {
        const st = f.stages[focus];
        if (!st.signaled) try put(vm, t, "code", Value.int(st.code)) else try put(vm, t, "signal", try vm.heap.internValue(st.signal));
    }
    if (f.stdout_captured) try put(vm, t, "stdout", try io.byteArray(vm, f.stdout));
    if (f.stderr_captured and root_stderr) try put(vm, t, "stderr", try io.byteArray(vm, f.stages[focus].stderr));
    try put(vm, t, "ok", Value.boolean(f.ok()));
    try put(vm, t, "truncated", Value.boolean(f.truncated));
    try put(vm, t, "timed_out", Value.boolean(f.timed_out));
    if (pipeline) {
        const list = try vm.heap.newTableSized(@intCast(f.n));
        for (0..f.n) |i| {
            const st = try vm.heap.newTableSized(3);
            try putStage(vm, st, f, i);
            try put(vm, st, "ok", Value.boolean(f.stageOk(i)));
            try list.set(vm.gpa, Value.int(@intCast(i + 1)), Value.heap(&st.header));
        }
        try put(vm, t, "stages", Value.heap(&list.header));
    }
    return t;
}

/// The programs' names, joined as a pipeline reads.
fn programs(vm: *Vm, o: *const Options) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(vm.gpa);
    for (0..o.stages.items.len) |i| {
        if (i > 0) try buf.appendSlice(vm.gpa, " | ");
        try buf.appendSlice(vm.gpa, o.program(i));
    }
    return buf.toOwnedSlice(vm.gpa);
}

/// Raise the failure of programs that ended badly: the result's fields plus
/// `kind`, `program` and `message`, with a `__tostring` that gives the
/// message, so an uncaught one still prints (doc 75 §3.3).
fn raiseFailure(vm: *Vm, o: *const Options, f: *const Finished, pipeline: bool) anyerror {
    const timed_out = f.timed_out;
    const focus = f.failing() orelse f.n - 1;
    const t = try resultTable(vm, f, focus, pipeline, true);
    const st = f.stages[focus];
    const program: []u8 = if (timed_out) try programs(vm, o) else try vm.gpa.dupe(u8, o.program(focus));
    defer vm.gpa.free(program);
    const kind: []const u8, const message: []u8 = if (timed_out)
        .{ "timeout", try std.fmt.allocPrint(vm.gpa, "command '{s}' timed out after {d} seconds", .{ program, o.timeout_s orelse 0 }) }
    else if (st.signaled)
        .{ "signal", try std.fmt.allocPrint(vm.gpa, "command '{s}' was killed by {s}", .{ program, st.signal }) }
    else
        .{ "exit", try std.fmt.allocPrint(vm.gpa, "command '{s}' exited with status {d}", .{ program, st.code }) };
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
// proc.run and proc.pipe
// ---------------------------------------------------------------------------

/// Make room in the recording for this call's worst case before the programs
/// run (doc 75 §5.2): a result that would not fit cannot be refused after
/// they have already done their work.
fn reserveLog(vm: *Vm, o: *const Options) !void {
    const n = o.stages.items.len;
    var need: usize = recordOverhead(n);
    if (o.capturesStdout()) need +|= o.max_bytes;
    if (o.capturesStderr()) need +|= o.max_bytes *| n;
    if (vm.effect_log_limit != 0 and vm.effect_log_encoded +| need > vm.effect_log_limit) return error.EffectLogLimit;
}

/// The one body of both calls: ask the host (or the log), log the answer,
/// build the Lua result from the record.
fn execute(vm: *Vm, o: *const Options, pipeline: bool, out: []Value) anyerror!usize {
    // A recording is a promise to replay: refuse a call it could not.
    if (vm.effect_mode != .off and !o.recordable()) return error.ProcNotRecordable;
    if (vm.effect_mode == .record) try reserveLog(vm, o);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(vm.gpa);
    const rec: []const u8 = blk: {
        if (vm.effect_mode == .replay) {
            switch (try interp.replayHost(vm, .proc_run)) {
                .bytes => |span| break :blk vm.effect_log.bytesOf(span),
                .fail, .value => return error.EffectKindMismatch,
            }
        }
        const result: system.ProcResult = if (vm.system) |sys|
            if (sys.vtable.proc) |run| run(sys.ctx, o.request()) else .{ .fail = .{ .class = .other } }
        else
            .{ .fail = .{ .class = .other } };
        switch (result) {
            .fail => |fail| try encodeFailure(vm.gpa, fail, &scratch),
            .done => |done| try encode(vm.gpa, o, done, &scratch),
        }
        try interp.recordHostBytes(vm, .proc_run, scratch.items);
        break :blk scratch.items;
    };

    switch (try decode(rec, o.stages.items.len)) {
        .start_failed => |sf| return startFailure(vm, o, sf.stage, sf.class),
        .done => |*f| {
            if (o.check and !f.ok()) return raiseFailure(vm, o, f, pipeline);
            const t = try resultTable(vm, f, f.n - 1, pipeline, !pipeline);
            return io.putResults(out, &.{Value.heap(&t.header)});
        },
    }
}

fn runN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    var o: Options = .{};
    defer o.deinit(vm.gpa);
    try parseRun(vm, args, &o);
    return execute(vm, &o, false, out);
}

fn pipeN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    var o: Options = .{};
    defer o.deinit(vm.gpa);
    try parsePipe(vm, args, &o);
    return execute(vm, &o, true, out);
}

/// A program that could not be started raises whatever `check` says.
fn startFailure(vm: *Vm, o: *const Options, stage: usize, class: system.ErrorClass) anyerror {
    const msg = try std.fmt.allocPrint(vm.gpa, "cannot run '{s}': {s}", .{ o.program(stage), class.text() });
    defer vm.gpa.free(msg);
    return vm.raiseLocatedError(msg, 1);
}

pub const natives = [_]function.BaseNative{
    .{ .name = "proc.run", .func = io.single(&runN), .multi = &runN, .module = "proc", .field = "run", .groups = .{ .proc = true } },
    .{ .name = "proc.pipe", .func = io.single(&pipeN), .multi = &pipeN, .module = "proc", .field = "pipe", .groups = .{ .proc = true } },
    // The `__tostring` of a failure; made by `raiseFailure`, not installed.
    .{ .name = "proc.error_tostring", .func = &errorToString, .manual = true },
};
