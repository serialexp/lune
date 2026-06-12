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

test {
    // Pull in tests from referenced files.
    _ = dispatch;
}
