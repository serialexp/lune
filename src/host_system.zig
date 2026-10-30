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
const datetime = @import("datetime.zig");
const tzif = @import("tzif.zig");
const proc_host = @import("proc_host.zig");

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
    /// The local time zone, loaded on the first `localZone` (doc 65 §8).
    zone: ?ZoneSource = null,
    /// What the last `proc` result points into (doc 75).
    proc_capture: proc_host.Capture = .{},

    /// For the CLI, with the process environment from `Init`.
    pub fn init(gpa: std.mem.Allocator, io: Io, env_map: ?*std.process.Environ.Map) RealSystem {
        return .{ .gpa = gpa, .io = io, .env_map = env_map };
    }

    pub fn deinit(self: *RealSystem) void {
        self.dropLast();
        self.proc_capture.deinit(self.gpa);
        if (self.zone) |*z| z.deinit(self.gpa);
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
        .environ = &environ,
        .proc = if (proc_host.supported) &procRun else null,
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
        .remove = &remove,
        .rename = &rename,
        .tmpname = &tmpname,
        .wallSeconds = &wallSeconds,
        .localZone = &localZone,
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
    pub fn classOf(err: anyerror) seam.ErrorClass {
        return switch (err) {
            error.FileNotFound, error.NotDir => .not_found,
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .permission_denied,
            error.PathAlreadyExists => .exists,
            error.IsDir => .is_a_directory,
            error.DirNotEmpty => .not_empty,
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

    // ---- paths (doc 65 §5.1) ----

    /// C's `remove`: a file, or an empty directory.
    fn remove(ctx: *anyopaque, path: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        Io.Dir.cwd().deleteFile(self.io, path) catch |e| switch (e) {
            error.IsDir => Io.Dir.cwd().deleteDir(self.io, path) catch |d| return classOf(d),
            else => return classOf(e),
        };
        return null;
    }

    fn rename(ctx: *anyopaque, from: []const u8, to: []const u8) ?seam.ErrorClass {
        const self = of(ctx);
        Io.Dir.rename(Io.Dir.cwd(), from, Io.Dir.cwd(), to, self.io) catch |e| return classOf(e);
        return null;
    }

    /// A fresh name in the temporary directory, created empty so no other
    /// process takes it (Lua's `mkstemp` template, `lua_XXXXXX`).
    fn tmpname(ctx: *anyopaque) seam.Result([]const u8) {
        const self = of(ctx);
        const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        var attempt: usize = 0;
        while (attempt < 100) : (attempt += 1) {
            var rand: [6]u8 = undefined;
            mio.hostEntropy(&rand);
            var suffix: [6]u8 = undefined;
            for (&suffix, rand) |*c, r| c.* = alphabet[r % alphabet.len];
            const dir = self.tempDir();
            const path = std.fmt.allocPrint(self.gpa, "{s}{c}lua_{s}", .{ dir, std.fs.path.sep, &suffix }) catch return .{ .fail = .other };
            const file = Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true }) catch |e| {
                self.gpa.free(path);
                if (e == error.PathAlreadyExists) continue;
                return .{ .fail = classOf(e) };
            };
            file.close(self.io);
            self.dropLast();
            self.last = path;
            return .{ .ok = path };
        }
        return .{ .fail = .exists };
    }

    // ---- time (doc 65 §8) ----

    fn wallSeconds(ctx: *anyopaque) i64 {
        const self = of(ctx);
        return @intCast(@divFloor(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
    }

    /// Where the local zone comes from: a TZif file, a POSIX `TZ` string, the
    /// Windows zone API, or nothing (UTC).
    const ZoneSource = union(enum) {
        tzif: tzif.TzInfo,
        /// The `TZ` value (owned) and its parse, which borrows it.
        posix: struct { text: []u8, tz: tzif.Posix },
        windows: WindowsZone,
        utc,

        fn deinit(z: *ZoneSource, gpa: std.mem.Allocator) void {
            switch (z.*) {
                .tzif => |*t| t.deinit(gpa),
                .posix => |p| gpa.free(p.text),
                .windows => |*w| w.deinit(gpa),
                .utc => {},
            }
        }
    };

    const utc_zone: seam.LocalZone = .{ .offset = 0, .dst = false, .abbr = "UTC" };

    fn localZone(ctx: *anyopaque, utc: i64) seam.LocalZone {
        const self = of(ctx);
        if (self.zone == null) self.zone = self.loadZone();
        return switch (self.zone.?) {
            .tzif => |*t| t.lookup(utc),
            .posix => |p| p.tz.lookup(utc),
            .windows => |*w| w.lookup(self.gpa, utc),
            .utc => utc_zone,
        };
    }

    /// The zone as C's `tzset` finds it: `$TZ` names a zoneinfo file (under
    /// `$TZDIR`, or absolute) or is a POSIX rule; unset, `/etc/localtime`;
    /// empty or unusable, UTC. Windows asks the system.
    fn loadZone(self: *RealSystem) ZoneSource {
        if (builtin.os.tag == .windows) return .{ .windows = .{} };
        const tz_env = getenv(self, "TZ") orelse return self.loadTzif("/etc/localtime") orelse .utc;
        var name = tz_env;
        if (name.len > 0 and name[0] == ':') name = name[1..];
        if (name.len == 0) return .utc;
        // `getenv`'s result is borrowed: copy what outlives the next call.
        const owned = self.gpa.dupe(u8, name) catch return .utc;
        defer self.gpa.free(owned);
        if (owned[0] == '/') return self.loadTzif(owned) orelse .utc;
        const dir = if (getenv(self, "TZDIR")) |d| (if (d.len > 0) d else "/usr/share/zoneinfo") else "/usr/share/zoneinfo";
        const path = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, owned }) catch return .utc;
        defer self.gpa.free(path);
        if (self.loadTzif(path)) |z| return z;
        const text = self.gpa.dupe(u8, owned) catch return .utc;
        const tz = tzif.Posix.parse(text) orelse {
            self.gpa.free(text);
            return .utc;
        };
        return .{ .posix = .{ .text = text, .tz = tz } };
    }

    fn loadTzif(self: *RealSystem, path: []const u8) ?ZoneSource {
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, Io.Limit.limited(1 << 20)) catch return null;
        defer self.gpa.free(bytes);
        return .{ .tzif = tzif.TzInfo.parse(self.gpa, bytes) catch return null };
    }

    /// The Windows zone API: the system's current zone, its rules applied to
    /// any instant by `SystemTimeToTzSpecificLocalTime`, its names (UTF-16)
    /// as the abbreviations, as the C runtime's `%Z` gives them.
    const WindowsZone = struct {
        /// The UTF-8 name last returned (borrowed by the caller).
        name: ?[]u8 = null,

        fn deinit(w: *WindowsZone, gpa: std.mem.Allocator) void {
            if (w.name) |n| gpa.free(n);
        }

        fn lookup(w: *WindowsZone, gpa: std.mem.Allocator, utc: i64) seam.LocalZone {
            if (builtin.os.tag != .windows) unreachable;
            var tzi: win.TIME_ZONE_INFORMATION = undefined;
            if (win.GetTimeZoneInformation(&tzi) == win.TIME_ZONE_ID_INVALID) return utc_zone;
            const standard = -(tzi.Bias + tzi.StandardBias) * 60;
            const tm = datetime.breakDown(utc);
            // SYSTEMTIME covers 1601..30827; outside it, standard time.
            var offset = standard;
            if (tm.year >= 1601 and tm.year <= 30827) {
                const st: win.SYSTEMTIME = .{ .wYear = @intCast(tm.year), .wMonth = tm.month, .wDayOfWeek = tm.wday, .wDay = tm.day, .wHour = tm.hour, .wMinute = tm.min, .wSecond = tm.sec, .wMilliseconds = 0 };
                var local: win.SYSTEMTIME = undefined;
                if (win.SystemTimeToTzSpecificLocalTime(null, &st, &local) != 0) {
                    const l = datetime.secondsOf(.{ .year = local.wYear, .month = local.wMonth, .day = local.wDay, .hour = local.wHour, .min = local.wMinute, .sec = local.wSecond });
                    offset = @intCast(l - utc);
                }
            }
            const dst = offset != standard;
            const wide = if (dst) &tzi.DaylightName else &tzi.StandardName;
            if (w.name) |n| gpa.free(n);
            w.name = std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.sliceTo(wide, 0)) catch null;
            const name = w.name orelse "";
            return .{ .offset = offset, .dst = dst, .abbr = name[0..@min(name.len, seam.max_abbr_len)] };
        }
    };

    const win = struct {
        const SYSTEMTIME = extern struct {
            wYear: u16,
            wMonth: u16,
            wDayOfWeek: u16,
            wDay: u16,
            wHour: u16,
            wMinute: u16,
            wSecond: u16,
            wMilliseconds: u16,
        };
        const TIME_ZONE_INFORMATION = extern struct {
            Bias: i32,
            StandardName: [32]u16,
            StandardDate: SYSTEMTIME,
            StandardBias: i32,
            DaylightName: [32]u16,
            DaylightDate: SYSTEMTIME,
            DaylightBias: i32,
        };
        const TIME_ZONE_ID_INVALID: u32 = 0xFFFF_FFFF;
        extern "kernel32" fn GetTimeZoneInformation(tzi: *TIME_ZONE_INFORMATION) callconv(.winapi) u32;
        extern "kernel32" fn SystemTimeToTzSpecificLocalTime(tzi: ?*const TIME_ZONE_INFORMATION, utc: *const SYSTEMTIME, local: *SYSTEMTIME) callconv(.winapi) i32;
    };

    /// Every variable of the process environment (doc 75 §3.1): the CLI's
    /// map, or, embedded with libc on POSIX, `environ`. Windows without a map
    /// has none yet (Phase 6).
    fn environ(ctx: *anyopaque, visit: seam.EnvVisitFn, visit_ctx: *anyopaque) void {
        const self = of(ctx);
        if (self.env_map) |m| {
            var it = m.iterator();
            while (it.next()) |e| visit(visit_ctx, e.key_ptr.*, e.value_ptr.*);
            return;
        }
        if (comptime builtin.link_libc and builtin.os.tag != .windows) {
            var p: [*:null]?[*:0]u8 = std.c.environ;
            while (p[0]) |entry| : (p += 1) {
                const kv = std.mem.span(entry);
                // A leading `=` has no name; skip it (a pair needs `NAME=`).
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                visit(visit_ctx, kv[0..eq], kv[eq + 1 ..]);
            }
        }
    }

    /// `proc.run` (doc 75): the program runs against the CLI's environment map
    /// when it has one, else the process environment.
    fn procRun(ctx: *anyopaque, req: seam.ProcRequest) seam.ProcResult {
        const self = of(ctx);
        // Starting a child allocates through the Io's own allocator, which the
        // shared `io` (the C API passes the failing global one) may not have:
        // so the call runs on a private, threadless Io over this host's gpa.
        var threaded: std.Io.Threaded = .init(self.gpa, .{ .async_limit = .nothing });
        defer threaded.deinit();
        return proc_host.run(self.gpa, threaded.io(), self.env_map, req, &self.proc_capture);
    }

    fn getenv(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self = of(ctx);
        if (self.env_map) |m| return m.get(name);
        if (builtin.os.tag == .windows) {
            // libmahina on Windows: the process environment block, which has
            // no libc `getenv` behind it.
            const key = std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, name) catch return null;
            defer self.gpa.free(key);
            const env: std.process.Environ = .{ .block = .global };
            const wide = env.getWindows(key) orelse return null;
            const val = std.unicode.wtf16LeToWtf8Alloc(self.gpa, wide) catch return null;
            self.dropLast();
            self.last = val;
            return val;
        }
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

// ---------------------------------------------------------------------------
// Tests: the real OS, in a scratch directory under `.zig-cache/tmp`.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A path inside the test's scratch directory, relative to the cwd (the
/// host's path operations take paths as a program would give them).
fn scratchPath(buf: []u8, tmp: *const testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache{c}tmp{c}{s}{c}{s}", .{ std.fs.path.sep, std.fs.path.sep, &tmp.sub_path, std.fs.path.sep, name }) catch unreachable;
}

test "remove, rename and tmpname on the real file system" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const ctx: *anyopaque = &sys;
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    var d_buf: [256]u8 = undefined;
    const a = scratchPath(&a_buf, &tmp, "a.txt");
    const b = scratchPath(&b_buf, &tmp, "b.txt");
    const d = scratchPath(&d_buf, &tmp, "d");
    try tmp.dir.writeFile(mio.hostIo(), .{ .sub_path = "a.txt", .data = "A" });
    try testing.expectEqual(@as(?seam.ErrorClass, null), RealSystem.rename(ctx, a, b));
    try testing.expectEqual(@as(?seam.ErrorClass, .not_found), RealSystem.rename(ctx, a, b));
    try testing.expectEqual(@as(?seam.ErrorClass, null), RealSystem.remove(ctx, b));
    try testing.expectEqual(@as(?seam.ErrorClass, .not_found), RealSystem.remove(ctx, b));
    // A directory goes when it is empty, as C's `remove` does.
    try tmp.dir.createDir(mio.hostIo(), "d", .default_dir);
    try tmp.dir.writeFile(mio.hostIo(), .{ .sub_path = "d" ++ std.fs.path.sep_str ++ "x", .data = "" });
    try testing.expectEqual(@as(?seam.ErrorClass, .not_empty), RealSystem.remove(ctx, d));
    try tmp.dir.deleteFile(mio.hostIo(), "d" ++ std.fs.path.sep_str ++ "x");
    try testing.expectEqual(@as(?seam.ErrorClass, null), RealSystem.remove(ctx, d));
    // A temporary name is a new, empty file.
    const name = switch (RealSystem.tmpname(ctx)) {
        .ok => |n| try testing.allocator.dupe(u8, n),
        .fail => |c| return std.debug.panic("tmpname failed: {s}", .{c.text()}),
    };
    defer testing.allocator.free(name);
    try testing.expect(std.mem.indexOf(u8, name, "lua_") != null);
    try testing.expectEqual(@as(?seam.ErrorClass, null), RealSystem.remove(ctx, name));
}

/// The zone a fresh system finds under `TZ=tz` (null: unset).
fn zoneUnder(env: *std.process.Environ.Map, utc: i64, abbr_buf: []u8) !seam.LocalZone {
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), env);
    defer sys.deinit();
    var z = RealSystem.localZone(&sys, utc);
    @memcpy(abbr_buf[0..z.abbr.len], z.abbr);
    z.abbr = abbr_buf[0..z.abbr.len];
    return z;
}

test "the local zone follows TZ: a POSIX rule, a zoneinfo name, empty for UTC" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the system zone
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var buf: [64]u8 = undefined;
    const summer: i64 = 1_690_000_000; // 2023-07-22
    const winter: i64 = 1_700_000_000; // 2023-11-14

    try env.put("TZ", "CET-1CEST,M3.5.0,M10.5.0/3");
    var z = try zoneUnder(&env, summer, &buf);
    try testing.expectEqual(@as(i32, 7200), z.offset);
    try testing.expect(z.dst);
    try testing.expectEqualStrings("CEST", z.abbr);
    z = try zoneUnder(&env, winter, &buf);
    try testing.expectEqual(@as(i32, 3600), z.offset);
    try testing.expectEqualStrings("CET", z.abbr);

    // A name that is no file under `TZDIR` falls back to a POSIX parse.
    try env.put("TZDIR", ".zig-cache/no-such-zoneinfo");
    try env.put("TZ", "<+0530>-5:30");
    z = try zoneUnder(&env, summer, &buf);
    try testing.expectEqual(@as(i32, 19800), z.offset);
    try testing.expectEqualStrings("+0530", z.abbr);

    try env.put("TZ", "");
    z = try zoneUnder(&env, summer, &buf);
    try testing.expectEqual(@as(i32, 0), z.offset);
    try testing.expectEqualStrings("UTC", z.abbr);

    // A zoneinfo name, where the system has the database.
    try env.put("TZDIR", "/usr/share/zoneinfo");
    Io.Dir.cwd().access(mio.hostIo(), "/usr/share/zoneinfo/Europe/Amsterdam", .{}) catch return;
    try env.put("TZ", ":Europe/Amsterdam");
    z = try zoneUnder(&env, summer, &buf);
    try testing.expectEqual(@as(i32, 7200), z.offset);
    try testing.expectEqualStrings("CEST", z.abbr);
    z = try zoneUnder(&env, -1_520_000_000, &buf); // 1921-11-01: Amsterdam mean time
    try testing.expectEqual(@as(i32, 1172), z.offset);
    try testing.expectEqualStrings("AMT", z.abbr);
}

test "on Windows the zone is the system's, named as the C runtime names it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    for ([_]i64{ 1_690_000_000, 1_700_000_000 }) |t| {
        const z = RealSystem.localZone(&sys, t);
        try testing.expect(@abs(z.offset) <= 14 * 3600);
        try testing.expect(z.abbr.len > 0);
        try testing.expect(std.unicode.utf8ValidateSlice(z.abbr));
    }
}

test "without an environment map, getenv reads the process environment" {
    if (builtin.os.tag != .windows and !builtin.link_libc) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    try testing.expect(RealSystem.getenv(&sys, "PATH") != null);
    try testing.expect(RealSystem.getenv(&sys, "MAHINA_SURELY_UNSET_VARIABLE") == null);
}

test "the wall clock is past 2020" {
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    try testing.expect(RealSystem.wallSeconds(&sys) > 1_577_836_800);
}

test "environ lists the environment map" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("ALPHA", "1");
    try env.put("BETA", "");
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), &env);
    defer sys.deinit();
    const Seen = struct {
        n: usize = 0,
        saw_alpha: bool = false,
        saw_beta: bool = false,
        fn visit(ctx: *anyopaque, name: []const u8, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
            if (std.mem.eql(u8, name, "ALPHA") and std.mem.eql(u8, value, "1")) self.saw_alpha = true;
            if (std.mem.eql(u8, name, "BETA") and value.len == 0) self.saw_beta = true;
        }
    };
    var seen: Seen = .{};
    RealSystem.environ(&sys, &Seen.visit, &seen);
    try testing.expectEqual(@as(usize, 2), seen.n);
    try testing.expect(seen.saw_alpha and seen.saw_beta);
}

test "proc runs a real program: exit code, both streams, stdin, env and cwd" {
    if (!proc_host.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const env = [_]seam.ProcEnvPair{.{ .name = "GREETING", .value = "hi" }};
    const r = RealSystem.procRun(&sys, .{
        .stages = &.{&.{ "/bin/sh", "-c", "read x; echo \"$x $GREETING $(pwd)\"; echo oops >&2; exit 3" }},
        .cwd = "/",
        .env = &env,
        .stdin = .{ .bytes = "line\n" },
        .max_bytes = 1024,
    });
    try testing.expectEqual(@as(u32, 3), r.done.stages[0].status.exited);
    try testing.expectEqualStrings("line hi /\n", r.done.stdout);
    try testing.expectEqualStrings("oops\n", r.done.stages[0].stderr);
    try testing.expect(!r.done.truncated);
}

test "proc keeps the latest bytes, merges stderr, and names a signal" {
    if (!proc_host.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const t = RealSystem.procRun(&sys, .{
        .stages = &.{&.{ "/bin/sh", "-c", "printf 0123456789; printf abc >&2" }},
        .stderr = .merge,
        .max_bytes = 4,
    });
    try testing.expectEqualStrings("9abc", t.done.stdout);
    try testing.expect(t.done.truncated);
    const s = RealSystem.procRun(&sys, .{ .stages = &.{&.{ "/bin/sh", "-c", "kill -SEGV $$" }}, .max_bytes = 16 });
    try testing.expectEqualStrings("SIGSEGV", s.done.stages[0].status.signaled);
}

test "proc times out a program and everything it started, and reports a missing one" {
    if (!proc_host.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    const env = [_]seam.ProcEnvPair{.{ .name = "X", .value = "1" }};
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const t = RealSystem.procRun(&sys, .{
        .stages = &.{&.{ "/bin/sh", "-c", "sleep 30 & wait" }},
        .env = &env,
        .stdin = .{ .bytes = "" },
        .max_bytes = 16,
        .timeout_ns = 100_000_000,
    });
    try testing.expect(t.done.timed_out);
    const m = RealSystem.procRun(&sys, .{ .stages = &.{&.{"/no/such/program"}}, .max_bytes = 16 });
    try testing.expectEqual(seam.ErrorClass.not_found, m.fail.class);
    try testing.expectEqual(@as(u32, 0), m.fail.stage);
}

test "proc pipes each stage's stdout into the next, with every stage's stderr kept apart" {
    if (!proc_host.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const r = RealSystem.procRun(&sys, .{
        .stages = &.{
            &.{ "/bin/sh", "-c", "echo one >&2; printf 'b\\na\\nc\\n'" },
            &.{ "/bin/sh", "-c", "echo two >&2; sort" },
            &.{ "/bin/sh", "-c", "echo three >&2; tr a-z A-Z; exit 4" },
        },
        .max_bytes = 1024,
    });
    try testing.expectEqualStrings("A\nB\nC\n", r.done.stdout);
    try testing.expectEqual(@as(usize, 3), r.done.stages.len);
    try testing.expectEqualStrings("one\n", r.done.stages[0].stderr);
    try testing.expectEqualStrings("two\n", r.done.stages[1].stderr);
    try testing.expectEqualStrings("three\n", r.done.stages[2].stderr);
    try testing.expectEqual(@as(u32, 0), r.done.stages[1].status.exited);
    try testing.expectEqual(@as(u32, 4), r.done.stages[2].status.exited);
}

test "proc pipeline: stdin feeds the first stage, merge follows the pipe, an early reader ends the writer" {
    if (!proc_host.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const m = RealSystem.procRun(&sys, .{
        .stages = &.{
            &.{ "/bin/sh", "-c", "cat; echo warn >&2" },
            &.{ "/bin/sh", "-c", "cat" },
        },
        .stdin = .{ .bytes = "in\n" },
        .stderr = .merge,
        .max_bytes = 1024,
    });
    try testing.expectEqualStrings("in\nwarn\n", m.done.stdout);
    // `yes` writes until its reader goes; `head` reads one line and goes.
    const y = RealSystem.procRun(&sys, .{
        .stages = &.{ &.{ "/bin/sh", "-c", "yes" }, &.{ "/bin/sh", "-c", "head -n 1" } },
        .max_bytes = 1024,
    });
    try testing.expectEqualStrings("y\n", y.done.stdout);
    try testing.expect(!y.done.timed_out);
}

test "proc pipeline: a stage that cannot start ends the ones before it, and a timeout ends them all" {
    if (!proc_host.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    var sys = RealSystem.init(testing.allocator, mio.hostIo(), null);
    defer sys.deinit();
    const f = RealSystem.procRun(&sys, .{
        .stages = &.{ &.{ "/bin/sh", "-c", "sleep 30" }, &.{"/no/such/program"} },
        .max_bytes = 16,
    });
    try testing.expectEqual(@as(u32, 1), f.fail.stage);
    try testing.expectEqual(seam.ErrorClass.not_found, f.fail.class);
    const t = RealSystem.procRun(&sys, .{
        .stages = &.{ &.{ "/bin/sh", "-c", "sleep 30" }, &.{ "/bin/sh", "-c", "cat" } },
        .max_bytes = 16,
        .timeout_ns = 100_000_000,
    });
    try testing.expect(t.done.timed_out);
}
