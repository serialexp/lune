//! Doc 83 §4.3: the formatter's document algebra and its fitting printer.
//!
//! A `Doc` is a tree the formatter builds from the program's syntax and the
//! printer turns into text. This file has no language in it: the unit tests
//! print hand-built documents. Everything is allocated by the caller's
//! allocator (the formatter hands in an arena); the printer's own working
//! memory (a command stack, the lookahead's scratch stack, the queued
//! trailing comments, the output) is allocated once per `print` and freed on
//! return.
//!
//! The algebra is Wadler's ("A prettier printer"), with three additions the
//! formatter needs:
//!
//!   * `hug(d)`: `d` is always printed in break mode, and an enclosing
//!     group's "does it fit" question stops at `d`'s first newline. A function
//!     body (all hardlines) can therefore be the last argument of a call
//!     whose other arguments stay on the call's line (§6.2).
//!   * `lineSuffix(s)`: queued, and written at the next newline, after
//!     whatever the code itself prints on that line (a comma, a closing
//!     bracket), so a trailing `-- comment` can never swallow code (§5).
//!   * `fill(items)`: as many items per line as fit (§6.5).
//!
//! Cost (Rule #20): a group is decided by `fits`, which stops the moment the
//! remaining width is used up, so it reads at most `width` columns of text
//! per group whatever the line's length. `Stats.fits_steps` counts the nodes
//! it visits, and a test asserts the bound on deep nesting.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Doc = *const Node;

pub const Node = union(enum) {
    /// Prints nothing.
    empty,
    /// Text with no newline in it. Its width is its code point count.
    text: []const u8,
    /// Verbatim text that may contain newlines (a block comment, a long
    /// string). Never re-indented, never trimmed; a group holding one fits if
    /// its first line does.
    raw: []const u8,
    /// A space when the enclosing group is flat, a newline when it is broken.
    line,
    /// Nothing when flat, a newline when broken.
    softline,
    /// Always a newline. Forces every enclosing group (up to a `hug`) to break.
    hardline,
    /// Forces every enclosing group (up to a `hug`) to break, prints nothing.
    break_parent,
    concat: []const Doc,
    /// Its content's newlines indent one level deeper.
    indent: Doc,
    /// Flat if it fits in the remaining width (counting the text up to the
    /// next possible newline after it), else broken.
    group: Doc,
    /// See the file comment.
    hug: Doc,
    /// Items separated by a space or a newline, each placed on the current
    /// line if it fits there.
    fill: []const Doc,
    /// Queued text, written at the next newline (or at the end).
    line_suffix: []const u8,
};

pub const empty: Doc = &.{ .empty = {} };
pub const line: Doc = &.{ .line = {} };
pub const softline: Doc = &.{ .softline = {} };
pub const hardline: Doc = &.{ .hardline = {} };
pub const break_parent: Doc = &.{ .break_parent = {} };

/// Builds nodes in the allocator it is given (the formatter's arena).
pub const Builder = struct {
    a: Allocator,

    fn node(b: Builder, n: Node) Allocator.Error!Doc {
        const p = try b.a.create(Node);
        p.* = n;
        return p;
    }

    pub fn text(b: Builder, s: []const u8) Allocator.Error!Doc {
        std.debug.assert(std.mem.indexOfScalar(u8, s, '\n') == null);
        if (s.len == 0) return empty;
        return b.node(.{ .text = s });
    }

    pub fn raw(b: Builder, s: []const u8) Allocator.Error!Doc {
        return b.node(.{ .raw = s });
    }

    /// The parts are copied, so a stack array can be passed.
    pub fn cat(b: Builder, parts: []const Doc) Allocator.Error!Doc {
        return b.node(.{ .concat = try b.a.dupe(Doc, parts) });
    }

    pub fn indent(b: Builder, d: Doc) Allocator.Error!Doc {
        return b.node(.{ .indent = d });
    }

    pub fn group(b: Builder, d: Doc) Allocator.Error!Doc {
        return b.node(.{ .group = d });
    }

    pub fn hug(b: Builder, d: Doc) Allocator.Error!Doc {
        return b.node(.{ .hug = d });
    }

    pub fn fill(b: Builder, items: []const Doc) Allocator.Error!Doc {
        return b.node(.{ .fill = try b.a.dupe(Doc, items) });
    }

    pub fn lineSuffix(b: Builder, s: []const u8) Allocator.Error!Doc {
        return b.node(.{ .line_suffix = s });
    }

    /// `items` separated by `sep`.
    pub fn join(b: Builder, sep: Doc, items: []const Doc) Allocator.Error!Doc {
        const out = try b.a.alloc(Doc, if (items.len == 0) 0 else items.len * 2 - 1);
        for (items, 0..) |it, i| {
            if (i > 0) out[2 * i - 1] = sep;
            out[2 * i] = it;
        }
        return b.node(.{ .concat = out });
    }
};

pub const Options = struct {
    /// Columns a line may use before a group breaks.
    width: u32 = 100,
    /// Spaces per `indent` level.
    indent: u32 = 4,
};

pub const Stats = struct {
    /// Nodes the lookahead visited, over all groups.
    fits_steps: u64 = 0,
};

const Mode = enum { flat, brk };

const Cmd = struct {
    indent: u32,
    mode: Mode,
    doc: Doc,
    /// For a `fill`: the next item to place.
    fill_next: u32 = 0,
};

/// Columns in `s`: its code points.
pub fn textWidth(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

const Printer = struct {
    gpa: Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Cmd) = .empty,
    scratch: std.ArrayList(Cmd) = .empty,
    suffixes: std.ArrayList([]const u8) = .empty,
    /// Column of the next character, once the indentation is written.
    col: u32 = 0,
    /// Indentation owed to the next text (written lazily, so a blank line
    /// carries none).
    pending_indent: ?u32 = null,
    /// Bytes of `out` below this index are verbatim (`raw`) and are never trimmed.
    trim_floor: usize = 0,
    stats: Stats = .{},

    fn deinit(p: *Printer) void {
        p.out.deinit(p.gpa);
        p.stack.deinit(p.gpa);
        p.scratch.deinit(p.gpa);
        p.suffixes.deinit(p.gpa);
    }

    fn flushIndent(p: *Printer) Allocator.Error!void {
        if (p.pending_indent) |n| {
            try p.out.appendNTimes(p.gpa, ' ', n);
            p.col = n;
            p.pending_indent = null;
        }
    }

    fn emitText(p: *Printer, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        try p.flushIndent();
        try p.out.appendSlice(p.gpa, s);
        p.col += textWidth(s);
    }

    fn emitRaw(p: *Printer, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        try p.flushIndent();
        try p.out.appendSlice(p.gpa, s);
        p.trim_floor = p.out.items.len;
        if (std.mem.lastIndexOfScalar(u8, s, '\n')) |nl| {
            p.col = textWidth(s[nl + 1 ..]);
        } else {
            p.col += textWidth(s);
        }
    }

    fn newline(p: *Printer, indent: u32) Allocator.Error!void {
        for (p.suffixes.items) |s| try p.emitText(s);
        p.suffixes.clearRetainingCapacity();
        // No trailing spaces of ours; a raw token's own bytes stay.
        var n = p.out.items.len;
        while (n > p.trim_floor and p.out.items[n - 1] == ' ') n -= 1;
        p.out.shrinkRetainingCapacity(n);
        try p.out.append(p.gpa, '\n');
        p.pending_indent = indent;
        p.col = 0;
    }

    fn push(p: *Printer, c: Cmd) Allocator.Error!void {
        try p.stack.append(p.gpa, c);
    }

    fn pushChildren(p: *Printer, base: Cmd, kids: []const Doc) Allocator.Error!void {
        var i = kids.len;
        while (i > 0) {
            i -= 1;
            try p.push(.{ .indent = base.indent, .mode = base.mode, .doc = kids[i] });
        }
    }

    /// Does `first` (printed flat) and what follows it on the command stack
    /// fit in `budget` columns up to the first newline? `rest` is the part
    /// of the main stack that follows; it is read, never changed.
    fn fits(p: *Printer, budget: i64, first: Cmd, rest: []const Cmd) Allocator.Error!bool {
        var w = budget;
        var rest_i = rest.len;
        p.scratch.clearRetainingCapacity();
        try p.scratch.append(p.gpa, first);
        while (true) {
            if (w < 0) return false;
            const c = p.scratch.pop() orelse {
                if (rest_i == 0) return true;
                rest_i -= 1;
                try p.scratch.append(p.gpa, rest[rest_i]);
                continue;
            };
            p.stats.fits_steps += 1;
            switch (c.doc.*) {
                .empty, .line_suffix => {},
                .text => |s| w -= textWidth(s),
                .raw => |s| {
                    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
                        return w - textWidth(s[0..nl]) >= 0;
                    }
                    w -= textWidth(s);
                },
                .line => switch (c.mode) {
                    .flat => w -= 1,
                    .brk => return true,
                },
                .softline => if (c.mode == .brk) return true,
                .hardline => return c.mode == .brk,
                .break_parent => if (c.mode == .flat) return false,
                .concat => |kids| {
                    var i = kids.len;
                    while (i > 0) {
                        i -= 1;
                        try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = kids[i] });
                    }
                },
                .indent, .group => |d| try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = d }),
                .hug => |d| try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .brk, .doc = d }),
                .fill => |items| {
                    if (items.len == 0) continue;
                    if (c.mode == .brk) {
                        // Only the first item is on this line.
                        try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = items[0] });
                        continue;
                    }
                    var i = items.len;
                    while (i > 0) {
                        i -= 1;
                        try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = items[i] });
                        if (i > 0) try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = line });
                    }
                },
            }
        }
    }

    fn remaining(p: *const Printer) i64 {
        return @as(i64, p.opts.width) - @as(i64, p.col);
    }

    fn run(p: *Printer, doc: Doc) Allocator.Error!void {
        try p.push(.{ .indent = 0, .mode = .brk, .doc = doc });
        while (p.stack.pop()) |c| {
            switch (c.doc.*) {
                .empty => {},
                .text => |s| try p.emitText(s),
                .raw => |s| try p.emitRaw(s),
                .line_suffix => |s| try p.suffixes.append(p.gpa, s),
                .break_parent => {},
                .line => switch (c.mode) {
                    .flat => try p.emitText(" "),
                    .brk => try p.newline(c.indent),
                },
                .softline => if (c.mode == .brk) try p.newline(c.indent),
                .hardline => try p.newline(c.indent),
                .concat => |kids| try p.pushChildren(c, kids),
                .indent => |d| try p.push(.{ .indent = c.indent + p.opts.indent, .mode = c.mode, .doc = d }),
                .hug => |d| try p.push(.{ .indent = c.indent, .mode = .brk, .doc = d }),
                .group => |d| {
                    const mode: Mode = switch (c.mode) {
                        .flat => .flat,
                        .brk => if (try p.fits(p.remaining(), .{ .indent = c.indent, .mode = .flat, .doc = d }, p.stack.items)) .flat else .brk,
                    };
                    try p.push(.{ .indent = c.indent, .mode = mode, .doc = d });
                },
                .fill => |items| try p.fillStep(c, items),
            }
        }
        for (p.suffixes.items) |s| try p.emitText(s);
        p.suffixes.clearRetainingCapacity();
    }

    fn fillStep(p: *Printer, c: Cmd, items: []const Doc) Allocator.Error!void {
        const i = c.fill_next;
        if (i >= items.len) return;
        const last = i + 1 == items.len;
        if (!last) try p.push(.{ .indent = c.indent, .mode = c.mode, .doc = c.doc, .fill_next = i + 1 });
        const item: Cmd = .{ .indent = c.indent, .mode = .flat, .doc = items[i] };
        // The item (and, for the last one, what follows it) after a space.
        const tail: []const Cmd = if (last) p.stack.items else &.{};
        var mode: Mode = .flat;
        if (i > 0) {
            if (c.mode == .flat or try p.fits(p.remaining() - 1, item, tail)) {
                try p.emitText(" ");
            } else {
                try p.newline(c.indent);
                if (!try p.fits(p.remaining(), item, tail)) mode = .brk;
            }
        } else if (c.mode == .brk and !try p.fits(p.remaining(), item, tail)) {
            mode = .brk;
        }
        try p.push(.{ .indent = c.indent, .mode = mode, .doc = items[i] });
    }
};

/// Prints `doc`. The result is owned by `gpa`. It has no trailing newline
/// unless the document ends in a `hardline`.
pub fn print(gpa: Allocator, doc: Doc, opts: Options, stats: ?*Stats) Allocator.Error![]u8 {
    var p: Printer = .{ .gpa = gpa, .opts = opts };
    defer p.deinit();
    try p.run(doc);
    if (stats) |s| s.* = p.stats;
    return p.out.toOwnedSlice(gpa);
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn expectPrint(width: u32, doc: Doc, expected: []const u8) !void {
    const got = try print(testing.allocator, doc, .{ .width = width }, null);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// `name(a, b, c)` as an argument-list group.
fn call(b: Builder, name: []const u8, args: []const []const u8) !Doc {
    var items: [8]Doc = undefined;
    for (args, 0..) |a, i| items[i] = try b.cat(&.{ try b.text(a), if (i + 1 < args.len) try b.text(",") else empty });
    const sep = try b.join(line, items[0..args.len]);
    return b.group(try b.cat(&.{
        try b.text(name),
        try b.text("("),
        try b.indent(try b.cat(&.{ softline, sep })),
        softline,
        try b.text(")"),
    }));
}

test "format_doc: a group that fits prints flat, one that does not breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try call(b, "f", &.{ "alpha", "beta", "gamma" });
    try expectPrint(100, d, "f(alpha, beta, gamma)");
    try expectPrint(12, d, "f(\n    alpha,\n    beta,\n    gamma\n)");
    // Exactly the width fits; one column less does not.
    try expectPrint(21, d, "f(alpha, beta, gamma)");
    try expectPrint(20, d, "f(\n    alpha,\n    beta,\n    gamma\n)");
}

test "format_doc: what follows a group counts against its width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.cat(&.{ try call(b, "f", &.{ "a", "b" }), try b.text(" -- tail") });
    try expectPrint(100, d, "f(a, b) -- tail");
    try expectPrint(14, d, "f(\n    a,\n    b\n) -- tail");
}

test "format_doc: nested groups decide independently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const inner = try call(b, "g", &.{ "x", "y" });
    const outer = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, inner, try b.text(","), line, try b.text("tail_argument_that_is_long") })),
        softline,
        try b.text(")"),
    }));
    try expectPrint(100, outer, "f(g(x, y), tail_argument_that_is_long)");
    try expectPrint(30, outer, "f(\n    g(x, y),\n    tail_argument_that_is_long\n)");
}

test "format_doc: a hardline breaks every enclosing group; a blank line has no indentation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.group(try b.cat(&.{
        try b.text("do"),
        try b.indent(try b.cat(&.{ line, try b.text("a"), hardline, hardline, try b.text("b") })),
        line,
        try b.text("end"),
    }));
    try expectPrint(100, d, "do\n    a\n\n    b\nend");
}

test "format_doc: break_parent breaks a group that would fit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.group(try b.cat(&.{ try b.text("{"), try b.indent(try b.cat(&.{ line, try b.text("a"), break_parent })), line, try b.text("}") }));
    try expectPrint(100, d, "{\n    a\n}");
}

test "format_doc: a hugged last argument keeps the others on the call's line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const body = try b.cat(&.{
        try b.text("function()"),
        try b.indent(try b.cat(&.{ hardline, try b.text("return 1") })),
        hardline,
        try b.text("end"),
    });
    // f(a, <hug>): the function body has hardlines, yet `a` stays put.
    const d = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.text("a, "),
        try b.hug(body),
        try b.text(")"),
    }));
    try expectPrint(100, d, "f(a, function()\n    return 1\nend)");
    // Without the hug the same document breaks the group (and `softline`s with it).
    const plain = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, try b.text("a,"), line, body })),
        softline,
        try b.text(")"),
    }));
    try expectPrint(100, plain, "f(\n    a,\n    function()\n        return 1\n    end\n)");
}

test "format_doc: a hug whose head does not fit makes the enclosing group break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const body = try b.cat(&.{ try b.text("function()"), try b.indent(try b.cat(&.{ hardline, try b.text("x") })), hardline, try b.text("end") });
    const d = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, try b.text("long_first_argument,"), line, try b.hug(body) })),
        softline,
        try b.text(")"),
    }));
    // The head "f(long_first_argument, function()" is 33 columns.
    try expectPrint(33, d, "f(long_first_argument, function()\n        x\n    end)");
    try expectPrint(32, d, "f(\n    long_first_argument,\n    function()\n        x\n    end\n)");
}

test "format_doc: a trailing comment is written at the newline, after the code's comma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.cat(&.{
        try b.text("a"),
        try b.lineSuffix(" -- first"),
        try b.text(","),
        hardline,
        try b.text("b"),
        try b.lineSuffix(" -- last"),
    });
    try expectPrint(100, d, "a, -- first\nb -- last");
}

test "format_doc: a trailing comment is not counted against the width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.group(try b.cat(&.{ try b.text("f("), try b.text("a"), try b.lineSuffix(" -- a very long trailing comment indeed"), try b.text(")") }));
    try expectPrint(12, d, "f(a) -- a very long trailing comment indeed");
}

test "format_doc: fill packs items per line, aligned to the indent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    var items: [10]Doc = undefined;
    const names = [_][]const u8{ "1,", "2,", "3,", "4,", "5,", "6,", "7,", "8,", "9,", "10," };
    for (names, 0..) |n, i| items[i] = try b.text(n);
    const d = try b.group(try b.cat(&.{
        try b.text("{"),
        try b.indent(try b.cat(&.{ hardline, try b.fill(&items) })),
        hardline,
        try b.text("}"),
    }));
    try expectPrint(100, d, "{\n    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,\n}");
    try expectPrint(15, d, "{\n    1, 2, 3, 4,\n    5, 6, 7, 8,\n    9, 10,\n}");
    try expectPrint(14, d, "{\n    1, 2, 3,\n    4, 5, 6,\n    7, 8, 9,\n    10,\n}");
}

test "format_doc: raw text is verbatim; its last line sets the column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.cat(&.{
        try b.text("local s = "),
        try b.raw("[[a  \n  b  ]]"),
        hardline,
        try b.text("x"),
    });
    try expectPrint(100, d, "local s = [[a  \n  b  ]]\nx");
    // A group holding a raw token fits on its first line.
    const g = try b.group(try b.cat(&.{ try b.text("f("), try b.raw("[[a\nb]]"), try b.text(")") }));
    try expectPrint(100, g, "f([[a\nb]])");
}

test "format_doc: no trailing spaces before a newline; multibyte text counts code points" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    const d = try b.cat(&.{ try b.text("a "), hardline, try b.text("b") });
    try expectPrint(100, d, "a\nb");
    try testing.expectEqual(@as(u32, 3), textWidth("añ€"));
    const g = try b.group(try b.cat(&.{ try b.text("ñññ"), line, try b.text("ñññ") }));
    try expectPrint(7, g, "ñññ ñññ");
    try expectPrint(6, g, "ñññ\nñññ");
}

test "format_doc: deciding deeply nested groups reads a bounded amount of text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const b: Builder = .{ .a = arena.allocator() };
    // f(f(f(... x ...))) nested `depth` deep, each level an argument group.
    const depth = 400;
    var d: Doc = try b.text("x");
    for (0..depth) |_| {
        d = try b.group(try b.cat(&.{
            try b.text("f("),
            try b.indent(try b.cat(&.{ softline, d })),
            softline,
            try b.text(")"),
        }));
    }
    var stats: Stats = .{};
    const got = try print(testing.allocator, d, .{ .width = 100 }, &stats);
    defer testing.allocator.free(got);
    // Every group's lookahead stops once the width is spent: at most a
    // constant number of nodes per column, per group.
    try testing.expect(stats.fits_steps <= @as(u64, depth) * 100 * 6);
    // And the output is the broken staircase, not a hang.
    try testing.expect(std.mem.count(u8, got, "\n") > depth);
}
