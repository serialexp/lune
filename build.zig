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

    // Live JIT debug logging (src/jitdbg.zig). Default off: every jitdbg call
    // site is comptime-gated on this option and compiles to nothing — zero
    // branches, zero format strings in the binary. Build with
    // `-Djit-debug=true` to compile the telemetry in, then enable it at run
    // time with the CLI `--jit-debug` flag (or `vm.trace.config.debug_log` in
    // a test) — both gates must be open before anything prints.
    const jit_debug = b.option(
        bool,
        "jit-debug",
        "Compile in live JIT debug logging (src/jitdbg.zig); enable at runtime with --jit-debug.",
    ) orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "jit_debug", jit_debug);
    const build_opts_mod = build_opts.createModule();

    // The vendored binschema runtime (src/gen/binschema/). The generated trace
    // serializer (src/gen/trace_schema.zig) imports this as the "binschema"
    // module; the mahina module re-exports the import so any src/ file can reach
    // it. Regenerate both with tools/regen-trace-schema.sh — never hand-edit.
    const binschema_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/binschema/binschema.zig"),
        .target = target,
    });

    // The library module: the VM core, importable by consumers and by tests.
    const mod = b.addModule("mahina", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "binschema", .module = binschema_mod },
            .{ .name = "build_options", .module = build_opts_mod },
        },
    });

    // The CLI executable. Thin shell over the library module for now.
    const exe = b.addExecutable(.{
        .name = "mahina",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
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
    const run_step = b.step("run", "Run the mahina CLI");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — run unit tests from both the library and the CLI module.
    // `-Dtest-filter=<substr>` narrows to matching test names (repeatable).
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose names match the filter") orelse &.{};
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
    mod_tests.use_llvm = true; // tail-call smoke test needs LLVM (see above)
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });
    exe_tests.use_llvm = true; // ditto
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- embedding C ABI (doc 59) -------------------------------------------
    //
    // `zig build lib` — `libmahina.a` + `include/mahina.h`: the C-ABI embedding
    // surface (`src/capi.zig`) a host (the Rust crates under `embed/rust/`, or
    // any C program) links against. Static first (no soname story); needs libc
    // (the exports allocate through malloc).
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "mahina", .module = mod },
        },
    });
    const capi_lib = b.addLibrary(.{
        .name = "mahina",
        .root_module = capi_mod,
        .linkage = .static,
    });
    capi_lib.use_llvm = true; // tail-call dispatch needs LLVM (see above)
    // A static lib handed to a foreign linker (rustc/cc) must carry Zig's
    // compiler-rt itself (__zig_probe_stack etc.) — nothing else provides it.
    capi_lib.bundle_compiler_rt = true;
    capi_lib.installHeader(b.path("include/mahina.h"), "mahina.h");
    const install_capi_lib = b.addInstallArtifact(capi_lib, .{});
    const lib_step = b.step("lib", "Build the embedding static library (libmahina.a + mahina.h)");
    lib_step.dependOn(&install_capi_lib.step);

    // capi unit tests (src/capi_test.zig) ride the normal test gate.
    const capi_tests = b.addTest(.{ .root_module = capi_mod, .filters = test_filters });
    capi_tests.use_llvm = true;
    const run_capi_tests = b.addRunArtifact(capi_tests);
    test_step.dependOn(&run_capi_tests.step);

    // The C header-consumer smoke test (doc 59 §3.8): a real C program compiled
    // against include/mahina.h and linked with libmahina.a, so the HEADER is
    // validated (Zig-side tests can't see it drift) along with layout and one
    // full lifecycle. Runs under `zig build test`.
    const smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.addCSourceFile(.{ .file = b.path("tests/capi_smoke.c"), .flags = &.{"-std=c99"} });
    smoke_mod.addIncludePath(b.path("include"));
    smoke_mod.linkLibrary(capi_lib);
    const smoke_exe = b.addExecutable(.{ .name = "capi-smoke", .root_module = smoke_mod });
    const run_smoke = b.addRunArtifact(smoke_exe);
    test_step.dependOn(&run_smoke.step);

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
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_exe.use_llvm = true; // tail-call dispatch needs LLVM (see above)
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the trace-optimizer benchmark (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // `zig build bench-topology` — doc 58 §4.8: the region-topology rebuild
    // boundary as proto size and qualifying-root count grow. ReleaseFast,
    // informational, not a test (global Rule #22).
    const bench_topo_exe = b.addExecutable(.{
        .name = "bench-topology",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_topology.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_topo_exe.use_llvm = true;
    const run_bench_topo = b.addRunArtifact(bench_topo_exe);
    const bench_topo_step = b.step("bench-topology", "Run the region-topology rebuild benchmark (ReleaseFast)");
    bench_topo_step.dependOn(&run_bench_topo.step);

    // --- wasm32-freestanding browser target ---------------------------------
    //
    // `zig build wasm` compiles the VM core to a reactor-style wasm module that
    // the viz/ app loads and runs in-browser (src/wasm_entry.zig — a host-free
    // C-ABI surface over the library `run` path). The clock and program output
    // cross the boundary as imports/exports, never as syscalls, so the artifact
    // carries zero host I/O. See docs/design/00-architecture.md (Phase 7 v3).
    //
    // Guaranteed tail calls are a portable architectural pillar (#4), NOT a
    // native-only convenience: the wasm target enables the `tail_call` CPU
    // feature so `@call(.always_tail)` keeps its compile-time guarantee here too
    // (`return_call` ships on-by-default in every major browser since Safari
    // 18.2). The dispatch smoke test must stay green on wasm — see the wasm test
    // step below. wasm compiles via LLVM, so `use_llvm = true` mirrors native.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.tail_call}),
    });

    const wasm_binschema_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/binschema/binschema.zig"),
        .target = wasm_target,
    });
    const wasm_mahina_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .imports = &.{
            .{ .name = "binschema", .module = wasm_binschema_mod },
            .{ .name = "build_options", .module = build_opts_mod },
        },
    });
    const wasm_exe = b.addExecutable(.{
        .name = "mahina",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_entry.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mahina", .module = wasm_mahina_mod },
            },
        }),
    });
    wasm_exe.use_llvm = true; // guaranteed tail calls need LLVM, on wasm too
    wasm_exe.entry = .disabled; // reactor module: exported functions, no `_start`
    wasm_exe.rdynamic = true; // keep the `export fn`s in the dynamic symbol table
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step("wasm", "Build the wasm32 browser VM (src/wasm_entry.zig)");
    wasm_step.dependOn(&install_wasm.step);

    // Tail-call capability gate on wasm — note the two halves:
    //   1. COMPILE-TIME: `wasm_entry.zig` exports `mahina_dispatch_smoke`, which
    //      pulls `dispatch.zig`'s `@call(.always_tail)` into this artifact. That
    //      call is a *guarantee*: if `wasm32 + tail_call` couldn't emit a real
    //      tail call, `zig build wasm` would fail right here. So a green wasm
    //      build already proves the capability survives on the browser target.
    //   2. RUNTIME: a `bun` test (viz/test/) instantiates the module and runs
    //      `mahina_dispatch_smoke(2_000_000)`, proving the engine reuses frames in
    //      practice (no stack overflow). We run it under bun rather than a Zig
    //      `addTest` because Zig's test runner needs host I/O to report results,
    //      which `wasm32-freestanding` lacks — there is no in-`zig build` way to
    //      execute freestanding-wasm tests without a WASI shim + runtime.
}

/// Compare the compiler driving this build script against the pinned toolchain.
/// Warns by default; hard-fails when `enforce` is set.
fn checkZigVersion(enforce: bool) void {
    const pinned = std.SemanticVersion.parse(pinned_zig_version) catch unreachable;
    const active = builtin.zig_version;
    if (active.order(pinned) == .eq) return;

    if (enforce) {
        std.debug.panic(
            "mahina pins Zig {s} but the active toolchain is {f}. " ++
                "Install the pinned `-dev` build (see .zig-version) or drop -Denforce-zig-version.",
            .{ pinned_zig_version, active },
        );
    } else {
        std.log.warn(
            "mahina pins Zig {s} but the active toolchain is {f}; building anyway. " ++
                "Pass -Denforce-zig-version=true to make this fatal.",
            .{ pinned_zig_version, active },
        );
    }
}
