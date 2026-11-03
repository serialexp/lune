//! The terminal handed to a child (doc 75 §6, Q12): the real `mahina`
//! binary runs on a pseudo-terminal as the session leader, so a program it
//! runs with an inherited stdin has a terminal to take. A unit test cannot
//! stand in for this: the foreground group is a property of the controlling
//! terminal, which a test process does not have.
//!
//! Linux only (the pty and the `/proc` stat the children read are Linux's).
//! `build.zig` runs this test in the directory the CLI was just built into.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const testing = std.testing;

/// How long a test waits for the terminal to say something before it gives
/// up, in 100 ms looks: a bound against hanging, not a measurement.
const patience_looks = 300;

const Pty = struct {
    master: i32,
    slave: i32,

    fn open() !Pty {
        var rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.NoPtmx;
        const master: i32 = @intCast(rc);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyUnlock;
        var n: c_uint = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.PtyNumber;
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});
        buf[path.len] = 0;
        rc = linux.open(@ptrCast(&buf), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.NoPtySlave;
        return .{ .master = master, .slave = @intCast(rc) };
    }

    fn close(self: Pty) void {
        _ = linux.close(self.master);
        _ = linux.close(self.slave);
    }
};

/// The CLI, in the working directory `build.zig` runs this test from.
const exe_path: [*:0]const u8 = "./mahina";

/// Run `mahina -e code` as the session leader of `pty`, with the terminal as
/// its stdin, stdout and stderr. Returns its pid.
fn launch(pty: Pty, code: [*:0]const u8) !linux.pid_t {
    const argv = [_:null]?[*:0]const u8{ exe_path, "-e", code };
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin", "TERM=dumb" };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    if (rc != 0) return @intCast(rc);
    // The child: only system calls until the exec.
    _ = linux.close(pty.master);
    _ = linux.setsid();
    _ = linux.ioctl(pty.slave, linux.T.IOCSCTTY, 0);
    _ = linux.dup2(pty.slave, 0);
    _ = linux.dup2(pty.slave, 1);
    _ = linux.dup2(pty.slave, 2);
    if (pty.slave > 2) _ = linux.close(pty.slave);
    _ = linux.execve(exe_path, &argv, &envp);
    linux.exit(127);
}

/// Read from the terminal into `out` until `marker` has appeared. Fails if
/// the terminal closes or goes quiet for too long first.
fn readUntil(gpa: std.mem.Allocator, master: i32, out: *std.ArrayList(u8), marker: []const u8) !void {
    var looks: usize = 0;
    while (std.mem.indexOf(u8, out.items, marker) == null) {
        if (looks == patience_looks) return error.TerminalQuiet;
        var fds = [_]linux.pollfd{.{ .fd = master, .events = linux.POLL.IN }};
        const ready = linux.poll(&fds, 1, 100);
        if (linux.errno(ready) != .SUCCESS) return error.PollFailed;
        if (ready == 0) {
            looks += 1;
            continue;
        }
        var buf: [512]u8 = undefined;
        const n = linux.read(master, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return error.TerminalClosed;
        try out.appendSlice(gpa, buf[0..n]);
    }
}

fn typeInto(master: i32, bytes: []const u8) !void {
    if (linux.errno(linux.write(master, bytes.ptr, bytes.len)) != .SUCCESS) return error.WriteFailed;
}

/// The exit status of `pid`, waiting for it.
fn finish(pid: linux.pid_t) !u8 {
    var status: i32 = 0;
    if (linux.errno(linux.waitpid(pid, &status, 0)) != .SUCCESS) return error.WaitFailed;
    const s: u32 = @bitCast(status);
    if (!linux.W.IFEXITED(s)) return error.EndedBySignal;
    return linux.W.EXITSTATUS(s);
}

/// The line of `out` that starts with `prefix`, without the prefix and the
/// terminal's carriage return.
fn lineAfter(out: []const u8, prefix: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, out, prefix) orelse return error.LineMissing;
    const rest = out[at + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    return rest[0..end];
}

/// "A B" -> A and B.
fn pair(line: []const u8) !struct { pgrp: i64, tpgid: i64 } {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const a = it.next() orelse return error.BadPair;
    const b = it.next() orelse return error.BadPair;
    return .{ .pgrp = try std.fmt.parseInt(i64, a, 10), .tpgid = try std.fmt.parseInt(i64, b, 10) };
}

test "[REQ-52.1] [REQ-52.2] a child that inherits the terminal can read it, and leads its foreground while it runs" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try Pty.open();
    defer pty.close();
    const code = (
        \\local r = proc.run({"/bin/sh", "-c", "read x; echo got:$x; echo own:$(sed 's/.*) //' /proc/$$/stat | cut -d' ' -f3,6)", stdin = {inherit = true}, timeout = 25})
        \\io.write(string.decode(r.stdout))
        \\local m = proc.run({"/bin/sh", "-c", "echo mine:$(sed 's/.*) //' /proc/$PPID/stat | cut -d' ' -f3,6)", timeout = 25})
        \\io.write(string.decode(m.stdout))
        \\print("finished")
    ) ++ "\x00";
    const pid = try launch(pty, @ptrCast(code.ptr));
    var killed = false;
    defer if (!killed) {
        _ = linux.kill(pid, .KILL);
        _ = finish(pid) catch {};
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try typeInto(pty.master, "hi\n");
    try readUntil(gpa, pty.master, &out, "finished");
    killed = true;
    try testing.expectEqual(@as(u8, 0), try finish(pid));

    try testing.expectEqualStrings("hi", try lineAfter(out.items, "got:"));
    // While it ran, the child was the terminal's foreground group...
    const own = try pair(try lineAfter(out.items, "own:"));
    try testing.expectEqual(own.pgrp, own.tpgid);
    // ... and not mahina's group, which took the terminal back afterwards.
    const mine = try pair(try lineAfter(out.items, "mine:"));
    try testing.expectEqual(mine.pgrp, mine.tpgid);
    try testing.expect(own.pgrp != mine.pgrp);
}

test "[REQ-52.3] the terminal's Ctrl-C reaches the child that holds it, and mahina carries on" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const pty = try Pty.open();
    defer pty.close();
    const code = (
        \\local r = proc.run({"/bin/sh", "-c", "trap 'echo int:$(sed \"s/.*) //\" /proc/$$/stat | cut -d\" \" -f3,6); exit 9' INT; echo ready >&2; while :; do sleep 0.05; done", stdin = {inherit = true}, stderr = "inherit", check = false, timeout = 25})
        \\io.write(string.decode(r.stdout))
        \\print("code", r.code)
        \\print("finished")
    ) ++ "\x00";
    const pid = try launch(pty, @ptrCast(code.ptr));
    var killed = false;
    defer if (!killed) {
        _ = linux.kill(pid, .KILL);
        _ = finish(pid) catch {};
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try readUntil(gpa, pty.master, &out, "ready");
    try typeInto(pty.master, "\x03");
    try readUntil(gpa, pty.master, &out, "finished");
    killed = true;
    try testing.expectEqual(@as(u8, 0), try finish(pid));

    // The trap ran, so the child got the interrupt, and it did so as the
    // terminal's foreground group: the terminal sent it, not mahina.
    const at_int = try pair(try lineAfter(out.items, "int:"));
    try testing.expectEqual(at_int.pgrp, at_int.tpgid);
    try testing.expectEqualStrings("9", try lineAfter(out.items, "code\t"));
}
