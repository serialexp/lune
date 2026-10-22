//! mahina stdlib — protected calls and error raising: `pcall`, `xpcall`, `error`,
//! `assert`. Top-level globals (Lua's "basic" library, not a namespace).
//!
//!   * `error(v)` / `assert(false, v)` stash `v` in `Vm.pending_error` and return
//!     the Zig signal `error.LuaError`, which unwinds the dispatch loop (a native
//!     is a trace barrier, so this never touches the JIT).
//!   * `pcall`/`xpcall` (doc 68 §5) check their arguments. For a Lua function
//!     they return the signal `error.ActivatePcall`/`error.ActivateXpcall`,
//!     and the `.call` instruction runs the function in a frame tagged
//!     `ctl.protect` in their place (`interp.Protect`): no Zig frame stays on
//!     the stack for it, so a suspend inside the protected call is an
//!     ordinary one, and the catch is `Vm.catchProtected`. Anything else (a
//!     native, a callable table, a non-callable value) has no frame to tag
//!     and is protected in Zig (`Vm.protectedCallSync`), as is a protected
//!     call `callValue` makes. On a **catchable** fault (`interp.catchable`)
//!     both read the value from `pending_error`, or — for a bare runtime
//!     fault like `nil + 1` — synthesize it from the still-live faulting
//!     frames via `Vm.synthErrorValue` before discarding them. Non-catchable
//!     faults (OOM, effect-log integrity) propagate unchanged so a program
//!     can never observe heap pressure or mask a replay divergence.
//!
//! Determinism: the whole error path reads only deterministic state (argument
//! values, opcodes, operand types, source spans) and interns id-stable strings,
//! so a program raises and catches byte-identical values across all 8 modes.
//!
//! `error(msg, level)` prepends a `chunk:line:` location to **string** messages
//! per Lua's `level` rule (via `Vm.raiseLocatedError` + the shared `callSiteAt`
//! locator); non-string messages pass through verbatim. `pcall` counts as a
//! level with no location, as Lua's C `pcall` does.
//!
//! `xpcall`'s message handler runs **before** the stack unwinds (Lua semantics):
//! it executes as a frame on top of the still-live faulting frames, so a handler
//! of `debug.traceback` produces a real backtrace of where the error happened.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");

const Value = value.Value;
const Vm = interp.Vm;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

// ---------------------------------------------------------------------------
// pcall / xpcall — argument checks, then a protected frame or a Zig catch
// ---------------------------------------------------------------------------

fn isClosure(v: Value) bool {
    return v.isHeap() and v.heapType() == .function;
}

/// Lua's `luaL_checkany(L, 1)`.
fn pcallEnter(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    if (args.len < 1) return vm.badArgReason(1, "value expected");
    if (isClosure(args[0])) return error.ActivatePcall;
    return vm.protectedCallSync(.pcall, args, out);
}

/// Lua's `luaL_checktype(L, 2, LUA_TFUNCTION)`: the handler must be a
/// function (a closure or a native), not merely callable.
fn xpcallEnter(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    const h: ?Value = if (args.len >= 2) args[1] else null;
    const is_fn = if (h) |v| v.isHeap() and (v.heapType() == .function or v.heapType() == .native) else false;
    if (!is_fn) return vm.badArg(2, "function", h);
    if (isClosure(args[0])) return error.ActivateXpcall;
    return vm.protectedCallSync(.xpcall, args, out);
}

fn nPcallN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return pcallEnter(vmOf(ctx), args, out);
}

fn nPcall1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [1]Value = undefined;
    _ = try pcallEnter(vmOf(ctx), args, &b);
    return b[0];
}

fn nXpcallN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return xpcallEnter(vmOf(ctx), args, out);
}

fn nXpcall1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [1]Value = undefined;
    _ = try xpcallEnter(vmOf(ctx), args, &b);
    return b[0];
}

// ---------------------------------------------------------------------------
// error / assert — raising a value
// ---------------------------------------------------------------------------

/// `error(message[, level])` — raise `message` as the in-flight error value and
/// unwind. For a **string** message and `level >= 1` (the default), prepend the
/// `chunk:line:` location of the call site `level` frames up (`level 1` = the
/// caller of `error`, `level 2` its caller, …), exactly like Lua. `level 0`, and
/// any non-string message, are stored verbatim. Never returns normally.
fn nError(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const msg = if (args.len >= 1) args[0] else Value.nil();
    var level: i64 = 1;
    if (args.len >= 2 and !args[1].isNil()) {
        const lv = args[1];
        if (lv.isInt()) {
            level = lv.asInt();
        } else if (lv.isFloat()) {
            const f = lv.asFloat();
            const two_pow_63 = 9223372036854775808.0;
            if (!std.math.isFinite(f) or @trunc(f) != f or f < -two_pow_63 or f >= two_pow_63) {
                return vm.badArgReason(2, "number has no integer representation");
            }
            level = @intFromFloat(f);
        } else {
            return vm.badArg(2, "number", lv);
        }
    }
    if (level >= 1) {
        if (interp.strBytes(msg)) |bytes| return vm.raiseLocatedError(bytes, @intCast(level));
    }
    vm.pending_error = msg;
    return error.LuaError;
}

/// `assert(v[, message, ...])` — if `v` is truthy, return all arguments unchanged;
/// otherwise raise `message` (any type) or the default `"assertion failed!"`.
fn assertRaise(vm: *Vm, args: []const Value) anyerror {
    vm.pending_error = if (args.len >= 2) args[1] else try vm.heap.internValue("assertion failed!");
    return error.LuaError;
}

fn nAssertN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    if (args.len >= 1 and args[0].isTruthy()) {
        const n = @min(args.len, out.len);
        var k: usize = 0;
        while (k < n) : (k += 1) out[k] = args[k];
        return n;
    }
    return assertRaise(vm, args);
}

fn nAssert1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len >= 1 and args[0].isTruthy()) return args[0];
    return assertRaise(vm, args);
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const natives = [_]function.BaseNative{
    .{ .name = "pcall", .func = &nPcall1, .multi = &nPcallN },
    .{ .name = "xpcall", .func = &nXpcall1, .multi = &nXpcallN },
    .{ .name = "error", .func = &nError },
    .{ .name = "assert", .func = &nAssert1, .multi = &nAssertN, .recorded = .assert },
};

test "A-iv pcall unwind drops region_profit for the destroyed activation" {
    const testing = std.testing;
    const parser = @import("../parser.zig");
    const compiler = @import("../compiler.zig");
    const diag = @import("../diag.zig");
    const trace = @import("../trace.zig");
    const source = "return function() error('boom') end\n";

    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    const failing = try vm.run(chunk.proto);

    // The next physical push is the protected closure (`callValue` protects
    // it in Zig). Seed a nonzero remainder under its exact activation id;
    // the only path that can remove it is the pcall catch's depth-restore
    // cleanup hook.
    const activation = vm.next_call_seq;
    try vm.trace.region_policy.region_profit.put(testing.allocator, .{
        .region_id = @as(trace.RegionId, @enumFromInt(123)),
        .activation = activation,
    }, .{
        .outer_traversals = 3,
        .root_frame_depth = 1,
        .root_call_seq = activation,
    });
    const baseline = vm.trace.regionProfitCount() - 1;
    const pcall = vm.globals.get(try vm.heap.internValue("pcall"));
    var out: [2]Value = undefined;
    const n = try vm.callValue(pcall, &.{failing}, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(!out[0].asBool());
    try testing.expectEqual(baseline, vm.trace.regionProfitCount());
}
