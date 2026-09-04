//! Shared test harness for `interp.zig`.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const FsSource = interp.FsSource;
const Vm = interp.Vm;

/// Run `source` (tier-0, no GC stress) and return the captured output bytes in
/// `sink` for assertion.
pub fn runOut(source: [:0]const u8, sink: *io.Writer) !void {
    try runCaptured(testing.allocator, source, sink, false, .off);
}
/// How the trace machinery participates in a `runCaptured` pass:
///  * `off`            — Phase-0 behaviour: no counting, recording, or execution.
///  * `record_only`         — Phase-5a: record hot loops but tier-0 executes all.
///  * `record_execute_noopt`— Phase-6a: run cached *unoptimized* traces.
///  * `record_execute`      — Phase-6b: run cached traces through the optimizer.
///  * `record_execute_native`— Phase-8: run cached traces as native machine code
///    where they fall in the proven-int/bool subset (silent tier-1a fallback else).
pub const TraceMode = enum { off, record_only, record_execute_noopt, record_execute, record_execute_native };

/// Run `source` to completion, capturing everything `print` emits into `sink`.
/// With `stress`, the collector runs at *every* safepoint — the GC torture test.
/// `mode` selects how the tracing JIT participates (with a low hotness threshold
/// so even short test loops go hot) — used to assert the JIT stays transparent:
/// recording, and now *executing* traces, must not change a program's output.
pub fn runCaptured(gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer, stress: bool, mode: TraceMode) !void {
    return runCapturedTuned(gpa, source, sink, stress, mode, .{});
}

/// Knobs for a `runCaptured` pass that needs more than the default wiring.
/// `inspect` runs against the live VM after the program completes and before it
/// is destroyed — the only way for a matrix leg to assert on transient JIT state
/// (region discovery, window flushes) that does not survive `deinit`.
pub const CapturedOpts = struct {
    hotguard: ?u32 = null,
    coverage: bool = false,
    /// Per-VM jitdbg receipts (`src/jitdbg.zig`): only observable in a
    /// `-Djit-debug=true` build, comptime-inert otherwise. The sanctioned way
    /// to watch dispatcher/link events for a single harness leg without
    /// touching the CLI's global flag.
    debug_log: bool = false,
    inspect: ?*const fn (*Vm, TraceMode) anyerror!void = null,
};

pub fn runCapturedTuned(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    sink: *io.Writer,
    stress: bool,
    mode: TraceMode,
    opts: CapturedOpts,
) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = sink;
    vm.source = source; // back located error messages (error level prefix, faults)
    vm.heap.gc_stress = stress;
    vm.trace.config.enabled = mode != .off;
    vm.trace.config.execute = mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
    vm.trace.config.optimize = mode == .record_execute or mode == .record_execute_native;
    vm.trace.config.native_codegen = mode == .record_execute_native;
    vm.trace.config.hotloop = 4; // record short test loops
    vm.trace.config.coverage = opts.coverage;
    vm.trace.config.debug_log = opts.debug_log;
    if (opts.hotguard) |hg| vm.trace.config.hotguard = hg;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    if (opts.inspect) |inspect| try inspect(&vm, mode);
}

/// Run `source` across the full matrix of GC discipline × trace mode and assert
/// it prints exactly `expected` every time. Three invariants ride on this:
///  * **GC**: the stress pass frees aggressively — a wrongly-collected live
///    object diverges or faults.
///  * **Recording transparency**: the recorder must not perturb tier-0.
///  * **Execution transparency (Phase 6)**: a trace executed by the tier-1a
///    IR-interpreter must produce byte-identical output to tier-0 — a wrong arith
///    mapping, a bad guard, a deopt mistake, or an exit-store error all diverge here.
pub fn expectProgram(source: [:0]const u8, expected: []const u8) !void {
    return expectProgramTuned(source, expected, .{});
}

/// `expectProgram` with harness knobs — same ten legs, same output oracle, plus
/// whatever per-leg configuration and post-run assertions `opts` carries.
pub fn expectProgramTuned(source: [:0]const u8, expected: []const u8, opts: CapturedOpts) !void {
    inline for (.{ false, true }) |stress| {
        inline for (.{ .off, .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            var buf: [256]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            try runCapturedTuned(testing.allocator, source, &sink, stress, mode, opts);
            try testing.expectEqualStrings(expected, sink.buffered());
        }
    }
}
/// Compile + run `source` on an already-configured `vm` (out sink, effect mode,
/// and any injected sources set by the caller). Kept separate from `effectRun` so
/// env tests can inspect `vm.effect_log` (whose string results live in `vm.heap`)
/// while the VM is still alive — `effectRun` dupes the log across `vm.deinit`,
/// which would dangle a heap-string result.
pub fn compileRun(gpa: std.mem.Allocator, vm: *Vm, source: [:0]const u8) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
}
/// A deterministic in-memory filesystem for the `file_read` effect: a fixed map of
/// path → content. Any unknown path reads as `null` (couldn't open). Injected as a
/// `FsSource` so tests never touch the real disk.
pub const FakeFs = struct {
    entries: []const struct { path: []const u8, content: []const u8 },
    pub fn readFn(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| if (std.mem.eql(u8, e.path, path)) return e.content;
        return null;
    }
    pub fn source(self: *FakeFs) FsSource {
        return .{ .ctx = self, .read = &FakeFs.readFn };
    }
};
/// Like `runForTrace` but with tier-1a execution ON, capturing `print` output
/// into `sink`. Leaves `vm` inspectable (cache / penalty / blacklist / back-edge
/// counters). The caller must `deinit` the returned chunk only *after* inspecting
/// traces (an anchor points into the chunk arena — see `runForTrace`).
pub fn runExecForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.out = sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

/// Assert `source` prints byte-identically in tier-0 and in record+execute — the
/// equivalence check for deopt-heavy programs whose output (e.g. a float) is
/// tedious to spell but must match tier-0 regardless of how the trace side-exits.
pub fn expectTier0Equiv(source: [:0]const u8) !void {
    var buf0: [256]u8 = undefined;
    var s0 = io.Writer.fixed(&buf0);
    try runCaptured(testing.allocator, source, &s0, false, .off);
    var buf1: [256]u8 = undefined;
    var s1 = io.Writer.fixed(&buf1);
    try runCaptured(testing.allocator, source, &s1, false, .record_execute);
    try testing.expectEqualStrings(s0.buffered(), s1.buffered());
}
/// `runExecForTrace` with native codegen on: a hot trace in the proven-int/bool
/// subset runs as machine code; anything else silently falls back to tier-1a.
pub fn runNativeForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.out = sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}
