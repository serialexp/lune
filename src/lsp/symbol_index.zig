//! The workspace symbol index (doc 74 §7.4, P6e): every function and method
//! of every source file in the workspace folders, at any depth, and each
//! file's top-level names, for `workspace/symbol`.
//!
//! Kept per file. A folder is walked once, when it first appears (and again
//! when its source extensions change); after that only the paths in the
//! change log are looked at again: what the client's file watcher reported
//! created, changed or deleted (`note`). A looked-at file is read and parsed
//! again only when its `Files.Stamp` (size and modification time) differs
//! from the one it was indexed at. A client that cannot watch files has no
//! change log, so the server marks the index `stale` and every request walks
//! every folder; the stamps still spare the parsing. Open documents are
//! indexed from their text, keyed by a hash of it, ahead of their file.
//! Bounded (§3): at most `max_files` files are indexed, and a change log
//! longer than that is dropped for a walk.

const std = @import("std");
const diag = @import("../diag.zig");
const parser = @import("../parser.zig");
const position = @import("position.zig");
const syntax = @import("syntax.zig");
const uri_mod = @import("uri.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;

pub const max_files = 20_000;

/// Directories a walk does not enter, besides the hidden ones (`.git`).
pub const skipped_dirs = [_][]const u8{ "node_modules", "zig-out", "target" };

pub const Symbol = struct {
    name: []const u8,
    kind: syntax.Kind,
    /// The function or table it is declared in, when it is not top-level.
    container: ?[]const u8,
    /// The name, in the file's text.
    range: position.Range,
};

/// One folder to walk, and the extensions of the files it holds.
pub const Root = struct {
    path: []const u8,
    extensions: []const []const u8,
};

/// An open document, indexed from its text.
pub const Open = struct {
    uri: []const u8,
    /// Its file, resolved, so the walk leaves the file to the document.
    path: ?[]const u8,
    text: []const u8,
};

pub const Index = struct {
    gpa: Allocator,
    /// By path (by uri for a document with no file).
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// The roots the index was last brought up to date with, in `roots_arena`.
    roots: []const Root = &.{},
    roots_arena: std.heap.ArenaAllocator,
    /// The change log: the paths reported since the last refresh (keys owned
    /// by `gpa`). Only these are looked at again.
    pending: std.StringHashMapUnmanaged(void) = .empty,
    /// The next refresh walks every root: there is no change log to go by
    /// (nothing walked yet, the log overflowed, or the client cannot watch).
    stale: bool = true,
    encoding: position.Encoding = .utf16,
    /// Counts refreshes; an entry remembers the last one that saw it.
    generation: u32 = 0,
    /// Files parsed, and files stamped, so far: what an unchanged stamp and
    /// the change log save, for tests and the benchmark.
    builds: u64 = 0,
    stamps: u64 = 0,
    /// A walk stopped at `max_files`.
    truncated: bool = false,

    /// Two allocations per file, sized exactly (a 10k-file workspace holds
    /// 10k of these): `strings` holds `key`, `uri` and every symbol's names.
    const Entry = struct {
        strings: []u8,
        key: []const u8,
        uri: []const u8,
        stamp: workspace.Files.Stamp,
        symbols: []const Symbol,
        seen: u32,
        /// Indexed from an open document's text.
        document: bool,
        /// `key` is a path (else the uri of a document with no file).
        file: bool,
    };

    pub const Change = enum { created, changed, deleted };

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa, .roots_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Index) void {
        self.clear();
        self.entries.deinit(self.gpa);
        self.clearPending();
        self.pending.deinit(self.gpa);
        self.roots_arena.deinit();
    }

    fn clear(self: *Index) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| self.free(e.*);
        self.entries.clearRetainingCapacity();
    }

    fn clearPending(self: *Index) void {
        var it = self.pending.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.pending.clearRetainingCapacity();
    }

    fn free(self: *Index, e: *Entry) void {
        self.gpa.free(e.strings);
        self.gpa.free(e.symbols);
        self.gpa.destroy(e);
    }

    fn remove(self: *Index, key: []const u8) void {
        const e = (self.entries.fetchRemove(key) orelse return).value;
        self.free(e);
    }

    /// Log a change the client's watcher reported at `path` (resolved). What
    /// cannot matter is dropped here: a path in no root or in a directory the
    /// walk does not enter, and a change to a file that is not a source file
    /// (a creation or deletion is kept: it may be a directory's).
    pub fn note(self: *Index, path: []const u8, change: Change) Allocator.Error!void {
        if (self.stale) return; // the next refresh walks everything
        const root = innermost(self.roots, path) orelse return;
        if (skippedBelow(root.path, path)) return;
        if (change == .changed and !hasExtension(path, root.extensions)) return;
        try self.queue(path);
    }

    fn queue(self: *Index, path: []const u8) Allocator.Error!void {
        if (self.pending.contains(path)) return;
        if (self.pending.count() >= max_files) {
            self.clearPending();
            self.stale = true;
            return;
        }
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.pending.put(self.gpa, key, {});
    }

    /// Bring the index up to date with the open documents, the roots, and
    /// the change log (or, when `stale`, everything under the roots).
    /// `scratch` holds what lives only for this call.
    pub fn refresh(
        self: *Index,
        scratch: Allocator,
        roots: []const Root,
        files: ?workspace.Files,
        opened: []const Open,
        encoding: position.Encoding,
    ) Allocator.Error!void {
        self.generation +%= 1;
        if (encoding != self.encoding) {
            self.clear();
            self.encoding = encoding;
            self.stale = true;
        }
        const disk: ?workspace.Files = if (files) |f| (if (f.list != null and f.stamp != null) f else null) else null;

        // Open documents first: the walks leave their files to them.
        var open_paths: std.StringHashMapUnmanaged(void) = .empty;
        var open_keys: std.StringHashMapUnmanaged(void) = .empty;
        for (opened) |d| {
            const key = d.path orelse d.uri;
            try open_keys.put(scratch, key, {});
            if (d.path) |q| try open_paths.put(scratch, q, {});
            const stamp: workspace.Files.Stamp = .{ .size = d.text.len, .mtime_ns = @as(u64, @truncate(std.hash.Wyhash.hash(0, d.text))) };
            try self.update(key, d.uri, stamp, d.text, true, d.path != null);
        }
        // A document closed since goes back to its file, if there is one.
        var closed: std.ArrayList([]const u8) = .empty;
        var eit = self.entries.valueIterator();
        while (eit.next()) |e| {
            if (e.*.document and !open_keys.contains(e.*.key)) try closed.append(scratch, try scratch.dupe(u8, e.*.key));
        }
        for (closed.items) |k| {
            const e = self.entries.get(k).?;
            if (disk != null and e.file) {
                e.document = false;
                try self.queue(k);
            } else self.remove(k);
        }

        const fs = disk orelse {
            self.clearPending();
            self.stale = false;
            return;
        };
        var walk: Walk = .{ .index = self, .scratch = scratch, .fs = fs, .open_paths = &open_paths };
        // Where entries not seen by this refresh are gone: each scope, swept
        // of what belongs to its root (a nested root's files are its own).
        var scopes: std.StringHashMapUnmanaged([]const u8) = .empty;

        // A root new since the last refresh is walked, and so is one that held
        // a nested root that went, since that directory is now its own
        // (every root, when stale).
        const roots_changed = !sameRoots(self.roots, roots);
        if (roots_changed or self.stale) {
            var to_walk: std.ArrayList(Root) = .empty;
            for (roots) |r| {
                const known = for (self.roots) |o| {
                    if (sameRoot(o, r)) break true;
                } else false;
                const gained = for (self.roots) |o| {
                    const kept = for (roots) |n| {
                        if (std.mem.eql(u8, n.path, o.path)) break true;
                    } else false;
                    if (!kept and o.path.len > r.path.len and within(r.path, o.path)) break true;
                } else false;
                if (self.stale or !known or gained) try to_walk.append(scratch, r);
            }
            if (roots_changed) {
                // `to_walk` points into the caller's roots, not the old ones.
                _ = self.roots_arena.reset(.retain_capacity);
                self.roots = try copyRoots(self.roots_arena.allocator(), roots);
            }
            if (self.stale) self.truncated = false;
            for (to_walk.items) |r| {
                const root = innermost(self.roots, r.path).?;
                try walk.dir(root, root.path);
                try scopes.put(scratch, root.path, root.path);
            }
        }

        // Then only what the change log names.
        var pit = self.pending.keyIterator();
        while (pit.next()) |k| {
            const q = k.*;
            if (open_paths.contains(q)) continue;
            const root = innermost(self.roots, q) orelse continue;
            if (skippedBelow(root.path, q)) continue;
            self.stamps += 1;
            if (fs.stamp.?(fs.ctx, q)) |stamp| {
                if (hasExtension(q, root.extensions)) {
                    try walk.file(q, stamp);
                    continue;
                }
            } else if (fs.list.?(fs.ctx, scratch, q) != null) {
                try walk.dir(root, q);
            }
            // Gone, not a source file, or a directory: whatever was indexed
            // there and was not just seen again is gone.
            try scopes.put(scratch, try scratch.dupe(u8, q), root.path);
        }
        self.clearPending();
        self.stale = false;

        if (walk.stopped) scopes.clearRetainingCapacity();
        if (scopes.count() > 0 or roots_changed) try self.sweep(scratch, &scopes);
    }

    /// Drop the entries from a file that this refresh did not see and that
    /// lie in one of `scopes` (keyed by path, valued by the path of the root
    /// the scope belongs to) under that same root, or that lie in no root.
    fn sweep(self: *Index, scratch: Allocator, scopes: *const std.StringHashMapUnmanaged([]const u8)) Allocator.Error!void {
        var gone: std.ArrayList([]const u8) = .empty;
        var it = self.entries.valueIterator();
        while (it.next()) |ep| {
            const e = ep.*;
            if (e.seen == self.generation or e.document or !e.file) continue;
            const root = innermost(self.roots, e.key) orelse {
                try gone.append(scratch, e.key);
                continue;
            };
            // The entry's path, then each directory above it.
            var at: []const u8 = e.key;
            while (true) {
                if (scopes.get(at)) |scope_root| {
                    if (std.mem.eql(u8, scope_root, root.path)) try gone.append(scratch, e.key);
                    break;
                }
                if (at.len <= root.path.len) break;
                at = std.fs.path.dirnamePosix(at) orelse break;
            }
        }
        for (gone.items) |k| self.remove(k);
    }

    const Walk = struct {
        index: *Index,
        scratch: Allocator,
        fs: workspace.Files,
        open_paths: *const std.StringHashMapUnmanaged(void),
        /// A walk reached `max_files`: what it did not get to was not seen,
        /// and is not gone.
        stopped: bool = false,

        /// Index every source file under `start`, in `root`, leaving out what
        /// the walk does not enter and the directories of nested roots.
        fn dir(w: *Walk, root: Root, start: []const u8) Allocator.Error!void {
            const self = w.index;
            var stack: std.ArrayList([]const u8) = .empty;
            try stack.append(w.scratch, start);
            while (stack.pop()) |d| {
                const listing = w.fs.list.?(w.fs.ctx, w.scratch, d) orelse continue;
                for (listing) |e| {
                    if (e.name.len == 0 or e.name[0] == '.') continue;
                    const path = try std.fs.path.resolveAllocPosix(w.scratch, &.{ d, e.name });
                    switch (e.kind) {
                        .directory => {
                            if (isSkipped(e.name)) continue;
                            const nested = for (self.roots) |r| {
                                if (std.mem.eql(u8, r.path, path)) break true;
                            } else false;
                            if (!nested) try stack.append(w.scratch, path);
                        },
                        .file => {
                            if (!hasExtension(e.name, root.extensions)) continue;
                            if (w.open_paths.contains(path)) continue;
                            if (self.entries.get(path)) |old| if (old.seen == self.generation) continue;
                            self.stamps += 1;
                            const stamp = w.fs.stamp.?(w.fs.ctx, path) orelse continue;
                            try w.file(path, stamp);
                            if (w.stopped) return;
                        },
                    }
                }
            }
        }

        /// Index the file at `path`, unless it is indexed at `stamp` already.
        fn file(w: *Walk, path: []const u8, stamp: workspace.Files.Stamp) Allocator.Error!void {
            const self = w.index;
            const old = self.entries.get(path);
            if (old) |e| if (!e.document and std.meta.eql(e.stamp, stamp)) {
                e.seen = self.generation;
                return;
            };
            if (old == null and self.entries.count() >= max_files) {
                self.truncated = true;
                w.stopped = true;
                return;
            }
            // Freed at once: a first walk reads every file.
            const text = w.fs.read(w.fs.ctx, self.gpa, path) orelse return;
            defer self.gpa.free(text);
            try self.update(path, try uri_mod.fromPath(w.scratch, path), stamp, text, false, true);
        }
    };

    /// Index `text` under `key`, unless it is indexed at `stamp` already.
    fn update(self: *Index, key: []const u8, uri: []const u8, stamp: workspace.Files.Stamp, text: []const u8, document: bool, file: bool) Allocator.Error!void {
        if (self.entries.get(key)) |old| {
            if (old.document == document and std.meta.eql(old.stamp, stamp)) {
                old.seen = self.generation;
                return;
            }
            self.remove(key);
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const found = try self.symbolsOf(scratch.allocator(), text);

        var size = key.len + uri.len;
        for (found) |s| size += s.name.len + if (s.container) |c| c.len else 0;
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        e.strings = try self.gpa.alloc(u8, size);
        errdefer self.gpa.free(e.strings);
        const symbols = try self.gpa.alloc(Symbol, found.len);
        var at: usize = 0;
        e.key = pack(e.strings, &at, key);
        e.uri = pack(e.strings, &at, uri);
        for (found, symbols) |s, *slot| slot.* = .{
            .name = pack(e.strings, &at, s.name),
            .kind = s.kind,
            .container = if (s.container) |c| pack(e.strings, &at, c) else null,
            .range = s.range,
        };
        e.symbols = symbols;
        e.stamp = stamp;
        e.seen = self.generation;
        e.document = document;
        e.file = file;
        self.entries.put(self.gpa, e.key, e) catch |err| {
            self.gpa.free(symbols);
            return err;
        };
    }

    fn pack(buf: []u8, at: *usize, s: []const u8) []const u8 {
        const dst = buf[at.*..][0..s.len];
        @memcpy(dst, s);
        at.* += s.len;
        return dst;
    }

    /// The symbols of `text`, allocated in `a` (scratch).
    fn symbolsOf(self: *Index, a: Allocator, text: []const u8) Allocator.Error![]const Symbol {
        self.builds += 1;
        const source = try a.dupeSentinel(u8, text, 0);
        var diags = diag.Diagnostics.init(self.gpa);
        defer diags.deinit();
        var tree = parser.parse(self.gpa, source, &diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return &.{},
        };
        defer tree.deinit();
        const outline = try syntax.symbols(a, tree.root);
        var index = position.LineIndex.build(self.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TextTooLong => return &.{},
        };
        defer index.deinit(self.gpa);
        var out: std.ArrayList(Symbol) = .empty;
        try flatten(a, &out, outline, null, &index, text, self.encoding);
        return out.items;
    }

    /// The symbols matching `query` (see `score`), the closest first, at most
    /// `limit` of them; allocated in `a`, and valid until the next refresh.
    pub fn search(self: *const Index, a: Allocator, query: []const u8, limit: usize) Allocator.Error![]const Hit {
        var hits: std.ArrayList(Hit) = .empty;
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            for (e.*.symbols) |*s| {
                const rank = score(s.name, query) orelse continue;
                try hits.append(a, .{ .symbol = s, .uri = e.*.uri, .rank = rank });
            }
        }
        std.mem.sort(Hit, hits.items, {}, Hit.before);
        return hits.items[0..@min(limit, hits.items.len)];
    }
};

/// The innermost of `roots` containing `path`.
fn innermost(roots: []const Root, path: []const u8) ?Root {
    var best: ?Root = null;
    for (roots) |r| {
        if (!within(r.path, path)) continue;
        if (best == null or r.path.len > best.?.path.len) best = r;
    }
    return best;
}

/// Whether `path` is `dir` or lies under it.
fn within(dir: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len) return true;
    return std.mem.endsWith(u8, dir, "/") or path[dir.len] == '/';
}

fn isSkipped(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for (skipped_dirs) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// Whether a component of `path` below `root` is one the walk does not enter.
fn skippedBelow(root: []const u8, path: []const u8) bool {
    if (path.len <= root.len) return false;
    var it = std.mem.tokenizeScalar(u8, path[root.len..], '/');
    while (it.next()) |part| {
        if (isSkipped(part)) return true;
    }
    return false;
}

fn sameRoot(x: Root, y: Root) bool {
    if (!std.mem.eql(u8, x.path, y.path) or x.extensions.len != y.extensions.len) return false;
    for (x.extensions, y.extensions) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn sameRoots(xs: []const Root, ys: []const Root) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| {
        if (!sameRoot(x, y)) return false;
    }
    return true;
}

fn copyRoots(a: Allocator, roots: []const Root) Allocator.Error![]const Root {
    const out = try a.alloc(Root, roots.len);
    for (roots, out) |r, *slot| {
        const xs = try a.alloc([]const u8, r.extensions.len);
        for (r.extensions, xs) |x, *s| s.* = try a.dupe(u8, x);
        slot.* = .{ .path = try a.dupe(u8, r.path), .extensions = xs };
    }
    return out;
}

pub const Hit = struct {
    symbol: *const Symbol,
    uri: []const u8,
    rank: u8,

    fn before(_: void, x: Hit, y: Hit) bool {
        if (x.rank != y.rank) return x.rank < y.rank;
        const order = std.mem.order(u8, x.symbol.name, y.symbol.name);
        if (order != .eq) return order == .lt;
        return std.mem.order(u8, x.uri, y.uri) == .lt;
    }
};

/// How `name` matches `query`, ignoring case: 0 the whole name, 1 a prefix,
/// 2 a substring, 3 a subsequence (`mad` in `M.add`); null for no match. An
/// empty query matches everything at 3.
pub fn score(name: []const u8, query: []const u8) ?u8 {
    if (query.len == 0) return 3;
    if (std.ascii.eqlIgnoreCase(name, query)) return 0;
    if (std.ascii.startsWithIgnoreCase(name, query)) return 1;
    if (std.ascii.findIgnoreCase(name, query) != null) return 2;
    var i: usize = 0;
    for (name) |c| {
        if (i < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[i])) i += 1;
    }
    return if (i == query.len) 3 else null;
}

fn hasExtension(name: []const u8, extensions: []const []const u8) bool {
    for (extensions) |x| {
        if (std.mem.endsWith(u8, name, x) and name.len > x.len) return true;
    }
    return false;
}

/// The outline's functions and methods at any depth, and its top-level names.
fn flatten(
    a: Allocator,
    out: *std.ArrayList(Symbol),
    list: []const syntax.Symbol,
    container: ?[]const u8,
    index: *const position.LineIndex,
    text: []const u8,
    encoding: position.Encoding,
) Allocator.Error!void {
    for (list) |s| {
        const callable = s.kind == .function or s.kind == .method;
        if (container == null or callable) {
            try out.append(a, .{
                .name = s.name,
                .kind = s.kind,
                .container = container,
                .range = index.toRange(text, s.selection.start, s.selection.end, encoding),
            });
        }
        try flatten(a, out, s.children, s.name, index, text, encoding);
    }
}

/// The file extensions `package.path` templates name: `.mah` of `./?.mah`.
pub fn extensionsOf(a: Allocator, templates: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (templates) |t| {
        const base = std.fs.path.basenamePosix(t);
        const dot = std.mem.findScalarLast(u8, base, '.') orelse continue;
        const x = base[dot..];
        const dup = for (out.items) |o| {
            if (std.mem.eql(u8, o, x)) break true;
        } else false;
        if (!dup) try out.append(a, x);
    }
    return out.items;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

test "symbol index: functions at any depth and top-level names, kept until a file changes" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "local M = {}\nfunction M.add(a, b)\n  local function helper() end\n  local inner = 1\nend\nreturn M\n" },
        .{ "/w/sub/b.mah", "function greet() end\n" },
        .{ "/w/notes.txt", "function nope() end\n" },
        .{ "/w/.git/c.mah", "function hidden() end\n" },
        .{ "/w/node_modules/d.mah", "function vendored() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = [_]Root{.{ .path = "/w", .extensions = &.{".mah"} }};

    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(u64, 2), idx.builds);
    const all = try idx.search(a, "", 100);
    var names: std.ArrayList(u8) = .empty;
    for (all) |h| {
        try names.appendSlice(a, h.symbol.name);
        try names.append(a, ' ');
    }
    try testing.expectEqualStrings("M M.add greet helper ", names.items);
    const helper = (try idx.search(a, "helper", 10))[0];
    try testing.expectEqualStrings("M.add", helper.symbol.container.?);
    try testing.expectEqualStrings("file:///w/a.mah", helper.uri);
    try testing.expectEqual(@as(u32, 2), helper.symbol.range.start.line);

    // Nothing reported: the disk is not looked at again.
    const stamped = idx.stamps;
    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(u64, 2), idx.builds);
    try testing.expectEqual(stamped, idx.stamps);

    // What the change log names is: a changed file is parsed again, a file
    // renamed away from a source extension goes. An open document wins over
    // its file, and its file is back once it closes.
    entries[1][1] = "function welcome() end\n";
    entries[0][0] = "/w/gone.txt";
    try idx.note("/w/sub/b.mah", .changed);
    try idx.note("/w/a.mah", .deleted);
    try idx.note("/w/gone.txt", .created);
    try idx.note("/w/notes.txt", .changed); // not a source file: dropped
    try idx.note("/w/.git/c.mah", .changed); // not walked: dropped
    try testing.expectEqual(@as(u32, 3), idx.pending.count());
    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, "add", 10)).len);
    try testing.expectEqualStrings("welcome", (try idx.search(a, "welcome", 10))[0].symbol.name);
    try testing.expectEqual(stamped + 3, idx.stamps);
    try idx.refresh(a, &roots, mem.files(), &.{.{ .uri = "file:///w/sub/b.mah", .path = "/w/sub/b.mah", .text = "function edited() end\n" }}, .utf8);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, "welcome", 10)).len);
    try testing.expectEqualStrings("edited", (try idx.search(a, "edit", 10))[0].symbol.name);
    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, "edited", 10)).len);
    try testing.expectEqualStrings("welcome", (try idx.search(a, "welcome", 10))[0].symbol.name);

    // A directory reported once stands for everything under it: deleted, its
    // files go; created (moved in), its files are walked.
    entries[1][0] = "/w/moved/b.mah";
    try idx.note("/w/sub", .deleted);
    try idx.note("/w/moved", .created);
    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqualStrings("file:///w/moved/b.mah", (try idx.search(a, "welcome", 10))[0].uri);
    try testing.expectEqual(@as(usize, 1), (try idx.search(a, "welcome", 10)).len);

    // With no change log (a client that cannot watch), a stale index walks
    // every root, and the stamps still spare the parsing.
    entries[2][0] = "/w/notes.mah";
    const built = idx.builds;
    idx.stale = true;
    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqualStrings("nope", (try idx.search(a, "nope", 10))[0].symbol.name);
    try testing.expectEqual(built + 1, idx.builds);
}

test "symbol index: nested roots keep their own files, and a root that goes takes its files" {
    var entries = [_][2][]const u8{
        .{ "/w/a.mah", "function outer() end\n" },
        .{ "/w/in/b.lua", "function inner() end\n" },
    };
    var mem: workspace.MemoryFiles = .{ .entries = &entries };
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const both = [_]Root{
        .{ .path = "/w", .extensions = &.{".mah"} },
        .{ .path = "/w/in", .extensions = &.{".lua"} },
    };
    try idx.refresh(a, &both, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(usize, 2), (try idx.search(a, "", 10)).len);
    // The outer folder's directory event does not sweep the inner's file.
    try idx.note("/w/in", .created);
    try idx.refresh(a, &both, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(usize, 1), (try idx.search(a, "inner", 10)).len);
    const outer_only = [_]Root{both[0]};
    try idx.refresh(a, &outer_only, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, "inner", 10)).len);
    try testing.expectEqual(@as(usize, 1), (try idx.search(a, "outer", 10)).len);
}

test "symbol index: the closest matches first" {
    try testing.expectEqual(@as(?u8, 0), score("Add", "add"));
    try testing.expectEqual(@as(?u8, 1), score("addAll", "add"));
    try testing.expectEqual(@as(?u8, 2), score("M.add", "add"));
    try testing.expectEqual(@as(?u8, 3), score("M.add", "mad"));
    try testing.expectEqual(@as(?u8, null), score("M.add", "dam"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const xs = try extensionsOf(arena.allocator(), &.{ "./?.mah", "./?/init.mah", "./?.lua", "lib/?" });
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqualStrings(".lua", xs[1]);
}
