//! The test runner for every mahina test binary: std's own runner
//! (`lib/compiler/test_runner.zig` of the pinned toolchain, imported as
//! `std_test_runner`), plus `debug.SelfInfo` from `jit_unwind`. std reads
//! that override from the root module, and a test binary's root is its
//! runner, so this is the only place tests can install it (see
//! `src/jit_unwind.zig` for why they must).
//!
//! A runner only sees the imports of the module under test, so `build.zig`
//! gives each tested module `std_test_runner` and `jit_unwind`.

const std = @import("std");
const builtin = @import("builtin");
const std_runner = @import("std_test_runner");

pub const debug = @import("jit_unwind").debug;

pub const std_options = std_runner.std_options;
pub const mainSimple = std_runner.mainSimple;
pub const log = std_runner.log;
pub const fuzz = std_runner.fuzz;

/// Test sharding for `zig build test -Dtest-shards=N`: `build.zig` starts N
/// runs of one test binary, each with `MAHINA_TEST_SHARD=<i>/<N>`, and run `i`
/// keeps every N-th test (by declaration order, so the slow tests of one file
/// spread over the shards instead of landing in one). std's runner has no
/// sharding of its own; it reads `builtin.test_functions`, which is a mutable
/// declaration, so the wrapper installs the filtered list before delegating.
/// Unset (or malformed) runs everything.
var shard_tests: [shard_capacity]std.lang.TestFn = undefined;
const shard_capacity = 16384;

pub fn main(init: std.process.Init.Minimal) void {
    if (init.environ.getPosix("MAHINA_TEST_SHARD")) |spec| installShard(spec);
    return std_runner.main(init);
}

fn installShard(spec: []const u8) void {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return;
    const index = std.fmt.parseInt(usize, spec[0..slash], 10) catch return;
    const count = std.fmt.parseInt(usize, spec[slash + 1 ..], 10) catch return;
    if (count == 0 or index >= count) return;
    var kept: usize = 0;
    for (builtin.test_functions, 0..) |t, i| {
        if (i % count != index) continue;
        if (kept == shard_tests.len) @panic("tests/test_runner.zig: raise shard_capacity");
        shard_tests[kept] = t;
        kept += 1;
    }
    builtin.test_functions = shard_tests[0..kept];
}

// std looks these up on the root by name, so a declaration std's runner adds
// and this file doesn't forward would be silently lost. Make it a build error.
comptime {
    for (@typeInfo(std_runner).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("tests/test_runner.zig must re-export std_test_runner." ++ name);
    }
}
