const std = @import("std");
const builtin = @import("builtin");

// The toolchain we pin to. Mirrors `.minimum_zig_version` in build.zig.zon and
// the `.zig-version` file. Architecture principle #4/#5: we ride a `-dev` Zig
// and must catch drift loudly rather than discover it as a mystery miscompile.
const pinned_zig_version = "0.17.0-dev.813+2153f8143";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Toolchain guard. By default we only warn on a version mismatch so local
    // hacking on a nearby compiler is not blocked; CI passes
    // `-Denforce-zig-version=true` to turn drift into a hard failure.
    const enforce_zig_version = b.option(
        bool,
        "enforce-zig-version",
        "Fail the build if the active Zig differs from the pinned toolchain (CI uses this).",
    ) orelse false;
    checkZigVersion(enforce_zig_version);

    // The vendored binschema runtime (src/gen/binschema/). The generated trace
    // serializer (src/gen/trace_schema.zig) imports this as the "binschema"
    // module; the lune module re-exports the import so any src/ file can reach
    // it. Regenerate both with tools/regen-trace-schema.sh — never hand-edit.
    const binschema_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/binschema/binschema.zig"),
        .target = target,
    });

    // The library module: the VM core, importable by consumers and by tests.
    const mod = b.addModule("lune", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "binschema", .module = binschema_mod },
        },
    });

    // The CLI executable. Thin shell over the library module for now.
    const exe = b.addExecutable(.{
        .name = "lune",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lune", .module = mod },
            },
        }),
    });
    // Force the LLVM backend. Threaded dispatch relies on guaranteed tail calls
    // (`@call(.always_tail)`), and as of this pinned Zig the default self-hosted
    // `stage2_x86_64` backend rejects them ("does not support tail calls on
    // target architecture x86_64"). Only LLVM honours the guarantee today. See
    // docs/design/00-architecture.md principle #4. Revisit when the self-hosted
    // backend gains tail-call support.
    exe.use_llvm = true;
    b.installArtifact(exe);

    // `zig build run` — run the CLI.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the lune CLI");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — run unit tests from both the library and the CLI module.
    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.use_llvm = true; // tail-call smoke test needs LLVM (see above)
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.use_llvm = true; // ditto
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `zig build bench` — the Phase 6b trace-optimizer benchmark. Always
    // ReleaseFast (a Debug bench would be dominated by safety checks and tell us
    // nothing about the optimizer); informational, not a test.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "lune", .module = mod },
            },
        }),
    });
    bench_exe.use_llvm = true; // tail-call dispatch needs LLVM (see above)
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the trace-optimizer benchmark (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
}

/// Compare the compiler driving this build script against the pinned toolchain.
/// Warns by default; hard-fails when `enforce` is set.
fn checkZigVersion(enforce: bool) void {
    const pinned = std.SemanticVersion.parse(pinned_zig_version) catch unreachable;
    const active = builtin.zig_version;
    if (active.order(pinned) == .eq) return;

    if (enforce) {
        std.debug.panic(
            "lune pins Zig {s} but the active toolchain is {f}. " ++
                "Install the pinned `-dev` build (see .zig-version) or drop -Denforce-zig-version.",
            .{ pinned_zig_version, active },
        );
    } else {
        std.log.warn(
            "lune pins Zig {s} but the active toolchain is {f}; building anyway. " ++
                "Pass -Denforce-zig-version=true to make this fatal.",
            .{ pinned_zig_version, active },
        );
    }
}
