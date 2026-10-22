//! `mahina viz`: serve the trace visualiser (viz/) on localhost.
//!
//! The UI is a static SolidJS app with the VM compiled to wasm, so almost all
//! of this is a file server for the assets `build.zig` embedded
//! (`-Dviz-dist`, the `viz_assets` module). Three dynamic routes:
//!
//!   GET  /trace/<name>  the `.mahinatrace` given on the command line, re-read
//!                       per request (re-run the emit, then reload the page);
//!                       the page opens on `/?src=trace/<name>`.
//!   GET  /project       the program given on the command line: its file and
//!                       the source files of its directory tree (what it can
//!                       `require`), re-read per request; the page opens on
//!                       `/?project=project`. Bounded (`project_*_limit`).
//!   POST /run           the differential validator's native side, the same
//!                       contract as the vite dev middleware
//!                       (viz/vite.config.ts): `{files, entry, args}` in, this
//!                       binary's artifacts + stdout out (base64), so the
//!                       validator works outside `vite dev` too. The files are
//!                       written into a fresh directory the run starts in.
//!
//! `/run` executes arbitrary code, so the server binds 127.0.0.1 only and
//! answers nothing whose `Host` isn't this listener (DNS rebinding) or whose
//! `Origin`, when sent, isn't this page (cross-site requests). A cross-site
//! page also can't send the `application/json` body `/run` requires without a
//! CORS preflight, which this server never grants.
//!
//! CLI-only and the one home of `std.Io.net` / `std.http` (Rule Z-2): neither
//! the VM core nor the embedding library imports it.

const std = @import("std");
const builtin = @import("builtin");
const mahina = @import("mahina");
const relpath = mahina.relpath;
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;

/// One embedded asset; the type the generated (or stub) `viz_assets` declares.
pub const File = @import("viz_assets").File;

pub const Options = struct {
    /// 0 asks the OS for a free port.
    port: u16 = 0,
    open_browser: bool = true,
    /// A `.mahinatrace` to serve at `/trace/<basename>` and open on start.
    trace_path: ?[]const u8 = null,
    /// A program to serve at `/project` (with its directory's other source
    /// files) and open on start.
    program_path: ?[]const u8 = null,
};

/// Per-run limits for `/run`, which spawns this binary twice per request.
const run_timeout_ns = 15 * std.time.ns_per_s;
const run_output_limit = 16 * 1024 * 1024;
const run_body_limit = 4 * 1024 * 1024;
/// The largest artifact `/run` reads back (keyframes of big heaps).
const artifact_limit = 256 * 1024 * 1024;
/// `/project` bounds, so `mahina viz` on a script in a big tree (a home
/// directory) answers quickly with what it found and says the list is cut:
/// source files sent, their total bytes, directory entries looked at, and how
/// deep it descends.
const project_file_limit = 256;
const project_bytes_limit = 8 * 1024 * 1024;
const project_entry_limit = 20_000;
const project_depth_limit = 8;

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    files: []const File,
    trace_path: ?[]const u8,
    /// `/trace/<percent-encoded basename>`, when `trace_path` is set.
    trace_url: ?[]const u8,
    /// The program `/project` serves, when one was given.
    program_path: ?[]const u8 = null,
    /// This binary, which `/run` spawns.
    exe_path: []const u8,
    /// Where `/run` makes its per-request directory.
    tmp_root: []const u8,
    listener: Io.net.Server,
    port: u16,

    pub fn init(
        gpa: Allocator,
        io: Io,
        files: []const File,
        trace_path: ?[]const u8,
        exe_path: []const u8,
        tmp_root: []const u8,
        port: u16,
    ) !Server {
        const address = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        const trace_url = if (trace_path) |p| try traceUrl(gpa, std.fs.path.basename(p)) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .files = files,
            .trace_path = trace_path,
            .trace_url = trace_url,
            .exe_path = exe_path,
            .tmp_root = tmp_root,
            .listener = listener,
            .port = listener.socket.address.getPort(),
        };
    }

    pub fn deinit(s: *Server) void {
        if (s.trace_url) |u| s.gpa.free(u);
        s.listener.deinit(s.io);
        s.* = undefined;
    }

    /// Accept connections until the listener fails; one concurrent task per
    /// connection. Not `Group.async`: past its limit that runs the task in
    /// place, and a browser's idle keep-alive connection would then stall
    /// `accept`. If no task can be had, the connection is served in place.
    pub fn run(s: *Server) !void {
        var group: Io.Group = .init;
        defer group.cancel(s.io);
        while (true) {
            const stream = try s.listener.accept(s.io);
            group.concurrent(s.io, serveConnection, .{ s, stream }) catch s.serveConnection(stream);
        }
    }

    pub fn serveConnection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        var recv_buffer: [8192]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var conn_reader = stream.reader(s.io, &recv_buffer);
        var conn_writer = stream.writer(s.io, &send_buffer);
        var server = http.Server.init(&conn_reader.interface, &conn_writer.interface);
        while (server.reader.state == .ready) {
            var request = server.receiveHead() catch return;
            s.serveRequest(&request) catch return;
        }
    }

    fn serveRequest(s: *Server, request: *http.Server.Request) !void {
        const head = request.head;
        if (!requestAllowed(request, s.port)) {
            return respondText(request, .forbidden, "forbidden: not a request from this page\n");
        }
        if (head.expect != null) {
            return respondText(request, .expectation_failed, "expectations are not supported\n");
        }
        const path = urlPath(head.target);

        if (std.mem.eql(u8, path, "/run")) {
            if (head.method != .POST) return respondText(request, .method_not_allowed, "POST only\n");
            return s.serveRun(request);
        }
        if (head.method != .GET and head.method != .HEAD) {
            return respondText(request, .method_not_allowed, "GET only\n");
        }
        if (s.trace_url) |url| if (std.mem.eql(u8, path, url)) return s.serveTrace(request);
        if (s.program_path != null and std.mem.eql(u8, path, "/project")) return s.serveProject(request);

        const asset_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        const file = findFile(s.files, asset_path) orelse {
            return respondText(request, .not_found, "not found\n");
        };
        try request.respond(file.data, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = contentType(asset_path) },
            .{ .name = "cache-control", .value = "no-cache" },
        } });
    }

    fn serveTrace(s: *Server, request: *http.Server.Request) !void {
        const bytes = Io.Dir.cwd().readFileAlloc(s.io, s.trace_path.?, s.gpa, .limited(artifact_limit)) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "cannot read {s}: {s}\n", .{ s.trace_path.?, @errorName(err) }) catch "cannot read the trace\n";
            return respondText(request, .not_found, msg);
        };
        defer s.gpa.free(bytes);
        try request.respond(bytes, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        } });
    }

    fn serveProject(s: *Server, request: *http.Server.Request) !void {
        const reply = s.projectJson() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "cannot read {s}: {s}", .{ s.program_path.?, @errorName(err) }) catch "cannot read the program";
            return respondJsonError(s.gpa, request, .not_found, msg);
        };
        defer s.gpa.free(reply);
        try request.respond(reply, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-cache" },
        } });
    }

    /// The `/project` reply: `{"entry": path, "files": [{"path", "text"}],
    /// "truncated"?: why}`. The entry first, then every source file of its
    /// directory tree by path (relative to the entry's directory, `/`
    /// separated). Hidden entries, build/dependency directories, symlinks and
    /// non-UTF-8 files are skipped; past a `project_*_limit` the walk stops and
    /// `truncated` says which.
    fn projectJson(s: *Server) ![]u8 {
        const gpa = s.gpa;
        const io = s.io;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const program = s.program_path.?;
        const entry = std.fs.path.basename(program);
        var dir = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(program) orelse ".", .{ .iterate = true });
        defer dir.close(io);

        const ProjectFile = struct { path: []const u8, text: []const u8 };
        var files: std.ArrayList(ProjectFile) = .empty;
        const entry_text = try dir.readFileAlloc(io, entry, arena, .limited(project_bytes_limit));
        var total: usize = entry_text.len;
        var truncated: ?[]const u8 = null;

        var walker = try dir.walkSelectively(arena);
        defer walker.deinit();
        var seen: usize = 0;
        walk: while (try walker.next(io)) |e| {
            seen += 1;
            if (seen > project_entry_limit) {
                truncated = "mahina viz: stopped looking for the program's files after 20000 directory entries";
                break;
            }
            if (e.basename.len == 0 or e.basename[0] == '.') continue;
            switch (e.kind) {
                .directory => {
                    if (skippedDir(e.basename)) continue;
                    if (walker.stack.items.len > project_depth_limit) continue;
                    try walker.enter(io, e);
                },
                .file => {
                    if (!isSourceName(e.basename)) continue;
                    const path = try projectPath(arena, e.path);
                    if (std.mem.eql(u8, path, entry)) continue;
                    if (files.items.len + 1 >= project_file_limit) {
                        truncated = "mahina viz: the program's directory has more than 256 source files; only some are open";
                        break :walk;
                    }
                    const text = e.dir.readFileAlloc(io, e.basename, arena, .limited(project_bytes_limit - total)) catch |err| switch (err) {
                        error.StreamTooLong => {
                            truncated = "mahina viz: the program's source files pass 8 MiB; only some are open";
                            break :walk;
                        },
                        else => continue,
                    };
                    if (!std.unicode.utf8ValidateSlice(text)) continue;
                    total += text.len;
                    try files.append(arena, .{ .path = path, .text = text });
                },
                else => {},
            }
        }
        std.mem.sort(ProjectFile, files.items, {}, struct {
            fn lt(_: void, a: ProjectFile, b: ProjectFile) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lt);

        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"entry\":");
        try writeJsonString(w, entry);
        try w.writeAll(",\"files\":[{\"path\":");
        try writeJsonString(w, entry);
        try w.writeAll(",\"text\":");
        try writeJsonString(w, entry_text);
        try w.writeByte('}');
        for (files.items) |f| {
            try w.writeAll(",{\"path\":");
            try writeJsonString(w, f.path);
            try w.writeAll(",\"text\":");
            try writeJsonString(w, f.text);
            try w.writeByte('}');
        }
        try w.writeByte(']');
        if (truncated) |t| {
            try w.writeAll(",\"truncated\":");
            try writeJsonString(w, t);
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }

    const RunFile = struct {
        path: []const u8,
        text: []const u8,
    };

    const RunRequest = struct {
        files: []const RunFile,
        entry: []const u8,
        args: []const []const u8 = &.{},
    };

    /// A `RunRequest` whose paths are normalized and checked: each inside the
    /// program's directory (a path that climbs out of the run's temp
    /// directory is refused, never written) and the entry among them.
    const RunProgram = struct {
        files: []const RunFile,
        entry: []const u8,
        args: []const []const u8,
    };

    fn checkRunRequest(arena: Allocator, req: RunRequest) error{ BadPath, NoEntry, OutOfMemory }!RunProgram {
        const files = try arena.alloc(RunFile, req.files.len);
        for (req.files, files) |f, *out| {
            var buf: [relpath.max_len]u8 = undefined;
            const norm = relpath.normalize(&buf, f.path) orelse return error.BadPath;
            out.* = .{ .path = try arena.dupe(u8, norm), .text = f.text };
        }
        var buf: [relpath.max_len]u8 = undefined;
        const entry = relpath.normalize(&buf, req.entry) orelse return error.NoEntry;
        for (files) |f| {
            if (std.mem.eql(u8, f.path, entry)) return .{ .files = files, .entry = f.path, .args = req.args };
        }
        return error.NoEntry;
    }

    fn serveRun(s: *Server, request: *http.Server.Request) !void {
        if (!isJson(request.head.content_type)) {
            return respondJsonError(s.gpa, request, .unsupported_media_type, "POST /run takes application/json");
        }
        if (request.head.content_length) |n| if (n > run_body_limit) {
            return respondJsonError(s.gpa, request, .payload_too_large, "the source is too large");
        };
        // Reading the body invalidates the strings in `request.head`.
        var body_buffer: [8192]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buffer);
        const body = body_reader.allocRemaining(s.gpa, .limited(run_body_limit)) catch |err| switch (err) {
            error.StreamTooLong => return respondJsonError(s.gpa, request, .payload_too_large, "the source is too large"),
            else => return err,
        };
        defer s.gpa.free(body);

        const parsed = std.json.parseFromSlice(RunRequest, s.gpa, body, .{ .ignore_unknown_fields = true }) catch {
            return respondJsonError(s.gpa, request, .bad_request, "expected {\"files\": [{\"path\": string, \"text\": string}], \"entry\": string, \"args\": [string]}");
        };
        defer parsed.deinit();
        var check_arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer check_arena.deinit();
        const program = checkRunRequest(check_arena.allocator(), parsed.value) catch |err| switch (err) {
            error.BadPath => return respondJsonError(s.gpa, request, .bad_request, "a file path is not inside the program's directory"),
            error.NoEntry => return respondJsonError(s.gpa, request, .bad_request, "the entry is not among the files"),
            error.OutOfMemory => return err,
        };

        const reply = s.runNative(program) catch |err| {
            return respondJsonError(s.gpa, request, .internal_server_error, @errorName(err));
        };
        defer s.gpa.free(reply);
        try request.respond(reply, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        } });
    }

    /// Run the program through this binary the way the vite middleware runs
    /// the native CLI: once with the three emit flags (the determinism
    /// compare), once more with `--jit-native --emit-coverage` (the coverage
    /// panel's native split; best-effort). The files go under `prog/` of a
    /// fresh directory, which both runs start in, so `require`/`loadfile`/
    /// `dofile` read them by the same relative paths as the wasm run. Returns
    /// the JSON reply.
    fn runNative(s: *Server, req: RunProgram) ![]u8 {
        const gpa = s.gpa;
        const io = s.io;

        var name_buf: [32]u8 = undefined;
        const dir_name = tmpDirName(io, &name_buf);
        var tmp_root = try Io.Dir.openDirAbsolute(io, s.tmp_root, .{});
        defer tmp_root.close(io);
        try tmp_root.createDir(io, dir_name, .default_dir);
        defer tmp_root.deleteTree(io, dir_name) catch {};
        var dir = try tmp_root.openDir(io, dir_name, .{});
        defer dir.close(io);

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = struct {
            fn of(a: Allocator, root: []const u8, sub: []const u8, file: []const u8) ![]const u8 {
                return std.fs.path.join(a, &.{ root, sub, file });
            }
        }.of;
        const prog = try path(arena, s.tmp_root, dir_name, "prog");
        const kf = try path(arena, s.tmp_root, dir_name, "k.mahinasnap");
        const ef = try path(arena, s.tmp_root, dir_name, "e.mahinaeff");
        const tr = try path(arena, s.tmp_root, dir_name, "t.mahinatrace");
        const cov = try path(arena, s.tmp_root, dir_name, "c.mahinacov");
        var prog_dir = try dir.createDirPathOpen(io, "prog", .{});
        defer prog_dir.close(io);
        for (req.files) |f| {
            if (std.fs.path.dirnamePosix(f.path)) |sub| try prog_dir.createDirPath(io, sub);
            try prog_dir.writeFile(io, .{ .sub_path = f.path, .data = f.text });
        }
        // The entry by its relative path, from inside the program's directory:
        // that is the native run's `arg[0]`, as the wasm run's is the entry's.
        const src = req.entry;

        // Script args go after the source path: the CLI fills arg[1..] from them.
        var diff_argv: std.ArrayList([]const u8) = .empty;
        try diff_argv.appendSlice(arena, &.{ s.exe_path, "--emit-traces", tr, "--emit-keyframe", kf, "--emit-effects", ef, src });
        try diff_argv.appendSlice(arena, req.args);
        var cov_argv: std.ArrayList([]const u8) = .empty;
        try cov_argv.appendSlice(arena, &.{ s.exe_path, "--jit-native", "--emit-coverage", cov, src });
        try cov_argv.appendSlice(arena, req.args);

        const diff = try s.runChild(arena, diff_argv.items, prog);
        if (s.runChild(arena, cov_argv.items, prog)) |_| {} else |_| {}

        const read = struct {
            fn file(d: Io.Dir, i: Io, a: Allocator, name: []const u8) []const u8 {
                return d.readFileAlloc(i, name, a, .limited(artifact_limit)) catch "";
            }
        }.file;

        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"status\":{d},\"stdout\":", .{@intFromBool(!diff.ok)});
        try writeJsonString(w, diff.stdout);
        try w.writeAll(",\"diagnostics\":");
        try writeJsonString(w, diff.stderr);
        const artifacts = [_]struct { []const u8, []const u8 }{
            .{ "keyframe", "k.mahinasnap" },
            .{ "effects", "e.mahinaeff" },
            .{ "trace", "t.mahinatrace" },
            .{ "coverage", "c.mahinacov" },
        };
        for (artifacts) |a| {
            try w.print(",\"{s}\":\"", .{a[0]});
            try std.base64.standard.Encoder.encodeWriter(w, read(dir, io, arena, a[1]));
            try w.writeByte('"');
        }
        try w.writeByte('}');
        return out.toOwnedSlice();
    }

    const ChildResult = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

    fn runChild(s: *Server, arena: Allocator, argv: []const []const u8, cwd: []const u8) !ChildResult {
        const deadline: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(run_timeout_ns), .clock = .awake } };
        const result = std.process.run(arena, s.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdout_limit = .limited(run_output_limit),
            .stderr_limit = .limited(run_output_limit),
            .timeout = deadline.toDeadline(s.io),
        }) catch |err| switch (err) {
            error.Timeout => return .{ .ok = false, .stdout = "", .stderr = "mahina viz: the run timed out after 15s\n" },
            error.StreamTooLong => return .{ .ok = false, .stdout = "", .stderr = "mahina viz: the run printed more than 16 MiB\n" },
            else => return err,
        };
        return .{ .ok = result.term.success(), .stdout = result.stdout, .stderr = result.stderr };
    }
};

/// Serve `opts` until interrupted. Prints the URL and, unless told not to,
/// opens it in the default browser.
pub fn serve(gpa: Allocator, io: Io, files: []const File, environ: *const std.process.Environ.Map, opts: Options) !void {
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);
    var s = try Server.init(gpa, io, files, opts.trace_path, exe_path, tmpRoot(environ), opts.port);
    defer s.deinit();
    s.program_path = opts.program_path;

    var url_buf: [512]u8 = undefined;
    const url = if (s.trace_url) |t|
        try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/?src={s}", .{ s.port, t[1..] })
    else if (s.program_path != null)
        try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/?project=project", .{s.port})
    else
        try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{s.port});
    var line_buf: [600]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "mahina viz: serving on {s} (Ctrl-C stops)\n", .{url});
    Io.File.stdout().writeStreamingAll(io, line) catch {};

    if (opts.open_browser) openBrowser(io, url);
    try s.run();
}

/// The OS temp directory: TMPDIR on POSIX, TEMP/TMP on Windows (where an
/// msys shell's TMPDIR is a POSIX-style path the native API can't open).
fn tmpRoot(environ: *const std.process.Environ.Map) []const u8 {
    const names: []const []const u8 = if (builtin.os.tag == .windows) &.{ "TEMP", "TMP" } else &.{"TMPDIR"};
    for (names) |name| {
        if (environ.get(name)) |v| if (v.len != 0 and std.fs.path.isAbsolute(v)) return v;
    }
    return if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
}

/// `mahina-viz-<16 random hex digits>`: one directory per `/run`.
fn tmpDirName(io: Io, buf: *[32]u8) []const u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bufPrint(buf, "mahina-viz-{x}", .{@as([]const u8, &bytes)}) catch unreachable;
}

fn openBrowser(io: Io, url: []const u8) void {
    // The child outlives nothing we track; like `zig std`, the task is leaked.
    const future = io.concurrent(openBrowserTask, .{ io, url }) catch {
        std.log.warn("cannot open a browser; open {s} yourself", .{url});
        return;
    };
    _ = future;
}

fn openBrowserTask(io: Io, url: []const u8) void {
    const opener = switch (builtin.os.tag) {
        .windows => "explorer",
        .macos => "open",
        else => "xdg-open",
    };
    var child = std.process.spawn(io, .{
        .argv = &.{ opener, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

/// Directories `/project` never descends into: dependency and build trees.
fn skippedDir(name: []const u8) bool {
    const skipped = [_][]const u8{ "node_modules", "zig-cache", "zig-out" };
    for (skipped) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// A file `require`/`loadfile`/`dofile` would read: `.mah`, `.mahina`, `.lua`.
fn isSourceName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.mem.eql(u8, ext, ".mah") or std.mem.eql(u8, ext, ".mahina") or std.mem.eql(u8, ext, ".lua");
}

/// A walker path as the UI names files: `/`-separated (Windows walks `\`).
fn projectPath(arena: Allocator, walked: []const u8) ![]const u8 {
    const path = try arena.dupe(u8, walked);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
    return path;
}

/// The target without its query string or fragment.
fn urlPath(target: []const u8) []const u8 {
    const end = std.mem.findAny(u8, target, "?#") orelse target.len;
    return target[0..end];
}

fn findFile(files: []const File, path: []const u8) ?File {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

fn contentType(path: []const u8) []const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".ico", "image/x-icon" },
        .{ ".txt", "text/plain; charset=utf-8" },
    };
    const ext = std.fs.path.extension(path);
    for (types) |t| if (std.mem.eql(u8, ext, t[0])) return t[1];
    return "application/octet-stream";
}

fn isJson(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    const end = std.mem.findScalar(u8, ct, ';') orelse ct.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, ct[0..end], " \t"), "application/json");
}

/// The `Host` must name this listener and the `Origin`, if any, this page.
fn requestAllowed(request: *const http.Server.Request, port: u16) bool {
    var host: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
    }
    return originAllowed(host, origin, port);
}

fn originAllowed(host: ?[]const u8, origin: ?[]const u8, port: u16) bool {
    const h = host orelse return false;
    var buf: [2][32]u8 = undefined;
    const ours = [_][]const u8{
        std.fmt.bufPrint(&buf[0], "127.0.0.1:{d}", .{port}) catch unreachable,
        std.fmt.bufPrint(&buf[1], "localhost:{d}", .{port}) catch unreachable,
    };
    const host_ok = for (ours) |o| {
        if (std.ascii.eqlIgnoreCase(h, o)) break true;
    } else false;
    if (!host_ok) return false;
    const o = origin orelse return true;
    const scheme = "http://";
    return o.len == scheme.len + h.len and
        std.mem.startsWith(u8, o, scheme) and
        std.ascii.eqlIgnoreCase(o[scheme.len..], h);
}

/// `/trace/` plus the basename with everything but RFC 3986 unreserved
/// characters percent-encoded.
fn traceUrl(gpa: Allocator, basename: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("/trace/");
    for (basename) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.writer.writeByte(c);
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}

/// A JSON string of `bytes`, with each invalid UTF-8 sequence replaced by
/// U+FFFD the way the dev server's `Buffer.toString("utf8")` does (std's
/// encoder requires valid UTF-8).
fn writeJsonString(w: *Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const run_end = validPrefix(bytes[i..]) + i;
        try std.json.Stringify.encodeJsonStringChars(bytes[i..run_end], .{}, w);
        i = run_end;
        if (i < bytes.len) {
            try w.writeAll("\u{FFFD}");
            i += invalidSequenceLen(bytes[i..]);
        }
    }
    try w.writeByte('"');
}

/// Length of the longest valid UTF-8 prefix of `bytes`.
fn validPrefix(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + n > bytes.len) return i;
        _ = std.unicode.utf8Decode(bytes[i..][0..n]) catch return i;
        i += n;
    }
    return i;
}

/// How many bytes one U+FFFD replaces at the start of `bytes` (which begins
/// with an invalid sequence): the lead byte plus the continuation bytes that
/// follow it, up to the length the lead byte claims.
fn invalidSequenceLen(bytes: []const u8) usize {
    const claimed: usize = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 1;
    var n: usize = 1;
    while (n < claimed and n < bytes.len and bytes[n] & 0xC0 == 0x80) n += 1;
    return n;
}

fn respondText(request: *http.Server.Request, status: http.Status, text: []const u8) !void {
    try request.respond(text, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    } });
}

fn respondJsonError(gpa: Allocator, request: *http.Server.Request, status: http.Status, message: []const u8) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"error\":");
    try writeJsonString(&out.writer, message);
    try out.writer.writeByte('}');
    try request.respond(out.written(), .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
    } });
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "viz_server: urlPath drops the query and fragment" {
    try testing.expectEqualStrings("/", urlPath("/?src=trace/a.mahinatrace"));
    try testing.expectEqualStrings("/assets/x.js", urlPath("/assets/x.js#frag"));
    try testing.expectEqualStrings("/run", urlPath("/run"));
}

test "viz_server: content types by extension" {
    try testing.expectEqualStrings("application/wasm", contentType("/mahina.wasm"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", contentType("/assets/index-x.js"));
    try testing.expectEqualStrings("application/octet-stream", contentType("/README"));
}

test "viz_server: only this listener's host and page origin are allowed" {
    try testing.expect(originAllowed("127.0.0.1:8080", null, 8080));
    try testing.expect(originAllowed("localhost:8080", "http://localhost:8080", 8080));
    try testing.expect(originAllowed("LOCALHOST:8080", "http://localhost:8080", 8080));
    // No Host, another port, a rebinding name, or a cross-site page.
    try testing.expect(!originAllowed(null, null, 8080));
    try testing.expect(!originAllowed("127.0.0.1:8081", null, 8080));
    try testing.expect(!originAllowed("evil.example:8080", null, 8080));
    try testing.expect(!originAllowed("127.0.0.1:8080", "http://evil.example", 8080));
    try testing.expect(!originAllowed("127.0.0.1:8080", "https://127.0.0.1:8080", 8080));
    try testing.expect(!originAllowed("127.0.0.1:8080", "null", 8080));
}

test "viz_server: isJson ignores parameters and case" {
    try testing.expect(isJson("application/json"));
    try testing.expect(isJson("Application/JSON; charset=utf-8"));
    try testing.expect(!isJson("text/plain"));
    try testing.expect(!isJson(null));
}

test "viz_server: traceUrl percent-encodes the basename" {
    const url = try traceUrl(testing.allocator, "my run #1.mahinatrace");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("/trace/my%20run%20%231.mahinatrace", url);
}

test "viz_server: writeJsonString escapes and replaces invalid UTF-8" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJsonString(&out.writer, "a\"b\n\xffc\xe2\x82d\xe2\x82\xac");
    try testing.expectEqualStrings("\"a\\\"b\\n\u{FFFD}c\u{FFFD}d\u{20AC}\"", out.written());
}

/// Send `request` to `server` over a real loopback connection and return the
/// response's status line plus body.
fn roundTrip(server: *Server, request: []const u8) ![]u8 {
    const io = testing.io;
    var accept_future = try io.concurrent(acceptOne, .{server});
    defer accept_future.cancel(io) catch {}; // idempotent after the await below

    const address = Io.net.IpAddress.parse("127.0.0.1", server.port) catch unreachable;
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const response = try reader.interface.allocRemaining(testing.allocator, .limited(1 << 20));
    try accept_future.await(io);
    return response;
}

fn acceptOne(server: *Server) !void {
    const stream = try server.listener.accept(server.io);
    server.serveConnection(stream);
}

test "viz_server: serves embedded files and refuses foreign origins over loopback" {
    const files = [_]File{
        .{ .path = "/index.html", .data = "<p>hi</p>" },
        .{ .path = "/mahina.wasm", .data = "\x00asm" },
    };
    var server = try Server.init(testing.allocator, testing.io, &files, null, "/nonexistent", "/tmp", 0);
    defer server.deinit();
    var host_buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{server.port});

    var req_buf: [512]u8 = undefined;
    {
        const req = try std.fmt.bufPrint(&req_buf, "GET /?src=x HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host});
        const resp = try roundTrip(&server, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.find(u8, resp, "content-type: text/html; charset=utf-8\r\n") != null);
        try testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n<p>hi</p>"));
    }
    {
        const req = try std.fmt.bufPrint(&req_buf, "GET /mahina.wasm HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host});
        const resp = try roundTrip(&server, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.find(u8, resp, "content-type: application/wasm\r\n") != null);
    }
    {
        const req = try std.fmt.bufPrint(&req_buf, "GET /missing.js HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host});
        const resp = try roundTrip(&server, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found\r\n"));
    }
    {
        // A cross-site page posting to /run is refused before anything runs.
        const req = try std.fmt.bufPrint(&req_buf, "POST /run HTTP/1.1\r\nHost: {s}\r\nOrigin: http://evil.example\r\n" ++
            "Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi", .{host});
        const resp = try roundTrip(&server, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403 Forbidden\r\n"));
    }
    {
        // Same origin but not JSON (a "simple" request no preflight guards).
        const req = try std.fmt.bufPrint(&req_buf, "POST /run HTTP/1.1\r\nHost: {s}\r\nOrigin: http://{s}\r\n" ++
            "Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi", .{ host, host });
        const resp = try roundTrip(&server, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 415 Unsupported Media Type\r\n"));
    }
    {
        // A rebinding name for the same socket.
        const req = try std.fmt.bufPrint(&req_buf, "GET / HTTP/1.1\r\nHost: evil.example:{d}\r\nConnection: close\r\n\r\n", .{server.port});
        const resp = try roundTrip(&server, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403 Forbidden\r\n"));
    }
}
test "viz_server: a /run program's paths are normalized and must stay inside its directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]Server.RunFile{
        .{ .path = "./main.mah", .text = "require('lib.util')" },
        .{ .path = "lib//util.mah", .text = "return 1" },
    };
    const ok = try Server.checkRunRequest(arena, .{ .files = &files, .entry = "main.mah" });
    try testing.expectEqualStrings("main.mah", ok.entry);
    try testing.expectEqualStrings("main.mah", ok.files[0].path);
    try testing.expectEqualStrings("lib/util.mah", ok.files[1].path);

    const escaping = [_]Server.RunFile{.{ .path = "../outside.mah", .text = "" }};
    try testing.expectError(error.BadPath, Server.checkRunRequest(arena, .{ .files = &escaping, .entry = "../outside.mah" }));
    const absolute = [_]Server.RunFile{.{ .path = "/etc/x.mah", .text = "" }};
    try testing.expectError(error.BadPath, Server.checkRunRequest(arena, .{ .files = &absolute, .entry = "x.mah" }));
    try testing.expectError(error.NoEntry, Server.checkRunRequest(arena, .{ .files = &files, .entry = "other.mah" }));
}

test "viz_server: /project lists the program and the source files of its tree" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mah", .data = "local u = require('lib.util')\n" });
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/util.mah", .data = "return {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "old.lua", .data = "print(1)\n" });
    // Not sources, hidden, a dependency tree, not UTF-8: all left out.
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hi" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/x.lua", .data = "" });
    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/y.lua", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin.lua", .data = "\xff\xfe" });

    var program_buf: [128]u8 = undefined;
    const program = try std.fmt.bufPrint(&program_buf, ".zig-cache/tmp/{s}/main.mah", .{tmp.sub_path});
    var server = try Server.init(testing.allocator, io, &.{}, null, "/nonexistent", "/tmp", 0);
    defer server.deinit();
    server.program_path = program;

    const json = try server.projectJson();
    defer testing.allocator.free(json);
    const Payload = struct {
        entry: []const u8,
        files: []const struct { path: []const u8, text: []const u8 },
        truncated: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Payload, testing.allocator, json, .{});
    defer parsed.deinit();
    const p = parsed.value;
    try testing.expectEqualStrings("main.mah", p.entry);
    try testing.expectEqual(@as(usize, 3), p.files.len);
    // The entry first, then the rest by path.
    try testing.expectEqualStrings("main.mah", p.files[0].path);
    try testing.expectEqualStrings("local u = require('lib.util')\n", p.files[0].text);
    try testing.expectEqualStrings("lib/util.mah", p.files[1].path);
    try testing.expectEqualStrings("old.lua", p.files[2].path);
    try testing.expectEqual(@as(?[]const u8, null), p.truncated);
}
