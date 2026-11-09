//! Doc 83 §4.3: the formatter's document algebra and its fitting printer.
//!
//! A `Doc` is a tree the formatter builds from the program's syntax and the
//! printer turns into text. This file has no language in it: the unit tests
//! print hand-built documents.
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
//! Memory (doc 83 §10, Rule #20): a document is a few nodes per source token,
//! so its encoding decides the formatter's footprint. A `Doc` is a `u32` index
//! into the `Builder`'s one node array; a node is 12 bytes; a node's children
//! are a range of the builder's one child array; text is a span of the source
//! (or of the builder's own bytes, for text the formatter makes), never a
//! copy; the punctuation and keywords the formatter prints are nodes made
//! once, at `init`. A caller builds a list of parts on the builder's stack
//! (`top`, `push`, `catFrom`) instead of a list of its own, so building leaves
//! no dead buffers behind. `mark`/`release` drop everything built after a
//! point, which is how the formatter prints a file one top-level statement at
//! a time (`Printer.feed`) in memory bounded by the largest statement.
//!
//! Cost: a group is decided by `fits`, which stops the moment the remaining
//! width is used up, so it reads at most `width` columns of text per group
//! whatever the line's length. `Stats.fits_steps` counts the nodes it visits,
//! and a test asserts the bound on deep nesting.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A document: an index into its `Builder`'s nodes.
pub const Doc = enum(u32) {
    empty,
    line,
    softline,
    hardline,
    break_parent,
    _,
};

/// Prints nothing.
pub const empty: Doc = .empty;
/// A space when the enclosing group is flat, a newline when it is broken.
pub const line: Doc = .line;
/// Nothing when flat, a newline when broken.
pub const softline: Doc = .softline;
/// Always a newline. Forces every enclosing group (up to a `hug`) to break.
pub const hardline: Doc = .hardline;
/// Forces every enclosing group (up to a `hug`) to break, prints nothing.
pub const break_parent: Doc = .break_parent;

pub const Tag = enum(u8) {
    empty,
    line,
    softline,
    hardline,
    break_parent,
    /// Text with no newline in it; its width is its code point count. `a`,
    /// `b`: offset and length in the source (`_src`) or the builder's bytes.
    text_src,
    text_own,
    /// Verbatim text that may contain newlines (a block comment, a long
    /// string). Never re-indented, never trimmed; a group holding one fits if
    /// its first line does.
    raw_src,
    raw_own,
    /// Queued text, written at the next newline (or at the end).
    suffix_src,
    suffix_own,
    /// `a`, `b`: first child and count, in the builder's child array.
    concat,
    /// Items separated by a space or a newline, each placed on the current
    /// line if it fits there. Children as for `concat`.
    fill,
    /// `a`: the child. Its newlines indent one level deeper.
    indent,
    /// `a`: the child. Flat if it fits in the remaining width (counting the
    /// text up to the next possible newline after it), else broken.
    group,
    /// `a`: the child. See the file comment.
    hug,
    /// `a` in a broken group, `b` in a flat one (a trailing comma that only
    /// the one-entry-per-line form has).
    if_break,
    /// Two layouts of one thing, for a call whose last argument is hugged:
    /// `a` (hugged) if its text up to its first newline fits where it stands,
    /// else `b` (expanded).
    alt,
};

pub const Node = struct {
    a: u32 = 0,
    b: u32 = 0,
    tag: Tag,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 12);
}

/// The text the formatter prints over and over, made once at `init`.
const interned = [_][]const u8{
    "(",        ")",         "{",       "}",        "[",       "]",      ",",       ", ",       ";",
    ":",        ": ",        ".",       "...",      "()",      "{}",     " ",       " = ",      "] = ",
    "end",      "do",        " do",     "then",     " then",   "else",   "if ",     "elseif ",  "for ",
    "while ",   "repeat",    "until ",  " in ",     "return",  "return ", "break",  "local ",   "global ",
    "function", "function ", "async function", "async function ", "await ", "not ", "-", "#", "~",
    "+",        "*",         "/",       "//",       "%",       "^",      "..",      "==",       "~=",
    "<",        "<=",        ">",       ">=",       "and",     "or",     "??",      "&",        "|",
    "<<",       ">>",        "~>>",
};

const interned_map = std.StaticStringMap(u32).initComptime(blk: {
    var kvs: [interned.len]struct { []const u8, u32 } = undefined;
    for (interned, 0..) |s, i| kvs[i] = .{ s, @intCast(i) };
    break :blk kvs;
});

/// Builds documents. Every array it owns is in `gpa`; `deinit` frees them.
pub const Builder = struct {
    gpa: Allocator,
    /// Text inside this slice is kept as a span of it, not copied.
    src: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    kids: std.ArrayList(Doc) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    /// The parts of the lists being built (`top`, `push`, `catFrom`).
    stack: std.ArrayList(Doc) = .empty,
    /// The first node after the fixed ones (`mark` never goes below it).
    base: u32 = 0,

    pub fn init(gpa: Allocator, src: []const u8) Allocator.Error!Builder {
        var b: Builder = .{ .gpa = gpa, .src = src };
        errdefer b.deinit();
        for ([_]Tag{ .empty, .line, .softline, .hardline, .break_parent }) |tag| try b.nodes.append(gpa, .{ .tag = tag });
        for (interned) |s| _ = try b.own(.text_own, s);
        b.base = @intCast(b.nodes.items.len);
        return b;
    }

    pub fn deinit(b: *Builder) void {
        b.nodes.deinit(b.gpa);
        b.kids.deinit(b.gpa);
        b.bytes.deinit(b.gpa);
        b.stack.deinit(b.gpa);
    }

    /// Bytes the builder holds, for the formatter's memory breakdown.
    pub fn capacityBytes(b: *const Builder) usize {
        return b.nodes.capacity * @sizeOf(Node) + b.kids.capacity * @sizeOf(Doc) + b.bytes.capacity + b.stack.capacity * @sizeOf(Doc);
    }

    pub fn node(b: *const Builder, d: Doc) Node {
        return b.nodes.items[@intFromEnum(d)];
    }

    /// The text of a `text_*`, `raw_*` or `suffix_*` node.
    pub fn str(b: *const Builder, n: Node) []const u8 {
        return switch (n.tag) {
            .text_src, .raw_src, .suffix_src => b.src[n.a..][0..n.b],
            else => b.bytes.items[n.a..][0..n.b],
        };
    }

    /// The children of a `concat` or `fill` node.
    pub fn children(b: *const Builder, n: Node) []const Doc {
        return b.kids.items[n.a..][0..n.b];
    }

    fn add(b: *Builder, n: Node) Allocator.Error!Doc {
        const i: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.gpa, n);
        return @enumFromInt(i);
    }

    fn inSrc(b: *const Builder, s: []const u8) bool {
        const lo = @intFromPtr(b.src.ptr);
        const p = @intFromPtr(s.ptr);
        return p >= lo and p + s.len <= lo + b.src.len;
    }

    fn own(b: *Builder, tag: Tag, s: []const u8) Allocator.Error!Doc {
        const at: u32 = @intCast(b.bytes.items.len);
        try b.bytes.appendSlice(b.gpa, s);
        return b.add(.{ .tag = tag, .a = at, .b = @intCast(s.len) });
    }

    /// `src_tag` for a span of the source, else `src_tag`'s `_own` twin (the
    /// tag after it) over a copy of `s`.
    fn span(b: *Builder, src_tag: Tag, s: []const u8) Allocator.Error!Doc {
        if (b.inSrc(s)) return b.add(.{ .tag = src_tag, .a = @intCast(s.ptr - b.src.ptr), .b = @intCast(s.len) });
        return b.own(@enumFromInt(@intFromEnum(src_tag) + 1), s);
    }

    pub fn text(b: *Builder, s: []const u8) Allocator.Error!Doc {
        std.debug.assert(std.mem.indexOfScalar(u8, s, '\n') == null);
        if (s.len == 0) return empty;
        if (interned_map.get(s)) |i| return @enumFromInt(5 + i);
        return b.span(.text_src, s);
    }

    pub fn raw(b: *Builder, s: []const u8) Allocator.Error!Doc {
        return b.span(.raw_src, s);
    }

    pub fn lineSuffix(b: *Builder, s: []const u8) Allocator.Error!Doc {
        return b.span(.suffix_src, s);
    }

    /// `docs` in order. Empty ones are dropped, and one is itself.
    /// The parts are copied, so a stack array can be passed.
    pub fn cat(b: *Builder, docs: []const Doc) Allocator.Error!Doc {
        var n: usize = 0;
        var only: Doc = empty;
        for (docs) |p| if (p != empty) {
            n += 1;
            only = p;
        };
        if (n <= 1) return only;
        const at: u32 = @intCast(b.kids.items.len);
        try b.kids.ensureUnusedCapacity(b.gpa, n);
        for (docs) |p| if (p != empty) b.kids.appendAssumeCapacity(p);
        return b.add(.{ .tag = .concat, .a = at, .b = @intCast(n) });
    }

    pub fn fill(b: *Builder, items: []const Doc) Allocator.Error!Doc {
        const at: u32 = @intCast(b.kids.items.len);
        try b.kids.appendSlice(b.gpa, items);
        return b.add(.{ .tag = .fill, .a = at, .b = @intCast(items.len) });
    }

    pub fn indent(b: *Builder, d: Doc) Allocator.Error!Doc {
        return b.add(.{ .tag = .indent, .a = @intFromEnum(d) });
    }

    pub fn group(b: *Builder, d: Doc) Allocator.Error!Doc {
        return b.add(.{ .tag = .group, .a = @intFromEnum(d) });
    }

    pub fn hug(b: *Builder, d: Doc) Allocator.Error!Doc {
        return b.add(.{ .tag = .hug, .a = @intFromEnum(d) });
    }

    pub fn ifBreak(b: *Builder, brk: Doc, flat: Doc) Allocator.Error!Doc {
        return b.add(.{ .tag = .if_break, .a = @intFromEnum(brk), .b = @intFromEnum(flat) });
    }

    pub fn alt(b: *Builder, hugged: Doc, expanded: Doc) Allocator.Error!Doc {
        return b.add(.{ .tag = .alt, .a = @intFromEnum(hugged), .b = @intFromEnum(expanded) });
    }

    /// `items` separated by `sep`.
    pub fn join(b: *Builder, sep: Doc, items: []const Doc) Allocator.Error!Doc {
        const t = b.top();
        for (items, 0..) |it, i| {
            if (i > 0) try b.push(sep);
            try b.push(it);
        }
        return b.catFrom(t);
    }

    // -- the parts stack: lists nest, innermost on top --

    pub fn top(b: *const Builder) usize {
        return b.stack.items.len;
    }

    pub fn push(b: *Builder, d: Doc) Allocator.Error!void {
        try b.stack.append(b.gpa, d);
    }

    /// The parts pushed since `t`.
    pub fn parts(b: *const Builder, t: usize) []const Doc {
        return b.stack.items[t..];
    }

    /// Drops the parts pushed since `t`.
    pub fn popTo(b: *Builder, t: usize) void {
        b.stack.shrinkRetainingCapacity(t);
    }

    /// The parts pushed since `t`, concatenated, and popped.
    pub fn catFrom(b: *Builder, t: usize) Allocator.Error!Doc {
        const d = try b.cat(b.stack.items[t..]);
        b.popTo(t);
        return d;
    }

    /// The parts pushed since `t`, as a `fill`, and popped.
    pub fn fillFrom(b: *Builder, t: usize) Allocator.Error!Doc {
        const d = try b.fill(b.stack.items[t..]);
        b.popTo(t);
        return d;
    }

    // -- releasing what has been printed --

    pub const Mark = struct { nodes: usize, kids: usize, bytes: usize };

    pub fn mark(b: *const Builder) Mark {
        return .{ .nodes = b.nodes.items.len, .kids = b.kids.items.len, .bytes = b.bytes.items.len };
    }

    /// Forgets every document built since `m`; their indices are reused.
    pub fn release(b: *Builder, m: Mark) void {
        std.debug.assert(m.nodes >= b.base);
        b.nodes.shrinkRetainingCapacity(m.nodes);
        b.kids.shrinkRetainingCapacity(m.kids);
        b.bytes.shrinkRetainingCapacity(m.bytes);
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
    /// Bytes of the printer's working memory at its largest (command stack,
    /// lookahead stack, queued suffixes; the output not included).
    work_bytes: usize = 0,
};

const Mode = enum { flat, brk };

const Cmd = struct {
    doc: Doc,
    indent: u32,
    /// For a `concat` or `fill`: the next child to print. Children are
    /// pushed one at a time, so the stacks hold one entry per level of
    /// nesting, however many children a node has, and `fits` reads no
    /// further than the width it is asked about.
    next: u32 = 0,
    mode: Mode,
};

/// Columns in `s`: its code points.
pub fn textWidth(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Prints documents one after another into one text (`feed`), so a caller
/// can print a part, `release` it, and build the next. Between feeds the
/// printer holds only its output, its column, and the queued trailing
/// comments (copied, so nothing it holds points into released documents).
pub const Printer = struct {
    gpa: Allocator,
    b: *const Builder,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Cmd) = .empty,
    scratch: std.ArrayList(Cmd) = .empty,
    /// The queued trailing comments' text, one after another.
    suffixes: std.ArrayList(u8) = .empty,
    /// Column of the next character, once the indentation is written.
    col: u32 = 0,
    /// Indentation owed to the next text (written lazily, so a blank line
    /// carries none).
    pending_indent: ?u32 = null,
    /// Bytes of `out` below this index are verbatim (`raw`) and are never trimmed.
    trim_floor: usize = 0,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, b: *const Builder, opts: Options) Printer {
        return .{ .gpa = gpa, .b = b, .opts = opts };
    }

    pub fn deinit(p: *Printer) void {
        p.out.deinit(p.gpa);
        p.stack.deinit(p.gpa);
        p.scratch.deinit(p.gpa);
        p.suffixes.deinit(p.gpa);
    }

    /// Prints `doc` after what is already printed, at indentation 0 in break
    /// mode, as if it followed a newline (or began the text).
    pub fn feed(p: *Printer, doc: Doc) Allocator.Error!void {
        try p.run(doc);
        p.noteWork();
    }

    /// The text printed so far, with any queued trailing comment written,
    /// owned by the caller. The printer is left empty.
    pub fn finish(p: *Printer) Allocator.Error![]u8 {
        try p.emitText(p.suffixes.items);
        p.suffixes.clearRetainingCapacity();
        return p.out.toOwnedSlice(p.gpa);
    }

    fn noteWork(p: *Printer) void {
        const w = p.stack.capacity * @sizeOf(Cmd) + p.scratch.capacity * @sizeOf(Cmd) + p.suffixes.capacity;
        p.stats.work_bytes = @max(p.stats.work_bytes, w);
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
        try p.emitText(p.suffixes.items);
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

    /// Does `first` (printed flat) and what follows it on the command stack
    /// fit in `budget` columns up to the first newline? `rest` is the part
    /// of the main stack that follows; it is read, never changed.
    fn fits(p: *Printer, budget: i64, first: Cmd, rest: []const Cmd) Allocator.Error!bool {
        const b = p.b;
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
            const n = b.node(c.doc);
            switch (n.tag) {
                .empty, .suffix_src, .suffix_own => {},
                .text_src, .text_own => w -= textWidth(b.str(n)),
                .raw_src, .raw_own => {
                    const s = b.str(n);
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
                .concat => {
                    const kids = b.children(n);
                    if (c.next >= kids.len) continue;
                    if (c.next + 1 < kids.len) try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = c.doc, .next = c.next + 1 });
                    try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = kids[c.next] });
                },
                .indent, .group => try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = @enumFromInt(n.a) }),
                .if_break => try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = @enumFromInt(if (c.mode == .brk) n.a else n.b) }),
                .alt => try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = c.mode, .doc = @enumFromInt(n.a) }),
                .hug => try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .brk, .doc = @enumFromInt(n.a) }),
                .fill => {
                    const items = b.children(n);
                    if (c.next >= items.len) continue;
                    if (c.mode == .brk) {
                        // Only the next item is on this line.
                        try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = items[c.next] });
                        continue;
                    }
                    // Flat: the items separated by spaces, one at a time.
                    if (c.next + 1 < items.len) {
                        try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = c.doc, .next = c.next + 1 });
                        try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = line });
                    }
                    try p.scratch.append(p.gpa, .{ .indent = c.indent, .mode = .flat, .doc = items[c.next] });
                },
            }
        }
    }

    fn remaining(p: *const Printer) i64 {
        return @as(i64, p.opts.width) - @as(i64, p.col);
    }

    fn run(p: *Printer, doc: Doc) Allocator.Error!void {
        const b = p.b;
        try p.push(.{ .indent = 0, .mode = .brk, .doc = doc });
        while (p.stack.pop()) |c| {
            const n = b.node(c.doc);
            switch (n.tag) {
                .empty, .break_parent => {},
                .text_src, .text_own => try p.emitText(b.str(n)),
                .raw_src, .raw_own => try p.emitRaw(b.str(n)),
                .suffix_src, .suffix_own => try p.suffixes.appendSlice(p.gpa, b.str(n)),
                .line => switch (c.mode) {
                    .flat => try p.emitText(" "),
                    .brk => try p.newline(c.indent),
                },
                .softline => if (c.mode == .brk) try p.newline(c.indent),
                .hardline => try p.newline(c.indent),
                .concat => {
                    const kids = b.children(n);
                    if (c.next >= kids.len) continue;
                    if (c.next + 1 < kids.len) try p.push(.{ .indent = c.indent, .mode = c.mode, .doc = c.doc, .next = c.next + 1 });
                    try p.push(.{ .indent = c.indent, .mode = c.mode, .doc = kids[c.next] });
                },
                .indent => try p.push(.{ .indent = c.indent + p.opts.indent, .mode = c.mode, .doc = @enumFromInt(n.a) }),
                .hug => try p.push(.{ .indent = c.indent, .mode = .brk, .doc = @enumFromInt(n.a) }),
                .if_break => try p.push(.{ .indent = c.indent, .mode = c.mode, .doc = @enumFromInt(if (c.mode == .brk) n.a else n.b) }),
                .alt => {
                    const hugged_doc: Doc = @enumFromInt(n.a);
                    const hugged = c.mode == .flat or
                        try p.fits(p.remaining(), .{ .indent = c.indent, .mode = .flat, .doc = hugged_doc }, p.stack.items);
                    try p.push(.{ .indent = c.indent, .mode = if (hugged) .flat else c.mode, .doc = if (hugged) hugged_doc else @enumFromInt(n.b) });
                },
                .group => {
                    const d: Doc = @enumFromInt(n.a);
                    const mode: Mode = switch (c.mode) {
                        .flat => .flat,
                        .brk => if (try p.fits(p.remaining(), .{ .indent = c.indent, .mode = .flat, .doc = d }, p.stack.items)) .flat else .brk,
                    };
                    try p.push(.{ .indent = c.indent, .mode = mode, .doc = d });
                },
                .fill => try p.fillStep(c, b.children(n)),
            }
        }
    }

    fn fillStep(p: *Printer, c: Cmd, items: []const Doc) Allocator.Error!void {
        const i = c.next;
        if (i >= items.len) return;
        const last = i + 1 == items.len;
        if (!last) try p.push(.{ .indent = c.indent, .mode = c.mode, .doc = c.doc, .next = i + 1 });
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

/// Prints `doc`, built by `b`. The result is owned by `gpa`. It has no
/// trailing newline unless the document ends in a `hardline`.
pub fn print(gpa: Allocator, b: *const Builder, doc: Doc, opts: Options, stats: ?*Stats) Allocator.Error![]u8 {
    var p: Printer = .init(gpa, b, opts);
    defer p.deinit();
    try p.feed(doc);
    const out = try p.finish();
    if (stats) |s| s.* = p.stats;
    return out;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn expectPrint(b: *const Builder, width: u32, doc: Doc, expected: []const u8) !void {
    const got = try print(testing.allocator, b, doc, .{ .width = width }, null);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// `name(a, b, c)` as an argument-list group.
fn call(b: *Builder, name: []const u8, args: []const []const u8) !Doc {
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
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try call(&b, "f", &.{ "alpha", "beta", "gamma" });
    try expectPrint(&b, 100, d, "f(alpha, beta, gamma)");
    try expectPrint(&b, 12, d, "f(\n    alpha,\n    beta,\n    gamma\n)");
    // Exactly the width fits; one column less does not.
    try expectPrint(&b, 21, d, "f(alpha, beta, gamma)");
    try expectPrint(&b, 20, d, "f(\n    alpha,\n    beta,\n    gamma\n)");
}

test "format_doc: what follows a group counts against its width" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.cat(&.{ try call(&b, "f", &.{ "a", "b" }), try b.text(" -- tail") });
    try expectPrint(&b, 100, d, "f(a, b) -- tail");
    try expectPrint(&b, 14, d, "f(\n    a,\n    b\n) -- tail");
}

test "format_doc: nested groups decide independently" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const inner = try call(&b, "g", &.{ "x", "y" });
    const outer = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, inner, try b.text(","), line, try b.text("tail_argument_that_is_long") })),
        softline,
        try b.text(")"),
    }));
    try expectPrint(&b, 100, outer, "f(g(x, y), tail_argument_that_is_long)");
    try expectPrint(&b, 30, outer, "f(\n    g(x, y),\n    tail_argument_that_is_long\n)");
}

test "format_doc: a hardline breaks every enclosing group; a blank line has no indentation" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.group(try b.cat(&.{
        try b.text("do"),
        try b.indent(try b.cat(&.{ line, try b.text("a"), hardline, hardline, try b.text("b") })),
        line,
        try b.text("end"),
    }));
    try expectPrint(&b, 100, d, "do\n    a\n\n    b\nend");
}

test "format_doc: break_parent breaks a group that would fit" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.group(try b.cat(&.{ try b.text("{"), try b.indent(try b.cat(&.{ line, try b.text("a"), break_parent })), line, try b.text("}") }));
    try expectPrint(&b, 100, d, "{\n    a\n}");
}

test "format_doc: a hugged last argument keeps the others on the call's line" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
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
    try expectPrint(&b, 100, d, "f(a, function()\n    return 1\nend)");
    // Without the hug the same document breaks the group (and `softline`s with it).
    const plain = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, try b.text("a,"), line, body })),
        softline,
        try b.text(")"),
    }));
    try expectPrint(&b, 100, plain, "f(\n    a,\n    function()\n        return 1\n    end\n)");
}

test "format_doc: a hug whose head does not fit makes the enclosing group break" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const body = try b.cat(&.{ try b.text("function()"), try b.indent(try b.cat(&.{ hardline, try b.text("x") })), hardline, try b.text("end") });
    const d = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, try b.text("long_first_argument,"), line, try b.hug(body) })),
        softline,
        try b.text(")"),
    }));
    // The head "f(long_first_argument, function()" is 33 columns.
    try expectPrint(&b, 33, d, "f(long_first_argument, function()\n        x\n    end)");
    try expectPrint(&b, 32, d, "f(\n    long_first_argument,\n    function()\n        x\n    end\n)");
}

test "format_doc: if_break picks by the group's mode" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.group(try b.cat(&.{
        try b.text("{"),
        try b.indent(try b.cat(&.{ line, try b.text("a = 1"), try b.ifBreak(try b.text(","), empty) })),
        line,
        try b.text("}"),
    }));
    try expectPrint(&b, 100, d, "{ a = 1 }");
    try expectPrint(&b, 6, d, "{\n    a = 1,\n}");
}

test "format_doc: alt takes the hugged layout when its first line fits, else the expanded one" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const body = try b.cat(&.{ try b.text("function()"), try b.indent(try b.cat(&.{ hardline, try b.text("x") })), hardline, try b.text("end") });
    const hugged = try b.cat(&.{ try b.text("f(aaaa, "), try b.hug(body), try b.text(")") });
    const expanded = try b.group(try b.cat(&.{
        try b.text("f("),
        try b.indent(try b.cat(&.{ softline, try b.text("aaaa,"), line, body })),
        softline,
        try b.text(")"),
    }));
    const d = try b.alt(hugged, expanded);
    try expectPrint(&b, 100, d, "f(aaaa, function()\n    x\nend)");
    try expectPrint(&b, 17, d, "f(\n    aaaa,\n    function()\n        x\n    end\n)");
}

test "format_doc: a trailing comment is written at the newline, after the code's comma" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.cat(&.{
        try b.text("a"),
        try b.lineSuffix(" -- first"),
        try b.text(","),
        hardline,
        try b.text("b"),
        try b.lineSuffix(" -- last"),
    });
    try expectPrint(&b, 100, d, "a, -- first\nb -- last");
}

test "format_doc: a trailing comment is not counted against the width" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.group(try b.cat(&.{ try b.text("f("), try b.text("a"), try b.lineSuffix(" -- a very long trailing comment indeed"), try b.text(")") }));
    try expectPrint(&b, 12, d, "f(a) -- a very long trailing comment indeed");
}

test "format_doc: fill packs items per line, aligned to the indent" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    var items: [10]Doc = undefined;
    const names = [_][]const u8{ "1,", "2,", "3,", "4,", "5,", "6,", "7,", "8,", "9,", "10," };
    for (names, 0..) |n, i| items[i] = try b.text(n);
    const d = try b.group(try b.cat(&.{
        try b.text("{"),
        try b.indent(try b.cat(&.{ hardline, try b.fill(&items) })),
        hardline,
        try b.text("}"),
    }));
    try expectPrint(&b, 100, d, "{\n    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,\n}");
    try expectPrint(&b, 15, d, "{\n    1, 2, 3, 4,\n    5, 6, 7, 8,\n    9, 10,\n}");
    try expectPrint(&b, 14, d, "{\n    1, 2, 3,\n    4, 5, 6,\n    7, 8, 9,\n    10,\n}");
}

test "format_doc: raw text is verbatim; its last line sets the column" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.cat(&.{
        try b.text("local s = "),
        try b.raw("[[a  \n  b  ]]"),
        hardline,
        try b.text("x"),
    });
    try expectPrint(&b, 100, d, "local s = [[a  \n  b  ]]\nx");
    // A group holding a raw token fits on its first line.
    const g = try b.group(try b.cat(&.{ try b.text("f("), try b.raw("[[a\nb]]"), try b.text(")") }));
    try expectPrint(&b, 100, g, "f([[a\nb]])");
}

test "format_doc: no trailing spaces before a newline; multibyte text counts code points" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    const d = try b.cat(&.{ try b.text("a "), hardline, try b.text("b") });
    try expectPrint(&b, 100, d, "a\nb");
    try testing.expectEqual(@as(u32, 3), textWidth("añ€"));
    const g = try b.group(try b.cat(&.{ try b.text("ñññ"), line, try b.text("ñññ") }));
    try expectPrint(&b, 7, g, "ñññ ñññ");
    try expectPrint(&b, 6, g, "ñññ\nñññ");
}

test "format_doc: deciding deeply nested groups reads a bounded amount of text" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
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
    const got = try print(testing.allocator, &b, d, .{ .width = 100 }, &stats);
    defer testing.allocator.free(got);
    // Every group's lookahead stops once the width is spent: at most a
    // constant number of nodes per column, per group.
    try testing.expect(stats.fits_steps <= @as(u64, depth) * 100 * 6);
    // And the output is the broken staircase, not a hang.
    try testing.expect(std.mem.count(u8, got, "\n") > depth);
}

test "format_doc: parts fed one at a time print as one document; a released part's trailing comment survives" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    var p: Printer = .init(testing.allocator, &b, .{});
    defer p.deinit();
    const m = b.mark();
    // Not source text: the suffix is in the builder's own bytes.
    try p.feed(try b.cat(&.{ try b.text("alpha"), try b.lineSuffix(" -- first") }));
    b.release(m);
    // The next part reuses the released memory.
    const second = try b.cat(&.{ try b.text("bravo"), try b.lineSuffix(" -- second") });
    try p.feed(hardline);
    try p.feed(second);
    const got = try p.finish();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("alpha -- first\nbravo -- second", got);
}

test "format_doc: text from the source is a span of it, and punctuation is made once" {
    const src = "local name = 1";
    var b: Builder = try .init(testing.allocator, src);
    defer b.deinit();
    const before = b.bytes.items.len;
    const d = try b.text(src[6..10]);
    try testing.expectEqual(Tag.text_src, b.node(d).tag);
    try testing.expectEqualStrings("name", b.str(b.node(d)));
    try testing.expectEqual(before, b.bytes.items.len);
    try testing.expectEqual(try b.text(", "), try b.text(", "));
    // A one-part concatenation is the part; empty parts are dropped.
    try testing.expectEqual(d, try b.cat(&.{ empty, d, empty }));
}

test "format_doc: a very wide document is walked one child at a time" {
    var b: Builder = try .init(testing.allocator, "");
    defer b.deinit();
    // One group of 20,000 children, and a fill of as many items.
    const n = 20_000;
    const t = b.top();
    for (0..n) |_| try b.push(try b.text("ab"));
    const wide = try b.group(try b.catFrom(t));
    for (0..n) |_| try b.push(try b.text("cd,"));
    const filled = try b.group(try b.indent(try b.fillFrom(t)));
    // Deciding the wide group stops after the width: a few nodes per column
    // (before, every child was pushed first). The stacks hold one entry per
    // level of nesting, not one per child.
    var stats: Stats = .{};
    const got = try print(testing.allocator, &b, wide, .{ .width = 100 }, &stats);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2 * n), got.len);
    try testing.expect(stats.fits_steps <= 100 * 3);
    try testing.expect(stats.work_bytes <= 64 * @sizeOf(Cmd));
    // The fill decides each item against what fits on its line: a bounded
    // number of nodes per item.
    var fstats: Stats = .{};
    const fgot = try print(testing.allocator, &b, filled, .{ .width = 100 }, &fstats);
    defer testing.allocator.free(fgot);
    try testing.expect(fstats.fits_steps <= @as(u64, n) * 8);
    try testing.expect(fstats.work_bytes <= 64 * @sizeOf(Cmd));
}
