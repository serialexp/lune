//! The test runner for every mahina test binary: std's own runner
//! (`lib/compiler/test_runner.zig` of the pinned toolchain, imported as
//! `std_test_runner`), plus `debug.SelfInfo` from `jit_unwind`. std reads
//! that override from the root module, and a test binary's root is its
//! runner, so this is the only place tests can install it (see
//! `src/jit_unwind.zig` for why they must).
//!
//! A runner only sees the imports of the module under test, so `build.zig`
//! gives each tested module `std_test_runner` and `jit_unwind`.

const std_runner = @import("std_test_runner");

pub const debug = @import("jit_unwind").debug;

pub const std_options = std_runner.std_options;
pub const main = std_runner.main;
pub const mainSimple = std_runner.mainSimple;
pub const log = std_runner.log;
pub const fuzz = std_runner.fuzz;

// std looks these up on the root by name, so a declaration std's runner adds
// and this file doesn't forward would be silently lost. Make it a build error.
comptime {
    for (@typeInfo(std_runner).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("tests/test_runner.zig must re-export std_test_runner." ++ name);
    }
}
