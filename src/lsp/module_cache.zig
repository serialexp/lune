//! The exports of the modules `require` reaches (doc 74 §7.4, P6d), kept per
//! path. Each lookup is checked against the module's text as it is now, so an
//! edit, on disk or in an open document, is never missed: a hit costs the read
//! and a hash, and a module is parsed again only when its text changed.
//! Bounded (§3): past `capacity` paths, the one used longest ago goes.
//!
//! Ranges are in the encoding asked for, which is part of the check.

const std = @import("std");
const diag = @import("../diag.zig");
const parser = @import("../parser.zig");
const resolve = @import("../resolve.zig");
const exports = @import("exports.zig");
const position = @import("position.zig");

const Allocator = std.mem.Allocator;

pub const capacity = 64;

pub const Member = struct {
    name: []const u8,
    kind: exports.Kind,
    signature: ?[]const u8,
    /// The name, in the module's text.
    range: position.Range,
};

pub const Cache = struct {
    gpa: Allocator,
    entries: std.ArrayList(*Entry) = .empty,
    /// Counts lookups; an entry remembers the count of its last use.
    clock: u64 = 0,
    /// Modules analysed so far: what a hit saves, for tests and the benchmark.
    builds: u64 = 0,

    const Entry = struct {
        /// Owns `path` and `members`.
        arena: std.heap.ArenaAllocator,
        path: []const u8,
        hash: u64,
        len: usize,
        encoding: position.Encoding,
        members: []const Member,
        used: u64,
    };

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |e| self.free(e);
        self.entries.deinit(self.gpa);
    }

    fn free(self: *Cache, e: *Entry) void {
        e.arena.deinit();
        self.gpa.destroy(e);
    }

    /// The members of the module at `path`, whose text is `text`. Valid until
    /// the next call.
    pub fn get(self: *Cache, path: []const u8, text: []const u8, encoding: position.Encoding) Allocator.Error![]const Member {
        self.clock += 1;
        const hash = std.hash.Wyhash.hash(0, text);
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (e.hash == hash and e.len == text.len and e.encoding == encoding) {
                e.used = self.clock;
                return e.members;
            }
            self.free(e);
            _ = self.entries.swapRemove(i);
            break;
        }
        if (self.entries.items.len >= capacity) self.evict();

        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        e.arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer e.arena.deinit();
        const a = e.arena.allocator();
        e.path = try a.dupe(u8, path);
        e.hash = hash;
        e.len = text.len;
        e.encoding = encoding;
        e.used = self.clock;
        e.members = try self.build(a, text, encoding);
        try self.entries.append(self.gpa, e);
        return e.members;
    }

    /// Forget `path`, whatever its text (a file the host says is gone).
    pub fn remove(self: *Cache, path: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            self.free(e);
            _ = self.entries.swapRemove(i);
            return;
        }
    }

    fn evict(self: *Cache) void {
        var oldest: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (e.used < self.entries.items[oldest].used) oldest = i;
        }
        self.free(self.entries.items[oldest]);
        _ = self.entries.swapRemove(oldest);
    }

    /// Parse and resolve `text` (no compile check: exports need only names),
    /// and keep its exports in `a`.
    fn build(self: *Cache, a: Allocator, text: []const u8, encoding: position.Encoding) Allocator.Error![]const Member {
        self.builds += 1;
        const source = try self.gpa.dupeSentinel(u8, text, 0);
        defer self.gpa.free(source);
        var diags = diag.Diagnostics.init(self.gpa);
        defer diags.deinit();
        var tree = parser.parse(self.gpa, source, &diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // The parser recovers; it has no path that gives up.
            error.ParseError => return &.{},
        };
        defer tree.deinit();
        var res = try resolve.resolve(self.gpa, tree.root, @intCast(source.len));
        defer res.deinit();
        const list = try exports.of(a, tree.root, &res);

        var index = position.LineIndex.build(self.gpa, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TextTooLong => return &.{},
        };
        defer index.deinit(self.gpa);
        const members = try a.alloc(Member, list.len);
        for (list, members) |x, *slot| slot.* = .{
            .name = x.name,
            .kind = x.kind,
            .signature = x.signature,
            .range = index.toRange(text, x.span.start, x.span.end, encoding),
        };
        return members;
    }
};

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

test "module cache: a hit until the text or the encoding changes" {
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    const v1 = "local M = {}\nfunction M.f(a) end\nreturn M";
    const got = try cache.get("/m.mah", v1, .utf16);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("f(a)", got[0].signature.?);
    try testing.expectEqual(position.Range{ .start = .{ .line = 1, .character = 11 }, .end = .{ .line = 1, .character = 12 } }, got[0].range);

    _ = try cache.get("/m.mah", v1, .utf16);
    try testing.expectEqual(@as(u64, 1), cache.builds);
    // The same path with new text, or in another encoding, is built again.
    const v2 = "local M = {}\nfunction M.g() end\nreturn M";
    try testing.expectEqualStrings("g", (try cache.get("/m.mah", v2, .utf16))[0].name);
    _ = try cache.get("/m.mah", v2, .utf8);
    try testing.expectEqual(@as(u64, 3), cache.builds);
    try testing.expectEqual(@as(usize, 1), cache.entries.items.len);

    cache.remove("/m.mah");
    _ = try cache.get("/m.mah", v2, .utf8);
    try testing.expectEqual(@as(u64, 4), cache.builds);
}

test "module cache: bounded, and the path used longest ago goes first" {
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    var buf: [32]u8 = undefined;
    for (0..capacity) |i| _ = try cache.get(try std.fmt.bufPrint(&buf, "/m{d}", .{i}), "return {}", .utf8);
    // Touch the first, then add one more: the second is the one evicted.
    _ = try cache.get("/m0", "return {}", .utf8);
    _ = try cache.get("/extra", "return {}", .utf8);
    try testing.expectEqual(@as(usize, capacity), cache.entries.items.len);
    const before = cache.builds;
    _ = try cache.get("/m0", "return {}", .utf8);
    try testing.expectEqual(before, cache.builds);
    _ = try cache.get("/m1", "return {}", .utf8);
    try testing.expectEqual(before + 1, cache.builds);
}
