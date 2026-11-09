//! `mahina fmt` (doc 83 §8.1): the command line around `format.format`.
//!
//! The formatter itself is a pure function (`mahina.format`); this file is
//! the file-system contract: which paths are walked, what is skipped, and how
//! a rewrite reaches the disk without ever clobbering a newer save.

const std = @import("std");
const mahina = @import("mahina");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

const format = mahina.format;
const Diagnostics = mahina.diag.Diagnostics;

/// Directories a walk never enters. Not an ignore file: it cannot be
/// configured (doc 83 §8.1).
const skip_dirs = [_][]const u8{ ".git", "zig-out", ".zig-cache", "node_modules", "target" };

pub const usage =
    \\usage: mahina fmt [--check] [--stdin] [paths...]
    \\
    \\Format mahina source in the one standard style. Each path is a file, or a
    \\directory whose .lua and .mah files are formatted (symlinks are skipped,
    \\as are .git, zig-out, .zig-cache, node_modules and target). A file with
    \\syntax errors is reported and left alone.
    \\
    \\options:
    \\  --check      write nothing; print the files that would change and exit 1
    \\               if there are any
    \\  --stdin      read source from stdin, write the formatted source to stdout
    \\  -h, --help   show this help
    \\
;

pub const Outcome = enum {
    /// Already formatted.
    unchanged,
    /// Formatted differently: rewritten, or (in check mode) would be.
    changed,
    /// Syntax errors, or a comment the formatter will not move.
    refused,
    /// Changed on disk since it was read; left for the next run.
    modified_meanwhile,
    /// Could not be read or written.
    io_error,
};

pub const Summary = struct {
    changed: usize = 0,
    refused: usize = 0,
    failed: usize = 0,

    /// The process exit code: 1 if anything was refused or failed, or (in
    /// check mode) would change.
    pub fn exitCode(self: Summary, check: bool) u8 {
        if (self.refused > 0 or self.failed > 0) return 1;
        if (check and self.changed > 0) return 1;
        return 0;
    }
};

fn isSource(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".lua") or std.mem.endsWith(u8, name, ".mah");
}

fn isSkipped(name: []const u8) bool {
    for (skip_dirs) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Format the file at `path` (relative to `dir`). Syntax errors land in
/// `diags`. In check mode nothing is written.
pub fn formatFile(
    gpa: Allocator,
    io: Io,
    dir: Dir,
    path: []const u8,
    check: bool,
    diags: *Diagnostics,
) Outcome {
    const read_stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return .io_error;
    const source = dir.readFileAllocOptions(io, path, gpa, Io.Limit.limited(mahina.io.max_source_bytes), .of(u8), 0) catch return .io_error;
    defer gpa.free(source);

    const out = format.format(gpa, source, diags) catch |e| switch (e) {
        error.OutOfMemory => return .io_error,
        error.SyntaxError, error.UnplacedComment => return .refused,
    };
    defer gpa.free(out);
    if (std.mem.eql(u8, source, out)) return .unchanged;
    if (check) return .changed;
    return replaceFile(io, dir, path, out, read_stat);
}

/// Write `data` over `path` through a temporary file in the same directory,
/// carrying the original's mode, and only if the file is still the one that
/// was read (same size and mtime).
fn replaceFile(io: Io, dir: Dir, path: []const u8, data: []const u8, read_stat: Io.File.Stat) Outcome {
    const parent_path = std.fs.path.dirname(path);
    const base = std.fs.path.basename(path);
    var parent = if (parent_path) |p| dir.openDir(io, p, .{}) catch return .io_error else dir;
    defer if (parent_path != null) parent.close(io);

    var af = parent.createFileAtomic(io, base, .{ .permissions = read_stat.permissions, .replace = true }) catch return .io_error;
    defer af.deinit(io);
    af.file.writeStreamingAll(io, data) catch return .io_error;

    const now = parent.statFile(io, base, .{ .follow_symlinks = false }) catch return .io_error;
    if (now.size != read_stat.size or now.mtime.nanoseconds != read_stat.mtime.nanoseconds) return .modified_meanwhile;
    af.replace(io) catch return .io_error;
    return .changed;
}

/// Format everything `paths` names; report as it goes. `dir` is what the
/// paths are relative to (the working directory for the CLI).
pub fn run(gpa: Allocator, io: Io, dir: Dir, paths: []const []const u8, check: bool) Summary {
    var summary: Summary = .{};
    for (paths) |p| visit(gpa, io, dir, p, true, check, &summary);
    return summary;
}

/// One path: a file is formatted, a directory walked, anything else
/// reported. `named` is true for a path the user gave, so an unreadable one
/// is an error and a stray symlink inside a walk is only a note.
fn visit(gpa: Allocator, io: Io, dir: Dir, path: []const u8, named: bool, check: bool, summary: *Summary) void {
    const st = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |e| {
        mahina.io.eprint("mahina fmt: {s}: {s}\n", .{ path, @errorName(e) });
        summary.failed += 1;
        return;
    };
    switch (st.kind) {
        .file => {
            if (!named and !isSource(path)) return;
            reportFile(gpa, io, dir, path, check, summary);
        },
        .directory => walk(gpa, io, dir, path, check, summary),
        .sym_link => mahina.io.eprint("mahina fmt: {s}: skipped (symbolic link)\n", .{path}),
        else => {
            mahina.io.eprint("mahina fmt: {s}: not a regular file or directory\n", .{path});
            summary.failed += 1;
        },
    }
}

fn walk(gpa: Allocator, io: Io, dir: Dir, path: []const u8, check: bool, summary: *Summary) void {
    var sub = dir.openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |e| {
        mahina.io.eprint("mahina fmt: {s}: {s}\n", .{ path, @errorName(e) });
        summary.failed += 1;
        return;
    };
    defer sub.close(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = sub.iterate();
    while (it.next(io) catch |e| {
        mahina.io.eprint("mahina fmt: {s}: {s}\n", .{ path, @errorName(e) });
        summary.failed += 1;
        return;
    }) |entry| {
        if (entry.kind == .directory and isSkipped(entry.name)) continue;
        const name = a.dupe(u8, entry.name) catch {
            summary.failed += 1;
            return;
        };
        names.append(a, name) catch {
            summary.failed += 1;
            return;
        };
    }
    // Directory order is the file system's; the output should not be.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (names.items) |name| {
        const child = std.fs.path.join(a, &.{ path, name }) catch {
            summary.failed += 1;
            return;
        };
        visit(gpa, io, dir, child, false, check, summary);
    }
}

fn reportFile(gpa: Allocator, io: Io, dir: Dir, path: []const u8, check: bool, summary: *Summary) void {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    switch (formatFile(gpa, io, dir, path, check, &diags)) {
        .unchanged => {},
        .changed => {
            summary.changed += 1;
            if (check) mahina.io.print("{s}\n", .{path});
        },
        .refused => {
            summary.refused += 1;
            if (diags.count() == 0) {
                mahina.io.eprint("mahina fmt: {s}: a comment sits where the formatter cannot place it; file left alone\n", .{path});
            }
            for (diags.list.items) |d| {
                mahina.io.eprint("{s}:{d}: {s}: {s}\n", .{ path, d.line, @tagName(d.severity), d.message });
            }
        },
        .modified_meanwhile => {
            summary.failed += 1;
            mahina.io.eprint("mahina fmt: {s}: changed while formatting; left alone\n", .{path});
        },
        .io_error => {
            summary.failed += 1;
            mahina.io.eprint("mahina fmt: {s}: could not be read or written\n", .{path});
        },
    }
}

/// `--stdin`: the formatted `source`, or the exit code and diagnostics.
pub fn formatStdin(gpa: Allocator, io: Io) u8 {
    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buf);
    const source = reader.interface.allocRemaining(gpa, Io.Limit.limited(mahina.io.max_source_bytes)) catch {
        mahina.io.eprint("mahina fmt: could not read stdin\n", .{});
        return 1;
    };
    defer gpa.free(source);
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    const out = format.format(gpa, source, &diags) catch |e| {
        switch (e) {
            error.OutOfMemory => mahina.io.eprint("mahina fmt: out of memory\n", .{}),
            error.UnplacedComment => mahina.io.eprint("<stdin>: a comment sits where the formatter cannot place it\n", .{}),
            error.SyntaxError => for (diags.list.items) |d| {
                mahina.io.eprint("<stdin>:{d}: {s}: {s}\n", .{ d.line, @tagName(d.severity), d.message });
            },
        }
        return 1;
    };
    defer gpa.free(out);
    Io.File.stdout().writeStreamingAll(io, out) catch return 1;
    return 0;
}

const testing = std.testing;

fn writeTmp(dir: Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn readTmp(dir: Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, path, testing.allocator, Io.Limit.limited(1 << 20));
}

test "formatFile rewrites in place, keeps the mode, and skips what is already formatted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "a.lua", "local x=1;\n");
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    try testing.expectEqual(Outcome.changed, formatFile(testing.allocator, testing.io, tmp.dir, "a.lua", false, &diags));
    const got = try readTmp(tmp.dir, "a.lua");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("local x = 1\n", got);
    try testing.expectEqual(Outcome.unchanged, formatFile(testing.allocator, testing.io, tmp.dir, "a.lua", false, &diags));
}

test "formatFile --check writes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "a.lua", "local x=1\n");
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    try testing.expectEqual(Outcome.changed, formatFile(testing.allocator, testing.io, tmp.dir, "a.lua", true, &diags));
    const got = try readTmp(tmp.dir, "a.lua");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("local x=1\n", got);
}

test "formatFile refuses a syntax error and leaves the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "bad.lua", "local = =\n");
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    try testing.expectEqual(Outcome.refused, formatFile(testing.allocator, testing.io, tmp.dir, "bad.lua", false, &diags));
    try testing.expect(diags.count() > 0);
    const got = try readTmp(tmp.dir, "bad.lua");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("local = =\n", got);
}

test "run walks directories, skips the fixed list and other extensions, and counts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/sub");
    try tmp.dir.createDirPath(testing.io, "node_modules");
    try writeTmp(tmp.dir, "src/a.lua", "local x=1\n");
    try writeTmp(tmp.dir, "src/sub/b.mah", "local y=2\n");
    try writeTmp(tmp.dir, "src/notes.txt", "local z=3\n");
    try writeTmp(tmp.dir, "node_modules/c.lua", "local w=4\n");
    const s = run(testing.allocator, testing.io, tmp.dir, &.{"src", "node_modules"}, false);
    // node_modules named explicitly is walked; only a nested one is skipped.
    try testing.expectEqual(@as(usize, 3), s.changed);
    try testing.expectEqual(@as(u8, 0), s.exitCode(false));
    const txt = try readTmp(tmp.dir, "src/notes.txt");
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings("local z=3\n", txt);
}

test "run does not enter a skipped directory met during a walk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/target");
    try writeTmp(tmp.dir, "proj/target/x.lua", "local x=1\n");
    try writeTmp(tmp.dir, "proj/y.lua", "local y = 1\n");
    const s = run(testing.allocator, testing.io, tmp.dir, &.{"proj"}, true);
    try testing.expectEqual(@as(usize, 0), s.changed);
    try testing.expectEqual(@as(u8, 0), s.exitCode(true));
}

test "exit code: check with changes, refusals" {
    try testing.expectEqual(@as(u8, 1), (Summary{ .changed = 1 }).exitCode(true));
    try testing.expectEqual(@as(u8, 0), (Summary{ .changed = 1 }).exitCode(false));
    try testing.expectEqual(@as(u8, 1), (Summary{ .refused = 1 }).exitCode(false));
}
