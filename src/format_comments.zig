//! Doc 83 §5: which comments go with which code, for the formatter.
//!
//! The lexer records each comment's bytes (`lexer.Trivia`). This turns them
//! into answers the document builder asks while it walks the tree in source
//! order: the own-line comments before an item (`takeLeading`), the comment
//! after code on the same line (`takeTrailing`), and whether a blank line
//! separates two points (`gapHasBlank`). A comment is consumed once, by the
//! first caller that reaches it, so none is printed twice; `pendingBefore`
//! lets the builder refuse when a comment it never reached lies behind it
//! (a comment in a position the builder does not place, which would
//! otherwise end up attached to the wrong code).
//!
//! The rule (D4): an own-line comment goes with the next item unless a blank
//! line separates them; a run of comment lines goes as a unit by its last
//! line; a comment after code on the same line stays on that line. "Goes
//! with" here is positional: the builder prints a comment where its item is,
//! with the blank lines the source had, so attached and free-standing
//! comments differ only in whether a blank line follows them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");

pub const Comment = lexer.Comment;

/// One own-line (or inline) comment in front of an item.
pub const Leading = struct {
    comment: Comment,
    /// A blank line lies between the previous point and this comment.
    blank_before: bool,
    /// Code follows on the same line (`--[[ c ]] x`): printed inline, with a
    /// space, not on a line of its own.
    inline_: bool,
};

pub const LeadingRun = struct {
    items: []const Leading,
    /// A blank line lies between the last comment and the item (so the run
    /// is free-standing, not attached). Meaningless when `items` is empty.
    blank_after: bool,
};

pub const Comments = struct {
    source: []const u8,
    list: []const Comment,
    /// Byte offset of each line's start.
    line_starts: []const u32,
    /// Index of the first comment not yet consumed.
    next: usize = 0,

    pub fn init(gpa: Allocator, source: []const u8, list: []const Comment) Allocator.Error!Comments {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        try starts.append(gpa, 0);
        for (source, 0..) |c, i| {
            if (c == '\n') try starts.append(gpa, @intCast(i + 1));
        }
        return .{ .source = source, .list = list, .line_starts = try starts.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *Comments, gpa: Allocator) void {
        gpa.free(self.line_starts);
    }

    /// The 0-based line holding byte `offset`.
    pub fn lineOf(self: *const Comments, offset: u32) u32 {
        // Last line start <= offset.
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= offset) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Is there a blank line (two newlines with only whitespace and `;`
    /// between them) in `source[from..to]`?
    pub fn gapHasBlank(self: *const Comments, from: u32, to: u32) bool {
        if (to <= from) return false;
        var newlines: u32 = 0;
        for (self.source[from..to]) |c| switch (c) {
            '\n' => {
                newlines += 1;
                if (newlines >= 2) return true;
            },
            ' ', '\t', '\r', ';' => {},
            else => newlines = 0,
        };
        return false;
    }

    /// The first comment not consumed, if any.
    pub fn peek(self: *const Comments) ?Comment {
        return if (self.next < self.list.len) self.list[self.next] else null;
    }

    /// Is a comment unconsumed that starts before `pos`? The builder asks
    /// this at the end of a construct: a yes means a comment inside it was
    /// never placed.
    pub fn pendingBefore(self: *const Comments, pos: u32) bool {
        const c = self.peek() orelse return false;
        return c.start < pos;
    }

    pub fn exhausted(self: *const Comments) bool {
        return self.next >= self.list.len;
    }

    /// The text of a comment as printed: a line comment loses its trailing
    /// whitespace (and a `\r`); a block comment is verbatim.
    pub fn text(self: *const Comments, c: Comment) []const u8 {
        const s = self.source[c.start..c.end];
        if (c.block) return s;
        return std.mem.trimEnd(u8, s, " \t\r");
    }

    /// Consume the comments that start before `before`, in order. `prev_end`
    /// is where the previous item (or its trailing comment) ended, for the
    /// blank-line test. Comments are allocated in `a`.
    pub fn takeLeading(self: *Comments, a: Allocator, prev_end: u32, before: u32) Allocator.Error!LeadingRun {
        var out: std.ArrayList(Leading) = .empty;
        var prev = prev_end;
        while (self.next < self.list.len and self.list[self.next].start < before) : (self.next += 1) {
            const c = self.list[self.next];
            const next_start: u32 = if (self.next + 1 < self.list.len and self.list[self.next + 1].start < before)
                self.list[self.next + 1].start
            else
                before;
            try out.append(a, .{
                .comment = c,
                .blank_before = self.gapHasBlank(prev, c.start),
                .inline_ = c.block and self.lineOf(c.end) == self.lineOf(next_start) and !self.gapHasNewline(c.end, next_start),
            });
            prev = c.end;
        }
        const blank_after = out.items.len > 0 and self.gapHasBlank(prev, before);
        return .{ .items = try out.toOwnedSlice(a), .blank_after = blank_after };
    }

    fn gapHasNewline(self: *const Comments, from: u32, to: u32) bool {
        return std.mem.indexOfScalar(u8, self.source[from..to], '\n') != null;
    }

    /// Consume the comments after code that ends at `after`, on the same
    /// line, and return them joined by single spaces (with the leading space
    /// the printer's `lineSuffix` wants), or null. A block comment that
    /// code follows on its line is not trailing (it is the next item's
    /// leading comment, inline).
    pub fn takeTrailing(self: *Comments, a: Allocator, after: u32) Allocator.Error!?[]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const line = self.lineOf(after);
        while (self.next < self.list.len) {
            const c = self.list[self.next];
            if (c.start < after or self.lineOf(c.start) != line) break;
            if (c.block and !self.endsLine(c.end)) break;
            try buf.append(a, ' ');
            try buf.appendSlice(a, self.text(c));
            self.next += 1;
            if (!c.block) break;
        }
        if (buf.items.len == 0) return null;
        return try buf.toOwnedSlice(a);
    }

    /// Only whitespace, then a newline, end of file, or another comment, follows `pos`.
    fn endsLine(self: *const Comments, pos: u32) bool {
        var i: usize = pos;
        while (i < self.source.len) : (i += 1) switch (self.source[i]) {
            ' ', '\t', '\r' => {},
            '\n' => return true,
            '-' => return i + 1 < self.source.len and self.source[i + 1] == '-',
            else => return false,
        };
        return true;
    }
};

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Diagnostics = @import("diag.zig").Diagnostics;

const Fixture = struct {
    trivia: lexer.Trivia,
    comments: Comments,
    a: std.heap.ArenaAllocator,

    fn init(src: [:0]const u8) !Fixture {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        var trivia = lexer.Trivia.init(testing.allocator);
        errdefer trivia.deinit();
        const toks = try lexer.tokenizeTrivia(testing.allocator, src, &diags, &trivia);
        testing.allocator.free(toks);
        return .{
            .trivia = trivia,
            .comments = try Comments.init(testing.allocator, src, trivia.comments.items),
            .a = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(f: *Fixture) void {
        f.a.deinit();
        f.comments.deinit(testing.allocator);
        f.trivia.deinit();
    }
};

fn offsetOf(src: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, src, needle).?);
}

test "comments: a trailing comment is on the code's line, and consumed once" {
    const src = "x = 1 -- one\n-- own\ny = 2\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    const t = (try f.comments.takeTrailing(f.a.allocator(), offsetOf(src, " --"))).?;
    try testing.expectEqualStrings(" -- one", t);
    // The next line's comment is not trailing.
    try testing.expect((try f.comments.takeTrailing(f.a.allocator(), offsetOf(src, " --"))) == null);
    const run = try f.comments.takeLeading(f.a.allocator(), offsetOf(src, "\n"), offsetOf(src, "y"));
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expect(!run.blank_after);
}

test "comments: a blank line makes a run free-standing; runs are attached by their last line" {
    const src = "a()\n-- far\n\n-- near 1\n-- near 2\nb()\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    const run = try f.comments.takeLeading(f.a.allocator(), offsetOf(src, "\n"), offsetOf(src, "b"));
    try testing.expectEqual(@as(usize, 3), run.items.len);
    try testing.expect(!run.items[0].blank_before);
    try testing.expect(run.items[1].blank_before); // blank line after "-- far"
    try testing.expect(!run.items[2].blank_before);
    try testing.expect(!run.blank_after); // "-- near 2" touches b()
}

test "comments: a run followed by a blank line is free-standing" {
    const src = "a()\n-- floating\n\nb()\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    const run = try f.comments.takeLeading(f.a.allocator(), offsetOf(src, "\n"), offsetOf(src, "b"));
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expect(run.blank_after);
}

test "comments: a block comment with code after it on its line is inline, and not trailing" {
    const src = "f(a, --[[ first ]] b)\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expect((try f.comments.takeTrailing(f.a.allocator(), offsetOf(src, ","))) == null);
    // takeTrailing at the comma: the block comment is followed by code, so not taken.
    try testing.expectEqual(@as(usize, 0), f.comments.next);
    const run = try f.comments.takeLeading(f.a.allocator(), offsetOf(src, ","), offsetOf(src, "b"));
    try testing.expectEqual(@as(usize, 1), run.items.len);
    try testing.expect(run.items[0].inline_);
}

test "comments: text trims a line comment's trailing whitespace and keeps a block comment" {
    const src = "-- hi  \t\n--[[ a  \n b ]]\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expectEqualStrings("-- hi", f.comments.text(f.comments.list[0]));
    try testing.expectEqualStrings("--[[ a  \n b ]]", f.comments.text(f.comments.list[1]));
}

test "comments: pendingBefore sees a comment nobody placed" {
    const src = "local x = -- skipped\n  1\nlocal y = 2\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expect(f.comments.pendingBefore(offsetOf(src, "local y")));
    try testing.expect(!f.comments.pendingBefore(offsetOf(src, "x")));
    _ = try f.comments.takeLeading(f.a.allocator(), 0, offsetOf(src, "1"));
    try testing.expect(!f.comments.pendingBefore(offsetOf(src, "local y")));
}

test "comments: lineOf and gapHasBlank" {
    const src = "a\n\n  \nb\nc\n";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expectEqual(@as(u32, 0), f.comments.lineOf(0));
    try testing.expectEqual(@as(u32, 3), f.comments.lineOf(offsetOf(src, "b")));
    try testing.expect(f.comments.gapHasBlank(1, offsetOf(src, "b")));
    try testing.expect(!f.comments.gapHasBlank(offsetOf(src, "b") + 1, offsetOf(src, "c")));
}
