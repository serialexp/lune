//! The test runner for every mahina test binary: std's own runner
//! (`lib/compiler/test_runner.zig` of the pinned toolchain, imported as
//! `std_test_runner`), plus `debug.SelfInfo` from `jit_unwind`. std reads
//! that override from the root module, and a test binary's root is its
//! runner, so this is the only place tests can install it (see
//! `src/jit_unwind.zig` for why they must).
//!
//! A runner only sees the imports of the module under test, so `build.zig`
//! gives each tested module `std_test_runner` and `jit_unwind`.

const std = @import("std");
const builtin = @import("builtin");
const std_runner = @import("std_test_runner");

pub const debug = @import("jit_unwind").debug;

pub const std_options = std_runner.std_options;
pub const mainSimple = std_runner.mainSimple;
pub const log = std_runner.log;
pub const fuzz = std_runner.fuzz;

/// Test sharding for `zig build test -Dtest-shards=N`: `build.zig` starts N
/// runs of one test binary, each with `MAHINA_TEST_SHARD=<i>/<N>`, and run `i`
/// keeps every N-th test (by declaration order, so the slow tests of one file
/// spread over the shards instead of landing in one). std's runner has no
/// sharding of its own; it reads `builtin.test_functions`, which is a mutable
/// declaration, so the wrapper installs the filtered list before delegating.
/// Unset (or malformed) runs everything.
var shard_tests: [shard_capacity]std.lang.TestFn = undefined;
const shard_capacity = 16384;

pub fn main(init: std.process.Init.Minimal) void {
    if (init.environ.getPosix("MAHINA_TEST_SHARD")) |spec| installShard(spec);
    if (init.environ.getPosix("MAHINA_TEST_JUNIT_DIR")) |dir| installJunit(dir);
    return std_runner.main(init);
}

// ---- JUnit report with requirement citations (doc 79) ----
//
// `MAHINA_TEST_JUNIT_DIR=<dir>` makes every test record its outcome as one
// `<testcase>` line in `<dir>/<pid>.frag` (a process is a shard of a test
// binary; `tools/junit-merge.py` joins the fragments into one report).
// A test cites the requirement criteria it verifies by tagging its name:
//
//     test "[REQ-12.1] a closed upvalue keeps its value" { ... }
//
// and each tag lands in the case's `requirements` property (the JUnit
// convention gothab.io ingests). std's runner stays in charge of running,
// leak checks, panics and skips: each test's `func` is swapped for a shim
// that calls the original and notes the result. A function pointer carries
// no data, so the shims are distinct functions, one per test index,
// generated at comptime up to `junit_capacity`. A binary with more tests
// than that reports nothing rather than a partial file. Leaks are detected by
// std after the function returns, so a leak shows in the build, not here.
// Linux only for now (raw syscalls keep this off the churning `std.Io`).
const junit_capacity = 8192;
const TestFnPtr = *const fn () anyerror!void;
var junit_tests: [junit_capacity]std.lang.TestFn = undefined;
var junit_originals: [junit_capacity]TestFnPtr = undefined;
var junit_fd: i32 = -1;
const junit_supported = builtin.os.tag == .linux;

fn JunitShim(comptime i: usize) type {
    return struct {
        fn run() anyerror!void {
            return junitRun(i);
        }
    };
}

const junit_shims = blk: {
    @setEvalBranchQuota(10 * junit_capacity);
    var t: [junit_capacity]TestFnPtr = undefined;
    for (&t, 0..) |*slot, i| slot.* = &JunitShim(i).run;
    break :blk t;
};

fn installJunit(dir: []const u8) void {
    if (!junit_supported) return;
    const linux = std.os.linux;
    const tests = builtin.test_functions;
    if (tests.len > junit_capacity) {
        std.debug.print("tests/test_runner.zig: {d} tests exceed junit_capacity; no JUnit fragment written\n", .{tests.len});
        return;
    }
    var path_buf: [512]u8 = undefined;
    // The directory may not exist yet (one level is created; EEXIST is fine).
    if (std.mem.printSentinel(&path_buf, "{s}", .{dir}, 0)) |dir_z| _ = linux.mkdir(dir_z.ptr, 0o755) else |_| return;
    const path = std.mem.printSentinel(&path_buf, "{s}/{d}.frag", .{ dir, linux.getpid() }, 0) catch return;
    const rc = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (@as(isize, @bitCast(rc)) < 0) return;
    junit_fd = @intCast(rc);
    for (tests, 0..) |t, i| {
        junit_originals[i] = t.func;
        junit_tests[i] = .{ .name = t.name, .func = junit_shims[i] };
    }
    builtin.test_functions = junit_tests[0..tests.len];
}

fn junitRun(i: usize) anyerror!void {
    const linux = std.os.linux;
    const name = builtin.test_functions[i].name;
    var t0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t0);
    const result = junit_originals[i]();
    var t1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t1);
    const ns = (@as(i64, t1.sec) - t0.sec) * 1_000_000_000 + (@as(i64, t1.nsec) - t0.nsec);
    junitWrite(name, ns, result);
    return result;
}

/// Splits `file.test.NAME` into the class (`file`) and the case name.
fn junitSplit(full: []const u8) struct { class: []const u8, name: []const u8 } {
    if (std.mem.indexOf(u8, full, ".test.")) |at| return .{ .class = full[0..at], .name = full[at + ".test.".len ..] };
    return .{ .class = "mahina", .name = full };
}

fn junitWrite(full: []const u8, ns: i64, result: anyerror!void) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const parts = junitSplit(full);
    w.writeAll("<testcase classname=\"") catch return;
    xmlEscape(&w, parts.class);
    w.writeAll("\" name=\"") catch return;
    xmlEscape(&w, parts.name);
    w.print("\" time=\"{d:.6}\">", .{@as(f64, @floatFromInt(ns)) / 1e9}) catch return;
    var keys: usize = 0;
    var rest = parts.name;
    while (std.mem.indexOf(u8, rest, "[REQ-")) |at| {
        const end = std.mem.indexOfScalarPos(u8, rest, at, ']') orelse break;
        const key = rest[at + 1 .. end];
        w.writeAll(if (keys == 0) "<properties><property name=\"requirements\" value=\"" else ",") catch return;
        xmlEscape(&w, key);
        keys += 1;
        rest = rest[end + 1 ..];
    }
    if (keys > 0) w.writeAll("\"/></properties>") catch return;
    if (result) |_| {} else |err| switch (err) {
        error.SkipZigTest => w.writeAll("<skipped/>") catch return,
        else => {
            w.writeAll("<failure message=\"") catch return;
            xmlEscape(&w, @errorName(err));
            w.writeAll("\"/>") catch return;
        },
    }
    w.writeAll("</testcase>\n") catch return;
    const out = w.buffered();
    // One write per case, O_APPEND: shards never interleave inside a line.
    _ = std.os.linux.write(junit_fd, out.ptr, out.len);
}

fn xmlEscape(w: *std.Io.Writer, text: []const u8) void {
    for (text) |c| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\n', '\r', '\t' => " ",
            else => &.{c},
        };
        w.writeAll(rep) catch return;
    }
}

fn installShard(spec: []const u8) void {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return;
    const index = std.fmt.parseInt(usize, spec[0..slash], 10) catch return;
    const count = std.fmt.parseInt(usize, spec[slash + 1 ..], 10) catch return;
    if (count == 0 or index >= count) return;
    var kept: usize = 0;
    for (builtin.test_functions, 0..) |t, i| {
        if (i % count != index) continue;
        if (kept == shard_tests.len) @panic("tests/test_runner.zig: raise shard_capacity");
        shard_tests[kept] = t;
        kept += 1;
    }
    builtin.test_functions = shard_tests[0..kept];
}

// std looks these up on the root by name, so a declaration std's runner adds
// and this file doesn't forward would be silently lost. Make it a build error.
comptime {
    for (@typeInfo(std_runner).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("tests/test_runner.zig must re-export std_test_runner." ++ name);
    }
}
