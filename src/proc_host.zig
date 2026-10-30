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

/// Service the pipes until they have all closed (or the deadline gave up on
/// them): feed `input`, drain the last stage's stdout and every stage's
/// stderr into the tails.
fn pump(gpa: Allocator, pipes: *Pipes, input: []const u8, cap: *Capture, pgid: posix.pid_t, dl: *Deadline) !void {
    var fed: usize = 0;
    if (pipes.stdin) |fd| {
        if (input.len == 0) {
            closeFd(fd);
            pipes.stdin = null;
        } else setNonblocking(fd);
    }
    var scratch: [64 * 1024]u8 = undefined;
    // Which descriptor each poll entry is: 0 stdin, 1 stdout, 2 + i the
    // stderr of stage i.
    var fds: [max_stages + 2]posix.pollfd = undefined;
    var which: [max_stages + 2]u8 = undefined;
    while (pipes.open()) {
        const now = nowNs();
        dl.step(pgid, now);
        if (dl.give_up) return;
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
        _ = try posix.poll(fds[0..n], dl.pollTimeout(now));
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
                const rc = posix.system.write(fd, input[fed..].ptr, input.len - fed);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        fed += @intCast(rc);
                        if (fed == input.len) {
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
                    } else try tail.push(gpa, scratch[0..got]);
                },
                .AGAIN, .INTR => {},
                else => {
                    closeFd(fd);
                    slot.* = null;
                },
            }
        }
    }
}

const Reaped = union(enum) { exited: u32, signaled: u32 };

/// Wait for the child to end. With no deadline pending this blocks; with one
/// it polls, escalating when the deadline passes. `pgid` is the group the
/// deadline signals.
fn reap(pid: posix.pid_t, pgid: posix.pid_t, dl: *Deadline) Reaped {
    while (true) {
        const blocking = dl.at == null and !dl.timed_out;
        var status: if (builtin.link_libc) c_int else i32 = undefined;
        const rc = posix.system.wait4(pid, &status, if (blocking) 0 else posix.W.NOHANG, null);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc != 0) {
                const s: u32 = @bitCast(@as(i32, status));
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

/// Run `req` to completion: every stage is started before any is waited on,
/// all in one process group. `host_env` is the environment an omitted
/// `req.env` means; null: the process environment. A stage that cannot be
/// started ends the ones before it and fails the call.
pub fn run(gpa: Allocator, io: Io, host_env: ?*const std.process.Environ.Map, req: seam.ProcRequest, cap: *Capture) seam.ProcResult {
    if (comptime !supported) return .{ .fail = .{ .class = .other } };
    const n = req.stages.len;
    if (n == 0 or n > max_stages) return .{ .fail = .{ .class = .other } };
    for (req.stages, 0..) |argv, i| {
        if (argv.len == 0) return .{ .fail = .{ .stage = @intCast(i), .class = .not_found } };
    }

    // The children's whole environment.
    var own_env: ?std.process.Environ.Map = null;
    defer if (own_env) |*m| m.deinit();
    const env: *const std.process.Environ.Map = blk: {
        if (req.env) |pairs| {
            own_env = std.process.Environ.Map.init(gpa);
            for (pairs) |kv| own_env.?.put(kv.name, kv.value) catch return .{ .fail = .{ .class = .other } };
            break :blk &own_env.?;
        }
        if (host_env) |m| break :blk m;
        own_env = processEnviron(gpa) catch return .{ .fail = .{ .class = .other } };
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
            return .{ .fail = .{ .stage = @intCast(i), .class = if (denied) .permission_denied else .not_found } };
        exes[i] = arena.dupe(u8, found) catch return .{ .fail = .{ .class = .other } };
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
            stdin_file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| return .{ .fail = .{ .class = startClass(e) } };
            break :blk .{ .file = stdin_file.? };
        },
    };

    cap.prepare(gpa, n, req.max_bytes) catch return .{ .fail = .{ .class = .other } };

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

    // The children are ours to reap by hand; the pipes are ours to close.
    var dl: Deadline = .{ .at = if (req.timeout_ns) |t| nowNs() +| t else null };

    if (failure) |f| {
        if (prev_r) |fd| closeFd(fd);
        pipes.closeAll();
        if (started > 0) _ = posix.system.kill(-pgid, .KILL);
        for (pids[0..started]) |pid| _ = reap(pid, pgid, &dl);
        return .{ .fail = f };
    }

    pump(gpa, &pipes, input, cap, pgid, &dl) catch {
        // Out of memory or a poll fault: end the children rather than leak them.
        _ = posix.system.kill(-pgid, .KILL);
        pipes.closeAll();
        for (pids[0..n]) |pid| _ = reap(pid, pgid, &dl);
        return .{ .fail = .{ .class = .other } };
    };
    pipes.closeAll();

    var truncated = req.stdout == .capture and cap.out.dropped;
    for (0..n) |i| {
        const stderr_bytes: []const u8 = if (req.stderr == .capture) blk: {
            if (cap.errs.items[i].dropped) truncated = true;
            break :blk cap.errs.items[i].finish();
        } else "";
        cap.stages.items[i] = .{
            .status = switch (reap(pids[i], pgid, &dl)) {
                .exited => |c| .{ .exited = c },
                .signaled => |sig| .{ .signaled = signalName(sig, &cap.sigs.items[i]) },
            },
            .stderr = stderr_bytes,
        };
    }
    return .{ .done = .{
        .stages = cap.stages.items,
        .stdout = if (req.stdout == .capture) cap.out.finish() else "",
        .timed_out = dl.timed_out,
        .truncated = truncated,
    } };
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
