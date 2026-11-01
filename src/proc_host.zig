//! The CLI's `proc` host (doc 75 §3, §3.5): runs one program to completion
//! with its stdio serviced concurrently, and hands back how it ended and
//! what it wrote. The one file that forks, polls and kills (Rule Z-2), and
//! POSIX only for now (Windows and the Darwin floor are Phase 6).
//!
//! The pieces, in the order a call uses them:
//!   - the child's environment, a whole `Environ.Map`: the given one, or the
//!     host's. The pinned Zig spawn resolves `argv[0]` against the *parent's*
//!     `PATH` and ignores the map's (`SpawnOptions.environ_map`), so this
//!     file searches `PATH` itself, in the child's environment, and hands
//!     the spawn the file it found (`Exe.explicit`).
//!   - the child leads its own process group (`pgid = 0`), so a timeout, a
//!     Ctrl-C and VM close can signal it and everything it started.
//!   - one `poll` loop feeds stdin and drains stdout and stderr together
//!     (a child that fills stderr while the parent reads stdout, or a stdin
//!     larger than a pipe, would deadlock a sequential reader). The captured
//!     streams keep only the latest `max_bytes` (`Tail`), and keep draining.
//!   - a `timeout` sends the group SIGTERM, then SIGKILL after a grace
//!     period, and gives up on the pipes a second later (a descendant that
//!     left the group can hold them open); the child is always reaped.
//!
//! The memory a result points into belongs to the `Capture` the caller keeps.

const std = @import("std");
const builtin = @import("builtin");
const seam = @import("system.zig");
const mio = @import("io.zig");

const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Whether this target can spawn at all.
pub const supported = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

/// How long a SIGTERM'd group has before SIGKILL, and how long after SIGKILL
/// the pipes are waited on.
const term_grace_ns: u64 = 500 * std.time.ns_per_ms;
const drain_grace_ns: u64 = 1000 * std.time.ns_per_ms;

/// The latest `cap` bytes written to a stream: a ring once it is full.
pub const Tail = struct {
    buf: std.ArrayList(u8) = .empty,
    cap: usize = 0,
    /// Where the oldest byte is, once the ring is full.
    head: usize = 0,
    /// Earlier bytes were dropped.
    dropped: bool = false,

    pub fn deinit(self: *Tail, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    pub fn reset(self: *Tail, cap: usize) void {
        self.buf.clearRetainingCapacity();
        self.cap = cap;
        self.head = 0;
        self.dropped = false;
    }

    pub fn push(self: *Tail, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        if (bytes.len == 0) return;
        if (self.cap == 0) {
            self.dropped = true;
            return;
        }
        if (bytes.len >= self.cap) {
            // Everything before these bytes, and any excess of them, goes.
            if (self.buf.items.len > 0 or bytes.len > self.cap) self.dropped = true;
            self.buf.clearRetainingCapacity();
            try self.buf.appendSlice(gpa, bytes[bytes.len - self.cap ..]);
            self.head = 0;
            return;
        }
        var rest = bytes;
        if (self.buf.items.len < self.cap) {
            const n = @min(rest.len, self.cap - self.buf.items.len);
            try self.buf.appendSlice(gpa, rest[0..n]);
            rest = rest[n..];
        }
        while (rest.len > 0) {
            const n = @min(rest.len, self.cap - self.head);
            @memcpy(self.buf.items[self.head..][0..n], rest[0..n]);
            self.head = (self.head + n) % self.cap;
            self.dropped = true;
            rest = rest[n..];
        }
    }

    /// The kept bytes in order. Valid until the next `push` or `reset`.
    pub fn finish(self: *Tail) []const u8 {
        if (self.head != 0) {
            std.mem.rotate(u8, self.buf.items, self.head);
            self.head = 0;
        }
        return self.buf.items;
    }
};

/// The most stages a pipeline has (`proc_max_stages`): up to three
/// descriptors a stage while it runs.
pub const max_stages = seam.proc_max_stages;

/// What a call leaves behind for its result to point into.
pub const Capture = struct {
    out: Tail = .{},
    /// One per stage.
    errs: std.ArrayList(Tail) = .empty,
    sigs: std.ArrayList([24]u8) = .empty,
    stages: std.ArrayList(seam.ProcStage) = .empty,

    pub fn deinit(self: *Capture, gpa: Allocator) void {
        self.out.deinit(gpa);
        for (self.errs.items) |*t| t.deinit(gpa);
        self.errs.deinit(gpa);
        self.sigs.deinit(gpa);
        self.stages.deinit(gpa);
    }

    /// Room for `n` stages, every stream empty and capped at `cap`.
    fn prepare(self: *Capture, gpa: Allocator, n: usize, cap: usize) Allocator.Error!void {
        self.out.reset(cap);
        while (self.errs.items.len < n) try self.errs.append(gpa, .{});
        for (self.errs.items[0..n]) |*t| t.reset(cap);
        try self.sigs.resize(gpa, n);
        try self.stages.resize(gpa, n);
    }
};

/// `SIGKILL`, `SIGSEGV`... by name, never by number: the numbers differ by
/// platform and a recording replays on any of them.
fn signalName(sig: u32, buf: *[24]u8) []const u8 {
    const info = @typeInfo(posix.SIG).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (sig == value) return "SIG" ++ name;
    }
    return std.fmt.bufPrint(buf, "SIG{d}", .{sig}) catch "SIG?";
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

fn setNonblocking(fd: posix.fd_t) void {
    const got = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    const flags: u32 = @intCast(@max(0, @as(isize, @intCast(got))));
    const nb: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    _ = posix.system.fcntl(fd, posix.F.SETFL, @as(usize, flags | nb));
}

fn nowNs() u64 {
    return @intCast(mio.monotonicNs());
}

/// How a start failure reads to the program.
fn startClass(err: anyerror) seam.ErrorClass {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.InvalidExe => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.IsDir => .is_a_directory,
        else => .other,
    };
}

/// Look `name` up on `path` ("a:b:c") the way `execvp` does: the first entry
/// holding an executable file of that name. A relative entry is relative to
/// the child's `cwd`. Null with `denied` set when a file was there but not
/// executable.
fn searchPath(io: Io, path: []const u8, name: []const u8, cwd: ?[]const u8, buf: []u8, denied: *bool) ?[]const u8 {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        const candidate = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch continue;
        var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const probe = if (cwd != null and dir[0] != '/')
            std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ cwd.?, candidate }) catch continue
        else
            candidate;
        Io.Dir.cwd().access(io, probe, .{ .execute = true }) catch |e| {
            if (e == error.AccessDenied or e == error.PermissionDenied) denied.* = true;
            continue;
        };
        return candidate;
    }
    return null;
}

/// The process environment as a map, for a host that has none of its own.
pub fn processEnviron(gpa: Allocator) Allocator.Error!std.process.Environ.Map {
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    if (comptime builtin.link_libc and supported) {
        var p: [*:null]?[*:0]u8 = std.c.environ;
        while (p[0]) |entry| : (p += 1) {
            const kv = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (eq == 0) continue;
            try map.put(kv[0..eq], kv[eq + 1 ..]);
        }
    }
    return map;
}

/// Escalation state for a child that outlived its deadline.
const Deadline = struct {
    /// When the program asked the call to end; null: never.
    at: ?u64,
    timed_out: bool = false,
    term_at: u64 = 0,
    sent_kill: bool = false,
    kill_at: u64 = 0,
    /// The pipes are no longer waited on.
    give_up: bool = false,

    /// Move through TERM → KILL → give up as `now` passes each point. The
    /// group is signalled, not just the child.
    fn step(self: *Deadline, pid: posix.pid_t, now: u64) void {
        if (!self.timed_out) {
            const at = self.at orelse return;
            if (now < at) return;
            self.timed_out = true;
            self.term_at = now;
            _ = posix.system.kill(-pid, .TERM);
            return;
        }
        if (!self.sent_kill and now >= self.term_at + term_grace_ns) {
            self.sent_kill = true;
            self.kill_at = now;
            _ = posix.system.kill(-pid, .KILL);
            return;
        }
        if (self.sent_kill and now >= self.kill_at + drain_grace_ns) self.give_up = true;
    }

    /// Milliseconds the next `poll` may sleep.
    fn pollTimeout(self: *const Deadline, now: u64) i32 {
        const next: ?u64 = if (!self.timed_out)
            self.at
        else if (!self.sent_kill)
            self.term_at + term_grace_ns
        else
            self.kill_at + drain_grace_ns;
        const t = next orelse return -1;
        if (t <= now) return 0;
        const ms = (t - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        return @intCast(@min(ms, std.math.maxInt(i32)));
    }
};

/// Ctrl-C while a call waits (doc 75 §6, Q12): the terminal delivers SIGINT
/// to mahina, the foreground group, not to the children in their own group.
/// While any call is waiting, a handler records it and the wait forwards it
/// to the children's group, then goes on waiting: the child may handle it, and
/// the call ends however the child does. The disposition is process-wide, so
/// it is installed by the first waiting call and restored by the last.
const Interrupt = struct {
    var flag: std.atomic.Value(bool) = .init(false);
    var users: std.atomic.Value(u32) = .init(0);
    var old: posix.Sigaction = undefined;

    /// How long a wait sleeps between looks at the flag: a signal does not cut
    /// short the `poll` below it (std retries it).
    const check_ms: i32 = 50;

    fn handler(_: posix.SIG) callconv(.c) void {
        flag.store(true, .release);
    }

    fn acquire() void {
        if (users.fetchAdd(1, .acq_rel) != 0) return;
        const act: posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.INT, &act, &old);
    }

    fn release() void {
        if (users.fetchSub(1, .acq_rel) == 1) posix.sigaction(.INT, &old, null);
    }

    /// Whether Ctrl-C arrived since the last look; forwards it to `pgid`.
    fn forward(pgid: posix.pid_t) void {
        if (flag.swap(false, .acq_rel)) _ = posix.system.kill(-pgid, .INT);
    }
};

/// This process's group.
fn ownPgrp() posix.pid_t {
    if (builtin.link_libc) {
        const C = struct {
            extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;
        };
        return C.getpgid(0);
    }
    return @intCast(posix.system.getpgid(0));
}

/// The terminal's foreground group (`tcgetpgrp`), or null when stdin is not a
/// terminal. libc builds call libc's, which std's wrapper does not reach.
fn ttyForeground() ?posix.pid_t {
    if (builtin.link_libc) {
        const C = struct {
            extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;
        };
        const g = C.tcgetpgrp(0);
        return if (g < 0) null else g;
    }
    return posix.tcgetpgrp(0) catch null;
}

fn ttySetForeground(pgrp: posix.pid_t) !void {
    if (builtin.link_libc) {
        const C = struct {
            extern "c" fn tcsetpgrp(fd: c_int, pgrp: posix.pid_t) c_int;
        };
        if (C.tcsetpgrp(0, pgrp) != 0) return error.NotATerminal;
        return;
    }
    try posix.tcsetpgrp(0, pgrp);
}

/// The terminal handed to a child that reads it (doc 75 §6): a child that
/// inherits stdin from a terminal we are the foreground group of becomes the
/// terminal's foreground group for its lifetime, or it would be stopped the
/// first time it read (`SIGTTIN`). The terminal then delivers Ctrl-C to it
/// directly. Handed back by `release`.
const Foreground = struct {
    saved: ?posix.pid_t = null,

    fn take(wanted: bool, pgid: posix.pid_t) Foreground {
        if (!wanted) return .{};
        const mine = ownPgrp();
        const fg = ttyForeground() orelse return .{};
        if (fg != mine) return .{};
        setForeground(pgid) catch return .{};
        // A child that read before it got the terminal is stopped: go on.
        _ = posix.system.kill(-pgid, .CONT);
        return .{ .saved = mine };
    }

    fn release(self: *Foreground) void {
        if (self.saved) |mine| setForeground(mine) catch {};
        self.saved = null;
    }

    /// `tcsetpgrp` from a background group raises SIGTTOU, so it is ignored
    /// around the call.
    fn setForeground(pgrp: posix.pid_t) !void {
        const ign: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
        var old: posix.Sigaction = undefined;
        posix.sigaction(.TTOU, &ign, &old);
        defer posix.sigaction(.TTOU, &old, null);
        try ttySetForeground(pgrp);
    }

    fn owns(self: *const Foreground) bool {
        return self.saved != null;
    }
};

const Pipes = struct {
    stdin: ?posix.fd_t = null,
    out: ?posix.fd_t = null,
    errs: [max_stages]?posix.fd_t = @splat(null),

    fn closeAll(self: *Pipes) void {
        if (self.stdin) |fd| closeFd(fd);
        self.stdin = null;
        if (self.out) |fd| closeFd(fd);
        self.out = null;
        for (&self.errs) |*p| {
            if (p.*) |fd| closeFd(fd);
            p.* = null;
        }
    }

    fn open(self: *const Pipes) bool {
        if (self.stdin != null or self.out != null) return true;
        for (self.errs) |p| if (p != null) return true;
        return false;
    }
};

/// One launched call: its children, the pipes to them and what they have
/// written so far. `run` makes one on the stack and waits for it at once; a
/// spawned background job (doc 75 Phase 3) is one on the heap that `advance`
/// moves along whenever the program looks at it.
pub const Job = struct {
    gpa: Allocator,
    n: usize = 0,
    pids: [max_stages]posix.pid_t = undefined,
    /// How each child ended, once it has been reaped.
    ended: [max_stages]?Reaped = @splat(null),
    pgid: posix.pid_t = 0,
    pipes: Pipes = .{},
    /// What the first stage's stdin is fed from, and how much has gone.
    input: []const u8 = "",
    input_owned: bool = false,
    fed: usize = 0,
    stdout_captured: bool = false,
    stderr_captured: bool = false,
    /// Where the captured streams collect; the result points into it.
    cap: *Capture,
    dl: Deadline,
    /// Every child is reaped and the pipes are closed.
    finished: bool = false,
    /// The pump hit an error that left the stream state unknown.
    failed: bool = false,

    pub fn init(gpa: Allocator, cap: *Capture) Job {
        return .{ .gpa = gpa, .cap = cap, .dl = .{ .at = null } };
    }

    /// Release the descriptors and the owned input. A job still running is
    /// `terminate`d first by whoever owns it.
    pub fn deinit(self: *Job) void {
        self.pipes.closeAll();
        if (self.input_owned) self.gpa.free(@constCast(self.input));
        self.input = "";
    }

    pub fn pid(self: *const Job) posix.pid_t {
        return self.pgid;
    }

    /// Whether the job still has to be waited on.
    pub fn running(self: *const Job) bool {
        return !self.finished;
    }

    /// Signal the whole group, unless every child has already been reaped:
    /// a reaped pid may be recycled, so a finished job is never signalled.
    pub fn signal(self: *Job, sig: posix.SIG) bool {
        if (self.finished) return false;
        _ = posix.system.kill(-self.pgid, sig);
        return true;
    }

    /// End the job now: SIGTERM, a moment to leave, then SIGKILL, and reap
    /// everything. For a VM that is closing with children still running.
    pub fn terminate(self: *Job) void {
        if (self.finished) return;
        _ = posix.system.kill(-self.pgid, .TERM);
        const give_up = nowNs() + term_grace_ns;
        var all = false;
        while (!all and nowNs() < give_up) {
            all = true;
            for (0..self.n) |i| {
                if (self.ended[i] == null) self.ended[i] = tryReap(self.pids[i]);
                if (self.ended[i] == null) all = false;
            }
            if (!all) _ = posix.poll(&.{}, 5) catch {};
        }
        if (!all) _ = posix.system.kill(-self.pgid, .KILL);
        var dl: Deadline = .{ .at = null };
        for (0..self.n) |i| {
            if (self.ended[i] == null) self.ended[i] = reap(self.pids[i], self.pgid, &dl, false);
        }
        self.pipes.closeAll();
        self.finished = true;
    }

    /// Move the job along. Blocking: until every pipe has closed and every
    /// child is reaped. Not blocking: one look at the pipes and the children.
    /// True once the job is finished.
    pub fn advance(self: *Job, block: bool, watch_stop: bool) bool {
        if (self.finished) return true;
        self.pump(block) catch {
            // Out of memory or a poll fault: end the children rather than leak them.
            _ = posix.system.kill(-self.pgid, .KILL);
            self.pipes.closeAll();
            self.failed = true;
        };
        if (self.pipes.open() and !self.dl.give_up and !self.failed) return false;
        // The pipes are done with (closed, or given up on).
        self.pipes.closeAll();
        for (0..self.n) |i| {
            if (self.ended[i] != null) continue;
            if (block) {
                self.ended[i] = reap(self.pids[i], self.pgid, &self.dl, watch_stop);
            } else {
                self.dl.step(self.pgid, nowNs());
                self.ended[i] = tryReap(self.pids[i]);
                if (self.ended[i] == null) return false;
            }
        }
        self.finished = true;
        return true;
    }

    /// Service the pipes until they have all closed (or the deadline gave up
    /// on them), or for one pass when not `block`ing: feed the input, drain
    /// the last stage's stdout and every stage's stderr into the tails.
    fn pump(self: *Job, block: bool) !void {
        const pipes = &self.pipes;
        const cap = self.cap;
        var scratch: [64 * 1024]u8 = undefined;
        // Which descriptor each poll entry is: 0 stdin, 1 stdout, 2 + i the
        // stderr of stage i.
        var fds: [max_stages + 2]posix.pollfd = undefined;
        var which: [max_stages + 2]u8 = undefined;
        while (pipes.open()) {
            const now = nowNs();
            self.dl.step(self.pgid, now);
            Interrupt.forward(self.pgid);
            if (self.dl.give_up) return;
            var n: usize = 0;
            if (pipes.stdin) |fd| {
                fds[n] = .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 };
                which[n] = 0;
                n += 1;
            }
            if (pipes.out) |fd| {
                fds[n] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
                which[n] = 1;
                n += 1;
            }
            for (pipes.errs, 0..) |p, i| {
                const fd = p orelse continue;
                fds[n] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
                which[n] = @intCast(2 + i);
                n += 1;
            }
            const wait_ms = self.dl.pollTimeout(now);
            const sleep_ms: i32 = if (!block) 0 else if (wait_ms < 0 or wait_ms > Interrupt.check_ms) Interrupt.check_ms else wait_ms;
            _ = try posix.poll(fds[0..n], sleep_ms);
            for (fds[0..n], which[0..n]) |pf, w| {
                if (pf.revents == 0) continue;
                if (w == 0) {
                    const fd = pipes.stdin.?;
                    if (pf.revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
                        // The child closed its stdin early: not an error.
                        closeFd(fd);
                        pipes.stdin = null;
                        continue;
                    }
                    const rc = posix.system.write(fd, self.input[self.fed..].ptr, self.input.len - self.fed);
                    switch (posix.errno(rc)) {
                        .SUCCESS => {
                            self.fed += @intCast(rc);
                            if (self.fed == self.input.len) {
                                closeFd(fd);
                                pipes.stdin = null;
                            }
                        },
                        .AGAIN, .INTR => {},
                        else => {
                            closeFd(fd);
                            pipes.stdin = null;
                        },
                    }
                    continue;
                }
                const slot = if (w == 1) &pipes.out else &pipes.errs[w - 2];
                const tail = if (w == 1) &cap.out else &cap.errs.items[w - 2];
                const fd = slot.*.?;
                const rc = posix.system.read(fd, &scratch, scratch.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        const got: usize = @intCast(rc);
                        if (got == 0) {
                            closeFd(fd);
                            slot.* = null;
                        } else try tail.push(self.gpa, scratch[0..got]);
                    },
                    .AGAIN, .INTR => {},
                    else => {
                        closeFd(fd);
                        slot.* = null;
                    },
                }
            }
            if (!block) return;
        }
    }

    /// What the finished job did. Slices point into `cap`.
    pub fn result(self: *Job) seam.ProcResult {
        if (self.failed) return .{ .fail = .{ .class = .other } };
        var truncated = self.stdout_captured and self.cap.out.dropped;
        for (0..self.n) |i| {
            const stderr_bytes: []const u8 = if (self.stderr_captured) blk: {
                if (self.cap.errs.items[i].dropped) truncated = true;
                break :blk self.cap.errs.items[i].finish();
            } else "";
            self.cap.stages.items[i] = .{
                .status = switch (self.ended[i].?) {
                    .exited => |c| .{ .exited = c },
                    .signaled => |sig| .{ .signaled = signalName(sig, &self.cap.sigs.items[i]) },
                },
                .stderr = stderr_bytes,
            };
        }
        return .{ .done = .{
            .stages = self.cap.stages.items,
            .stdout = if (self.stdout_captured) self.cap.out.finish() else "",
            .timed_out = self.dl.timed_out,
            .truncated = truncated,
        } };
    }
};

const Reaped = union(enum) { exited: u32, signaled: u32 };

/// One non-blocking look at whether `pid` has ended.
fn tryReap(pid: posix.pid_t) ?Reaped {
    while (true) {
        var status: if (builtin.link_libc) c_int else i32 = undefined;
        const rc = posix.system.wait4(pid, &status, @intCast(posix.W.NOHANG), null);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                const s: u32 = @bitCast(@as(i32, status));
                if (posix.W.IFSIGNALED(s)) return .{ .signaled = @intFromEnum(posix.W.TERMSIG(s)) };
                return .{ .exited = posix.W.EXITSTATUS(s) };
            },
            .INTR => continue,
            // Already reaped: nothing more to learn.
            else => return .{ .exited = 0 },
        }
    }
}

/// Wait for the child to end. With no deadline pending this blocks; with one
/// it polls, escalating when the deadline passes. `pgid` is the group the
/// deadline and Ctrl-C signal. With `watch_stop` (the child owns the
/// terminal) a child that stops (Ctrl-Z) cannot be waited on for ever: until
/// there is job control (doc 75 Phase 5) it is killed and reported as ended by
/// the stopping signal.
fn reap(pid: posix.pid_t, pgid: posix.pid_t, dl: *Deadline, watch_stop: bool) Reaped {
    var stopped_by: ?u32 = null;
    while (true) {
        Interrupt.forward(pgid);
        const blocking = dl.at == null and !dl.timed_out;
        var status: if (builtin.link_libc) c_int else i32 = undefined;
        var options: u32 = if (blocking) 0 else posix.W.NOHANG;
        if (watch_stop) options |= posix.W.UNTRACED;
        const rc = posix.system.wait4(pid, &status, @intCast(options), null);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc != 0) {
                const s: u32 = @bitCast(@as(i32, status));
                // (std's `IFSTOPPED` takes a core-dumped SIGSEGV for a stop.)
                if (s & 0xff == 0x7f) {
                    stopped_by = (s >> 8) & 0xff;
                    _ = posix.system.kill(-pgid, .KILL);
                    continue;
                }
                if (stopped_by) |sig| return .{ .signaled = sig };
                if (posix.W.IFSIGNALED(s)) return .{ .signaled = @intFromEnum(posix.W.TERMSIG(s)) };
                return .{ .exited = posix.W.EXITSTATUS(s) };
            },
            .INTR => continue,
            // Already reaped: nothing more to learn.
            .CHILD => return .{ .exited = 0 },
            else => return .{ .exited = 0 },
        }
        dl.step(pgid, nowNs());
        _ = posix.poll(&.{}, 5) catch {};
    }
}

/// Start `req` on `job`: every stage is launched before any is waited on, all
/// in one process group. `host_env` is the environment an omitted `req.env`
/// means; null: the process environment. A stage that cannot be started ends
/// the ones before it and fails the call, leaving `job` with nothing to wait
/// on. `own_input` copies stdin bytes into the job, for a job that outlives
/// the request.
pub fn start(job: *Job, io: Io, host_env: ?*const std.process.Environ.Map, req: seam.ProcRequest, own_input: bool) ?seam.ProcFail {
    if (comptime !supported) return .{ .class = .other };
    const gpa = job.gpa;
    const cap = job.cap;
    const n = req.stages.len;
    if (n == 0 or n > max_stages) return .{ .class = .other };
    for (req.stages, 0..) |argv, i| {
        if (argv.len == 0) return .{ .stage = @intCast(i), .class = .not_found };
    }

    // The children's whole environment.
    var own_env: ?std.process.Environ.Map = null;
    defer if (own_env) |*m| m.deinit();
    const env: *const std.process.Environ.Map = blk: {
        if (req.env) |pairs| {
            own_env = std.process.Environ.Map.init(gpa);
            for (pairs) |kv| own_env.?.put(kv.name, kv.value) catch return .{ .class = .other };
            break :blk &own_env.?;
        }
        if (host_env) |m| break :blk m;
        own_env = processEnviron(gpa) catch return .{ .class = .other };
        break :blk &own_env.?;
    };

    // The programs: a name with a slash is used as given (relative to the
    // child's cwd, as exec does); a bare name is searched for on its PATH.
    // All of them are found before any is started.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var exes: [max_stages][]const u8 = undefined;
    for (req.stages, 0..) |argv, i| {
        const prog = argv[0];
        if (std.mem.indexOfScalar(u8, prog, '/') != null) {
            exes[i] = prog;
            continue;
        }
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var denied = false;
        const found = searchPath(io, env.get("PATH") orelse "", prog, req.cwd, &path_buf, &denied) orelse
            return .{ .stage = @intCast(i), .class = if (denied) .permission_denied else .not_found };
        exes[i] = arena.dupe(u8, found) catch return .{ .class = .other };
    }

    // The first stage's stdin.
    var stdin_file: ?Io.File = null;
    defer if (stdin_file) |f| f.close(io);
    const input: []const u8 = switch (req.stdin) {
        .bytes => |b| b,
        else => "",
    };
    const first_stdin: std.process.SpawnOptions.StdIo = switch (req.stdin) {
        .empty => .ignore,
        .bytes => .pipe,
        .inherit => .inherit,
        .file => |path| blk: {
            stdin_file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| return .{ .class = startClass(e) };
            break :blk .{ .file = stdin_file.? };
        },
    };

    cap.prepare(gpa, n, req.max_bytes) catch return .{ .class = .other };

    var pipes: Pipes = .{};
    var pids: [max_stages]posix.pid_t = undefined;
    var started: usize = 0;
    var pgid: posix.pid_t = 0;
    // The read end that feeds the next stage, and (for stderr merged into a
    // captured stdout) the pipe the last stage writes both streams to.
    var prev_r: ?posix.fd_t = null;
    var merged: ?[2]posix.fd_t = null;
    var failure: ?seam.ProcFail = null;

    for (req.stages, 0..) |argv, i| {
        const last = i == n - 1;
        const stdin_mode: std.process.SpawnOptions.StdIo = if (i == 0)
            first_stdin
        else
            .{ .file = .{ .handle = prev_r.?, .flags = .{ .nonblocking = false } } };

        var next_r: ?posix.fd_t = null;
        var w: ?posix.fd_t = null;
        var out_spawn: std.process.SpawnOptions.StdIo = undefined;
        var err_mode: std.process.SpawnOptions.StdIo = switch (req.stderr) {
            .capture => .pipe,
            .discard => .ignore,
            .inherit => .inherit,
            .merge => .ignore,
        };
        if (!last) {
            // This stage's stdout is the next one's stdin.
            var fds: [2]posix.fd_t = undefined;
            if (posix.errno(posix.system.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
                failure = .{ .stage = @intCast(i), .class = .other };
                break;
            }
            next_r = fds[0];
            w = fds[1];
            out_spawn = .{ .file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
            if (req.stderr == .merge) err_mode = out_spawn;
        } else {
            const out_mode: std.process.SpawnOptions.StdIo = switch (req.stdout) {
                .capture => .pipe,
                .discard => .ignore,
                .inherit => .inherit,
                .merge => unreachable,
            };
            out_spawn = out_mode;
            if (req.stderr == .merge and req.stdout == .capture) {
                // One pipe, both streams: this file reads it.
                var fds: [2]posix.fd_t = undefined;
                if (posix.errno(posix.system.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
                    failure = .{ .stage = @intCast(i), .class = .other };
                    break;
                }
                merged = fds;
                out_spawn = .{ .file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
                err_mode = out_spawn;
            } else if (req.stderr == .merge) {
                // stdout is not captured: stderr goes where stdout goes.
                err_mode = out_mode;
            }
        }

        const child = std.process.spawn(io, .{
            .argv = argv,
            .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = exes[i] } },
            .cwd = if (req.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = env,
            .stdin = stdin_mode,
            .stdout = out_spawn,
            .stderr = err_mode,
            .pgid = pgid,
        }) catch |e| {
            if (next_r) |fd| closeFd(fd);
            if (w) |fd| closeFd(fd);
            if (merged) |m| {
                closeFd(m[0]);
                closeFd(m[1]);
                merged = null;
            }
            failure = .{ .stage = @intCast(i), .class = startClass(e) };
            break;
        };
        // Only the children hold these ends now; a read end reaches EOF when
        // its writer and that writer's descendants let go.
        if (w) |fd| closeFd(fd);
        if (merged) |m| closeFd(m[1]);
        if (prev_r) |fd| closeFd(fd);
        prev_r = next_r;

        const pid: posix.pid_t = child.id.?;
        pids[i] = pid;
        if (i == 0) {
            pgid = pid;
            if (child.stdin) |f| pipes.stdin = f.handle;
        }
        if (child.stderr) |f| pipes.errs[i] = f.handle;
        if (last) {
            if (child.stdout) |f| pipes.out = f.handle;
            if (merged) |m| pipes.out = m[0];
        }
        started += 1;
    }

    if (failure) |f| {
        if (prev_r) |fd| closeFd(fd);
        pipes.closeAll();
        if (started > 0) _ = posix.system.kill(-pgid, .KILL);
        var dl: Deadline = .{ .at = null };
        for (pids[0..started]) |pid| _ = reap(pid, pgid, &dl, false);
        return f;
    }

    job.n = n;
    job.pids = pids;
    job.pgid = pgid;
    job.pipes = pipes;
    job.stdout_captured = req.stdout == .capture;
    job.stderr_captured = req.stderr == .capture;
    job.dl = .{ .at = if (req.timeout_ns) |t| nowNs() +| t else null };
    job.fed = 0;
    if (job.pipes.stdin) |fd| {
        if (input.len == 0) {
            closeFd(fd);
            job.pipes.stdin = null;
        } else {
            setNonblocking(fd);
            if (own_input) {
                job.input = gpa.dupe(u8, input) catch {
                    job.terminate();
                    return .{ .class = .other };
                };
                job.input_owned = true;
            } else job.input = input;
        }
    }
    return null;
}

/// Run `req` to completion. See `start`. The result points into `cap`.
pub fn run(gpa: Allocator, io: Io, host_env: ?*const std.process.Environ.Map, req: seam.ProcRequest, cap: *Capture) seam.ProcResult {
    var job = Job.init(gpa, cap);
    defer job.deinit();
    if (start(&job, io, host_env, req, false)) |fail| return .{ .fail = fail };
    // Waiting from here on: Ctrl-C is the children's, and a child that reads
    // the terminal is its foreground group.
    Interrupt.acquire();
    defer Interrupt.release();
    var fg = Foreground.take(req.stdin == .inherit, job.pgid);
    defer fg.release();
    _ = job.advance(true, fg.owns());
    return job.result();
}

const testing = std.testing;

test "Tail keeps the latest bytes and says when it dropped some" {
    var t: Tail = .{};
    defer t.deinit(testing.allocator);
    t.reset(4);
    try t.push(testing.allocator, "ab");
    try testing.expectEqualStrings("ab", t.finish());
    try testing.expect(!t.dropped);
    try t.push(testing.allocator, "cd");
    try testing.expect(!t.dropped);
    try t.push(testing.allocator, "ef");
    try testing.expectEqualStrings("cdef", t.finish());
    try testing.expect(t.dropped);
    try t.push(testing.allocator, "ghijklm");
    try testing.expectEqualStrings("jklm", t.finish());
    t.reset(3);
    try t.push(testing.allocator, "abc");
    try testing.expect(!t.dropped);
    try testing.expectEqualStrings("abc", t.finish());
    t.reset(0);
    try t.push(testing.allocator, "x");
    try testing.expectEqualStrings("", t.finish());
    try testing.expect(t.dropped);
}

test "Tail ring wraps without losing order" {
    var t: Tail = .{};
    defer t.deinit(testing.allocator);
    t.reset(5);
    var expect: [64]u8 = undefined;
    var n: usize = 0;
    var c: u8 = 'a';
    while (n < 60) : (n += 1) {
        expect[n] = c;
        try t.push(testing.allocator, &.{c});
        c = if (c == 'z') 'a' else c + 1;
    }
    try testing.expectEqualStrings(expect[55..60], t.finish());
}
