//! lune stdlib — protected calls and error raising: `pcall`, `xpcall`, `error`,
//! `assert`. Top-level globals (Lua's "basic" library, not a namespace).
//!
//! These are the first consumers of the reentrancy + error-value machinery in
//! `interp.zig`:
//!
//!   * `error(v)` / `assert(false, v)` stash `v` in `Vm.pending_error` and return
//!     the Zig signal `error.LuaError`, which unwinds the dispatch loop (a native
//!     is a trace barrier, so this never touches the JIT).
//!   * `pcall`/`xpcall` drive the protected function through `Vm.callValue` (the
//!     bounded nested dispatch) and catch the unwinding error. On a **catchable**
//!     fault (`interp.catchable`) they read the value from `pending_error`, or —
//!     for a bare runtime fault like `nil + 1` — synthesize it from the still-live
//!     faulting frames via `Vm.synthErrorValue` **before** restoring the boundary.
//!     Non-catchable faults (OOM, effect-log integrity) re-raise unchanged so a
//!     program can never observe heap pressure or mask a replay divergence.
//!
//! Determinism: the whole error path reads only deterministic state (argument
//! values, opcodes, operand types, source spans) and interns id-stable strings,
//! so a program raises and catches byte-identical values across all 8 modes.
//!
//! `error(msg, level)` prepends a `chunk:line:` location to **string** messages
//! per Lua's `level` rule (via `Vm.raiseLocatedError` + the shared `callSiteAt`
//! locator); non-string messages pass through verbatim.
//!
//! Not yet (deferred follow-up): `xpcall`'s handler runs *after* the unwind with
//! the error value only (no before-unwind traceback — that waits on
//! `debug.traceback`).

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
// pcall / xpcall — the protected-call core
// ---------------------------------------------------------------------------

/// Run `f(call_args...)` protected, writing `out[0] = ok` and (on success)
/// `out[1..] = results`. Returns the number of values written into `out`.
///
/// `handler` non-null ⇒ `xpcall`: on a caught error the message handler is invoked
/// with the error value (after the boundary is restored) and its results replace
/// the error value in `out[1..]`. A handler that raises a *catchable* error yields
/// the fixed string `"error in error handling"` (never recurses); a *non-catchable*
/// handler fault (OOM, effect-log integrity, replay divergence) re-raises unchanged,
/// exactly like the primary protected call — it must never be masked.
///
/// MUST be called from a native (it reenters the VM). The boundary it restores is
/// `(vm.depth, vm.stack_top)` captured at entry — `callValue` leaves the faulting
/// frames live on error so `synthErrorValue` can read them here first.
fn protectedCall(vm: *Vm, f: Value, call_args: []const Value, out: []Value, handler: ?Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    const entry_depth = vm.depth;
    const entry_top = vm.stack_top;
    const results = if (out.len > 1) out[1..] else out[0..0];

    const produced = vm.callValue(f, call_args, results) catch |err| {
        // Determinism/replay-integrity faults are not catchable — re-raise so the
        // program cannot observe heap pressure or swallow a replay divergence.
        if (!interp.catchable(err)) return err;
        // Still at the faulting depth here (callValue did not unwind): build the
        // error value from the live frames BEFORE restoring the boundary.
        const errval = vm.pending_error orelse try vm.synthErrorValue(err);
        vm.pending_error = null;
        vm.depth = entry_depth;
        vm.stack_top = entry_top;
        out[0] = Value.boolean(false);

        if (handler) |h| {
            const hn = vm.callValue(h, &.{errval}, results) catch |herr| {
                // A non-catchable handler fault (OOM, effect-log integrity, a
                // replay divergence) must propagate unchanged — swallowing it as
                // "error in error handling" would let a program mask heap pressure
                // or a determinism break. Re-raise with the frames still live.
                if (!interp.catchable(herr)) return herr;
                // A catchable handler fault: restore again and report a fixed
                // message. Do not recurse into the handler.
                vm.pending_error = null;
                vm.depth = entry_depth;
                vm.stack_top = entry_top;
                if (out.len > 1) out[1] = try vm.heap.internValue("error in error handling");
                return @min(out.len, @as(usize, 2));
            };
            return @min(out.len, 1 + hn);
        }
        if (out.len > 1) out[1] = errval;
        return @min(out.len, @as(usize, 2));
    };
    // Success: no error value should be parked.
    std.debug.assert(vm.pending_error == null);
    out[0] = Value.boolean(true);
    return @min(out.len, 1 + produced);
}

fn nPcallN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    if (args.len < 1) return error.TypeError;
    return protectedCall(vmOf(ctx), args[0], args[1..], out, null);
}

fn nPcall1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    var b: [1]Value = undefined;
    _ = try protectedCall(vmOf(ctx), args[0], args[1..], b[0..1], null);
    return b[0];
}

fn nXpcallN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    if (args.len < 2) return error.TypeError;
    return protectedCall(vmOf(ctx), args[0], args[2..], out, args[1]);
}

fn nXpcall1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.TypeError;
    var b: [1]Value = undefined;
    _ = try protectedCall(vmOf(ctx), args[0], args[2..], b[0..1], args[1]);
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
    .{ .name = "assert", .func = &nAssert1, .multi = &nAssertN },
};
