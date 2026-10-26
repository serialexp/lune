//! mahina stdlib — `coroutine` (doc 73): Lua 5.4's coroutine library over the
//! VM's stack switch (`src/coroutine.zig`).
//!
//!   * `resume`/`yield` check their arguments, then return the signal
//!     `error.ActivateResume`/`error.ActivateYield`, and the `.call`
//!     instruction makes the switch in their place (`Vm.opEntry`): no Zig
//!     frame stays on the stack for a coroutine, so one that yields leaves
//!     nothing behind. A resume called from Zig (`pcall(coroutine.resume,
//!     co)`, a native's callback) runs the coroutine in a dispatch of its own
//!     on top of that Zig frame (`Vm.resumeSync`).
//!   * A coroutine may yield only while no Zig frame was entered since it was
//!     resumed (`Vm.canYield`): from inside a `table.sort` comparator, a
//!     metamethod run through a Zig re-entry, or a native body, yielding is
//!     Lua's "attempt to yield across a C-call boundary" error.
//!   * The main program is a `thread` value too (`coroutine.running()`), with
//!     no stack of its own.
//!
//! Not yet (doc 73 Outstanding): `coroutine.wrap`, and a native function as
//! a coroutine's body.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const coroutine = @import("../coroutine.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Thread = coroutine.Thread;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

fn raise(vm: *Vm, msg: []const u8) anyerror {
    vm.pending_error = try vm.heap.internValue(msg);
    return error.LuaError;
}

fn isThread(v: Value) bool {
    return v.isHeap() and v.heapType() == .thread;
}

/// Argument `i` (0-based) as a coroutine, as Lua's `getco` checks it.
fn coArg(vm: *Vm, args: []const Value, i: usize) anyerror!*Thread {
    if (i < args.len and isThread(args[i])) return Thread.fromHeader(args[i].asHeap());
    return vm.badArg(i + 1, "coroutine", if (i < args.len) args[i] else null);
}

/// `t`'s status. The main thread's follows whether a coroutine runs.
fn statusOf(vm: *const Vm, t: *const Thread) Thread.Status {
    if (vm.main_thread == t) return if (vm.current == null) .running else .normal;
    return t.status;
}

/// `coroutine.create(f)`.
fn nCreate(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const f: ?Value = if (args.len >= 1) args[0] else null;
    const is_fn = if (f) |v| v.isHeap() and (v.heapType() == .function or v.heapType() == .native) else false;
    if (!is_fn) return vm.badArg(1, "function", f);
    if (f.?.heapType() == .native) return vm.badArgReason(1, "Lua function expected");
    const t = try coroutine.newThread(vm.heap, f.?);
    return Value.heap(&t.header);
}

/// `coroutine.resume(co, ...)`: a suspended coroutine runs (the switch is
/// the caller's, `error.ActivateResume`); any other returns `false` and why.
fn resumeEnter(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    const co = try coArg(vm, args, 0);
    const why = switch (statusOf(vm, co)) {
        .suspended => return error.ActivateResume,
        .dead => "cannot resume dead coroutine",
        .running, .normal => "cannot resume non-suspended coroutine",
    };
    if (out.len == 0) return 0;
    out[0] = Value.boolean(false);
    if (out.len == 1) return 1;
    out[1] = try vm.heap.internValue(why);
    return 2;
}

fn nResumeN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return resumeEnter(vmOf(ctx), args, out);
}

fn nResume1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [1]Value = undefined;
    _ = try resumeEnter(vmOf(ctx), args, &b);
    return b[0];
}

/// `coroutine.yield(...)`: the running coroutine stops (the switch is the
/// caller's, `error.ActivateYield`), where it can.
fn yieldEnter(vm: *Vm) anyerror {
    if (vm.current == null) return raise(vm, "attempt to yield from outside a coroutine");
    if (!vm.canYield()) return raise(vm, "attempt to yield across a C-call boundary");
    return error.ActivateYield;
}

fn nYieldN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    _ = args;
    _ = out;
    return yieldEnter(vmOf(ctx));
}

fn nYield1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return yieldEnter(vmOf(ctx));
}

/// `coroutine.status(co)`.
fn nStatus(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const co = try coArg(vm, args, 0);
    return vm.heap.internValue(@tagName(statusOf(vm, co)));
}

/// `coroutine.running()`: the running coroutine, and whether it is the main
/// one.
fn runningThread(vm: *Vm) anyerror!*Thread {
    if (vm.current) |t| return t;
    return vm.mainThread();
}

fn nRunningN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    _ = args;
    const vm = vmOf(ctx);
    const t = try runningThread(vm);
    if (out.len == 0) return 0;
    out[0] = Value.heap(&t.header);
    if (out.len == 1) return 1;
    out[1] = Value.boolean(vm.current == null);
    return 2;
}

fn nRunning1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value.heap(&(try runningThread(vmOf(ctx))).header);
}

/// `coroutine.isyieldable([co])`.
fn nIsYieldable(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len == 0) return Value.boolean(vm.canYield());
    const co = try coArg(vm, args, 0);
    if (vm.main_thread == co) return Value.boolean(false);
    return Value.boolean(switch (co.status) {
        .running => vm.canYield(),
        // Unless it resumed the running one from a Zig frame.
        .normal => co.reentry_at_resume == co.reentry_base,
        .suspended, .dead => true,
    });
}

/// `coroutine.close(co)`: a suspended or dead coroutine is dead after it,
/// its open upvalues closed. Returns `true`, or `false` and the error that
/// killed it.
fn closeEnter(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    const co = try coArg(vm, args, 0);
    switch (statusOf(vm, co)) {
        .running => return raise(vm, "cannot close a running coroutine"),
        .normal => return raise(vm, "cannot close a normal coroutine"),
        .suspended => vm.closeCoroutine(co),
        .dead => {},
    }
    if (out.len == 0) return 0;
    const death = co.death;
    co.death = null;
    out[0] = Value.boolean(death == null);
    if (death == null or out.len == 1) return 1;
    out[1] = death.?;
    return 2;
}

fn nCloseN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return closeEnter(vmOf(ctx), args, out);
}

fn nClose1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [1]Value = undefined;
    _ = try closeEnter(vmOf(ctx), args, &b);
    return b[0];
}

pub const natives = [_]function.BaseNative{
    .{ .name = "coroutine.create", .func = &nCreate, .module = "coroutine", .field = "create" },
    .{ .name = "coroutine.resume", .func = &nResume1, .multi = &nResumeN, .module = "coroutine", .field = "resume" },
    .{ .name = "coroutine.yield", .func = &nYield1, .multi = &nYieldN, .module = "coroutine", .field = "yield" },
    .{ .name = "coroutine.status", .func = &nStatus, .module = "coroutine", .field = "status" },
    .{ .name = "coroutine.running", .func = &nRunning1, .multi = &nRunningN, .module = "coroutine", .field = "running" },
    .{ .name = "coroutine.isyieldable", .func = &nIsYieldable, .module = "coroutine", .field = "isyieldable" },
    .{ .name = "coroutine.close", .func = &nClose1, .multi = &nCloseN, .module = "coroutine", .field = "close" },
};
