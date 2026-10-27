//! The CLI's `aio` host (doc 73 §7.6): runs the operations `stdlib/aio.zig`
//! starts while the program goes on. The one file that uses threads (Rule
//! Z-2): a few workers do the file operations, each on a descriptor of its
//! own, and the timers live in a min-heap on the waiting thread, which
//! waits on a condition until the earliest deadline.
//!
//! The VM thread calls `start` and `next`; the workers touch only the job
//! queues, under `mutex`. A job is one allocation, which moves from the
//! request queue to the completion queue and is freed by the `next` after
//! the one that returned it (its bytes are borrowed until then). The
//! allocator must be thread-safe (the process allocator, not a
//! `mem.TrackingAllocator`, so `--mem-stats` does not count these buffers).
//!
//! Never compiled into the wasm build.

const std = @import("std");
const seam = @import("system.zig");
const host_system = @import("host_system.zig");

const Io = std.Io;
const AsyncHost = seam.AsyncHost;

pub const AioHost = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// Signalled when a job is queued or the host closes; workers wait on it.
    work: Io.Condition = .init,
    /// Signalled when a job finishes; `next` waits on it.
    finished: Io.Condition = .init,
    /// Queued file jobs, oldest first (under `mutex`).
    queued: Queue = .{},
    /// Finished file jobs, oldest first (under `mutex`).
    done: Queue = .{},
    closing: bool = false,
    workers: [worker_count]std.Thread = undefined,
    nworkers: usize = 0,
    /// File jobs started and not yet returned by `next` (VM thread only).
    outstanding: usize = 0,
    /// The sleeps, earliest deadline first (VM thread only).
    timers: Timers = .empty,
    /// Breaks deadline ties in start order.
    timer_seq: u64 = 0,
    /// The job the last `next` returned, freed by the next one.
    last: ?*Job = null,

    /// How many workers run file jobs at once. Started on the first one.
    pub const worker_count = 4;

    const Job = struct {
        next: ?*Job = null,
        id: AsyncHost.OpId,
        path: []u8,
        /// What a write writes (owned), or empty.
        data: []u8,
        op: enum { read, write, append },
        outcome: AsyncHost.Outcome = .done,
        /// A read's contents (owned), once it is done.
        bytes: ?[]u8 = null,
    };

    const Queue = struct {
        head: ?*Job = null,
        tail: ?*Job = null,

        fn push(q: *Queue, j: *Job) void {
            j.next = null;
            if (q.tail) |t| t.next = j else q.head = j;
            q.tail = j;
        }

        fn pop(q: *Queue) ?*Job {
            const j = q.head orelse return null;
            q.head = j.next;
            if (q.head == null) q.tail = null;
            return j;
        }
    };

    const Timer = struct { deadline: i96, seq: u64, id: AsyncHost.OpId };
    const Timers = std.PriorityQueue(Timer, void, struct {
        fn order(_: void, a: Timer, b: Timer) std.math.Order {
            return switch (std.math.order(a.deadline, b.deadline)) {
                .eq => std.math.order(a.seq, b.seq),
                else => |o| o,
            };
        }
    }.order);

    /// `gpa` must be thread-safe; `io` must work from any thread.
    pub fn init(gpa: std.mem.Allocator, io: Io) AioHost {
        return .{ .gpa = gpa, .io = io };
    }

    /// Stop the workers (each finishes the job it is on) and drop
    /// everything still queued, finished or timed.
    pub fn deinit(self: *AioHost) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.work.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.workers[0..self.nworkers]) |t| t.join();
        while (self.queued.pop()) |j| self.free(j);
        while (self.done.pop()) |j| self.free(j);
        if (self.last) |j| self.free(j);
        self.timers.deinit(self.gpa);
    }

    pub fn host(self: *AioHost) AsyncHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: AsyncHost.VTable = .{ .start = &start, .next = &next };

    fn of(ctx: *anyopaque) *AioHost {
        return @ptrCast(@alignCast(ctx));
    }

    fn free(self: *AioHost, j: *Job) void {
        self.gpa.free(j.path);
        self.gpa.free(j.data);
        if (j.bytes) |b| self.gpa.free(b);
        self.gpa.destroy(j);
    }

    fn now(self: *AioHost) i96 {
        return Io.Clock.awake.now(self.io).nanoseconds;
    }

    fn start(ctx: *anyopaque, id: AsyncHost.OpId, request: AsyncHost.Request) bool {
        const self = of(ctx);
        switch (request) {
            .sleep => |ns| {
                const deadline = self.now() +| @as(i96, ns);
                self.timers.push(self.gpa, .{ .deadline = deadline, .seq = self.timer_seq, .id = id }) catch return false;
                self.timer_seq += 1;
                return true;
            },
            .read => |path| return self.queue(id, .read, path, ""),
            .write => |w| return self.queue(id, if (w.append) .append else .write, w.path, w.data),
        }
    }

    fn queue(self: *AioHost, id: AsyncHost.OpId, op: @FieldType(Job, "op"), path: []const u8, data: []const u8) bool {
        if (self.nworkers == 0 and !self.spawnWorkers()) return false;
        const j = self.gpa.create(Job) catch return false;
        const p = self.gpa.dupe(u8, path) catch {
            self.gpa.destroy(j);
            return false;
        };
        const d = self.gpa.dupe(u8, data) catch {
            self.gpa.free(p);
            self.gpa.destroy(j);
            return false;
        };
        j.* = .{ .id = id, .path = p, .data = d, .op = op };
        self.mutex.lockUncancelable(self.io);
        self.queued.push(j);
        self.work.signal(self.io);
        self.mutex.unlock(self.io);
        self.outstanding += 1;
        return true;
    }

    /// Start the workers; false if not even one would start.
    fn spawnWorkers(self: *AioHost) bool {
        while (self.nworkers < worker_count) : (self.nworkers += 1) {
            self.workers[self.nworkers] = std.Thread.spawn(.{}, worker, .{self}) catch break;
        }
        return self.nworkers > 0;
    }

    fn worker(self: *AioHost) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (self.queued.head == null and !self.closing) self.work.waitUncancelable(self.io, &self.mutex);
            if (self.closing) return;
            const j = self.queued.pop().?;
            self.mutex.unlock(self.io);
            self.run(j);
            self.mutex.lockUncancelable(self.io);
            self.done.push(j);
            self.finished.signal(self.io);
        }
    }

    /// Do job `j` (on a worker, outside the lock).
    fn run(self: *AioHost, j: *Job) void {
        const cwd = Io.Dir.cwd();
        switch (j.op) {
            .read => {
                const bytes = cwd.readFileAlloc(self.io, j.path, self.gpa, .unlimited) catch |e| {
                    j.outcome = .{ .fail = host_system.RealSystem.classOf(e) };
                    return;
                };
                j.bytes = bytes;
                j.outcome = .{ .bytes = bytes };
            },
            .write, .append => {
                const file = cwd.createFile(self.io, j.path, .{ .truncate = j.op == .write }) catch |e| {
                    j.outcome = .{ .fail = host_system.RealSystem.classOf(e) };
                    return;
                };
                defer file.close(self.io);
                const at = if (j.op == .append) file.length(self.io) catch |e| {
                    j.outcome = .{ .fail = host_system.RealSystem.classOf(e) };
                    return;
                } else 0;
                file.writePositionalAll(self.io, j.data, at) catch |e| {
                    j.outcome = .{ .fail = host_system.RealSystem.classOf(e) };
                    return;
                };
                j.outcome = .done;
            },
        }
    }

    fn next(ctx: *anyopaque) AsyncHost.Completion {
        const self = of(ctx);
        if (self.last) |j| self.free(j);
        self.last = null;
        std.debug.assert(self.outstanding > 0 or self.timers.count() > 0);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.done.pop()) |j| {
                self.outstanding -= 1;
                self.last = j;
                return .{ .id = j.id, .outcome = j.outcome };
            }
            if (self.timers.peek()) |t| {
                if (t.deadline <= self.now()) {
                    _ = self.timers.pop();
                    return .{ .id = t.id, .outcome = .done };
                }
                const deadline: Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = t.deadline }, .clock = .awake };
                self.finished.waitTimeout(self.io, &self.mutex, .{ .deadline = deadline }) catch {};
            } else {
                self.finished.waitUncancelable(self.io, &self.mutex);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: the real OS, in a scratch directory under `.zig-cache/tmp`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const mio = @import("io.zig");

fn scratchPath(buf: []u8, tmp: *const testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache{c}tmp{c}{s}{c}{s}", .{ std.fs.path.sep, std.fs.path.sep, &tmp.sub_path, std.fs.path.sep, name }) catch unreachable;
}

test "aio host: sleeps finish in deadline order, ties in start order" {
    var h = AioHost.init(testing.allocator, mio.hostIo());
    defer h.deinit();
    const ah = h.host();
    try testing.expect(ah.vtable.start(ah.ctx, 1, .{ .sleep = 20 * std.time.ns_per_ms }));
    try testing.expect(ah.vtable.start(ah.ctx, 2, .{ .sleep = 0 }));
    try testing.expect(ah.vtable.start(ah.ctx, 3, .{ .sleep = 0 }));
    for ([_]AsyncHost.OpId{ 2, 3, 1 }) |want| {
        const c = ah.vtable.next(ah.ctx);
        try testing.expectEqual(want, c.id);
        try testing.expect(c.outcome == .done);
    }
}

test "aio host: write, append and read a file; failures are classes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = AioHost.init(testing.allocator, mio.hostIo());
    defer h.deinit();
    const ah = h.host();
    var buf: [256]u8 = undefined;
    const f = scratchPath(&buf, &tmp, "f.txt");
    try testing.expect(ah.vtable.start(ah.ctx, 1, .{ .write = .{ .path = f, .data = "hello", .append = false } }));
    try testing.expectEqual(@as(AsyncHost.OpId, 1), ah.vtable.next(ah.ctx).id);
    try testing.expect(ah.vtable.start(ah.ctx, 2, .{ .write = .{ .path = f, .data = ", world", .append = true } }));
    try testing.expectEqual(@as(AsyncHost.OpId, 2), ah.vtable.next(ah.ctx).id);
    try testing.expect(ah.vtable.start(ah.ctx, 3, .{ .read = f }));
    const r = ah.vtable.next(ah.ctx);
    try testing.expectEqual(@as(AsyncHost.OpId, 3), r.id);
    try testing.expectEqualStrings("hello, world", r.outcome.bytes);
    var mbuf: [256]u8 = undefined;
    const missing = scratchPath(&mbuf, &tmp, "missing.txt");
    try testing.expect(ah.vtable.start(ah.ctx, 4, .{ .read = missing }));
    const m = ah.vtable.next(ah.ctx);
    try testing.expectEqual(@as(AsyncHost.OpId, 4), m.id);
    try testing.expectEqual(seam.ErrorClass.not_found, m.outcome.fail);
}

test "aio host: many reads in flight all come back once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(mio.hostIo(), .{ .sub_path = "x", .data = "x" });
    var h = AioHost.init(testing.allocator, mio.hostIo());
    defer h.deinit();
    const ah = h.host();
    var buf: [256]u8 = undefined;
    const x = scratchPath(&buf, &tmp, "x");
    const n = 64;
    var seen: [n]bool = @splat(false);
    for (0..n) |i| try testing.expect(ah.vtable.start(ah.ctx, i, .{ .read = x }));
    for (0..n) |_| {
        const c = ah.vtable.next(ah.ctx);
        try testing.expect(!seen[c.id]);
        seen[c.id] = true;
        try testing.expectEqualStrings("x", c.outcome.bytes);
    }
}

test "aio host: closing with jobs queued and timers set drops them" {
    var h = AioHost.init(testing.allocator, mio.hostIo());
    const ah = h.host();
    try testing.expect(ah.vtable.start(ah.ctx, 1, .{ .sleep = std.time.ns_per_s * 3600 }));
    try testing.expect(ah.vtable.start(ah.ctx, 2, .{ .read = "does-not-exist" }));
    h.deinit();
}
