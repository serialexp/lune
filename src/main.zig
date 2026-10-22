//! mahina CLI — run a mahina program through the tier-0 interpreter.
//!
//! Usage:
//!   mahina [options] <script.lua>   run a script file
//!   mahina [options] -e <chunk>     run a chunk given inline on the command line
//!
//! The driver walks the same path the test suite exercises —
//! parse → compile → tier-0 interpret — and just wires it to argv and the
//! process stdout/stderr. A program's own output (via `print`) goes to stdout
//! through the host-effect seam (`Vm.out`); parse/compile diagnostics and driver
//! errors go to stderr. Exit code is 0 on success, 1 on an I/O / syntax /
//! compile / runtime error, 2 on a usage error.
//!
//! The tracing JIT (Phases 5–6) is opt-in via `--trace` / `--trace-record-only`
//! / `--dump-traces`, default off — without a flag the driver is byte-for-byte
//! its pre-Phase-5 self. `--trace` records hot loops *and* runs them through the
//! tier-1a IR-interpreter (Phase 6); `--trace-record-only` records but lets tier-0
//! execute everything (Phase 5a, for inspecting IR in isolation); `--trace-no-opt`
//! records & executes but skips the trace optimizer (Phase 6b — raw IR). All are
//! output-transparent: an executed trace produces byte-identical output to tier-0
//! (it deopts to tier-0 on any guard failure), so the flags never change a
//! program's output — only whether, and how, hot loops are traced.

const std = @import("std");
const builtin = @import("builtin");
const mahina = @import("mahina");
const viz_assets = @import("viz_assets");
const viz_server = @import("viz_server.zig");

/// std's `SelfInfo` with JIT code kept out of its unwinder: in Debug and
/// ReleaseSafe `init.gpa` traces every allocation (see `src/jit_unwind.zig`).
pub const debug = mahina.jit_unwind.debug;

/// std's panic handler, preceded by a flush of the buffered stdout (doc 65
/// §6): when mahina itself panics, the program's output up to the crash still
/// reaches the file or pipe, ahead of the panic message on stderr.
pub const panic = std.debug.FullPanic(panicFlushingStdout);

fn panicFlushingStdout(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    mahina.io.flushForPanic();
    // Start the trace at the panic site, not in this wrapper.
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

const Diagnostics = mahina.diag.Diagnostics;

const usage =
    \\mahina — a Lua-shaped language (tier-0 interpreter)
    \\
    \\usage:
    \\  mahina [options] <script.lua>   run a script file
    \\  mahina [options] -e <chunk>     run a chunk given inline
    \\  mahina viz [viz options] [trace.mahinatrace]
    \\                                  serve the trace visualiser on localhost
    \\                                  (`mahina viz --help`; a script named
    \\                                  `viz` runs as `./viz`)
    \\
    \\options:
    \\  --trace              enable the tracing JIT: detect hot loops, record them
    \\                       to trace IR, and execute them in the tier-1a
    \\                       IR-interpreter (deopting to tier-0 on a guard miss).
    \\                       Output is identical to a plain run.
    \\  --trace-record-only  record hot loops but let tier-0 execute everything
    \\                       (Phase 5a) — for inspecting trace IR in isolation.
    \\  --trace-no-opt       skip the trace optimizer (constant folding / CSE /
    \\                       dead-code elimination); record & execute raw IR. Useful
    \\                       with --dump-traces to see unoptimized IR.
    \\  --jit-native         imply --trace and run hot traces as native x86-64
    \\                       machine code (tier-1b) when they fall in the proven
    \\                       integer/boolean subset; others stay on tier-1a. Output
    \\                       is identical to a plain run. x86-64/Linux only;
    \\                       elsewhere it warns and stays on tier-1a.
    \\  --dump-native        imply --jit-native and print each trace's compiled
    \\                       machine code (or "unsupported") to stderr after the run.
    \\  --dump-traces        imply --trace and print every recorded trace's IR to
    \\                       stderr after the run.
    \\  --trace-opportunities
    \\                       imply --trace and analyse every trace for optimisation
    \\                       waste signatures (dead carries, duplicate phis, …),
    \\                       printing them to stderr after the run.
    \\  --dump-aborts        imply --trace and log every recording that aborts, then
    \\                       print an aggregated table (anchor, reason, opcode, how
    \\                       far it got, recurrence count) to stderr after the run —
    \\                       diagnoses why a hot loop never tiers up.
    \\  --jit-debug          stream live JIT telemetry (dispatcher receipts, link
    \\                       arm/disarm events) to stderr as the program runs. Only
    \\                       compiled in with `zig build -Djit-debug=true`; a plain
    \\                       binary warns and ignores the flag.
    \\  --jit-coverage       imply --trace and enable JIT execution-coverage
    \\                       accounting, then print a one-line native-vs-tier-0
    \\                       loop-iteration summary to stderr after the run. Combine
    \\                       with --jit-native to measure the native path. NB: the
    \\                       per-back-edge accounting is not free, so do not use it
    \\                       when timing with --time.
    \\  --jit-stats          imply --trace + --jit-coverage and print the FULL JIT
    \\                       stats block to stderr after the run: event counters + the
    \\                       native-vs-tier-0 coverage split + a per-anchor table.
    \\  --jit-no-exit-side-native  native traces take NO exit adapters (doc 56
    \\                       Phase 4 ablation): a hot attachable exit falls back to
    \\                       the coarse deopt instead of resuming mid-iteration in
    \\                       a side trace. On by default since doc 58 B2.
    \\  --trace-hotguard <N>  imply --trace and override the guard-failure threshold
    \\                       for side-trace recording (default 50).  When a specific
    \\                       guard fails this many times, the next back-edge records
    \\                       a side trace capturing the alternate path.
    \\  --trace-silent-budget <N>  imply --trace and override the promoted-cycle
    \\                       silent-transition budget (default 4096): the maximum
    \\                       trace-to-trace transitions one native call executes
    \\                       before the silent drain regains control. Tiering
    \\                       heuristic only — never affects program output.
    \\  --emit-traces <file> imply --trace and serialize the recorded trace cache
    \\                       to <file> (binschema wire format) after the run.
    \\  --emit-keyframe <file>
    \\                       serialize a whole-VM keyframe snapshot (the reachable
    \\                       heap graph + roots, binschema wire format) to <file>
    \\                       after the run. Independent of tracing.
    \\  --emit-effects <file>
    \\                       record the run's nondeterministic-input effect log
    \\                       (e.g. clock() results) and serialize it to <file>
    \\                       (binschema wire format) after the run.
    \\  --emit-coverage <file>
    \\                       imply --trace + JIT coverage accounting and serialize
    \\                       the coverage artifact (native-vs-tier-0 split by
    \\                       iterations + time, event counters, per-anchor) to
    \\                       <file> (binschema wire format) after the run.
    \\  --mem-stats          wrap the process allocator in mem.TrackingAllocator and
    \\                       print byte-level accounting (peak/live/total bytes,
    \\                       alloc/free counts) to stderr after the run. Small
    \\                       constant per-allocation overhead; do not combine with
    \\                       --time benchmarking.
    \\  --time               print VM execute-only wall time to stderr after the
    \\                       run (the run alone, excluding parse/compile/emit). Kept
    \\                       free of JIT coverage accounting so the timing is clean;
    \\                       add --jit-coverage explicitly if you also want the split.
    \\  --version            print the version, commit, toolchain and target
    \\  -h, --help           show this help
    \\
;

/// Tracing-JIT options parsed from the command line (default: off). When
/// `enabled`, `execute` decides tier-1a participation: true ⇒ run cached traces
/// (`--trace`), false ⇒ record only, tier-0 executes (`--trace-record-only`).
const TraceOpts = struct {
    enabled: bool = false,
    execute: bool = true,
    optimize: bool = true,
    dump: bool = false,
    /// `--jit-native`: run hot traces as native machine code (tier-1b) where they
    /// fall in the proven int/bool subset; others stay on the tier-1a interpreter.
    native_codegen: bool = false,
    /// `--dump-native`: print each cached trace's compiled machine code (or its
    /// `unsupported` verdict) to stderr after the run.
    dump_native: bool = false,
    /// `--emit-traces <file>`: serialize the trace cache here after the run.
    emit_path: ?[]const u8 = null,
    /// `--emit-keyframe <file>`: serialize a whole-VM keyframe snapshot here after
    /// the run. Independent of tracing (a heap snapshot, not a trace artifact).
    keyframe_path: ?[]const u8 = null,
    /// `--emit-effects <file>`: record the nondeterministic-input effect log and
    /// serialize it here after the run (puts the VM in effect `record` mode).
    effects_path: ?[]const u8 = null,
    /// `--emit-coverage <file>`: serialize the JIT execution-coverage artifact here
    /// after the run. Implies `--trace` + `coverage` (the accounting must be on).
    coverage_path: ?[]const u8 = null,
    /// `--time`: print the VM execute-only wall time (the `vm.run` call alone) to
    /// stderr after the run. Mirrors the browser's execute-only timing readout.
    time: bool = false,
    /// `--trace-opportunities`: imply `--trace` and run the trace-opportunity
    /// detector on every recorded+optimized trace, printing waste signatures to
    /// stderr after the run (like `--dump-traces` but for optimization signals).
    opportunities: bool = false,
    /// `--trace-hotguard <N>`: override the guard-failure threshold for side-trace
    /// recording (default 50).  When a specific guard fails this many times, the
    /// next back-edge records a side trace.
    hotguard: ?u32 = null,
    /// `--trace-silent-budget <N>`: override the promoted-cycle silent-transition
    /// budget (default 4096). B-3c sweep knob; tiering heuristic, never output.
    silent_budget: ?usize = null,
    /// `--jit-no-exit-side-native` clears it: doc 56 Phase 4 — native pages
    /// take exit adapters (`Config.exit_side_native`). On by default (doc 58 B2).
    exit_side_native: bool = true,
    /// `--dump-aborts`: imply `--trace`, record every abandoned recording into the
    /// abort log (`config.record_aborts`), and print the aggregated table to stderr
    /// after the run — which loop dies on which opcode/reason, and how far it got.
    dump_aborts: bool = false,
    /// `--jit-debug`: enable the live JIT debug log (`config.debug_log`). Only
    /// prints anything in a `-Djit-debug=true` build (the call sites are compiled
    /// out otherwise); a plain build warns to stderr and continues.
    jit_debug: bool = false,
    /// `--jit-coverage` / `--jit-stats`: enable JIT execution-coverage accounting
    /// (`config.coverage`) — native-vs-tier-0 loop-iteration split, per anchor.
    /// Deliberately NOT implied by `--time`: the per-back-edge accounting is not
    /// free (a hashmap probe per interpreted iteration), so `--time` stays clean
    /// for benchmark timing and you opt into coverage explicitly.
    coverage: bool = false,
    /// `--jit-coverage`: after the run, print the ONE-LINE JIT coverage summary to
    /// stderr. Implies `--trace` + `coverage`. Subsumed by `--jit-stats` (which
    /// prints the full block), so the one-liner is skipped when `jit_stats` is set.
    jit_coverage: bool = false,
    /// `--jit-stats`: after the run, print the full JIT stats block (event counters
    /// + coverage split + per-anchor table) to stderr. Implies `--trace` +
    /// `coverage`; combine with `--jit-native` to measure the native path.
    jit_stats: bool = false,
};

pub fn main(init: std.process.Init) u8 {
    // A program's stdout is buffered (fully, unless it is a terminal; doc 65
    // §6), so whatever is still in the buffer goes out here, on every return
    // path. Declared first, so it runs after every other deferred report.
    defer mahina.io.flush();
    // `--mem-stats` swaps `gpa` for a TrackingAllocator wrapper over the process
    // allocator (Rule Z-4: account at the boundary). The tracker must be declared
    // here — stable address for the vtable handle, and alive past `runSource` so
    // the deferred report sees final counts.
    var mem_tracker = mahina.mem.TrackingAllocator.init(init.gpa);
    var mem_stats = false;
    defer if (mem_stats) {
        const s = mem_tracker.stats;
        mahina.io.eprint(
            "mahina: mem stats\n" ++
                "  peak bytes:        {d}\n" ++
                "  total bytes:       {d}\n" ++
                "  alloc calls:       {d}\n" ++
                "  free calls:        {d}\n" ++
                "  leaked bytes:      {d} ({d} allocations)\n",
            .{ s.peak_bytes, s.total_bytes, s.alloc_count, s.free_count, s.live_bytes, s.live_allocations },
        );
    };

    // Windows and WASI must decode the command line into memory; the process
    // arena owns it (the args live as long as `main`).
    var it = init.minimal.args.iterateAllocator(init.arena.allocator()) catch {
        mahina.io.eprint("mahina: out of memory reading the command line\n", .{});
        return 1;
    };
    defer it.deinit(); // no-op on Linux; correct on Windows/WASI
    _ = it.skip(); // skip argv[0]

    // `mahina viz …` is a subcommand. Its first argument is read ahead, so the
    // flag loop below starts from `pending` before pulling from `it`.
    var pending = it.next();
    if (pending) |arg| if (std.mem.eql(u8, arg, "viz")) return vizMain(init, &it);

    // Leading options precede the script / `-e`; the first non-option argument
    // ends flag parsing.
    var topts: TraceOpts = .{};
    const first = while (pending orelse it.next()) |arg| : (pending = null) {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            mahina.io.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return 0;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            topts.enabled = true;
        } else if (std.mem.eql(u8, arg, "--trace-record-only")) {
            topts.enabled = true;
            topts.execute = false;
        } else if (std.mem.eql(u8, arg, "--trace-no-opt")) {
            topts.enabled = true;
            topts.optimize = false;
        } else if (std.mem.eql(u8, arg, "--jit-native")) {
            topts.enabled = true;
            topts.execute = true;
            topts.native_codegen = true;
        } else if (std.mem.eql(u8, arg, "--dump-native")) {
            topts.enabled = true;
            topts.execute = true;
            topts.native_codegen = true;
            topts.dump_native = true;
        } else if (std.mem.eql(u8, arg, "--dump-traces")) {
            topts.enabled = true;
            topts.dump = true;
        } else if (std.mem.eql(u8, arg, "--trace-opportunities")) {
            topts.enabled = true;
            topts.opportunities = true;
        } else if (std.mem.eql(u8, arg, "--dump-aborts")) {
            topts.enabled = true;
            topts.dump_aborts = true;
        } else if (std.mem.eql(u8, arg, "--jit-debug")) {
            topts.jit_debug = true;
            if (!mahina.jitdbg.enabled) {
                mahina.io.eprint("mahina: warning: --jit-debug has no effect in this binary; rebuild with `zig build -Djit-debug=true`\n", .{});
            }
        } else if (std.mem.eql(u8, arg, "--jit-coverage")) {
            topts.enabled = true;
            topts.execute = true;
            topts.coverage = true;
            topts.jit_coverage = true;
        } else if (std.mem.eql(u8, arg, "--jit-no-exit-side-native")) {
            topts.exit_side_native = false;
        } else if (std.mem.eql(u8, arg, "--jit-stats")) {
            topts.enabled = true;
            topts.execute = true;
            topts.coverage = true;
            topts.jit_stats = true;
        } else if (std.mem.eql(u8, arg, "--trace-hotguard")) {
            topts.enabled = true;
            const val = it.next() orelse {
                mahina.io.eprint("mahina: error: --trace-hotguard requires a numeric argument\n", .{});
                return 2;
            };
            topts.hotguard = std.fmt.parseUnsigned(u32, val, 10) catch {
                mahina.io.eprint("mahina: error: --trace-hotguard requires a numeric argument, got '{s}'\n", .{val});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--trace-silent-budget")) {
            topts.enabled = true;
            const val = it.next() orelse {
                mahina.io.eprint("mahina: error: --trace-silent-budget requires a numeric argument\n", .{});
                return 2;
            };
            topts.silent_budget = std.fmt.parseUnsigned(usize, val, 10) catch {
                mahina.io.eprint("mahina: error: --trace-silent-budget requires a numeric argument, got '{s}'\n", .{val});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--emit-traces")) {
            topts.enabled = true;
            topts.emit_path = it.next() orelse {
                mahina.io.eprint("mahina: error: --emit-traces requires a <file> argument\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--emit-keyframe")) {
            topts.keyframe_path = it.next() orelse {
                mahina.io.eprint("mahina: error: --emit-keyframe requires a <file> argument\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--emit-effects")) {
            topts.effects_path = it.next() orelse {
                mahina.io.eprint("mahina: error: --emit-effects requires a <file> argument\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--emit-coverage")) {
            topts.enabled = true;
            topts.coverage = true;
            topts.coverage_path = it.next() orelse {
                mahina.io.eprint("mahina: error: --emit-coverage requires a <file> argument\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--mem-stats")) {
            mem_stats = true;
        } else if (std.mem.eql(u8, arg, "--time")) {
            topts.time = true;
        } else break arg;
    } else {
        mahina.io.eprint("{s}", .{usage});
        return 2;
    };

    // Native codegen exists for one target; elsewhere the flag would silently
    // measure tier-1a, so say so (stderr: program output stays identical).
    if (topts.native_codegen and !mahina.nativegen.is_x64_linux) {
        mahina.io.eprint("mahina: warning: --jit-native: native code is x86-64 Linux only; " ++
            "hot traces run on the tier-1a interpreter on {s}-{s}\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    }

    // Everything below allocates, so the gpa choice happens exactly here: after
    // flag parsing (which only compares argv strings), before first use.
    const gpa = if (mem_stats) mem_tracker.allocator() else init.gpa;

    if (std.mem.eql(u8, first, "-e")) {
        // argv strings are already NUL-terminated, so this is a `[:0]const u8`.
        const chunk = it.next() orelse {
            mahina.io.eprint("mahina: error: -e requires a chunk argument\n", .{});
            return 2;
        };
        // Program argv for `-e`: argv(0) = "-e", then any trailing user args.
        var prog_argv: std.ArrayList([]const u8) = .empty;
        defer prog_argv.deinit(gpa);
        prog_argv.append(gpa, "-e") catch return 1;
        while (it.next()) |a| prog_argv.append(gpa, a) catch return 1;
        return runSource(gpa, init.io, "=(command line)", chunk, topts, init.environ_map, prog_argv.items);
    }

    // Otherwise the first non-option argument is a script path.
    const source = mahina.io.readFileZ(gpa, init.io, first) catch |err| {
        mahina.io.eprint("mahina: error: cannot read '{s}': {s}\n", .{ first, @errorName(err) });
        return 1;
    };
    defer gpa.free(source);
    // Program argv for a script: argv(0) = the script path, then trailing user args.
    var prog_argv: std.ArrayList([]const u8) = .empty;
    defer prog_argv.deinit(gpa);
    prog_argv.append(gpa, first) catch return 1;
    while (it.next()) |a| prog_argv.append(gpa, a) catch return 1;
    return runSource(gpa, init.io, first, source, topts, init.environ_map, prog_argv.items);
}

/// `mahina --version`: what this binary is and what it can do here.
fn printVersion() void {
    mahina.io.print(
        \\mahina {s}
        \\commit: {s}
        \\zig: {s}
        \\target: {s}-{s} (native JIT: {s})
        \\web UI (`mahina viz`): {s}
        \\
    , .{
        mahina.version,
        mahina.version_commit orelse "unknown (built without -Dversion-commit)",
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        if (mahina.nativegen.is_x64_linux) "yes" else "no, x86-64 Linux only",
        if (viz_assets.embedded) "built in" else "not built in",
    });
}

const viz_usage =
    \\usage: mahina viz [options] [script] [trace.mahinatrace]
    \\
    \\Serve the trace visualiser on http://127.0.0.1 and open it in a browser.
    \\The visualiser runs programs in-browser (wasm); its differential validator
    \\also runs them through this binary. With a script, the editor opens on it
    \\and on the other source files (.mah, .mahina, .lua) of its directory tree,
    \\which it can require; they are re-read on every page load. With a
    \\.mahinatrace (from `mahina --emit-traces <file> <script>`), the page opens
    \\on it, also re-read on every page load.
    \\
    \\options:
    \\  --port <N>   listen on port N (default: any free port)
    \\  --no-open    print the URL but don't open a browser
    \\  -h, --help   show this help
    \\
;

/// `mahina viz`: parse its options and serve until interrupted.
fn vizMain(init: std.process.Init, it: *std.process.Args.Iterator) u8 {
    var opts: viz_server.Options = .{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            mahina.io.print("{s}", .{viz_usage});
            return 0;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const text = it.next() orelse {
                mahina.io.eprint("mahina viz: error: --port requires a number\n", .{});
                return 2;
            };
            opts.port = std.fmt.parseInt(u16, text, 10) catch {
                mahina.io.eprint("mahina viz: error: bad port '{s}'\n", .{text});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            opts.open_browser = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            mahina.io.eprint("mahina viz: error: unknown option '{s}'\n{s}", .{ arg, viz_usage });
            return 2;
        } else if (std.mem.endsWith(u8, arg, ".mahinatrace")) {
            if (opts.trace_path != null) {
                mahina.io.eprint("mahina viz: error: one trace file at most\n{s}", .{viz_usage});
                return 2;
            }
            opts.trace_path = arg;
        } else if (opts.program_path != null) {
            mahina.io.eprint("mahina viz: error: one script at most\n{s}", .{viz_usage});
            return 2;
        } else {
            opts.program_path = arg;
        }
    }
    if (!viz_assets.embedded) {
        mahina.io.eprint("mahina viz: error: this build has no web UI; build with `just cli` " ++
            "(or `zig build -Dviz-dist=<built viz/dist>`)\n", .{});
        return 1;
    }
    viz_server.serve(init.gpa, init.io, &viz_assets.files, init.environ_map, opts) catch |err| {
        mahina.io.eprint("mahina viz: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Parse, compile, and run one source chunk. Returns the process exit code.
/// `name` labels the chunk in diagnostics (a file path or a synthetic name).
/// `topts` controls the tracing-JIT recorder (off by default).
fn runSource(gpa: std.mem.Allocator, io: mahina.io.Io, name: []const u8, source: [:0]const u8, topts: TraceOpts, env_map: *std.process.Environ.Map, argv: []const []const u8) u8 {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    // --- parse ---
    var tree = mahina.parser.parse(gpa, source, &diags) catch |err| {
        reportDiagnostics(name, &diags);
        mahina.io.eprint("mahina: error: parse failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        reportDiagnostics(name, &diags);
        return 1;
    }

    // The VM owns the heap that string constants are interned into, so it must
    // outlive the chunk. Bring it up before compiling.
    var vm = mahina.interp.Vm.init(gpa) catch |err| {
        mahina.io.eprint("mahina: error: vm init failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer vm.deinit();
    // Opt into the tracing JIT before running. Off by default ⇒ identical to the
    // pre-Phase-5 path; `--trace` ⇒ record *and* execute hot loops via tier-1a;
    // `--trace-record-only` ⇒ record but tier-0 executes everything.
    vm.trace.config.enabled = topts.enabled;
    vm.trace.config.execute = topts.execute;
    vm.trace.config.optimize = topts.optimize;
    vm.trace.config.native_codegen = topts.native_codegen;
    vm.trace.config.record_aborts = topts.dump_aborts;
    vm.trace.config.debug_log = topts.jit_debug;
    vm.trace.config.coverage = topts.coverage;
    if (topts.hotguard) |v| vm.trace.config.hotguard = v;
    if (topts.silent_budget) |v| vm.trace.config.silent_budget = v;
    vm.trace.config.exit_side_native = topts.exit_side_native;
    // Inject the native clock. The interpreter holds no platform clock of its own
    // (so the VM core stays portable, incl. wasm); the host that builds the VM —
    // here, the CLI — supplies one. This is the single place the OS clock syscall
    // lives now. `clock()` is `ClockUnavailable` without it.
    vm.clock_source = .{ .ctx = &clock_ctx, .nowNs = &nativeClockNs };
    // Inject the native seed source for `random()`. The VM owns the PRNG; the host
    // supplies only the one nondeterministic seed (OS entropy here). `random()` is
    // `RandomUnavailable` without it.
    vm.random_seed_source = .{ .ctx = &rng_ctx, .seed = &nativeRandomSeed };
    // Inject the native env/args window for `getenv`/`argc`/`argv`. `env_ctx` is a
    // stack local that outlives `vm.run` below; the env is read from the OS, argv
    // is the program's command line. `getenv`/`argv` are `EnvUnavailable` without it.
    var env_ctx = EnvCtx{ .env = env_map, .argv = argv };
    vm.host_env = .{ .ctx = &env_ctx, .getenv = &hostGetenv, .argCount = &hostArgCount, .arg = &hostArg };
    // Inject the native filesystem read seam for `loadfile`/`dofile`. `fs_ctx` is a
    // stack local that outlives `vm.run` below; it owns the most-recent file buffer
    // (freed at scope exit). `loadfile`/`dofile` are `FsUnavailable` without it.
    var fs_ctx = FsCtx{ .gpa = gpa, .io = io };
    defer fs_ctx.deinit();
    vm.fs_source = .{ .ctx = &fs_ctx, .read = &FsCtx.read };
    // Fill the global `arg` table from the program's command line (load-time host
    // input; keeps the exec core deterministic). `arg[0]` = script path.
    vm.populateArgs(argv) catch |err| {
        // A non-UTF-8 arg raises a located `LuaError` whose message lives in
        // `pending_error` (load-time, so `describeFault` sees no frame and would
        // only print the error name) — render the value directly.
        if (vm.pending_error) |ev| {
            var fault_arena = std.heap.ArenaAllocator.init(gpa);
            defer fault_arena.deinit();
            const msg = mahina.interp.Vm.renderErrorValue(ev, fault_arena.allocator()) catch @errorName(err);
            mahina.io.eprint("mahina: error: {s}\n", .{msg});
        } else {
            mahina.io.eprint("mahina: error: populating arg table failed: {s}\n", .{@errorName(err)});
        }
        return 1;
    };
    // `--emit-effects` records the nondeterministic-input log during the run.
    if (topts.effects_path != null) vm.effect_mode = .record;

    // --- compile --- (pass the builtin globals so the unknown-global lint
    // doesn't flag `print`/`clock`).
    var chunk = mahina.compiler.compileWithOptions(gpa, vm.heap, source, tree.root, &diags, .{
        .known_globals = &mahina.interp.builtin_global_names,
    }) catch |err| {
        reportDiagnostics(name, &diags);
        mahina.io.eprint("mahina: error: compile failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer chunk.deinit();
    if (diags.hasErrors()) {
        reportDiagnostics(name, &diags);
        return 1;
    }
    // Surface warnings (e.g. undefined globals) but keep running — advice, not a
    // failure. The chunk is alive (deferred deinit), so arena-owned messages are
    // valid here.
    if (diags.count() > 0) reportDiagnostics(name, &diags);

    // --- run --- (a program's `print` output reaches stdout via Vm.out == null)
    // Bracket the VM execution alone with the monotonic clock for `--time`;
    // parse/compile above and emit below are excluded.
    const exec_t0 = nativeClockNs(&clock_ctx);
    const run_outcome = vm.run(chunk.proto);
    const exec_ns: u64 = @intCast(nativeClockNs(&clock_ctx) - exec_t0);
    // Pair the wall-clock run duration with `run_cycles` (stamped inside `run`) so a
    // coverage consumer can recover the TSC frequency and render the per-class cycle
    // counts as real time. The two brackets differ only by a few call instructions —
    // negligible against a whole-program run. Harmless when coverage is off (the field
    // is only emitted with the artifact, which needs `--emit-coverage`).
    vm.trace.run_nanos = exec_ns;
    _ = run_outcome catch |err| {
        // Located, Lua-style message + call chain from the un-popped frame stack.
        var fault_arena = std.heap.ArenaAllocator.init(gpa);
        defer fault_arena.deinit();
        if (vm.describeFault(err, fault_arena.allocator())) |fault| {
            // A self-located message (a raised Lua value) already carries its
            // `chunk:line:` prefix — print it verbatim, Lua-style. The type-name
            // faults are not self-located and get the " at chunk:line" suffix.
            // The suffix names the chunk the faulting instruction is in: the
            // script for its own code, the loaded file's path for a fault inside
            // a `require`d / `dofile`d / `load`ed chunk.
            const fault_chunk = if (vm.loadedChunkIndexOf(fault.proto_id)) |i|
                vm.loaded_chunks.items[i].chunk.proto.name
            else
                name;
            if (fault.self_located)
                mahina.io.eprint("mahina: runtime error: {s}\n", .{fault.message})
            else
                mahina.io.eprint("mahina: runtime error: {s} at {s}:{d}\n", .{ fault.message, fault_chunk, fault.line });
            // A traceback only adds signal when control crossed a call boundary.
            if (fault.frames.len > 1) {
                mahina.io.eprint("stack traceback:\n", .{});
                for (fault.frames) |f| {
                    mahina.io.eprint("    {s}:{d}\n", .{ f.name, f.line });
                }
            }
        } else |_| {
            mahina.io.eprint("mahina: runtime error: {s}\n", .{@errorName(err)});
        }
        return 1;
    };

    // --- execute-only timing (--time) --- to stderr, never interleaving stdout.
    // Deliberately free of coverage accounting so the number is a clean measure of
    // the run (add --jit-coverage explicitly to also get the split).
    if (topts.time) {
        mahina.io.eprint("mahina: executed in {d} ns ({d:.3} ms)\n", .{ exec_ns, @as(f64, @floatFromInt(exec_ns)) / 1e6 });
    }

    // --- JIT coverage output --- to stderr. `--jit-stats` prints the full block
    // (event counters + iteration split + per-anchor table); `--jit-coverage`
    // prints just the one-line summary, unless --jit-stats already covers it. The
    // chunk is still alive, so every anchor's `proto.name` is valid.
    if (topts.jit_stats) {
        const w = mahina.io.stderrWriter();
        mahina.trace.writeJitStats(w, &vm.trace, true) catch {};
        w.flush() catch {};
    } else if (topts.jit_coverage) {
        const w = mahina.io.stderrWriter();
        mahina.trace.writeJitStats(w, &vm.trace, false) catch {};
        w.flush() catch {};
    }

    // --- dump recorded traces (--dump-traces) --- to stderr, so they never
    // interleave with the program's stdout. The chunk is still alive here (its
    // `deinit` is deferred), so each trace's `anchor.proto` is valid.
    if (topts.dump) dumpTraces(&vm);

    // --- dump trace-opportunity report (--trace-opportunities) --- to stderr.
    // Each cached trace is analysed for waste signatures; findings are printed
    // inline after the trace IR if --dump-traces is also active, or standalone.
    if (topts.opportunities) dumpOpportunities(&vm);

    // --- dump compiled machine code (--dump-native) --- to stderr. Resolves each
    // trace's native compilation (forcing any not yet attempted), then hexdumps the
    // emitted bytes or reports the `unsupported` verdict. The chunk is still alive,
    // so each trace (and its anchor proto) is valid.
    if (topts.dump_native) dumpNative(&vm);

    // --- dump the abort log (--dump-aborts) --- to stderr. Shows every loop that
    // could not be traced, deduped by (anchor, reason, opcode) with a recurrence
    // count, so a program stuck on tier-0 reveals exactly what blocks tiering.
    if (topts.dump_aborts) dumpAborts(&vm);

    // --- emit serialized traces (--emit-traces <file>) --- the chunk is still
    // alive, so every trace's `anchor.proto` (and its `id`) is valid.
    if (topts.emit_path) |path| {
        emitTraces(gpa, io, path, &vm) catch |err| {
            mahina.io.eprint("mahina: error: --emit-traces '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }

    // --- emit a keyframe snapshot (--emit-keyframe <file>) --- the VM is still
    // alive, so the reachable heap graph (and the live string bytes it borrows)
    // is valid. Independent of tracing.
    if (topts.keyframe_path) |path| {
        emitKeyframe(gpa, io, path, &vm) catch |err| {
            mahina.io.eprint("mahina: error: --emit-keyframe '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }

    // --- emit the recorded effect log (--emit-effects <file>) --- the VM ran in
    // `record` mode, so `effect_log` holds every nondeterministic input in order.
    if (topts.effects_path) |path| {
        emitEffects(gpa, io, path, &vm) catch |err| {
            mahina.io.eprint("mahina: error: --emit-effects '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }

    // --- emit the JIT coverage artifact (--emit-coverage <file>) --- the VM ran
    // with `config.coverage` on, so the aggregate/per-anchor accounting is live.
    if (topts.coverage_path) |path| {
        emitCoverage(gpa, io, path, &vm) catch |err| {
            mahina.io.eprint("mahina: error: --emit-coverage '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }
    return 0;
}

/// The native monotonic clock backing `clock()`, injected as `Vm.clock_source`.
/// The VM core stays platform-agnostic (it only sees the function pointer).
/// `ctx` is unused — the OS clock needs no state — so it points at a throwaway byte.
var clock_ctx: u8 = 0;

fn nativeClockNs(_: *anyopaque) i64 {
    return mahina.io.monotonicNs();
}

/// The native seed source backing `random()`, injected as `Vm.random_seed_source`.
/// The VM owns the PRNG; the host supplies only the single nondeterministic seed —
/// here, 8 bytes of OS entropy. `ctx` is unused (no state), so it points at a
/// throwaway byte, mirroring `clock_ctx`.
var rng_ctx: u8 = 0;

fn nativeRandomSeed(_: *anyopaque) u64 {
    var bytes: [8]u8 = undefined;
    mahina.io.hostEntropy(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

/// Backing state for the native `getenv`/`argc`/`argv` effects: the process
/// environment map and the program's command-line argv (both owned by the
/// process `Init`, valid for the whole run). Injected as `Vm.host_env`.
const EnvCtx = struct {
    env: *std.process.Environ.Map,
    argv: []const []const u8,
};

fn hostGetenv(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const self: *EnvCtx = @ptrCast(@alignCast(ctx));
    return self.env.get(name);
}

fn hostArgCount(ctx: *anyopaque) i64 {
    const self: *EnvCtx = @ptrCast(@alignCast(ctx));
    return @intCast(self.argv.len);
}

fn hostArg(ctx: *anyopaque, i: i64) ?[]const u8 {
    const self: *EnvCtx = @ptrCast(@alignCast(ctx));
    if (i < 0 or i >= self.argv.len) return null;
    return self.argv[@intCast(i)];
}

/// Backing state for the native `file_read` effect (`loadfile`/`dofile`): the real
/// filesystem, read through the project's `std.Io` wrapper. Injected as
/// `Vm.fs_source`. The `FsSource` contract returns bytes valid only for the call
/// (the native interns them immediately), so we hold the most-recent read in `last`
/// and free it on the next read and at teardown (`deinit`) — a single reusable
/// owner, never two live buffers.
const FsCtx = struct {
    gpa: std.mem.Allocator,
    io: mahina.io.Io,
    last: ?[]u8 = null,

    fn read(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *FsCtx = @ptrCast(@alignCast(ctx));
        if (self.last) |b| {
            self.gpa.free(b);
            self.last = null;
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            mahina.io.Io.Limit.limited(mahina.io.max_source_bytes),
        ) catch return null; // missing/unreadable/too-large → Lua's `cannot open`
        self.last = bytes;
        return bytes;
    }

    fn deinit(self: *FsCtx) void {
        if (self.last) |b| self.gpa.free(b);
        self.last = null;
    }
};

/// Serialize a whole-VM keyframe snapshot to `path` (binschema wire format).
fn emitKeyframe(gpa: std.mem.Allocator, io: mahina.io.Io, path: []const u8, vm: *mahina.interp.Vm) !void {
    const bytes = try mahina.keyframeser.encodeSnapshot(gpa, vm);
    defer gpa.free(bytes);
    try mahina.io.writeFile(io, path, bytes);
    mahina.io.eprint("mahina: wrote keyframe snapshot, {d} bytes → {s}\n", .{ bytes.len, path });
}

/// Serialize the recorded nondeterministic-input effect log to `path` (binschema
/// wire format). Mirrors `emitKeyframe`; the VM must have run in `record` mode.
fn emitEffects(gpa: std.mem.Allocator, io: mahina.io.Io, path: []const u8, vm: *mahina.interp.Vm) !void {
    const bytes = try mahina.effectser.encodeFile(gpa, vm.effect_log.items);
    defer gpa.free(bytes);
    try mahina.io.writeFile(io, path, bytes);
    mahina.io.eprint("mahina: wrote effect log, {d} effect(s), {d} bytes → {s}\n", .{ vm.effect_log.items.len, bytes.len, path });
}

/// Serialize the JIT execution-coverage artifact to `path` (binschema wire format).
/// Mirrors `emitTraces`; the VM must have run with `config.coverage` on (implied by
/// `--emit-coverage`), else the aggregates/anchors are all zero.
fn emitCoverage(gpa: std.mem.Allocator, io: mahina.io.Io, path: []const u8, vm: *mahina.interp.Vm) !void {
    const bytes = try mahina.coverageser.encodeState(gpa, &vm.trace);
    defer gpa.free(bytes);
    try mahina.io.writeFile(io, path, bytes);
    mahina.io.eprint("mahina: wrote JIT coverage, {d} anchor(s), {d} bytes → {s}\n", .{ vm.trace.coverage.count(), bytes.len, path });
}

/// Serialize the recorded trace cache to `path` (binschema wire format).
fn emitTraces(gpa: std.mem.Allocator, io: mahina.io.Io, path: []const u8, vm: *mahina.interp.Vm) !void {
    const bytes = try vm.trace.encodeTraceFile(gpa);
    defer gpa.free(bytes);
    try mahina.io.writeFile(io, path, bytes);
    mahina.io.eprint("mahina: wrote {d} trace(s), {d} bytes → {s}\n", .{ vm.trace.registry.cache.items.len, bytes.len, path });
}

/// Disassemble every cached trace to stderr (for `--dump-traces`).
/// Dump the recording abort log (`--dump-aborts`) to stderr: one aggregated row
/// per `(anchor, reason, opcode)`, sorted by recurrence count. A program that
/// stays on tier-0 names exactly which loop blocks tiering and why.
fn dumpAborts(vm: *mahina.interp.Vm) void {
    const w = mahina.io.stderrWriter();
    const rows = vm.trace.abort_log.items;
    if (rows.len == 0) {
        w.print("mahina: no recording aborts\n", .{}) catch {};
    } else {
        w.print("mahina: {d} distinct recording-abort site(s)\n", .{rows.len}) catch {};
        mahina.trace.writeAborts(w, rows) catch {};
    }
    w.flush() catch {};
}

fn dumpTraces(vm: *mahina.interp.Vm) void {
    const w = mahina.io.stderrWriter();
    if (vm.trace.registry.cache.items.len == 0) {
        w.print("mahina: no traces recorded\n", .{}) catch {};
    } else {
        w.print("mahina: {d} trace(s) recorded\n", .{vm.trace.registry.cache.items.len}) catch {};
        for (vm.trace.registry.cache.items) |t| {
            mahina.trace.writeTrace(w, t) catch {};
        }
    }
    w.flush() catch {};
}

/// Run the trace-opportunity detector on every cached trace and print findings to
/// stderr (for `--trace-opportunities`).
fn dumpOpportunities(vm: *mahina.interp.Vm) void {
    const gpa = vm.gpa;
    const w = mahina.io.stderrWriter();
    if (vm.trace.registry.cache.items.len == 0) {
        w.print("mahina: (no traces — cannot run opportunity detector)\n", .{}) catch {};
        w.flush() catch {};
        return;
    }

    var total: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const findings = mahina.troptdiag.analyze(gpa, &t.code) catch {
            w.print("mahina: error: opportunity analysis OOM\n", .{}) catch {};
            w.flush() catch {};
            return;
        };
        defer mahina.troptdiag.deinitFindings(gpa, findings);

        w.print("trace {s}:{d}  waste opportunities:\n", .{ t.code.anchor.proto.name, t.code.anchor.pc }) catch {};
        mahina.troptdiag.writeFindings(w, &t.code, findings) catch {};
        total += findings.len;
    }
    w.print("mahina: {d} waste signature(s) across {d} trace(s)\n", .{ total, vm.trace.registry.cache.items.len }) catch {};
    w.flush() catch {};
}

/// Dump every cached trace's tier-1b native compilation to stderr (for
/// `--dump-native`). Resolves each trace's `NativeState` (compiling any not yet
/// attempted), then hexdumps the emitted machine code or reports that the trace
/// fell outside the proven int/bool subset and runs on tier-1a.
fn dumpNative(vm: *mahina.interp.Vm) void {
    const w = mahina.io.stderrWriter();
    const items = vm.trace.registry.cache.items;
    if (items.len == 0) {
        w.print("mahina: no traces recorded\n", .{}) catch {};
        w.flush() catch {};
        return;
    }
    w.print("mahina: native codegen for {d} trace(s)\n", .{items.len}) catch {};
    for (items, 0..) |t, i| {
        if (vm.trace.nativeFor(t)) |ct| {
            const code = ct.page.code;
            w.print("trace #{d}: compiled, {d} bytes of x86-64, inputs={d}/{d}\n", .{
                i, code.len, t.code.inputs.len, mahina.trace.MAX_TRACE_INPUTS,
            }) catch {};
            var off: usize = 0;
            while (off < code.len) : (off += 16) {
                w.print("  {x:0>4}: ", .{off}) catch {};
                const end = @min(off + 16, code.len);
                for (code[off..end]) |b| w.print("{x:0>2} ", .{b}) catch {};
                w.print("\n", .{}) catch {};
            }
        } else {
            w.print("trace #{d}: unsupported — runs on the tier-1a interpreter, inputs={d}/{d}\n", .{
                i, t.code.inputs.len, mahina.trace.MAX_TRACE_INPUTS,
            }) catch {};
        }
    }
    w.flush() catch {};
}

/// Print every recorded diagnostic to stderr, one per line, with its 1-based
/// source line. v1 messages are static strings (see diag.zig).
fn reportDiagnostics(name: []const u8, diags: *const Diagnostics) void {
    for (diags.list.items) |d| {
        mahina.io.eprint("{s}:{d}: {s}: {s}\n", .{
            name,
            d.line,
            @tagName(d.severity),
            d.message,
        });
    }
}

test "cli smoke" {
    // Keep the CLI module's test target non-empty so `zig build test` covers it.
    // The end-to-end run path is covered by the interp/compiler test suites,
    // which exercise parse → compile → run against an in-memory output sink.
    try std.testing.expectEqual(@as(u64, 5), mahina.dispatch.run(5));
}

test {
    _ = viz_server;
}
