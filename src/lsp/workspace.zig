//! The workspace folders and their `mahina.toml` (doc 74 §7.4). One server
//! serves every folder of a multi-root workspace, and each folder's config
//! governs the files under it; when folders nest, the innermost wins. A file in
//! no folder gets the defaults, with `require` searching from its own
//! directory, the likeliest place the CLI is run from.
//!
//! The core reads no disk itself: the host supplies `Files`, and a host with
//! no filesystem (the browser) supplies none, so only built-in modules and
//! open documents resolve there.

const std = @import("std");
const system = @import("../system.zig");
const config = @import("config.zig");
const modules = @import("modules.zig");
const stdlib_db = @import("stdlib_db.zig");

const Allocator = std.mem.Allocator;

/// The config file in a folder's root.
pub const config_name = "mahina.toml";

/// The host's view of the disk.
pub const Files = struct {
    ctx: ?*anyopaque = null,
    /// The bytes of `path`, allocated in `a`, or null when it cannot be read.
    read: *const fn (ctx: ?*anyopaque, a: Allocator, path: []const u8) ?[]u8,
    /// Whether `path` is a file that exists.
    exists: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
    /// The files and directories in the directory `path`, names allocated in
    /// `a`; symbolic links and anything else are left out, so a walk cannot
    /// loop. Null when it cannot be read. A host without it has no
    /// workspace symbols beyond the open documents.
    list: ?*const fn (ctx: ?*anyopaque, a: Allocator, path: []const u8) ?[]const DirEntry = null,
    /// What tells a file's new contents from its old without reading it, or
    /// null when `path` is gone.
    stamp: ?*const fn (ctx: ?*anyopaque, path: []const u8) ?Stamp = null,
    /// The same for the directory `path`, moving when an entry in it is
    /// created, deleted or renamed (its modification time); null when it is
    /// not a directory. A walk needs all three of `list`, `stamp` and this.
    dir_stamp: ?*const fn (ctx: ?*anyopaque, path: []const u8) ?Stamp = null,

    pub const DirEntry = struct { name: []const u8, kind: enum { file, directory } };
    pub const Stamp = struct { size: u64, mtime_ns: i96 };
};

/// Where the host keeps what the server saves between sessions (the
/// workspace symbol index), by file name. A host without one (the browser,
/// or no cache directory) builds the index anew each session.
pub const Store = struct {
    ctx: ?*anyopaque = null,
    /// The bytes saved under `name`, allocated in `a`, or null.
    load: *const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]u8,
    /// Replace what is saved under `name`, as a whole: a reader never sees
    /// half of it. A failure is not reported; the next session rebuilds.
    save: *const fn (ctx: ?*anyopaque, name: []const u8, bytes: []const u8) void,
};

pub const Folder = struct {
    /// Owns every slice below.
    arena: std.heap.ArenaAllocator,
    uri: []const u8,
    /// `/`-separated, without a trailing separator.
    path: []const u8,
    config: config.Config,
    /// Why the folder's `mahina.toml` was rejected. The defaults apply
    /// meanwhile, and the server publishes this on the file.
    failure: ?config.Failure = null,
    /// The text of the folder's `mahina.toml`, when it has one: a failure's
    /// line and column are ranged against it.
    config_text: ?[]const u8 = null,
    /// The directory `require` searches from: the config's `cwd`, resolved
    /// against the folder.
    runtime_cwd: []const u8,
    /// The host's globals and the config's `[globals]`.
    known_globals: []const []const u8,

    pub fn configPath(self: *const Folder, a: Allocator) Allocator.Error![]const u8 {
        return std.fs.path.resolveAllocPosix(a, &.{ self.path, config_name });
    }
};

/// What governs one document.
pub const Settings = struct {
    /// Null when the document names no file: then only built-in modules resolve.
    cwd: ?[]const u8,
    package_path: []const []const u8,
    known_globals: []const []const u8,
    suppress: []const []const u8,
    /// The system groups the host enables.
    system: system.Groups,
};

pub const Workspace = struct {
    gpa: Allocator,
    folders: std.ArrayList(*Folder) = .empty,
    /// Owns `overrides` and `loose`: decode the editor's options into it,
    /// then `setOverrides`.
    options_arena: std.heap.ArenaAllocator,
    /// The editor's `initializationOptions`, over every folder's config.
    overrides: config.Overrides = .{},
    /// What governs a file in no folder: the defaults with the overrides
    /// applied, and the host globals that leaves known (null: the host's own).
    loose: config.Config = .{},
    loose_known: ?[]const []const u8 = null,

    pub fn init(gpa: Allocator) Workspace {
        return .{ .gpa = gpa, .options_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.folders.items) |f| self.destroy(f);
        self.folders.deinit(self.gpa);
        self.options_arena.deinit();
    }

    /// Set the editor's overrides (allocated in `options_arena`). Folders added
    /// from here on apply them; call it before adding any.
    pub fn setOverrides(self: *Workspace, o: config.Overrides, host_globals: []const []const u8) Allocator.Error!void {
        const a = self.options_arena.allocator();
        self.overrides = o;
        self.loose = try o.apply(a, .{});
        self.loose_known = try knownGlobals(a, host_globals, self.loose);
    }

    fn destroy(self: *Workspace, f: *Folder) void {
        f.arena.deinit();
        self.gpa.destroy(f);
    }

    fn indexOf(self: *const Workspace, path: []const u8) ?usize {
        for (self.folders.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.path, path)) return i;
        }
        return null;
    }

    /// Add the folder at `path` (named by `folder_uri`) and read its config.
    /// A folder already present is read again, replacing the old one.
    pub fn add(
        self: *Workspace,
        folder_uri: []const u8,
        path: []const u8,
        files: ?Files,
        host_globals: []const []const u8,
    ) Allocator.Error!*Folder {
        const f = try self.gpa.create(Folder);
        errdefer self.gpa.destroy(f);
        // The arena lives in `f`, so it is set first and every other field is
        // assigned on its own: a struct literal would copy the arena's state
        // from before the allocations made while building it.
        f.arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer f.arena.deinit();
        const a = f.arena.allocator();
        const dir = try std.fs.path.resolveAllocPosix(a, &.{path});
        f.uri = try a.dupe(u8, folder_uri);
        f.path = dir;
        f.config = .{};
        f.failure = null;
        f.config_text = null;
        f.known_globals = host_globals;
        if (files) |fs| {
            const cfg_path = try f.configPath(a);
            if (fs.read(fs.ctx, a, cfg_path)) |bytes| {
                f.config_text = bytes;
                switch (try config.parse(a, bytes)) {
                    .ok => |c| f.config = c,
                    .failed => |why| f.failure = why,
                }
            }
        }
        f.config = try self.overrides.apply(a, f.config);
        f.runtime_cwd = try std.fs.path.resolveAllocPosix(a, &.{ dir, f.config.cwd });
        f.known_globals = try knownGlobals(a, host_globals, f.config);

        if (self.indexOf(dir)) |i| {
            self.destroy(self.folders.items[i]);
            self.folders.items[i] = f;
        } else {
            try self.folders.append(self.gpa, f);
        }
        return f;
    }

    /// The folder whose root is exactly `path`.
    pub fn find(self: *const Workspace, a: Allocator, path: []const u8) Allocator.Error!?*Folder {
        const dir = try std.fs.path.resolveAllocPosix(a, &.{path});
        const i = self.indexOf(dir) orelse return null;
        return self.folders.items[i];
    }

    /// Drop the folder at `path`. Returns whether it was there.
    pub fn remove(self: *Workspace, path: []const u8) Allocator.Error!bool {
        const dir = try std.fs.path.resolveAllocPosix(self.gpa, &.{path});
        defer self.gpa.free(dir);
        const i = self.indexOf(dir) orelse return false;
        self.destroy(self.folders.orderedRemove(i));
        return true;
    }

    /// The innermost folder containing `path`.
    pub fn folderOf(self: *const Workspace, path: []const u8) ?*Folder {
        var best: ?*Folder = null;
        for (self.folders.items) |f| {
            if (!contains(f.path, path)) continue;
            if (best == null or f.path.len > best.?.path.len) best = f;
        }
        return best;
    }

    /// The settings for the document at `doc_path` (null for one that names
    /// no file).
    pub fn settingsFor(
        self: *const Workspace,
        a: Allocator,
        doc_path: ?[]const u8,
        host_globals: []const []const u8,
    ) Allocator.Error!Settings {
        const known = self.loose_known orelse host_globals;
        const p = doc_path orelse return .{
            .cwd = null,
            .package_path = self.loose.package_path,
            .known_globals = known,
            .suppress = self.loose.suppress,
            .system = self.loose.system,
        };
        if (self.folderOf(p)) |f| return .{
            .cwd = f.runtime_cwd,
            .package_path = f.config.package_path,
            .known_globals = f.known_globals,
            .suppress = f.config.suppress,
            .system = f.config.system,
        };
        return .{
            .cwd = try std.fs.path.resolveAllocPosix(a, &.{ p, "..", self.loose.cwd }),
            .package_path = self.loose.package_path,
            .known_globals = known,
            .suppress = self.loose.suppress,
            .system = self.loose.system,
        };
    }
};

/// The host's globals that the config's system groups install, then the
/// config's `[globals]`. Allocated in `a` unless it is `host` unchanged.
fn knownGlobals(a: Allocator, host: []const []const u8, cfg: config.Config) Allocator.Error![]const []const u8 {
    if (cfg.globals.len == 0 and cfg.system == system.Groups.all) return host;
    var out: std.ArrayList([]const u8) = try .initCapacity(a, host.len + cfg.globals.len);
    for (host) |g| {
        if (stdlib_db.globalAvailable(g, cfg.system)) out.appendAssumeCapacity(g);
    }
    for (cfg.globals) |g| out.appendAssumeCapacity(g.name);
    return out.items;
}

/// Whether `path` is `dir` or lies under it.
fn contains(dir: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len) return true;
    // `/` itself, or a separator right after the folder's name.
    return std.mem.endsWith(u8, dir, "/") or path[dir.len] == '/';
}

/// A probe that sees open documents ahead of the disk: an open document that
/// has never been saved still resolves, and one whose file is gone still does.
pub const Overlay = struct {
    open_paths: []const []const u8,
    files: ?Files,

    pub fn probe(self: *Overlay) modules.Probe {
        return .{ .context = self, .exists = exists };
    }

    fn exists(context: *anyopaque, path: []const u8) bool {
        const self: *Overlay = @ptrCast(@alignCast(context));
        for (self.open_paths) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        const fs = self.files orelse return false;
        return fs.exists(fs.ctx, path);
    }
};

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

/// Files held in memory, by path.
pub const MemoryFiles = struct {
    entries: []const [2][]const u8,

    pub fn files(self: *MemoryFiles) Files {
        return .{ .ctx = self, .read = read, .exists = exists, .list = list, .stamp = stamp, .dir_stamp = dirStamp };
    }

    /// The direct children of `dir` among the paths held; null when no path
    /// lies under it, as for a directory that is not there.
    fn list(ctx: ?*anyopaque, a: Allocator, dir: []const u8) ?[]const Files.DirEntry {
        const self: *MemoryFiles = @ptrCast(@alignCast(ctx.?));
        var out: std.ArrayList(Files.DirEntry) = .empty;
        var any = false;
        for (self.entries) |e| {
            if (!std.mem.startsWith(u8, e[0], dir) or e[0].len <= dir.len + 1 or e[0][dir.len] != '/') continue;
            any = true;
            const rest = e[0][dir.len + 1 ..];
            const cut = std.mem.findScalar(u8, rest, '/');
            const name = rest[0 .. cut orelse rest.len];
            const dup = for (out.items) |o| {
                if (std.mem.eql(u8, o.name, name)) break true;
            } else false;
            if (!dup) out.append(a, .{ .name = name, .kind = if (cut != null) .directory else .file }) catch return null;
        }
        return if (any) out.items else null;
    }

    /// The names in `dir` stand in for its modification time: their count,
    /// and the sum of their hashes, each counted once. Null when no path lies
    /// under it.
    fn dirStamp(ctx: ?*anyopaque, dir: []const u8) ?Files.Stamp {
        const self: *MemoryFiles = @ptrCast(@alignCast(ctx.?));
        var count: u64 = 0;
        var sum: u64 = 0;
        for (self.entries, 0..) |e, i| {
            const name = childOf(dir, e[0]) orelse continue;
            const seen = for (self.entries[0..i]) |o| {
                const other = childOf(dir, o[0]) orelse continue;
                if (std.mem.eql(u8, other, name)) break true;
            } else false;
            if (seen) continue;
            count += 1;
            sum +%= std.hash.Wyhash.hash(0, name);
        }
        if (count == 0) return null;
        return .{ .size = count, .mtime_ns = sum };
    }

    /// The name of the entry in `dir` that `path` is, or lies under (with a
    /// trailing `/` for a directory).
    fn childOf(dir: []const u8, path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, dir) or path.len <= dir.len + 1 or path[dir.len] != '/') return null;
        const rest = path[dir.len + 1 ..];
        const cut = std.mem.findScalar(u8, rest, '/') orelse return rest;
        return rest[0 .. cut + 1];
    }

    /// The length and a hash of the contents stand in for a modification time.
    fn stamp(ctx: ?*anyopaque, path: []const u8) ?Files.Stamp {
        const self: *MemoryFiles = @ptrCast(@alignCast(ctx.?));
        const bytes = self.find(path) orelse return null;
        return .{ .size = bytes.len, .mtime_ns = @as(u64, @truncate(std.hash.Wyhash.hash(0, bytes))) };
    }

    fn find(self: *MemoryFiles, path: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e[0], path)) return e[1];
        }
        return null;
    }

    fn read(ctx: ?*anyopaque, a: Allocator, path: []const u8) ?[]u8 {
        const self: *MemoryFiles = @ptrCast(@alignCast(ctx.?));
        const bytes = self.find(path) orelse return null;
        return a.dupe(u8, bytes) catch null;
    }

    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *MemoryFiles = @ptrCast(@alignCast(ctx.?));
        return self.find(path) != null;
    }
};

/// A `Store` in memory, by name.
pub const MemoryStore = struct {
    gpa: Allocator,
    saved: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *MemoryStore) void {
        var it = self.saved.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.saved.deinit(self.gpa);
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .ctx = self, .load = load, .save = save };
    }

    fn load(ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx.?));
        const bytes = self.saved.get(name) orelse return null;
        return a.dupe(u8, bytes) catch null;
    }

    fn save(ctx: ?*anyopaque, name: []const u8, bytes: []const u8) void {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx.?));
        const copy = self.gpa.dupe(u8, bytes) catch return;
        if (self.saved.getPtr(name)) |old| {
            self.gpa.free(old.*);
            old.* = copy;
            return;
        }
        const key = self.gpa.dupe(u8, name) catch {
            self.gpa.free(copy);
            return;
        };
        self.saved.put(self.gpa, key, copy) catch {
            self.gpa.free(key);
            self.gpa.free(copy);
        };
    }
};

test "workspace: each folder reads its own config, and nested folders take the innermost" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/a/mahina.toml", "version = 1\n[runtime]\ncwd = \"src\"\npackage_path = [\"./?.mah\"]\n[globals]\nspawn = \"host\"\n" },
        .{ "/w/a/inner/mahina.toml", "version = 1\n[diagnostics]\nsuppress = [\"unused-local\"]\n" },
    } };
    var ws = Workspace.init(testing.allocator);
    defer ws.deinit();
    const host = [_][]const u8{"print"};
    _ = try ws.add("file:///w/a", "/w/a/", mem.files(), &host);
    _ = try ws.add("file:///w/b", "/w/b", mem.files(), &host);
    _ = try ws.add("file:///w/a/inner", "/w/a/inner", mem.files(), &host);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const in_a = try ws.settingsFor(a, "/w/a/src/main.mah", &host);
    try testing.expectEqualStrings("/w/a/src", in_a.cwd.?);
    try testing.expectEqual(@as(usize, 1), in_a.package_path.len);
    try testing.expectEqual(@as(usize, 2), in_a.known_globals.len);
    try testing.expectEqualStrings("spawn", in_a.known_globals[1]);

    const in_inner = try ws.settingsFor(a, "/w/a/inner/x.mah", &host);
    try testing.expectEqualStrings("unused-local", in_inner.suppress[0]);
    try testing.expectEqualStrings("/w/a/inner", in_inner.cwd.?);

    // No config: the defaults, searching from the folder.
    const in_b = try ws.settingsFor(a, "/w/b/m.mah", &host);
    try testing.expectEqualStrings("/w/b", in_b.cwd.?);
    try testing.expectEqual(config.default_package_path.len, in_b.package_path.len);

    // `/w/ab` is not inside `/w/a`; a file in no folder searches from its directory.
    const outside = try ws.settingsFor(a, "/w/ab/m.mah", &host);
    try testing.expectEqualStrings("/w/ab", outside.cwd.?);
    try testing.expect((try ws.settingsFor(a, null, &host)).cwd == null);
}

test "workspace: the system groups decide which of the host's globals exist" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/none/mahina.toml", "version = 1\n[runtime]\nsystem = []\n" },
        .{ "/clock/mahina.toml", "version = 1\n[runtime]\nsystem = [\"clock\"]\n" },
    } };
    var ws = Workspace.init(testing.allocator);
    defer ws.deinit();
    const host = [_][]const u8{ "print", "aio" };
    _ = try ws.add("file:///none", "/none", mem.files(), &host);
    _ = try ws.add("file:///clock", "/clock", mem.files(), &host);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = try ws.settingsFor(a, "/none/m.mah", &host);
    try testing.expectEqual(system.Groups.none, none.system);
    try testing.expectEqual(@as(usize, 1), none.known_globals.len);
    try testing.expectEqualStrings("print", none.known_globals[0]);
    try testing.expectEqual(@as(usize, 2), (try ws.settingsFor(a, "/clock/m.mah", &host)).known_globals.len);
    // Outside any folder, every group, as the CLI gives.
    try testing.expectEqual(system.Groups.all, (try ws.settingsFor(a, "/elsewhere/m.mah", &host)).system);
}

test "workspace: the editor's overrides apply over every folder's config and to loose files" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/mahina.toml", "version = 1\n[runtime]\ncwd = \"src\"\nsystem = [\"files\"]\n[diagnostics]\nsuppress = [\"W0001\"]\n" },
    } };
    var ws = Workspace.init(testing.allocator);
    defer ws.deinit();
    const host = [_][]const u8{ "print", "aio" };
    try ws.setOverrides(.{
        .system = .none,
        .package_path = &.{"./lib/?.mah"},
        .suppress = &.{"unresolved-require"},
        .globals = &.{.{ .name = "emit", .description = "" }},
    }, &host);
    _ = try ws.add("file:///w", "/w", mem.files(), &host);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_w = try ws.settingsFor(a, "/w/m.mah", &host);
    try testing.expectEqualStrings("/w/src", in_w.cwd.?);
    try testing.expectEqual(system.Groups.none, in_w.system);
    try testing.expectEqualStrings("./lib/?.mah", in_w.package_path[0]);
    try testing.expectEqual(@as(usize, 2), in_w.suppress.len);
    // `aio` needs a group the override turned off; `emit` is the editor's.
    try testing.expectEqual(@as(usize, 2), in_w.known_globals.len);
    try testing.expectEqualStrings("emit", in_w.known_globals[1]);

    const loose = try ws.settingsFor(a, "/elsewhere/m.mah", &host);
    try testing.expectEqualStrings("/elsewhere", loose.cwd.?);
    try testing.expectEqual(system.Groups.none, loose.system);
    try testing.expectEqualStrings("unresolved-require", loose.suppress[0]);
    try testing.expectEqualStrings("emit", (try ws.settingsFor(a, null, &host)).known_globals[1]);
}

test "workspace: a rejected config keeps the defaults and says why; re-adding and removing" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/mahina.toml", "version = 1\n[runtme]\n" },
    } };
    var ws = Workspace.init(testing.allocator);
    defer ws.deinit();
    const f = try ws.add("file:///w", "/w", mem.files(), &.{});
    try testing.expectEqual(@as(u32, 2), f.failure.?.line);
    try testing.expectEqualStrings("/w", f.runtime_cwd);

    // Adding the same folder again replaces it rather than listing it twice.
    _ = try ws.add("file:///w", "/w", mem.files(), &.{});
    try testing.expectEqual(@as(usize, 1), ws.folders.items.len);
    try testing.expect(try ws.remove("/w/"));
    try testing.expect(!try ws.remove("/w"));
    try testing.expect(ws.folderOf("/w/x.mah") == null);
}

test "workspace: the overlay sees open documents before the disk" {
    var mem: MemoryFiles = .{ .entries = &.{.{ "/w/disk.mah", "" }} };
    var overlay: Overlay = .{ .open_paths = &.{"/w/unsaved.mah"}, .files = mem.files() };
    const p = overlay.probe();
    try testing.expect(p.exists(p.context, "/w/unsaved.mah"));
    try testing.expect(p.exists(p.context, "/w/disk.mah"));
    try testing.expect(!p.exists(p.context, "/w/none.mah"));
    var no_disk: Overlay = .{ .open_paths = &.{}, .files = null };
    const q = no_disk.probe();
    try testing.expect(!q.exists(q.context, "/w/disk.mah"));
}
