//! Byte offsets <-> LSP positions (doc 74 §5.3).
//!
//! The compiler and parser speak byte offsets (`ast.Span`); LSP speaks
//! `(line, character)` with `character` counted in the *negotiated* unit:
//! UTF-8 bytes, or UTF-16 code units (a character outside the BMP is 2).
//! This module is the only place that converts, and it is pure: no I/O, no
//! JSON, nothing the wasm host cannot compile.
//!
//! Line breaks here are LSP's: `\n`, `\r\n` and a bare `\r`. They are NOT the
//! compiler's `LineTable` (`\n\r` is one break there, Lua's `inclinenumber`);
//! the two indexes answer different questions and must not be shared.
//!
//! Cost model (Rule 20): building the index is linear in the text. A single
//! conversion is O(line length) for short lines and O(log n + checkpoint
//! gap) for lines over `long_line` bytes (sparse checkpoints, one every
//! `checkpoint_gap` bytes). A sorted batch of conversions (semantic tokens,
//! a diagnostic list) goes through a `Cursor` and costs one pass in total.

const std = @import("std");

/// How `character` is counted.
pub const Encoding = enum { utf8, utf16 };

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

/// A line longer than this gets checkpoints so a random conversion on it does
/// not rescan the whole line.
const long_line: u32 = 1024;
/// Distance between checkpoints on a long line, in bytes.
const checkpoint_gap: u32 = 1024;

/// A point inside a long line whose UTF-16 column is already known. Entries are
/// strictly increasing in `(line, offset)` and in `(line, utf16_col)`.
const Checkpoint = struct {
    line: u32,
    /// Byte offset into the text (a code point boundary).
    offset: u32,
    /// UTF-16 column of `offset` within its line.
    utf16_col: u32,
};

/// Byte length and UTF-16 length of the code point starting at `text[i]`,
/// clamped to the text and tolerant of invalid UTF-8 (a stray byte is one
/// byte and one unit). `i` must be < `text.len`.
inline fn codePoint(text: []const u8, i: usize) struct { bytes: u32, units: u32 } {
    const b = text[i];
    var n: u32 = 1;
    var units: u32 = 1;
    if (b >= 0xF0 and b < 0xF8) {
        n = 4;
        units = 2;
    } else if (b >= 0xE0 and b < 0xF0) {
        n = 3;
    } else if (b >= 0xC0 and b < 0xE0) {
        n = 2;
    }
    const left: u32 = @intCast(@min(text.len - i, std.math.maxInt(u32)));
    if (n > left) {
        n = left;
        units = 1;
    }
    return .{ .bytes = n, .units = units };
}

pub const LineIndex = struct {
    /// `starts[k]` is the byte offset of line `k`; `starts[0] == 0`.
    starts: []u32,
    /// Checkpoints on lines longer than `long_line`.
    checkpoints: []Checkpoint,
    /// Length of the indexed text, for clamping.
    len: u32,

    pub const Error = std.mem.Allocator.Error || error{TextTooLong};

    pub fn build(gpa: std.mem.Allocator, text: []const u8) Error!LineIndex {
        if (text.len > std.math.maxInt(u32)) return error.TextTooLong;

        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        var cps: std.ArrayList(Checkpoint) = .empty;
        errdefer cps.deinit(gpa);
        try starts.append(gpa, 0);

        // Line breaks are found by a bulk search; a line is decoded code point
        // by code point only when it is long enough to need checkpoints, so
        // building the index of ordinary source is a scan for `\n`/`\r`.
        var line_start: usize = 0;
        while (true) {
            const brk = std.mem.findAnyPos(u8, text, line_start, "\r\n");
            const line_end = brk orelse text.len;
            if (line_end - line_start > long_line) {
                try addCheckpoints(gpa, &cps, text, line_start, line_end, @intCast(starts.items.len - 1));
            }
            const b = brk orelse break;
            var next = b + 1;
            if (text[b] == '\r' and next < text.len and text[next] == '\n') next += 1;
            try starts.append(gpa, @intCast(next));
            line_start = next;
        }

        const s = try starts.toOwnedSlice(gpa);
        errdefer gpa.free(s);
        const c = try cps.toOwnedSlice(gpa);
        return .{ .starts = s, .checkpoints = c, .len = @intCast(text.len) };
    }

    /// Checkpoints for one long line `[line_start, line_end)`: one every
    /// `checkpoint_gap` bytes, at a code point boundary, with its UTF-16 column.
    fn addCheckpoints(
        gpa: std.mem.Allocator,
        cps: *std.ArrayList(Checkpoint),
        text: []const u8,
        line_start: usize,
        line_end: usize,
        line: u32,
    ) std.mem.Allocator.Error!void {
        var i = line_start;
        var col: u32 = 0;
        var next = line_start + checkpoint_gap;
        while (i < line_end) {
            if (i >= next) {
                try cps.append(gpa, .{ .line = line, .offset = @intCast(i), .utf16_col = col });
                next = i + checkpoint_gap;
            }
            const cp = codePoint(text, i);
            col += cp.units;
            i += cp.bytes;
        }
    }

    pub fn deinit(self: LineIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.starts);
        gpa.free(self.checkpoints);
    }

    pub fn lineCount(self: LineIndex) u32 {
        return @intCast(self.starts.len);
    }

    /// The line containing byte `offset` (clamped to the text).
    pub fn lineOf(self: LineIndex, offset: u32) u32 {
        const off = @min(offset, self.len);
        // Last start <= off.
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= off) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// First byte of `line`; the text length for a line past the end.
    pub fn lineStart(self: LineIndex, line: u32) u32 {
        if (line >= self.starts.len) return self.len;
        return self.starts[line];
    }

    /// One past the last content byte of `line` (before its terminator).
    pub fn lineEnd(self: LineIndex, text: []const u8, line: u32) u32 {
        if (line >= self.starts.len) return self.len;
        if (line + 1 == self.starts.len) return self.len;
        var e = self.starts[line + 1];
        if (e > 0 and text[e - 1] == '\n') e -= 1;
        if (e > self.starts[line] and text[e - 1] == '\r') e -= 1;
        return e;
    }

    /// The last checkpoint at or before `(line, offset)`, if any.
    fn checkpointAtOrBefore(self: LineIndex, line: u32, offset: u32) ?Checkpoint {
        var lo: usize = 0;
        var hi: usize = self.checkpoints.len;
        // First checkpoint strictly after (line, offset).
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.checkpoints[mid];
            if (c.line < line or (c.line == line and c.offset <= offset)) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const c = self.checkpoints[lo - 1];
        return if (c.line == line) c else null;
    }

    /// The last checkpoint on `line` whose UTF-16 column is <= `col`.
    fn checkpointAtOrBeforeCol(self: LineIndex, line: u32, col: u32) ?Checkpoint {
        var lo: usize = 0;
        var hi: usize = self.checkpoints.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.checkpoints[mid];
            if (c.line < line or (c.line == line and c.utf16_col <= col)) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const c = self.checkpoints[lo - 1];
        return if (c.line == line) c else null;
    }

    /// The position of byte `offset`. An offset past the end clamps to the end;
    /// one inside a line terminator clamps to the end of its line; one inside a
    /// multi-byte character rounds down to the character's start.
    pub fn toPosition(self: LineIndex, text: []const u8, offset: u32, enc: Encoding) Position {
        const line = self.lineOf(offset);
        const end = self.lineEnd(text, line);
        const off = @min(@min(offset, self.len), end);
        const start = self.starts[line];
        if (enc == .utf8) return .{ .line = line, .character = off - start };

        var pos: u32 = start;
        var col: u32 = 0;
        if (self.checkpointAtOrBefore(line, off)) |c| {
            pos = c.offset;
            col = c.utf16_col;
        }
        while (pos < off) {
            const cp = codePoint(text, pos);
            if (pos + cp.bytes > off) break; // `off` is inside this character
            col += cp.units;
            pos += cp.bytes;
        }
        return .{ .line = line, .character = col };
    }

    /// The byte offset of `pos`. A line past the end clamps to the text end; a
    /// character past the end of its line clamps to the line's end; one that
    /// points inside a surrogate pair rounds down to the character's start.
    pub fn toOffset(self: LineIndex, text: []const u8, pos: Position, enc: Encoding) u32 {
        if (pos.line >= self.starts.len) return self.len;
        const start = self.starts[pos.line];
        const end = self.lineEnd(text, pos.line);
        if (enc == .utf8) return start + @min(pos.character, end - start);

        var at: u32 = start;
        var col: u32 = 0;
        if (self.checkpointAtOrBeforeCol(pos.line, pos.character)) |c| {
            at = c.offset;
            col = c.utf16_col;
        }
        while (at < end and col < pos.character) {
            const cp = codePoint(text, at);
            if (col + cp.units > pos.character) break; // inside a surrogate pair
            col += cp.units;
            at += cp.bytes;
        }
        return at;
    }

    pub fn toRange(self: LineIndex, text: []const u8, start: u32, end: u32, enc: Encoding) Range {
        return .{
            .start = self.toPosition(text, start, enc),
            .end = self.toPosition(text, end, enc),
        };
    }
};

/// Converts a non-decreasing sequence of byte offsets to positions in one
/// pass over the text, however long a line is. An offset smaller than the
/// previous one is searched for (correct, just not O(1)).
pub const Cursor = struct {
    index: *const LineIndex,
    text: []const u8,
    enc: Encoding,
    line: u32 = 0,
    /// Byte offset the scan has reached, and its column on `line`.
    pos: u32 = 0,
    col: u32 = 0,

    pub fn init(index: *const LineIndex, text: []const u8, enc: Encoding) Cursor {
        return .{ .index = index, .text = text, .enc = enc };
    }

    pub fn positionOf(self: *Cursor, offset: u32) Position {
        const idx = self.index;
        const want = @min(offset, idx.len);
        // Behind the scan: search for the line.
        if (want < self.pos) {
            self.line = idx.lineOf(want);
            self.pos = idx.starts[self.line];
            self.col = 0;
        }
        // Ahead of it: step over the whole lines in between. Each line is passed
        // once over the cursor's life, so a sorted batch costs no search at all.
        while (self.line + 1 < idx.lineCount() and want >= idx.lineStart(self.line + 1)) {
            self.line += 1;
            self.pos = idx.starts[self.line];
            self.col = 0;
        }
        const end = idx.lineEnd(self.text, self.line);
        const off = @min(want, end);
        if (self.enc == .utf8) return .{ .line = self.line, .character = off - idx.starts[self.line] };

        while (self.pos < off) {
            const cp = codePoint(self.text, self.pos);
            if (self.pos + cp.bytes > off) break;
            self.col += cp.units;
            self.pos += cp.bytes;
        }
        return .{ .line = self.line, .character = self.col };
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn buildIndex(text: []const u8) !LineIndex {
    return LineIndex.build(testing.allocator, text);
}

test "lines: LF, CRLF, bare CR, and the compiler-only LFCR" {
    const text = "a\nb\r\nc\rd\n\re";
    const ix = try buildIndex(text);
    defer ix.deinit(testing.allocator);
    // a | b | c | d | (empty, from the lone \n before \r) | e  -- LFCR is two breaks for LSP
    try testing.expectEqual(@as(u32, 6), ix.lineCount());
    try testing.expectEqual(@as(u32, 0), ix.lineOf(0));
    try testing.expectEqual(@as(u32, 1), ix.lineOf(2));
    try testing.expectEqual(@as(u32, 2), ix.lineOf(5));
    try testing.expectEqual(@as(u32, 3), ix.lineOf(7));
    try testing.expectEqual(@as(u32, 5), ix.lineOf(text.len - 1));
    // Line ends exclude the terminator, including a two-byte CRLF.
    try testing.expectEqual(@as(u32, 1), ix.lineEnd(text, 0));
    try testing.expectEqual(@as(u32, 3), ix.lineEnd(text, 1));
    try testing.expectEqual(@as(u32, text.len), ix.lineEnd(text, 5));
}

test "empty text and a missing final newline" {
    const e = try buildIndex("");
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), e.lineCount());
    try testing.expectEqual(Position{ .line = 0, .character = 0 }, e.toPosition("", 0, .utf16));
    try testing.expectEqual(@as(u32, 0), e.toOffset("", .{ .line = 3, .character = 9 }, .utf16));

    const t = "ab\ncd";
    const ix = try buildIndex(t);
    defer ix.deinit(testing.allocator);
    try testing.expectEqual(Position{ .line = 1, .character = 2 }, ix.toPosition(t, 5, .utf16));
    // A trailing newline makes a final empty line.
    const t2 = "ab\n";
    const ix2 = try buildIndex(t2);
    defer ix2.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), ix2.lineCount());
    try testing.expectEqual(Position{ .line = 1, .character = 0 }, ix2.toPosition(t2, 3, .utf16));
}

test "utf-16 counts code units: BMP is 1, astral is 2; utf-8 counts bytes" {
    // "a" (1B) "é" (2B, 1u) "€" (3B, 1u) "😀" (4B, 2u) "b"
    const t = "a\u{e9}\u{20ac}\u{1f600}b";
    const ix = try buildIndex(t);
    defer ix.deinit(testing.allocator);
    // Byte offsets of each character: 0, 1, 3, 6, 10; end 11.
    try testing.expectEqual(@as(u32, 0), ix.toPosition(t, 0, .utf16).character);
    try testing.expectEqual(@as(u32, 1), ix.toPosition(t, 1, .utf16).character);
    try testing.expectEqual(@as(u32, 2), ix.toPosition(t, 3, .utf16).character);
    try testing.expectEqual(@as(u32, 3), ix.toPosition(t, 6, .utf16).character);
    try testing.expectEqual(@as(u32, 5), ix.toPosition(t, 10, .utf16).character);
    try testing.expectEqual(@as(u32, 6), ix.toPosition(t, 11, .utf16).character);
    try testing.expectEqual(@as(u32, 10), ix.toPosition(t, 10, .utf8).character);
    // Round trip at every character boundary, both encodings.
    for ([_]u32{ 0, 1, 3, 6, 10, 11 }) |off| {
        inline for (.{ Encoding.utf8, Encoding.utf16 }) |enc| {
            try testing.expectEqual(off, ix.toOffset(t, ix.toPosition(t, off, enc), enc));
        }
    }
    // Inside a surrogate pair (character 4) rounds down to the emoji's start.
    try testing.expectEqual(@as(u32, 6), ix.toOffset(t, .{ .line = 0, .character = 4 }, .utf16));
    // An offset inside a multi-byte character rounds down too.
    try testing.expectEqual(@as(u32, 2), ix.toPosition(t, 4, .utf16).character);
}

test "clamping: past the line, past the document, inside a CRLF" {
    const t = "ab\r\ncd";
    const ix = try buildIndex(t);
    defer ix.deinit(testing.allocator);
    // Character past the end of line 0 clamps to the line end, not into the CRLF.
    try testing.expectEqual(@as(u32, 2), ix.toOffset(t, .{ .line = 0, .character = 99 }, .utf16));
    try testing.expectEqual(@as(u32, 2), ix.toOffset(t, .{ .line = 0, .character = 99 }, .utf8));
    // Line past the end is the end of the text.
    try testing.expectEqual(@as(u32, 6), ix.toOffset(t, .{ .line = 9, .character = 0 }, .utf16));
    // An offset between the \r and the \n sits at the end of line 0.
    try testing.expectEqual(Position{ .line = 0, .character = 2 }, ix.toPosition(t, 3, .utf16));
    // An offset past the end clamps.
    try testing.expectEqual(Position{ .line = 1, .character = 2 }, ix.toPosition(t, 999, .utf16));
}

test "invalid and truncated UTF-8 count as single units" {
    const t = "a\xffb\xe2\x82"; // stray 0xff, then a 3-byte lead cut short
    const ix = try buildIndex(t);
    defer ix.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), ix.toPosition(t, 2, .utf16).character);
    // The truncated tail is one unit and does not read past the text.
    try testing.expectEqual(@as(u32, 4), ix.toPosition(t, t.len, .utf16).character);
}

/// A line of `n` astral characters, so a UTF-16 column is twice the count.
fn astralLine(n: usize) ![]u8 {
    const out = try testing.allocator.alloc(u8, n * 4);
    for (0..n) |k| @memcpy(out[k * 4 ..][0..4], "\u{1f600}");
    return out;
}

test "a long line gets checkpoints and agrees with the plain scan" {
    const n = 5000; // 20 KB on one line
    const line = try astralLine(n);
    defer testing.allocator.free(line);
    const t = try std.fmt.allocPrint(testing.allocator, "x\n{s}\ny", .{line});
    defer testing.allocator.free(t);
    const ix = try buildIndex(t);
    defer ix.deinit(testing.allocator);
    try testing.expect(ix.checkpoints.len >= 10);
    // Checkpoints are strictly increasing in both coordinates.
    for (ix.checkpoints[1..], 0..) |c, k| {
        try testing.expect(c.offset > ix.checkpoints[k].offset);
        try testing.expect(c.utf16_col > ix.checkpoints[k].utf16_col);
    }
    for ([_]usize{ 0, 1, 255, 256, 257, 2500, 4999, 5000 }) |k| {
        const off: u32 = @intCast(2 + k * 4);
        const p = ix.toPosition(t, off, .utf16);
        try testing.expectEqual(@as(u32, 1), p.line);
        try testing.expectEqual(@as(u32, @intCast(k * 2)), p.character);
        try testing.expectEqual(off, ix.toOffset(t, p, .utf16));
    }
}

test "cursor: a sorted batch matches independent conversions across lines and encodings" {
    const line = try astralLine(3000);
    defer testing.allocator.free(line);
    const t = try std.fmt.allocPrint(testing.allocator, "ab\n{s}\r\n\u{e9}z\nlast", .{line});
    defer testing.allocator.free(t);
    const ix = try buildIndex(t);
    defer ix.deinit(testing.allocator);
    inline for (.{ Encoding.utf8, Encoding.utf16 }) |enc| {
        var cur = Cursor.init(&ix, t, enc);
        var off: u32 = 0;
        while (off <= t.len) : (off += 7) {
            try testing.expectEqual(ix.toPosition(t, off, enc), cur.positionOf(off));
        }
        // Going backwards restarts and is still right.
        try testing.expectEqual(ix.toPosition(t, 1, enc), cur.positionOf(1));
        try testing.expectEqual(ix.toPosition(t, @intCast(t.len), enc), cur.positionOf(@intCast(t.len)));
    }
}
