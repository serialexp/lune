//! The host system seam (doc 65 §5): the one interface through which a VM
//! reaches files, the standard streams, the environment and the wall clock.
//! The VM core holds no platform access of its own — it compiles to
//! `wasm32-freestanding` — so the host that builds a VM supplies a
//! `HostSystem` (the CLI and libmahina: `host_system.zig`, the real OS; the
//! wasm playground: an in-memory file set; tests: fakes) and says which
//! interface groups to install (`Groups`). A group that is off installs none
//! of its functions (Q5): `io.open` is `nil`, as in a Lua state that never
//! opened the library.
//!
//! Every call here is made only in `off`/`record` mode; `replay` feeds the
//! logged results back and never reaches the host (doc 65 §2). Results that
//! borrow host memory (`readFile`, `fill`, `getenv`, `tmpname`) are valid only
//! until the next call on the same system; the VM copies them at once.
//!
//! Dependency-free on purpose (no `std.Io`): `function.zig` names `Group` in the
//! native registry, and the VM core imports this file on every target.

const std = @import("std");
const datetime = @import("datetime.zig");

/// One interface group (doc 65 §5.2). A native tagged with a group is
/// installed only when the host enables that group.
pub const Group = enum(u3) {
    /// `io.open`/`io.lines`/`io.input`/`io.output`/`io.close`/`io.tmpfile`,
    /// `os.remove`/`os.rename`/`os.tmpname`.
    files,
    /// `io.stdin` and `io.read` (the default input). stdout/stderr are always
    /// present: they write to the VM's output seam (`Vm.out`/`Vm.err`).
    stdio,
    /// `os.getenv`, `os.exit`.
    env,
    /// `os.time`, `os.date` (they read the wall clock and the local zone).
    time,
    /// `os.clock`, `os.nsclock` (the monotonic clock, `Vm.clock`).
    clock,
    /// A host entropy seed for `math.random` (`Vm.random_seed_source`). Off,
    /// `math.random` starts from a fixed seed, so a VM is deterministic.
    random,
};

/// The set of enabled groups. The bit order is the C API's `MH_SYSTEM_*`
/// mask (`include/mahina.h`), so the mask converts with one `@bitCast`.
pub const Groups = packed struct(u8) {
    files: bool = false,
    stdio: bool = false,
    env: bool = false,
    time: bool = false,
    clock: bool = false,
    random: bool = false,
    _pad: u2 = 0,

    pub const none: Groups = .{};
    pub const all: Groups = .{ .files = true, .stdio = true, .env = true, .time = true, .clock = true, .random = true };

    pub fn has(self: Groups, g: Group) bool {
        return switch (g) {
            .files => self.files,
            .stdio => self.stdio,
            .env => self.env,
            .time => self.time,
            .clock => self.clock,
            .random => self.random,
        };
    }

    /// Whether the two sets share a group.
    pub fn overlaps(self: Groups, other: Groups) bool {
        return @as(u8, @bitCast(self)) & @as(u8, @bitCast(other)) != 0;
    }

    pub fn unite(self: Groups, other: Groups) Groups {
        return @bitCast(@as(u8, @bitCast(self)) | @as(u8, @bitCast(other)));
    }

    /// From the C mask; bits above `MH_SYSTEM_ALL` are ignored.
    pub fn fromMask(mask: u32) Groups {
        var g: Groups = @bitCast(@as(u8, @truncate(mask)));
        g._pad = 0;
        return g;
    }

    /// The CLI's `--system` value: `all`, `none`, or a comma-separated list
    /// of group names (`clock,random`). Null on an unknown name or an empty
    /// list entry.
    pub fn parse(list: []const u8) ?Groups {
        if (std.mem.eql(u8, list, "all")) return .all;
        if (std.mem.eql(u8, list, "none")) return .none;
        var g: Groups = .none;
        var names = std.mem.splitScalar(u8, list, ',');
        while (names.next()) |name| {
            const group = std.meta.stringToEnum(Group, name) orelse return null;
            switch (group) {
                .files => g.files = true,
                .stdio => g.stdio = true,
                .env => g.env = true,
                .time => g.time = true,
                .clock => g.clock = true,
                .random => g.random = true,
            }
        }
        return g;
    }
};

test "Groups.parse" {
    try std.testing.expectEqual(Groups.all, Groups.parse("all").?);
    try std.testing.expectEqual(Groups.none, Groups.parse("none").?);
    const g = Groups.parse("clock,random").?;
    try std.testing.expect(g.clock and g.random and !g.files and !g.env);
    try std.testing.expect(Groups.parse("clock,") == null);
    try std.testing.expect(Groups.parse("disk") == null);
    try std.testing.expect(Groups.parse("") == null);
}

/// What a failed `io`/`os` call does (doc 65 §4.4). The ordinal is the
/// `io_error_mode` effect's logged value, so it is part of the wire format.
pub const IoErrors = enum(u8) {
    /// Raise a catchable error (the default).
    raise = 0,
    /// Return Lua's `nil, msg, code` (`--lua-io-errors`).
    lua = 1,
};

/// Why a host operation failed (doc 65 §4.2). The message a script sees is
/// mahina's own text for the class plus the path or handle, never the OS's
/// `strerror`, so a recording replays with the same text on any machine. The
/// ordinal is the `code` a Lua-compatibility-mode return carries (§4.4) and
/// the byte the effect log stores, so it is part of the wire format: append
/// only.
pub const ErrorClass = enum(u8) {
    not_found = 1,
    permission_denied = 2,
    exists = 3,
    is_a_directory = 4,
    /// A text-mode read that is not valid UTF-8 (raised by the VM, not the host).
    not_utf8 = 5,
    other = 6,
    /// A read from a handle opened only for writing. Decided by the VM from
    /// the handle's mode, so never logged; the ordinal is still the `code`.
    not_readable = 7,
    /// A write to a handle opened only for reading (VM-decided, like
    /// `not_readable`).
    not_writable = 8,
    /// A seek on a stream that has no position: a pipe or terminal (from the
    /// host), or the VM's stdout/stderr seam (VM-decided).
    not_seekable = 9,
    /// Removing a directory that still has entries.
    not_empty = 10,

    pub fn text(self: ErrorClass) []const u8 {
        return switch (self) {
            .not_found => "not found",
            .permission_denied => "permission denied",
            .exists => "already exists",
            .is_a_directory => "is a directory",
            .not_utf8 => "not valid UTF-8",
            .other => "input/output error",
            .not_readable => "not open for reading",
            .not_writable => "not open for writing",
            .not_seekable => "not seekable",
            .not_empty => "directory not empty",
        };
    }
};

/// A file id the VM assigned (a deterministic counter, doc 65 §4.1). Ids 0, 1
/// and 2 are stdin, stdout and stderr.
pub const FileId = u32;
pub const stdin_id: FileId = 0;
pub const stdout_id: FileId = 1;
pub const stderr_id: FileId = 2;

/// An `io.open` mode, parsed by the VM (`r`, `w`, `a`, each optionally with
/// `+`, then optionally `b`).
pub const OpenMode = struct {
    kind: enum(u2) { read, write, append },
    update: bool = false,
    binary: bool = false,

    pub fn readable(self: OpenMode) bool {
        return self.kind == .read or self.update;
    }
    pub fn writable(self: OpenMode) bool {
        return self.kind != .read or self.update;
    }
};

pub const Whence = enum(u2) { set, cur, end };
pub const BufferMode = enum(u2) { no, full, line };

/// A file as it was when a keyframe captured it (doc 65 Q7): reopening after a
/// restore checks the file still matches before seeking to `position`.
pub const Fingerprint = struct {
    size: u64,
    mtime_ns: i64,
    position: u64,
};

/// A host result: a value, or the class of the failure.
pub fn Result(comptime T: type) type {
    return union(enum) { ok: T, fail: ErrorClass };
}

/// The host side of the seam. Every function is optional: a host fills in the
/// groups it enables (the real OS fills all of them; the wasm playground only
/// `readFile`). The VM checks for a missing function where it would call it
/// and reports `other`, so a partial host can never crash the VM.
pub const HostSystem = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // ---- whole-file read: `loadfile`/`dofile`/`require` (any group) ----
        /// The whole file, or null if it can't be read (any reason).
        readFile: ?*const fn (ctx: *anyopaque, path: []const u8) ?[]const u8 = null,

        // ---- files and stdin (doc 65 §5.1) ----
        /// Open `path` as file `id`.
        open: ?*const fn (ctx: *anyopaque, id: FileId, path: []const u8, mode: OpenMode) ?ErrorClass = null,
        /// Open an anonymous read-write temporary file as file `id`, removed
        /// when it is closed (or at exit).
        tmpfile: ?*const fn (ctx: *anyopaque, id: FileId) ?ErrorClass = null,
        /// The bytes buffered at the read position, refilling when empty. An
        /// empty slice is end of file. Reading does not advance until `consume`.
        fill: ?*const fn (ctx: *anyopaque, id: FileId) Result([]const u8) = null,
        /// Advance the read position by `n` bytes of the last `fill`.
        consume: ?*const fn (ctx: *anyopaque, id: FileId, n: usize) void = null,
        write: ?*const fn (ctx: *anyopaque, id: FileId, bytes: []const u8) ?ErrorClass = null,
        /// Move the position; returns the new absolute byte offset.
        seek: ?*const fn (ctx: *anyopaque, id: FileId, whence: Whence, offset: i64) Result(u64) = null,
        flush: ?*const fn (ctx: *anyopaque, id: FileId) ?ErrorClass = null,
        setvbuf: ?*const fn (ctx: *anyopaque, id: FileId, mode: BufferMode, size: usize) ?ErrorClass = null,
        close: ?*const fn (ctx: *anyopaque, id: FileId) ?ErrorClass = null,
        /// The file's identity and position, for a keyframe (null: not a
        /// regular file, or unknown).
        fingerprint: ?*const fn (ctx: *anyopaque, id: FileId) ?Fingerprint = null,
        /// Reopen `path` as `id` after a restore, if it still matches `fp`.
        reopen: ?*const fn (ctx: *anyopaque, id: FileId, path: []const u8, mode: OpenMode, fp: Fingerprint) ?ErrorClass = null,
        remove: ?*const fn (ctx: *anyopaque, path: []const u8) ?ErrorClass = null,
        rename: ?*const fn (ctx: *anyopaque, from: []const u8, to: []const u8) ?ErrorClass = null,
        /// A fresh temporary file name.
        tmpname: ?*const fn (ctx: *anyopaque) Result([]const u8) = null,

        // ---- environment ----
        /// An environment variable, or null if unset (`""` if set but empty).
        getenv: ?*const fn (ctx: *anyopaque, name: []const u8) ?[]const u8 = null,

        // ---- time ----
        /// Wall-clock seconds since the Unix epoch.
        wallSeconds: ?*const fn (ctx: *anyopaque) i64 = null,
        /// The local zone at `utc` (seconds since the epoch): it varies with
        /// daylight saving. A host without this function is in UTC.
        localZone: ?*const fn (ctx: *anyopaque, utc: i64) LocalZone = null,
    };
};

/// The local zone at one instant (doc 65 §8): what `os.date` needs beyond
/// the instant itself. The abbreviation borrows host memory like the other
/// borrowed results (valid until the next call), and is at most
/// `max_abbr_len` bytes of UTF-8; a host truncates a longer one.
pub const LocalZone = datetime.Zone;

/// The `local_zone` effect's byte record: the offset (`i32`, little-endian),
/// daylight saving (one byte), then the abbreviation.
pub const local_zone_fixed_len = 5;
pub const max_abbr_len = 64;
pub const max_local_zone_len = local_zone_fixed_len + max_abbr_len;

/// Encode `zone` into `buf` as the `local_zone` record (the abbreviation cut
/// to `max_abbr_len`).
pub fn encodeLocalZone(zone: LocalZone, buf: *[max_local_zone_len]u8) []const u8 {
    std.mem.writeInt(i32, buf[0..4], zone.offset, .little);
    buf[4] = @intFromBool(zone.dst);
    const n = @min(zone.abbr.len, max_abbr_len);
    @memcpy(buf[local_zone_fixed_len..][0..n], zone.abbr[0..n]);
    return buf[0 .. local_zone_fixed_len + n];
}

/// Decode a `local_zone` record; the abbreviation borrows `rec`. The effect
/// decoder has checked it is at least `local_zone_fixed_len` bytes.
pub fn decodeLocalZone(rec: []const u8) LocalZone {
    return .{ .offset = std.mem.readInt(i32, rec[0..4], .little), .dst = rec[4] != 0, .abbr = rec[local_zone_fixed_len..] };
}
