//! jitdbg — compile-gated live JIT debug logging.
//!
//! The permanent home for the dispatcher/arming telemetry we used to hand-add
//! and hand-remove as ad-hoc `std.debug.print` scaffolding every time the JIT
//! needed live inspection. Everything routed through here is comptime-gated on
//! the `-Djit-debug` build option (`build_options.jit_debug`, default false):
//! in a normal build every call site compiles to **nothing** — zero branches,
//! zero format strings in the binary — so it can stay in the tree forever.
//!
//! Two gates stack:
//!   1. **Compile time**: `zig build -Djit-debug=true` compiles the logging in.
//!      (Also works for tests: `zig build test -Djit-debug=true`.)
//!   2. **Run time**: even in a debug build a VM is silent until
//!      `vm.trace.config.debug_log` is set. The CLI flag `--jit-debug` sets it;
//!      a test sets it on exactly the VM under investigation, so parallel VMs
//!      in the same test binary don't drown each other out.
//!
//! Use via `TraceState.dbg()` and the `TraceState.dbgDump*` helpers in
//! trace.zig rather than calling `log` directly, so the runtime gate is
//! applied consistently. Output goes to stderr (like the `--dump-*` family)
//! and never touches program stdout, so byte-identity gates are unaffected.

const std = @import("std");

/// Comptime master switch — `zig build -Djit-debug=true`.
pub const enabled: bool = @import("build_options").jit_debug;

/// Print one debug line to stderr (with a `[jit]` prefix). Compiled out
/// entirely unless the build sets `-Djit-debug=true`. Callers are responsible
/// for the runtime gate (`TraceState.config.debug_log`).
pub inline fn log(comptime fmt: []const u8, args: anytype) void {
    if (comptime enabled) std.debug.print("[jit] " ++ fmt ++ "\n", args);
}
