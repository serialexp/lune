//! Line editing for the REPL (doc 75 §6): a key decoder, an editing buffer, a
//! history, and a one-line renderer. Everything here is pure: bytes in, bytes
//! out, no terminal and no `std.Io`, so the editor is tested without a tty.
//! The terminal itself (raw mode, window size, reading) lives in `repl.zig`.
//!
//! The editor is single-line. A line longer than the window scrolls
//! horizontally. Width is counted in code points, so double-width characters
//! shift the cursor; combining marks do too. Good enough to type Lua and shell
//! commands; a width table would fix it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Key = union(enum) {
    /// A printable code point to insert.
    char: u21,
    enter,
    /// Ctrl-D: end of input on an empty line, delete under the cursor otherwise.
    ctrl_d,
    /// Ctrl-C: abandon the line.
    interrupt,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    word_left,
    word_right,
    kill_end,
    kill_start,
    kill_word,
    /// Ctrl-L: clear the screen and redraw.
    clear,
    tab,
};

/// Turns terminal bytes into keys. One byte in, at most one key out; an escape
/// sequence or a multi-byte character yields its key on the last byte.
pub const Decoder = struct {
    state: enum { ground, utf8, esc, csi, ss3 } = .ground,
    cp: u21 = 0,
    left_bytes: u3 = 0,
    params: [16]u8 = undefined,
    params_len: u8 = 0,

    pub fn feed(self: *Decoder, byte: u8) ?Key {
        switch (self.state) {
            .ground => return self.ground(byte),
            .utf8 => {
                if (byte & 0xc0 != 0x80) {
                    // A broken sequence: drop it and read this byte afresh.
                    self.state = .ground;
                    return self.ground(byte);
                }
                self.cp = (self.cp << 6) | (byte & 0x3f);
                self.left_bytes -= 1;
                if (self.left_bytes != 0) return null;
                self.state = .ground;
                return if (std.unicode.utf8ValidCodepoint(self.cp)) .{ .char = self.cp } else null;
            },
            .esc => {
                self.state = .ground;
                switch (byte) {
                    '[' => {
                        self.state = .csi;
                        self.params_len = 0;
                        return null;
                    },
                    'O' => {
                        self.state = .ss3;
                        return null;
                    },
                    'b' => return .word_left,
                    'f' => return .word_right,
                    0x7f, 0x08 => return .kill_word,
                    else => return null,
                }
            },
            .ss3 => {
                self.state = .ground;
                return switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => null,
                };
            },
            .csi => {
                if (byte >= 0x30 and byte <= 0x3f) {
                    if (self.params_len < self.params.len) {
                        self.params[self.params_len] = byte;
                        self.params_len += 1;
                    }
                    return null;
                }
                if (byte >= 0x20 and byte <= 0x2f) return null; // intermediates
                self.state = .ground;
                const p = self.params[0..self.params_len];
                const modified = std.mem.indexOfScalar(u8, p, ';') != null;
                return switch (byte) {
                    'A' => .up,
                    'B' => .down,
                    'C' => if (modified) .word_right else .right,
                    'D' => if (modified) .word_left else .left,
                    'H' => .home,
                    'F' => .end,
                    '~' => if (std.mem.eql(u8, p, "1") or std.mem.eql(u8, p, "7"))
                        .home
                    else if (std.mem.eql(u8, p, "4") or std.mem.eql(u8, p, "8"))
                        .end
                    else if (std.mem.eql(u8, p, "3"))
                        .delete
                    else
                        null,
                    else => null,
                };
            },
        }
    }

    fn ground(self: *Decoder, byte: u8) ?Key {
        switch (byte) {
            0x01 => return .home,
            0x02 => return .left,
            0x03 => return .interrupt,
            0x04 => return .ctrl_d,
            0x05 => return .end,
            0x06 => return .right,
            0x08, 0x7f => return .backspace,
            0x09 => return .tab,
            0x0a, 0x0d => return .enter,
            0x0b => return .kill_end,
            0x0c => return .clear,
            0x0e => return .down,
            0x10 => return .up,
            0x15 => return .kill_start,
            0x17 => return .kill_word,
            0x1b => {
                self.state = .esc;
                return null;
            },
            0x20...0x7e => return .{ .char = byte },
            0xc2...0xdf => return self.lead(byte & 0x1f, 1),
            0xe0...0xef => return self.lead(byte & 0x0f, 2),
            0xf0...0xf4 => return self.lead(byte & 0x07, 3),
            else => return null,
        }
    }

    fn lead(self: *Decoder, bits: u8, follow: u3) ?Key {
        self.state = .utf8;
        self.cp = bits;
        self.left_bytes = follow;
        return null;
    }
};

/// The lines typed before, oldest first.
pub const History = struct {
    gpa: Allocator,
    items: std.ArrayList([]u8) = .empty,
    max: usize = 1000,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |s| self.gpa.free(s);
        self.items.deinit(self.gpa);
    }

    /// Remember a submitted line. A blank line, or one equal to the last, is
    /// not kept.
    pub fn add(self: *History, line: []const u8) Allocator.Error!void {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], line)) return;
        const copy = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(copy);
        try self.items.append(self.gpa, copy);
        if (self.items.items.len > self.max) {
            self.gpa.free(self.items.orderedRemove(0));
        }
    }

    /// Read a history file's text: one line per entry.
    pub fn load(self: *History, text: []const u8) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try self.add(std.mem.trimEnd(u8, l, "\r"));
    }

    pub fn write(self: *const History, w: *Writer) Writer.Error!void {
        for (self.items.items) |s| {
            try w.writeAll(s);
            try w.writeByte('\n');
        }
    }
};

pub const Status = enum { editing, submitted, eof, interrupted };

/// One line being edited.
pub const Editor = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor, always on a code point boundary.
    cursor: usize = 0,
    /// The history entry on screen, or null for the line being typed.
    nav: ?usize = null,
    /// The line being typed, set aside while a history entry is on screen.
    saved: ?[]u8 = null,

    pub fn init(gpa: Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.gpa);
        if (self.saved) |s| self.gpa.free(s);
    }

    /// Start a fresh line.
    pub fn reset(self: *Editor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.nav = null;
        if (self.saved) |s| self.gpa.free(s);
        self.saved = null;
    }

    pub fn line(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn handle(self: *Editor, key: Key, hist: *const History) Allocator.Error!Status {
        switch (key) {
            .char => |c| {
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &enc) catch return .editing;
                try self.buf.insertSlice(self.gpa, self.cursor, enc[0..n]);
                self.cursor += n;
            },
            .enter => return .submitted,
            .interrupt => return .interrupted,
            .ctrl_d => {
                if (self.buf.items.len == 0) return .eof;
                self.deleteForward();
            },
            .backspace => {
                if (self.cursor > 0) {
                    const from = self.prevBoundary(self.cursor);
                    self.buf.replaceRangeAssumeCapacity(from, self.cursor - from, "");
                    self.cursor = from;
                }
            },
            .delete => self.deleteForward(),
            .left => self.cursor = self.prevBoundary(self.cursor),
            .right => self.cursor = self.nextBoundary(self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = self.buf.items.len,
            .word_left => self.cursor = self.wordStart(self.cursor),
            .word_right => self.cursor = self.wordEnd(self.cursor),
            .kill_end => self.buf.shrinkRetainingCapacity(self.cursor),
            .kill_start => {
                self.buf.replaceRangeAssumeCapacity(0, self.cursor, "");
                self.cursor = 0;
            },
            .kill_word => {
                const from = self.wordStart(self.cursor);
                self.buf.replaceRangeAssumeCapacity(from, self.cursor - from, "");
                self.cursor = from;
            },
            .up => try self.older(hist),
            .down => try self.newer(hist),
            .clear, .tab => {},
        }
        return .editing;
    }

    fn deleteForward(self: *Editor) void {
        if (self.cursor >= self.buf.items.len) return;
        const to = self.nextBoundary(self.cursor);
        self.buf.replaceRangeAssumeCapacity(self.cursor, to - self.cursor, "");
    }

    fn prevBoundary(self: *const Editor, at: usize) usize {
        var i = at;
        while (i > 0) {
            i -= 1;
            if (self.buf.items[i] & 0xc0 != 0x80) break;
        }
        return i;
    }

    fn nextBoundary(self: *const Editor, at: usize) usize {
        var i = at;
        if (i >= self.buf.items.len) return i;
        i += 1;
        while (i < self.buf.items.len and self.buf.items[i] & 0xc0 == 0x80) i += 1;
        return i;
    }

    fn isWordByte(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
    }

    fn wordStart(self: *const Editor, at: usize) usize {
        var i = at;
        while (i > 0 and !isWordByte(self.buf.items[i - 1])) i -= 1;
        while (i > 0 and isWordByte(self.buf.items[i - 1])) i -= 1;
        return i;
    }

    fn wordEnd(self: *const Editor, at: usize) usize {
        var i = at;
        const s = self.buf.items;
        while (i < s.len and !isWordByte(s[i])) i += 1;
        while (i < s.len and isWordByte(s[i])) i += 1;
        return i;
    }

    fn show(self: *Editor, text: []const u8) Allocator.Error!void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.gpa, text);
        self.cursor = self.buf.items.len;
    }

    fn older(self: *Editor, hist: *const History) Allocator.Error!void {
        const n = hist.items.items.len;
        if (n == 0) return;
        if (self.nav) |i| {
            if (i == 0) return;
            self.nav = i - 1;
        } else {
            self.saved = try self.gpa.dupe(u8, self.buf.items);
            self.nav = n - 1;
        }
        try self.show(hist.items.items[self.nav.?]);
    }

    fn newer(self: *Editor, hist: *const History) Allocator.Error!void {
        const i = self.nav orelse return;
        if (i + 1 < hist.items.items.len) {
            self.nav = i + 1;
            try self.show(hist.items.items[i + 1]);
        } else {
            self.nav = null;
            const s = self.saved orelse "";
            try self.show(s);
            if (self.saved) |old| self.gpa.free(old);
            self.saved = null;
        }
    }

    /// Redraw the line: return to column 0, the prompt, the text that fits,
    /// clear the rest, put the cursor back. `prompt_width` is the prompt's
    /// width on screen (it may carry colour codes that take none). A line wider
    /// than the window scrolls to keep the cursor in view.
    pub fn render(self: *const Editor, w: *Writer, prompt: []const u8, prompt_width: usize, cols: usize) Writer.Error!void {
        const s = self.buf.items;
        const room = if (cols > prompt_width + 2) cols - prompt_width - 1 else 1;
        const cursor_chars = std.unicode.utf8CountCodepoints(s[0..self.cursor]) catch self.cursor;
        const start_chars = if (cursor_chars >= room) cursor_chars - room + 1 else 0;
        const from = byteOffset(s, start_chars);
        const to = byteOffset(s, start_chars + room);
        try w.writeAll("\r");
        try w.writeAll(prompt);
        try w.writeAll(s[from..to]);
        try w.writeAll("\x1b[K\r");
        const col = prompt_width + cursor_chars - start_chars;
        if (col > 0) try w.print("\x1b[{d}C", .{col});
    }
};

/// The byte offset of the `n`th code point of `s` (its length when shorter).
fn byteOffset(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < s.len and seen < n) {
        i += 1;
        while (i < s.len and s[i] & 0xc0 == 0x80) i += 1;
        seen += 1;
    }
    return i;
}

/// Display width of a prompt that may carry ANSI colour sequences (`ESC [ … m`):
/// the code points that are not part of one.
pub fn promptWidth(prompt: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < prompt.len) {
        if (prompt[i] == 0x1b and i + 1 < prompt.len and prompt[i + 1] == '[') {
            i += 2;
            while (i < prompt.len and !(prompt[i] >= 0x40 and prompt[i] <= 0x7e)) i += 1;
            i += 1;
            continue;
        }
        if (prompt[i] & 0xc0 != 0x80) n += 1;
        i += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn decodeAll(gpa: Allocator, bytes: []const u8) ![]Key {
    var d: Decoder = .{};
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |b| if (d.feed(b)) |k| try out.append(gpa, k);
    return out.toOwnedSlice(gpa);
}

fn typeInto(ed: *Editor, hist: *const History, bytes: []const u8) !Status {
    var d: Decoder = .{};
    var st: Status = .editing;
    for (bytes) |b| if (d.feed(b)) |k| {
        st = try ed.handle(k, hist);
        if (st != .editing) return st;
    };
    return st;
}

test "decoder: plain bytes, control keys, UTF-8 and escape sequences" {
    const keys = try decodeAll(testing.allocator, "a\xc3\xa9\x01\x1b[A\x1b[3~\x1bOH\x1b[1;5C\x1bb\x7f\r");
    defer testing.allocator.free(keys);
    try testing.expectEqual(@as(usize, 10), keys.len);
    try testing.expectEqual(@as(u21, 'a'), keys[0].char);
    try testing.expectEqual(@as(u21, 0xe9), keys[1].char);
    try testing.expect(keys[2] == .home);
    try testing.expect(keys[3] == .up);
    try testing.expect(keys[4] == .delete);
    try testing.expect(keys[5] == .home);
    try testing.expect(keys[6] == .word_right);
    try testing.expect(keys[7] == .word_left);
    try testing.expect(keys[8] == .backspace);
    try testing.expect(keys[9] == .enter);
}

test "decoder: a broken UTF-8 sequence and unknown escapes are dropped" {
    const keys = try decodeAll(testing.allocator, "\xe2\x82x\x1b[99zy");
    defer testing.allocator.free(keys);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqual(@as(u21, 'x'), keys[0].char);
    try testing.expectEqual(@as(u21, 'y'), keys[1].char);
}

test "editor: insert, move, delete and kill" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try typeInto(&ed, &hist, "hello world");
    try testing.expectEqualStrings("hello world", ed.line());
    _ = try typeInto(&ed, &hist, "\x1bb"); // word left
    try testing.expectEqual(@as(usize, 6), ed.cursor);
    _ = try typeInto(&ed, &hist, "\x7f"); // backspace joins the words
    try testing.expectEqualStrings("helloworld", ed.line());
    _ = try typeInto(&ed, &hist, "\x0b"); // kill to end
    try testing.expectEqualStrings("hello", ed.line());
    _ = try typeInto(&ed, &hist, "\x01X\x15"); // home, X, kill to start
    try testing.expectEqualStrings("hello", ed.line());
    try testing.expectEqual(@as(usize, 0), ed.cursor);
    _ = try typeInto(&ed, &hist, "\x1b[3~"); // delete
    try testing.expectEqualStrings("ello", ed.line());
    _ = try typeInto(&ed, &hist, "\x05\x17"); // end, kill word
    try testing.expectEqualStrings("", ed.line());
}

test "editor: multi-byte characters are one step" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try typeInto(&ed, &hist, "a\xc3\xa9\xe2\x82\xacz");
    _ = try typeInto(&ed, &hist, "\x02\x02"); // two lefts: before the euro sign
    try testing.expectEqual(@as(usize, 3), ed.cursor);
    _ = try typeInto(&ed, &hist, "\x7f"); // removes the whole é
    try testing.expectEqualStrings("a\xe2\x82\xacz", ed.line());
}

test "editor: Enter, Ctrl-C, and Ctrl-D (end of input only when empty)" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expectEqual(Status.eof, try typeInto(&ed, &hist, "\x04"));
    _ = try typeInto(&ed, &hist, "ab\x01");
    try testing.expectEqual(Status.editing, try typeInto(&ed, &hist, "\x04"));
    try testing.expectEqualStrings("b", ed.line());
    try testing.expectEqual(Status.submitted, try typeInto(&ed, &hist, "\r"));
    try testing.expectEqual(Status.interrupted, try typeInto(&ed, &hist, "\x03"));
}

test "editor: history walks back and forward and gives the typed line back" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    try hist.add("one");
    try hist.add("two");
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try typeInto(&ed, &hist, "draft");
    _ = try typeInto(&ed, &hist, "\x1b[A");
    try testing.expectEqualStrings("two", ed.line());
    _ = try typeInto(&ed, &hist, "\x1b[A\x1b[A"); // stops at the oldest
    try testing.expectEqualStrings("one", ed.line());
    _ = try typeInto(&ed, &hist, "\x1b[B");
    try testing.expectEqualStrings("two", ed.line());
    _ = try typeInto(&ed, &hist, "\x1b[B");
    try testing.expectEqualStrings("draft", ed.line());
    _ = try typeInto(&ed, &hist, "\x1b[B"); // nothing newer
    try testing.expectEqualStrings("draft", ed.line());
}

test "history: blanks and repeats are not kept, the oldest go past the limit, a file round-trips" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    hist.max = 3;
    try hist.add("");
    try hist.add("  \t");
    try hist.add("a");
    try hist.add("a");
    try hist.add("b");
    try hist.add("c");
    try hist.add("d");
    try testing.expectEqual(@as(usize, 3), hist.items.items.len);
    try testing.expectEqualStrings("b", hist.items.items[0]);
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try hist.write(&aw.writer);
    try testing.expectEqualStrings("b\nc\nd\n", aw.written());
    var back = History.init(testing.allocator);
    defer back.deinit();
    try back.load("x\r\ny\n\n");
    try testing.expectEqual(@as(usize, 2), back.items.items.len);
    try testing.expectEqualStrings("x", back.items.items[0]);
}

test "render: prompt, text, clear and cursor column; a long line scrolls" {
    var hist = History.init(testing.allocator);
    defer hist.deinit();
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try typeInto(&ed, &hist, "abc");
    _ = try typeInto(&ed, &hist, "\x02");
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try ed.render(&aw.writer, "> ", 2, 80);
    try testing.expectEqualStrings("\r> abc\x1b[K\r\x1b[4C", aw.written());

    // Ten columns: the prompt takes 2, so 7 characters show; the cursor sits at the end.
    ed.reset();
    _ = try typeInto(&ed, &hist, "0123456789");
    aw.clearRetainingCapacity();
    try ed.render(&aw.writer, "> ", 2, 10);
    try testing.expectEqualStrings("\r> 456789\x1b[K\r\x1b[8C", aw.written());
}

test "promptWidth skips colour codes" {
    try testing.expectEqual(@as(usize, 5), promptWidth("\x1b[32m~/x\x1b[0m> "));
    try testing.expectEqual(@as(usize, 2), promptWidth("> "));
}
