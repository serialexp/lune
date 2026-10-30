//! The workspace symbol index (doc 74 §7.4, P6e): every function and method
//! of every source file in the workspace folders, at any depth, and each
//! file's top-level names, for `workspace/symbol`.
//!
//! Kept per file and brought up to date on each request: the folders are
//! walked and each file's `Files.Stamp` (size and modification time) is
//! compared with the one it was indexed at, so only a changed file is read
//! and parsed again, and a removed one is dropped. Open documents are indexed
//! from their text, keyed by a hash of it, ahead of their file. Bounded
//! (§3): at most `max_files` files are indexed; a walk past that stops and
//! says so.

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
    /// Counts refreshes; an entry remembers the last one that saw it.
    generation: u32 = 0,
    /// Files parsed so far: what an unchanged stamp saves, for tests and the
    /// benchmark.
    builds: u64 = 0,
    /// The last walk stopped at `max_files`.
    truncated: bool = false,

    /// Two allocations per file, sized exactly (a 10k-file workspace holds
    /// 10k of these): `strings` holds `key`, `uri` and every symbol's names.
    const Entry = struct {
        strings: []u8,
        key: []const u8,
        uri: []const u8,
        stamp: workspace.Files.Stamp,
        encoding: position.Encoding,
        symbols: []const Symbol,
        seen: u32,
    };

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Index) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| self.free(e.*);
        self.entries.deinit(self.gpa);
    }

    fn free(self: *Index, e: *Entry) void {
        self.gpa.free(e.strings);
        self.gpa.free(e.symbols);
        self.gpa.destroy(e);
    }

    /// Bring the index up to date with the open documents and the files under
    /// `roots`. `scratch` holds what lives only for this call.
    pub fn refresh(
        self: *Index,
        scratch: Allocator,
        roots: []const Root,
        files: ?workspace.Files,
        opened: []const Open,
        encoding: position.Encoding,
    ) Allocator.Error!void {
        self.generation +%= 1;
        self.truncated = false;
        var open_paths: std.StringHashMapUnmanaged(void) = .empty;
        for (opened) |d| {
            const key = d.path orelse d.uri;
            if (d.path) |p| try open_paths.put(scratch, p, {});
            const stamp: workspace.Files.Stamp = .{ .size = d.text.len, .mtime_ns = @as(u64, @truncate(std.hash.Wyhash.hash(0, d.text))) };
            try self.update(key, d.uri, stamp, encoding, d.text);
        }
        if (files) |fs| if (fs.list != null and fs.stamp != null) {
            var count: usize = 0;
            for (roots) |r| try self.walk(scratch, r, fs, &open_paths, encoding, &count);
        };
        // Whatever no walk or document saw is gone.
        var gone: std.ArrayList([]const u8) = .empty;
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (e.*.seen != self.generation) try gone.append(scratch, e.*.key);
        }
        for (gone.items) |k| {
            const e = self.entries.fetchRemove(k).?.value;
            self.free(e);
        }
    }

    fn walk(
        self: *Index,
        scratch: Allocator,
        root: Root,
        fs: workspace.Files,
        open_paths: *const std.StringHashMapUnmanaged(void),
        encoding: position.Encoding,
        count: *usize,
    ) Allocator.Error!void {
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(scratch, root.path);
        while (stack.pop()) |dir| {
            const listing = fs.list.?(fs.ctx, scratch, dir) orelse continue;
            for (listing) |e| {
                if (e.name.len == 0 or e.name[0] == '.') continue;
                const path = try std.fs.path.resolveAllocPosix(scratch, &.{ dir, e.name });
                switch (e.kind) {
                    .directory => {
                        const skip = for (skipped_dirs) |s| {
                            if (std.mem.eql(u8, s, e.name)) break true;
                        } else false;
                        if (!skip) try stack.append(scratch, path);
                    },
                    .file => {
                        if (!hasExtension(e.name, root.extensions)) continue;
                        if (open_paths.contains(path)) continue;
                        if (self.entries.get(path)) |old| if (old.seen == self.generation) continue; // nested folders
                        if (count.* >= max_files) {
                            self.truncated = true;
                            return;
                        }
                        count.* += 1;
                        const stamp = fs.stamp.?(fs.ctx, path) orelse continue;
                        if (self.entries.get(path)) |old| if (std.meta.eql(old.stamp, stamp) and old.encoding == encoding) {
                            old.seen = self.generation;
                            continue;
                        };
                        // Freed at once: a cold walk reads every file.
                        const text = fs.read(fs.ctx, self.gpa, path) orelse continue;
                        defer self.gpa.free(text);
                        try self.update(path, try uri_mod.fromPath(scratch, path), stamp, encoding, text);
                    },
                }
            }
        }
    }

    /// Index `text` under `key`, unless it is indexed at `stamp` already.
    fn update(self: *Index, key: []const u8, uri: []const u8, stamp: workspace.Files.Stamp, encoding: position.Encoding, text: []const u8) Allocator.Error!void {
        if (self.entries.get(key)) |old| {
            if (std.meta.eql(old.stamp, stamp) and old.encoding == encoding) {
                old.seen = self.generation;
                return;
            }
            _ = self.entries.remove(key);
            self.free(old);
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const found = try self.symbolsOf(scratch.allocator(), text, encoding);

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
        e.encoding = encoding;
        e.seen = self.generation;
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
    fn symbolsOf(self: *Index, a: Allocator, text: []const u8, encoding: position.Encoding) Allocator.Error![]const Symbol {
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
        try flatten(a, &out, outline, null, &index, text, encoding);
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

    // Nothing changed: nothing is parsed again. A changed file is; a removed
    // one goes; an open document wins over its file.
    try idx.refresh(a, &roots, mem.files(), &.{}, .utf8);
    try testing.expectEqual(@as(u64, 2), idx.builds);
    entries[1][1] = "function welcome() end\n";
    entries[0][0] = "/w/gone.txt";
    try idx.refresh(a, &roots, mem.files(), &.{.{ .uri = "file:///w/sub/b.mah", .path = "/w/sub/b.mah", .text = "function edited() end\n" }}, .utf8);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, "add", 10)).len);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, "welcome", 10)).len);
    try testing.expectEqualStrings("edited", (try idx.search(a, "edit", 10))[0].symbol.name);
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
