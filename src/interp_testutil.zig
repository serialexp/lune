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

const seam = @import("system.zig");
const tzif = @import("tzif.zig");
const HostSystem = interp.HostSystem;
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
    /// Override `Config.hotexit` (taken exits before a side trace is
    /// wanted); null keeps the default.
    hotexit: ?u8 = null,
    /// The loop-recording threshold. The harness default (4) records short
    /// test loops; pass `trace.Config`'s own default to reproduce the CLI's
    /// tiering order (arms land at different moments, which exercises
    /// different ledger shapes).
    hotloop: u32 = 4,
    coverage: bool = false,
    /// Per-VM jitdbg receipts (`src/jitdbg.zig`): only observable in a
    /// `-Djit-debug=true` build, comptime-inert otherwise. The sanctioned way
    /// to watch dispatcher/link events for a single harness leg without
    /// touching the CLI's global flag.
    debug_log: bool = false,
    /// Doc 56 Phase 4: native traces take exit adapters
    /// (`Config.exit_side_native`); null keeps the config default (on), so
    /// every matrix test covers the shipped native path. Only the native leg
    /// compiles pages, so the other legs are unaffected.
    exit_side_native: ?bool = null,
    /// Populate `vm.trace.abort_log` (what `--dump-aborts` turns on), so an
    /// `inspect` callback can assert which abort reasons fired.
    record_aborts: bool = false,
    /// Doc 57 P3: override `Config.instunroll` (the instability-unroll
    /// budget); null keeps the default.
    instunroll: ?u8 = null,
    /// Override `Config.minstitch` (the fewest IR instructions a trace needs
    /// to end at a host call or loop back-edge); null keeps the default.
    minstitch: ?u32 = null,
    /// Set `Config.trace_host_calls` (doc 63).
    trace_host_calls: bool = false,
    /// Override `Config.silent_promotion_enabled` (doc 56 Phase 6's rowed
    /// vs silent comparisons); null keeps the default.
    silent_promotion: ?bool = null,
    /// Runs on each leg's configured VM before the program: install
    /// test-only natives or globals.
    setup: ?*const fn (*Vm) anyerror!void = null,
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
    try configureLeg(&vm, sink, stress, mode, opts);

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    if (opts.inspect) |inspect| try inspect(&vm, mode);
}

/// Configure `vm` as one leg of the matrix: its output, GC discipline and
/// trace mode, then `opts`' knobs and setup.
fn configureLeg(vm: *Vm, sink: *io.Writer, stress: bool, mode: TraceMode, opts: CapturedOpts) !void {
    vm.out = sink;
    vm.heap.setGcStress(stress);
    vm.trace.config.enabled = mode != .off;
    vm.trace.config.execute = mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
    vm.trace.config.optimize = mode == .record_execute or mode == .record_execute_native;
    vm.trace.config.native_codegen = mode == .record_execute_native;
    vm.trace.config.hotloop = opts.hotloop;
    vm.trace.config.coverage = opts.coverage;
    vm.trace.config.debug_log = opts.debug_log;
    if (opts.exit_side_native) |on| vm.trace.config.exit_side_native = on;
    vm.trace.config.record_aborts = opts.record_aborts;
    if (opts.hotguard) |hg| vm.trace.config.hotguard = hg;
    if (opts.hotexit) |he| vm.trace.config.hotexit = he;
    if (opts.instunroll) |n| vm.trace.config.instunroll = n;
    if (opts.minstitch) |n| vm.trace.config.minstitch = n;
    vm.trace.config.trace_host_calls = opts.trace_host_calls;
    if (opts.silent_promotion) |on| vm.trace.config.silent_promotion_enabled = on;
    if (opts.setup) |setup| try setup(vm);
}

/// Doc 73 §7: the task library's `pending` and `settle`, the host's half
/// of a pending operation, as globals: the library's own closures, which a
/// keyframe restore rebuilds as it rebuilds the library. Loaded after the
/// program `root`'s proto ids are taken, as a run would load it.
pub fn installTaskGlobals(vm: *Vm, root: *const bytecode.Proto) anyerror!void {
    vm.seedProtoIds(root);
    try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("pending"), try vm.taskFn(.pending));
    try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("settle"), try vm.taskFn(.settle));
}

/// `expectProgramTuned` for a program that fails: on every leg it prints
/// exactly `expected` and then raises a runtime error whose message
/// (`Vm.describeFault`) is `message`.
pub fn expectProgramFault(source: [:0]const u8, expected: []const u8, message: []const u8, opts: CapturedOpts) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const gpa = testing.allocator;
    inline for (.{ false, true }) |stress| {
        inline for (.{ .off, .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            var buf: [256]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            var diags = diag.Diagnostics.init(gpa);
            defer diags.deinit();
            var tree = try parser.parse(gpa, source, &diags);
            defer tree.deinit();
            try testing.expect(!diags.hasErrors());
            var vm = try Vm.init(gpa);
            defer vm.deinit();
            try configureLeg(&vm, &sink, stress, mode, opts);
            var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
            defer chunk.deinit();
            try testing.expect(!diags.hasErrors());
            if (vm.run(chunk.proto)) |_| return error.TestExpectedError else |err| {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const fault = try vm.describeFault(err, arena.allocator());
                try testing.expectEqualStrings(message, fault.message);
            }
            try testing.expectEqualStrings(expected, sink.buffered());
        }
    }
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

/// Doc 61 test setup: installs `unmask(fn)`, which marks a function's proto
/// non-maskable, as a proto failing the call-layout check would be
/// (`bc_liveness.maskable`). The collector then roots its frames whole and
/// its traces keep every store. Call it before the function first runs.
pub fn installUnmask(vm: *Vm) !void {
    const unmask = struct {
        fn call(_: *anyopaque, args: []const Value) anyerror!Value {
            const closure = Closure.fromHeader(args[0].asHeap());
            @constCast(closure.proto).maskable = false;
            return Value.nil();
        }
    }.call;
    const native = try vm.heap.newNative(&unmask, "unmask");
    try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("unmask"), Value.heap(&native.header));
}

/// `expectProgram` for output that depends on when collections run, such as
/// an object id printed after a dead string was re-interned. Doc 61's masked
/// walk frees an object as soon as only dead registers name it, so the stress
/// legs (a collection at every safepoint) free more often and may print other
/// ids than the normal legs (§9). Every trace mode must still print exactly
/// its GC discipline's expected output.
pub fn expectProgramByGc(source: [:0]const u8, normal: []const u8, stress_expected: []const u8, opts: CapturedOpts) !void {
    inline for (.{ false, true }) |stress| {
        inline for (.{ .off, .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            var buf: [256]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            try runCapturedTuned(testing.allocator, source, &sink, stress, mode, opts);
            testing.expectEqualStrings(if (stress) stress_expected else normal, sink.buffered()) catch |e| {
                std.debug.print("leg: stress={} mode={s}\n", .{ stress, @tagName(mode) });
                return e;
            };
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
/// host system with only `readFile`, so tests never touch the real disk.
pub const FakeFs = struct {
    entries: []const struct { path: []const u8, content: []const u8 },
    pub fn readFn(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| if (std.mem.eql(u8, e.path, path)) return e.content;
        return null;
    }
    const vtable: HostSystem.VTable = .{ .readFile = &FakeFs.readFn };
    pub fn system(self: *FakeFs) HostSystem {
        return .{ .ctx = self, .vtable = &vtable };
    }
};
/// An in-memory host system for the `io` library (doc 65 Phase 3): files by
/// path, stdin, and handles by the VM's id — the `HostSystem` surface the
/// real OS implements (`host_system.zig`), so tests never touch the disk. A
/// `fill` returns at most `chunk` bytes, so reads cross host buffers. `calls`
/// counts every vtable call, so a test can prove a replay made none.
pub const FakeHost = struct {
    gpa: std.mem.Allocator,
    files: std.StringArrayHashMapUnmanaged(FakeFile) = .empty,
    handles: std.AutoHashMapUnmanaged(seam.FileId, FakeHandle) = .empty,
    /// Paths `open` refuses with `permission_denied`.
    denied: []const []const u8 = &.{},
    stdin: []const u8 = "",
    stdin_pos: usize = 0,
    chunk: usize = 3,
    calls: usize = 0,
    /// The modification clock: every write ticks it.
    clock: i64 = 0,
    /// The wall clock `os.time()` reads.
    now: i64 = 0,
    /// The local zone, a POSIX `TZ` rule; null is UTC.
    tz: ?tzif.Posix = null,
    /// Paths `remove`/`rename` refuse with `permission_denied`.
    locked: []const []const u8 = &.{},
    /// How many names `tmpname` has handed out.
    tmp_count: usize = 0,
    tmp_name: [32]u8 = undefined,
    /// The environment `os.environ` lists: name/value pairs.
    vars: []const [2][]const u8 = &.{},
    /// What `proc` answers, and a few facts about the last request.
    proc_result: seam.ProcResult = .{ .fail = .{ .class = .not_found } },
    proc_calls: usize = 0,
    proc_argc: usize = 0,
    proc_stages: usize = 0,
    proc_stdout_inherit: bool = false,
    /// Background jobs: what `proc_spawn` answers, the states `proc_job`
    /// walks through (the last one repeats), and what `proc_kill` answers.
    spawn_result: seam.ProcSpawned = .{ .job = .{ .id = 7, .pid = 4242 } },
    job_states: []const seam.ProcJobState = &.{.running},
    job_looks: usize = 0,
    job_blocked: usize = 0,
    kill_result: seam.ProcKill = .sent,
    kill_signal: [16]u8 = undefined,
    kill_signal_len: usize = 0,
    kill_calls: usize = 0,
    /// The working directory and environment mutations (doc 75 §6): what
    /// `getcwd` answers, what `chdir` and `setenv` answer, and the last
    /// request each saw.
    cwd: seam.Result([]const u8) = .{ .ok = "/work" },
    chdir_result: ?seam.ErrorClass = null,
    setenv_result: ?seam.ErrorClass = null,
    mutate_calls: usize = 0,
    set_name: [32]u8 = undefined,
    set_name_len: usize = 0,
    set_value: [32]u8 = undefined,
    set_value_len: ?usize = null,
    chdir_path: [64]u8 = undefined,
    chdir_path_len: usize = 0,
    proc_max_bytes: usize = 0,
    proc_timeout_ns: ?u64 = null,

    pub const FakeFile = struct {
        content: std.ArrayList(u8) = .empty,
        mtime: i64 = 0,
    };
    const FakeHandle = struct {
        /// The key in `files` (owned by the map).
        path: []const u8,
        pos: usize = 0,
        append: bool = false,
        /// A `tmpfile`: its file goes when it is closed.
        tmp: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) FakeHost {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeHost) void {
        var it = self.files.iterator();
        while (it.next()) |e| {
            e.value_ptr.content.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.files.deinit(self.gpa);
        self.handles.deinit(self.gpa);
    }

    /// Create or replace a file.
    pub fn put(self: *FakeHost, path: []const u8, bytes: []const u8) !void {
        const f = try self.fileFor(path);
        f.content.clearRetainingCapacity();
        try f.content.appendSlice(self.gpa, bytes);
        self.clock += 1;
        f.mtime = self.clock;
    }

    /// A file's content, or null if there is none.
    pub fn contentOf(self: *FakeHost, path: []const u8) ?[]const u8 {
        const f = self.files.getPtr(path) orelse return null;
        return f.content.items;
    }

    fn fileFor(self: *FakeHost, path: []const u8) !*FakeFile {
        const gop = try self.files.getOrPut(self.gpa, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
                self.files.swapRemoveAt(gop.index);
                return e;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn of(ctx: *anyopaque) *FakeHost {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self;
    }

    fn openFn(ctx: *anyopaque, id: seam.FileId, path: []const u8, mode: seam.OpenMode) ?seam.ErrorClass {
        const self = of(ctx);
        for (self.denied) |d| if (std.mem.eql(u8, d, path)) return .permission_denied;
        if (mode.kind == .read and !self.files.contains(path)) return .not_found;
        const f = self.fileFor(path) catch return .other;
        if (mode.kind == .write) {
            f.content.clearRetainingCapacity();
            self.clock += 1;
            f.mtime = self.clock;
        }
        const key = self.files.getKey(path).?;
        self.handles.put(self.gpa, id, .{ .path = key, .append = mode.kind == .append }) catch return .other;
        return null;
    }

    fn tmpfileFn(ctx: *anyopaque, id: seam.FileId) ?seam.ErrorClass {
        const self = of(ctx);
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "<tmp {d}>", .{id}) catch return .other;
        _ = self.fileFor(name) catch return .other;
        self.handles.put(self.gpa, id, .{ .path = self.files.getKey(name).?, .tmp = true }) catch return .other;
        return null;
    }

    fn fillFn(ctx: *anyopaque, id: seam.FileId) seam.Result([]const u8) {
        const self = of(ctx);
        if (id == seam.stdin_id) {
            const rest = self.stdin[self.stdin_pos..];
            return .{ .ok = rest[0..@min(rest.len, self.chunk)] };
        }
        const h = self.handles.getPtr(id) orelse return .{ .fail = .other };
        const bytes = self.files.getPtr(h.path).?.content.items;
        if (h.pos >= bytes.len) return .{ .ok = "" };
        const rest = bytes[h.pos..];
        return .{ .ok = rest[0..@min(rest.len, self.chunk)] };
    }

    fn consumeFn(ctx: *anyopaque, id: seam.FileId, n: usize) void {
        const self = of(ctx);
        if (id == seam.stdin_id) {
            self.stdin_pos += n;
        } else if (self.handles.getPtr(id)) |h| h.pos += n;
    }

    fn writeFn(ctx: *anyopaque, id: seam.FileId, bytes: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        const h = self.handles.getPtr(id) orelse return .other;
        const f = self.files.getPtr(h.path).?;
        if (h.append) h.pos = f.content.items.len;
        const end = h.pos + bytes.len;
        if (end > f.content.items.len) {
            const old = f.content.items.len;
            f.content.resize(self.gpa, end) catch return .other;
            if (h.pos > old) @memset(f.content.items[old..h.pos], 0);
        }
        @memcpy(f.content.items[h.pos..end], bytes);
        h.pos = end;
        self.clock += 1;
        f.mtime = self.clock;
        return null;
    }

    fn seekFn(ctx: *anyopaque, id: seam.FileId, whence: seam.Whence, offset: i64) seam.Result(u64) {
        const self = of(ctx);
        if (id == seam.stdin_id) return .{ .fail = .not_seekable };
        const h = self.handles.getPtr(id) orelse return .{ .fail = .other };
        const base: i64 = switch (whence) {
            .set => 0,
            .cur => @intCast(h.pos),
            .end => @intCast(self.files.getPtr(h.path).?.content.items.len),
        };
        const to = base + offset;
        if (to < 0) return .{ .fail = .other };
        h.pos = @intCast(to);
        return .{ .ok = h.pos };
    }

    fn okFn(ctx: *anyopaque, id: seam.FileId) ?seam.ErrorClass {
        const self = of(ctx);
        return if (self.handles.contains(id)) null else .other;
    }

    fn setvbufFn(ctx: *anyopaque, id: seam.FileId, mode: seam.BufferMode, size: usize) ?seam.ErrorClass {
        _ = mode;
        _ = size;
        return okFn(ctx, id);
    }

    fn closeFn(ctx: *anyopaque, id: seam.FileId) ?seam.ErrorClass {
        const self = of(ctx);
        const kv = self.handles.fetchRemove(id) orelse return .other;
        if (kv.value.tmp) {
            const i = self.files.getIndex(kv.value.path).?;
            const key = self.files.keys()[i];
            self.files.values()[i].content.deinit(self.gpa);
            self.files.swapRemoveAt(i);
            self.gpa.free(key);
        }
        return null;
    }

    fn dropFile(self: *FakeHost, path: []const u8) void {
        const i = self.files.getIndex(path).?;
        const key = self.files.keys()[i];
        self.files.values()[i].content.deinit(self.gpa);
        self.files.orderedRemoveAt(i);
        self.gpa.free(key);
    }

    fn removeFn(ctx: *anyopaque, path: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        for (self.locked) |d| if (std.mem.eql(u8, d, path)) return .permission_denied;
        if (!self.files.contains(path)) return .not_found;
        self.dropFile(path);
        return null;
    }

    fn renameFn(ctx: *anyopaque, from: []const u8, to: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        for (self.locked) |d| if (std.mem.eql(u8, d, from) or std.mem.eql(u8, d, to)) return .permission_denied;
        const content = (self.files.getPtr(from) orelse return .not_found).content.items;
        if (std.mem.eql(u8, from, to)) return null;
        const copy = self.gpa.dupe(u8, content) catch return .other;
        defer self.gpa.free(copy);
        self.put(to, copy) catch return .other;
        self.dropFile(from);
        return null;
    }

    fn tmpnameFn(ctx: *anyopaque) seam.Result([]const u8) {
        const self = of(ctx);
        self.tmp_count += 1;
        const name = std.fmt.bufPrint(&self.tmp_name, "/tmp/lua_{d}", .{self.tmp_count}) catch return .{ .fail = .other };
        self.put(name, "") catch return .{ .fail = .other };
        return .{ .ok = name };
    }

    fn wallSecondsFn(ctx: *anyopaque) i64 {
        return of(ctx).now;
    }

    fn procFn(ctx: *anyopaque, req: seam.ProcRequest) seam.ProcResult {
        const self = of(ctx);
        self.calls += 1;
        self.proc_calls += 1;
        self.proc_argc = req.stages[0].len;
        self.proc_stages = req.stages.len;
        self.proc_max_bytes = req.max_bytes;
        self.proc_timeout_ns = req.timeout_ns;
        return self.proc_result;
    }

    fn procSpawnFn(ctx: *anyopaque, req: seam.ProcRequest) seam.ProcSpawned {
        const self = of(ctx);
        self.calls += 1;
        self.proc_calls += 1;
        self.proc_stages = req.stages.len;
        self.proc_max_bytes = req.max_bytes;
        self.proc_timeout_ns = req.timeout_ns;
        self.proc_stdout_inherit = req.stdout == .inherit;
        return self.spawn_result;
    }

    fn procJobFn(ctx: *anyopaque, id: seam.ProcJobId, block: bool) seam.ProcJobState {
        const self = of(ctx);
        _ = id;
        self.calls += 1;
        if (block) self.job_blocked += 1;
        const i = @min(self.job_looks, self.job_states.len - 1);
        self.job_looks += 1;
        return self.job_states[i];
    }

    fn procKillFn(ctx: *anyopaque, id: seam.ProcJobId, signal: []const u8) seam.ProcKill {
        const self = of(ctx);
        _ = id;
        self.calls += 1;
        self.kill_calls += 1;
        self.kill_signal_len = @min(signal.len, self.kill_signal.len);
        @memcpy(self.kill_signal[0..self.kill_signal_len], signal[0..self.kill_signal_len]);
        return self.kill_result;
    }

    fn environFn(ctx: *anyopaque, visit: seam.EnvVisitFn, visit_ctx: *anyopaque) void {
        const self = of(ctx);
        self.calls += 1;
        for (self.vars) |kv| visit(visit_ctx, kv[0], kv[1]);
    }

    fn setenvFn(ctx: *anyopaque, name: []const u8, val: ?[]const u8) ?seam.ErrorClass {
        const self = of(ctx);
        self.calls += 1;
        self.mutate_calls += 1;
        self.set_name_len = @min(name.len, self.set_name.len);
        @memcpy(self.set_name[0..self.set_name_len], name[0..self.set_name_len]);
        self.set_value_len = if (val) |v| @min(v.len, self.set_value.len) else null;
        if (val) |v| @memcpy(self.set_value[0..self.set_value_len.?], v[0..self.set_value_len.?]);
        return self.setenv_result;
    }

    fn chdirFn(ctx: *anyopaque, path: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        self.calls += 1;
        self.mutate_calls += 1;
        self.chdir_path_len = @min(path.len, self.chdir_path.len);
        @memcpy(self.chdir_path[0..self.chdir_path_len], path[0..self.chdir_path_len]);
        return self.chdir_result;
    }

    fn getcwdFn(ctx: *anyopaque) seam.Result([]const u8) {
        const self = of(ctx);
        self.calls += 1;
        return self.cwd;
    }

    fn localZoneFn(ctx: *anyopaque, utc: i64) seam.LocalZone {
        const self = of(ctx);
        return if (self.tz) |tz| tz.lookup(utc) else seam.LocalZone.utc;
    }

    fn fingerprintFn(ctx: *anyopaque, id: seam.FileId) ?seam.Fingerprint {
        const self = of(ctx);
        const h = self.handles.getPtr(id) orelse return null;
        const f = self.files.getPtr(h.path).?;
        return .{ .size = f.content.items.len, .mtime_ns = f.mtime, .position = h.pos };
    }

    fn reopenFn(ctx: *anyopaque, id: seam.FileId, path: []const u8, mode: seam.OpenMode, fp: seam.Fingerprint) ?seam.ErrorClass {
        const self = of(ctx);
        const f = self.files.getPtr(path) orelse return .not_found;
        if (f.content.items.len != fp.size or f.mtime != fp.mtime_ns) return .other;
        self.handles.put(self.gpa, id, .{ .path = self.files.getKey(path).?, .pos = @intCast(fp.position), .append = mode.kind == .append }) catch return .other;
        return null;
    }

    const vtable: HostSystem.VTable = .{
        .open = &openFn,
        .tmpfile = &tmpfileFn,
        .fill = &fillFn,
        .consume = &consumeFn,
        .write = &writeFn,
        .seek = &seekFn,
        .flush = &okFn,
        .setvbuf = &setvbufFn,
        .close = &closeFn,
        .fingerprint = &fingerprintFn,
        .reopen = &reopenFn,
        .remove = &removeFn,
        .rename = &renameFn,
        .tmpname = &tmpnameFn,
        .wallSeconds = &wallSecondsFn,
        .localZone = &localZoneFn,
        .environ = &environFn,
        .setenv = &setenvFn,
        .chdir = &chdirFn,
        .getcwd = &getcwdFn,
        .proc = &procFn,
        .proc_spawn = &procSpawnFn,
        .proc_job = &procJobFn,
        .proc_kill = &procKillFn,
    };

    pub fn system(self: *FakeHost) HostSystem {
        return .{ .ctx = self, .vtable = &vtable };
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

/// A test-only native that runs a full collection from inside a host call,
/// the in-run shape of `mh_collect` (doc 61 F3).
fn collectNative(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    vm.collect();
    return Value.nil();
}

/// Install `collect()` (see `collectNative`) as a global.
pub fn installCollect(vm: *Vm) anyerror!void {
    const native = try vm.heap.newNative(collectNative, "collect");
    try vm.globals.set(vm.gpa, try vm.heap.internValue("collect"), Value.heap(&native.header));
}

/// Doc 68 §5.1: a program that runs Lua code from `table.sort`'s
/// activation in every way it can: a comparator, `__lt` handlers, a sort
/// inside a comparator, comparator errors caught, the table frozen
/// mid-sort, a native comparator, a callable table, `pcall` of the native
/// (the Zig fallback), and a comparator yielding inside a coroutine.
pub const resumable_natives_program: [:0]const u8 =
    \\local t = {5, 2, 8, 1, 9, 3, 7}
    \\table.sort(t, function(a, b) return a > b end)
    \\print(table.concat(t, " "))
    \\local V = {__lt = function(a, b) return a.k < b.k end}
    \\local u = {}
    \\for i = 1, 6 do u[i] = setmetatable({ k = (i * 5) % 7 }, V) end
    \\table.sort(u)
    \\local ks = {}
    \\for i = 1, #u do ks[i] = u[i].k end
    \\print(table.concat(ks, " "))
    \\local calls = 0
    \\local w = {4, 3, 2, 1}
    \\table.sort(w, function(a, b)
    \\  calls = calls + 1
    \\  local inner = {b, a}
    \\  table.sort(inner, function(x, y) return x < y end)
    \\  return inner[1] == a and a ~= b
    \\end)
    \\print(table.concat(w, " "), calls)
    \\print(pcall(table.sort, {3, 1, 2}, function(a, b) return a < b end))
    \\local e = {3, 1, 2}
    \\print(pcall(function() table.sort(e, function(a, b) error("cmp", 2) end) end))
    \\print(pcall(function() table.sort(e, function(a, b) error("cmp") end) end))
    \\local f = {5, 4, 3, 2, 1}
    \\print(pcall(function()
    \\  table.sort(f, function(a, b) if not table.isfrozen(f) then table.freeze(f) end return a < b end)
    \\end))
    \\print(table.concat(f, " "))
    \\print(pcall(function() table.sort({3, 2, 1}, string.rep) end))
    \\local cmp = setmetatable({}, {__call = function(self, x, y) return x < y end})
    \\local g = {3, 1, 2}
    \\table.sort(g, cmp)
    \\print(table.concat(g, " "))
    \\local co = coroutine.wrap(function()
    \\  local y = {5, 3, 9, 1}
    \\  table.sort(y, function(a, b) coroutine.yield(a) return a < b end)
    \\  return table.concat(y, " ")
    \\end)
    \\local r, n = co(), 0
    \\while type(r) == "number" do n = n + 1 r = co() end
    \\print(r, n)
    \\print(string.gsub("hello world", "(o)(%s?)", function(a, b) return "<" .. a .. b .. ">" end))
    \\print(string.gsub("abc", "%w", function(c) if c == "b" then return false end return c:upper() end))
    \\print(string.gsub("a b c", "%a", function(c) return (string.gsub(c, ".", function(x) return x .. x end)) end))
    \\print(string.gsub("abc", "", function() return "-" end))
    \\print(string.gsub("héllo", "l+", function(m) return #m end, 1))
    \\print(pcall(function() return string.gsub("abc", "b", function() return {} end) end))
    \\print(pcall(function() return string.gsub("abc", "b", function() error("rep", 2) end) end))
    \\print(pcall(string.gsub, "a b", "%a", function(c) return c .. c end))
    \\print(select("#", string.gsub("x", "x", function() end)))
    \\local words = {}
    \\for i = 1, 400 do words[i] = "w" .. i end
    \\local long, cnt = table.concat(words, " "):gsub("%w+", function(w) return w:upper() .. "!" end)
    \\print(#long, cnt, long:sub(-12))
    \\local gco = coroutine.wrap(function()
    \\  return (string.gsub("x y z", "%a", function(c) return coroutine.yield(c) end))
    \\end)
    \\local parts = { gco() }
    \\parts[2] = gco("A")
    \\parts[3] = gco("B")
    \\parts[4] = gco("C")
    \\print(table.concat(parts, " "))
;

/// `resumable_natives_program`'s output.
pub const resumable_natives_output =
    "9 8 7 5 3 2 1\n" ++
    "1 2 3 4 5 6\n" ++
    "1 2 3 4\t6\n" ++
    "true\n" ++
    "false\tcmp\n" ++
    "false\tmain:23: cmp\n" ++
    "false\tmain:26: attempt to modify a readonly table\n" ++
    "5 4 3 2 1\n" ++
    "false\tbad argument #1 to 'string.rep' (string expected, got number)\n" ++
    "1 2 3\n" ++
    "1 3 5 9\t6\n" ++
    "hell<o >w<o>rld\t2\n" ++
    "AbC\t3\n" ++
    "aa bb cc\t3\n" ++
    "-a-b-c-\t4\n" ++
    "hé2o\t1\n" ++
    "false\tmain:47: invalid replacement value (a table)\n" ++
    "false\trep\n" ++
    "true\taa bb\t2\n" ++
    "2\n" ++
    "2291\t400\t W399! W400!\n" ++
    "x y z A B C\n";

/// Doc 68 P3: the other resumable natives, with no file: `require` with a
/// Lua loader from `package.preload`, a Lua searcher and a failing search,
/// both under a coroutine that yields in them; `tostring` and `print` of
/// objects whose `__tostring` is a Lua function, one that yields while
/// `print` has already written.
pub const resumable_natives_program2: [:0]const u8 =
    \\package.preload.a = function(n) return {n = n} end
    \\local m, d = require("a")
    \\print(m.n, d, select("#", require("a")))
    \\package.searchers[#package.searchers + 1] = function(n)
    \\  if n == "late" then return function(nn, dd) return nn .. "!", "ld" end, "ldata" end
    \\  return "\n\tno late"
    \\end
    \\print(require("late"))
    \\local co = coroutine.wrap(function()
    \\  package.preload.y = function(n) return coroutine.yield("loader") end
    \\  return require("y")
    \\end)
    \\print(co())
    \\print(co(7))
    \\local O = setmetatable({}, {__tostring = function() return "O" end})
    \\print(tostring(O), O, 1, O)
    \\local Y = setmetatable({}, {__tostring = function() return coroutine.yield("ts") end})
    \\local c2 = coroutine.wrap(function() print("a", Y, "b") return tostring(Y) end)
    \\print(c2())
    \\print(c2("S1"))
    \\print(c2("S2"))
    \\package.searchers = {function() return "\n\tA" end}
    \\print(pcall(require, "nope"))
    \\print(pcall(function() return require("nope") end))
;

/// `resumable_natives_program2`'s output.
pub const resumable_natives_output2 =
    "a\t:preload:\t1\n" ++
    "late!\tldata\n" ++
    "loader\n" ++
    "7\t:preload:\n" ++
    "O\tO\t1\tO\n" ++
    "a\tts\n" ++
    "S1\tb\n" ++
    "ts\n" ++
    "S2\n" ++
    "false\tmodule 'nope' not found:\n\tA\n" ++
    "false\tmodule 'nope' not found:\n\tA\n";

/// Doc 68 P2: a program that runs Lua code in every kind of metamethod
/// frame: operators, compare-and-branch, `__index`/`__newindex` (fused
/// steps on either side), `__close` on block exit and on `return f()`, a
/// `__close` error caught, coroutines yielding inside `__index` and
/// `__close`, and a native `__index`, which still runs in place.
pub const metamethod_frames_program: [:0]const u8 =
    \\local V = {}
    \\V.__index = function(t, k) local d = k * 2 return d end
    \\V.__newindex = function(t, k, v) rawset(t, "last", v) end
    \\V.__add = function(a, b) return a.x + b.x end
    \\V.__eq = function(a, b) return a.x == b.x end
    \\V.__lt = function(a, b) return a.x < b.x end
    \\V.__concat = function(a, b) return "c" end
    \\V.__len = function(a) return 7 end
    \\V.__unm = function(a) return -a.x end
    \\local p, q = setmetatable({ x = 1 }, V), setmetatable({ x = 2 }, V)
    \\print(p[5], p + q, p == q, p ~= q, p < q, p > q, p .. q, #p, -p)
    \\p[3] = 9
    \\if p < q then print("lt", p.last) end
    \\local g = setmetatable({}, {__index = function(t, k)
    \\  return setmetatable({}, {__index = function(t2, k2) return k * 10 + k2 end,
    \\    __newindex = function(t2, k2, v) print("set", k, k2, v) end})
    \\end})
    \\print(g[1][2])
    \\g[3][4] = 5
    \\local C = {__close = function(o, e) print("close", o.n, e) end}
    \\do
    \\  local a <close> = setmetatable({ n = 1 }, C)
    \\  local b <close> = setmetatable({ n = 2 }, C)
    \\end
    \\local function three() return 4, 5, 6 end
    \\local function f()
    \\  local a <close> = setmetatable({ n = 3 }, C)
    \\  return three()
    \\end
    \\print(f())
    \\print(pcall(function()
    \\  local a <close> = setmetatable({ n = 4 }, C)
    \\  local b <close> = setmetatable({}, {__close = function() error("cl") end})
    \\end))
    \\local co = coroutine.wrap(function()
    \\  local a <close> = setmetatable({}, {__close = function() coroutine.yield("yc") end})
    \\  local m = setmetatable({}, {__index = function(t, k) return coroutine.yield("yi") end})
    \\  print("got", m.k)
    \\  return "done"
    \\end)
    \\print(co(), co(8), co())
    \\local s = setmetatable({}, {__index = rawequal})
    \\print(s.ab)
    \\local K = setmetatable({ n = 1 }, {__call = function(self, a, ...) return self.n + a + select("#", ...) end})
    \\print(K(5, 6, 7))
    \\local Y = setmetatable({}, {__call = function(self, v) return coroutine.yield(v) end})
    \\local cy = coroutine.wrap(function() return Y("yk") + 1 end)
    \\print(cy(), cy(4))
;
