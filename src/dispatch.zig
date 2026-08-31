//! Phase 0 smoke test: prove guaranteed tail calls.
//!
//! mahina's tier-0 interpreter will use threaded dispatch — each bytecode handler
//! does its work and then *tail-calls* the next handler, so an entire program
//! runs as one long chain of tail calls with no interpreter stack growth. That
//! design only holds if `@call(.always_tail, ...)` actually elides the caller's
//! frame in the builds we ship, including Debug.
//!
//! `@call(.always_tail)` is a *guarantee*: if the compiler cannot emit a real
//! tail call it is a compile error, not a silent downgrade. So merely compiling
//! this file is already strong evidence. The runtime test below is the
//! belt-and-suspenders the architecture doc asks for: it executes millions of
//! handler-to-handler tail calls under whatever mode the test is built in. If
//! frames were *not* being reused, that depth would overflow the stack long
//! before completion. Reaching the assertion means the chain ran in O(1) stack.
//!
//! Scope of "throwaway": only this *toy 2-opcode loop* is temporary — the real
//! interpreter (Phase 3) replaces the code, NOT the capability. Guaranteed tail
//! calls are a permanent architectural pillar (`docs/design/00-architecture.md`
//! principle #4: "Stay on Zig's bedrock"); verifying them here is *the* reason
//! the build forces `use_llvm = true` on every artifact that uses threaded
//! dispatch. The current tier-0 (`interp.zig`) is deliberately a `while/switch`
//! correctness oracle and does not yet thread its dispatch — threaded dispatch is
//! a reserved fast-path technique, and this test is the permanent **capability
//! gate** that keeps it available. Do NOT delete or skip it (e.g. when porting to
//! a new target like wasm32): if a target can't emit guaranteed tail calls, that
//! must surface as a loud failure here, not be quietly gated away.

const std = @import("std");

/// Minimal opcode set for the smoke test.
const Op = enum(u8) {
    /// Decrement the loop counter and bump the accumulator, staying on this PC
    /// until the counter hits zero (then fall through to `halt`).
    loop,
    /// Stop and return the accumulator.
    halt,
};

/// The toy machine state threaded through every handler by pointer.
const Vm = struct {
    code: []const Op,
    pc: usize = 0,
    acc: u64 = 0,
    counter: u64,
};

/// A handler takes the VM and returns the final accumulator once `halt` is hit.
const Handler = *const fn (*Vm) u64;

/// Dispatch table indexed by opcode. The indirect call through this table is
/// the only thing between handlers — mirroring the real interpreter's hot path.
const handlers = [_]Handler{ opLoop, opHalt };

/// Decode the current opcode and tail-call its handler.
fn dispatch(vm: *Vm) u64 {
    const op = vm.code[vm.pc];
    return @call(.always_tail, handlers[@intFromEnum(op)], .{vm});
}

fn opLoop(vm: *Vm) u64 {
    if (vm.counter == 0) {
        vm.pc += 1; // advance to `halt`
        return @call(.always_tail, dispatch, .{vm});
    }
    vm.counter -= 1;
    vm.acc += 1;
    // PC stays put: re-enter dispatch, which re-enters opLoop — the tail-call
    // chain whose depth equals `counter` if frames were NOT being reused.
    return @call(.always_tail, dispatch, .{vm});
}

fn opHalt(vm: *Vm) u64 {
    return vm.acc;
}

/// Run the toy program: loop `iterations` times, then halt.
pub fn run(iterations: u64) u64 {
    const program = [_]Op{ .loop, .halt };
    var vm = Vm{ .code = &program, .counter = iterations };
    return dispatch(&vm);
}

test "always_tail dispatch runs in constant stack" {
    // Far more iterations than any reasonable stack could hold as frames
    // (~2M frames * tens of bytes >> the default 8 MiB main-thread stack).
    // Completing without a stack overflow is the proof that `.always_tail`
    // reuses the frame.
    const iterations: u64 = 2_000_000;
    const result = run(iterations);
    try std.testing.expectEqual(iterations, result);
}
