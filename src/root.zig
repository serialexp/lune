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
pub const table = @import("table.zig");
pub const function = @import("function.zig");
pub const gc = @import("gc.zig");
pub const bytecode = @import("bytecode.zig");
pub const compiler = @import("compiler.zig");
pub const interp = @import("interp.zig");

/// Phase 5 — hot-path detection + trace recorder (records IR; tier-0 executes).
pub const trace = @import("trace.zig");

/// Phase 6 — tier-1a trace IR-interpreter (executes recorded traces; deopts to
/// tier-0 on a guard failure).
pub const irinterp = @import("irinterp.zig");

/// Phase 6b — trace optimizer (constant folding / CSE / dead-code elimination;
/// rewrite passes run once at commit time).
pub const tropt = @import("tropt.zig");

/// Phase 5b — trace serialization: maps a committed `trace.Trace` to/from its
/// on-disk wire form via the vendored, generated binschema codec.
pub const traceser = @import("traceser.zig");

/// Re-exports for ergonomic access.
pub const Value = value.Value;
pub const GcHeader = object.GcHeader;

test {
    // Pull in tests from referenced files.
    _ = dispatch;
    _ = object;
    _ = value;
    _ = arith;
    _ = mem;
    _ = io;
    _ = diag;
    _ = token;
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = string;
    _ = table;
    _ = function;
    _ = gc;
    _ = bytecode;
    _ = compiler;
    _ = interp;
    _ = trace;
    _ = irinterp;
    _ = tropt;
    _ = traceser;
}
