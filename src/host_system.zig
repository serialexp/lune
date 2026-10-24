//! The real-OS `HostSystem` (doc 65 §5.1), shared by the CLI (`main.zig`) and
//! libmahina (`capi.zig`). One of the `std.Io` users Rule Z-2 confines, beside
//! `io.zig` and `viz_server.zig`: a toolchain bump that moves the file API
//! is a fix here, not in the VM.
//!
//! Never compiled into the wasm build (the browser has no system interface).

const std = @import("std");
const builtin = @import("builtin");
const seam = @import("system.zig");
const mio = @import("io.zig");

const Io = std.Io;
const HostSystem = seam.HostSystem;

pub const RealSystem = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The process environment (the CLI's `Init.environ_map`). Null in
    /// libmahina, which reads the host process's through libc.
    env_map: ?*std.process.Environ.Map = null,
    /// The bytes behind the last borrowed result (`readFile`), freed on the
    /// next call that borrows and at `deinit`.
    last: ?[]u8 = null,
    /// The open files, by the VM's handle id (doc 65 §4.1). stdin (id 0) is
    /// added on its first use. Files the program never closed are flushed
    /// and closed by `deinit`.
    handles: std.AutoHashMapUnmanaged(seam.FileId, *Handle) = .empty,

    /// For the CLI, with the process environment from `Init`.
    pub fn init(gpa: std.mem.Allocator, io: Io, env_map: ?*std.process.Environ.Map) RealSystem {
        return .{ .gpa = gpa, .io = io, .env_map = env_map };
    }

    pub fn deinit(self: *RealSystem) void {
        self.dropLast();
        var it = self.handles.valueIterator();
        while (it.next()) |h| {
            _ = h.*.flushWrites(self.io);
            self.destroyHandle(h.*);
        }
        self.handles.deinit(self.gpa);
    }

    pub fn system(self: *RealSystem) HostSystem {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: HostSystem.VTable = .{
        .readFile = &readFile,
        .getenv = &getenv,
        .open = &open,
        .tmpfile = &tmpfile,
        .fill = &fill,
        .consume = &consume,
        .write = &write,
        .seek = &seek,
        .flush = &flush,
        .setvbuf = &setvbuf,
        .close = &close,
        .fingerprint = &fingerprint,
        .reopen = &reopen,
    };

    fn of(ctx: *anyopaque) *RealSystem {
        return @ptrCast(@alignCast(ctx));
    }

    fn dropLast(self: *RealSystem) void {
        if (self.last) |b| self.gpa.free(b);
        self.last = null;
    }

    fn readFile(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self = of(ctx);
        self.dropLast();
        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            Io.Limit.limited(mio.max_source_bytes),
        ) catch return null; // missing/unreadable/too large: "cannot open"
        self.last = bytes;
        return bytes;
    }

    // ---- files (doc 65 §5.1) ----

    /// The read buffer: how much one `fill` asks the OS for. A line loop over
    /// a large file makes one read syscall per this many bytes.
    const read_buffer_len = 64 * 1024;
    /// The write buffer. A write at least this long goes straight to the OS
    /// instead of being copied in (Phase 0 measured the copy as the cost of a
    /// larger stdout buffer).
    const write_buffer_len = 8 * 1024;

    /// One open file. Its position is the program's (`pos`): the read buffer
    /// holds the bytes from `pos` on, the write buffer the bytes just before
    /// it, and at most one of them is non-empty. A regular file reads and
    /// writes positionally at `pos`; anything else (stdin, a pipe, a device)
    /// streams and cannot seek.
    const Handle = struct {
        file: Io.File,
        positional: bool,
        /// `a` mode: every write goes to the end of the file.
        append: bool,
        pos: u64 = 0,
        rbuf: []u8 = &.{},
        rstart: usize = 0,
        rend: usize = 0,
        wbuf: []u8 = &.{},
        wlen: usize = 0,
        buffering: seam.BufferMode = .full,
        /// A temporary file the OS could not unlink while open (Windows):
        /// removed at close.
        remove_at_close: ?[]u8 = null,
        /// Not a file this system opened (stdin): never closed by it.
        borrowed: bool = false,

        /// Write out the write buffer. On failure the buffered bytes are
        /// dropped, as C stdio drops them.
        fn flushWrites(h: *Handle, io: Io) ?seam.ErrorClass {
            if (h.wlen == 0) return null;
            const bytes = h.wbuf[0..h.wlen];
            h.wlen = 0;
            return h.writeOut(io, bytes);
        }

        /// Write `bytes` to the OS at the handle's position, which advances
        /// past them. In append mode that position is the end of the file.
        fn writeOut(h: *Handle, io: Io, bytes: []const u8) ?seam.ErrorClass {
            if (!h.positional) {
                h.file.writeStreamingAll(io, bytes) catch |e| return classOf(e);
                return null;
            }
            // The position counts the bytes now being written already
            // (`write` advanced it), so they start `bytes.len` before it.
            const at = if (h.append) h.file.length(io) catch |e| return classOf(e) else h.pos - bytes.len;
            h.file.writePositionalAll(io, bytes, at) catch |e| return classOf(e);
            if (h.append) h.pos = at + bytes.len;
            return null;
        }
    };

    /// The class of an OS error (doc 65 §4.2): what the program sees,
    /// instead of the OS's own text.
    fn classOf(err: anyerror) seam.ErrorClass {
        return switch (err) {
            error.FileNotFound, error.NotDir => .not_found,
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .permission_denied,
            error.PathAlreadyExists => .exists,
            error.IsDir => .is_a_directory,
            error.Unseekable => .not_seekable,
            error.NotOpenForReading => .not_readable,
            error.NotOpenForWriting => .not_writable,
            else => .other,
        };
    }

    fn handleOf(self: *RealSystem, id: seam.FileId) ?*Handle {
        if (self.handles.get(id)) |h| return h;
        if (id != seam.stdin_id) return null;
        // stdin on first use. A redirected regular file reads positionally;
        // a terminal or pipe streams.
        const file = Io.File.stdin();
        const st = file.stat(self.io) catch null;
        return self.addHandle(id, file, .{ .positional = if (st) |s| s.kind == .file else false, .borrowed = true }) catch null;
    }

    fn addHandle(self: *RealSystem, id: seam.FileId, file: Io.File, opts: struct { positional: bool, append: bool = false, borrowed: bool = false }) !*Handle {
        const h = try self.gpa.create(Handle);
        errdefer self.gpa.destroy(h);
        h.* = .{ .file = file, .positional = opts.positional, .append = opts.append, .borrowed = opts.borrowed };
        try self.handles.put(self.gpa, id, h);
        return h;
    }

    fn destroyHandle(self: *RealSystem, h: *Handle) void {
        if (!h.borrowed) h.file.close(self.io);
        if (h.remove_at_close) |path| {
            Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.gpa.free(path);
        }
        self.gpa.free(h.rbuf);
        self.gpa.free(h.wbuf);
        self.gpa.destroy(h);
    }

    /// Open `path` in `mode` as an OS file. `w` truncates and `a` creates;
    /// `reopening` (after a restore, Q7) does neither.
    fn openPath(self: *RealSystem, path: []const u8, mode: seam.OpenMode, reopening: bool) !Io.File {
        const cwd = Io.Dir.cwd();
        if (mode.kind == .read or reopening) {
            return cwd.openFile(self.io, path, .{ .mode = if (mode.update or (reopening and mode.kind != .read))
                (if (mode.readable()) .read_write else .write_only)
            else
                .read_only });
        }
        return cwd.createFile(self.io, path, .{ .read = mode.update, .truncate = mode.kind == .write });
    }

    /// Whether `file` is a regular file, which reads and writes positionally.
    fn isRegular(self: *RealSystem, file: Io.File) bool {
        const st = file.stat(self.io) catch return false;
        return st.kind == .file;
    }

    fn open(ctx: *anyopaque, id: seam.FileId, path: []const u8, mode: seam.OpenMode) ?seam.ErrorClass {
        const self = of(ctx);
        const file = self.openPath(path, mode, false) catch |e| return classOf(e);
        _ = self.addHandle(id, file, .{ .positional = self.isRegular(file), .append = mode.kind == .append }) catch {
            file.close(self.io);
            return .other;
        };
        return null;
    }

    fn tmpfile(ctx: *anyopaque, id: seam.FileId) ?seam.ErrorClass {
        const self = of(ctx);
        var rand: [8]u8 = undefined;
        mio.hostEntropy(&rand);
        const path = std.fmt.allocPrint(self.gpa, "{s}{c}mahina-{x}", .{ self.tempDir(), std.fs.path.sep, std.mem.readInt(u64, &rand, .little) }) catch return .other;
        var keep_path = false;
        defer if (!keep_path) self.gpa.free(path);
        const file = Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .exclusive = true }) catch |e| return classOf(e);
        // POSIX removes the name now and the file when it is closed; Windows
        // cannot remove an open file, so it waits for `close`.
        const unlinked = builtin.os.tag != .windows and if (Io.Dir.cwd().deleteFile(self.io, path)) true else |_| false;
        const h = self.addHandle(id, file, .{ .positional = true }) catch {
            file.close(self.io);
            if (!unlinked) Io.Dir.cwd().deleteFile(self.io, path) catch {};
            return .other;
        };
        if (!unlinked) {
            h.remove_at_close = path;
            keep_path = true;
        }
        return null;
    }

    /// Where temporary files go: `$TMPDIR` (`%TEMP%` on Windows), else the
    /// platform default.
    fn tempDir(self: *RealSystem) []const u8 {
        if (builtin.os.tag == .windows) {
            if (getenv(self, "TEMP")) |d| if (d.len > 0) return d;
            if (getenv(self, "TMP")) |d| if (d.len > 0) return d;
            return ".";
        }
        if (getenv(self, "TMPDIR")) |d| if (d.len > 0) return d;
        return "/tmp";
    }

    fn fill(ctx: *anyopaque, id: seam.FileId) seam.Result([]const u8) {
        const self = of(ctx);
        const h = self.handleOf(id) orelse return .{ .fail = .other };
        if (h.flushWrites(self.io)) |c| return .{ .fail = c };
        if (h.rstart < h.rend) return .{ .ok = h.rbuf[h.rstart..h.rend] };
        if (h.rbuf.len == 0) h.rbuf = self.gpa.alloc(u8, read_buffer_len) catch return .{ .fail = .other };
        const n = if (h.positional)
            h.file.readPositional(self.io, &.{h.rbuf}, h.pos) catch |e| return .{ .fail = classOf(e) }
        else
            h.file.readStreaming(self.io, &.{h.rbuf}) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => return .{ .fail = classOf(e) },
            };
        h.rstart = 0;
        h.rend = n;
        return .{ .ok = h.rbuf[0..n] };
    }

    fn consume(ctx: *anyopaque, id: seam.FileId, n: usize) void {
        const h = of(ctx).handleOf(id) orelse return;
        std.debug.assert(n <= h.rend - h.rstart);
        h.rstart += n;
        h.pos += n;
    }

    fn write(ctx: *anyopaque, id: seam.FileId, bytes: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        const h = self.handleOf(id) orelse return .other;
        // Writing drops what was read ahead; the position is already the
        // program's.
        h.rstart = 0;
        h.rend = 0;
        if (h.wlen + bytes.len > write_buffer_len) {
            if (h.flushWrites(self.io)) |c| return c;
        }
        h.pos += bytes.len;
        if (bytes.len >= write_buffer_len) {
            if (h.writeOut(self.io, bytes)) |c| return c;
        } else {
            if (h.wbuf.len == 0) h.wbuf = self.gpa.alloc(u8, write_buffer_len) catch return .other;
            @memcpy(h.wbuf[h.wlen..][0..bytes.len], bytes);
            h.wlen += bytes.len;
        }
        const now = switch (h.buffering) {
            .no => true,
            .line => std.mem.indexOfScalar(u8, bytes, '\n') != null,
            .full => false,
        };
        if (now) return h.flushWrites(self.io);
        return null;
    }

    fn seek(ctx: *anyopaque, id: seam.FileId, whence: seam.Whence, offset: i64) seam.Result(u64) {
        const self = of(ctx);
        const h = self.handleOf(id) orelse return .{ .fail = .other };
        if (!h.positional) return .{ .fail = .not_seekable };
        if (h.flushWrites(self.io)) |c| return .{ .fail = c };
        const base: u64 = switch (whence) {
            .set => 0,
            .cur => h.pos,
            .end => h.file.length(self.io) catch |e| return .{ .fail = classOf(e) },
        };
        const to = std.math.add(i128, base, offset) catch unreachable;
        if (to < 0 or to > std.math.maxInt(i64)) return .{ .fail = .other };
        h.pos = @intCast(to);
        h.rstart = 0;
        h.rend = 0;
        return .{ .ok = h.pos };
    }

    fn flush(ctx: *anyopaque, id: seam.FileId) ?seam.ErrorClass {
        const self = of(ctx);
        const h = self.handleOf(id) orelse return .other;
        return h.flushWrites(self.io);
    }

    fn setvbuf(ctx: *anyopaque, id: seam.FileId, mode: seam.BufferMode, size: usize) ?seam.ErrorClass {
        _ = size; // the buffer stays `write_buffer_len`
        const self = of(ctx);
        const h = self.handleOf(id) orelse return .other;
        if (h.flushWrites(self.io)) |c| return c;
        h.buffering = mode;
        return null;
    }

    fn close(ctx: *anyopaque, id: seam.FileId) ?seam.ErrorClass {
        const self = of(ctx);
        const kv = self.handles.fetchRemove(id) orelse return .other;
        const err = kv.value.flushWrites(self.io);
        self.destroyHandle(kv.value);
        return err;
    }

    /// The file's size, modification time and position, after writing out
    /// what is buffered (a keyframe captures the file as the program sees
    /// it). Null for what is not a regular file.
    fn fingerprint(ctx: *anyopaque, id: seam.FileId) ?seam.Fingerprint {
        const self = of(ctx);
        const h = self.handleOf(id) orelse return null;
        if (!h.positional or h.borrowed) return null;
        if (h.flushWrites(self.io) != null) return null;
        const st = h.file.stat(self.io) catch return null;
        return .{ .size = st.size, .mtime_ns = std.math.cast(i64, st.mtime.nanoseconds) orelse return null, .position = h.pos };
    }

    /// Reopen `path` after a restore (Q7) if its size and modification time
    /// still match `fp`, positioned where the program left it.
    fn reopen(ctx: *anyopaque, id: seam.FileId, path: []const u8, mode: seam.OpenMode, fp: seam.Fingerprint) ?seam.ErrorClass {
        const self = of(ctx);
        const file = self.openPath(path, mode, true) catch |e| return classOf(e);
        const st = file.stat(self.io) catch |e| {
            file.close(self.io);
            return classOf(e);
        };
        const mtime = std.math.cast(i64, st.mtime.nanoseconds);
        if (st.kind != .file or st.size != fp.size or mtime != fp.mtime_ns) {
            file.close(self.io);
            return .other;
        }
        const h = self.addHandle(id, file, .{ .positional = true, .append = mode.kind == .append }) catch {
            file.close(self.io);
            return .other;
        };
        h.pos = fp.position;
        return null;
    }

    fn getenv(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self = of(ctx);
        if (self.env_map) |m| return m.get(name);
        if (comptime builtin.link_libc and builtin.os.tag != .windows) {
            // libc wants a NUL-terminated name; an over-long or NUL-bearing
            // name can't name a variable.
            var buf: [256]u8 = undefined;
            if (name.len >= buf.len or std.mem.indexOfScalar(u8, name, 0) != null) return null;
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            const v = std.c.getenv(buf[0..name.len :0]) orelse return null;
            return std.mem.span(v);
        }
        return null;
    }
};
