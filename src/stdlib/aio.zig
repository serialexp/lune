//! The `aio` library (doc 73 §7.6): operations that run while the program
//! goes on. Each function starts one and returns it at once as a host
//! `pending` task (`stdlib/task.lua`) for the program to `await`:
//!
//! - `aio.sleep(s)`: finishes after `s` seconds and gives nothing.
//! - `aio.read(path [, "b"])`: the whole file, as a string (which must be
//!   valid UTF-8) or, with `"b"`, a byte array.
//! - `aio.write(path, data)`, `aio.append(path, data)`: replace the file
//!   with `data` (a string, a number or a byte array), or add it at the
//!   end; give `true`.
//!
//! A failure raises where the program awaits it, as `cannot read 'path':
//! not found`, or under `--lua-io-errors` the await gives `nil, msg, code`
//! (doc 65 §4.4).
//!
//! The host runs the operations (`system.AsyncHost`, the CLI's
//! `aio_host.zig`); the VM numbers them with a counter (`Vm.aio_next_id`)
//! and keeps each one's record in `Vm.aio_ops`: `{ pending, kind, path }`.
//! When every task waits and some wait on `aio`, the task library's host
//! wait comes here (`wait`), which takes **one** completion and settles
//! its operation: from the host in `off`/`record` (logged as `aio_complete`
//! then `aio_result`), from the log in `replay`, which never starts
//! anything. One completion per wait makes the order tasks wake in the
//! logged order, whatever order the host's threads finished in.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const system = @import("../system.zig");
const table = @import("../table.zig");
const stdio = @import("io.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Table = table.Table;
const AsyncHost = system.AsyncHost;
const ErrorClass = system.ErrorClass;

/// An operation's kind, the second entry of its record.
const Kind = enum(u8) {
    sleep = 1,
    read = 2,
    read_binary = 3,
    write = 4,
    append = 5,

    fn verb(k: Kind) []const u8 {
        return switch (k) {
            .sleep => "sleep",
            .read, .read_binary => "read",
            .write, .append => "write",
        };
    }
};

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// The operation records, made on the first operation.
fn opsTable(vm: *Vm) anyerror!*Table {
    if (vm.aio_ops) |t| return t;
    const t = try vm.heap.newTable();
    vm.aio_ops = t;
    return t;
}

/// Start an operation of `kind` on `path` (nil for a sleep): number it,
/// make its pending task, keep its record and, live, hand it to the host.
fn begin(vm: *Vm, kind: Kind, path: Value, request: AsyncHost.Request) anyerror!Value {
    const replay = vm.effect_mode == .replay;
    const host = vm.aio;
    if (!replay and host == null) return vm.raiseLocatedError("aio: this host runs no asynchronous operations", 1);
    const ops = try opsTable(vm);
    var made: [1]Value = undefined;
    std.debug.assert(try vm.callValue(try vm.taskFn(.pending), &.{}, &made) == 1);
    const pending = made[0];
    // No safepoint from here until the record holds `pending`.
    const id = vm.aio_next_id;
    vm.aio_next_id = std.math.add(u64, id, 1) catch return vm.raiseLocatedError("aio: too many operations", 1);
    const rec = try vm.heap.newTable();
    try rec.set(vm.gpa, Value.int(1), pending);
    try rec.set(vm.gpa, Value.int(2), Value.int(@intFromEnum(kind)));
    try rec.set(vm.gpa, Value.int(3), path);
    try ops.set(vm.gpa, Value.int(@intCast(id)), Value.heap(&rec.header));
    vm.aio_inflight += 1;
    if (!replay and !host.?.vtable.start(host.?.ctx, id, request)) {
        // The host could not take it: no completion will ever come, so
        // the operation fails now rather than leaving its waiters waiting.
        try ops.set(vm.gpa, Value.int(@intCast(id)), Value.nil());
        vm.aio_inflight -= 1;
        const msg = try vm.heap.internValue("aio: out of memory");
        _ = try vm.callValue(try vm.taskFn(.settle), &.{ pending, Value.boolean(false), msg }, &.{});
        return error.OutOfMemory;
    }
    return pending;
}

/// `aio.sleep(s)`.
fn aioSleep(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len == 0 or !args[0].isNumber()) return vm.badArg(1, "number", if (args.len > 0) args[0] else null);
    const s: f64 = if (args[0].isInt()) @floatFromInt(args[0].asInt()) else args[0].asFloat();
    if (!(s >= 0)) return vm.badArgReason(1, "negative or NaN duration");
    const ns_f = s * std.time.ns_per_s;
    const ns: u64 = if (ns_f >= 0x1p64) std.math.maxInt(u64) else @intFromFloat(ns_f);
    return begin(vm, .sleep, Value.nil(), .{ .sleep = ns });
}

/// Argument 1 as a path: a string.
fn pathArg(vm: *Vm, args: []const Value) anyerror![]const u8 {
    if (args.len == 0) return vm.badArg(1, "string", null);
    return interp.strBytes(args[0]) orelse vm.badArg(1, "string", args[0]);
}

/// `aio.read(path [, "b"])`.
fn aioRead(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const path = try pathArg(vm, args);
    var kind: Kind = .read;
    if (args.len > 1 and !args[1].isNil()) {
        const m = interp.strBytes(args[1]) orelse return vm.badArg(2, "string", args[1]);
        if (!std.mem.eql(u8, m, "b")) return vm.badArgReason(2, "invalid mode");
        kind = .read_binary;
    }
    try interp.noteIoErrorMode(vm);
    return begin(vm, kind, args[0], .{ .read = path });
}

/// `aio.write`/`aio.append`: `data` is copied by the host at `start`.
fn writeOp(vm: *Vm, args: []const Value, kind: Kind) anyerror!Value {
    const path = try pathArg(vm, args);
    if (args.len < 2) return vm.badArg(2, "string or byte array", null);
    const d = args[1];
    var buf: [64]u8 = undefined;
    const data: []const u8 = if (d.isNumber() or interp.strBytes(d) != null)
        try interp.coerceConcat(d, &buf)
    else if (stdio.asByteArray(d)) |t| blk: {
        try stdio.checkByteArray(vm, t);
        break :blk try stdio.byteArrayBytes(vm, t);
    } else return vm.badArg(2, "string or byte array", d);
    try interp.noteIoErrorMode(vm);
    return begin(vm, kind, args[0], .{ .write = .{ .path = path, .data = data, .append = kind == .append } });
}

fn aioWrite(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return writeOp(vmOf(ctx), args, .write);
}

fn aioAppend(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return writeOp(vmOf(ctx), args, .append);
}

/// Take one completion and settle its operation (see the file comment).
/// The task library calls this, through `task.host_wait`, only while
/// operations are in flight (`Vm.aio_inflight`).
pub fn wait(vm: *Vm) anyerror!void {
    std.debug.assert(vm.aio_inflight > 0);
    switch (vm.effect_mode) {
        .replay => {
            const idv = switch (try interp.replayHost(vm, .aio_complete)) {
                .value => |v| v,
                else => return error.EffectKindMismatch,
            };
            if (!idv.isInt() or idv.asInt() < 0) return error.EffectKindMismatch;
            const id: u64 = @intCast(idv.asInt());
            // The record first: a log naming an operation this run never
            // started was recorded from another program.
            const rec = record(vm, id) orelse return error.EffectKindMismatch;
            const outcome: AsyncHost.Outcome = switch (try interp.replayHost(vm, .aio_result)) {
                .value => |v| if (v.isNil()) .done else return error.EffectKindMismatch,
                .bytes => |span| .{ .bytes = vm.effect_log.bytesOf(span) },
                .fail => |c| .{ .fail = c },
            };
            try settle(vm, id, rec, outcome);
        },
        .off, .record => {
            if (vm.aio_restored > 0)
                return vm.raiseLocatedError("aio: an operation in flight at the keyframe cannot continue live", 1);
            const host = vm.aio orelse return vm.raiseLocatedError("aio: this host runs no asynchronous operations", 1);
            const c = host.vtable.next(host.ctx);
            // A completion for no operation in flight is the host's bug.
            const rec = record(vm, c.id) orelse @panic("aio: the host finished an operation the VM never started");
            try interp.recordHost(vm, .aio_complete, .{ .value = Value.int(@intCast(c.id)) });
            switch (c.outcome) {
                .done => try interp.recordHost(vm, .aio_result, .{ .value = Value.nil() }),
                .bytes => |b| try interp.recordHostBytes(vm, .aio_result, b),
                .fail => |cl| try interp.recordHost(vm, .aio_result, .{ .fail = cl }),
            }
            try settle(vm, c.id, rec, c.outcome);
        },
    }
}

/// Operation `id`'s record, if it is in flight.
fn record(vm: *Vm, id: u64) ?*Table {
    const ops = vm.aio_ops orelse return null;
    if (id > std.math.maxInt(i64)) return null;
    const v = ops.getInt(@intCast(id));
    if (!v.isHeap() or v.heapType() != .table) return null;
    return Table.fromHeader(v.asHeap());
}

/// Finish operation `id` with `outcome`: drop its record and settle its
/// pending task, so the tasks awaiting it are ready.
fn settle(vm: *Vm, id: u64, rec: *Table, outcome: AsyncHost.Outcome) anyerror!void {
    const pending = rec.getInt(1);
    const kv = rec.getInt(2);
    const kind = std.enums.fromInt(Kind, if (kv.isInt()) kv.asInt() else 0) orelse return error.EffectKindMismatch;
    const path = rec.getInt(3);
    // No safepoint from here until `callValue` has the values in its window.
    try vm.aio_ops.?.set(vm.gpa, Value.int(@intCast(id)), Value.nil());
    vm.aio_inflight -= 1;
    if (id < vm.aio_live_from) vm.aio_restored -= 1;
    var args: [5]Value = .{ pending, Value.boolean(true), Value.nil(), Value.nil(), Value.nil() };
    var n: usize = 2;
    const failed: ?ErrorClass = switch (outcome) {
        .done => switch (kind) {
            .sleep => null,
            .write, .append => blk: {
                args[2] = Value.boolean(true);
                n = 3;
                break :blk null;
            },
            .read, .read_binary => return error.EffectKindMismatch,
        },
        .bytes => |b| switch (kind) {
            .read => if (std.unicode.utf8ValidateSlice(b)) blk: {
                args[2] = try vm.heap.internValue(b);
                n = 3;
                break :blk null;
            } else .not_utf8,
            .read_binary => blk: {
                args[2] = try stdio.byteArray(vm, b);
                n = 3;
                break :blk null;
            },
            .sleep, .write, .append => return error.EffectKindMismatch,
        },
        .fail => |c| if (kind == .sleep) return error.EffectKindMismatch else c,
    };
    if (failed) |c| {
        const p = interp.strBytes(path) orelse return error.EffectKindMismatch;
        const text = try std.fmt.allocPrint(vm.gpa, "cannot {s} '{s}': {s}", .{ kind.verb(), p, c.text() });
        defer vm.gpa.free(text);
        const msg = try vm.heap.internValue(text);
        if (vm.io_errors == .raise) {
            args[1] = Value.boolean(false);
            args[2] = msg;
            n = 3;
        } else {
            args[3] = msg;
            args[4] = Value.int(@intFromEnum(c));
            n = 5;
        }
    }
    _ = try vm.callValue(try vm.taskFn(.settle), args[0..n], &.{});
}

/// After a keyframe restore (`keyframeser`): check `Vm.aio_ops` holds only
/// what `begin` makes — operation ids below `next_id`, each with a record
/// — and count them in flight. No host is running them (`Vm.aio_restored`).
pub fn restoreOps(vm: *Vm, next_id: u64) error{InvalidAioOps}!void {
    if (next_id == 0) return error.InvalidAioOps;
    vm.aio_next_id = next_id;
    vm.aio_live_from = next_id;
    const ops = vm.aio_ops orelse return;
    var n: u32 = 0;
    for (0..ops.array.asize) |i| {
        const v = ops.array.get(i);
        if (v.isNil()) continue;
        try checkRestored(Value.int(@intCast(i)), v, next_id);
        n += 1;
    }
    var it = ops.hash.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.isNil()) continue;
        try checkRestored(e.key, e.value_ptr.*, next_id);
        n = std.math.add(u32, n, 1) catch return error.InvalidAioOps;
    }
    vm.aio_inflight = n;
    vm.aio_restored = n;
}

fn checkRestored(key: Value, rec: Value, next_id: u64) error{InvalidAioOps}!void {
    if (!key.isInt() or key.asInt() < 1 or @as(u64, @intCast(key.asInt())) >= next_id) return error.InvalidAioOps;
    if (!rec.isHeap() or rec.heapType() != .table) return error.InvalidAioOps;
    const r = Table.fromHeader(rec.asHeap());
    const kv = r.getInt(2);
    if (!kv.isInt() or std.enums.fromInt(Kind, kv.asInt()) == null) return error.InvalidAioOps;
}

const clock: system.Groups = .{ .clock = true };
const files: system.Groups = .{ .files = true };

pub const natives = [_]function.BaseNative{
    .{ .name = "aio.sleep", .func = &aioSleep, .module = "aio", .field = "sleep", .groups = clock, .aio = true },
    .{ .name = "aio.read", .func = &aioRead, .module = "aio", .field = "read", .groups = files, .aio = true },
    .{ .name = "aio.write", .func = &aioWrite, .module = "aio", .field = "write", .groups = files, .aio = true },
    .{ .name = "aio.append", .func = &aioAppend, .module = "aio", .field = "append", .groups = files, .aio = true },
};
