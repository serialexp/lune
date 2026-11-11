//! The time-travel debugger's core (doc 86). This file is the module hub: it
//! re-exports the submodules and pulls their tests into the build. The core
//! does no I/O; `mahina dap` and the C API are its transports (P3, P6).

pub const session = @import("debug/session.zig");
pub const Session = session.Session;

test {
    _ = session;
    _ = @import("debug/session_test.zig");
}
