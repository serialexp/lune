//! mahina stdlib — the `debug` library (introspection subset).
//!
//! Only `debug.traceback` is implemented: a pure, deterministic formatter over
//! the live call stack. It walks `Vm.backtraceFrames` (the same deepest-first
//! frame walk `describeFault` uses for runtime-error backtraces) and renders one
//! line per frame, so the output is a function only of static proto names and
//! source offsets — byte-identical across all 8 modes. A `debug.traceback` call
//! is a native, hence a trace barrier, so it never enters recorded/JIT code.
//!
//! The canonical use is `xpcall(f, debug.traceback)`: `xpcall` now runs its
//! message handler **before** the stack unwinds (see `stdlib/errors.zig`), so
//! when `traceback` runs as that handler the faulting frames are still live and
//! the backtrace shows where the error happened.
//!
//! The rest of `debug.*` (`getinfo`, `sethook`, `getlocal`, …) is intentionally
//! absent — most is determinism-hostile or needs richer frame introspection than
//! mahina exposes, and `traceback` carries the usability payoff on its own.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");

const Value = value.Value;
const Vm = interp.Vm;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// `debug.traceback([message [, level]])` — return a string describing the
/// current call stack, optionally prefixed by `message`.
///
/// Lua-shaped (no leading `thread` argument — mahina exposes no coroutines), and
/// mirroring Lua's `db_traceback` (which calls `lua_tostring`, so it **coerces a
/// number** message):
///   * a string or number `message` is rendered (numbers via `coerceConcat`, the
///     same path `..` uses) and prefixed as `message .. "\n"` before the traceback;
///   * a `message` that is neither string, number, nor nil (a table, boolean, or
///     function) is returned **unchanged** — the Lua quirk that lets
///     `xpcall(f, debug.traceback)` pass an error *object* through untouched;
///   * a nil/absent `message` yields the bare traceback;
///   * `level` (default 1) starts the walk `level-1` frames above the deepest
///     (leaf) frame — `level == 1` is the function that called `traceback`. A
///     non-integer-representable float `level` is a bad argument, never a trap.
///
/// Each line follows mahina's existing `chunk:line:` error convention, using a
/// frame's `proto.name` as its chunk: `<name>:<line>: in main chunk` for the top
/// chunk (`proto.name == "main"`), else `<name>:<line>: in function '<name>'`.
fn nTraceback(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);

    // Render a string/number message (coercing numbers like `..`); a value that
    // is neither string, number, nor nil passes through untouched. `msgbuf` must
    // outlive `msg` (a number renders into it) — its size matches every other
    // `coerceConcat` caller in the VM, so a float can never overflow it.
    var msgbuf: [64]u8 = undefined;
    const msg: ?[]const u8 = blk: {
        if (args.len < 1 or args[0].isNil()) break :blk null;
        break :blk interp.coerceConcat(args[0], &msgbuf) catch |e| {
            if (e == error.TypeError) return args[0]; // table/bool/function → verbatim
            return e;
        };
    };

    // `level` (default 1): parsed like `error`'s level — an out-of-range or
    // non-integral float is a located bad argument, NOT a `@intFromFloat` trap.
    var level: i64 = 1;
    if (args.len >= 2 and !args[1].isNil()) {
        const lv = args[1];
        if (lv.isInt()) {
            level = lv.asInt();
        } else if (lv.isFloat()) {
            const f = lv.asFloat();
            const two_pow_63 = 9223372036854775808.0;
            if (!std.math.isFinite(f) or @trunc(f) != f or f < -two_pow_63 or f >= two_pow_63)
                return vm.badArgReason(2, "number has no integer representation");
            level = @intFromFloat(f);
        } else return vm.badArg(2, "number", lv);
    }

    // backtraceFrames allocates the frame slice; an arena keeps it scratch.
    var arena_inst = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena_inst.deinit();
    const frames = try vm.backtraceFrames(vm.source, arena_inst.allocator());

    // Skip the first `level-1` leaf frames, clamped to the frame count. Computed
    // in i64 and narrowed only once it is known to be `< frames.len`
    // (`<= max_call_depth`), so there is no out-of-range `usize` cast on any
    // target (e.g. wasm32 where `usize` is 32-bit).
    const start: usize = if (level <= 1) 0 else blk: {
        const skip = level - 1;
        if (skip >= @as(i64, @intCast(frames.len))) break :blk frames.len;
        break :blk @intCast(skip);
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.gpa);
    if (msg) |m| {
        try buf.appendSlice(vm.gpa, m);
        try buf.append(vm.gpa, '\n');
    }
    try buf.appendSlice(vm.gpa, "stack traceback:");
    for (frames[start..]) |fr| {
        var nbuf: [16]u8 = undefined;
        const line_digits = std.fmt.bufPrint(&nbuf, "{d}", .{fr.line}) catch unreachable;
        try buf.appendSlice(vm.gpa, "\n\t");
        try buf.appendSlice(vm.gpa, fr.name);
        try buf.append(vm.gpa, ':');
        try buf.appendSlice(vm.gpa, line_digits);
        if (std.mem.eql(u8, fr.name, "main")) {
            try buf.appendSlice(vm.gpa, ": in main chunk");
        } else {
            try buf.appendSlice(vm.gpa, ": in function '");
            try buf.appendSlice(vm.gpa, fr.name);
            try buf.append(vm.gpa, '\'');
        }
    }
    return vm.heap.internValue(buf.items);
}

pub const natives = [_]function.BaseNative{
    .{ .name = "debug.traceback", .func = &nTraceback, .module = "debug", .field = "traceback" },
};
