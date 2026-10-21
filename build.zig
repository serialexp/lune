const std = @import("std");
const builtin = @import("builtin");

// The toolchain we pin to. Mirrors `.minimum_zig_version` in build.zig.zon and
// the `.zig-version` file. Architecture principle #4/#5: we pin one exact Zig
// and must catch drift loudly rather than discover it as a mystery miscompile.
const pinned_zig_version = "0.17.0";

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
    // `mahina --version`: the version is build.zig.zon's; the commit is only
    // known when the builder says (tools/mahina-cli.sh passes LUNE_COMMIT), so
    // a plain build reads no git state and stays reproducible.
    const version_commit = b.option([]const u8, "version-commit", "The commit this is built from, for `mahina --version` (the release CLIs pass it)");
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "jit_debug", jit_debug);
    build_opts.addOption([]const u8, "version", @import("build.zig.zon").version);
    build_opts.addOption(?[]const u8, "version_commit", version_commit);
    const build_opts_mod = build_opts.createModule();

    // The vendored binschema runtime (src/gen/binschema/). The generated trace
    // serializer (src/gen/trace_schema.zig) imports this as the "binschema"
    // module; the mahina module re-exports the import so any src/ file can reach
    // it. Regenerate both with tools/regen-trace-schema.sh — never hand-edit.
    const binschema_mod = b.createModule(.{
        .root_source_file = b.path("src/gen/binschema/binschema.zig"),
        .target = target,
    });

    // Keeps std's stack unwinder out of JIT code (src/jit_unwind.zig): the
    // registry `nativegen_mcode.zig` records executable mappings in, and the
    // `debug.SelfInfo` every root we own installs. Its own module, so the
    // test runner (tests/test_runner.zig) reaches the same registry.
    const jit_unwind_mod = b.createModule(.{
        .root_source_file = b.path("src/jit_unwind.zig"),
        .target = target,
    });

    // The library module: the VM core, importable by consumers and by tests.
    const mod = b.addModule("mahina", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "binschema", .module = binschema_mod },
            .{ .name = "build_options", .module = build_opts_mod },
            .{ .name = "jit_unwind", .module = jit_unwind_mod },
        },
    });

    // The web UI `mahina viz` serves (src/viz_server.zig). `-Dviz-dist=<dir>`
    // embeds a built `viz/dist` (`just cli` builds one): tools/embed_assets.zig
    // packs it into one blob plus an index module. It reads a WriteFile copy of
    // the tree, whose content-hashed path re-runs the generator whenever an
    // asset changes. Without the option the CLI gets a stub with no files, and
    // `mahina viz` says the UI wasn't built in.
    const viz_dist = b.option(std.Build.LazyPath, "viz-dist", "Embed this built viz/dist in the CLI for `mahina viz`");
    const viz_assets_root = if (viz_dist) |dist| blk: {
        const copy = b.addWriteFiles();
        const tree = copy.addCopyDirectory(dist, "dist", .{});
        const embed_tool = b.addExecutable(.{
            .name = "embed_assets",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/embed_assets.zig"),
                .target = b.graph.host,
            }),
        });
        const gen = b.addRunArtifact(embed_tool);
        gen.addDirectoryArg2(tree, .{});
        break :blk gen.addOutputDirectoryArg2("viz_assets", .{}).path(b, "assets.zig");
    } else b.addWriteFiles().add("assets.zig",
        \\//! The CLI was built without `-Dviz-dist`: no web UI to serve.
        \\
        \\pub const File = struct { path: []const u8, data: []const u8 };
        \\
        \\pub const embedded = false;
        \\
        \\pub const files = [_]File{};
        \\
    );
    const viz_assets_mod = b.createModule(.{ .root_source_file = viz_assets_root });

    // `-Dcli-strip=true` drops the CLI's debug info (the release binaries do).
    const cli_strip = b.option(bool, "cli-strip", "Build the CLI without debug info (the release binaries do)");
    // `-Dcli-frame-pointers=true` keeps rbp in every CLI frame, so
    // `perf record -g` unwinds the runtime's call chains (the DWARF unwinder
    // drops them on a ReleaseFast build).
    const cli_frame_pointers = b.option(bool, "cli-frame-pointers", "Keep frame pointers in the CLI (for perf call graphs)") orelse false;

    // The CLI executable. Thin shell over the library module for now.
    const exe = b.addExecutable(.{
        .name = "mahina",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = cli_strip,
            .omit_frame_pointer = if (cli_frame_pointers) false else null,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
                .{ .name = "viz_assets", .module = viz_assets_mod },
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
    // Every test binary runs tests/test_runner.zig: std's runner plus the
    // jit_unwind `debug.SelfInfo`. A runner sees only the imports of the
    // module under test, hence `runner.addImports`.
    const runner: MahinaTestRunner = .{
        .path = b.path("tests/test_runner.zig"),
        .std_runner = b.createModule(.{
            .root_source_file = b.graph.path(.zig_lib, "compiler/test_runner.zig"),
            .target = target,
        }),
        .jit_unwind = jit_unwind_mod,
    };
    runner.addImports(mod);
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = test_filters, .test_runner = runner.config() });
    mod_tests.use_llvm = true; // tail-call smoke test needs LLVM (see above)
    const run_mod_tests = b.addRunArtifact(mod_tests);

    runner.addImports(exe.root_module);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters, .test_runner = runner.config() });
    exe_tests.use_llvm = true; // ditto
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // jit_unwind's own tests (registry + wrapper): std's plain runner, since
    // they exercise the wrapper directly rather than through std.debug.
    const jit_unwind_tests = b.addTest(.{ .root_module = jit_unwind_mod, .filters = test_filters });
    const run_jit_unwind_tests = b.addRunArtifact(jit_unwind_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_jit_unwind_tests.step);

    // --- embedding C ABI (doc 59) -------------------------------------------
    //
    // `zig build lib` — `libmahina.a` + `include/mahina.h`: the C-ABI embedding
    // surface (`src/capi.zig`) a host (the Rust crates under `embed/rust/`, or
    // any C program) links against. Static first (no soname story); needs libc
    // (the exports allocate through malloc).
    //
    // Position-independent by default on every target: the archive's consumers
    // link it into PIEs (rustc's default) and shared libraries (doc 60 §6.3's
    // acceptance harness), and zig's static-musl default is non-PIC, whose
    // R_X86_64_32 relocations a PIE link rejects. `-Dlib-pic=false` opts out.
    // The pic and strip settings set here on the root module govern the whole
    // compilation unit, the imported `mahina` module included.
    // The acceptance harness's frame-pointer unwinding walks also need every
    // library frame to keep rbp. Unwind tables are always async (§3.3: the
    // DWARF walks rely on them).
    // `-Dlib-strip=true` drops debug info: the vendor bundle
    // (tools/mahina-bundle.sh) ships stripped archives.
    const lib_pic = b.option(bool, "lib-pic", "Build libmahina position-independent (default true)") orelse true;
    const lib_strip = b.option(bool, "lib-strip", "Build libmahina without debug info (the vendor bundle does)");
    const lib_frame_pointers = b.option(bool, "lib-frame-pointers", "Keep frame pointers in libmahina (doc 60 §6.3 acceptance)") orelse false;
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = lib_pic,
        .strip = lib_strip,
        .unwind_tables = .async,
        .omit_frame_pointer = if (lib_frame_pointers) false else null,
        .imports = &.{
            .{ .name = "mahina", .module = mod },
        },
    });
    // Doc 60 §3.1: the hand-written host-call entry joins the module on the
    // targets `src/asm/target.zig` gates in (Linux x86-64 SysV/ELF); every
    // other target runs H1. `capi.zig` reads the same predicate to decide
    // whether `mh_call` tail-calls into it.
    // Its offsets file has a block per runtime-safety mode (std's hash maps
    // grow under safety), selected by this define; `std.debug.runtime_safety`
    // is the same function of the optimize mode, and creating a VM
    // (`capi.createVm`) verifies the two agree.
    if (@import("src/asm/target.zig").hostcallEntry(&target.result)) {
        const safety = optimize == .debug or optimize == .safe;
        capi_mod.addCSourceFile(.{
            .file = b.path("src/asm/hostcall_x64.S"),
            .language = .assembly_with_preprocessor,
            .flags = &.{if (safety) "-DMAHINA_RUNTIME_SAFETY=1" else "-DMAHINA_RUNTIME_SAFETY=0"},
        });
    }
    const capi_lib = b.addLibrary(.{
        .name = "mahina",
        .root_module = capi_mod,
        .linkage = .static,
    });
    capi_lib.use_llvm = true; // tail-call dispatch needs LLVM (see above)
    // NOT bundled: Zig's compiler-rt carries memset/memcpy/memmove, which a
    // foreign linker (rustc/cc) would resolve for the whole host process in
    // place of libc's. capi.zig exports the one routine the host can't supply
    // (__zig_probe_stack); the rest (__divti3, …) come from libgcc / Rust's
    // compiler_builtins.
    capi_lib.bundle_compiler_rt = false;
    capi_lib.installHeader(b.path("include/mahina.h"), "mahina.h");
    const install_capi_lib = b.addInstallArtifact(capi_lib, .{});
    const lib_step = b.step("lib", "Build the embedding static library (libmahina.a + mahina.h)");
    lib_step.dependOn(&install_capi_lib.step);

    // capi unit tests (src/capi_test.zig) ride the normal test gate.
    runner.addImports(capi_mod);
    const capi_tests = b.addTest(.{ .root_module = capi_mod, .filters = test_filters, .test_runner = runner.config() });
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
            .optimize = .fast,
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
            .optimize = .fast,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_topo_exe.use_llvm = true;
    const run_bench_topo = b.addRunArtifact(bench_topo_exe);
    const bench_topo_step = b.step("bench-topology", "Run the region-topology rebuild benchmark (ReleaseFast)");
    bench_topo_step.dependOn(&run_bench_topo.step);

    // `zig build bench-facts` — doc 67 §5.3: building a page's slab fact
    // tables, and one arm-time `proves`, at the trace size limits.
    // ReleaseFast, informational, not a test (global Rule #22).
    const bench_facts_exe = b.addExecutable(.{
        .name = "bench-facts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_facts.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_facts_exe.use_llvm = true;
    const run_bench_facts = b.addRunArtifact(bench_facts_exe);
    const bench_facts_step = b.step("bench-facts", "Run the doc 67 fact-table build benchmark (ReleaseFast)");
    bench_facts_step.dependOn(&run_bench_facts.step);

    // `zig build bench-retire` — doc 61 Phase Q: trace retirement at a
    // collection (one batch, one structural rebuild) as the cache grows.
    // ReleaseFast, informational, not a test (global Rule #22).
    const bench_retire_exe = b.addExecutable(.{
        .name = "bench-retire",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_retire.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_retire_exe.use_llvm = true;
    const run_bench_retire = b.addRunArtifact(bench_retire_exe);
    const bench_retire_step = b.step("bench-retire", "Run the Phase Q trace-retirement benchmark (ReleaseFast)");
    bench_retire_step.dependOn(&run_bench_retire.step);

    // `zig build bench-gcwalk` — doc 61 §6.3: the masked `.gc` root walk on a
    // near-full register stack, against the same walk with every frame kept
    // whole. ReleaseFast, informational, not a test (global Rule #22).
    const bench_gcwalk_exe = b.addExecutable(.{
        .name = "bench-gcwalk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_gcwalk.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_gcwalk_exe.use_llvm = true;
    const run_bench_gcwalk = b.addRunArtifact(bench_gcwalk_exe);
    const bench_gcwalk_step = b.step("bench-gcwalk", "Run the doc 61 masked GC root-walk benchmark (ReleaseFast)");
    bench_gcwalk_step.dependOn(&run_bench_gcwalk.step);

    // `zig build bench-keyframe` — doc 61 Phase K: keyframe capture and
    // restore over a million objects, hash entries or cells. ReleaseFast,
    // informational, not a test (global Rule #22).
    const bench_keyframe_exe = b.addExecutable(.{
        .name = "bench-keyframe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_keyframe.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{
                .{ .name = "mahina", .module = mod },
            },
        }),
    });
    bench_keyframe_exe.use_llvm = true;
    const run_bench_keyframe = b.addRunArtifact(bench_keyframe_exe);
    const bench_keyframe_step = b.step("bench-keyframe", "Run the doc 61 Phase K keyframe capture/restore benchmark (ReleaseFast)");
    bench_keyframe_step.dependOn(&run_bench_keyframe.step);

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
    // `-Dwasm-strip=true` drops its debug info: the CLI's embedded web UI
    // (`just cli`) ships a stripped ReleaseFast module.
    const wasm_strip = b.option(bool, "wasm-strip", "Build the wasm VM without debug info (the CLI's embedded UI does)");
    const wasm_exe = b.addExecutable(.{
        .name = "mahina",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_entry.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .strip = wasm_strip,
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

/// tests/test_runner.zig and the two modules it imports from the module under
/// test.
const MahinaTestRunner = struct {
    path: std.Build.LazyPath,
    std_runner: *std.Build.Module,
    jit_unwind: *std.Build.Module,

    fn config(r: MahinaTestRunner) std.Build.Step.Compile.TestRunner {
        return .{ .path = r.path, .mode = .server };
    }

    /// A tested module must import what the runner imports.
    fn addImports(r: MahinaTestRunner, m: *std.Build.Module) void {
        m.addImport("std_test_runner", r.std_runner);
        if (m.import_table.get("jit_unwind") == null) m.addImport("jit_unwind", r.jit_unwind);
    }
};

/// Compare the compiler driving this build script against the pinned toolchain.
/// Warns by default; hard-fails when `enforce` is set.
fn checkZigVersion(enforce: bool) void {
    const pinned = std.SemanticVersion.parse(pinned_zig_version) catch unreachable;
    const active = builtin.zig_version;
    if (active.order(pinned) == .eq) return;

    if (enforce) {
        std.debug.panic(
            "mahina pins Zig {s} but the active toolchain is {f}. " ++
                "Install the pinned build (see .zig-version) or drop -Denforce-zig-version.",
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
