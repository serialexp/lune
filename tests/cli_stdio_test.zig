//! The real CLI's standard streams, exit status and host flags (doc 65 §6,
//! Q6, Q9): what a script's output looks like from outside the process. A
//! unit test inside the VM cannot see these: buffering, the order of stdout
//! against stderr, and the status the process ends with belong to the
//! binary, and to the kind of file it was handed.
//!
//! Linux only (raw `fork`/`execve`, `memfd_create`). `build.zig` runs this
//! test in the directory the CLI was just built into.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const testing = std.testing;

const exe_path: [*:0]const u8 = "./mahina";

/// What a run left behind: everything written to the shared sink, and the
/// exit status.
const Result = struct {
    out: []u8,
    status: u8,

    fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
    }
};

fn expectOk(rc: usize) !usize {
    if (linux.errno(rc) != .SUCCESS) return error.SyscallFailed;
    return rc;
}

/// Start `mahina args...` with the given stdin, and stdout and stderr both
/// on `sink` (a descriptor the caller keeps). Returns the pid.
fn start(args: []const [*:0]const u8, stdin_fd: i32, sink: i32) !linux.pid_t {
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    argv[0] = exe_path;
    for (args, 1..) |a, i| argv[i] = a;
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp" };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    if (rc != 0) return @intCast(rc);
    _ = linux.dup2(stdin_fd, 0);
    _ = linux.dup2(sink, 1);
    _ = linux.dup2(sink, 2);
    _ = linux.execve(exe_path, &argv, &envp);
    linux.exit(127);
}

fn finish(pid: linux.pid_t) !u8 {
    var status: i32 = 0;
    _ = try expectOk(linux.waitpid(pid, &status, 0));
    const s: u32 = @bitCast(status);
    if (!linux.W.IFEXITED(s)) return error.EndedBySignal;
    return linux.W.EXITSTATUS(s);
}

/// A regular, seekable file that stdout and stderr share, like `prog > f 2>&1`.
fn sinkFile() !i32 {
    return @intCast(try expectOk(linux.memfd_create("cli-sink", 0)));
}

fn readAll(gpa: std.mem.Allocator, fd: i32) ![]u8 {
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(gpa);
    var buf: [512]u8 = undefined;
    var at: i64 = 0;
    while (true) {
        const n = try expectOk(linux.pread(fd, &buf, buf.len, at));
        if (n == 0) break;
        try all.appendSlice(gpa, buf[0..n]);
        at += @intCast(n);
    }
    return all.toOwnedSlice(gpa);
}

/// Run `mahina args...` to the end with no input and both streams in one
/// regular file.
fn runToFile(gpa: std.mem.Allocator, args: []const [*:0]const u8) !Result {
    const sink = try sinkFile();
    defer _ = linux.close(sink);
    const dev_null: i32 = @intCast(try expectOk(linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0)));
    defer _ = linux.close(dev_null);
    const pid = try start(args, dev_null, sink);
    const status = try finish(pid);
    return .{ .out = try readAll(gpa, sink), .status = status };
}

fn onlyLinux() !void {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
}

test "[REQ-78.1] [REQ-79.1] [REQ-81.1] stdout and stderr in one file keep the program's order and none is overwritten" {
    try onlyLinux();
    const r = try runToFile(testing.allocator, &.{
        "-e",
        "io.write('one\\n') io.stderr:write('two\\n') io.write('three\\n') io.stderr:write('four\\n') io.write('five\\n')",
    });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\n", r.out);
}

test "[REQ-81.2] [REQ-83.6] os.exit writes what was held back, and the status is the low 8 bits" {
    try onlyLinux();
    const r = try runToFile(testing.allocator, &.{ "-e", "io.write('held\\n') os.exit(300)" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 44), r.status);
    try testing.expectEqualStrings("held\n", r.out);
    const f = try runToFile(testing.allocator, &.{ "-e", "os.exit(false)" });
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), f.status);
}

test "[REQ-81.3] held-back stdout is written before the error report when the script fails" {
    try onlyLinux();
    const r = try runToFile(testing.allocator, &.{ "-e", "io.write('before\\n') error('boom')" });
    defer r.deinit(testing.allocator);
    try testing.expect(r.status != 0);
    try testing.expect(std.mem.startsWith(u8, r.out, "before\n"));
    try testing.expect(std.mem.indexOf(u8, r.out, "boom") != null);
}

/// Both ends of a pipe for the child's stdin and stdout, and the child:
/// `code` as `-e`. The parent keeps `in_w` (to the child's stdin) and `out_r`.
const Piped = struct {
    pid: linux.pid_t,
    in_w: i32,
    out_r: i32,
    done: bool = false,

    fn open(code: [*:0]const u8) !Piped {
        var in_pipe: [2]i32 = undefined;
        _ = try expectOk(linux.pipe2(&in_pipe, .{ .CLOEXEC = true }));
        var out_pipe: [2]i32 = undefined;
        _ = try expectOk(linux.pipe2(&out_pipe, .{ .CLOEXEC = true }));
        const pid = try start(&.{ "-e", code }, in_pipe[0], out_pipe[1]);
        _ = linux.close(in_pipe[0]);
        _ = linux.close(out_pipe[1]);
        return .{ .pid = pid, .in_w = in_pipe[1], .out_r = out_pipe[0] };
    }

    /// Whether the child's stdout has something to read within `ms`.
    fn readable(self: Piped, ms: i32) !bool {
        var fds = [_]linux.pollfd{.{ .fd = self.out_r, .events = linux.POLL.IN }};
        return try expectOk(linux.poll(&fds, 1, ms)) != 0;
    }

    /// Everything the child writes until it ends, and its status.
    fn drain(self: *Piped, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !u8 {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = try expectOk(linux.read(self.out_r, &buf, buf.len));
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        self.done = true;
        return finish(self.pid);
    }

    fn deinit(self: Piped) void {
        if (!self.done) {
            _ = linux.kill(self.pid, .KILL);
            _ = finish(self.pid) catch {};
        }
        _ = linux.close(self.in_w);
        _ = linux.close(self.out_r);
    }
};

test "[REQ-80.2] to a pipe, output is held back until the program ends" {
    try onlyLinux();
    const gpa = testing.allocator;
    // The script writes, then keeps busy for a second of CPU time.
    var child = try Piped.open("io.write('held\\n') while os.clock() < 1 do end io.write('rest\\n')");
    defer child.deinit();
    // The first write is still in the buffer after the wait. (A bound on
    // waiting for something that must not happen, not a measurement.)
    try testing.expect(!try child.readable(300));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), try child.drain(gpa, &out));
    try testing.expectEqualStrings("held\nrest\n", out.items);
}

test "[REQ-80.3] held-back stdout is written before the program reads standard input" {
    try onlyLinux();
    const gpa = testing.allocator;
    var child = try Piped.open("io.write('prompt> ') io.read() io.write('done\\n')");
    defer child.deinit();
    // The prompt arrives while the script is still waiting for its input.
    try testing.expect(try child.readable(5000));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try expectOk(linux.write(child.in_w, "go\n", 3));
    try testing.expectEqual(@as(u8, 0), try child.drain(gpa, &out));
    try testing.expectEqualStrings("prompt> done\n", out.items);
}

test "[REQ-57.2] --system gives exactly the groups named, and a bad list is refused" {
    try onlyLinux();
    const ok = try runToFile(testing.allocator, &.{
        "--system", "clock", "-e", "print(io.open, os.exit, os.time, os.clock ~= nil)",
    });
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), ok.status);
    try testing.expectEqualStrings("nil\tnil\tnil\ttrue\n", ok.out);
    const bad = try runToFile(testing.allocator, &.{ "--system", "disk", "-e", "print(1)" });
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 2), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.out, "--system") != null);
}

test "[REQ-98.1] a failing io.open raises, and returns nil, a message and a code under --lua-io-errors" {
    try onlyLinux();
    const code = "print(io.open('/nonexistent-dir/x'))";
    const raised = try runToFile(testing.allocator, &.{ "-e", code });
    defer raised.deinit(testing.allocator);
    try testing.expect(raised.status != 0);
    try testing.expect(std.mem.indexOf(u8, raised.out, "cannot open '/nonexistent-dir/x': not found") != null);
    const lua = try runToFile(testing.allocator, &.{ "--lua-io-errors", "-e", code });
    defer lua.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), lua.status);
    try testing.expectEqualStrings("nil\tcannot open '/nonexistent-dir/x': not found\t1\n", lua.out);
}

test "[REQ-76.4] --effect-log-limit caps the recording, and the failure names the flag" {
    try onlyLinux();
    const r = try runToFile(testing.allocator, &.{
        "--emit-effects",    "/dev/null",
        "--effect-log-limit", "64",
        "-e",                 "for i = 1, 100 do os.getenv('MAHINA_UNSET_VARIABLE') end",
    });
    defer r.deinit(testing.allocator);
    try testing.expect(r.status != 0);
    try testing.expect(std.mem.indexOf(u8, r.out, "--effect-log-limit") != null);
}
