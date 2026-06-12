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

/// Phase 3 — bytecode ISA + tier-0 interpreter.
pub const bytecode = @import("bytecode.zig");
pub const interp = @import("interp.zig");

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
    _ = bytecode;
    _ = interp;
}
