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

/// What a call leaves behind for its result to point into.
pub const Capture = struct {
    out: Tail = .{},
    err: Tail = .{},
    sig: [24]u8 = undefined,

    pub fn deinit(self: *Capture, gpa: Allocator) void {
        self.out.deinit(gpa);
        self.err.deinit(gpa);
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
    err: ?posix.fd_t = null,

    fn closeAll(self: *Pipes) void {
        inline for (.{ &self.stdin, &self.out, &self.err }) |p| {
            if (p.*) |fd| closeFd(fd);
            p.* = null;
        }
    }
};

/// Service the pipes until they have all closed (or the deadline gave up on
/// them): feed `input`, drain stdout and stderr into the tails.
fn pump(gpa: Allocator, pipes: *Pipes, input: []const u8, cap: *Capture, pid: posix.pid_t, dl: *Deadline) !void {
    var fed: usize = 0;
    if (pipes.stdin) |fd| {
        if (input.len == 0) {
            closeFd(fd);
            pipes.stdin = null;
        } else setNonblocking(fd);
    }
    var scratch: [64 * 1024]u8 = undefined;
    while (pipes.stdin != null or pipes.out != null or pipes.err != null) {
        const now = nowNs();
        dl.step(pid, now);
        if (dl.give_up) return;
        var fds: [3]posix.pollfd = undefined;
        var which: [3]u2 = undefined;
        var n: usize = 0;
        if (pipes.stdin) |fd| {
            fds[n] = .{ .fd = fd, .events = posix.POLL.OUT };
            which[n] = 0;
            n += 1;
        }
        if (pipes.out) |fd| {
            fds[n] = .{ .fd = fd, .events = posix.POLL.IN };
            which[n] = 1;
            n += 1;
        }
        if (pipes.err) |fd| {
            fds[n] = .{ .fd = fd, .events = posix.POLL.IN };
            which[n] = 2;
            n += 1;
        }
        _ = try posix.poll(fds[0..n], dl.pollTimeout(now));
        for (fds[0..n], which[0..n]) |pf, w| {
            if (pf.revents == 0) continue;
            switch (w) {
                0 => {
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
                },
                1, 2 => {
                    const slot = if (w == 1) &pipes.out else &pipes.err;
                    const tail = if (w == 1) &cap.out else &cap.err;
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
                },
                else => unreachable,
            }
        }
    }
}

const Reaped = union(enum) { exited: u32, signaled: u32 };

/// Wait for the child to end. With no deadline pending this blocks; with one
/// it polls, escalating when the deadline passes.
fn reap(pid: posix.pid_t, dl: *Deadline) Reaped {
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
        dl.step(pid, nowNs());
        _ = posix.poll(&.{}, 5) catch {};
    }
}

/// Run `req` to completion. `host_env` is the environment an omitted
/// `req.env` means; null: the process environment.
pub fn run(gpa: Allocator, io: Io, host_env: ?*const std.process.Environ.Map, req: seam.ProcRequest, cap: *Capture) seam.ProcResult {
    if (comptime !supported) return .{ .fail = .other };
    if (req.argv.len == 0) return .{ .fail = .not_found };

    // The child's whole environment.
    var own_env: ?std.process.Environ.Map = null;
    defer if (own_env) |*m| m.deinit();
    const env: *const std.process.Environ.Map = blk: {
        if (req.env) |pairs| {
            own_env = std.process.Environ.Map.init(gpa);
            for (pairs) |kv| own_env.?.put(kv.name, kv.value) catch return .{ .fail = .other };
            break :blk &own_env.?;
        }
        if (host_env) |m| break :blk m;
        own_env = processEnviron(gpa) catch return .{ .fail = .other };
        break :blk &own_env.?;
    };

    // The program: a name with a slash is used as given (relative to the
    // child's cwd, as exec does); a bare name is searched for on its PATH.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prog = req.argv[0];
    const exe_path: []const u8 = if (std.mem.indexOfScalar(u8, prog, '/') != null) prog else blk: {
        var denied = false;
        break :blk searchPath(io, env.get("PATH") orelse "", prog, req.cwd, &path_buf, &denied) orelse
            return .{ .fail = if (denied) .permission_denied else .not_found };
    };

    // stdin.
    var stdin_file: ?Io.File = null;
    defer if (stdin_file) |f| f.close(io);
    const input: []const u8 = switch (req.stdin) {
        .bytes => |b| b,
        else => "",
    };
    const stdin_mode: std.process.SpawnOptions.StdIo = switch (req.stdin) {
        .empty => .ignore,
        .bytes => .pipe,
        .inherit => .inherit,
        .file => |path| blk: {
            stdin_file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| return .{ .fail = startClass(e) };
            break :blk .{ .file = stdin_file.? };
        },
    };

    // stderr merged into stdout shares one pipe (the child's two ends are the
    // same file), which this file reads.
    var merged: ?[2]posix.fd_t = null;
    const out_mode: std.process.SpawnOptions.StdIo = switch (req.stdout) {
        .capture => .pipe,
        .discard => .ignore,
        .inherit => .inherit,
        .merge => unreachable,
    };
    var err_mode: std.process.SpawnOptions.StdIo = switch (req.stderr) {
        .capture => .pipe,
        .discard => .ignore,
        .inherit => .inherit,
        .merge => .ignore,
    };
    var out_spawn = out_mode;
    if (req.stderr == .merge and req.stdout == .capture) {
        var fds: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return .{ .fail = .other };
        merged = fds;
        out_spawn = .{ .file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
        err_mode = .{ .file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
    } else if (req.stderr == .merge) {
        // stdout is not captured: stderr goes where stdout goes.
        err_mode = out_mode;
    }

    const child = std.process.spawn(io, .{
        .argv = req.argv,
        .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = exe_path } },
        .cwd = if (req.cwd) |p| .{ .path = p } else .inherit,
        .environ_map = env,
        .stdin = stdin_mode,
        .stdout = out_spawn,
        .stderr = err_mode,
        .pgid = 0,
    }) catch |e| {
        if (merged) |m| {
            closeFd(m[0]);
            closeFd(m[1]);
        }
        return .{ .fail = startClass(e) };
    };
    // Only the child holds the write end now; the read end reaches EOF when
    // it and its descendants let go.
    if (merged) |m| closeFd(m[1]);
    const pid: posix.pid_t = child.id.?;

    cap.out.reset(req.max_bytes);
    cap.err.reset(req.max_bytes);
    var pipes: Pipes = .{
        .stdin = if (child.stdin) |f| f.handle else null,
        .out = if (child.stdout) |f| f.handle else null,
        .err = if (child.stderr) |f| f.handle else null,
    };
    if (merged) |m| pipes.out = m[0];
    // The child was reaped by hand below; the pipes are ours.
    var dl: Deadline = .{ .at = if (req.timeout_ns) |t| nowNs() +| t else null };

    pump(gpa, &pipes, input, cap, pid, &dl) catch {
        // Out of memory or a poll fault: end the child rather than leak it.
        _ = posix.system.kill(-pid, .KILL);
        pipes.closeAll();
        _ = reap(pid, &dl);
        return .{ .fail = .other };
    };
    pipes.closeAll();
    const reaped = reap(pid, &dl);

    const status: seam.ProcStatus = if (dl.timed_out) .timed_out else switch (reaped) {
        .exited => |c| .{ .exited = c },
        .signaled => |s| .{ .signaled = signalName(s, &cap.sig) },
    };
    return .{ .done = .{
        .status = status,
        .stdout = if (req.stdout == .capture) cap.out.finish() else "",
        .stderr = if (req.stderr == .capture) cap.err.finish() else "",
        .truncated = (req.stdout == .capture and cap.out.dropped) or (req.stderr == .capture and cap.err.dropped),
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
