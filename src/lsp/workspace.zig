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
const config = @import("config.zig");
const modules = @import("modules.zig");

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
};

pub const Workspace = struct {
    gpa: Allocator,
    folders: std.ArrayList(*Folder) = .empty,

    pub fn init(gpa: Allocator) Workspace {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.folders.items) |f| self.destroy(f);
        self.folders.deinit(self.gpa);
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
        f.runtime_cwd = try std.fs.path.resolveAllocPosix(a, &.{ dir, f.config.cwd });
        if (f.config.globals.len > 0) {
            const all = try a.alloc([]const u8, host_globals.len + f.config.globals.len);
            @memcpy(all[0..host_globals.len], host_globals);
            for (f.config.globals, all[host_globals.len..]) |g, *slot| slot.* = g.name;
            f.known_globals = all;
        }

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
        const p = doc_path orelse return .{
            .cwd = null,
            .package_path = &config.default_package_path,
            .known_globals = host_globals,
            .suppress = &.{},
        };
        if (self.folderOf(p)) |f| return .{
            .cwd = f.runtime_cwd,
            .package_path = f.config.package_path,
            .known_globals = f.known_globals,
            .suppress = f.config.suppress,
        };
        return .{
            .cwd = try std.fs.path.resolveAllocPosix(a, &.{ p, ".." }),
            .package_path = &config.default_package_path,
            .known_globals = host_globals,
            .suppress = &.{},
        };
    }
};

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
        return .{ .ctx = self, .read = read, .exists = exists };
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
