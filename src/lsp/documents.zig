//! The open-document store (doc 74 §5.3).
//!
//! Text is one contiguous buffer per document, edited in place by range
//! splices; the line index is rebuilt lazily after an edit (a bulk scan for
//! line breaks, see `position.zig`) and only when a position has to be
//! converted. Every analysis re-parses the whole text.

const std = @import("std");
const position = @import("position.zig");
const analysis_mod = @import("analysis.zig");

pub const Document = struct {
    /// Owned.
    uri: []u8,
    version: i64,
    text: std.ArrayList(u8) = .empty,
    /// Built on demand; dropped by every edit.
    index: ?position.LineIndex = null,

    /// Monotonic milliseconds of the first change since the last analysis, and
    /// of the most recent one; null while the published diagnostics are
    /// current. The server's debounce reads these.
    dirty_since: ?u64 = null,
    last_change: u64 = 0,

    /// The latest finished analysis and the document version it was made
    /// from. Features read it only while `analysed_version == version`; an
    /// edit leaves it in place (stale) until the next analysis replaces it.
    analysis: ?analysis_mod.Analysis = null,
    analysed_version: i64 = -1,

    pub const Error = std.mem.Allocator.Error || error{TextTooLong};

    pub fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        if (self.analysis) |*a| a.deinit();
        if (self.index) |ix| ix.deinit(gpa);
        self.text.deinit(gpa);
        gpa.free(self.uri);
    }

    /// Keep `result`, made from the current text, in place of the previous one.
    pub fn setAnalysis(self: *Document, result: analysis_mod.Analysis) void {
        if (self.analysis) |*old| old.deinit();
        self.analysis = result;
        self.analysed_version = self.version;
    }

    /// The analysis, if it is of the text as it is now.
    pub fn currentAnalysis(self: *const Document) ?*const analysis_mod.Analysis {
        if (self.analysed_version != self.version) return null;
        return if (self.analysis) |*a| a else null;
    }

    pub fn source(self: *const Document) []const u8 {
        return self.text.items;
    }

    /// The line index of the current text, building it if an edit dropped it.
    pub fn lineIndex(self: *Document, gpa: std.mem.Allocator) Error!*const position.LineIndex {
        if (self.index == null) self.index = try position.LineIndex.build(gpa, self.text.items);
        return &self.index.?;
    }

    fn dropIndex(self: *Document, gpa: std.mem.Allocator) void {
        if (self.index) |ix| ix.deinit(gpa);
        self.index = null;
    }

    /// Replace the whole text. The analysis of the old text is no longer
    /// current, whatever the version says: a re-open may repeat a version.
    pub fn setText(self: *Document, gpa: std.mem.Allocator, new_text: []const u8) Error!void {
        if (new_text.len > std.math.maxInt(u32)) return error.TextTooLong;
        self.analysed_version = -1;
        self.dropIndex(gpa);
        try self.text.replaceRange(gpa, 0, self.text.items.len, new_text);
    }

    /// Apply one content change. `range == null` replaces everything. A range
    /// that ends before it starts is applied with its ends swapped; positions
    /// past the document clamp (the client's view of the text can be a version
    /// behind, and a clamped edit beats a dropped one).
    pub fn applyChange(
        self: *Document,
        gpa: std.mem.Allocator,
        enc: position.Encoding,
        range: ?position.Range,
        new_text: []const u8,
    ) Error!void {
        const r = range orelse return self.setText(gpa, new_text);
        const ix = try self.lineIndex(gpa);
        var a = ix.toOffset(self.text.items, r.start, enc);
        var b = ix.toOffset(self.text.items, r.end, enc);
        if (b < a) std.mem.swap(u32, &a, &b);
        const new_len = self.text.items.len - (b - a) + new_text.len;
        if (new_len > std.math.maxInt(u32)) return error.TextTooLong;
        self.analysed_version = -1; // the analysis is of the text before this edit
        self.dropIndex(gpa); // `ix` is stale from here
        try self.text.replaceRange(gpa, a, b - a, new_text);
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(*Document) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.valueIterator();
        while (it.next()) |d| {
            d.*.deinit(self.gpa);
            self.gpa.destroy(d.*);
        }
        self.map.deinit(self.gpa);
    }

    pub fn get(self: *const Store, uri: []const u8) ?*Document {
        return self.map.get(uri);
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    /// Open (or re-open: the client's copy wins) a document.
    pub fn open(self: *Store, uri: []const u8, version: i64, text: []const u8) Document.Error!*Document {
        if (self.map.get(uri)) |d| {
            d.version = version;
            try d.setText(self.gpa, text);
            return d;
        }
        const d = try self.gpa.create(Document);
        errdefer self.gpa.destroy(d);
        const key = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(key);
        d.* = .{ .uri = key, .version = version };
        errdefer d.text.deinit(self.gpa);
        try d.setText(self.gpa, text);
        try self.map.put(self.gpa, key, d);
        return d;
    }

    pub fn close(self: *Store, uri: []const u8) void {
        const kv = self.map.fetchRemove(uri) orelse return;
        kv.value.deinit(self.gpa);
        self.gpa.destroy(kv.value);
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn pos(l: u32, c: u32) position.Position {
    return .{ .line = l, .character = c };
}

test "store: open, re-open, close; no leaks" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const d = try s.open("file:///a", 1, "one");
    try testing.expectEqualStrings("one", d.source());
    const d2 = try s.open("file:///a", 5, "two");
    try testing.expect(d == d2);
    try testing.expectEqual(@as(i64, 5), d.version);
    try testing.expectEqualStrings("two", d.source());
    _ = try s.open("file:///b", 1, "");
    try testing.expectEqual(@as(usize, 2), s.count());
    s.close("file:///a");
    s.close("file:///missing");
    try testing.expect(s.get("file:///a") == null);
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "edits: insert, delete, replace, multi-line, and whole-text" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const d = try s.open("u", 1, "hello\nworld\n");
    // Insert at a point.
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(0, 5), .end = pos(0, 5) }, ",");
    try testing.expectEqualStrings("hello,\nworld\n", d.source());
    // Replace across a line break.
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(0, 4), .end = pos(1, 1) }, "O W");
    try testing.expectEqualStrings("hellO World\n", d.source());
    // Delete.
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(0, 0), .end = pos(0, 5) }, "");
    try testing.expectEqualStrings(" World\n", d.source());
    // Whole-text replacement (no range).
    try d.applyChange(testing.allocator, .utf16, null, "x");
    try testing.expectEqualStrings("x", d.source());
}

test "edits: columns follow the negotiated encoding" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    // "😀" is 2 UTF-16 units, 4 bytes.
    const d = try s.open("u", 1, "\u{1f600}b");
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(0, 2), .end = pos(0, 3) }, "B");
    try testing.expectEqualStrings("\u{1f600}B", d.source());
    const e = try s.open("v", 1, "\u{1f600}b");
    try e.applyChange(testing.allocator, .utf8, .{ .start = pos(0, 4), .end = pos(0, 5) }, "B");
    try testing.expectEqualStrings("\u{1f600}B", e.source());
}

test "edits: a stale or backwards range is clamped, not dropped or crashing" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const d = try s.open("u", 1, "abc");
    // Past the end of the document: appends.
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(9, 9), .end = pos(9, 9) }, "!");
    try testing.expectEqualStrings("abc!", d.source());
    // End before start: swapped.
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(0, 3), .end = pos(0, 1) }, "-");
    try testing.expectEqualStrings("a-!", d.source());
}

test "a re-open with the same version and new text drops the old analysis" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const d = try s.open("u", 1, "local a = 1");
    const an = try analysis_mod.analyse(testing.allocator, d.source(), &.{}, .{});
    d.setAnalysis(an);
    try testing.expect(d.currentAnalysis() != null);
    _ = try s.open("u", 1, "local b = 2");
    try testing.expect(d.currentAnalysis() == null);
}

test "line index is rebuilt after an edit, not served stale" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    const d = try s.open("u", 1, "a\nb");
    try testing.expectEqual(@as(u32, 2), (try d.lineIndex(testing.allocator)).lineCount());
    try d.applyChange(testing.allocator, .utf16, .{ .start = pos(0, 1), .end = pos(0, 1) }, "\n\n");
    try testing.expectEqual(@as(u32, 4), (try d.lineIndex(testing.allocator)).lineCount());
}
