//! lune CLI — Phase 0 placeholder.
//!
//! There is no language to run yet. This prints a banner and exercises the
//! threaded-dispatch smoke test so `zig build run` does something observable.
//! The real CLI (run a script, dump bytecode, record a trace) arrives with the
//! later phases.

const std = @import("std");
const lune = @import("lune");

pub fn main() void {
    const iterations: u64 = 1_000_000;
    const acc = lune.dispatch.run(iterations);

    std.debug.print(
        "lune {s} — scaffold.\n" ++
            "threaded-dispatch smoke test: {d} tail-call steps, acc={d} (constant stack).\n",
        .{ lune.version, iterations, acc },
    );
}

test "cli smoke" {
    // Keep the CLI module's test target non-empty so `zig build test` covers it.
    try std.testing.expectEqual(@as(u64, 5), lune.dispatch.run(5));
}
