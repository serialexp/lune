//! The stdio host for the language server (doc 74 §5.2): the thread and I/O
//! side of the sans-IO core in `server.zig`.
//!
//! Two threads. The **reader** (spawned) reads bytes, frames them, notes any
//! `$/cancelRequest`, and queues the bodies. The **worker** (the caller's
//! thread) pops bodies in arrival order, feeds the core, writes what comes
//! out, and sleeps on the queue's condition with the core's debounce deadline
//! as the timeout. Only the worker touches the core and the output, so
//! document edits apply in order and every positional request sees the version
//! it was sent against.
//!
//! This file and `io.zig`-style transports are the LSP's `std.Io` surface
//! (Rule Z-2); it is never compiled into the wasm host.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const server_mod = @import("server.zig");
const workspace = @import("workspace.zig");
const io_mod = @import("../io.zig");

const Io = std.Io;

/// Bytes in, bytes out. `read` returns 0 at end of input.
pub const Transport = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
    write: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!void,
    /// `read` always returns in bounded time (0 at the end), so `run` waits
    /// for the reader thread before it returns and nothing touches the
    /// allocator afterwards. Stdin can block forever after `exit`, so its
    /// reader is detached instead and lets go of its share when it wakes.
    joinable: bool = false,
};

pub const Config = struct {
    /// Largest accepted message body.
    max_body: usize = jsonrpc.FrameReader.default_max_body,
    /// Bytes of message bodies the reader may have queued before it waits for
    /// the worker. Bounds memory when the client outpaces analysis.
    max_queue_bytes: usize = 128 * 1024 * 1024,
    /// Diagnostics for the operator (stderr; stdout is the protocol).
    log: *const fn ([]const u8) void = logStderr,
    /// Monotonic milliseconds.
    clock: *const fn () u64 = monotonicMs,
    /// The global names the host installs, which are not flagged as undefined.
    known_globals: []const []const u8 = &.{},
};

/// The largest file the server reads: a `mahina.toml`, or a module `require`
/// reaches for its exports (doc 74 §7.4). Well past the 100k-line budget
/// (3 MB); a larger file is treated as unreadable.
const max_file_bytes = 16 << 20;

/// The disk, for `mahina.toml`, `require` resolution and module exports.
pub const disk: workspace.Files = .{ .read = diskRead, .exists = diskExists, .list = diskList, .stamp = diskStamp };

fn diskList(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const workspace.Files.DirEntry {
    const io = io_mod.hostIo();
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch return null;
    defer dir.close(io);
    var out: std.ArrayList(workspace.Files.DirEntry) = .empty;
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch return null) |e| {
        const kind: @FieldType(workspace.Files.DirEntry, "kind") = switch (e.kind) {
            .file => .file,
            .directory => .directory,
            else => continue,
        };
        const name = a.dupe(u8, e.name) catch return null;
        out.append(a, .{ .name = name, .kind = kind }) catch return null;
    }
    return out.items;
}

fn diskStamp(_: ?*anyopaque, path: []const u8) ?workspace.Files.Stamp {
    const st = Io.Dir.cwd().statFile(io_mod.hostIo(), path, .{}) catch return null;
    if (st.kind != .file) return null;
    return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}

fn diskRead(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8) ?[]u8 {
    // Missing, unreadable or too large: no config (the defaults apply), or no
    // exports.
    return Io.Dir.cwd().readFileAlloc(io_mod.hostIo(), path, a, Io.Limit.limited(max_file_bytes)) catch null;
}

fn diskExists(_: ?*anyopaque, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io_mod.hostIo(), path, .{}) catch return false;
    return st.kind == .file;
}

fn logStderr(msg: []const u8) void {
    io_mod.eprint("mahina lsp: {s}\n", .{msg});
}

pub fn monotonicMs() u64 {
    const ns = io_mod.monotonicNs();
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

/// stdin / stdout.
pub fn stdioTransport() Transport {
    return .{ .read = stdinRead, .write = stdoutWrite };
}

fn stdinRead(_: ?*anyopaque, buf: []u8) anyerror!usize {
    return Io.File.stdin().readStreaming(io_mod.hostIo(), &.{buf}) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => e,
    };
}

fn stdoutWrite(_: ?*anyopaque, bytes: []const u8) anyerror!void {
    return Io.File.stdout().writeStreamingAll(io_mod.hostIo(), bytes);
}

/// State shared by the two threads. Reference counted: the reader may be
/// blocked in `read` when the worker is done, and must outlive it safely.
const Shared = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// Signalled when a message is queued or input closes (worker waits).
    ready: Io.Condition = .init,
    /// Signalled when the worker drains the queue or stops (reader waits).
    room: Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty,
    head: usize = 0,
    queued_bytes: usize = 0,
    input_closed: bool = false,
    stopped: bool = false,
    cancelled: std.ArrayList(Cancel) = .empty,
    cfg: Config,
    transport: Transport,
    refs: std.atomic.Value(u32) = .init(2),

    const Cancel = union(enum) { int: i64, string: []u8 };
    const max_cancels = 1024;

    fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.queue.items[self.head..]) |b| self.gpa.free(b);
        self.queue.deinit(self.gpa);
        for (self.cancelled.items) |c| if (c == .string) self.gpa.free(c.string);
        self.cancelled.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn lock(self: *Shared) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Shared) void {
        self.mutex.unlock(self.io);
    }

    /// Reader side: remember that request `id` was cancelled.
    fn noteCancel(self: *Shared, id: jsonrpc.Id) void {
        const entry: Cancel = switch (id) {
            .int => |i| .{ .int = i },
            .string => |s| .{ .string = self.gpa.dupe(u8, s) catch return },
        };
        self.lock();
        defer self.unlock();
        if (self.cancelled.items.len >= max_cancels) {
            const old = self.cancelled.orderedRemove(0);
            if (old == .string) self.gpa.free(old.string);
        }
        self.cancelled.append(self.gpa, entry) catch {
            if (entry == .string) self.gpa.free(entry.string);
        };
    }

    /// Worker side (the core's hook): was `id` cancelled? Consumes the mark.
    fn takeCancel(self: *Shared, id: jsonrpc.Id) bool {
        self.lock();
        defer self.unlock();
        for (self.cancelled.items, 0..) |c, i| {
            const hit = switch (c) {
                .int => |x| id == .int and id.int == x,
                .string => |x| id == .string and std.mem.eql(u8, x, id.string),
            };
            if (!hit) continue;
            const gone = self.cancelled.orderedRemove(i);
            if (gone == .string) self.gpa.free(gone.string);
            return true;
        }
        return false;
    }

    /// Reader side: queue a body (ownership passes). Waits while the queue is
    /// over its byte budget; returns false if the worker has stopped.
    fn push(self: *Shared, body: []u8) bool {
        self.lock();
        defer self.unlock();
        while (self.queued_bytes >= self.cfg.max_queue_bytes and !self.stopped) {
            self.room.waitUncancelable(self.io, &self.mutex);
        }
        if (self.stopped) {
            self.gpa.free(body);
            return false;
        }
        self.queue.append(self.gpa, body) catch {
            self.gpa.free(body);
            return true; // dropping one message beats dying; OOM is logged by the host
        };
        self.queued_bytes += body.len;
        self.ready.signal(self.io);
        return true;
    }

    fn closeInput(self: *Shared) void {
        self.lock();
        defer self.unlock();
        self.input_closed = true;
        self.ready.signal(self.io);
    }

    fn stop(self: *Shared) void {
        self.lock();
        defer self.unlock();
        self.stopped = true;
        self.room.broadcast(self.io);
    }

    /// Worker side. Caller holds the lock.
    fn popLocked(self: *Shared) ?[]u8 {
        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
            return null;
        }
        const b = self.queue.items[self.head];
        self.head += 1;
        self.queued_bytes -= b.len;
        self.room.signal(self.io);
        return b;
    }
};

fn readerMain(sh: *Shared) void {
    defer sh.release();
    readLoop(sh) catch |e| {
        var buf: [96]u8 = undefined;
        sh.cfg.log(std.fmt.bufPrint(&buf, "input stopped: {s}", .{@errorName(e)}) catch "input stopped");
    };
    sh.closeInput();
}

fn readLoop(sh: *Shared) !void {
    var frames = jsonrpc.FrameReader.init(sh.gpa);
    defer frames.deinit();
    frames.max_body = sh.cfg.max_body;
    const chunk = try sh.gpa.alloc(u8, 64 * 1024);
    defer sh.gpa.free(chunk);

    while (true) {
        const n = try sh.transport.read(sh.transport.ctx, chunk);
        if (n == 0) return;
        try frames.feed(chunk[0..n]);
        while (true) {
            const maybe = frames.next() catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.HeaderTooLong, error.BadHeader, error.BodyTooLong => {
                    sh.cfg.log(switch (e) {
                        error.HeaderTooLong => "dropped a message: header too long",
                        error.BadHeader => "dropped a message: bad header",
                        else => "dropped a message: body too large",
                    });
                    continue;
                },
            };
            const body = maybe orelse break;
            noteIfCancel(sh, body);
            const owned = try sh.gpa.dupe(u8, body);
            if (!sh.push(owned)) return;
        }
    }
}

/// Cheap gate first: only a body that mentions `$/cancelRequest` is parsed on
/// the reader thread.
fn noteIfCancel(sh: *Shared, body: []const u8) void {
    if (std.mem.find(u8, body, "$/cancelRequest") == null) return;
    var arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena.deinit();
    var bad: ?jsonrpc.Id = null;
    const msg = jsonrpc.parse(arena.allocator(), body, &bad) catch return;
    if (jsonrpc.cancelTarget(msg)) |id| sh.noteCancel(id);
}

fn cancelledHook(ctx: ?*anyopaque, id: jsonrpc.Id) bool {
    const sh: *Shared = @ptrCast(@alignCast(ctx.?));
    return sh.takeCancel(id);
}

/// Another message is already queued: an analysis under way is out of date.
fn inputPendingHook(ctx: ?*anyopaque) bool {
    const sh: *Shared = @ptrCast(@alignCast(ctx.?));
    sh.lock();
    defer sh.unlock();
    return sh.head < sh.queue.items.len;
}

/// Run the server until `exit` or end of input. Returns the process exit code.
pub fn run(gpa: std.mem.Allocator, transport: Transport, cfg: Config) !u8 {
    const sh = try gpa.create(Shared);
    sh.* = .{ .gpa = gpa, .io = io_mod.hostIo(), .cfg = cfg, .transport = transport };
    // The worker's reference is released on the way out; if the thread can't
    // start, both are.
    defer sh.release();
    const reader = std.Thread.spawn(.{}, readerMain, .{sh}) catch {
        sh.release();
        return error.ThreadSpawnFailed;
    };
    // A reader that may be blocked in `read` is detached; `Shared` is
    // ref-counted for that. One that cannot block is joined on the way out.
    if (!transport.joinable) reader.detach();
    defer {
        sh.stop();
        if (transport.joinable) reader.join();
    }

    var core = server_mod.Server.init(gpa, .{ .ctx = sh, .cancelled = cancelledHook, .input_pending = inputPendingHook });
    defer core.deinit();
    core.known_globals = cfg.known_globals;
    core.files = disk;
    var out = server_mod.Outbox.init(gpa);
    defer out.deinit();
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);

    while (!core.isDone()) {
        var item: ?[]u8 = null;
        var eof = false;
        {
            sh.lock();
            defer sh.unlock();
            while (true) {
                if (sh.popLocked()) |b| {
                    item = b;
                    break;
                }
                if (sh.input_closed) {
                    eof = true;
                    break;
                }
                const now = cfg.clock();
                if (core.nextDeadline()) |dl| {
                    if (dl <= now) break; // a debounce has run out
                    const wait: Io.Timeout = .{ .duration = .{
                        .raw = Io.Duration.fromMilliseconds(@intCast(dl - now)),
                        .clock = .awake,
                    } };
                    sh.ready.waitTimeout(sh.io, &sh.mutex, wait) catch {};
                } else {
                    sh.ready.waitUncancelable(sh.io, &sh.mutex);
                }
            }
        }

        out.reset();
        if (item) |b| {
            defer gpa.free(b);
            try core.handle(cfg.clock(), b, &out);
        } else if (eof) {
            core.inputClosed();
        }
        // After every message too, so a steady stream cannot starve a deadline.
        try core.tick(cfg.clock(), &out);

        if (!try flush(gpa, transport, &out, &wire, cfg)) core.inputClosed();
    }
    return core.exit_code orelse 1;
}

/// Frame and write everything in `out` with one write. False if the peer is
/// gone.
fn flush(
    gpa: std.mem.Allocator,
    transport: Transport,
    out: *server_mod.Outbox,
    wire: *std.ArrayList(u8),
    cfg: Config,
) !bool {
    if (out.messages().len == 0) return true;
    wire.clearRetainingCapacity();
    for (out.messages()) |m| try jsonrpc.writeFrame(gpa, wire, m);
    transport.write(transport.ctx, wire.items) catch |e| {
        var buf: [96]u8 = undefined;
        cfg.log(std.fmt.bufPrint(&buf, "output stopped: {s}", .{@errorName(e)}) catch "output stopped");
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn quiet(_: []const u8) void {}

/// An in-memory client: scripted input, captured output, and an optional gate
/// that holds the input open until the server has answered something.
const Pipe = struct {
    gpa: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,
    /// Bytes handed out per `read` (1 = worst-case fragmentation).
    chunk: usize = 4096,
    out: std.ArrayList(u8) = .empty,
    // Hold input after `hold_at` until `released`.
    hold_at: ?usize = null,
    released: bool = false,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Release when this text appears in the output.
    release_on: ?[]const u8 = null,
    gave_up: bool = false,

    fn io(self: *Pipe) Io {
        _ = self;
        return io_mod.hostIo();
    }

    fn transport(self: *Pipe) Transport {
        // Every `read` returns, at worst after the hold's bounded wait.
        return .{ .ctx = self, .read = read, .write = write, .joinable = true };
    }

    fn read(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ctx.?));
        if (self.hold_at) |h| if (self.pos >= h) {
            self.mutex.lockUncancelable(self.io());
            defer self.mutex.unlock(self.io());
            // A generous bound: the test fails rather than hangs.
            var waited: usize = 0;
            while (!self.released and waited < 200) : (waited += 1) {
                self.cond.waitTimeout(self.io(), &self.mutex, .{ .duration = .{
                    .raw = Io.Duration.fromMilliseconds(50),
                    .clock = .awake,
                } }) catch {};
            }
            if (!self.released) {
                self.gave_up = true;
                return 0;
            }
            self.hold_at = null;
        };
        const end = if (self.hold_at) |h| h else self.input.len;
        if (self.pos >= end) return 0;
        const n = @min(@min(buf.len, self.chunk), end - self.pos);
        @memcpy(buf[0..n], self.input[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn write(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Pipe = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        try self.out.appendSlice(self.gpa, bytes);
        if (self.release_on) |needle| if (std.mem.find(u8, self.out.items, needle) != null) {
            self.released = true;
            self.cond.broadcast(self.io());
        };
    }

    fn deinit(self: *Pipe) void {
        self.out.deinit(self.gpa);
    }
};

fn frameInto(list: *std.ArrayList(u8), body: []const u8) !void {
    try jsonrpc.writeFrame(testing.allocator, list, body);
}

/// The bodies in a framed output stream.
fn bodiesOf(bytes: []const u8, arena: std.mem.Allocator) ![][]const u8 {
    var r = jsonrpc.FrameReader.init(testing.allocator);
    defer r.deinit();
    try r.feed(bytes);
    var list: std.ArrayList([]const u8) = .empty;
    while (try r.next()) |b| try list.append(arena, try arena.dupe(u8, b));
    return list.items;
}

test "session: initialize, open, shutdown, exit — fragmented one byte at a time" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"u\",\"version\":1,\"text\":\"x\"}}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var pipe = Pipe{ .gpa = testing.allocator, .input = input.items, .chunk = 1 };
    defer pipe.deinit();
    const code = try run(testing.allocator, pipe.transport(), .{ .log = quiet });
    try testing.expectEqual(@as(u8, 0), code);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bodies = try bodiesOf(pipe.out.items, arena.allocator());
    try testing.expectEqual(@as(usize, 2), bodies.len); // initialize + shutdown replies
    try testing.expect(std.mem.find(u8, bodies[0], "\"capabilities\"") != null);
    try testing.expect(std.mem.find(u8, bodies[1], "\"result\":null") != null);
}

test "session: end of input without exit is status 1" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    var pipe = Pipe{ .gpa = testing.allocator, .input = input.items };
    defer pipe.deinit();
    try testing.expectEqual(@as(u8, 1), try run(testing.allocator, pipe.transport(), .{ .log = quiet }));
}

test "session: garbage between messages is dropped and the stream recovers" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "Nonsense: 1\r\n\r\n");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try frameInto(&input, "{not json");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    var pipe = Pipe{ .gpa = testing.allocator, .input = input.items };
    defer pipe.deinit();
    _ = try run(testing.allocator, pipe.transport(), .{ .log = quiet });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bodies = try bodiesOf(pipe.out.items, arena.allocator());
    try testing.expectEqual(@as(usize, 2), bodies.len);
    try testing.expect(std.mem.find(u8, bodies[1], "-32700") != null); // the parse error reply
}

test "session: an oversize message is skipped, later ones still run" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"padding\":\"0123456789012345678901234567890123456789\"}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    var pipe = Pipe{ .gpa = testing.allocator, .input = input.items, .chunk = 5 };
    defer pipe.deinit();
    _ = try run(testing.allocator, pipe.transport(), .{ .log = quiet, .max_body = 64 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bodies = try bodiesOf(pipe.out.items, arena.allocator());
    try testing.expectEqual(@as(usize, 1), bodies.len);
    try testing.expect(std.mem.find(u8, bodies[0], "\"id\":2") != null);
}

test "debounce through the host: diagnostics arrive on the timer, with no further input" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"u\",\"version\":7,\"text\":\"x\"}}}");
    const hold = input.items.len;
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    // The input stalls after didOpen until publishDiagnostics has been written;
    // reaching that point means the worker woke on its own deadline. (A generous
    // bound in the pipe turns a hang into a failure.)
    var pipe = Pipe{
        .gpa = testing.allocator,
        .input = input.items,
        .hold_at = hold,
        .release_on = "publishDiagnostics",
    };
    defer pipe.deinit();
    _ = try run(testing.allocator, pipe.transport(), .{ .log = quiet });
    try testing.expect(!pipe.gave_up);
    try testing.expect(std.mem.find(u8, pipe.out.items, "\"version\":7") != null);
}

test "cancellation through the host: a cancelled request is answered as cancelled" {
    // `$/cancelRequest` is noted by the reader thread before the worker takes the
    // request it names. Whether the worker has already answered request 3 is a
    // race, so the test queues the cancel first (id 3 is not yet sent) and sends
    // the request after: the mark must be there when it is dispatched.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":3}}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}");
    try frameInto(&input, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    var pipe = Pipe{ .gpa = testing.allocator, .input = input.items };
    defer pipe.deinit();
    const code = try run(testing.allocator, pipe.transport(), .{ .log = quiet });
    // The cancelled shutdown was not performed, so `exit` finds the server running.
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.find(u8, pipe.out.items, "-32800") != null);
}
