//! lune — wasm32-freestanding browser entry.
//!
//! A thin C-ABI surface over the library `run` path so the VM can execute a
//! lune source chunk *in the browser*, with no host I/O. It mirrors
//! `main.zig`'s `runSource` minus everything host-bound: there is no file read,
//! no stdout fd, no process exit — the program's `print` output is captured into
//! an in-memory `io.Writer.fixed` sink, and the run's artifacts (keyframe
//! snapshot, effect log, trace cache) are returned as owned byte buffers that
//! JS copies out of linear memory.
//!
//! Why this exists: wasm is the platform that *cannot* cheat on lune's own
//! determinism rules — there is no clock syscall here, so `clock()` is forced to
//! flow through the injected `ClockSource` (backed by a JS `host_now_ns` import),
//! exactly as `docs/design/02-determinism.md` intends. Two different engines
//! (this one and the native binary) agreeing byte-for-byte is the strongest
//! determinism check we have; see the dual-execution differential validator.
//!
//! ABI (all integers little-endian u32 unless noted; wasm32 ⇒ pointer == u32):
//!   import  env.host_now_ns() i64          — monotonic-ish ns from the host (JS)
//!   export  lune_alloc(len) -> ptr         — allocate `len` bytes in linear mem
//!   export  lune_free(ptr, len)            — free a prior `lune_alloc`
//!   export  lune_run(src_ptr, src_len) -> *Result
//!   export  lune_free_result(*Result)      — free a Result and all its buffers
//!   export  lune_check(src_ptr, src_len) -> *CheckResult
//!   export  lune_free_check_result(*CheckResult)
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
//! Result/CheckResult struct is one too. `lune_free_result` /
//! `lune_free_check_result` free them all.

const std = @import("std");
const lune = @import("lune");

const Diagnostics = lune.diag.Diagnostics;

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

/// A (pointer, length) pair into linear memory, as two u32s for JS DataView.
const Buf = extern struct {
    ptr: u32 = 0,
    len: u32 = 0,
};

/// The fixed result block JS reads after `lune_run`. See the file header.
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

/// The result of `lune_check`: a flat array of `Diag` (or null when clean). Note
/// `diags.len` is the *record count*, not a byte length.
const CheckResult = extern struct {
    status: u32 = 0,
    diags: Buf = .{},
};

/// Wrap an owned byte slice as a `Buf` (transfers ownership to JS; freed by
/// `lune_free_result`). An empty slice yields a null `Buf`.
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
export fn lune_dispatch_smoke(iterations: u32) u32 {
    return @intCast(lune.dispatch.run(@as(u64, iterations)));
}

/// Allocate `len` bytes of linear memory for JS to write a source chunk into.
/// Returns 0 on OOM. Free with `lune_free` (or it is consumed by `lune_run`,
/// which copies the source and frees nothing of the caller's — JS still owns it).
export fn lune_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const slice = gpa.alloc(u8, @as(usize, len)) catch return 0;
    return @intCast(@intFromPtr(slice.ptr));
}

/// Free a buffer obtained from `lune_alloc`.
export fn lune_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const p: [*]u8 = @ptrFromInt(@as(usize, ptr));
    gpa.free(p[0..@as(usize, len)]);
}

/// Parse, compile, and run a source chunk; return an owned `*Result` (0 on a
/// catastrophic allocation failure before a Result exists). The source bytes at
/// `[src_ptr, src_ptr+src_len)` are read but not freed — JS still owns that
/// buffer and frees it with `lune_free`.
export fn lune_run(src_ptr: u32, src_len: u32) ?*Result {
    const res = gpa.create(Result) catch return null;
    res.* = .{};

    const src: []const u8 = blk: {
        if (src_len == 0) break :blk &[_]u8{};
        const p: [*]const u8 = @ptrFromInt(@as(usize, src_ptr));
        break :blk p[0..@as(usize, src_len)];
    };

    run(res, src) catch |err| {
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
export fn lune_free_result(res: ?*Result) void {
    const r = res orelse return;
    freeBuf(r.stdout);
    freeBuf(r.keyframe);
    freeBuf(r.effects);
    freeBuf(r.trace);
    freeBuf(r.diag);
    freeBuf(r.backtrace);
    gpa.destroy(r);
}

/// Parse + compile a source chunk and return its diagnostics — *without running
/// it*. This is the editor's live-validation entry: it stops after the frontend,
/// so there are no side effects and a user's infinite loop can never hang the
/// tab. Returns 0 only on a catastrophic allocation failure before a CheckResult
/// exists. The source bytes are read but not freed (JS still owns them).
export fn lune_check(src_ptr: u32, src_len: u32) ?*CheckResult {
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
export fn lune_free_check_result(res: ?*CheckResult) void {
    const r = res orelse return;
    if (r.diags.len != 0) {
        const base: [*]Diag = @ptrFromInt(@as(usize, r.diags.ptr));
        const diags = base[0..@as(usize, r.diags.len)];
        for (diags) |d| freeBuf(d.msg);
        gpa.free(diags);
    }
    gpa.destroy(r);
}

// --- the run path (mirrors main.zig runSource, host-free) ------------------

fn run(res: *Result, source: []const u8) !void {
    // The lexer wants a NUL-terminated `[:0]const u8`. Copy the borrowed source
    // into an owned, sentinel-terminated buffer.
    const src0 = try gpa.allocSentinel(u8, source.len, 0);
    defer gpa.free(src0);
    @memcpy(src0, source);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    // --- parse ---
    var tree = lune.parser.parse(gpa, src0, &diags) catch {
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
    var vm = try lune.interp.Vm.init(gpa);
    defer vm.deinit();

    // Capture program output into an in-memory sink — there is no host stdout.
    var out_buf: [64 * 1024]u8 = undefined;
    var sink = lune.io.Writer.fixed(&out_buf);
    vm.out = &sink;

    // Mirror the native `--emit-traces --emit-keyframe --emit-effects` run:
    // trace recording + execution on, effect recording on, clock injected.
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.effect_mode = .record;
    vm.clock_source = .{ .ctx = &clock_ctx, .nowNs = &wasmClockNs };
    vm.random_seed_source = .{ .ctx = &rng_ctx, .seed = &wasmRandomSeed };

    // --- compile --- (pass builtin globals so the unknown-global lint doesn't
    // flag `print`/`clock`).
    var chunk = lune.compiler.compileWithOptions(gpa, &vm.heap, src0, tree.root, &diags, .{
        .known_globals = &lune.interp.builtin_global_names,
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

    // --- run ---
    _ = vm.run(chunk.proto) catch |err| {
        res.status = 1;
        // Located, Lua-style message from the un-popped faulting frame. The
        // message is freshly `gpa`-allocated by `describeFault`, so hand its
        // ownership straight to the Result (freed by `lune_free_result`).
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
    res.keyframe = bufFromSlice(try lune.keyframeser.encodeSnapshot(gpa, &vm));
    res.effects = bufFromSlice(try lune.effectser.encodeFile(gpa, vm.effect_log.items));
    res.trace = bufFromSlice(try lune.traceser.encodeFile(gpa, vm.trace.cache.items));
    res.status = 0;
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
    var tree_opt: ?lune.ast.Ast = lune.parser.parse(gpa, src0, &diags) catch null;
    defer if (tree_opt) |*t| t.deinit();

    // Only attempt compilation if parsing produced a usable tree with no errors;
    // the compiler needs a heap to intern string constants into.
    //
    // The chunk is kept alive until after `collectDiags` (deferred deinit): the
    // unknown-global lint allocates its messages in the chunk arena, and
    // `collectDiags` dupes them out — freeing the chunk first would be a
    // use-after-free.
    var vm_opt: ?lune.interp.Vm = null;
    defer if (vm_opt) |*vm| vm.deinit();
    var chunk_opt: ?lune.compiler.Chunk = null;
    defer if (chunk_opt) |*c| c.deinit();

    if (tree_opt) |tree| {
        if (!diags.hasErrors()) {
            vm_opt = try lune.interp.Vm.init(gpa);
            chunk_opt = lune.compiler.compileWithOptions(gpa, &vm_opt.?.heap, src0, tree.root, &diags, .{
                .known_globals = &lune.interp.builtin_global_names,
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
fn encodeBacktrace(frames: []const lune.interp.FaultFrame) ![]u8 {
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
