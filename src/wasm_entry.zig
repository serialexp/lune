//! mahina — wasm32-freestanding browser entry.
//!
//! A thin C-ABI surface over the library `run` path so the VM can execute a
//! mahina source chunk *in the browser*, with no host I/O. It mirrors
//! `main.zig`'s `runSource` minus everything host-bound: there is no file read,
//! no stdout fd, no process exit — the program's `print` output is captured into
//! an in-memory `io.Writer.fixed` sink, and the run's artifacts (keyframe
//! snapshot, effect log, trace cache) are returned as owned byte buffers that
//! JS copies out of linear memory.
//!
//! Why this exists: wasm is the platform that *cannot* cheat on mahina's own
//! determinism rules — there is no clock syscall here, so `clock()` is forced to
//! flow through the injected `ClockSource` (backed by a JS `host_now_ns` import),
//! exactly as `docs/design/02-determinism.md` intends. Two different engines
//! (this one and the native binary) agreeing byte-for-byte is the strongest
//! determinism check we have; see the dual-execution differential validator.
//!
//! ABI (all integers little-endian u32 unless noted; wasm32 ⇒ pointer == u32):
//!   import  env.host_now_ns() i64          — monotonic-ish ns from the host (JS)
//!   export  mahina_alloc(len) -> ptr         — allocate `len` bytes in linear mem
//!   export  mahina_free(ptr, len)            — free a prior `mahina_alloc`
//!   export  mahina_run(src_ptr, src_len) -> *Result
//!   export  mahina_free_result(*Result)      — free a Result and all its buffers
//!   export  mahina_check(src_ptr, src_len) -> *CheckResult
//!   export  mahina_free_check_result(*CheckResult)
//!   export  mahina_replay(src_ptr, src_len, eff_ptr, eff_len, stop_after) -> *ReplayResult
//!   export  mahina_free_replay_result(*ReplayResult)
//!
//! Result layout (extern struct, read by JS via DataView):
//!   u32 status        0 = ok, 1 = error (see `diag` for the message)
//!   {u32 ptr,u32 len} stdout     program output (tab/newline formatted)
//!   {u32 ptr,u32 len} keyframe   binschema keyframe snapshot
//!   {u32 ptr,u32 len} effects    binschema effect log
//!   {u32 ptr,u32 len} trace      binschema trace cache
//!   {u32 ptr,u32 len} diag       human-readable diagnostics / error text (utf8)
//!   u32 error_line    1-based source line of a runtime error (0 = none)
//!   u32 error_start   byte offset [start,end) of the faulting span (for a squiggle)
//!   u32 error_end
//!   {u32 ptr,u32 len} backtrace  structured call chain blob (see encodeBacktrace;
//!                                empty when there's no located runtime error):
//!                                u32 frame_count, then per frame deepest-first
//!                                { u32 line, start, end, name_len, [name_len]u8 }
//!   (further fields are appended after `backtrace` — exec timing, the step-replay
//!    index `safepoint_*`/`safepoint_lines`, and the bytecode-view `disasm` blob;
//!    each is documented at its field in the `Result` struct below. New fields are
//!    always appended last so existing JS DataView offsets stay stable.)
//!
//! CheckResult layout (compile-only validation; for the in-browser editor's live
//! linter — parse + compile WITHOUT running the program, so there are no side
//! effects and no risk of an infinite loop hanging the tab):
//!   u32 status        0 = no errors, 1 = at least one error diagnostic
//!   {u32 ptr,u32 len} diags      ptr → array of `Diag`; len is the *record count*
//!                                (NOT a byte length). JS strides @sizeof(Diag).
//! Diag (extern struct, 24 bytes): { u32 severity (0=error,1=warning), u32 start,
//!   u32 end, u32 line (1-based), {u32 ptr,u32 len} msg (owned utf8) }. `start`/
//!   `end` are byte offsets [start,end) into the source the editor passed in.
//!
//! Each non-empty buffer is an independent `wasm_allocator` allocation; the
//! Result/CheckResult struct is one too. `mahina_free_result` /
//! `mahina_free_check_result` free them all.

const std = @import("std");
const mahina = @import("mahina");

const Diagnostics = mahina.diag.Diagnostics;

/// Linear-memory allocator for freestanding wasm (backed by `memory.grow`).
const gpa = std.heap.wasm_allocator;

/// The host clock import. JS supplies a monotonic-ish nanosecond counter
/// (e.g. `performance.now() * 1e6`). In `record` mode every `clock()` call is
/// logged; in `replay` mode the log is fed back and this is never consulted.
extern "env" fn host_now_ns() i64;

fn wasmClockNs(_: *anyopaque) i64 {
    return host_now_ns();
}

/// `ClockSource.ctx` is unused (the import needs no state) — point it anywhere.
var clock_ctx: u8 = 0;

/// The host seed import for `random()`. JS supplies one nondeterministic 64-bit
/// seed (e.g. from `crypto.getRandomValues`); the VM owns the PRNG and reproduces
/// the whole draw stream from it. In `record` mode the seed is logged once; in
/// `replay` mode the log is fed back and this is never consulted.
extern "env" fn host_random_seed() i64;

fn wasmRandomSeed(_: *anyopaque) u64 {
    return @bitCast(host_random_seed());
}

/// `RandomSeedSource.ctx` is unused (the import needs no state) — point it anywhere.
var rng_ctx: u8 = 0;

/// A null env/args source for the browser playground: there is no process
/// environment or command line, so `getenv` always returns nil, `argc` is 0, and
/// `argv` is always nil. Injected (in `record`) so `getenv`/`argc`/`argv` are
/// *available* (they cleanly return empty) rather than `EnvUnavailable`. A
/// JS-supplied env/argv map could replace this later; for now the playground has
/// none. `ctx` is unused — point it at the shared throwaway byte.
fn nullEnvGetenv(_: *anyopaque, _: []const u8) ?[]const u8 {
    return null;
}
fn nullEnvArgCount(_: *anyopaque) i64 {
    return 0;
}
fn nullEnvArg(_: *anyopaque, _: i64) ?[]const u8 {
    return null;
}
fn nullHostEnv() mahina.interp.HostEnv {
    return .{
        .ctx = &clock_ctx,
        .getenv = &nullEnvGetenv,
        .argCount = &nullEnvArgCount,
        .arg = &nullEnvArg,
    };
}

/// A (pointer, length) pair into linear memory, as two u32s for JS DataView.
const Buf = extern struct {
    ptr: u32 = 0,
    len: u32 = 0,
};

/// The fixed result block JS reads after `mahina_run`. See the file header.
const Result = extern struct {
    status: u32 = 0,
    stdout: Buf = .{},
    keyframe: Buf = .{},
    effects: Buf = .{},
    trace: Buf = .{},
    diag: Buf = .{},
    /// Runtime-error location, set only on a *run* failure (status 1 with a
    /// faulting frame). `error_line == 0` ⇒ no located runtime error.
    error_line: u32 = 0,
    error_start: u32 = 0,
    error_end: u32 = 0,
    /// Structured backtrace blob (see `encodeBacktrace`); empty unless a located
    /// runtime error. Appended last so existing JS field offsets stay stable.
    backtrace: Buf = .{},
    /// VM-execute-only wall time in nanoseconds (the `vm.run` call alone — excludes
    /// parse/compile and artifact serialization), measured via the host clock
    /// import. Set on both the success and run-error paths. Appended last so prior
    /// JS field offsets stay stable.
    exec_ns: u64 = 0,
    /// Total instruction-boundary safepoint count of a pure tier-0 replay of this
    /// run (the step-debugger's step count). 0 when the replay index couldn't be
    /// built (e.g. a run failure) — the UI then offers no replay. See
    /// `buildReplayIndex`. Appended last so prior JS field offsets stay stable.
    safepoint_count: u32 = 0,
    /// 1 if the replay index hit the `safepoint_cap` before the program finished
    /// (stepping is bounded to the first `safepoint_count` steps — logged, never
    /// silent); 0 otherwise.
    safepoint_capped: u32 = 0,
    /// Line-per-safepoint index for line-grain stepping: a blob of `safepoint_count`
    /// little-endian `u32`s, where entry k is the 1-based source line of the
    /// instruction pending at safepoint k+1. Empty when `safepoint_count == 0`.
    safepoint_lines: Buf = .{},
    /// Static disassembly of every proto in this program (the bytecode view the
    /// step-replay panel renders, indexed by the replay cursor's `proto_id`). A
    /// self-describing little-endian blob; see `buildDisasm` for the layout. Empty
    /// when the disassembly couldn't be built. Appended last so prior JS field
    /// offsets stay stable.
    disasm: Buf = .{},
    /// Per-trace **execution log** (`execlogser.ExecLogFile`) for the JIT-trace
    /// iteration animation: for every cached trace, the recorded entries/exit-ramps
    /// and their per-iteration events. Empty when no trace executed (no hot loop).
    /// Appended last so prior JS field offsets stay stable.
    exec_log: Buf = .{},
    /// JIT execution-**coverage** artifact (`coverageser.CoverageFile`): the
    /// aggregate native-vs-tier-0 split (by iterations; time is n/a in wasm — no
    /// rdtsc) plus the event counters and per-anchor breakdown. The playground run
    /// forces `config.coverage = true`, so this is always present after a
    /// successful run with at least one back-edge. Appended last so prior JS field
    /// offsets stay stable.
    coverage: Buf = .{},
};

/// One compile diagnostic, flattened for JS (24 bytes; see file header). `start`/
/// `end` are byte offsets into the source; `msg` is an owned utf8 buffer.
const Diag = extern struct {
    severity: u32 = 0,
    start: u32 = 0,
    end: u32 = 0,
    line: u32 = 0,
    msg: Buf = .{},
};

/// The result of `mahina_check`: a flat array of `Diag` (or null when clean). Note
/// `diags.len` is the *record count*, not a byte length.
const CheckResult = extern struct {
    status: u32 = 0,
    diags: Buf = .{},
};

/// The state at one replay step (see `mahina_replay`). All buffers are owned and
/// freed by `mahina_free_replay_result`.
const ReplayResult = extern struct {
    /// 0 = ok (suspended at the step, or finished), 1 = error (`diag` has why).
    status: u32 = 0,
    /// Program output accumulated up to this step (`print` so far).
    stdout: Buf = .{},
    /// Whole-VM keyframe snapshot AT this step (the heap graph + roots), decodable
    /// by the generated `SnapshotFileDecoder` — the source of the locals/globals view.
    keyframe: Buf = .{},
    /// Error text, set only when `status == 1`.
    diag: Buf = .{},
    /// 1-based source line of the instruction *pending* at this step (0 when the
    /// program already finished, or no span was available).
    current_line: u32 = 0,
    /// UTF-8 byte span [start,end) of that pending instruction (for the editor's
    /// current-line highlight). Both 0 when finished / unavailable.
    current_start: u32 = 0,
    current_end: u32 = 0,
    /// Live call depth at this step (number of active frames).
    depth: u32 = 0,
    /// 1 if the program ran to completion before reaching the requested step
    /// (`stop_after` was at/after the last safepoint); 0 if suspended mid-run.
    finished: u32 = 0,
    /// Structured call-chain blob at this step (deepest-first; same format as
    /// `Result.backtrace`, see `encodeBacktrace`). Empty when finished.
    backtrace: Buf = .{},
    /// Replay cursor at this step: the `Proto.id` of the live (innermost) frame
    /// and its `pc` — i.e. the index of the pending instruction within that
    /// proto's disassembly (`Result.disasm`). Both 0 when finished/unavailable.
    /// Appended last so prior JS field offsets stay stable.
    proto_id: u32 = 0,
    pc: u32 = 0,
    /// Doc 61 Phase V: one byte per register of the innermost frame's window,
    /// 1 when a collection at this step roots it (`Vm.frameMask`), 0 when the
    /// register is dead: no path from `pc` reads it before writing it, and a
    /// collection may already have set it to nil. Empty when finished, or
    /// when the frame is rooted whole (a non-maskable proto).
    live: Buf = .{},
};

/// Wrap an owned byte slice as a `Buf` (transfers ownership to JS; freed by
/// `mahina_free_result`). An empty slice yields a null `Buf`.
fn bufFromSlice(bytes: []u8) Buf {
    if (bytes.len == 0) return .{};
    return .{ .ptr = @intCast(@intFromPtr(bytes.ptr)), .len = @intCast(bytes.len) };
}

/// Free a `Buf` previously handed to JS, if non-empty.
fn freeBuf(b: Buf) void {
    if (b.len == 0) return;
    const ptr: [*]u8 = @ptrFromInt(@as(usize, b.ptr));
    gpa.free(ptr[0..@as(usize, b.len)]);
}

// --- exports ---------------------------------------------------------------

/// The guaranteed-tail-call capability gate, exported so the browser can verify
/// it at runtime. Runs `iterations` handler-to-handler `@call(.always_tail)`
/// hops (see `dispatch.zig`); returns the accumulator, which equals `iterations`
/// iff every frame was reused (O(1) stack). Two roles:
///   1. *Compile-time gate* — merely exporting this forces `dispatch.zig` to be
///      compiled for `wasm32 + tail_call`. `@call(.always_tail)` is a hard
///      guarantee: if wasm couldn't emit a real tail call, `zig build wasm`
///      would fail here rather than silently grow the stack. This is pillar #4
///      ("Stay on Zig's bedrock") holding on the browser target.
///   2. *Runtime gate* — a `bun` test calls this with ~2M iterations; completing
///      without a stack overflow proves the browser engine honours `return_call`.
export fn mahina_dispatch_smoke(iterations: u32) u32 {
    return @intCast(mahina.dispatch.run(@as(u64, iterations)));
}

/// Allocate `len` bytes of linear memory for JS to write a source chunk into.
/// Returns 0 on OOM. Free with `mahina_free` (or it is consumed by `mahina_run`,
/// which copies the source and frees nothing of the caller's — JS still owns it).
export fn mahina_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const slice = gpa.alloc(u8, @as(usize, len)) catch return 0;
    return @intCast(@intFromPtr(slice.ptr));
}

/// Free a buffer obtained from `mahina_alloc`.
export fn mahina_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const p: [*]u8 = @ptrFromInt(@as(usize, ptr));
    gpa.free(p[0..@as(usize, len)]);
}

/// Parse, compile, and run a source chunk; return an owned `*Result` (0 on a
/// catastrophic allocation failure before a Result exists). The source bytes at
/// `[src_ptr, src_ptr+src_len)` are read but not freed — JS still owns that
/// buffer and frees it with `mahina_free`.
export fn mahina_run(src_ptr: u32, src_len: u32, args_ptr: u32, args_len: u32) ?*Result {
    const res = gpa.create(Result) catch return null;
    res.* = .{};

    const src: []const u8 = blk: {
        if (src_len == 0) break :blk &[_]u8{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, src_ptr));
        break :blk p[0..@as(usize, src_len)];
    };

    // The packed argv blob (may be empty). Decoded into a `[][]const u8` inside
    // `run`, which owns the freeing; the blob memory itself is borrowed (freed by
    // the JS caller after `mahina_run` returns), so `populateArgs` must intern (it
    // does) before we return.
    const args_blob: []const u8 = blk: {
        if (args_len == 0) break :blk &[_]u8{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, args_ptr));
        break :blk p[0..@as(usize, args_len)];
    };

    run(res, src, args_blob) catch |err| {
        // Best-effort: surface the error name as diagnostics text. If even that
        // allocation fails, leave diag null; status still flags the failure.
        res.status = 1;
        if (res.diag.len == 0) {
            if (gpa.dupe(u8, @errorName(err))) |name| {
                res.diag = bufFromSlice(name);
            } else |_| {}
        }
    };
    return res;
}

/// Free a `Result` and every buffer it owns.
export fn mahina_free_result(res: ?*Result) void {
    const r = res orelse return;
    freeBuf(r.stdout);
    freeBuf(r.keyframe);
    freeBuf(r.effects);
    freeBuf(r.trace);
    freeBuf(r.diag);
    freeBuf(r.backtrace);
    freeBuf(r.safepoint_lines);
    freeBuf(r.disasm);
    freeBuf(r.exec_log);
    freeBuf(r.coverage);
    gpa.destroy(r);
}

/// Parse + compile a source chunk and return its diagnostics — *without running
/// it*. This is the editor's live-validation entry: it stops after the frontend,
/// so there are no side effects and a user's infinite loop can never hang the
/// tab. Returns 0 only on a catastrophic allocation failure before a CheckResult
/// exists. The source bytes are read but not freed (JS still owns them).
export fn mahina_check(src_ptr: u32, src_len: u32) ?*CheckResult {
    const res = gpa.create(CheckResult) catch return null;
    res.* = .{};

    const src: []const u8 = blk: {
        if (src_len == 0) break :blk &[_]u8{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, src_ptr));
        break :blk p[0..@as(usize, src_len)];
    };

    check(res, src) catch {
        // An allocation failure while gathering diagnostics: report the failure
        // via status but hand back whatever (possibly empty) array we have.
        res.status = 1;
    };
    return res;
}

/// Free a `CheckResult`, every `Diag.msg`, and the `Diag` array itself.
export fn mahina_free_check_result(res: ?*CheckResult) void {
    const r = res orelse return;
    if (r.diags.len != 0) {
        const base: [*]Diag = @ptrFromInt(@as(usize, r.diags.ptr));
        const diags = base[0..@as(usize, r.diags.len)];
        for (diags) |d| freeBuf(d.msg);
        gpa.free(diags);
    }
    gpa.destroy(r);
}

/// Replay `source` forward to instruction-boundary safepoint `stop_after` and
/// return the VM state there (the stateless "replay to k" the step-debugger UI
/// drives). The recorded effect log at `[eff_ptr, eff_ptr+eff_len)` (the `effects`
/// blob from a prior `mahina_run`) is fed back in `.replay` mode, so re-running to
/// the same `stop_after` yields identical state every time. Runs in **pure tier-0**
/// (no trace execution), matching the `Result.safepoint_count` index, so every
/// loop iteration is its own step. `stop_after` is clamped to `safepoint_cap`.
///
/// Returns 0 only on a catastrophic allocation failure before a ReplayResult
/// exists. The source/effect bytes are read but not freed (JS still owns them).
export fn mahina_replay(src_ptr: u32, src_len: u32, eff_ptr: u32, eff_len: u32, stop_after: u32) ?*ReplayResult {
    const res = gpa.create(ReplayResult) catch return null;
    res.* = .{};

    const src: []const u8 = blk: {
        if (src_len == 0) break :blk &[_]u8{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, src_ptr));
        break :blk p[0..@as(usize, src_len)];
    };
    const eff: []const u8 = blk: {
        if (eff_len == 0) break :blk &[_]u8{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, eff_ptr));
        break :blk p[0..@as(usize, eff_len)];
    };

    replayRun(res, src, eff, stop_after) catch |err| {
        res.status = 1;
        if (res.diag.len == 0) {
            if (gpa.dupe(u8, @errorName(err))) |name| {
                res.diag = bufFromSlice(name);
            } else |_| {}
        }
    };
    return res;
}

/// Free a `ReplayResult` and every buffer it owns.
export fn mahina_free_replay_result(res: ?*ReplayResult) void {
    const r = res orelse return;
    freeBuf(r.stdout);
    freeBuf(r.keyframe);
    freeBuf(r.diag);
    freeBuf(r.backtrace);
    freeBuf(r.live);
    gpa.destroy(r);
}

fn replayRun(res: *ReplayResult, source: []const u8, eff_bytes: []const u8, stop_after: u32) !void {
    const src0 = try gpa.allocSentinel(u8, source.len, 0);
    defer gpa.free(src0);
    @memcpy(src0, source);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    var tree = mahina.parser.parse(gpa, src0, &diags) catch {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    }

    var vm = try mahina.interp.Vm.init(gpa);
    defer vm.deinit();

    var out_buf: [64 * 1024]u8 = undefined;
    var sink = mahina.io.Writer.fixed(&out_buf);
    vm.out = &sink;

    // Feed the recorded nondeterministic inputs back, deterministically. No
    // clock/seed source is injected: `.replay` reads the log, never the host.
    vm.effect_mode = .replay;
    if (eff_bytes.len > 0) {
        // String results (getenv/argv) are re-interned into `vm.heap`; the
        // effect-log GC root keeps them alive while the cursor feeds them back.
        const effects = try mahina.effectser.decodeFile(gpa, vm.heap, eff_bytes);
        defer gpa.free(effects);
        try vm.effect_log.appendSlice(gpa, effects);
    }
    vm.source = src0;
    // Pure tier-0: trace recording/execution stays off (the default), so each
    // instruction is one safepoint — matching `Result.safepoint_count`.
    vm.setSuspendCtl(.{ .after_safepoints = @min(@as(u64, stop_after), safepoint_cap) });

    var chunk = mahina.compiler.compileWithOptions(gpa, vm.heap, src0, tree.root, &diags, .{
        .known_globals = &mahina.interp.builtin_global_names,
    }) catch {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    };
    defer chunk.deinit();
    if (diags.hasErrors()) {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    }

    const outcome = vm.start(chunk.proto) catch |err| {
        // A runtime fault during replay: surface it the same way the live run does
        // (located message + backtrace), plus whatever printed before it.
        res.status = 1;
        const fault = try vm.describeFault(src0, err, gpa);
        res.diag = bufFromSlice(@constCast(fault.message));
        res.current_line = fault.line;
        res.current_start = fault.start;
        res.current_end = fault.end;
        res.backtrace = bufFromSlice(try encodeBacktrace(fault.frames));
        gpa.free(fault.frames);
        res.stdout = bufFromSlice(try gpa.dupe(u8, sink.buffered()));
        res.depth = vm.depth;
        return;
    };

    switch (outcome) {
        .suspended => {
            res.finished = 0;
            res.depth = vm.depth;
            const frame = &vm.frames[vm.depth - 1];
            const proto = frame.closure.proto;
            res.proto_id = proto.id;
            res.pc = @intCast(frame.pc);
            if (frame.pc < proto.spans.len) {
                const span = proto.spans[frame.pc];
                res.current_line = mahina.compiler.lineFromOffset(src0, span.start);
                res.current_start = span.start;
                res.current_end = span.end;
            }
            // Deepest-first call chain at this step (same encoding as a fault's).
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const frames = try vm.backtraceFrames(src0, arena.allocator());
            res.backtrace = bufFromSlice(try encodeBacktrace(frames));
            if (vm.frameMask(vm.depth - 1)) |mask| {
                const live = try gpa.alloc(u8, proto.num_registers);
                for (live, 0..) |*b, reg| b.* = @intFromBool(mask.keeps(reg));
                res.live = bufFromSlice(live);
            }
        },
        .finished => {
            // Ran to completion before `stop_after`: final state, no pending line.
            res.finished = 1;
            res.depth = 0;
        },
    }

    // The heap snapshot at this step (mid-run on suspend, final on finish) and the
    // output so far. `encodeSnapshot` is sound mid-execution (proven by F2c).
    res.keyframe = bufFromSlice(try mahina.keyframeser.encodeSnapshot(gpa, &vm));
    res.stdout = bufFromSlice(try gpa.dupe(u8, sink.buffered()));
    res.status = 0;
}

// --- the run path (mirrors main.zig runSource, host-free) ------------------

/// Decode the packed argv blob the JS host builds (see `runSource` in
/// `viz/src/wasm/mahina.ts`): a little-endian `u32 count`, then `count` records of
/// `{ u32 len; u8[len] }`. Returns a gpa-owned slice of borrowed sub-slices that
/// point into `blob` (no string copies — `populateArgs` interns them). The caller
/// frees the returned outer slice; `blob` stays owned by the FFI caller. An empty
/// blob yields an empty argv. Any length that overruns the blob is `Malformed`.
fn parseArgv(blob: []const u8) ![]const []const u8 {
    if (blob.len == 0) return &[_][]const u8{};
    if (blob.len < 4) return error.Malformed;
    const count = std.mem.readInt(u32, blob[0..4], .little);
    var argv = try gpa.alloc([]const u8, count);
    errdefer gpa.free(argv);
    var off: usize = 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (off + 4 > blob.len) return error.Malformed;
        const len = std.mem.readInt(u32, blob[off..][0..4], .little);
        off += 4;
        if (off + len > blob.len) return error.Malformed;
        argv[i] = blob[off .. off + len];
        off += len;
    }
    return argv;
}

fn run(res: *Result, source: []const u8, args_blob: []const u8) !void {
    // The lexer wants a NUL-terminated `[:0]const u8`. Copy the borrowed source
    // into an owned, sentinel-terminated buffer.
    const src0 = try gpa.allocSentinel(u8, source.len, 0);
    defer gpa.free(src0);
    @memcpy(src0, source);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    // --- parse ---
    var tree = mahina.parser.parse(gpa, src0, &diags) catch {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    }

    // The VM owns the heap string constants are interned into; bring it up
    // before compiling.
    var vm = try mahina.interp.Vm.init(gpa);
    defer vm.deinit();

    // Capture program output into an in-memory sink — there is no host stdout.
    var out_buf: [64 * 1024]u8 = undefined;
    var sink = mahina.io.Writer.fixed(&out_buf);
    vm.out = &sink;

    // Mirror the native `--emit-traces --emit-keyframe --emit-effects` run:
    // trace recording + execution on, effect recording on, clock injected.
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    // Record a per-trace execution log for the visualizer's iteration animation
    // (every entry/exit-ramp, capped detail). Off the JIT fast path; this is the
    // instrumented playground run.
    vm.trace.config.record_exec_log = true;
    // JIT execution-coverage accounting for the coverage view (native-vs-tier-0
    // split + per-anchor). Always on in the playground — the timing-purity concern
    // that keeps it opt-in on the CLI doesn't apply here (this run is already fully
    // instrumented). Time attribution is n/a in wasm (no rdtsc), so the artifact
    // carries iteration counts only.
    vm.trace.config.coverage = true;
    vm.effect_mode = .record;
    vm.clock_source = .{ .ctx = &clock_ctx, .nowNs = &wasmClockNs };
    vm.random_seed_source = .{ .ctx = &rng_ctx, .seed = &wasmRandomSeed };
    // The browser has no process env/args — inject a null source so getenv→nil,
    // argc→0, argv→nil (available, not EnvUnavailable).
    vm.host_env = nullHostEnv();

    // --- compile --- (pass builtin globals so the unknown-global lint doesn't
    // flag `print`/`clock`).
    var chunk = mahina.compiler.compileWithOptions(gpa, vm.heap, src0, tree.root, &diags, .{
        .known_globals = &mahina.interp.builtin_global_names,
    }) catch {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    };
    defer chunk.deinit();
    if (diags.hasErrors()) {
        res.status = 1;
        res.diag = bufFromSlice(try renderDiagnostics(&diags));
        return;
    }

    // Fill the global `arg` table from the host-supplied argv (load-time input,
    // like the CLI at main.zig:350 — the exec core never reads it mid-run, so
    // determinism holds). `argv[0]` is the script name, `argv[1..]` the user args;
    // a program reads its workload from `arg[1]` etc. Empty blob → arg stays the
    // empty table `installBaseLib` created (unchanged playground default). The
    // `argc()`/`argv()` *effect* natives remain null here (host_env is null) — this
    // only populates the deterministic `arg` table, which is what scripts use.
    const argv = try parseArgv(args_blob);
    defer gpa.free(argv);
    if (argv.len > 0) try vm.populateArgs(argv);

    // --- run --- (bracket the VM execution alone with the host clock for an
    // execute-only timing; parse/compile above and serialization below are
    // excluded. The same `host_now_ns` import backs `clock()`, but these reads are
    // pure measurement — not recorded as effects.)
    const exec_t0 = host_now_ns();
    const run_outcome = vm.run(chunk.proto);
    res.exec_ns = @intCast(host_now_ns() - exec_t0);
    _ = run_outcome catch |err| {
        res.status = 1;
        // Located, Lua-style message from the un-popped faulting frame. The
        // message is freshly `gpa`-allocated by `describeFault`, so hand its
        // ownership straight to the Result (freed by `mahina_free_result`).
        const fault = try vm.describeFault(src0, err, gpa);
        res.diag = bufFromSlice(@constCast(fault.message));
        res.error_line = fault.line;
        res.error_start = fault.start;
        res.error_end = fault.end;
        // Serialize the full call chain (including a lone frame) into an owned
        // blob; the FaultFrame slice is gpa-owned scratch (names point into the
        // proto, not gpa) — free it once copied. The UI decides when to show it.
        res.backtrace = bufFromSlice(try encodeBacktrace(fault.frames));
        gpa.free(fault.frames);
        // Still hand back whatever was printed before the fault.
        res.stdout = bufFromSlice(try gpa.dupe(u8, sink.buffered()));
        return;
    };

    // --- collect artifacts (all owned []u8, mirroring the emit* helpers) ---
    res.stdout = bufFromSlice(try gpa.dupe(u8, sink.buffered()));
    res.keyframe = bufFromSlice(try mahina.keyframeser.encodeSnapshot(gpa, &vm));
    res.effects = bufFromSlice(try mahina.effectser.encodeFile(gpa, vm.effect_log.items));
    res.trace = bufFromSlice(try vm.trace.encodeTraceFile(gpa));
    res.exec_log = bufFromSlice(try mahina.execlogser.encodeFile(gpa, vm.trace.exec_logs.items));
    res.coverage = bufFromSlice(try mahina.coverageser.encodeState(gpa, &vm.trace));
    res.status = 0;

    // Build the step-debugger index from the just-recorded effect log. This is a
    // *separate* pure-tier-0 pass (no trace execution) so the main run's trace
    // artifact above is untouched — and so every loop iteration is its own step
    // (a hot-traced run would batch iterations and skip them). Best-effort: a
    // failure here just leaves `safepoint_count == 0` (no replay offered); the
    // run itself already succeeded. The proto is immutable, so re-running it on a
    // fresh VM is sound; `vm` is still alive (its `effect_log` is the input).
    buildReplayIndex(res, chunk.proto, src0, vm.effect_log.items);

    // Disassemble every proto once for the step-replay bytecode view. The proto
    // tree is static and its ids are stable across compiles (deterministic
    // `assignProtoIds`), so the disassembly the record run emits here aligns with
    // the cursor (`proto_id`/`pc`) a replay step reports. Best-effort.
    buildDisasm(res, chunk.proto, src0);
}

/// The maximum number of safepoints the replay index records (and the ceiling
/// `mahina_replay` clamps `stop_after` to). Bounds the index blob and the per-step
/// re-execution cost for a very long (but finite) program: stepping is limited to
/// the first `safepoint_cap` steps, surfaced via `Result.safepoint_capped` rather
/// than silently truncated. ~1M steps ⇒ a ~4 MiB line blob, the practical ceiling
/// for an in-browser scrubber.
const safepoint_cap: u64 = 1_000_000;

/// Populate `res.safepoint_count` / `safepoint_capped` / `safepoint_lines` by
/// replaying `effects` through a fresh pure-tier-0 VM with the safepoint-line
/// recorder on. Best-effort — swallows errors (the replay affordance is simply
/// absent on failure).
fn buildReplayIndex(res: *Result, proto: *const mahina.bytecode.Proto, src0: [:0]const u8, effects: []const mahina.interp.Effect) void {
    buildReplayIndexInner(res, proto, src0, effects) catch {};
}

fn buildReplayIndexInner(res: *Result, proto: *const mahina.bytecode.Proto, src0: [:0]const u8, effects: []const mahina.interp.Effect) !void {
    var vm = try mahina.interp.Vm.init(gpa);
    defer vm.deinit();

    // stdout is irrelevant to the index; a throwaway sink (same size as the run
    // sink, so an over-printing program fails here identically rather than diverging).
    var out_buf: [64 * 1024]u8 = undefined;
    var sink = mahina.io.Writer.fixed(&out_buf);
    vm.out = &sink;

    vm.effect_mode = .replay;
    try vm.effect_log.appendSlice(gpa, effects);
    vm.source = src0;
    vm.setRecordSafepointLines(true);
    // Arm a suspend at the cap: if the program needs more safepoints than the cap,
    // we stop there (capped) instead of building an unbounded index.
    vm.setSuspendCtl(.{ .after_safepoints = safepoint_cap });

    const outcome = try vm.start(proto);
    res.safepoint_capped = if (outcome == .suspended) 1 else 0;
    res.safepoint_count = @intCast(vm.safepoint_lines.items.len);
    res.safepoint_lines = bufFromSlice(try encodeU32Array(vm.safepoint_lines.items));
}

/// Serialize a `[]u32` as a flat little-endian blob (4 bytes each). Empty → empty.
fn encodeU32Array(values: []const u32) ![]u8 {
    if (values.len == 0) return &[_]u8{};
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (values) |v| try appendU32(&buf, v);
    return buf.toOwnedSlice(gpa);
}

/// Populate `res.disasm` with a static disassembly of the whole proto tree (the
/// bytecode the step-replay panel renders). Best-effort — swallows errors (the
/// bytecode view is simply absent on failure; the run already succeeded).
fn buildDisasm(res: *Result, root: *const mahina.bytecode.Proto, src0: [:0]const u8) void {
    res.disasm = bufFromSlice(buildDisasmBlob(root, src0) catch return);
}

/// Encode the proto tree as a self-describing little-endian blob:
///   u32 proto_count
///   per proto:
///     u32 id
///     u32 name_len, [name_len]u8 name
///     u16 num_params, u16 num_registers
///     u32 instr_count
///     per instruction:
///       u32 line          1-based source line (0 if no span)
///       u32 text_len, [text_len]u8 text   (rendered via bytecode.writeInstr)
/// Protos are emitted in pre-order (root first, then children), matching the id
/// assignment order — but consumers index by `id`, not position.
fn buildDisasmBlob(root: *const mahina.bytecode.Proto, src0: [:0]const u8) ![]u8 {
    var protos: std.ArrayList(*const mahina.bytecode.Proto) = .empty;
    defer protos.deinit(gpa);
    try collectProtos(&protos, root);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try appendU32(&buf, @intCast(protos.items.len));
    for (protos.items) |proto| {
        try appendU32(&buf, proto.id);
        try appendU32(&buf, @intCast(proto.name.len));
        try buf.appendSlice(gpa, proto.name);
        try appendU16(&buf, proto.num_params);
        try appendU16(&buf, proto.num_registers);
        try appendU32(&buf, @intCast(proto.code.len));
        for (proto.code, 0..) |instr, i| {
            const line: u32 = if (i < proto.spans.len)
                mahina.compiler.lineFromOffset(src0, proto.spans[i].start)
            else
                0;
            try appendU32(&buf, line);

            // Render this one instruction into a scratch buffer (instructions are
            // short and fixed-width; 128 bytes is comfortably enough).
            var instr_buf: [128]u8 = undefined;
            var w = mahina.io.Writer.fixed(&instr_buf);
            try mahina.bytecode.writeInstr(&w, instr);
            const text = w.buffered();
            try appendU32(&buf, @intCast(text.len));
            try buf.appendSlice(gpa, text);
        }
    }
    return buf.toOwnedSlice(gpa);
}

/// Pre-order collect a proto and all its nested protos into `out`.
fn collectProtos(out: *std.ArrayList(*const mahina.bytecode.Proto), proto: *const mahina.bytecode.Proto) !void {
    try out.append(gpa, proto);
    for (proto.protos) |child| try collectProtos(out, child);
}

/// Parse + compile only (no execution), collecting every diagnostic — errors and
/// warnings alike — into `res.diags`. Mirrors `run()`'s parse→Vm.init→compile
/// prefix; it deliberately stops before `vm.run`. A parse/compile *failure*
/// (returned error from the frontend) is not itself a diagnostic source here —
/// the frontend records the reason into `diags` first, which we then surface.
fn check(res: *CheckResult, source: []const u8) !void {
    const src0 = try gpa.allocSentinel(u8, source.len, 0);
    defer gpa.free(src0);
    @memcpy(src0, source);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    // Parse. On a hard parse error the tree is unusable, but the diagnostics are
    // already recorded — fall through to emit them.
    var tree_opt: ?mahina.ast.Ast = mahina.parser.parse(gpa, src0, &diags) catch null;
    defer if (tree_opt) |*t| t.deinit();

    // Only attempt compilation if parsing produced a usable tree with no errors;
    // the compiler needs a heap to intern string constants into.
    //
    // The chunk is kept alive until after `collectDiags` (deferred deinit): the
    // unknown-global lint allocates its messages in the chunk arena, and
    // `collectDiags` dupes them out — freeing the chunk first would be a
    // use-after-free.
    var vm_opt: ?mahina.interp.Vm = null;
    defer if (vm_opt) |*vm| vm.deinit();
    var chunk_opt: ?mahina.compiler.Chunk = null;
    defer if (chunk_opt) |*c| c.deinit();

    if (tree_opt) |tree| {
        if (!diags.hasErrors()) {
            vm_opt = try mahina.interp.Vm.init(gpa);
            chunk_opt = mahina.compiler.compileWithOptions(gpa, vm_opt.?.heap, src0, tree.root, &diags, .{
                .known_globals = &mahina.interp.builtin_global_names,
            }) catch null;
        }
    }

    res.diags = try collectDiags(&diags);
    res.status = if (diags.hasErrors()) 1 else 0;
}

/// Flatten a `Diagnostics` list into an owned `[]Diag` (each `msg` duped). The
/// returned `Buf.len` is the record *count*. On any allocation failure, frees
/// what was built so far and propagates the error.
fn collectDiags(diags: *const Diagnostics) !Buf {
    const items = diags.list.items;
    if (items.len == 0) return .{};

    const out = try gpa.alloc(Diag, items.len);
    errdefer gpa.free(out);

    var filled: usize = 0;
    errdefer for (out[0..filled]) |d| freeBuf(d.msg);

    for (items, 0..) |d, i| {
        const msg = try gpa.dupe(u8, d.message);
        out[i] = .{
            .severity = @intFromEnum(d.severity),
            .start = d.start,
            .end = d.end,
            .line = d.line,
            .msg = bufFromSlice(msg),
        };
        filled = i + 1;
    }

    return .{ .ptr = @intCast(@intFromPtr(out.ptr)), .len = @intCast(out.len) };
}

/// Render every recorded diagnostic into one owned utf8 buffer (one per line,
/// `line: severity: message`). Mirrors `main.zig`'s `reportDiagnostics` but to a
/// string instead of stderr.
fn renderDiagnostics(diags: *const Diagnostics) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (diags.list.items) |d| {
        const line = try std.fmt.allocPrint(gpa, "{d}: {s}: {s}\n", .{ d.line, @tagName(d.severity), d.message });
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
    return buf.toOwnedSlice(gpa);
}

/// Serialize a runtime-error backtrace into a self-describing little-endian blob
/// for JS: `u32 frame_count`, then per frame (deepest-first)
/// `{ u32 line, u32 start, u32 end, u32 name_len, [name_len]u8 name }`. Empty
/// chain → empty slice (a null `Buf`).
fn encodeBacktrace(frames: []const mahina.interp.FaultFrame) ![]u8 {
    if (frames.len == 0) return &[_]u8{};
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try appendU32(&buf, @intCast(frames.len));
    for (frames) |f| {
        try appendU32(&buf, f.line);
        try appendU32(&buf, f.start);
        try appendU32(&buf, f.end);
        try appendU32(&buf, @intCast(f.name.len));
        try buf.appendSlice(gpa, f.name);
    }
    return buf.toOwnedSlice(gpa);
}

fn appendU32(buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

fn appendU16(buf: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}
