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
//!
//! Result layout (extern struct, read by JS via DataView):
//!   u32 status        0 = ok, 1 = error (see `diag` for the message)
//!   {u32 ptr,u32 len} stdout     program output (tab/newline formatted)
//!   {u32 ptr,u32 len} keyframe   binschema keyframe snapshot
//!   {u32 ptr,u32 len} effects    binschema effect log
//!   {u32 ptr,u32 len} trace      binschema trace cache
//!   {u32 ptr,u32 len} diag       human-readable diagnostics / error text (utf8)
//!
//! Each non-empty buffer is an independent `wasm_allocator` allocation; the
//! Result struct is one too. `lune_free_result` frees them all.

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

    // --- compile ---
    var chunk = lune.compiler.compile(gpa, &vm.heap, src0, tree.root, &diags) catch {
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
        res.diag = bufFromSlice(try gpa.dupe(u8, @errorName(err)));
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
