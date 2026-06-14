//! lune CLI — run a lune program through the tier-0 interpreter.
//!
//! Usage:
//!   lune [options] <script.lua>   run a script file
//!   lune [options] -e <chunk>     run a chunk given inline on the command line
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
const lune = @import("lune");

const Diagnostics = lune.diag.Diagnostics;

const usage =
    \\lune — a Lua-shaped language (tier-0 interpreter)
    \\
    \\usage:
    \\  lune [options] <script.lua>   run a script file
    \\  lune [options] -e <chunk>     run a chunk given inline
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
    \\  --dump-traces        imply --trace and print every recorded trace's IR to
    \\                       stderr after the run.
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
    /// `--emit-traces <file>`: serialize the trace cache here after the run.
    emit_path: ?[]const u8 = null,
    /// `--emit-keyframe <file>`: serialize a whole-VM keyframe snapshot here after
    /// the run. Independent of tracing (a heap snapshot, not a trace artifact).
    keyframe_path: ?[]const u8 = null,
    /// `--emit-effects <file>`: record the nondeterministic-input effect log and
    /// serialize it here after the run (puts the VM in effect `record` mode).
    effects_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;

    var it = init.minimal.args.iterate();
    defer it.deinit(); // no-op on Linux; correct on Windows/WASI
    _ = it.skip(); // skip argv[0]

    // Leading options precede the script / `-e`; the first non-option argument
    // ends flag parsing.
    var topts: TraceOpts = .{};
    const first = while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            lune.io.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            topts.enabled = true;
        } else if (std.mem.eql(u8, arg, "--trace-record-only")) {
            topts.enabled = true;
            topts.execute = false;
        } else if (std.mem.eql(u8, arg, "--trace-no-opt")) {
            topts.enabled = true;
            topts.optimize = false;
        } else if (std.mem.eql(u8, arg, "--dump-traces")) {
            topts.enabled = true;
            topts.dump = true;
        } else if (std.mem.eql(u8, arg, "--emit-traces")) {
            topts.enabled = true;
            topts.emit_path = it.next() orelse {
                lune.io.eprint("lune: error: --emit-traces requires a <file> argument\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--emit-keyframe")) {
            topts.keyframe_path = it.next() orelse {
                lune.io.eprint("lune: error: --emit-keyframe requires a <file> argument\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--emit-effects")) {
            topts.effects_path = it.next() orelse {
                lune.io.eprint("lune: error: --emit-effects requires a <file> argument\n", .{});
                return 2;
            };
        } else break arg;
    } else {
        lune.io.eprint("{s}", .{usage});
        return 2;
    };

    if (std.mem.eql(u8, first, "-e")) {
        // argv strings are already NUL-terminated, so this is a `[:0]const u8`.
        const chunk = it.next() orelse {
            lune.io.eprint("lune: error: -e requires a chunk argument\n", .{});
            return 2;
        };
        return runSource(gpa, init.io, "=(command line)", chunk, topts);
    }

    // Otherwise the first non-option argument is a script path.
    const source = lune.io.readFileZ(gpa, init.io, first) catch |err| {
        lune.io.eprint("lune: error: cannot read '{s}': {s}\n", .{ first, @errorName(err) });
        return 1;
    };
    defer gpa.free(source);
    return runSource(gpa, init.io, first, source, topts);
}

/// Parse, compile, and run one source chunk. Returns the process exit code.
/// `name` labels the chunk in diagnostics (a file path or a synthetic name).
/// `topts` controls the tracing-JIT recorder (off by default).
fn runSource(gpa: std.mem.Allocator, io: lune.io.Io, name: []const u8, source: [:0]const u8, topts: TraceOpts) u8 {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    // --- parse ---
    var tree = lune.parser.parse(gpa, source, &diags) catch |err| {
        reportDiagnostics(name, &diags);
        lune.io.eprint("lune: error: parse failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        reportDiagnostics(name, &diags);
        return 1;
    }

    // The VM owns the heap that string constants are interned into, so it must
    // outlive the chunk. Bring it up before compiling.
    var vm = lune.interp.Vm.init(gpa) catch |err| {
        lune.io.eprint("lune: error: vm init failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer vm.deinit();
    // Opt into the tracing JIT before running. Off by default ⇒ identical to the
    // pre-Phase-5 path; `--trace` ⇒ record *and* execute hot loops via tier-1a;
    // `--trace-record-only` ⇒ record but tier-0 executes everything.
    vm.trace.config.enabled = topts.enabled;
    vm.trace.config.execute = topts.execute;
    vm.trace.config.optimize = topts.optimize;
    // Inject the native clock. The interpreter holds no platform clock of its own
    // (so the VM core stays portable, incl. wasm); the host that builds the VM —
    // here, the CLI — supplies one. This is the single place the OS clock syscall
    // lives now. `clock()` is `ClockUnavailable` without it.
    vm.clock_source = .{ .ctx = &clock_ctx, .nowNs = &nativeClockNs };
    // `--emit-effects` records the nondeterministic-input log during the run.
    if (topts.effects_path != null) vm.effect_mode = .record;

    // --- compile --- (pass the builtin globals so the unknown-global lint
    // doesn't flag `print`/`clock`).
    var chunk = lune.compiler.compileWithOptions(gpa, &vm.heap, source, tree.root, &diags, .{
        .known_globals = &lune.interp.builtin_global_names,
    }) catch |err| {
        reportDiagnostics(name, &diags);
        lune.io.eprint("lune: error: compile failed: {s}\n", .{@errorName(err)});
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
    _ = vm.run(chunk.proto) catch |err| {
        // Located, Lua-style message + call chain from the un-popped frame stack.
        var fault_arena = std.heap.ArenaAllocator.init(gpa);
        defer fault_arena.deinit();
        if (vm.describeFault(source, err, fault_arena.allocator())) |fault| {
            lune.io.eprint("lune: runtime error: {s} at {s}:{d}\n", .{ fault.message, name, fault.line });
            // A traceback only adds signal when control crossed a call boundary.
            if (fault.frames.len > 1) {
                lune.io.eprint("stack traceback:\n", .{});
                for (fault.frames) |f| {
                    lune.io.eprint("    {s}:{d}\n", .{ f.name, f.line });
                }
            }
        } else |_| {
            lune.io.eprint("lune: runtime error: {s}\n", .{@errorName(err)});
        }
        return 1;
    };

    // --- dump recorded traces (--dump-traces) --- to stderr, so they never
    // interleave with the program's stdout. The chunk is still alive here (its
    // `deinit` is deferred), so each trace's `anchor.proto` is valid.
    if (topts.dump) dumpTraces(&vm);

    // --- emit serialized traces (--emit-traces <file>) --- the chunk is still
    // alive, so every trace's `anchor.proto` (and its `id`) is valid.
    if (topts.emit_path) |path| {
        emitTraces(gpa, io, path, &vm) catch |err| {
            lune.io.eprint("lune: error: --emit-traces '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }

    // --- emit a keyframe snapshot (--emit-keyframe <file>) --- the VM is still
    // alive, so the reachable heap graph (and the live string bytes it borrows)
    // is valid. Independent of tracing.
    if (topts.keyframe_path) |path| {
        emitKeyframe(gpa, io, path, &vm) catch |err| {
            lune.io.eprint("lune: error: --emit-keyframe '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }

    // --- emit the recorded effect log (--emit-effects <file>) --- the VM ran in
    // `record` mode, so `effect_log` holds every nondeterministic input in order.
    if (topts.effects_path) |path| {
        emitEffects(gpa, io, path, &vm) catch |err| {
            lune.io.eprint("lune: error: --emit-effects '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
    }
    return 0;
}

/// The native monotonic clock backing `clock()`, injected as `Vm.clock_source`.
/// Linux-only, which is fine here: this is the CLI, the one place a host clock is
/// chosen. The VM core stays platform-agnostic (it only sees the function pointer).
/// `ctx` is unused — the OS clock needs no state — so it points at a throwaway byte.
var clock_ctx: u8 = 0;

fn nativeClockNs(_: *anyopaque) i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

/// Serialize a whole-VM keyframe snapshot to `path` (binschema wire format).
fn emitKeyframe(gpa: std.mem.Allocator, io: lune.io.Io, path: []const u8, vm: *lune.interp.Vm) !void {
    const bytes = try lune.keyframeser.encodeSnapshot(gpa, vm);
    defer gpa.free(bytes);
    try lune.io.writeFile(io, path, bytes);
    lune.io.eprint("lune: wrote keyframe snapshot, {d} bytes → {s}\n", .{ bytes.len, path });
}

/// Serialize the recorded nondeterministic-input effect log to `path` (binschema
/// wire format). Mirrors `emitKeyframe`; the VM must have run in `record` mode.
fn emitEffects(gpa: std.mem.Allocator, io: lune.io.Io, path: []const u8, vm: *lune.interp.Vm) !void {
    const bytes = try lune.effectser.encodeFile(gpa, vm.effect_log.items);
    defer gpa.free(bytes);
    try lune.io.writeFile(io, path, bytes);
    lune.io.eprint("lune: wrote effect log, {d} effect(s), {d} bytes → {s}\n", .{ vm.effect_log.items.len, bytes.len, path });
}

/// Serialize the recorded trace cache to `path` (binschema wire format).
fn emitTraces(gpa: std.mem.Allocator, io: lune.io.Io, path: []const u8, vm: *lune.interp.Vm) !void {
    const bytes = try lune.traceser.encodeFile(gpa, vm.trace.cache.items);
    defer gpa.free(bytes);
    try lune.io.writeFile(io, path, bytes);
    lune.io.eprint("lune: wrote {d} trace(s), {d} bytes → {s}\n", .{ vm.trace.cache.items.len, bytes.len, path });
}

/// Disassemble every cached trace to stderr (for `--dump-traces`).
fn dumpTraces(vm: *lune.interp.Vm) void {
    const w = lune.io.stderrWriter();
    if (vm.trace.cache.items.len == 0) {
        w.print("lune: no traces recorded\n", .{}) catch {};
    } else {
        w.print("lune: {d} trace(s) recorded\n", .{vm.trace.cache.items.len}) catch {};
        for (vm.trace.cache.items) |t| {
            lune.trace.writeTrace(w, t) catch {};
        }
    }
    w.flush() catch {};
}

/// Print every recorded diagnostic to stderr, one per line, with its 1-based
/// source line. v1 messages are static strings (see diag.zig).
fn reportDiagnostics(name: []const u8, diags: *const Diagnostics) void {
    for (diags.list.items) |d| {
        lune.io.eprint("{s}:{d}: {s}: {s}\n", .{
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
    try std.testing.expectEqual(@as(u64, 5), lune.dispatch.run(5));
}
