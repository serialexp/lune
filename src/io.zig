//! The one place that touches `std.Io`'s writer API.
//!
//! `std.Io` is the churning frontier of the toolchain (architecture principle
//! #4), and Zig is pre-1.0 — so the *shape* of "get a stdout writer and
//! print to it" is expected to move under us. Everything that depends on that
//! shape, plus the `Value` → text rendering, is funnelled through this module.
//! If a toolchain bump changes the writer API (or we change how a value prints),
//! this is the only file to touch — not a thousand call sites.
//!
//! It also carries the CLI's process stdout — what `print`/`io.write` reach
//! when no `Vm.out` seam is set — buffered C-stdio style (doc 65 §6), since a
//! script printing in a loop makes that path hot. The VM core does its own
//! buffered serialization for traces (binschema, Phase 5b).

const std = @import("std");
const value = @import("value.zig");
const string = @import("string.zig");
const Value = value.Value;

/// Generic byte-sink writer type. Re-exported so callers never name `std.Io`
/// directly — if the path changes, it changes here.
pub const Writer = std.Io.Writer;

/// The async/blocking I/O context type (vtable + userdata). Re-exported for the
/// same reason as `Writer`: callers (the CLI driver) hold one without naming
/// `std.Io` themselves.
pub const Io = std.Io;

/// On `wasm32-freestanding` (the browser VM, src/wasm_entry.zig) there is no
/// host stdout/stderr — and `std.Io.Threaded` doesn't even compile there
/// (no `getrandom`/`IOV_MAX`). The VM's print seam (`vm.out`) is always set on
/// that target, so the host-stdout fallback is never *called*; it only has to
/// *compile*. We give it a `Discarding` sink and prune the `std.Io.Threaded`
/// machinery out of the artifact via the comptime branches below.
const is_freestanding = @import("builtin").target.os.tag == .freestanding;

// A lazily-initialised discarding writer for the freestanding fallback. The
// small buffer is drain scratch; nothing is ever read back from it.
var fs_discarding: Writer.Discarding = undefined;
var fs_discard_buf: [64]u8 = undefined;
var fs_initialized = false;

fn fsWriter() *Writer {
    if (!fs_initialized) {
        fs_discarding = Writer.Discarding.init(&fs_discard_buf);
        fs_initialized = true;
    }
    return &fs_discarding.writer;
}

/// The stdout and stderr buffer size. With stdout fully buffered
/// (`Buffering.full`) this is how much output one `write` syscall drains.
/// Measured (doc 65 Phase 0; `bench/stdlib/io_print.lua`, `io_write.lua`):
/// 4 KiB already batches a million short `print`s into a few thousand
/// syscalls, and a bigger buffer makes 4 KiB `io.write` chunks get copied in
/// instead of going straight to the kernel — 32 KiB was ~1.7× slower than
/// 4 KiB writing 100 MB to a pipe.
const buffer_len = 4096;

/// How stdout is buffered (doc 65 §6) — C stdio's policy, which Lua inherits:
/// line-buffered on a terminal, so an interactive user sees each line as it is
/// printed, and fully buffered otherwise, so a program printing a million lines
/// into a pipe or file makes a few hundred syscalls, not a million.
pub const Buffering = enum { none, line, full };

// Process-global, lazily initialised stdout plumbing. A global (stable address)
// is required because the writer's vtable recovers the `File.Writer` from the
// `interface` field via `@fieldParentPtr`. Caching it also avoids re-installing
// signal handlers on every `print` (a side effect of `Io.Threaded.init`).
var threaded: std.Io.Threaded = undefined;
var file_writer: std.Io.File.Writer = undefined;
var stdout_buffer: [buffer_len]u8 = undefined;
var stdout_buffering: Buffering = .full;
var initialized = false;

// stdout and stderr are *streaming* writers, not std's default positional ones.
// A positional writer tracks its own file offset and writes at it (`pwritev`),
// so when both streams are the same file (`prog > log 2>&1`) each one starts at
// offset 0 and they overwrite each other. Streaming writes append at the
// file's shared position, like `write(2)` and C stdio.
fn ensureInit() void {
    if (initialized) return;
    threaded = .init(std.heap.page_allocator, .{});
    const file = std.Io.File.stdout();
    file_writer = file.writerStreaming(threaded.io(), &stdout_buffer);
    const tty = file.isTty(threaded.io()) catch false;
    stdout_buffering = if (tty) .line else .full;
    initialized = true;
}

// Lazily-initialised stderr plumbing, mirroring stdout. Shares the one
// `std.Io.Threaded` context (created by `ensureInit`).
var stderr_writer: std.Io.File.Writer = undefined;
var stderr_buffer: [buffer_len]u8 = undefined;
var stderr_initialized = false;

fn ensureStderr() void {
    if (stderr_initialized) return;
    ensureInit(); // shares the threaded io context
    stderr_writer = std.Io.File.stderr().writerStreaming(threaded.io(), &stderr_buffer);
    stderr_initialized = true;
}

/// The buffered stdout writer. Output is not guaranteed visible until `flush()`
/// (or use `print`, which flushes for you). A program-output write through it
/// ends with `stdoutWrote`, which applies the buffering policy.
pub fn stdout() *Writer {
    if (is_freestanding) {
        return fsWriter();
    } else {
        ensureInit();
        return &file_writer.interface;
    }
}

/// Flush buffered stdout. No-op if nothing was ever written.
pub fn flush() void {
    if (is_freestanding) {
        return;
    } else {
        if (!initialized) return;
        file_writer.interface.flush() catch {};
    }
}

/// Set by the first `flushForPanic`, so a panic raised *inside* that flush
/// (stdout writer state the panic itself corrupted) doesn't try again.
var panic_flushed = false;

/// `flush()` for a panic handler (the CLI's `panic` in `main.zig`): push out
/// what the program printed before the crash, at most once per process. A
/// segfault in native code still loses the buffer; there is no safe point to
/// flush from there.
pub fn flushForPanic() void {
    if (panic_flushed) return;
    panic_flushed = true;
    flush();
}

/// End of one program-output write to `stdout()` (`print`, `io.write`): flush
/// it if the buffering policy says so. `newline` is whether the write
/// contained a `\n`, which is what flushes a line-buffered stdout. A fully
/// buffered stdout drains only when its buffer fills, on `flush()` (`io.flush`,
/// CLI teardown), or before anything is written to stderr (`stderrWriter`).
pub fn stdoutWrote(newline: bool) void {
    switch (stdout_buffering) {
        .none => flush(),
        .line => if (newline) flush(),
        .full => {},
    }
}

/// printf-style line to stdout, flushed immediately. Swallows I/O errors —
/// failing to print a banner is not the VM's problem. For explicit error
/// handling, use `stdout()` directly.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const w = stdout();
    w.print(fmt, args) catch {};
    flush();
}

/// The buffered stderr writer. Diagnostics and CLI error messages go here so
/// they don't interleave with a program's stdout. Getting it flushes stdout
/// first, so when both go to one place (`2>&1`, a terminal) what the program
/// printed before an error or warning appears before it, buffered or not.
pub fn stderrWriter() *Writer {
    if (is_freestanding) {
        return fsWriter();
    } else {
        flush();
        ensureStderr();
        return &stderr_writer.interface;
    }
}

/// printf-style line to stderr, flushed immediately. Swallows I/O errors.
pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    const w = stderrWriter();
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

/// Largest source file the CLI will load (a sanity bound, not a language limit).
pub const max_source_bytes: usize = 64 * 1024 * 1024;

/// Read an entire source file into a NUL-terminated buffer — the `[:0]const u8`
/// form the lexer wants. File access is churny `std.Io` surface, funnelled here
/// with the rest of this module. Caller owns the returned buffer (free with
/// `gpa`). Reads larger than `max_source_bytes` fail with `error.StreamTooLong`.
pub fn readFileZ(gpa: std.mem.Allocator, io: Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        Io.Limit.limited(max_source_bytes),
        .of(u8),
        0,
    );
}

/// Write `data` to `path`, creating/truncating it. The symmetric counterpart of
/// `readFileZ`; funnels the churny `std.Io` file-write surface through this one
/// module. Used by the CLI's `--emit-traces` to drop a serialized trace cache.
pub fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// The `Io` behind the host primitives below: std's prebuilt single-threaded
/// instance. Unlike `Io.Threaded.init` it installs no signal handlers, which
/// matters in libmahina, where the process belongs to the host. Its clock is
/// stateless and its entropy calls lock internally, so any thread may call
/// these.
fn hostIo() Io {
    if (is_freestanding) @compileError("no host clock or entropy on freestanding");
    return std.Io.Threaded.global_single_threaded.io();
}

/// The host's monotonic clock in nanoseconds from an unspecified start
/// (`CLOCK_MONOTONIC` on Linux, `CLOCK_UPTIME_RAW` on macOS, QPC on Windows):
/// what the CLI and libmahina inject as `Vm.clock_source`.
pub fn monotonicNs() i64 {
    return @intCast(std.Io.Clock.awake.now(hostIo()).nanoseconds);
}

/// Fill `buf` with fresh OS entropy (`getrandom` on Linux), falling back to
/// std's process CSPRNG if the OS has none to give: what the CLI and
/// libmahina inject as `Vm.random_seed_source`.
pub fn hostEntropy(buf: []u8) void {
    const io = hostIo();
    std.Io.randomSecure(io, buf) catch std.Io.random(io, buf);
}

/// Render a `Value` to `w` in a human-readable, debugger-friendly form. The
/// canonical text form of a value lives here (one place), separate from the
/// `Value` type itself so the type stays free of the churny writer dependency.
pub fn writeValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.tag) {
        .nil => try w.writeAll("nil"),
        .boolean => try w.writeAll(if (v.asBool()) "true" else "false"),
        .int => try w.print("{d}", .{v.asInt()}),
        .float => try w.print("{d}", .{v.asFloat()}),
        .heap_ref => switch (v.heapType()) {
            // Strings print as their raw bytes (Lua `print`/`tostring` style).
            .string => try w.writeAll(string.String.fromHeader(v.asHeap()).bytes()),
            // Other objects: kind + identity (e.g. "table: 0x3"). The identity is
            // the object's stable, heap-assigned `id` — NOT its address — so the
            // output is deterministic and reproducible run-to-run, never leaking
            // ASLR into a program's observable behaviour (docs/design/02).
            else => try w.print("{s}: 0x{x}", .{
                @tagName(v.heapType()),
                v.asHeap().id,
            }),
        },
        // A transient grid row handle. Diagnostic form only — Phase 3 makes
        // `tostring(a[i])` render exactly like a table. Identity is the parent's
        // stable id + the row, never an address (determinism).
        .row_view => try w.print("table: 0x{x}#{d}", .{ v.rowViewParent().id, v.rowViewRow() }),
    }
}

/// Convenience: print a `Value` to stdout followed by a newline.
pub fn printValue(v: Value) void {
    const w = stdout();
    writeValue(w, v) catch {};
    w.writeAll("\n") catch {};
    flush();
}

// ---------------------------------------------------------------------------
// Tests — exercise the formatting logic against an in-memory writer so they
// never depend on a real stdout.
// ---------------------------------------------------------------------------

fn renderValue(buf: []u8, v: Value) []const u8 {
    var w = Writer.fixed(buf);
    writeValue(&w, v) catch unreachable;
    return w.buffered();
}

test "writeValue renders scalars" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("nil", renderValue(&buf, Value.nil()));
    try std.testing.expectEqualStrings("true", renderValue(&buf, Value.boolean(true)));
    try std.testing.expectEqualStrings("false", renderValue(&buf, Value.boolean(false)));
    try std.testing.expectEqualStrings("-42", renderValue(&buf, Value.int(-42)));
    try std.testing.expectEqualStrings("3.5", renderValue(&buf, Value.float(3.5)));
}

test "writeValue prints a real string's bytes" {
    const str = try string.String.create(std.testing.allocator, "hello");
    defer str.destroy(std.testing.allocator);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", renderValue(&buf, Value.heap(&str.header)));
}

test "writeValue renders other heap kinds with kind + identity" {
    const object = @import("object.zig");
    var hdr = object.GcHeader.init(.table);
    var buf: [64]u8 = undefined;
    const s = renderValue(&buf, Value.heap(&hdr));
    // e.g. "table: 0x7ffd…"
    try std.testing.expect(std.mem.startsWith(u8, s, "table: 0x"));
}
