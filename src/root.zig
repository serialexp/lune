//! lune — the library root module.
//!
//! Public surface of the VM core. Phase 0 is scaffolding only: this exposes a
//! version string and the threaded-dispatch smoke test. Real subsystems (value
//! model, lexer, parser, bytecode, interpreter, trace recorder, …) attach here
//! as the build phases land. See docs/design/00-architecture.md.

const std = @import("std");

/// Project version. Kept in step with build.zig.zon's `.version`.
pub const version = "0.0.0";

/// Phase 0 dispatch smoke test (threaded `@call(.always_tail)`).
pub const dispatch = @import("dispatch.zig");

/// Phase 1 — value & object model and numeric semantics.
pub const object = @import("object.zig");
pub const value = @import("value.zig");
pub const regwindow = @import("regwindow.zig");
pub const arith = @import("arith.zig");

/// Memory accounting — the `TrackingAllocator` wrapper + allocation discipline.
pub const mem = @import("mem.zig");

/// Diagnostic / CLI I/O — the single wrapper around the churny `std.Io` writer
/// API and `Value` text rendering.
pub const io = @import("io.zig");

/// Phase 2 — front end: lexer, AST, parser.
pub const diag = @import("diag.zig");
pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

/// Phase 3 — runtime heap objects + bytecode ISA + tier-0 interpreter.
pub const string = @import("string.zig");
pub const array = @import("array.zig");
pub const table = @import("table.zig");
pub const function = @import("function.zig");
pub const gc = @import("gc.zig");
pub const bytecode = @import("bytecode.zig");
pub const compiler = @import("compiler.zig");
pub const interp = @import("interp.zig");

/// Standard library — one module per Lua-shaped library. Each owns its native fn
/// bodies plus a `natives`/`constants` registry slice that `interp.base_natives`
/// concatenates, so library code stays out of the interpreter core. Re-exported
/// here so `zig build test` analyses and runs each library's unit tests.
pub const stdlib_math = @import("stdlib/math.zig");
pub const stdlib_table = @import("stdlib/table.zig");
pub const stdlib_base = @import("stdlib/base.zig");
pub const stdlib_basic = @import("stdlib/basic.zig");
pub const stdlib_string = @import("stdlib/string.zig");
pub const stdlib_pattern = @import("stdlib/pattern.zig");

/// Phase 5 — hot-path detection + trace recorder (records IR; tier-0 executes).
pub const trace = @import("trace.zig");

/// Compile-gated live JIT debug logging (`-Djit-debug` + `--jit-debug`).
pub const jitdbg = @import("jitdbg.zig");

/// Phase 6 — tier-1a trace IR-interpreter (executes recorded traces; deopts to
/// tier-0 on a guard failure).
pub const irinterp = @import("irinterp.zig");

/// Phase 8 — tier-1b native codegen: a hand-rolled x86-64 encoder (`x64`) and the
/// integer-trace machine-code compiler (`nativegen`). CLI/native-only — its
/// OS-specific bits are comptime-gated to x86-64 Linux (inert elsewhere, incl. wasm).
pub const x64 = @import("x64.zig");
pub const nativegen = @import("nativegen.zig");

/// Phase 7 (trace-iteration animation) — in-memory trace **execution log**: per
/// entry/exit-ramp events the IR-interpreter emits for the visualizer. Off the JIT
/// path (the executor is comptime-specialized).
pub const execlog = @import("execlog.zig");

/// Phase 6b — trace optimizer (constant folding / CSE / dead-code elimination;
/// rewrite passes run once at commit time).
pub const tropt = @import("tropt.zig");

/// Trace-opportunity detector — a deterministic analysis pass over an optimized
/// trace that scores it against a catalog of waste signatures (dead carried phis,
/// duplicate carries, …). Pure detection, no transforms.
pub const troptdiag = @import("troptdiag.zig");

/// Phase 5b — trace serialization: maps a committed `trace.Trace` to/from its
/// on-disk wire form via the vendored, generated binschema codec.
pub const traceser = @import("traceser.zig");

/// Phase 7 v2 (F2a) — keyframe snapshot serialization: maps a live VM's
/// reachable heap graph + roots to its on-disk snapshot form (shares the
/// generated binschema codec with `traceser`).
pub const keyframeser = @import("keyframeser.zig");

/// Phase 7 v2 (F2d) — effect-log serialization: maps a VM's recorded
/// nondeterministic inputs (`interp.Effect`) to/from their on-disk form (shares
/// the generated binschema codec with `traceser`/`keyframeser`).
pub const effectser = @import("effectser.zig");

/// Phase 7 (trace-iteration animation) — execution-log serialization: maps the
/// IR-interpreter's per-trace execution logs (`execlog.TraceExecLog`) to/from their
/// on-disk form (fourth record family; shares the generated binschema codec).
pub const execlogser = @import("execlogser.zig");

/// JIT coverage serialization: maps `trace.TraceState`'s execution-coverage
/// accounting (aggregate native-vs-tier-0 split by iterations + TSC time, event
/// counters, per-anchor breakdown) to its on-disk form (fifth record family;
/// shares the generated binschema codec). An observation artifact for the viz.
pub const coverageser = @import("coverageser.zig");

/// Re-exports for ergonomic access.
pub const Value = value.Value;
pub const GcHeader = object.GcHeader;

test {
    // Pull in tests from referenced files.
    _ = dispatch;
    _ = object;
    _ = value;
    _ = regwindow;
    _ = arith;
    _ = mem;
    _ = io;
    _ = diag;
    _ = token;
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = string;
    _ = array;
    _ = table;
    _ = function;
    _ = gc;
    _ = bytecode;
    _ = compiler;
    _ = interp;
    _ = trace;
    _ = jitdbg;
    _ = irinterp;
    _ = x64;
    _ = nativegen;
    _ = execlog;
    _ = tropt;
    _ = troptdiag;
    _ = traceser;
    _ = keyframeser;
    _ = effectser;
    _ = execlogser;
    _ = coverageser;
}
