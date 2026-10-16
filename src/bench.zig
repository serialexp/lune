//! Phase 6b / Phase 8 benchmark harness — `zig build bench` (ReleaseFast).
//!
//! Quantifies the trace optimizer's effect *and* the tier-1b native-codegen win on
//! a handful of representative hot loops. For each program it reports two things:
//!
//!   * **Static instruction counts** — how many IR instructions the cached trace
//!     presents to the tier-1a executor with the optimizer off vs on. This is the
//!     deterministic signal: a smaller body is fewer dispatches per iteration. (The
//!     unit tests in `tropt.zig`/`interp.zig` are the *gate*; this just shows it on
//!     realistic loops.)
//!   * **Wall-time per mode** — tier-0, record+execute (no opt), record+execute
//!     (opt), as the best of N runs of `Vm.run` (parse/compile excluded from the
//!     timer). Wall-time is **informational only**: it is noisy, sensitive to the
//!     trip count and the machine, and the optimizer's per-iteration win is small
//!     until typed fast paths land (Phase 6c+). Treat the instruction counts as
//!     the real result and the timings as a sanity check that opt is never slower.
//!
//! Not a test target (no asserts): it prints a table and exits 0. Determinism of
//! the optimizer is proven by the test suite, not here.

const std = @import("std");
const mahina = @import("mahina");

const Vm = mahina.interp.Vm;

const Bench = struct { name: []const u8, source: [:0]const u8 };

// Big trip counts so `Vm.run` dwarfs the per-rep parse/compile (which the timer
// already excludes anyway) and the traced body — not the warm-up — dominates.
const benches = [_]Bench{
    // A plain reduction: nothing for the optimizer to remove (a useful baseline —
    // confirms opt never *adds* instructions or time).
    .{
        .name = "numeric-for sum",
        .source =
        \\local acc = 0
        \\for i = 1, 4000000 do acc = acc + i end
        \\print(acc)
        ,
    },
    // A repeated subexpression `(i + 7)` the recorder sees twice — CSE collapses it
    // to one add, so the optimized body is shorter.
    .{
        .name = "CSE-able body",
        .source =
        \\local acc = 0
        \\for i = 1, 4000000 do acc = acc + (i + 7) * (i + 7) end
        \\print(acc)
        ,
    },
    // Several loop-carried variables (DCE must root every exit_store) plus a shared
    // subexpression — exercises liveness + CSE together.
    .{
        .name = "multi-var + shared subexpr",
        .source =
        \\local a = 0
        \\local b = 0
        \\for i = 1, 4000000 do
        \\  a = a + (i - 1) * (i - 1)
        \\  b = b + (i - 1)
        \\end
        \\print(a)
        \\print(b)
        ,
    },
};

const reps = 5;

/// Time `Vm.run` (parse/compile excluded) for one trace configuration; returns
/// the best (minimum) nanoseconds over `reps` fresh VMs.
fn timeRun(gpa: std.mem.Allocator, io: std.Io, source: [:0]const u8, enabled: bool, execute: bool, optimize: bool, native: bool) !u64 {
    var best: u64 = std.math.maxInt(u64);
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        var diags = mahina.diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try mahina.parser.parse(gpa, source, &diags);
        defer tree.deinit();

        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = enabled;
        vm.trace.config.execute = execute;
        vm.trace.config.optimize = optimize;
        vm.trace.config.native_codegen = native;
        var sink_buf: [64]u8 = undefined;
        var sink = mahina.io.Writer.fixed(&sink_buf);
        vm.out = &sink;

        var chunk = try mahina.compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        _ = try vm.run(chunk.proto);
        const end = std.Io.Timestamp.now(io, .awake);
        const ns: u64 = @intCast(@max(@as(i96, 0), end.nanoseconds - start.nanoseconds));
        if (ns < best) best = ns;
    }
    return best;
}

/// Instruction count of the first cached trace after one record+execute run with
/// the optimizer in the requested state (0 if no trace was recorded).
fn traceInstrCount(gpa: std.mem.Allocator, source: [:0]const u8, optimize: bool) !usize {
    var diags = mahina.diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina.parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = optimize;
    var sink_buf: [64]u8 = undefined;
    var sink = mahina.io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina.compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    if (vm.trace.registry.cache.items.len == 0) return 0;
    return vm.trace.registry.cache.items[0].code.instrs.len;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    mahina.io.print(
        \\mahina trace-optimizer benchmark (best of {d} runs; Vm.run only)
        \\
        \\{s: <30} {s: >8} {s: >8} {s: >10} {s: >10} {s: >10} {s: >10}
        \\
    , .{ reps, "program", "ir(raw)", "ir(opt)", "tier0(ms)", "1a-opt(ms)", "1b-nat(ms)", "1a/1b" });

    for (benches) |bch| {
        const raw = traceInstrCount(gpa, bch.source, false) catch |e| return fail(e);
        const opt = traceInstrCount(gpa, bch.source, true) catch |e| return fail(e);
        const t0 = timeRun(gpa, io, bch.source, false, false, false, false) catch |e| return fail(e);
        const t1a = timeRun(gpa, io, bch.source, true, true, true, false) catch |e| return fail(e);
        const t1b = timeRun(gpa, io, bch.source, true, true, true, true) catch |e| return fail(e);
        // Native vs tier-1a speedup (∞-guarded; tier-1b that fell back to 1a ≈ 1.0×).
        const speedup: f64 = if (t1b == 0) 0 else @as(f64, @floatFromInt(t1a)) / @as(f64, @floatFromInt(t1b));

        mahina.io.print("{s: <30} {d: >8} {d: >8} {d: >10.3} {d: >10.3} {d: >10.3} {d: >9.2}x\n", .{
            bch.name, raw, opt, ms(t0), ms(t1a), ms(t1b), speedup,
        });
    }

    mahina.io.print(
        \\
        \\ir(raw)/ir(opt): IR instructions per traced loop body before/after the
        \\optimizer (lower = fewer dispatches/iteration). 1a-opt = tier-1a executor
        \\(optimized IR); 1b-nat = tier-1b native machine code where the trace is in
        \\the proven int/bool subset (else it silently falls back to 1a, so 1a/1b ≈ 1).
        \\
    , .{});
    return 0;
}

fn fail(e: anyerror) u8 {
    mahina.io.eprint("bench: error: {s}\n", .{@errorName(e)});
    return 1;
}
